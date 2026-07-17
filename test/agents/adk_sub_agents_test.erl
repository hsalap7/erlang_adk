-module(adk_sub_agents_test).
-include_lib("eunit/include/eunit.hrl").

sub_agents_routing_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_) -> ok end,
     [
      fun test_sub_agent_delegation/0,
      fun test_sub_agent_uses_tool_callback_lifecycle/0,
      fun test_runtime_delegation_cycle_fails_before_provider/0,
      fun test_runtime_delegation_depth_is_bounded/0,
      fun test_agent_tool_bridge_preserves_runtime_path/0,
      fun test_runner_agent_tool_bridge_preserves_runtime_path/0,
      fun test_resolved_module_bridge_preserves_runtime_path/0,
      fun test_runner_resolved_module_bridge_preserves_runtime_path/0,
      fun test_agent_tool_invocations_have_fresh_history/0,
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
    %% The probe is entered again after the delegated tool result.  Consume
    %% that notification as part of this test so no asynchronous evidence is
    %% left for the next setup-list case.
    receive
        {probe_generate, _FinalHistory, _FinalTools} -> ok
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

test_runtime_delegation_cycle_fails_before_provider() ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    ChildName = <<"RuntimeCycleChild_", Suffix/binary>>,
    ParentName = <<"RuntimeCycleParent_", Suffix/binary>>,
    {ok, ChildPid} = erlang_adk:spawn_agent(
                       ChildName,
                       #{provider => adk_llm_probe,
                         test_pid => self(),
                         response => <<"must not run">>}, []),
    {ok, ParentPid} = erlang_adk:spawn_agent(
                        ParentName,
                        #{provider => adk_llm_probe,
                          mode => sub_agent_call,
                          call_name => ChildName,
                          sub_agents => #{ChildName => ChildPid}}, []),
    try
        %% Pretend this invocation has already crossed the child.  The parent
        %% may run, but its attempted call back into the child must be rejected
        %% before the child's provider is entered.
        ?assertEqual(
           {ok, <<"delegation complete">>},
           erlang_adk:invoke(
             ParentPid, <<"delegate">>,
             #{'$adk_agent_path' => [ChildName]})),
        receive
            {probe_generate, _History, _Tools} ->
                ?assert(false)
        after 50 ->
            ok
        end,
        ?assert(is_process_alive(ParentPid)),
        ?assert(is_process_alive(ChildPid))
    after
        _ = catch erlang_adk:stop_agent(ParentPid),
        _ = catch erlang_adk:stop_agent(ChildPid)
    end.

test_runtime_delegation_depth_is_bounded() ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    AgentName = <<"RuntimeDepthAgent_", Suffix/binary>>,
    Path = [<<"Ancestor", (integer_to_binary(N))/binary>>
            || N <- lists:seq(1, 64)],
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       AgentName,
                       #{provider => adk_llm_probe,
                         test_pid => self(),
                         response => <<"must not run">>}, []),
    try
        ?assertEqual(
           {error, {delegation_depth_exceeded, 64}},
           erlang_adk:invoke(
             AgentPid, <<"too deep">>,
             #{'$adk_agent_path' => Path})),
        receive
            {probe_generate, _History, _Tools} ->
                ?assert(false)
        after 50 ->
            ok
        end,
        ?assert(is_process_alive(AgentPid))
    after
        _ = catch erlang_adk:stop_agent(AgentPid)
    end.

test_agent_tool_bridge_preserves_runtime_path() ->
    run_agent_tool_cycle_case(direct, configured_module).

test_runner_agent_tool_bridge_preserves_runtime_path() ->
    run_agent_tool_cycle_case(runner, configured_module).

test_resolved_module_bridge_preserves_runtime_path() ->
    run_agent_tool_cycle_case(direct, resolved_module).

test_runner_resolved_module_bridge_preserves_runtime_path() ->
    run_agent_tool_cycle_case(runner, resolved_module).

run_agent_tool_cycle_case(Mode, ToolKind) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    RootName = <<"AgentToolCycleRoot_", Suffix/binary>>,
    ChildName = <<"AgentToolCycleChild_", Suffix/binary>>,
    TestPid = self(),
    RootProbe = spawn(fun() -> tagged_probe(TestPid, root) end),
    ChildProbe = spawn(fun() -> tagged_probe(TestPid, child) end),
    RootConfig = #{provider => adk_llm_probe,
                   mode => tool_call,
                   call_name => <<"delegate_via_agent_tool">>,
                   call_args => #{<<"prompt">> => <<"call root again">>},
                   test_pid => RootProbe},
    RootTools = case ToolKind of
        configured_module ->
            [adk_agent_tool_bridge];
        resolved_module ->
            {ok, BridgeToolset} = adk_toolset:new(
                                    adk_resolved_module_toolset,
                                    {module, adk_agent_tool_bridge}),
            [BridgeToolset]
    end,
    {ok, RootPid} = erlang_adk:spawn_agent(
                      RootName, RootConfig, RootTools),
    ChildConfig = #{provider => adk_llm_probe,
                    mode => sub_agent_call,
                    call_name => RootName,
                    test_pid => ChildProbe,
                    sub_agents => #{RootName => RootPid}},
    {ok, ChildPid} = erlang_adk:spawn_agent(ChildName, ChildConfig, []),
    persistent_term:put({adk_agent_tool_bridge, target}, ChildPid),
    App = <<"agent-tool-cycle-app">>,
    User = <<"agent-tool-cycle-user">>,
    Session = <<"agent-tool-cycle-", Suffix/binary>>,
    try
        Result = case Mode of
            direct ->
                erlang_adk:prompt(RootPid, <<"start bridge">>);
            runner ->
                Runner = adk_runner:new(
                           RootPid, App, erlang_adk_session,
                           #{run_timeout => 2000}),
                adk_runner:run(Runner, User, Session, <<"start bridge">>)
        end,
        ?assertEqual({ok, <<"tool complete">>}, Result),
        Counts = collect_tagged_probes(#{root => 0, child => 0}),
        ?assertEqual(2, maps:get(root, Counts)),
        ?assertEqual(2, maps:get(child, Counts)),
        ?assert(is_process_alive(RootPid)),
        ?assert(is_process_alive(ChildPid))
    after
        persistent_term:erase({adk_agent_tool_bridge, target}),
        RootProbe ! stop,
        ChildProbe ! stop,
        _ = catch erlang_adk:stop_agent(ChildPid),
        _ = catch erlang_adk:stop_agent(RootPid),
        _ = erlang_adk_session:delete_session(App, User, Session)
    end.

tagged_probe(Target, Tag) ->
    receive
        {probe_generate, History, Tools} ->
            Target ! {tagged_probe, Tag, History, Tools},
            tagged_probe(Target, Tag);
        stop -> ok;
        _Other -> tagged_probe(Target, Tag)
    end.

collect_tagged_probes(Counts) ->
    receive
        {tagged_probe, Tag, _History, _Tools} ->
            collect_tagged_probes(
              Counts#{Tag => maps:get(Tag, Counts, 0) + 1})
    after 50 ->
        Counts
    end.

test_agent_tool_invocations_have_fresh_history() ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    AgentName = <<"AgentToolIsolation_", Suffix/binary>>,
    First = <<"first invocation secret">>,
    Second = <<"second invocation request">>,
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       AgentName,
                       #{provider => adk_llm_probe,
                         test_pid => self(),
                         response => <<"specialist result">>}, []),
    try
        ?assertEqual(
           {ok, <<"specialist result">>},
           adk_agent_tool:execute(
             AgentPid, #{<<"prompt">> => First}, #{})),
        FirstHistory = receive_probe_history(),
        ?assert(lists:member(First, history_contents(FirstHistory))),
        ?assertEqual(
           {ok, <<"specialist result">>},
           adk_agent_tool:execute(
             AgentName, #{<<"prompt">> => Second}, #{})),
        SecondHistory = receive_probe_history(),
        ?assert(lists:member(Second, history_contents(SecondHistory))),
        ?assertNot(lists:member(First, history_contents(SecondHistory)))
    after
        _ = catch erlang_adk:stop_agent(AgentPid)
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

receive_probe_history() ->
    receive
        {probe_generate, History, _Tools} -> History
    after 1000 ->
        ?assert(false)
    end.

history_contents(History) ->
    [Content || #{content := Content} <- History].
