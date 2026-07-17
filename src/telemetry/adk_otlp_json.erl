%% @doc Strict, dependency-light OTLP/HTTP JSON projection.
%%
%% Completed v2 operation spans are mapped to ExportTraceServiceRequest and
%% metadata-only v1 envelopes are mapped to ExportLogsServiceRequest.  The
%% mapper follows the OTLP JSON deviations from proto3 JSON: trace/span IDs
%% remain hexadecimal, enum values are numbers, and every int64 value is a
%% decimal string.  It never maps prompt/response/media/tool payload content.
-module(adk_otlp_json).

-export([to_request/1, any_value/1, mapping_version/0]).

-define(MAPPING_VERSION, <<"otlp-json-1.10-erlang-adk-0.8">>).
-define(SCOPE_NAME, <<"erlang_adk">>).
-define(SCOPE_VERSION, <<"0.8.0">>).
-define(MAX_VALUE_DEPTH, 8).
-define(MAX_COLLECTION_ITEMS, 64).
-define(MAX_STRING_BYTES, 16384).
-define(MAX_KEY_BYTES, 128).
-define(INT64_MIN, -9223372036854775808).
-define(INT64_MAX, 9223372036854775807).

-spec mapping_version() -> binary().
mapping_version() -> ?MAPPING_VERSION.

-spec to_request(map()) ->
    {ok, traces | logs, map()} | {skip, term()} | {error, term()}.
to_request(#{<<"schema_version">> := 2,
             <<"signal">> := <<"span">>,
             <<"phase">> := <<"start">>}) ->
    %% OTLP exports completed spans.  The v2 signal stream also contains a
    %% local start notification, which must not be retried as bad telemetry.
    {skip, incomplete_span};
to_request(#{<<"schema_version">> := 2} = Signal0) ->
    case adk_observability_signal:validate(Signal0) of
        {ok, #{<<"phase">> := <<"end">>} = Signal} ->
            trace_request(Signal);
        {ok, _} -> {skip, incomplete_span};
        {error, _} -> {error, invalid_otlp_span_signal}
    end;
to_request(#{<<"schema_version">> := 1} = Envelope0) ->
    case adk_observability:encode(Envelope0) of
        {ok, Envelope} -> log_request(Envelope);
        {error, _} -> {error, invalid_otlp_log_envelope}
    end;
to_request(#{<<"schema_version">> := Version}) ->
    {error, {unsupported_otlp_source_schema, Version}};
to_request(_) ->
    {error, invalid_otlp_source}.

-spec any_value(term()) -> {ok, map()} | {error, term()}.
any_value(Value) ->
    any_value(Value, 0).

trace_request(Signal) ->
    Attributes0 = maps:get(<<"attributes">>, Signal),
    case {otlp_time(maps:get(<<"start_time_unix_nano">>, Signal)),
          otlp_time(maps:get(<<"end_time_unix_nano">>, Signal)),
          key_values(Attributes0, 0)} of
        {{ok, StartTime}, {ok, EndTime}, {ok, Attributes}} ->
            Span0 = #{
              <<"traceId">> => maps:get(<<"trace_id">>, Signal),
              <<"spanId">> => maps:get(<<"span_id">>, Signal),
              <<"name">> => maps:get(<<"name">>, Signal),
              <<"kind">> => span_kind(maps:get(<<"kind">>, Signal)),
              <<"startTimeUnixNano">> => StartTime,
              <<"endTimeUnixNano">> => EndTime,
              <<"attributes">> => Attributes,
              <<"flags">> => maps:get(<<"trace_flags">>, Signal),
              <<"status">> =>
                  #{<<"code">> => span_status(
                                      maps:get(<<"status">>, Signal))}},
            Span1 = optional_binary_field(
                      <<"parentSpanId">>,
                      maps:get(<<"parent_span_id">>, Signal, null), Span0),
            Span = optional_binary_field(
                     <<"traceState">>,
                     maps:get(<<"tracestate">>, Signal, null), Span1),
            {ok, traces, trace_payload(Span)};
        {_, _, {error, _} = Error} -> Error;
        _ -> {error, invalid_otlp_timestamp}
    end.

log_request(Envelope) ->
    case {maps:get(<<"content_captured">>, Envelope, false),
          maps:is_key(<<"content">>, Envelope)} of
        {false, false} -> metadata_log_request(Envelope);
        _ -> {error, content_bearing_envelope_not_exportable}
    end.

metadata_log_request(Envelope) ->
    Event = maps:get(<<"event">>, Envelope),
    Timestamp = maps:get(<<"timestamp_ms">>, Envelope),
    Measurements = maps:get(<<"measurements">>, Envelope),
    Metadata0 = maps:get(<<"metadata">>, Envelope),
    ContextKeys = [<<"trace_id">>, <<"span_id">>, <<"trace_flags">>],
    MetadataKeys = [<<"run_id">>, <<"invocation_id">>, <<"session">>,
                    <<"agent">>, <<"model">>, <<"tool">>, <<"call_id">>,
                    <<"parent_id">>, <<"tracestate">>],
    Metadata = maps:with(MetadataKeys,
                         maps:without(ContextKeys, Metadata0)),
    Attributes0 = maps:merge(
                    prefixed(<<"erlang_adk.measurement.">>, Measurements),
                    prefixed(<<"erlang_adk.metadata.">>, Metadata)),
    Attributes1 = Attributes0#{<<"erlang_adk.content_captured">> => false},
    case {safe_measurements(Measurements), log_time(Timestamp),
          key_values(Attributes1, 0)} of
        {true, {ok, TimeNano}, {ok, Attributes}} ->
            Record0 = #{<<"timeUnixNano">> => TimeNano,
                        <<"observedTimeUnixNano">> => TimeNano,
                        <<"severityNumber">> => 0,
                        <<"body">> => #{<<"stringValue">> => Event},
                        <<"attributes">> => Attributes},
            Record = add_log_correlation(Metadata0, Record0),
            {ok, logs, log_payload(Record)};
        {_, _, {error, _} = Error} -> Error;
        _ -> {error, invalid_otlp_log_metadata}
    end.

trace_payload(Span) ->
    #{<<"resourceSpans">> =>
          [#{<<"resource">> => resource(),
             <<"scopeSpans">> =>
                 [#{<<"scope">> => scope(), <<"spans">> => [Span]}]}]}.

log_payload(Record) ->
    #{<<"resourceLogs">> =>
          [#{<<"resource">> => resource(),
             <<"scopeLogs">> =>
                 [#{<<"scope">> => scope(),
                    <<"logRecords">> => [Record]}]}]}.

resource() ->
    {ok, Attributes} = key_values(
                         #{<<"service.name">> => <<"erlang_adk">>,
                           <<"service.version">> => ?SCOPE_VERSION,
                           <<"telemetry.sdk.language">> => <<"erlang">>,
                           <<"erlang_adk.otlp.mapping.version">> =>
                               ?MAPPING_VERSION}, 0),
    #{<<"attributes">> => Attributes}.

scope() ->
    #{<<"name">> => ?SCOPE_NAME, <<"version">> => ?SCOPE_VERSION}.

add_log_correlation(Metadata, Record0) ->
    TraceId = maps:get(<<"trace_id">>, Metadata, undefined),
    SpanId = maps:get(<<"span_id">>, Metadata, undefined),
    Record1 = case {adk_trace_context:validate_trace_id(TraceId),
                    adk_trace_context:validate_span_id(SpanId)} of
        {ok, ok} -> Record0#{<<"traceId">> => TraceId,
                            <<"spanId">> => SpanId};
        _ -> Record0
    end,
    case maps:get(<<"trace_flags">>, Metadata, undefined) of
        Flags when is_integer(Flags), Flags >= 0, Flags =< 255 ->
            Record1#{<<"flags">> => Flags};
        _ -> Record1
    end.

prefixed(Prefix, Map) when is_map(Map) ->
    maps:from_list(
      [{<<Prefix/binary, Key/binary>>, Value}
       || {Key, Value} <- maps:to_list(Map), is_binary(Key)]).

key_values(Map, Depth)
  when is_map(Map), map_size(Map) =< ?MAX_COLLECTION_ITEMS,
       Depth =< ?MAX_VALUE_DEPTH ->
    key_values(lists:sort(maps:to_list(Map)), Depth, []);
key_values(_, _) ->
    {error, invalid_otlp_attributes}.

key_values([], _Depth, Acc) ->
    {ok, lists:reverse(Acc)};
key_values([{Key, Value} | Rest], Depth, Acc) ->
    case valid_attribute(Key, Value) of
        false -> {error, forbidden_otlp_attribute};
        true ->
            case any_value(Value, Depth + 1) of
                {ok, Encoded} ->
                    Entry = #{<<"key">> => Key, <<"value">> => Encoded},
                    key_values(Rest, Depth, [Entry | Acc]);
                {error, _} = Error -> Error
            end
    end.

any_value(_Value, Depth) when Depth > ?MAX_VALUE_DEPTH ->
    {error, otlp_attribute_depth_exceeded};
any_value(Value, _Depth)
  when is_binary(Value), byte_size(Value) =< ?MAX_STRING_BYTES ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> {ok, #{<<"stringValue">> => Value}};
        _ -> {error, invalid_otlp_string_attribute}
    end;
any_value(Value, _Depth)
  when is_integer(Value), Value >= ?INT64_MIN, Value =< ?INT64_MAX ->
    {ok, #{<<"intValue">> => integer_to_binary(Value)}};
any_value(Value, _Depth) when is_float(Value) ->
    case finite_float(Value) of
        true -> {ok, #{<<"doubleValue">> => Value}};
        false -> {error, invalid_otlp_float_attribute}
    end;
any_value(Value, _Depth) when is_boolean(Value) ->
    {ok, #{<<"boolValue">> => Value}};
any_value(Values, Depth)
  when is_list(Values), length(Values) =< ?MAX_COLLECTION_ITEMS ->
    case any_values(Values, Depth + 1, []) of
        {ok, Encoded} ->
            {ok, #{<<"arrayValue">> =>
                       #{<<"values">> => Encoded}}};
        {error, _} = Error -> Error
    end;
any_value(Map, Depth) when is_map(Map) ->
    case key_values(Map, Depth + 1) of
        {ok, Values} ->
            {ok, #{<<"kvlistValue">> => #{<<"values">> => Values}}};
        {error, _} = Error -> Error
    end;
any_value(_, _) ->
    {error, invalid_otlp_attribute_value}.

any_values([], _Depth, Acc) -> {ok, lists:reverse(Acc)};
any_values([Value | Rest], Depth, Acc) ->
    case any_value(Value, Depth) of
        {ok, Encoded} -> any_values(Rest, Depth, [Encoded | Acc]);
        {error, _} = Error -> Error
    end.

valid_attribute_key(Key)
  when is_binary(Key), byte_size(Key) > 0,
       byte_size(Key) =< ?MAX_KEY_BYTES ->
    case unicode:characters_to_binary(Key, utf8, utf8) of
        Key -> not forbidden_attribute_key(Key);
        _ -> false
    end;
valid_attribute_key(_) -> false.

valid_attribute(Key, Value) ->
    case lists:member(Key, usage_attribute_keys()) of
        true -> is_integer(Value) andalso Value >= 0;
        false -> valid_attribute_key(Key)
    end.

usage_attribute_keys() ->
    [<<"gen_ai.usage.input_tokens">>,
     <<"gen_ai.usage.output_tokens">>,
     <<"gen_ai.usage.cache_read.input_tokens">>,
     <<"gen_ai.usage.reasoning_tokens">>].

forbidden_attribute_key(Key) ->
    adk_context_guard:sensitive_key(Key) orelse
    content_key(normalized_key(Key), forbidden_content_keys()).

content_key(_Key, []) -> false;
content_key(Key, [Forbidden | Rest]) ->
    Key =:= Forbidden orelse binary_suffix(Key, Forbidden) orelse
    content_key(Key, Rest).

binary_suffix(Value, Suffix) when byte_size(Value) >= byte_size(Suffix) ->
    Offset = byte_size(Value) - byte_size(Suffix),
    binary:part(Value, Offset, byte_size(Suffix)) =:= Suffix;
binary_suffix(_, _) -> false.

normalized_key(Key) ->
    Lower = string:lowercase(Key),
    lists:foldl(
      fun(Separator, Acc) ->
          binary:replace(Acc, Separator, <<>>, [global])
      end, Lower, [<<"_">>, <<"-">>, <<" ">>, <<".">>, <<":">>]).

forbidden_content_keys() ->
    [<<"content">>, <<"contents">>, <<"prompt">>, <<"prompts">>,
     <<"message">>, <<"messages">>, <<"text">>, <<"audio">>,
     <<"video">>, <<"image">>, <<"media">>, <<"transcript">>,
     <<"transcription">>, <<"inputmessages">>, <<"outputmessages">>,
     <<"toolarguments">>, <<"toolargs">>, <<"toolresult">>,
     <<"toolresponse">>, <<"reasoning">>, <<"reasoningtrace">>,
     <<"systeminstruction">>, <<"systeminstructions">>].

span_kind(<<"internal">>) -> 1;
span_kind(<<"server">>) -> 2;
span_kind(<<"client">>) -> 3;
span_kind(<<"producer">>) -> 4;
span_kind(<<"consumer">>) -> 5.

span_status(<<"unset">>) -> 0;
span_status(<<"ok">>) -> 1;
span_status(<<"error">>) -> 2.

otlp_time(Value)
  when is_integer(Value), Value >= 0, Value =< ?INT64_MAX ->
    {ok, integer_to_binary(Value)};
otlp_time(_) -> error.

log_time(Value)
  when is_integer(Value), Value >= 0,
       Value =< (?INT64_MAX div 1000000) ->
    otlp_time(Value * 1000000);
log_time(_) -> error.

safe_measurements(Map) when is_map(Map) ->
    lists:all(
      fun({Key, Value}) ->
          valid_attribute_key(Key) andalso scalar_measurement(Value)
      end, maps:to_list(Map)).

scalar_measurement(Value) when is_integer(Value) -> true;
scalar_measurement(Value) when is_float(Value) -> finite_float(Value);
scalar_measurement(Value) when is_boolean(Value) -> true;
scalar_measurement(_) -> false.

optional_binary_field(_Key, null, Map) -> Map;
optional_binary_field(Key, Value, Map) when is_binary(Value) ->
    Map#{Key => Value}.

finite_float(Value) ->
    try
        Encoded = float_to_binary(Value, [short]),
        Encoded =/= <<"nan">> andalso Encoded =/= <<"inf">> andalso
        Encoded =/= <<"-inf">>
    catch
        _:_ -> false
    end.
