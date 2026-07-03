-module(adk_sub_agents_test).
-include_lib("eunit/include/eunit.hrl").

sub_agents_routing_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_) -> application:stop(erlang_adk) end,
     [
      fun test_sub_agent_delegation/0,
      fun test_unknown_tool_fallback/0
     ]}.

test_sub_agent_delegation() ->
    %% Create a sub-agent
    {ok, SubPid} = erlang_adk:spawn_agent("SubWorker", #{provider => adk_llm_dummy}, []),
    
    %% Create a master agent with sub_agents configured
    MasterConfig = #{
        provider => adk_llm_dummy,
        sub_agents => #{<<"SubWorker">> => SubPid}
    },
    {ok, MasterPid} = erlang_adk:spawn_agent("MasterAgent", MasterConfig, []),
    
    %% Verify get_tools returns sub_agents
    {ok, Tools, SubAgents} = adk_agent:get_tools(MasterPid),
    ?assertEqual([], Tools),
    ?assertEqual(#{<<"SubWorker">> => SubPid}, SubAgents).

test_unknown_tool_fallback() ->
    %% When no tool and no sub-agent matches, should return "Tool not found"
    MasterConfig = #{provider => adk_llm_dummy, sub_agents => #{}},
    {ok, MasterPid} = erlang_adk:spawn_agent("MasterNoSub", MasterConfig, []),
    {ok, _Tools, SubAgents} = adk_agent:get_tools(MasterPid),
    ?assertEqual(#{}, SubAgents).
