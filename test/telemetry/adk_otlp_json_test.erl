-module(adk_otlp_json_test).
-include_lib("eunit/include/eunit.hrl").

-export([span/0, log_envelope/0]).

completed_span_is_strict_otlp_json_test() ->
    {ok, traces, Request} = adk_otlp_json:to_request(span()),
    Span = only_span(Request),
    ?assertEqual(<<"0123456789abcdef0123456789abcdef">>,
                 maps:get(<<"traceId">>, Span)),
    ?assertEqual(<<"0123456789abcdef">>, maps:get(<<"spanId">>, Span)),
    ?assertEqual(<<"fedcba9876543210">>,
                 maps:get(<<"parentSpanId">>, Span)),
    ?assertEqual(<<"vendor=value">>, maps:get(<<"traceState">>, Span)),
    ?assertEqual(3, maps:get(<<"kind">>, Span)),
    ?assertEqual(1, maps:get(<<"flags">>, Span)),
    ?assertEqual(<<"1770000000000000000">>,
                 maps:get(<<"startTimeUnixNano">>, Span)),
    ?assertEqual(<<"1770000000001000000">>,
                 maps:get(<<"endTimeUnixNano">>, Span)),
    ?assertEqual(1, maps:get(<<"code">>, maps:get(<<"status">>, Span))),
    Attributes = attributes_map(maps:get(<<"attributes">>, Span)),
    ?assertEqual(#{<<"stringValue">> => <<"google">>},
                 maps:get(<<"gen_ai.provider.name">>, Attributes)),
    ?assertEqual(#{<<"intValue">> => <<"17">>},
                 maps:get(<<"gen_ai.usage.input_tokens">>, Attributes)),
    #{<<"arrayValue">> := #{<<"values">> := Reasons}} =
        maps:get(<<"gen_ai.response.finish_reasons">>, Attributes),
    ?assertEqual([#{<<"stringValue">> => <<"STOP">>}], Reasons),
    %% OTLP's JSON deviations survive actual JSON encoding.
    Decoded = jsx:decode(jsx:encode(Request), [return_maps]),
    EncodedSpan = only_span(Decoded),
    ?assert(is_integer(maps:get(<<"kind">>, EncodedSpan))),
    ?assert(is_binary(maps:get(<<"startTimeUnixNano">>, EncodedSpan))).

typed_any_values_are_deterministic_test() ->
    {ok, #{<<"boolValue">> := true}} = adk_otlp_json:any_value(true),
    {ok, #{<<"doubleValue">> := 1.5}} = adk_otlp_json:any_value(1.5),
    {ok, #{<<"kvlistValue">> := #{<<"values">> := Values}}} =
        adk_otlp_json:any_value(#{<<"z">> => 2, <<"a">> => false}),
    ?assertEqual([<<"a">>, <<"z">>],
                 [maps:get(<<"key">>, Entry) || Entry <- Values]),
    ?assertMatch({error, _}, adk_otlp_json:any_value(null)).

semantic_usage_counts_survive_secret_pruning_test() ->
    {ok, Context} = adk_observability:new_context(#{}),
    {ok, Handle} = adk_observability:start_span(
                     generate_content, client, Context,
                     #{provider => <<"google">>},
                     #{delivery => sync, exporters => []}),
    {ok, Signal} = adk_observability:finish_span(
                     Handle, ok,
                     #{input_tokens => 11, output_tokens => 7,
                       cached_input_tokens => 3, reasoning_tokens => 2}),
    Attributes = maps:get(<<"attributes">>, Signal),
    ?assertEqual(11, maps:get(<<"gen_ai.usage.input_tokens">>, Attributes)),
    ?assertEqual(7, maps:get(<<"gen_ai.usage.output_tokens">>, Attributes)),
    {ok, traces, Request} = adk_otlp_json:to_request(Signal),
    Mapped = attributes_map(maps:get(<<"attributes">>, only_span(Request))),
    ?assertEqual(#{<<"intValue">> => <<"3">>},
                 maps:get(<<"gen_ai.usage.cache_read.input_tokens">>, Mapped)),
    UsageKey = <<"gen_ai.usage.input_tokens">>,
    {ok, GenericContext} = adk_context_guard:sanitize_value(
                             #{UsageKey => <<"secret disguised as count">>}),
    ?assertNot(maps:is_key(UsageKey, GenericContext)),
    Forged = (span())#{<<"attributes">> =>
                          #{UsageKey => <<"secret disguised as count">>}},
    ?assertEqual({error, invalid_otlp_span_signal},
                 adk_otlp_json:to_request(Forged)).

start_span_is_not_exported_test() ->
    Start = maps:without([<<"status">>, <<"end_time_unix_nano">>,
                          <<"duration_nano">>],
                         (span())#{<<"phase">> => <<"start">>}),
    ?assertEqual({skip, incomplete_span}, adk_otlp_json:to_request(Start)).

content_and_credentials_are_rejected_test() ->
    Prompt = (span())#{<<"attributes">> =>
                         #{<<"prompt">> => <<"private prompt">>}},
    ?assertEqual({error, forbidden_otlp_attribute},
                 adk_otlp_json:to_request(Prompt)),
    Credential = (span())#{<<"attributes">> =>
                             #{<<"api_key">> => <<"must-not-leak">>}},
    ?assertEqual({error, invalid_otlp_span_signal},
                 adk_otlp_json:to_request(Credential)),
    ?assertEqual(nomatch,
                 binary:match(jsx:encode(element(2,
                   adk_otlp_json:any_value(<<"ordinary metadata">>))),
                              <<"must-not-leak">>)).

metadata_envelope_maps_to_log_request_test() ->
    Envelope = log_envelope(),
    {ok, logs, Request} = adk_otlp_json:to_request(Envelope),
    Record = only_log(Request),
    ?assertEqual(0, maps:get(<<"severityNumber">>, Record)),
    ?assertEqual(<<"1770000000123000000">>,
                 maps:get(<<"timeUnixNano">>, Record)),
    ?assertEqual(#{<<"stringValue">> => <<"erlang_adk.run.stop">>},
                 maps:get(<<"body">>, Record)),
    ?assertEqual(<<"0123456789abcdef0123456789abcdef">>,
                 maps:get(<<"traceId">>, Record)),
    ?assertEqual(<<"0123456789abcdef">>, maps:get(<<"spanId">>, Record)),
    ?assertEqual(1, maps:get(<<"flags">>, Record)),
    Attrs = attributes_map(maps:get(<<"attributes">>, Record)),
    ?assertEqual(#{<<"intValue">> => <<"12">>},
                 maps:get(<<"erlang_adk.measurement.duration_ms">>, Attrs)).

captured_v1_content_is_never_mapped_test() ->
    Envelope = (log_envelope())#{<<"content_captured">> => true,
                                 <<"content">> =>
                                     #{<<"input">> => <<"private">>}},
    ?assertEqual({error, content_bearing_envelope_not_exportable},
                 adk_otlp_json:to_request(Envelope)).

out_of_range_timestamps_return_errors_test() ->
    TooLarge = (span())#{<<"end_time_unix_nano">> =>
                            9223372036854775808},
    ?assertEqual({error, invalid_otlp_timestamp},
                 adk_otlp_json:to_request(TooLarge)),
    NegativeLog = (log_envelope())#{<<"timestamp_ms">> => -1},
    ?assertEqual({error, invalid_otlp_log_metadata},
                 adk_otlp_json:to_request(NegativeLog)).

span() ->
    #{<<"schema_version">> => 2,
      <<"signal">> => <<"span">>,
      <<"phase">> => <<"end">>,
      <<"name">> => <<"gen_ai.generate_content">>,
      <<"kind">> => <<"client">>,
      <<"trace_id">> => <<"0123456789abcdef0123456789abcdef">>,
      <<"span_id">> => <<"0123456789abcdef">>,
      <<"parent_span_id">> => <<"fedcba9876543210">>,
      <<"trace_flags">> => 1,
      <<"tracestate">> => <<"vendor=value">>,
      <<"start_time_unix_nano">> => 1770000000000000000,
      <<"end_time_unix_nano">> => 1770000000001000000,
      <<"duration_nano">> => 1000000,
      <<"status">> => <<"ok">>,
      <<"attributes">> =>
          #{<<"gen_ai.provider.name">> => <<"google">>,
            <<"gen_ai.usage.input_tokens">> => 17,
            <<"gen_ai.response.finish_reasons">> => [<<"STOP">>]}}.

log_envelope() ->
    #{<<"schema_version">> => 1,
      <<"event">> => <<"erlang_adk.run.stop">>,
      <<"timestamp_ms">> => 1770000000123,
      <<"measurements">> => #{<<"duration_ms">> => 12},
      <<"metadata">> =>
          #{<<"trace_id">> => <<"0123456789abcdef0123456789abcdef">>,
            <<"span_id">> => <<"0123456789abcdef">>,
            <<"trace_flags">> => 1,
            <<"agent">> => <<"writer">>,
            <<"attributes">> => #{}},
      <<"content_captured">> => false}.

only_span(#{<<"resourceSpans">> :=
                [#{<<"scopeSpans">> :=
                       [#{<<"spans">> := [Span]}]}]}) -> Span.

only_log(#{<<"resourceLogs">> :=
               [#{<<"scopeLogs">> :=
                      [#{<<"logRecords">> := [Record]}]}]}) -> Record.

attributes_map(Entries) ->
    maps:from_list([{maps:get(<<"key">>, Entry),
                     maps:get(<<"value">>, Entry)} || Entry <- Entries]).
