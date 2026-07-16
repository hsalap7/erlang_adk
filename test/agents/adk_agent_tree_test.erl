-module(adk_agent_tree_test).

-include_lib("eunit/include/eunit.hrl").

agent_tree_validation_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_) -> ok end,
     [fun valid_identifier_tree_starts/0,
      fun reserved_root_name_is_rejected/0,
      fun invalid_root_identifiers_are_rejected/0,
      fun invalid_and_reserved_child_names_are_rejected/0,
      fun root_self_reference_is_rejected/0,
      fun normalized_sibling_names_must_be_unique/0,
      fun names_must_be_unique_across_the_tree/0,
      fun child_cycles_are_rejected/0,
      fun unresponsive_child_validation_is_time_bounded/0]}.

valid_identifier_tree_starts() ->
    {ok, Child} = erlang_adk:spawn_agent(
                    <<"TreeChild_1">>, #{provider => adk_llm_dummy}, []),
    try
        {ok, Root} = erlang_adk:spawn_agent(
                       <<"_TreeRoot1">>,
                       #{provider => adk_llm_dummy,
                         sub_agents => #{<<"TreeChild_1">> => Child}}, []),
        ok = erlang_adk:stop_agent(Root)
    after
        _ = catch erlang_adk:stop_agent(Child)
    end.

reserved_root_name_is_rejected() ->
    ?assertEqual(
       {error, {invalid_agent_tree,
                {invalid_name, root, reserved_user}}},
       erlang_adk:spawn_agent(
         <<"user">>, #{provider => adk_llm_dummy}, [])).

invalid_root_identifiers_are_rejected() ->
    lists:foreach(
      fun(Name) ->
          ?assertEqual(
             {error, {invalid_agent_tree,
                      {invalid_name, root, invalid_identifier}}},
             erlang_adk:spawn_agent(
               Name, #{provider => adk_llm_dummy}, []))
      end,
      [<<>>, <<"9Agent">>, <<"bad-name">>, <<"has space">>]).

invalid_and_reserved_child_names_are_rejected() ->
    lists:foreach(
      fun({Name, Detail}) ->
          Config = #{provider => adk_llm_dummy,
                     sub_agents => #{Name => self()}},
          ?assertEqual(
             {error, {invalid_agent_tree,
                      {invalid_name, sub_agent, Detail}}},
             erlang_adk:spawn_agent(<<"ValidRoot">>, Config, []))
      end,
      [{<<"user">>, reserved_user},
       {<<"invalid-child">>, invalid_identifier}]).

root_self_reference_is_rejected() ->
    Config = #{provider => adk_llm_dummy,
               sub_agents => #{<<"SelfRoot">> => self()}},
    ?assertEqual(
       {error, {invalid_agent_tree,
                {self_reference, <<"SelfRoot">>}}},
       erlang_adk:spawn_agent(<<"SelfRoot">>, Config, [])).

normalized_sibling_names_must_be_unique() ->
    Config = #{provider => adk_llm_dummy,
               sub_agents => #{duplicate_child => self(),
                               <<"duplicate_child">> => self()}},
    ?assertEqual(
       {error, {invalid_agent_tree,
                {duplicate_name, <<"duplicate_child">>}}},
       erlang_adk:spawn_agent(<<"DuplicateRoot">>, Config, [])).

names_must_be_unique_across_the_tree() ->
    Pids = [BranchA, BranchB, LeafA, LeafB] =
        [start_runtime(Name) || Name <-
             [<<"BranchA">>, <<"BranchB">>,
              <<"SharedLeaf">>, <<"SharedLeaf">>]],
    try
        ok = set_sub_agents(BranchA, #{<<"SharedLeaf">> => LeafA}),
        ok = set_sub_agents(BranchB, #{<<"SharedLeaf">> => LeafB}),
        Config = #{provider => adk_llm_dummy,
                   sub_agents => #{<<"BranchA">> => BranchA,
                                   <<"BranchB">> => BranchB}},
        ?assertEqual(
           {error, {invalid_agent_tree,
                    {duplicate_name, <<"SharedLeaf">>}}},
           erlang_adk:spawn_agent(<<"GlobalDuplicateRoot">>, Config, []))
    after
        stop_runtimes(Pids)
    end.

child_cycles_are_rejected() ->
    Pids = [AgentA, AgentB] =
        [start_runtime(Name) || Name <- [<<"CycleA">>, <<"CycleB">>]],
    try
        ok = set_sub_agents(AgentA, #{<<"CycleB">> => AgentB}),
        ok = set_sub_agents(AgentB, #{<<"CycleA">> => AgentA}),
        Config = #{provider => adk_llm_dummy,
                   sub_agents => #{<<"CycleA">> => AgentA}},
        ?assertEqual(
           {error, {invalid_agent_tree, {cycle, <<"CycleA">>}}},
           erlang_adk:spawn_agent(<<"CycleRoot">>, Config, []))
    after
        stop_runtimes(Pids)
    end.

unresponsive_child_validation_is_time_bounded() ->
    SlowChild = spawn(fun unresponsive_runtime/0),
    StartedAt = erlang:monotonic_time(millisecond),
    try
        Config = #{provider => adk_llm_dummy,
                   sub_agents => #{<<"SlowChild">> => SlowChild}},
        ?assertEqual(
           {error, {invalid_agent_tree,
                    agent_tree_validation_timeout}},
           erlang_adk:spawn_agent(<<"BoundedRoot">>, Config, [])),
        Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
        ?assert(Elapsed < 3000)
    after
        SlowChild ! stop
    end.

start_runtime(Name) ->
    spawn(fun() -> runtime_loop(Name, #{}) end).

set_sub_agents(Pid, SubAgents) ->
    Ref = make_ref(),
    Pid ! {set_sub_agents, self(), Ref, SubAgents},
    receive
        {Ref, ok} -> ok
    after 1000 ->
        erlang:error(runtime_setup_timeout)
    end.

runtime_loop(Name, SubAgents) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, Name, #{}, [], SubAgents}),
            runtime_loop(Name, SubAgents);
        {set_sub_agents, Caller, Ref, NewSubAgents} ->
            Caller ! {Ref, ok},
            runtime_loop(Name, NewSubAgents);
        stop ->
            ok
    end.

unresponsive_runtime() ->
    receive
        stop -> ok
    end.

stop_runtimes(Pids) ->
    lists:foreach(fun(Pid) -> Pid ! stop end, Pids).
