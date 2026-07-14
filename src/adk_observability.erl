%% @doc Correlated telemetry and safe structured event/log envelopes.
%%
%% The module has no mandatory OpenTelemetry dependency. It emits ordinary
%% `telemetry' events carrying stable correlation metadata and can deliver the
%% same JSON-safe envelope to optional bounded exporters. Prompt, response,
%% tool arguments, and other content are omitted unless capture is explicitly
%% enabled; authentication material is pruned in either mode.
-module(adk_observability).

-export([
    schema_version/0,
    new_context/0,
    new_context/1,
    child_context/2,
    emit/3,
    emit/4,
    validate_exporters/1,
    export/2,
    encode/1,
    decode/1
]).

-define(VERSION, 1).
-define(DEFAULT_EXPORT_TIMEOUT_MS, 1000).
-define(DEFAULT_EXPORT_MAX_HEAP_WORDS, 250000).

-type context() :: map().
-type envelope() :: map().
-export_type([context/0, envelope/0]).

-spec schema_version() -> pos_integer().
schema_version() -> ?VERSION.

-spec new_context() -> {ok, context()}.
new_context() ->
    new_context(#{}).

%% @doc Build a root correlation context.
%%
%% Known identity fields are copied explicitly; unknown safe fields are placed
%% below `attributes'. Binary input is never converted into an atom.
-spec new_context(map()) -> {ok, context()} | {error, term()}.
new_context(Attrs) when is_map(Attrs) ->
    case adk_context_guard:sanitize_value(Attrs) of
        {ok, Safe} when is_map(Safe) ->
            TraceId = value_or_id(Safe, <<"trace_id">>, 16),
            SpanId = value_or_id(Safe, <<"span_id">>, 8),
            case explicit_attributes(Safe) of
                {ok, ExplicitAttributes} ->
                    UnknownAttributes = maps:without(
                                          known_binary_keys(), Safe),
                    Context0 = #{
                        trace_id => TraceId,
                        span_id => SpanId,
                        parent_id => optional_binary(
                                       Safe, <<"parent_id">>, null),
                        run_id => optional_binary(Safe, <<"run_id">>, null),
                        invocation_id => optional_binary(
                                           Safe, <<"invocation_id">>, null),
                        session => session_value(Safe),
                        agent => optional_binary(Safe, <<"agent">>, null),
                        model => optional_binary(Safe, <<"model">>, null),
                        tool => optional_binary(Safe, <<"tool">>, null),
                        call_id => optional_binary(Safe, <<"call_id">>, null),
                        attributes => maps:merge(
                                        ExplicitAttributes,
                                        UnknownAttributes)
                    },
                    validate_context(Context0);
                {error, _} = Error -> Error
            end;
        {ok, _} -> {error, invalid_observability_context};
        {error, Reason} ->
            {error, {invalid_observability_context, reason_tag(Reason)}}
    end;
new_context(_) ->
    {error, invalid_observability_context}.

%% @doc Create a correlated child span context.
%%
%% Trace/run/session identity is inherited. The parent's span ID becomes the
%% child parent ID. Additional agent/model/tool/call fields may be overridden.
-spec child_context(context(), map()) ->
    {ok, context()} | {error, term()}.
child_context(Parent, Attrs) when is_map(Parent), is_map(Attrs) ->
    case validate_context(Parent) of
        {ok, ValidParent} ->
            Base = context_to_input(ValidParent),
            Forced = Base#{
                <<"trace_id">> => maps:get(trace_id, ValidParent),
                <<"parent_id">> => maps:get(span_id, ValidParent),
                <<"span_id">> => generate_id(8)
            },
            case adk_context_guard:sanitize_value(Attrs) of
                {ok, SafeAttrs} when is_map(SafeAttrs) ->
                    %% Correlation lineage cannot be replaced by untrusted
                    %% child attributes.
                    Extra = maps:without(
                              [<<"trace_id">>, <<"parent_id">>,
                               <<"span_id">>, <<"run_id">>,
                               <<"invocation_id">>, <<"session">>,
                               <<"session_id">>], SafeAttrs),
                    new_context(maps:merge(Forced, Extra));
                {ok, _} -> {error, invalid_observability_context};
                {error, Reason} ->
                    {error, {invalid_observability_context,
                             reason_tag(Reason)}}
            end;
        {error, _} = Error -> Error
    end;
child_context(_, _) ->
    {error, invalid_observability_context}.

-spec emit([atom(), ...], map(), context()) ->
    {ok, envelope()} | {error, term()}.
emit(EventName, Measurements, Context) ->
    emit(EventName, Measurements, Context, #{}).

%% @doc Emit a connected telemetry event and return its structured envelope.
%%
%% Options are `attributes', `capture_content' (default false), and `content'.
%% Even when capture is enabled, secret-bearing keys are removed before either
%% telemetry handlers or exporters can see them.
-spec emit([atom(), ...], map(), context(), map()) ->
    {ok, envelope()} | {error, term()}.
emit(EventName, Measurements0, Context0, Opts)
  when is_list(EventName), is_map(Measurements0), is_map(Context0),
       is_map(Opts) ->
    case valid_event_name(EventName) of
        true ->
            case {validate_context(Context0),
                  safe_map(Measurements0),
                  safe_map(maps:get(attributes, Opts, #{})),
                  validate_capture(maps:get(capture_content, Opts, false))} of
                {{ok, Context}, {ok, Measurements}, {ok, Attributes},
                 {ok, Capture}} ->
                    build_and_emit(EventName, Measurements, Context,
                                   Attributes, Capture, Opts);
                {{error, _} = Error, _, _, _} -> Error;
                {_, {error, _} = Error, _, _} -> Error;
                {_, _, {error, _} = Error, _} -> Error;
                {_, _, _, {error, _} = Error} -> Error
            end;
        false -> {error, invalid_telemetry_event_name}
    end;
emit(_, _, _, _) ->
    {error, invalid_observability_emit_arguments}.

%% @doc Deliver one already-safe envelope to bounded exporters in list order.
%%
%% Exporter descriptors use `id', `module', optional `config', `timeout_ms',
%% `max_heap_words', and `failure_policy' (`open' by default). Fail-open
%% exporters report failure and allow later exporters to run. Fail-closed stops
%% immediately with a typed error.
-spec export(envelope(), [map()]) ->
    {ok, [map()]} | {error, term()} | {error, term(), [map()]}.
export(Envelope0, Exporters) when is_map(Envelope0), is_list(Exporters) ->
    case encode(Envelope0) of
        {ok, Envelope} -> export_all(Envelope, Exporters, 0, [], #{});
        {error, _} = Error -> Error
    end;
export(_, _) ->
    {error, invalid_export_arguments, []}.

%% @doc Validate exporter descriptors at Runner construction time.
%% Callback execution still revalidates the immutable descriptors so a forged
%% Runner term cannot bypass the boundary.
-spec validate_exporters([map()]) -> ok | {error, term()}.
validate_exporters(Exporters) when is_list(Exporters) ->
    validate_exporters(Exporters, 0, #{});
validate_exporters(_) ->
    {error, invalid_exporter_list}.

%% @doc Verify and return the canonical JSON-safe envelope.
-spec encode(envelope()) -> {ok, envelope()} | {error, term()}.
encode(#{<<"schema_version">> := ?VERSION,
         <<"event">> := Event,
         <<"timestamp_ms">> := Timestamp,
         <<"measurements">> := Measurements,
         <<"metadata">> := Metadata} = Envelope)
  when is_binary(Event), is_integer(Timestamp), is_map(Measurements),
       is_map(Metadata) ->
    case adk_context_guard:sanitize_value(Envelope) of
        {ok, Safe} when is_map(Safe) -> {ok, Safe};
        {ok, _} -> {error, invalid_observability_envelope};
        {error, Reason} ->
            {error, {invalid_observability_envelope, reason_tag(Reason)}}
    end;
encode(#{<<"schema_version">> := Version}) when Version =/= ?VERSION ->
    {error, {unsupported_observability_schema_version, Version}};
encode(_) ->
    {error, invalid_observability_envelope}.

%% @doc Decode a persisted envelope. Unknown schema versions are rejected.
-spec decode(map()) -> {ok, envelope()} | {error, term()}.
decode(Envelope) -> encode(Envelope).

build_and_emit(EventName, Measurements, Context, Attributes, Capture, Opts) ->
    {ContentCaptured, CaptureAttributes, CapturedContent} =
        capture_content(Capture, Opts),
    EffectiveAttributes = maps:merge(Attributes, CaptureAttributes),
    Metadata0 = telemetry_metadata(Context),
    Metadata = Metadata0#{attributes => EffectiveAttributes,
                          content_captured => ContentCaptured},
    Base0 = #{
        <<"schema_version">> => ?VERSION,
        <<"event">> => event_binary(EventName),
        <<"timestamp_ms">> => erlang:system_time(millisecond),
        <<"measurements">> => Measurements,
        <<"metadata">> => metadata_envelope(Metadata0, EffectiveAttributes),
        <<"content_captured">> => ContentCaptured
    },
    Envelope = maybe_add_captured_content(Base0, CapturedContent),
    maybe_telemetry_execute(EventName, Measurements, Metadata),
    {ok, Envelope}.

maybe_telemetry_execute(EventName, Measurements, Metadata) ->
    %% Some library-level unit tests intentionally exercise a Runner without
    %% starting the OTP application. Building/exporting the safe envelope must
    %% still work and should not make telemetry log a handler-table warning.
    case erlang:whereis(telemetry_handler_table) of
        undefined -> ok;
        _Pid -> telemetry:execute(EventName, Measurements, Metadata)
    end.

%% Observability must never destabilize an invocation. If explicitly requested
%% content contains an opaque Erlang term (pid, port, reference, or fun), emit
%% the metadata-only envelope and record a stable capture diagnostic instead.
capture_content(false, _Opts) ->
    {false, #{}, none};
capture_content(true, Opts) ->
    case adk_context_guard:sanitize_value(maps:get(content, Opts, null)) of
        {ok, Content} -> {true, #{}, {some, Content}};
        {error, _Reason} ->
            {false, #{<<"capture_error">> => <<"unsupported_content">>}, none}
    end.

maybe_add_captured_content(Base, none) -> Base;
maybe_add_captured_content(Base, {some, Content}) ->
    Base#{<<"content">> => Content}.

telemetry_metadata(Context) ->
    maps:with([run_id, invocation_id, session, agent, model, tool, call_id,
               trace_id, span_id, parent_id], Context).

metadata_envelope(Metadata, Attributes) ->
    BinaryMetadata = maps:from_list(
                       [{atom_to_binary(Key, utf8), Value}
                        || {Key, Value} <- maps:to_list(Metadata)]),
    BinaryMetadata#{<<"attributes">> => Attributes}.

validate_context(Context) when is_map(Context) ->
    Required = [trace_id, span_id, parent_id, run_id, invocation_id,
                session, agent, model, tool, call_id, attributes],
    case lists:all(fun(Key) -> maps:is_key(Key, Context) end, Required) of
        true ->
            Values = [maps:get(Key, Context)
                      || Key <- Required, Key =/= attributes],
            case lists:all(fun valid_optional_id/1, Values) andalso
                 is_map(maps:get(attributes, Context)) of
                true ->
                    case safe_map(maps:get(attributes, Context)) of
                        {ok, SafeAttributes} ->
                            {ok, Context#{attributes => SafeAttributes}};
                        {error, _} = Error -> Error
                    end;
                false -> {error, invalid_observability_context}
            end;
        false -> {error, invalid_observability_context}
    end.

valid_optional_id(null) -> true;
valid_optional_id(Value) when is_binary(Value), byte_size(Value) > 0 -> true;
valid_optional_id(_) -> false.

safe_map(Value) ->
    case adk_context_guard:sanitize_value(Value) of
        {ok, Safe} when is_map(Safe) -> {ok, Safe};
        {ok, _} -> {error, invalid_observability_map};
        {error, Reason} ->
            {error, {invalid_observability_map, reason_tag(Reason)}}
    end.

validate_capture(true) -> {ok, true};
validate_capture(false) -> {ok, false};
validate_capture(_) -> {error, invalid_content_capture_option}.

valid_event_name([Head | Rest]) when is_atom(Head) ->
    lists:all(fun erlang:is_atom/1, Rest);
valid_event_name(_) -> false.

event_binary(EventName) ->
    Parts = [atom_to_binary(Part, utf8) || Part <- EventName],
    iolist_to_binary(lists:join(<<".">>, Parts)).

context_to_input(Context) ->
    Base = maps:from_list(
             [{atom_to_binary(Key, utf8), Value}
              || {Key, Value} <- maps:to_list(
                   maps:without([attributes], Context))]),
    maps:merge(maps:get(attributes, Context), Base).

session_value(Safe) ->
    case maps:find(<<"session">>, Safe) of
        {ok, Value} -> valid_or_null(Value);
        error -> optional_binary(Safe, <<"session_id">>, null)
    end.

value_or_id(Safe, Key, Bytes) ->
    case maps:get(Key, Safe, undefined) of
        Value when is_binary(Value), byte_size(Value) > 0 -> Value;
        _ -> generate_id(Bytes)
    end.

optional_binary(Safe, Key, Default) ->
    valid_or_default(maps:get(Key, Safe, Default), Default).

valid_or_null(Value) -> valid_or_default(Value, null).

valid_or_default(Value, _Default)
  when is_binary(Value), byte_size(Value) > 0 -> Value;
valid_or_default(null, _Default) -> null;
valid_or_default(_Value, Default) -> Default.

known_binary_keys() ->
    [<<"trace_id">>, <<"span_id">>, <<"parent_id">>, <<"run_id">>,
     <<"invocation_id">>, <<"session">>, <<"session_id">>,
     <<"agent">>, <<"model">>, <<"tool">>, <<"call_id">>,
     <<"attributes">>].

explicit_attributes(Safe) ->
    case maps:get(<<"attributes">>, Safe, #{}) of
        Attributes when is_map(Attributes) -> {ok, Attributes};
        _ -> {error, invalid_observability_attributes}
    end.

generate_id(Bytes) ->
    << <<(hex(Nibble))>> || <<Nibble:4>> <= crypto:strong_rand_bytes(Bytes) >>.

hex(N) when N < 10 -> $0 + N;
hex(N) -> $a + (N - 10).

export_all(_Envelope, [], _Index, Acc, _Ids) ->
    {ok, lists:reverse(Acc)};
export_all(Envelope, [Descriptor | Rest], Index, Acc, Ids)
  when is_map(Descriptor) ->
    case compile_exporter(Descriptor, Index, Ids) of
        {ok, Exporter, NewIds} ->
            Status = run_exporter(Envelope, Exporter),
            Entry = exporter_status(Exporter, Status),
            case {Status, maps:get(failure_policy, Exporter)} of
                {ok, _} ->
                    export_all(Envelope, Rest, Index + 1,
                               [Entry | Acc], NewIds);
                {{error, _Failure}, open} ->
                    export_all(Envelope, Rest, Index + 1,
                               [Entry | Acc], NewIds);
                {{error, Failure}, closed} ->
                    {error, {exporter_failed, maps:get(id, Exporter), Failure},
                     lists:reverse([Entry | Acc])}
            end;
        {error, Reason} ->
            {error, Reason, lists:reverse(Acc)}
    end;
export_all(_Envelope, [_ | _], Index, Acc, _Ids) ->
    {error, {invalid_exporter_descriptor, Index}, lists:reverse(Acc)};
export_all(_Envelope, _Improper, Index, Acc, _Ids) ->
    {error, {invalid_exporter_list, Index}, lists:reverse(Acc)}.

compile_exporter(Descriptor, Index, Ids) ->
    Id = maps:get(id, Descriptor, undefined),
    Module = maps:get(module, Descriptor, undefined),
    Config = maps:get(config, Descriptor, #{}),
    Timeout = maps:get(timeout_ms, Descriptor,
                       ?DEFAULT_EXPORT_TIMEOUT_MS),
    Heap = maps:get(max_heap_words, Descriptor,
                    ?DEFAULT_EXPORT_MAX_HEAP_WORDS),
    Failure = maps:get(failure_policy, Descriptor, open),
    case {is_binary(Id) andalso byte_size(Id) > 0,
          is_atom(Module), is_map(Config),
          is_integer(Timeout) andalso Timeout > 0,
          is_integer(Heap) andalso Heap >= 1000,
          Failure =:= open orelse Failure =:= closed,
          maps:is_key(Id, Ids)} of
        {true, true, true, true, true, true, false} ->
            case code:ensure_loaded(Module) of
                {module, Module} ->
                    case erlang:function_exported(Module, export, 2) of
                        true ->
                            {ok, #{id => Id, module => Module,
                                   config => Config, timeout_ms => Timeout,
                                   max_heap_words => Heap,
                                   failure_policy => Failure},
                             Ids#{Id => true}};
                        false ->
                            {error, {invalid_exporter_descriptor, Index,
                                     missing_callback}}
                    end;
                _ ->
                    {error, {invalid_exporter_descriptor, Index,
                             module_unavailable}}
            end;
        {_, _, _, _, _, _, true} -> {error, {duplicate_exporter_id, Id}};
        _ -> {error, {invalid_exporter_descriptor, Index}}
    end.

validate_exporters([], _Index, _Ids) -> ok;
validate_exporters([Descriptor | Rest], Index, Ids)
  when is_map(Descriptor) ->
    case compile_exporter(Descriptor, Index, Ids) of
        {ok, Exporter, NewIds} ->
            _ = Exporter,
            validate_exporters(Rest, Index + 1, NewIds);
        {error, _} = Error -> Error
    end;
validate_exporters([_ | _], Index, _Ids) ->
    {error, {invalid_exporter_descriptor, Index}};
validate_exporters(_Improper, Index, _Ids) ->
    {error, {invalid_exporter_list, Index}}.

run_exporter(Envelope, Exporter) ->
    Parent = self(),
    Ref = make_ref(),
    Module = maps:get(module, Exporter),
    Config = maps:get(config, Exporter),
    Worker = fun() ->
        Result = try Module:export(Envelope, Config) of
            ok -> ok;
            {error, _} -> {error, exporter_error};
            _ -> {error, invalid_result}
        catch
            _:_ -> {error, exception}
        end,
        Parent ! {adk_exporter_reply, Ref, self(), Result}
    end,
    {Pid, Monitor} = spawn_opt(
                       Worker,
                       [monitor,
                        {max_heap_size,
                         #{size => maps:get(max_heap_words, Exporter),
                           kill => true, error_logger => false}}]),
    receive
        {adk_exporter_reply, Ref, Pid, Result} ->
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Pid, _} ->
            flush_export_reply(Ref, Pid),
            {error, worker_down}
    after maps:get(timeout_ms, Exporter) ->
        exit(Pid, kill),
        receive {'DOWN', Monitor, process, Pid, _} -> ok
        after 100 -> erlang:demonitor(Monitor, [flush])
        end,
        flush_export_reply(Ref, Pid),
        {error, timeout}
    end.

flush_export_reply(Ref, Pid) ->
    receive {adk_exporter_reply, Ref, Pid, _} -> ok after 0 -> ok end.

exporter_status(Exporter, ok) ->
    #{<<"exporter_id">> => maps:get(id, Exporter),
      <<"status">> => <<"ok">>};
exporter_status(Exporter, {error, Failure}) ->
    #{<<"exporter_id">> => maps:get(id, Exporter),
      <<"status">> => <<"error">>,
      <<"reason">> => atom_to_binary(Failure, utf8)}.

reason_tag({Tag, _}) when is_atom(Tag) -> Tag;
reason_tag({Tag, _, _}) when is_atom(Tag) -> Tag.
