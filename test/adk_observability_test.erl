-module(adk_observability_test).
-include_lib("eunit/include/eunit.hrl").

correlation_and_content_default_off_test() ->
    ensure_telemetry(),
    HandlerId = {adk_observability_test, make_ref()},
    TestPid = self(),
    EventName = [erlang_adk, test, correlated],
    ok = telemetry:attach(
           HandlerId, EventName,
           fun(Name, Measurements, Metadata, Pid) ->
               Pid ! {telemetry_seen, Name, Measurements, Metadata}
           end, TestPid),
    try
        {ok, Root} = adk_observability:new_context(
                       #{run_id => <<"run-7">>,
                         invocation_id => <<"inv-3">>,
                         session => <<"session-9">>,
                         agent => <<"planner">>, model => <<"model-a">>,
                         access_token => <<"must-not-leak">>}),
        {ok, Child} = adk_observability:child_context(
                        Root, #{tool => <<"weather">>,
                                call_id => <<"call-1">>}),
        ?assertEqual(maps:get(trace_id, Root), maps:get(trace_id, Child)),
        ?assertEqual(maps:get(span_id, Root), maps:get(parent_id, Child)),
        {ok, Envelope} = adk_observability:emit(
                           EventName, #{duration_ms => 12}, Child,
                           #{content => #{prompt => <<"private prompt">>,
                                         authorization => <<"secret">>}}),
        ?assertEqual(false, maps:get(<<"content_captured">>, Envelope)),
        ?assertNot(maps:is_key(<<"content">>, Envelope)),
        MetadataMap = maps:get(<<"metadata">>, Envelope),
        ?assertEqual(<<"run-7">>, maps:get(<<"run_id">>, MetadataMap)),
        ?assertEqual(<<"weather">>, maps:get(<<"tool">>, MetadataMap)),
        receive
            {telemetry_seen, EventName, #{<<"duration_ms">> := 12}, Meta} ->
                ?assertEqual(<<"run-7">>, maps:get(run_id, Meta)),
                ?assertEqual(<<"inv-3">>, maps:get(invocation_id, Meta)),
                ?assertEqual(<<"session-9">>, maps:get(session, Meta)),
                ?assertEqual(<<"planner">>, maps:get(agent, Meta)),
                ?assertEqual(<<"model-a">>, maps:get(model, Meta)),
                ?assertEqual(<<"weather">>, maps:get(tool, Meta)),
                ?assertEqual(<<"call-1">>, maps:get(call_id, Meta)),
                ?assertEqual(false, maps:get(content_captured, Meta))
        after 1000 -> erlang:error(telemetry_timeout)
        end
    after
        telemetry:detach(HandlerId)
    end.

explicit_capture_is_secret_pruned_test() ->
    ensure_telemetry(),
    {ok, Context} = adk_observability:new_context(#{}),
    {ok, Envelope} = adk_observability:emit(
                       [erlang_adk, test, capture], #{}, Context,
                       #{capture_content => true,
                         content => #{input => <<"hello">>,
                                      api_key => <<"secret">>,
                                      nested => #{password => <<"hidden">>,
                                                  safe => true}}}),
    Content = maps:get(<<"content">>, Envelope),
    ?assertEqual(<<"hello">>, maps:get(<<"input">>, Content)),
    ?assertNot(maps:is_key(<<"api_key">>, Content)),
    Nested = maps:get(<<"nested">>, Content),
    ?assertNot(maps:is_key(<<"password">>, Nested)),
    ?assertEqual(true, maps:get(<<"safe">>, Nested)).

opaque_opt_in_content_degrades_to_metadata_test() ->
    ensure_telemetry(),
    {ok, Context} = adk_observability:new_context(#{}),
    {ok, Envelope} = adk_observability:emit(
                       [erlang_adk, test, opaque_capture], #{}, Context,
                       #{capture_content => true,
                         content => #{request => <<"safe">>,
                                      worker => self()}}),
    ?assertEqual(false, maps:get(<<"content_captured">>, Envelope)),
    ?assertNot(maps:is_key(<<"content">>, Envelope)),
    Metadata = maps:get(<<"metadata">>, Envelope),
    Attributes = maps:get(<<"attributes">>, Metadata),
    ?assertEqual(<<"unsupported_content">>,
                 maps:get(<<"capture_error">>, Attributes)).

exporter_order_failure_and_timeout_test() ->
    ensure_telemetry(),
    {ok, Context} = adk_observability:new_context(#{run_id => <<"r">>}),
    {ok, Envelope} = adk_observability:emit(
                       [erlang_adk, test, export], #{}, Context),
    First = exporter(<<"first">>, open,
                     #{test_pid => self(), label => first, action => error}),
    Second = exporter(<<"second">>, closed,
                      #{test_pid => self(), label => second, action => ok}),
    {ok, Statuses} = adk_observability:export(Envelope, [First, Second]),
    ?assertEqual([<<"error">>, <<"ok">>],
                 [maps:get(<<"status">>, Status) || Status <- Statuses]),
    {exported, first, Envelope} = receive_export(first, Envelope),
    {exported, second, Envelope} = receive_export(second, Envelope),

    Timeout = (exporter(<<"slow">>, closed,
                        #{action => timeout, delay_ms => 500}))#{
        timeout_ms => 20
    },
    Started = erlang:monotonic_time(millisecond),
    {error, {exporter_failed, <<"slow">>, timeout}, [_]} =
        adk_observability:export(Envelope, [Timeout]),
    ?assert(erlang:monotonic_time(millisecond) - Started < 1000).

exporter_descriptor_limits_are_preflighted_test() ->
    ensure_telemetry(),
    {ok, Context} = adk_observability:new_context(#{run_id => <<"limits">>}),
    {ok, Envelope} = adk_observability:emit(
                       [erlang_adk, test, exporter_limits], #{}, Context),
    Base = exporter(<<"bounded">>, open, #{}),
    ?assertEqual(
       {error, {invalid_exporter_descriptor, 0,
                {unknown_exporter_options, 1}}},
       adk_observability:validate_exporters(
         [Base#{unexpected_option => true}])),
    LongId = binary:copy(<<"x">>, 129),
    ?assertEqual(
       {error, {invalid_exporter_descriptor, 0,
                {exporter_id_too_long, 129, 128}}},
       adk_observability:validate_exporters([Base#{id => LongId}])),
    ?assertEqual(
       {error, {invalid_exporter_descriptor, 0,
                {exporter_timeout_out_of_range, 30000}}},
       adk_observability:validate_exporters(
         [Base#{timeout_ms => 30001}])),
    ?assertEqual(
       {error, {invalid_exporter_descriptor, 0,
                {exporter_heap_out_of_range, 10000000}}},
       adk_observability:validate_exporters(
         [Base#{max_heap_words => 10000001}])),
    ?assertMatch(
       {error, {invalid_exporter_descriptor, 0,
                {exporter_config_too_large, _, 1048576}}},
       adk_observability:validate_exporters(
         [Base#{config =>
                    #{blob => binary:copy(<<"x">>, 1048577)}}])),
    ?assertEqual(
       {error, {duplicate_exporter_id, <<"bounded">>}},
       adk_observability:validate_exporters([Base, Base])),
    SixtyFour = [Base#{id => <<"exporter-",
                               (integer_to_binary(N))/binary>>,
                        config => #{test_pid => self(),
                                    label => should_not_run}}
                 || N <- lists:seq(1, 64)],
    ?assertEqual(ok, adk_observability:validate_exporters(SixtyFour)),
    SixtyFive = SixtyFour ++
        [exporter(<<"exporter-65">>, open,
                  #{test_pid => self(), label => should_not_run})],
    ?assertEqual(
       {error, {exporter_limit_exceeded, 64}},
       adk_observability:validate_exporters(SixtyFive)),
    ?assertEqual(
       {error, {exporter_limit_exceeded, 64}, []},
       adk_observability:export(Envelope, SixtyFive)),
    receive
        {exported, should_not_run, _} ->
            erlang:error(invalid_exporter_tail_caused_side_effect)
    after 0 -> ok
    end.

caller_death_kills_owned_exporter_callback_test() ->
    ensure_telemetry(),
    {ok, Context} = adk_observability:new_context(#{run_id => <<"owner">>}),
    {ok, Envelope} = adk_observability:emit(
                       [erlang_adk, test, exporter_owner], #{}, Context),
    Blocking = (exporter(
                  <<"owner-fenced">>, closed,
                  #{action => owner_fence, test_pid => self(),
                    label => owner_fenced}))#{timeout_ms => 30000},
    TestPid = self(),
    Caller = spawn(fun() ->
        TestPid ! {unexpected_export_result,
                   adk_observability:export(Envelope, [Blocking])}
    end),
    Callback = receive
        {exporter_callback_started, Pid} -> Pid
    after 1000 -> erlang:error(exporter_callback_not_started)
    end,
    CallbackMonitor = erlang:monitor(process, Callback),
    CallerMonitor = erlang:monitor(process, Caller),
    exit(Caller, kill),
    receive
        {'DOWN', CallerMonitor, process, Caller, killed} -> ok
    after 1000 -> erlang:error(export_caller_not_killed)
    end,
    receive
        {'DOWN', CallbackMonitor, process, Callback, _} -> ok
    after 1000 -> erlang:error(orphan_exporter_callback_survived)
    end,
    receive
        {unexpected_export_result, _} ->
            erlang:error(dead_export_caller_returned)
    after 0 -> ok
    end.

exporter_timeout_direct_kills_trapping_callback_test() ->
    ensure_telemetry(),
    {ok, Context} = adk_observability:new_context(
                       #{run_id => <<"trap-exit-timeout">>}),
    {ok, Envelope} = adk_observability:emit(
                       [erlang_adk, test, trapping_exporter_timeout],
                       #{}, Context),
    Blocking = (exporter(
                  <<"trapping-timeout">>, closed,
                  #{action => owner_fence, test_pid => self(),
                    label => trapping_timeout}))#{timeout_ms => 200},
    TestPid = self(),
    _Caller = spawn(fun() ->
        TestPid ! {trapping_export_result,
                   adk_observability:export(Envelope, [Blocking])}
    end),
    Callback = receive
        {exporter_callback_started, Pid} -> Pid
    after 1000 -> erlang:error(trapping_exporter_not_started)
    end,
    Monitor = erlang:monitor(process, Callback),
    receive
        {trapping_export_result,
         {error, {exporter_failed, <<"trapping-timeout">>, timeout}, [_]}} ->
            ok
    after 1000 -> erlang:error(trapping_export_timeout_missing)
    end,
    receive
        {'DOWN', Monitor, process, Callback, killed} -> ok;
        {'DOWN', Monitor, process, Callback, OtherReason} ->
            erlang:error({unexpected_trapping_callback_exit, OtherReason})
    after 1000 -> erlang:error(trapping_exporter_survived_timeout)
    end.

envelope_roundtrip_test() ->
    ensure_telemetry(),
    {ok, Context} = adk_observability:new_context(#{run_id => <<"run">>}),
    {ok, Envelope} = adk_observability:emit(
                       [erlang_adk, run, start], #{count => 1}, Context),
    Json = jsx:encode(Envelope),
    Decoded = jsx:decode(Json, [return_maps]),
    ?assertEqual({ok, Envelope}, adk_observability:decode(Decoded)).

exporter(Id, Policy, Config) ->
    #{id => Id, module => adk_observability_test_exporter,
      failure_policy => Policy, config => Config,
      timeout_ms => 1000, max_heap_words => 100000}.

receive_export(Label, Envelope) ->
    receive
        {exported, Label, Envelope} = Message -> Message
    after 1000 -> erlang:error({export_timeout, Label})
    end.

ensure_telemetry() ->
    {ok, _} = application:ensure_all_started(telemetry),
    ok.
