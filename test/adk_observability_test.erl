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
