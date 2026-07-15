%% @doc Versioned SDK-neutral operation span signal.
%%
%% Signals use Unix nanoseconds for export and monotonic native time for
%% duration.  The returned handle is runtime-only and must not be persisted or
%% exposed to plugins/tools.  Attribute limits are enforced before an exporter
%% or telemetry handler receives the signal.
-module(adk_observability_signal).

-export([schema_version/0, start_span/4, finish_span/3, validate/1]).

-define(VERSION, 2).
-define(MAX_ATTRIBUTES, 64).
-define(MAX_ATTRIBUTE_KEY_BYTES, 128).
-define(MAX_ATTRIBUTES_BYTES, 65536).
-define(MAX_NAME_BYTES, 128).

-type span_handle() :: map().
-export_type([span_handle/0]).

schema_version() -> ?VERSION.

-spec start_span(binary(), atom() | binary(), map(), map()) ->
    {ok, span_handle(), map()} | {error, term()}.
start_span(Name, Kind0, Context, Attributes0)
  when is_binary(Name), is_map(Context), is_map(Attributes0) ->
    case {valid_name(Name), normalize_kind(Kind0),
          correlation(Context), bounded_attributes(Attributes0)} of
        {true, {ok, Kind}, {ok, Correlation}, {ok, Attributes}} ->
            StartUnix = erlang:system_time(nanosecond),
            StartMono = erlang:monotonic_time(),
            Signal = Correlation#{
              <<"schema_version">> => ?VERSION,
              <<"signal">> => <<"span">>,
              <<"phase">> => <<"start">>,
              <<"name">> => Name,
              <<"kind">> => Kind,
              <<"start_time_unix_nano">> => StartUnix,
              <<"attributes">> => Attributes},
            Handle = #{schema_version => ?VERSION, name => Name,
                       kind => Kind, context => Context,
                       start_unix_nano => StartUnix,
                       start_monotonic => StartMono,
                       attributes => Attributes},
            {ok, Handle, Signal};
        {false, _, _, _} -> {error, invalid_span_name};
        {_, {error, _} = Error, _, _} -> Error;
        {_, _, {error, _} = Error, _} -> Error;
        {_, _, _, {error, _} = Error} -> Error
    end;
start_span(_, _, _, _) -> {error, invalid_span_start}.

-spec finish_span(span_handle(), term(), map()) ->
    {ok, map()} | {error, term()}.
finish_span(#{schema_version := ?VERSION, name := Name, kind := Kind,
              context := Context, start_unix_nano := StartUnix,
              start_monotonic := StartMono,
              attributes := StartAttributes}, Status0, EndAttributes0)
  when is_map(Context), is_map(StartAttributes), is_map(EndAttributes0) ->
    case {normalize_status(Status0), bounded_attributes(EndAttributes0),
          correlation(Context)} of
        {{ok, Status, StatusAttributes}, {ok, EndAttributes},
         {ok, Correlation}} ->
            EndUnix0 = erlang:system_time(nanosecond),
            EndUnix = erlang:max(StartUnix, EndUnix0),
            Duration = erlang:convert_time_unit(
                         erlang:monotonic_time() - StartMono,
                         native, nanosecond),
            Attributes0 = maps:merge(StartAttributes, EndAttributes),
            case bounded_attributes(
                   maps:merge(Attributes0, StatusAttributes)) of
                {ok, Attributes} ->
                    Signal = Correlation#{
                      <<"schema_version">> => ?VERSION,
                      <<"signal">> => <<"span">>,
                      <<"phase">> => <<"end">>,
                      <<"name">> => Name,
                      <<"kind">> => Kind,
                      <<"status">> => Status,
                      <<"start_time_unix_nano">> => StartUnix,
                      <<"end_time_unix_nano">> => EndUnix,
                      <<"duration_nano">> => erlang:max(0, Duration),
                      <<"attributes">> => Attributes},
                    {ok, Signal};
                {error, _} = Error -> Error
            end;
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end;
finish_span(_, _, _) -> {error, invalid_span_handle}.

-spec validate(map()) -> {ok, map()} | {error, term()}.
validate(#{<<"schema_version">> := ?VERSION,
           <<"signal">> := <<"span">>,
           <<"phase">> := Phase,
           <<"name">> := Name,
           <<"kind">> := Kind,
           <<"start_time_unix_nano">> := Start,
           <<"attributes">> := Attributes} = Signal)
  when (Phase =:= <<"start">> orelse Phase =:= <<"end">>),
       is_integer(Start), Start >= 0 ->
    Context = #{trace_id => maps:get(<<"trace_id">>, Signal, undefined),
                span_id => maps:get(<<"span_id">>, Signal, undefined),
                parent_id => maps:get(<<"parent_span_id">>, Signal, null),
                trace_flags => maps:get(<<"trace_flags">>, Signal, 0),
                tracestate => maps:get(<<"tracestate">>, Signal, null)},
    case {valid_name(Name), normalize_kind(Kind), correlation(Context),
          bounded_attributes(Attributes), validate_phase(Phase, Signal)} of
        {true, {ok, _}, {ok, _}, {ok, _}, ok} ->
            case sanitize_signal(Signal) of
                {ok, Signal} -> {ok, Signal};
                {ok, _Changed} -> {error, signal_not_canonical};
                {error, _} -> {error, invalid_observability_signal}
            end;
        _ -> {error, invalid_observability_signal}
    end;
validate(#{<<"schema_version">> := Version}) when Version =/= ?VERSION ->
    {error, {unsupported_observability_schema_version, Version}};
validate(_) -> {error, invalid_observability_signal}.

validate_phase(<<"start">>, Signal) ->
    case maps:is_key(<<"end_time_unix_nano">>, Signal) orelse
         maps:is_key(<<"duration_nano">>, Signal) orelse
         maps:is_key(<<"status">>, Signal) of
        true -> {error, invalid_start_signal};
        false -> ok
    end;
validate_phase(<<"end">>, Signal) ->
    Start = maps:get(<<"start_time_unix_nano">>, Signal),
    case {maps:get(<<"end_time_unix_nano">>, Signal, invalid),
          maps:get(<<"duration_nano">>, Signal, invalid),
          maps:get(<<"status">>, Signal, invalid)} of
        {End, Duration, Status}
          when is_integer(End), End >= Start,
               is_integer(Duration), Duration >= 0,
               (Status =:= <<"ok">> orelse Status =:= <<"error">> orelse
                Status =:= <<"unset">>) -> ok;
        _ -> {error, invalid_end_signal}
    end.

correlation(Context) ->
    TraceId = get_either(Context, trace_id, <<"trace_id">>, undefined),
    SpanId = get_either(Context, span_id, <<"span_id">>, undefined),
    Parent = get_either(Context, parent_id, <<"parent_id">>, null),
    Flags = get_either(Context, trace_flags, <<"trace_flags">>, 0),
    Tracestate0 = get_either(Context, tracestate, <<"tracestate">>, null),
    ParentValid = Parent =:= null orelse
                  adk_trace_context:validate_span_id(Parent) =:= ok,
    case {adk_trace_context:validate_trace_id(TraceId),
          adk_trace_context:validate_span_id(SpanId), ParentValid,
          is_integer(Flags) andalso Flags >= 0 andalso Flags =< 255,
          adk_trace_context:validate_tracestate(Tracestate0)} of
        {ok, ok, true, true, {ok, Tracestate}} ->
            Base = #{<<"trace_id">> => TraceId,
                     <<"span_id">> => SpanId,
                     <<"parent_span_id">> => Parent,
                     <<"trace_flags">> => Flags},
            case Tracestate of
                null -> {ok, Base};
                _ -> {ok, Base#{<<"tracestate">> => Tracestate}}
            end;
        _ -> {error, invalid_span_correlation}
    end.

bounded_attributes(Attributes0) when is_map(Attributes0),
                                    map_size(Attributes0) =< ?MAX_ATTRIBUTES ->
    case sanitize_attributes(Attributes0) of
        {ok, Attributes} when is_map(Attributes),
                              map_size(Attributes) =< ?MAX_ATTRIBUTES ->
            KeysValid = lists:all(
                          fun(Key) ->
                              is_binary(Key) andalso byte_size(Key) > 0 andalso
                              byte_size(Key) =< ?MAX_ATTRIBUTE_KEY_BYTES
                          end, maps:keys(Attributes)),
            Size = try erlang:external_size(Attributes)
                   catch _:_ -> ?MAX_ATTRIBUTES_BYTES + 1
                   end,
            case KeysValid andalso Size =< ?MAX_ATTRIBUTES_BYTES of
                true -> {ok, Attributes};
                false -> {error, invalid_span_attributes}
            end;
        _ -> {error, invalid_span_attributes}
    end;
bounded_attributes(_) -> {error, invalid_span_attributes}.

%% Generic context data treats every token-shaped key as a credential.  These
%% four exact GenAI fields are safe only at the observability signal boundary,
%% and only when their values are numeric counters.  Keeping the exception
%% here prevents a caller from disguising a secret string as a usage field in
%% ordinary agent/session context.
sanitize_attributes(Attributes0) ->
    UsageKeys = usage_attribute_keys(),
    Usage = maps:with(UsageKeys, Attributes0),
    case lists:all(fun({_Key, Value}) ->
                           is_integer(Value) andalso Value >= 0
                   end, maps:to_list(Usage)) of
        false -> {error, invalid_usage_attributes};
        true ->
            case adk_context_guard:sanitize_value(
                   maps:without(UsageKeys, Attributes0)) of
                {ok, Safe} when is_map(Safe) ->
                    {ok, maps:merge(Safe, Usage)};
                {error, _} = Error -> Error;
                _ -> {error, invalid_span_attributes}
            end
    end.

sanitize_signal(#{<<"attributes">> := Attributes0} = Signal) ->
    case sanitize_attributes(Attributes0) of
        {ok, Attributes} ->
            UsageKeys = usage_attribute_keys(),
            Usage = maps:with(UsageKeys, Attributes),
            WithoutUsage = maps:without(UsageKeys, Attributes),
            case adk_context_guard:sanitize_value(
                   Signal#{<<"attributes">> => WithoutUsage}) of
                {ok, SafeSignal} when is_map(SafeSignal) ->
                    SafeAttributes = maps:get(<<"attributes">>, SafeSignal),
                    {ok, SafeSignal#{<<"attributes">> =>
                                          maps:merge(SafeAttributes, Usage)}};
                Other -> Other
            end;
        {error, _} = Error -> Error
    end.

usage_attribute_keys() ->
    [<<"gen_ai.usage.input_tokens">>,
     <<"gen_ai.usage.output_tokens">>,
     <<"gen_ai.usage.cache_read.input_tokens">>,
     <<"gen_ai.usage.reasoning_tokens">>].

normalize_kind(internal) -> {ok, <<"internal">>};
normalize_kind(client) -> {ok, <<"client">>};
normalize_kind(server) -> {ok, <<"server">>};
normalize_kind(producer) -> {ok, <<"producer">>};
normalize_kind(consumer) -> {ok, <<"consumer">>};
normalize_kind(Value) when Value =:= <<"internal">>;
                           Value =:= <<"client">>;
                           Value =:= <<"server">>;
                           Value =:= <<"producer">>;
                           Value =:= <<"consumer">> -> {ok, Value};
normalize_kind(_) -> {error, invalid_span_kind}.

normalize_status(ok) -> {ok, <<"ok">>, #{}};
normalize_status(unset) -> {ok, <<"unset">>, #{}};
normalize_status(error) ->
    {ok, <<"error">>, #{<<"error.type">> => <<"unknown">>}};
normalize_status({error, Type}) when is_atom(Type) ->
    normalize_status({error, atom_to_binary(Type, utf8)});
normalize_status({error, Type}) when is_binary(Type), byte_size(Type) > 0,
                                     byte_size(Type) =< 256 ->
    {ok, <<"error">>, #{<<"error.type">> => Type}};
normalize_status(_) -> {error, invalid_span_status}.

valid_name(Name) ->
    byte_size(Name) > 0 andalso byte_size(Name) =< ?MAX_NAME_BYTES andalso
    case unicode:characters_to_binary(Name, utf8, utf8) of
        Name -> true;
        _ -> false
    end.

get_either(Map, AtomKey, BinaryKey, Default) ->
    case maps:find(AtomKey, Map) of
        {ok, Value} -> Value;
        error -> maps:get(BinaryKey, Map, Default)
    end.
