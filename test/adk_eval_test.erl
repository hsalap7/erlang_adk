-module(adk_eval_test).
-include_lib("eunit/include/eunit.hrl").

eval_test_() ->
    [
        {"Run evaluation suite", ?_test(test_eval_run())}
    ].

setup() ->
    application:ensure_all_started(erlang_adk),
    ok.

teardown(_) ->
    application:stop(erlang_adk).

test_eval_run() ->
    setup(),
    %% Setup dummy agent
    AgentConfig = #{
        name => <<"TestAgent">>,
        provider => adk_llm_dummy,
        model => <<"dummy">>
    },
    {ok, AgentPid} = erlang_adk:spawn_agent("TestAgent", AgentConfig, []),
    
    Dataset = [
        #{input => <<"Trigger tool">>, expected => "Tool executed", metadata => #{}},
        #{input => <<"Hello">>, expected => "Simulated response", metadata => #{}}
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
