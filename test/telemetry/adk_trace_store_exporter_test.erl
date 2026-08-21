-module(adk_trace_store_exporter_test).

-include_lib("eunit/include/eunit.hrl").

-define(PRINCIPAL, <<"exporter-owner">>).
-define(RUN_ID, <<"exporter-run">>).
-define(TRACE_ID, <<"0123456789abcdef0123456789abcdef">>).

strict_config_validation_test() ->
    {ok, Store} = start_store(),
    try
        Config = #{principal => ?PRINCIPAL, server => Store},
        ?assertEqual({ok, Config},
                     adk_trace_store_exporter:validate_config(Config)),
        ?assertEqual(
           {error, invalid_trace_store_exporter_config},
           adk_trace_store_exporter:validate_config(
             Config#{unknown => true})),
        ?assertEqual(
           {error, invalid_trace_store_exporter_config},
           adk_trace_store_exporter:validate_config(
             maps:remove(principal, Config))),
        ?assertEqual(
           {error, invalid_trace_store_exporter_config},
           adk_trace_store_exporter:validate_config(
             Config#{principal => binary:copy(<<"p">>, 257)})),
        ?assertEqual(
           {error, invalid_trace_store_exporter_config},
           adk_trace_store_exporter:validate_config(
             Config#{server => undefined}))
    after
        gen_server:stop(Store)
    end.

exporter_forwards_canonical_envelope_test() ->
    {ok, Store} = start_store(),
    try
        Config = #{principal => ?PRINCIPAL, server => Store},
        Descriptor = #{id => <<"trace-store">>,
                       module => adk_trace_store_exporter,
                       config => Config,
                       failure_policy => closed,
                       timeout_ms => 1000,
                       max_heap_words => 100000},
        {ok, [_Status]} = adk_observability:export(
                            envelope(<<"accepted">>), [Descriptor]),
        {ok, Page} = adk_trace_store:query(
                       Store, ?PRINCIPAL,
                       #{run_id => ?RUN_ID, trace_id => ?TRACE_ID}, #{}),
        [Stored] = maps:get(<<"events">>, Page),
        ?assertEqual(1, maps:get(<<"cursor">>, Stored)),
        ?assertEqual(<<"observability">>, maps:get(<<"kind">>, Stored)),
        ?assertEqual(envelope(<<"accepted">>),
                     maps:get(<<"event">>, Stored))
    after
        gen_server:stop(Store)
    end.

malformed_or_content_bearing_input_fails_closed_test() ->
    {ok, Store} = start_store(),
    try
        Config = #{principal => ?PRINCIPAL, server => Store},
        ?assertEqual(
           {error, invalid_trace_store_exporter_envelope},
           adk_trace_store_exporter:export(#{}, Config)),
        Secret = <<"private-prompt-never-reflected">>,
        Content = (envelope(<<"rejected">>))#{
                    <<"content_captured">> => true,
                    <<"content">> => #{<<"prompt">> => Secret}},
        Error = adk_trace_store_exporter:export(Content, Config),
        ?assertEqual({error, trace_content_rejected}, Error),
        EncodedError = term_to_binary(Error),
        ?assertEqual(nomatch, binary:match(EncodedError, Secret)),
        ?assertEqual(nomatch, binary:match(EncodedError, ?PRINCIPAL)),
        {ok, Status} = adk_trace_store:status(Store),
        ?assertEqual(0, maps:get(<<"events">>, Status))
    after
        gen_server:stop(Store)
    end.

unavailable_store_returns_structural_error_test() ->
    Config = #{principal => ?PRINCIPAL,
               server => adk_trace_store_exporter_missing},
    ?assertEqual(
       {error, trace_store_unavailable},
       adk_trace_store_exporter:export(envelope(<<"unavailable">>), Config)).

start_store() ->
    adk_trace_store:start_link(
      #{name => undefined,
        max_events => 8,
        max_bytes => 65536,
        max_event_bytes => 8192,
        max_principals => 4,
        max_events_per_principal => 8,
        max_bytes_per_principal => 65536,
        retention_ms => 5000,
        prune_interval_ms => 1000,
        max_query_events => 8,
        max_query_bytes => 65536}).

envelope(Phase) ->
    #{<<"schema_version">> => 1,
      <<"event">> => <<"erlang_adk.test.trace_exporter">>,
      <<"timestamp_ms">> => 123456789,
      <<"measurements">> => #{<<"count">> => 1},
      <<"metadata">> =>
          #{<<"run_id">> => ?RUN_ID,
            <<"trace_id">> => ?TRACE_ID,
            <<"invocation_id">> => <<"exporter-invocation">>,
            <<"attributes">> => #{<<"phase">> => Phase}},
      <<"content_captured">> => false}.
