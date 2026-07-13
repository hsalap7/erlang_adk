-module(adk_sub_agents_test).
-include_lib("eunit/include/eunit.hrl").

sub_agents_routing_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_) -> ok end,
     [
      fun test_sub_agent_delegation/0,
      fun test_sub_agent_uses_tool_callback_lifecycle/0,
      fun test_unknown_tool_fallback/0,
      fun test_restarted_sub_agent_is_resolved_by_name/0
     ]}.

test_sub_agent_delegation() ->
    %% Create a sub-agent
    {ok, SubPid} = erlang_adk:spawn_agent("SubWorker", #{provider => adk_llm_dummy}, []),
    
    %% Create a master agent with sub_agents configured
    MasterConfig = #{
        provider => adk_llm_probe,
        mode => sub_agent_call,
        call_name => <<"SubWorker">>,
        test_pid => self(),
        sub_agents => #{<<"SubWorker">> => #{
            pid => SubPid,
            description => <<"Handles specialist work">>
        }}
    },
    {ok, MasterPid} = erlang_adk:spawn_agent("MasterAgent", MasterConfig, []),
    
    %% Verify get_tools returns sub_agents
    {ok, Tools, SubAgents} = adk_agent:get_tools(MasterPid),
    ?assertEqual([], Tools),
    ?assertMatch(#{<<"SubWorker">> := #{pid := SubPid}}, SubAgents),

    %% Exercise actual model-visible delegation, not just config storage.
    ?assertEqual({ok, <<"delegation complete">>},
                 erlang_adk:prompt(MasterPid, "delegate this")),
    receive
        {probe_generate, _History, ModelTools} ->
            Schemas = [Schema || Schema <- ModelTools, is_map(Schema)],
            ?assert(lists:any(fun(Schema) ->
                maps:get(<<"name">>, Schema, undefined) =:= <<"SubWorker">>
            end, Schemas))
    after 1000 ->
        ?assert(false)
    end,
    ok = erlang_adk:stop_agent(MasterPid),
    ok = erlang_adk:stop_agent(SubPid).

test_sub_agent_uses_tool_callback_lifecycle() ->
    persistent_term:put({adk_callback_lifecycle_test, target}, self()),
    {ok, SubPid} = erlang_adk:spawn_agent(
                     "CallbackSubWorker",
                     #{provider => adk_llm_probe,
                       response => <<"specialist response">>}, []),
    {ok, MasterPid} = erlang_adk:spawn_agent(
                        "CallbackSubMaster",
                        #{provider => adk_llm_probe,
                          mode => sub_agent_call,
                          call_name => <<"CallbackSubWorker">>,
                          callbacks => [adk_callback_lifecycle_test],
                          sub_agents => #{<<"CallbackSubWorker">> => SubPid}},
                        []),
    try
        ?assertEqual({ok, <<"delegation complete">>},
                     erlang_adk:prompt(MasterPid, <<"delegate">>)),
        Events = collect_callback_events(10, []),
        ?assertEqual(1, callback_count(on_tool_start, Events)),
        ?assertEqual(1, callback_count(before_tool, Events)),
        ?assertEqual(1, callback_count(after_tool, Events)),
        ?assertEqual(1, callback_count(on_tool_end, Events))
    after
        _ = catch erlang_adk:stop_agent(MasterPid),
        _ = catch erlang_adk:stop_agent(SubPid),
        persistent_term:erase({adk_callback_lifecycle_test, target})
    end.

test_unknown_tool_fallback() ->
    %% When no tool and no sub-agent matches, should return "Tool not found"
    MasterConfig = #{provider => adk_llm_dummy, sub_agents => #{}},
    {ok, MasterPid} = erlang_adk:spawn_agent("MasterNoSub", MasterConfig, []),
    {ok, _Tools, SubAgents} = adk_agent:get_tools(MasterPid),
    ?assertEqual(#{}, SubAgents),
    ok = erlang_adk:stop_agent(MasterPid).

test_restarted_sub_agent_is_resolved_by_name() ->
    {ok, OldSubPid} = erlang_adk:spawn_agent(
                        "RestartableSub", #{provider => adk_llm_dummy}, []),
    {ok, MasterPid} = erlang_adk:spawn_agent("RestartAwareMaster", #{
        provider => adk_llm_probe,
        mode => sub_agent_call,
        call_name => <<"RestartableSub">>,
        sub_agents => #{<<"RestartableSub">> => OldSubPid}
    }, []),
    OldMonitor = erlang:monitor(process, OldSubPid),
    exit(OldSubPid, kill),
    receive {'DOWN', OldMonitor, process, OldSubPid, _} -> ok
    after 1000 -> ?assert(false)
    end,
    NewSubPid = wait_for_restarted_agent(<<"RestartableSub">>, OldSubPid, 50),
    ?assert(is_pid(NewSubPid)),
    ?assertEqual({ok, <<"delegation complete">>},
                 erlang_adk:prompt(MasterPid, <<"delegate after restart">>)),
    ?assert(is_process_alive(MasterPid)),
    ok = erlang_adk:stop_agent(MasterPid),
    ok = erlang_adk:stop_agent(NewSubPid).

wait_for_restarted_agent(_Name, _OldPid, 0) ->
    ?assert(false);
wait_for_restarted_agent(Name, OldPid, Attempts) ->
    case adk_agent_registry:lookup(Name) of
        {ok, Pid} when Pid =/= OldPid -> Pid;
        _ ->
            timer:sleep(10),
            wait_for_restarted_agent(Name, OldPid, Attempts - 1)
    end.

collect_callback_events(0, Acc) -> Acc;
collect_callback_events(Remaining, Acc) ->
    receive
        {callback, Event} ->
            collect_callback_events(Remaining - 1, [Event | Acc])
    after 1000 ->
        Acc
    end.

callback_count(Event, Events) ->
    length([ok || Seen <- Events, Seen =:= Event]).
