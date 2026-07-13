-module(erlang_adk_tests).
-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {setup,
        fun() -> 
            application:ensure_all_started(erlang_adk)
        end,
        fun(_) -> 
            ok
        end,
        [
            fun basic_agent_test_case/0,
            fun orchestrator_test_case/0,
            fun telemetry_test_case/0,
            fun a2a_test_case/0,
            fun mnesia_session_test_case/0,
            fun tools_test_case/0,
            fun async_delegate_test_case/0
        ]
    }.

basic_agent_test_case() ->
    LLMConfig = #{provider => adk_llm_dummy, instructions => "You are a helpful assistant.", session_id => test_session_1},
    {ok, Pid} = erlang_adk:spawn_agent("TestAgent", LLMConfig, []),
    {ok, Response} = erlang_adk:prompt(Pid, "Hello"),
    ok = erlang_adk:delegate(Pid, "Do something async"),
    ?assertEqual(<<"Simulated response">>, Response),
    Memory = erlang_adk_session:load(test_session_1),
    ?assert(length(Memory) > 0),
    erlang_adk_session:delete(test_session_1).

orchestrator_test_case() ->
    LLMConfig = #{provider => adk_llm_dummy, instructions => "Test"},
    {ok, Pid1} = erlang_adk:spawn_agent("Agent1", LLMConfig, []),
    {ok, Pid2} = erlang_adk:spawn_agent("Agent2", LLMConfig, []),
    {ok, SeqRes} = erlang_adk:sequential([Pid1, Pid2], "Hello"),
    ?assertEqual(<<"Simulated response">>, SeqRes),
    ParallelRes = erlang_adk:parallel([Pid1, Pid2], "Hello"),
    SortedRes = lists:sort(ParallelRes),
    SortedExpected = lists:sort(
                       [{Pid1, <<"Simulated response">>},
                        {Pid2, <<"Simulated response">>}]),
    ?assertEqual(SortedExpected, SortedRes).

telemetry_test_case() ->
    Self = self(),
    Handler = fun(_Event, _Measurements, _Metadata, _Config) ->
        Self ! telemetry_fired
    end,
    telemetry:attach(<<"test_handler">>, [erlang_adk, agent, prompt, stop], Handler, #{}),
    {ok, Pid} = erlang_adk:spawn_agent("TelemetryAgent", #{provider => adk_llm_dummy}, []),
    {ok, _} = erlang_adk:prompt(Pid, "Hello"),
    receive
        telemetry_fired -> ok
    after 1000 ->
        ?assert(false)
    end,
    telemetry:detach(<<"test_handler">>).

a2a_test_case() ->
    UnicodeResponse = <<"café \x{2615}"/utf8>>,
    {ok, Pid} = erlang_adk:spawn_agent("A2AAgent", #{
        provider => adk_llm_probe,
        response => UnicodeResponse
    }, []),
    %% Wait a tiny bit for Cowboy to be ready
    timer:sleep(100),
    Res = erlang_adk_a2a_client:prompt(
            "http://localhost:8080/a2a/prompt", "A2AAgent", <<"héllo"/utf8>>),
    ?assertEqual({ok, UnicodeResponse}, Res),
    ok = erlang_adk:stop_agent(Pid).

mnesia_session_test_case() ->
    LLMConfig = #{provider => adk_llm_dummy, session_id => mnesia_test_1, session_store => erlang_adk_session_mnesia},
    {ok, Pid} = erlang_adk:spawn_agent("MnesiaAgent", LLMConfig, []),
    {ok, _} = erlang_adk:prompt(Pid, "Hello Mnesia"),
    Memory = erlang_adk_session_mnesia:load(mnesia_test_1),
    ?assert(length(Memory) > 0),
    erlang_adk_session_mnesia:delete(mnesia_test_1).

tools_test_case() ->
    {ok, Pid} = erlang_adk:spawn_agent("ToolsAgent", #{provider => adk_llm_dummy}, [dummy_tool]),
    {ok, Res} = erlang_adk:prompt(Pid, "Trigger tool"),
    ?assertEqual(<<"Tool executed">>, Res).

async_delegate_test_case() ->
    {ok, Pid} = erlang_adk:spawn_agent("AsyncAgent", #{provider => adk_llm_dummy}, []),
    erlang_adk:delegate(Pid, "Hello", self()),
    receive
        {agent_response, Pid, Res} ->
            ?assertEqual(<<"Simulated response">>, Res)
    after 5000 ->
        ?assert(false)
    end.
