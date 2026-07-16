-module(adk_observability_runner_test).
-include_lib("eunit/include/eunit.hrl").

runner_uses_async_bus_and_real_model_span_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    BusName = adk_observability_runner_bus_test,
    Exporter = #{id => <<"runner-test">>,
                 module => adk_observability_test_exporter,
                 config => #{test_pid => self(), label => runner_span},
                 timeout_ms => 1000, max_heap_words => 100000,
                 failure_policy => open},
    {ok, Bus} = adk_observability_bus:start_link(
                  #{name => BusName, exporters => [Exporter],
                    flush_interval_ms => 10, batch_size => 8}),
    unlink(Bus),
    {ok, Agent} = erlang_adk:spawn_agent(
                    <<"ObservedRunnerAgent">>,
                    #{provider => adk_llm_probe,
                      model => <<"probe-model">>,
                      mode => tool_call,
                      call_name => <<"dummy_tool">>,
                      call_args => #{<<"arg">> => <<"observed">>},
                      call_id => <<"observed-call-id">>,
                      response => <<"observed response">>}, [dummy_tool]),
    Runner = adk_runner:new(
               Agent, <<"observed-app">>, erlang_adk_session,
               #{observability =>
                     #{delivery => async, bus => BusName,
                       failure_policy => closed,
                       capture_content => false,
                       attributes => #{deployment => <<"test">>}}}),
    try
        ?assertEqual(
           {ok, <<"observed response">>},
           adk_runner:run(
             Runner, <<"observed-user">>, <<"observed-session">>,
             <<"hello">>)),
        ok = adk_observability_bus:drain(BusName, 3000),
        Envelopes = receive_envelopes([], 100),
        EndSpans = [Envelope || Envelope <- Envelopes,
                                maps:get(<<"schema_version">>, Envelope, 0)
                                  =:= 2,
                                maps:get(<<"phase">>, Envelope, undefined)
                                  =:= <<"end">>],
        [ModelSpan | _] =
            [Span || Span <- EndSpans,
                     maps:get(<<"name">>, Span) =:=
                       <<"gen_ai.generate_content">>],
        ?assert(maps:get(<<"duration_nano">>, ModelSpan) >= 0),
        Attributes = maps:get(<<"attributes">>, ModelSpan),
        ?assertEqual(<<"adk_llm_probe">>,
                     maps:get(<<"gen_ai.provider.name">>, Attributes)),
        ?assertEqual(<<"probe-model">>,
                     maps:get(<<"gen_ai.request.model">>, Attributes)),
        [ToolSpan | _] =
            [Span || Span <- EndSpans,
                     maps:get(<<"name">>, Span) =:=
                       <<"gen_ai.execute_tool">>],
        ToolAttributes = maps:get(<<"attributes">>, ToolSpan),
        ?assertEqual(<<"dummy_tool">>,
                     maps:get(<<"gen_ai.tool.name">>, ToolAttributes)),
        ?assertEqual(<<"observed-call-id">>,
                     maps:get(<<"gen_ai.tool.call.id">>, ToolAttributes)),
        ?assertEqual(false,
                     lists:any(
                       fun(Envelope) -> maps:is_key(<<"content">>, Envelope)
                       end, Envelopes))
    after
        erlang_adk:stop_agent(Agent),
        gen_server:stop(Bus)
    end.

post_execution_delivery_failure_preserves_model_result_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    HandlerId = {?MODULE, make_ref()},
    TestPid = self(),
    ok = telemetry:attach(
           HandlerId,
           [erlang_adk, observability, delivery_failure],
           fun(_Event, Measurements, Metadata, Pid) ->
               Pid ! {observability_delivery_failure,
                      Measurements, Metadata}
           end, TestPid),
    Exporter = #{id => <<"fail-end">>,
                 module => adk_observability_test_exporter,
                 config => #{action => fail_end, test_pid => self(),
                             label => fail_end},
                 timeout_ms => 1000, max_heap_words => 100000,
                 failure_policy => closed},
    {ok, Agent} = erlang_adk:spawn_agent(
                    <<"PostExecutionObservedAgent">>,
                    #{provider => adk_llm_probe,
                      model => <<"probe-model">>,
                      mode => tool_call,
                      call_name => <<"dummy_tool">>,
                      call_args => #{<<"arg">> => <<"side-effect">>},
                      call_id => <<"post-execution-call">>,
                      response => <<"completed exactly once">>}, [dummy_tool]),
    Runner = adk_runner:new(
               Agent, <<"observed-app-post">>, erlang_adk_session,
               #{observability =>
                     #{delivery => sync, exporters => [Exporter],
                       failure_policy => closed,
                       capture_content => false}}),
    try
        ?assertEqual(
           {ok, <<"completed exactly once">>},
           adk_runner:run(
             Runner, <<"observed-user-post">>, <<"observed-session-post">>,
             <<"hello">>)),
        receive
            {observability_delivery_failure, #{count := 1}, Metadata} ->
                ?assertEqual(finish_span, maps:get(phase, Metadata)),
                ?assertEqual(generate_content,
                             maps:get(operation, Metadata)),
                ?assertEqual(exporter_failed, maps:get(reason, Metadata)),
                ?assert(is_binary(maps:get(trace_id, Metadata))),
                ?assert(is_binary(maps:get(span_id, Metadata)))
        after 1000 ->
            erlang:error(delivery_failure_diagnostic_missing)
        end
    after
        telemetry:detach(HandlerId),
        erlang_adk:stop_agent(Agent)
    end.

receive_envelopes(Acc, Wait) ->
    receive
        {exported, runner_span, Envelope} ->
            receive_envelopes([Envelope | Acc], Wait)
    after Wait ->
        lists:reverse(Acc)
    end.
