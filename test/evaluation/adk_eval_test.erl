-module(adk_eval_test).
-include_lib("eunit/include/eunit.hrl").

eval_test_() ->
    [
        {"Run evaluation suite", ?_test(test_eval_run())},
        {"Timeout rows remain aggregate-safe", ?_test(test_eval_timeout())},
        {"Sequential timeout is enforced", ?_test(test_eval_sequential_timeout())},
        {"Invalid options are rejected", ?_test(test_invalid_options())}
    ].

setup() ->
    application:ensure_all_started(erlang_adk),
    ok.

teardown(_) ->
    ok.

test_eval_run() ->
    setup(),
    %% Setup dummy agent
    AgentConfig = #{
        name => <<"EvalTestAgent">>,
        provider => adk_llm_dummy,
        model => <<"dummy">>
    },
    {ok, AgentPid} = erlang_adk:spawn_agent("EvalTestAgent", AgentConfig, []),
    
    Dataset = [
        #{input => <<"Trigger tool">>, expected => <<"Tool executed">>, metadata => #{}},
        #{input => <<"Hello">>, expected => <<"Simulated response">>, metadata => #{}}
    ],
    
    MetricFn = fun(Expected, Actual) ->
        if Expected == Actual -> 1.0; true -> 0.0 end
    end,
    
    {ok, Results} = adk_eval:run(AgentPid, Dataset, MetricFn),
    
    ?assertEqual(1.0, maps:get(average_score, Results)),
    List = maps:get(results, Results),
    ?assertEqual(2, length(List)),
    
    [Res1, Res2] = List,
    ?assertEqual(1.0, maps:get(score, Res1)),
    ?assertEqual(1.0, maps:get(score, Res2)),
    
    gen_server:stop(AgentPid),
    teardown(ok).

test_eval_timeout() ->
    BlockingAgent = spawn(fun blocking_agent/0),
    Dataset = [
        #{input => <<"one">>, expected => <<"first">>,
          metadata => #{case_id => 1}},
        #{input => <<"two">>, expected => <<"second">>,
          metadata => #{case_id => 2}}
    ],
    MetricFn = fun(_Expected, _Actual) -> 1.0 end,
    StartedAt = erlang:monotonic_time(millisecond),
    {ok, Summary} = adk_eval:run(
                      BlockingAgent, Dataset, MetricFn,
                      #{concurrency => 2, timeout => 20}),
    ?assert(erlang:monotonic_time(millisecond) - StartedAt < 1000),
    ?assertEqual(0.0, maps:get(average_score, Summary)),
    ?assert(is_integer(maps:get(total_duration_ms, Summary))),
    Rows = maps:get(results, Summary),
    ?assertEqual(2, length(Rows)),
    lists:foreach(fun(Row) ->
        ?assertEqual(timeout, maps:get(error, Row)),
        ?assertEqual(undefined, maps:get(actual, Row)),
        ?assertEqual(0.0, maps:get(score, Row)),
        ?assert(is_integer(maps:get(duration, Row))),
        ?assert(maps:is_key(input, Row)),
        ?assert(maps:is_key(expected, Row)),
        ?assert(maps:is_key(metadata, Row))
    end, Rows),
    exit(BlockingAgent, kill).

test_eval_sequential_timeout() ->
    BlockingAgent = spawn(fun blocking_agent/0),
    Dataset = [#{input => <<"one">>, expected => <<"never">>,
                 metadata => #{case_id => sequential}}],
    StartedAt = erlang:monotonic_time(millisecond),
    {ok, Summary} = adk_eval:run(
                      BlockingAgent, Dataset,
                      fun(_Expected, _Actual) -> 1.0 end,
                      #{concurrency => 1, timeout => 20}),
    ?assert(erlang:monotonic_time(millisecond) - StartedAt < 1000),
    [Row] = maps:get(results, Summary),
    ?assertEqual(timeout, maps:get(error, Row)),
    ?assertEqual(#{case_id => sequential}, maps:get(metadata, Row)),
    exit(BlockingAgent, kill).

test_invalid_options() ->
    Metric = fun(_Expected, _Actual) -> 1.0 end,
    ?assertEqual(
       {error, {invalid_concurrency, 0}},
       adk_eval:run(self(), [], Metric, #{concurrency => 0})),
    ?assertEqual(
       {error, {invalid_timeout, -1}},
       adk_eval:run(self(), [], Metric, #{timeout => -1})).

blocking_agent() ->
    receive
        _Message -> blocking_agent()
    end.
