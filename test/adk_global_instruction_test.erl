-module(adk_global_instruction_test).

-include_lib("eunit/include/eunit.hrl").

global_instruction_test_() ->
    {setup,
     fun() ->
         {ok, _} = application:ensure_all_started(erlang_adk),
         ok = erlang_adk_session:init(),
         ok
     end,
     fun(_) -> flush_probe_messages() end,
     [fun root_global_instruction_reaches_dynamic_sub_agent_tree/0,
      fun empty_root_global_still_suppresses_child_global/0,
      fun nested_delegation_keeps_root_global_scope/0]}.

root_global_instruction_reaches_dynamic_sub_agent_tree() ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    SubName = <<"GlobalInstructionSub-", Suffix/binary>>,
    RootName = <<"GlobalInstructionRoot-", Suffix/binary>>,
    App = <<"global-instruction-app">>,
    User = <<"user-1">>,
    Session = <<"global-instruction-session-", Suffix/binary>>,
    {ok, _} = erlang_adk_session:create_session(
                App, User,
                #{session_id => Session,
                  state => #{<<"user:name">> => <<"Ada">>}}),
    {ok, SubPid} = erlang_adk:spawn_agent(
                     SubName,
                     #{provider => adk_llm_probe,
                       test_pid => self(),
                       global_instruction => <<"CHILD GLOBAL">>,
                       instructions => <<"SUB LOCAL">>,
                       response => <<"specialist response">>}, []),
    {ok, RootPid} = erlang_adk:spawn_agent(
                      RootName,
                      #{provider => adk_llm_probe,
                        test_pid => self(),
                        mode => sub_agent_call,
                        call_name => SubName,
                        global_instruction =>
                            {dynamic,
                             adk_agent_spec_instruction_provider,
                             global_scoped},
                        instructions => <<"ROOT LOCAL">>,
                        sub_agents =>
                            #{SubName =>
                                  #{pid => SubPid,
                                    description => <<"specialist">>}}}, []),
    try
        Runner = adk_runner:new(RootPid, App, erlang_adk_session),
        ?assertEqual(
           {ok, <<"delegation complete">>},
           adk_runner:run(
             Runner, User, Session, <<"Delegate this request">>)),
        Histories = collect_probe_histories(3, []),
        RootSystem = <<"Global Ada.\n\nROOT LOCAL">>,
        SubSystem = <<"Global Ada.\n\nSUB LOCAL">>,
        ?assertEqual(2, count_system(RootSystem, Histories)),
        ?assertEqual(1, count_system(SubSystem, Histories)),
        ?assertEqual(0,
                     count_system(
                       <<"CHILD GLOBAL\n\nSUB LOCAL">>, Histories)),

        %% Invoking the same process directly makes it the root of a new tree;
        %% its own global instruction then applies.
        ?assertEqual({ok, <<"specialist response">>},
                     erlang_adk:prompt(SubPid, <<"Standalone request">>)),
        [StandaloneHistory] = collect_probe_histories(1, []),
        ?assertEqual(<<"CHILD GLOBAL\n\nSUB LOCAL">>,
                     system_instruction(StandaloneHistory))
    after
        _ = catch erlang_adk:stop_agent(RootPid),
        _ = catch erlang_adk:stop_agent(SubPid),
        _ = erlang_adk_session:delete_session(App, User, Session),
        flush_probe_messages()
    end.

empty_root_global_still_suppresses_child_global() ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    SubName = <<"EmptyGlobalSub-", Suffix/binary>>,
    RootName = <<"EmptyGlobalRoot-", Suffix/binary>>,
    {ok, SubPid} = erlang_adk:spawn_agent(
                     SubName,
                     #{provider => adk_llm_probe,
                       test_pid => self(),
                       global_instruction => <<"CHILD GLOBAL">>,
                       instructions => <<"SUB LOCAL">>,
                       response => <<"specialist response">>}, []),
    {ok, RootPid} = erlang_adk:spawn_agent(
                      RootName,
                      #{provider => adk_llm_probe,
                        test_pid => self(),
                        mode => sub_agent_call,
                        call_name => SubName,
                        instructions => <<"ROOT LOCAL">>,
                        sub_agents =>
                            #{SubName =>
                                  #{pid => SubPid,
                                    description => <<"specialist">>}}}, []),
    try
        ?assertEqual({ok, <<"delegation complete">>},
                     erlang_adk:prompt(RootPid, <<"Delegate this request">>)),
        Histories = collect_probe_histories(3, []),
        ?assertEqual(2, count_system(<<"ROOT LOCAL">>, Histories)),
        ?assertEqual(1, count_system(<<"SUB LOCAL">>, Histories)),
        ?assertEqual(
           0,
           count_system(<<"CHILD GLOBAL\n\nSUB LOCAL">>, Histories))
    after
        _ = catch erlang_adk:stop_agent(RootPid),
        _ = catch erlang_adk:stop_agent(SubPid),
        flush_probe_messages()
    end.

nested_delegation_keeps_root_global_scope() ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    LeafName = <<"NestedGlobalLeaf-", Suffix/binary>>,
    MiddleName = <<"NestedGlobalMiddle-", Suffix/binary>>,
    RootName = <<"NestedGlobalRoot-", Suffix/binary>>,
    App = <<"nested-global-instruction-app">>,
    User = <<"user-1">>,
    Session = <<"nested-global-instruction-session-", Suffix/binary>>,
    {ok, _} = erlang_adk_session:create_session(
                App, User,
                #{session_id => Session,
                  state => #{<<"user:name">> => <<"Ada">>}}),
    {ok, LeafPid} = erlang_adk:spawn_agent(
                      LeafName,
                      #{provider => adk_llm_probe,
                        test_pid => self(),
                        global_instruction => <<"LEAF GLOBAL">>,
                        instructions => <<"LEAF LOCAL">>,
                        response => <<"leaf response">>}, []),
    {ok, MiddlePid} = erlang_adk:spawn_agent(
                        MiddleName,
                        #{provider => adk_llm_probe,
                          test_pid => self(),
                          mode => sub_agent_call,
                          call_name => LeafName,
                          global_instruction => <<"MIDDLE GLOBAL">>,
                          instructions => <<"MIDDLE LOCAL">>,
                          sub_agents =>
                              #{LeafName =>
                                    #{pid => LeafPid,
                                      description => <<"leaf">>}}}, []),
    {ok, RootPid} = erlang_adk:spawn_agent(
                      RootName,
                      #{provider => adk_llm_probe,
                        test_pid => self(),
                        mode => sub_agent_call,
                        call_name => MiddleName,
                        global_instruction =>
                            {dynamic,
                             adk_agent_spec_instruction_provider,
                             global_scoped},
                        instructions => <<"ROOT LOCAL">>,
                        sub_agents =>
                            #{MiddleName =>
                                  #{pid => MiddlePid,
                                    description => <<"middle">>}}}, []),
    try
        Runner = adk_runner:new(RootPid, App, erlang_adk_session),
        ?assertEqual(
           {ok, <<"delegation complete">>},
           adk_runner:run(
             Runner, User, Session, <<"Delegate through the tree">>)),
        Histories = collect_probe_histories(5, []),
        ?assertEqual(
           2, count_system(<<"Global Ada.\n\nROOT LOCAL">>, Histories)),
        ?assertEqual(
           2, count_system(<<"Global Ada.\n\nMIDDLE LOCAL">>, Histories)),
        ?assertEqual(
           1, count_system(<<"Global Ada.\n\nLEAF LOCAL">>, Histories)),
        ?assertEqual(
           0,
           count_system(<<"MIDDLE GLOBAL\n\nMIDDLE LOCAL">>, Histories)),
        ?assertEqual(
           0, count_system(<<"LEAF GLOBAL\n\nLEAF LOCAL">>, Histories))
    after
        _ = catch erlang_adk:stop_agent(RootPid),
        _ = catch erlang_adk:stop_agent(MiddlePid),
        _ = catch erlang_adk:stop_agent(LeafPid),
        _ = erlang_adk_session:delete_session(App, User, Session),
        flush_probe_messages()
    end.

collect_probe_histories(0, Acc) ->
    lists:reverse(Acc);
collect_probe_histories(Remaining, Acc) ->
    receive
        {probe_generate, History, _Tools} ->
            collect_probe_histories(Remaining - 1, [History | Acc])
    after 2000 ->
        erlang:error({missing_probe_histories, Remaining})
    end.

count_system(Expected, Histories) ->
    length([ok || History <- Histories,
                  system_instruction(History) =:= Expected]).

system_instruction(History) ->
    case [Content || #{role := system, content := Content} <- History] of
        [Content | _] -> Content;
        [] -> undefined
    end.

flush_probe_messages() ->
    receive
        {probe_generate, _, _} -> flush_probe_messages()
    after 0 ->
        ok
    end.
