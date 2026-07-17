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
    from_headers/2,
    inject_headers/2,
    child_context/2,
    start_span/5,
    finish_span/3,
    report_delivery_failure/3,
    emit/3,
    emit/4,
    validate_exporters/1,
    export/2,
    deliver/2,
    encode/1,
    decode/1
]).

-define(VERSION, 1).
-define(DEFAULT_EXPORT_TIMEOUT_MS, 1000).
-define(DEFAULT_EXPORT_MAX_HEAP_WORDS, 250000).
-define(MAX_EXPORTERS, 64).
-define(MAX_EXPORTER_ID_BYTES, 128).
-define(MAX_EXPORT_TIMEOUT_MS, 30000).
-define(MAX_EXPORT_HEAP_WORDS, 10000000).
-define(MAX_EXPORT_CONFIG_BYTES, 1048576).
-define(EXPORT_GUARD_HEAP_WORDS, 65536).

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
                        trace_flags => maps:get(<<"trace_flags">>, Safe, 1),
                        tracestate => maps:get(<<"tracestate">>, Safe, null),
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

%% @doc Continue a valid inbound W3C trace with a fresh local span.
%%
%% This function validates wire syntax but deliberately does not decide
%% whether the remote sampling bit should be trusted.  Network boundaries may
%% clear `trace_flags' or start a new trace before calling it.
-spec from_headers(map() | list(), map()) ->
    {ok, context()} | {error, term()} | not_found.
from_headers(Headers, Attrs) when is_map(Attrs) ->
    case adk_trace_context:extract(Headers) of
        {ok, Remote} ->
            SafeAttrs = maps:without(
                          [trace_id, span_id, parent_id, trace_flags,
                           tracestate, <<"trace_id">>, <<"span_id">>,
                           <<"parent_id">>, <<"trace_flags">>,
                           <<"tracestate">>], Attrs),
            Input = SafeAttrs#{
                      trace_id => maps:get(trace_id, Remote),
                      parent_id => maps:get(span_id, Remote),
                      trace_flags => maps:get(trace_flags, Remote),
                      tracestate => maps:get(tracestate, Remote)},
            new_context(Input);
        not_found -> not_found;
        {error, _} = Error -> Error
    end;
from_headers(_, _) ->
    {error, invalid_observability_headers}.

%% @doc Inject this context into outbound HTTP-style headers.
-spec inject_headers(context(), map() | list()) ->
    {ok, map() | list()} | {error, term()}.
inject_headers(Context, Headers) ->
    case validate_context(Context) of
        {ok, Valid} -> adk_trace_context:inject(Valid, Headers);
        {error, _} = Error -> Error
    end.

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
                <<"span_id">> => generate_id(8),
                <<"trace_flags">> => maps:get(trace_flags, ValidParent),
                <<"tracestate">> => maps:get(tracestate, ValidParent)
            },
            case adk_context_guard:sanitize_value(Attrs) of
                {ok, SafeAttrs} when is_map(SafeAttrs) ->
                    %% Correlation lineage cannot be replaced by untrusted
                    %% child attributes.
                    Extra = maps:without(
                              [<<"trace_id">>, <<"parent_id">>,
                               <<"span_id">>, <<"run_id">>,
                               <<"trace_flags">>, <<"tracestate">>,
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

%% @doc Start a real operation span at the execution boundary.
%%
%% `Details' is mapped through the pinned metadata-only GenAI convention; it
%% cannot inject prompt/output content.  The returned handle carries monotonic
%% timing and must be finished exactly once by the operation owner.
-spec start_span(atom() | binary(), atom() | binary(), context(), map(), map()) ->
    {ok, map()} | {error, term()}.
start_span(Operation, Kind, Parent, Details, Delivery)
  when is_map(Parent), is_map(Details), is_map(Delivery) ->
    ChildAttrs = maps:with([model, tool, call_id,
                            <<"model">>, <<"tool">>, <<"call_id">>],
                           Details),
    case child_context(Parent, ChildAttrs) of
        {ok, Child} ->
            case adk_genai_semconv:attributes(Operation, Child, Details) of
                {ok, Attributes} ->
                    Name = span_name(Operation),
                    case adk_observability_signal:start_span(
                           Name, Kind, Child, Attributes) of
                        {ok, SignalHandle, Signal} ->
                            case deliver(Signal, Delivery) of
                                {ok, _} ->
                                    emit_signal_telemetry(start, Signal),
                                    {ok, #{signal_handle => SignalHandle,
                                           delivery => Delivery,
                                           operation => Operation,
                                           context => Child}};
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
start_span(_, _, _, _, _) -> {error, invalid_span_start}.

%% @doc Finish an operation span and update bounded low-cardinality metrics.
-spec finish_span(map(), term(), map()) -> {ok, map()} | {error, term()}.
finish_span(#{signal_handle := SignalHandle, delivery := Delivery,
              operation := Operation, context := Context}, Status, Details)
  when is_map(Details) ->
    case adk_genai_semconv:attributes(Operation, Context, Details) of
        {ok, Attributes} ->
            case adk_observability_signal:finish_span(
                   SignalHandle, Status, Attributes) of
                {ok, Signal} ->
                    %% The operation already completed. Record the local end
                    %% signal regardless of whether an external exporter can
                    %% accept it; callers handle external delivery failure as
                    %% a separate diagnostic and must not turn a successful
                    %% side effect into a retryable operation error.
                    emit_signal_telemetry(stop, Signal),
                    record_span_metrics(Signal),
                    case deliver(Signal, Delivery) of
                        {ok, _} -> {ok, Signal};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
finish_span(_, _, _) -> {error, invalid_span_handle}.

%% @doc Surface an exporter failure which happened after an operation had
%% already completed. Only structural tags and correlation IDs are emitted;
%% the untrusted exporter reason is never forwarded. This diagnostic is
%% deliberately separate from the operation result so callers cannot replay a
%% successful model/tool side effect merely because span delivery failed.
-spec report_delivery_failure(atom(), term(), map()) -> ok.
report_delivery_failure(Phase, Reason,
                        #{operation := Operation, context := Context})
  when is_atom(Phase), is_map(Context) ->
    Failure = reason_tag(Reason),
    Metadata = #{phase => Phase,
                 operation => safe_operation(Operation),
                 reason => Failure,
                 trace_id => maps:get(trace_id, Context, null),
                 span_id => maps:get(span_id, Context, null)},
    case erlang:whereis(telemetry_handler_table) of
        undefined -> ok;
        _ -> telemetry:execute(
               [erlang_adk, observability, delivery_failure],
               #{count => 1}, Metadata)
    end,
    case erlang:whereis(adk_observability_metrics) of
        undefined -> ok;
        _ ->
            _ = adk_observability_metrics:record(
                  <<"erlang_adk.observability.delivery.failures">>, counter,
                  1, #{<<"status">> => <<"error">>,
                       <<"error.type">> => atom_to_binary(Failure, utf8)}),
            ok
    end;
report_delivery_failure(_Phase, _Reason, _Span) -> ok.

safe_operation(Operation) when is_atom(Operation) -> Operation;
safe_operation(Operation) when is_binary(Operation) -> Operation;
safe_operation(_) -> unknown.

%% @doc Deliver one already-safe envelope to bounded exporters in list order.
%%
%% Exporter descriptors use `id', `module', optional `config', `timeout_ms',
%% `max_heap_words', and `failure_policy' (`open' by default). Fail-open
%% exporters report failure and allow later exporters to run. Fail-closed stops
%% immediately with a typed error.
-spec export(envelope(), [map()]) ->
    {ok, [map()]} | {error, term()} | {error, term(), [map()]}.
export(Envelope0, Exporters) when is_map(Envelope0) ->
    case encode(Envelope0) of
        {ok, Envelope} ->
            %% Preflight the complete bounded list before invoking the first
            %% exporter. An invalid tail must never cause partial side effects.
            case validate_exporters(Exporters) of
                ok -> export_all(Envelope, Exporters, 0, [], #{});
                {error, Reason} -> {error, Reason, []}
            end;
        {error, _} = Error -> Error
    end;
export(_, _) ->
    {error, invalid_export_arguments, []}.

%% @doc Deliver through either the compatibility synchronous path or the
%% bounded supervised asynchronous bus.
%%
%% Async admission is explicit: a full queue is returned to the caller and is
%% also visible in bus counters.  `failure_policy' controls whether admission
%% failure is reported (`closed') or converted into a structural dropped
%% result (`open').
-spec deliver(envelope(), map()) -> {ok, term()} | {error, term()}.
deliver(Envelope, #{delivery := async} = Config) ->
    Server = maps:get(bus, Config, adk_observability_bus),
    FailurePolicy = maps:get(failure_policy, Config, open),
    case adk_observability_bus:enqueue(Server, Envelope) of
        {ok, Admission} -> {ok, Admission};
        {error, Reason} when FailurePolicy =:= open ->
            {ok, #{status => dropped, reason => reason_tag(Reason)}};
        {error, Reason} when FailurePolicy =:= closed ->
            {error, {observability_bus_admission_failed,
                     reason_tag(Reason)}};
        {error, _Reason} -> {error, invalid_observability_failure_policy}
    end;
deliver(Envelope, #{delivery := sync} = Config) ->
    case export(Envelope, maps:get(exporters, Config, [])) of
        {ok, Statuses} -> {ok, Statuses};
        {error, Reason, _Statuses} -> {error, Reason};
        {error, Reason} -> {error, Reason}
    end;
deliver(Envelope, #{exporters := _} = Config) ->
    deliver(Envelope, Config#{delivery => sync});
deliver(_, _) -> {error, invalid_observability_delivery_config}.

%% @doc Validate exporter descriptors at Runner construction time.
%% Callback execution still revalidates the immutable descriptors so a forged
%% Runner term cannot bypass the boundary.
-spec validate_exporters([map()]) -> ok | {error, term()}.
validate_exporters([]) ->
    validate_exporters([], 0, #{});
validate_exporters([_ | _] = Exporters) ->
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
encode(#{<<"schema_version">> := 2} = Signal) ->
    adk_observability_signal:validate(Signal);
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
               trace_id, span_id, parent_id, trace_flags, tracestate],
              Context).

metadata_envelope(Metadata, Attributes) ->
    BinaryMetadata = maps:from_list(
                       [{atom_to_binary(Key, utf8), Value}
                        || {Key, Value} <- maps:to_list(Metadata)]),
    BinaryMetadata#{<<"attributes">> => Attributes}.

span_name(Operation) when is_atom(Operation) ->
    span_name(atom_to_binary(Operation, utf8));
span_name(Operation) when is_binary(Operation) ->
    <<"gen_ai.", Operation/binary>>.

emit_signal_telemetry(Phase, Signal) ->
    case erlang:whereis(telemetry_handler_table) of
        undefined -> ok;
        _ ->
            Measurements = case Phase of
                start -> #{system_time => maps:get(
                                           <<"start_time_unix_nano">>,
                                           Signal)};
                stop -> #{duration => maps:get(<<"duration_nano">>, Signal),
                          monotonic_time => erlang:monotonic_time()}
            end,
            Metadata = #{trace_id => maps:get(<<"trace_id">>, Signal),
                         span_id => maps:get(<<"span_id">>, Signal),
                         parent_id => maps:get(<<"parent_span_id">>, Signal),
                         name => maps:get(<<"name">>, Signal),
                         kind => maps:get(<<"kind">>, Signal),
                         attributes => maps:get(<<"attributes">>, Signal)},
            telemetry:execute([erlang_adk, operation, Phase],
                              Measurements, Metadata)
    end.

record_span_metrics(Signal) ->
    case erlang:whereis(adk_observability_metrics) of
        undefined -> ok;
        _Pid ->
            Attributes0 = maps:get(<<"attributes">>, Signal),
            Status = maps:get(<<"status">>, Signal),
            Attributes = Attributes0#{<<"status">> => Status},
            DurationMs = maps:get(<<"duration_nano">>, Signal) / 1000000,
            _ = adk_observability_metrics:record(
                  <<"gen_ai.client.operation.duration">>, histogram,
                  DurationMs, Attributes),
            _ = adk_observability_metrics:record(
                  <<"gen_ai.client.operation.count">>, counter, 1,
                  Attributes),
            ok
    end.

validate_context(Context) when is_map(Context) ->
    Required = [trace_id, span_id, parent_id, run_id, invocation_id,
                session, agent, model, tool, call_id, trace_flags,
                tracestate, attributes],
    case lists:all(fun(Key) -> maps:is_key(Key, Context) end, Required) of
        true ->
            validate_context_fields(Context);
        false -> {error, invalid_observability_context}
    end.

validate_context_fields(Context) ->
    OtherValues = [maps:get(Key, Context)
                   || Key <- [run_id, invocation_id, session, agent,
                              model, tool, call_id]],
    Parent = maps:get(parent_id, Context),
    ParentValid = Parent =:= null orelse
                  adk_trace_context:validate_span_id(Parent) =:= ok,
    case {adk_trace_context:validate_trace_id(maps:get(trace_id, Context)),
          adk_trace_context:validate_span_id(maps:get(span_id, Context)),
          valid_trace_flags(maps:get(trace_flags, Context)),
          adk_trace_context:validate_tracestate(
            maps:get(tracestate, Context)),
          ParentValid,
          lists:all(fun valid_optional_id/1, OtherValues),
          is_map(maps:get(attributes, Context))} of
        {ok, ok, true, {ok, Tracestate}, true, true, true} ->
            case safe_map(maps:get(attributes, Context)) of
                {ok, SafeAttributes} ->
                    {ok, Context#{attributes => SafeAttributes,
                                  tracestate => Tracestate}};
                {error, _} = Error -> Error
            end;
        _ -> {error, invalid_observability_context}
    end.

valid_trace_flags(Value) ->
    is_integer(Value) andalso Value >= 0 andalso Value =< 255.

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
     <<"trace_flags">>, <<"tracestate">>,
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
    end.

compile_exporter(Descriptor, Index, Ids) ->
    Allowed = [id, module, config, timeout_ms, max_heap_words,
               failure_policy],
    %% Count against the fixed allowlist without copying a potentially hostile
    %% descriptor map through maps:without/2.
    KnownCount = length([Key || Key <- Allowed,
                                maps:is_key(Key, Descriptor)]),
    UnknownCount = map_size(Descriptor) - KnownCount,
    Id = maps:get(id, Descriptor, undefined),
    Module = maps:get(module, Descriptor, undefined),
    Config = maps:get(config, Descriptor, #{}),
    Timeout = maps:get(timeout_ms, Descriptor,
                       ?DEFAULT_EXPORT_TIMEOUT_MS),
    Heap = maps:get(max_heap_words, Descriptor,
                    ?DEFAULT_EXPORT_MAX_HEAP_WORDS),
    Failure = maps:get(failure_policy, Descriptor, open),
    case validate_exporter_fields(
           UnknownCount, Id, Module, Config, Timeout, Heap, Failure, Ids) of
        ok ->
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
        {error, {duplicate_exporter_id, _} = Duplicate} ->
            {error, Duplicate};
        {error, Reason} ->
            {error, {invalid_exporter_descriptor, Index, Reason}}
    end.

validate_exporter_fields(Unknown, _Id, _Module, _Config, _Timeout,
                         _Heap, _Failure, _Ids) when Unknown > 0 ->
    {error, {unknown_exporter_options, Unknown}};
validate_exporter_fields(_Unknown, Id, _Module, _Config, _Timeout,
                         _Heap, _Failure, _Ids)
  when not is_binary(Id); Id =:= <<>> ->
    {error, invalid_id};
validate_exporter_fields(_Unknown, Id, _Module, _Config, _Timeout,
                         _Heap, _Failure, _Ids)
  when byte_size(Id) > ?MAX_EXPORTER_ID_BYTES ->
    {error, {exporter_id_too_long, byte_size(Id),
             ?MAX_EXPORTER_ID_BYTES}};
validate_exporter_fields(_Unknown, Id, _Module, _Config, _Timeout,
                         _Heap, _Failure, Ids)
  when is_map_key(Id, Ids) ->
    {error, {duplicate_exporter_id, Id}};
validate_exporter_fields(_Unknown, _Id, Module, _Config, _Timeout,
                         _Heap, _Failure, _Ids) when not is_atom(Module) ->
    {error, invalid_module};
validate_exporter_fields(_Unknown, _Id, _Module, Config, _Timeout,
                         _Heap, _Failure, _Ids) when not is_map(Config) ->
    {error, invalid_config};
validate_exporter_fields(_Unknown, _Id, _Module, Config, _Timeout,
                         _Heap, _Failure, _Ids) ->
    case bounded_exporter_config(Config) of
        ok ->
            validate_exporter_runtime_limits(_Timeout, _Heap, _Failure);
        {error, _} = Error -> Error
    end.

validate_exporter_runtime_limits(Timeout, _Heap, _Failure)
  when not is_integer(Timeout); Timeout =< 0;
       Timeout > ?MAX_EXPORT_TIMEOUT_MS ->
    {error, {exporter_timeout_out_of_range, ?MAX_EXPORT_TIMEOUT_MS}};
validate_exporter_runtime_limits(_Timeout, Heap, _Failure)
  when not is_integer(Heap); Heap < 1000;
       Heap > ?MAX_EXPORT_HEAP_WORDS ->
    {error, {exporter_heap_out_of_range, ?MAX_EXPORT_HEAP_WORDS}};
validate_exporter_runtime_limits(_Timeout, _Heap, Failure)
  when Failure =/= open, Failure =/= closed ->
    {error, invalid_failure_policy};
validate_exporter_runtime_limits(_Timeout, _Heap, _Failure) -> ok.

bounded_exporter_config(Config) ->
    try erlang:external_size(Config) of
        Bytes when Bytes =< ?MAX_EXPORT_CONFIG_BYTES -> ok;
        Bytes -> {error, {exporter_config_too_large, Bytes,
                          ?MAX_EXPORT_CONFIG_BYTES}}
    catch
        _:_ -> {error, invalid_config_size}
    end.

validate_exporters([], _Index, _Ids) -> ok;
validate_exporters([_ | _], Index, _Ids) when Index >= ?MAX_EXPORTERS ->
    {error, {exporter_limit_exceeded, ?MAX_EXPORTERS}};
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
    Owner = self(),
    Alias = erlang:alias([reply]),
    Module = maps:get(module, Exporter),
    Config = maps:get(config, Exporter),
    MaxHeap = maps:get(max_heap_words, Exporter),
    Guard = fun() ->
        exporter_guard(Owner, Alias, Module, Envelope, Config, MaxHeap)
    end,
    {Pid, Monitor} = spawn_opt(
                       Guard,
                       [monitor, {message_queue_data, off_heap},
                        {max_heap_size,
                         #{size => ?EXPORT_GUARD_HEAP_WORDS,
                           kill => true, error_logger => false}}]),
    Deadline = erlang:monotonic_time(millisecond) +
               maps:get(timeout_ms, Exporter),
    wait_exporter(Alias, Pid, Monitor, undefined, Deadline).

wait_exporter(Alias, Guard, Monitor, CallbackPid, Deadline) ->
    receive
        {adk_exporter_ready, Alias, Guard, ReadyCallback, StartRef}
          when CallbackPid =:= undefined ->
            Guard ! {adk_exporter_start, self(), StartRef},
            wait_exporter(Alias, Guard, Monitor, ReadyCallback, Deadline);
        {adk_exporter_reply, Alias, Guard, Result} ->
            %% Keep the guard alive until this process has consumed the alias
            %% reply. This makes the terminal result definitive without
            %% relying on alias-delivery versus monitor-teardown ordering.
            Guard ! {adk_exporter_reply_ack, self()},
            _ = erlang:unalias(Alias),
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Guard, _} ->
            _ = erlang:unalias(Alias),
            kill_exporter_callback(CallbackPid),
            flush_export_messages(Alias, Guard),
            {error, worker_down}
    after export_remaining(Deadline) ->
        _ = erlang:unalias(Alias),
        cancel_exporter(Guard, Monitor, CallbackPid),
        flush_export_messages(Alias, Guard),
        {error, timeout}
    end.

exporter_guard(Owner, Alias, Module, Envelope, Config, MaxHeap) ->
    process_flag(trap_exit, true),
    OwnerMonitor = erlang:monitor(process, Owner),
    Guard = self(),
    StartRef = make_ref(),
    Callback = fun() ->
        receive
            {adk_exporter_start, Guard, StartRef} ->
                %% Once user code can run, cancellation always uses its known
                %% PID and a direct exit(Pid, kill); active lifetime no longer
                %% depends on this bootstrap link.
                unlink(Guard),
                Result = run_exporter_callback(Module, Envelope, Config),
                Guard ! {adk_exporter_callback, self(), Result},
                %% Likewise, do not let callback DOWN race its result at the
                %% guard. The owner can still kill this process directly while
                %% it waits, including when exporter code enabled trap_exit.
                receive
                    {adk_exporter_callback_ack, Guard} -> ok
                end
        end
    end,
    {CallbackPid, CallbackMonitor} = spawn_opt(
                                       Callback,
                                       [link, monitor,
                                        {message_queue_data, off_heap},
                                        {max_heap_size,
                                         #{size => MaxHeap, kill => true,
                                           error_logger => false,
                                           include_shared_binaries => true}}]),
    %% A `reply' alias is single-use: reserve it for the terminal result.
    %% Readiness is an ordinary owner message, still correlated by Alias.
    Owner ! {adk_exporter_ready, Alias, self(), CallbackPid, StartRef},
    exporter_guard_wait_start(
      Owner, OwnerMonitor, Alias, CallbackPid, CallbackMonitor, StartRef).

exporter_guard_wait_start(Owner, OwnerMonitor, Alias, CallbackPid,
                          CallbackMonitor, StartRef) ->
    receive
        {adk_exporter_start, Owner, StartRef} ->
            CallbackPid ! {adk_exporter_start, self(), StartRef},
            exporter_guard_wait_active(
              Owner, OwnerMonitor, Alias, CallbackPid, CallbackMonitor);
        {'DOWN', OwnerMonitor, process, Owner, _} ->
            kill_callback_and_wait(CallbackPid, CallbackMonitor);
        {adk_exporter_cancel, Owner, CancelRef} ->
            kill_callback_and_wait(CallbackPid, CallbackMonitor),
            Owner ! {adk_exporter_cancelled, CancelRef, self()};
        {'DOWN', CallbackMonitor, process, CallbackPid, _} ->
            exporter_guard_reply(
              Owner, OwnerMonitor, Alias, {error, worker_down});
        {'EXIT', CallbackPid, _} ->
            exporter_guard_wait_start(
              Owner, OwnerMonitor, Alias, CallbackPid,
              CallbackMonitor, StartRef)
    end.

exporter_guard_wait_active(Owner, OwnerMonitor, Alias, CallbackPid,
                           CallbackMonitor) ->
    receive
        {adk_exporter_callback, CallbackPid, Result} ->
            CallbackPid ! {adk_exporter_callback_ack, self()},
            erlang:demonitor(CallbackMonitor, [flush]),
            exporter_guard_reply(Owner, OwnerMonitor, Alias, Result);
        {'DOWN', OwnerMonitor, process, Owner, _} ->
            kill_callback_and_wait(CallbackPid, CallbackMonitor);
        {adk_exporter_cancel, Owner, CancelRef} ->
            kill_callback_and_wait(CallbackPid, CallbackMonitor),
            Owner ! {adk_exporter_cancelled, CancelRef, self()};
        {'DOWN', CallbackMonitor, process, CallbackPid, _} ->
            Result = receive
                {adk_exporter_callback, CallbackPid, CompletedResult} ->
                    CompletedResult
            after 0 -> {error, worker_down}
            end,
            exporter_guard_reply(Owner, OwnerMonitor, Alias, Result)
    end.

exporter_guard_reply(Owner, OwnerMonitor, Alias, Result) ->
    Alias ! {adk_exporter_reply, Alias, self(), Result},
    receive
        {adk_exporter_reply_ack, Owner} ->
            erlang:demonitor(OwnerMonitor, [flush]);
        {'DOWN', OwnerMonitor, process, Owner, _} ->
            ok;
        {adk_exporter_cancel, Owner, CancelRef} ->
            Owner ! {adk_exporter_cancelled, CancelRef, self()}
    end.

run_exporter_callback(Module, Envelope, Config) ->
    try Module:export(Envelope, Config) of
        ok -> ok;
        {error, Reason} -> {error, exporter_failure(Reason)};
        _ -> {error, invalid_result}
    catch
        _:_ -> {error, exception}
    end.

cancel_exporter(Guard, Monitor, CallbackPid) ->
    %% CallbackPid is always known before user code starts. The direct kill is
    %% untrappable even when exporter code changed trap_exit itself.
    kill_exporter_callback(CallbackPid),
    CancelRef = make_ref(),
    Guard ! {adk_exporter_cancel, self(), CancelRef},
    receive
        {adk_exporter_cancelled, CancelRef, Guard} ->
            receive {'DOWN', Monitor, process, Guard, _} -> ok
            after 100 ->
                exit(Guard, kill),
                wait_guard_down(Monitor, Guard)
            end;
        {'DOWN', Monitor, process, Guard, _} -> ok
    after 100 ->
        %% Before the ready handshake CallbackPid is undefined and user code
        %% cannot have started; its non-trapping bootstrap remains linked to
        %% the guard. After ready, the active callback was killed directly.
        exit(Guard, kill),
        wait_guard_down(Monitor, Guard)
    end.

wait_guard_down(Monitor, Guard) ->
    receive {'DOWN', Monitor, process, Guard, _} -> ok
    after 100 -> erlang:demonitor(Monitor, [flush])
    end.

kill_callback_and_wait(CallbackPid, CallbackMonitor) ->
    exit(CallbackPid, kill),
    receive
        {'DOWN', CallbackMonitor, process, CallbackPid, _} -> ok
    after 100 -> erlang:demonitor(CallbackMonitor, [flush])
    end.

kill_exporter_callback(undefined) -> ok;
kill_exporter_callback(CallbackPid) when is_pid(CallbackPid) ->
    exit(CallbackPid, kill),
    ok.

flush_export_messages(Alias, Guard) ->
    receive
        {adk_exporter_ready, Alias, Guard, CallbackPid, _StartRef} ->
            kill_exporter_callback(CallbackPid),
            flush_export_messages(Alias, Guard);
        {adk_exporter_reply, Alias, Guard, _} ->
            flush_export_messages(Alias, Guard)
    after 0 -> ok
    end.

export_remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

exporter_status(Exporter, ok) ->
    #{<<"exporter_id">> => maps:get(id, Exporter),
      <<"status">> => <<"ok">>};
exporter_status(Exporter, {error, Failure}) ->
    Base = #{<<"exporter_id">> => maps:get(id, Exporter),
             <<"status">> => <<"error">>,
             <<"reason">> => atom_to_binary(reason_tag(Failure), utf8)},
    case Failure of
        #{retryable := Retryable} when is_boolean(Retryable) ->
            Base#{<<"retryable">> => Retryable};
        _ -> Base
    end.

%% Exporter error terms are untrusted and can contain endpoint credentials or
%% response bodies.  Preserve only the boolean delivery hint used by the
%% supervised bus; every other detail is collapsed to a public atom.
exporter_failure({_Tag, #{retryable := Retryable}})
  when is_boolean(Retryable) ->
    #{reason => exporter_error, retryable => Retryable};
exporter_failure(#{retryable := Retryable}) when is_boolean(Retryable) ->
    #{reason => exporter_error, retryable => Retryable};
exporter_failure(_Reason) -> exporter_error.

reason_tag({Tag, _}) when is_atom(Tag) -> Tag;
reason_tag({Tag, _, _}) when is_atom(Tag) -> Tag;
reason_tag(#{reason := Tag}) when is_atom(Tag) -> Tag;
reason_tag(Tag) when is_atom(Tag) -> Tag;
reason_tag(_) -> invalid_reason.
