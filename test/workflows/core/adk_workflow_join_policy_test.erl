-module(adk_workflow_join_policy_test).
-include_lib("eunit/include/eunit.hrl").

workflow_join_policy_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_Setup) -> flush_branch_messages() end,
     [fun any_stops_before_starting_unneeded_branches/0,
      fun quorum_stops_at_declared_threshold/0,
      fun first_success_skips_failed_branches/0,
      fun first_success_fails_when_no_branch_succeeds/0,
      fun invalid_quorum_is_rejected/0]}.

any_stops_before_starting_unneeded_branches() ->
    Compiled = compile_policy(any,
                              [success(<<"one">>),
                               success(<<"two">>),
                               success(<<"three">>)]),
    {completed, State, Checkpoint} = adk_workflow:run(Compiled, #{}),
    ?assertEqual(true, maps:get(<<"one">>, State)),
    ?assertEqual(false, maps:is_key(<<"two">>, State)),
    ?assertEqual([<<"one">>], started_branches()),
    ?assertEqual([<<"one">>],
                 lists:sort(maps:keys(maps:get(<<"output">>, Checkpoint)))).

quorum_stops_at_declared_threshold() ->
    Compiled = compile_policy(
                 {quorum, 2},
                 [success(<<"one">>), success(<<"two">>),
                  success(<<"three">>)]),
    {completed, State, Checkpoint} = adk_workflow:run(Compiled, #{}),
    ?assertEqual(true, maps:get(<<"one">>, State)),
    ?assertEqual(true, maps:get(<<"two">>, State)),
    ?assertEqual(false, maps:is_key(<<"three">>, State)),
    ?assertEqual([<<"one">>, <<"two">>], started_branches()),
    ?assertEqual([<<"one">>, <<"two">>],
                 lists:sort(maps:keys(maps:get(<<"output">>, Checkpoint)))).

first_success_skips_failed_branches() ->
    Compiled = compile_policy(
                 first_success,
                 [failure(<<"one">>), success(<<"two">>),
                  success(<<"three">>)]),
    {completed, State, Checkpoint} = adk_workflow:run(Compiled, #{}),
    ?assertEqual(true, maps:get(<<"two">>, State)),
    ?assertEqual(false, maps:is_key(<<"three">>, State)),
    ?assertEqual([<<"one">>, <<"two">>], started_branches()),
    ?assertEqual([<<"two">>],
                 maps:keys(maps:get(<<"output">>, Checkpoint))).

first_success_fails_when_no_branch_succeeds() ->
    Compiled = compile_policy(
                 first_success,
                 [failure(<<"one">>), failure(<<"two">>)]),
    ?assertMatch(
       {failed, {fork_join_unsatisfied, <<"fork">>}, _},
       adk_workflow:run(Compiled, #{})),
    ?assertEqual([<<"one">>, <<"two">>], started_branches()).

invalid_quorum_is_rejected() ->
    Spec = policy_spec(
             {quorum, 3}, [success(<<"one">>), success(<<"two">>)]),
    ?assertEqual(
       {error, {invalid_workflow, [nodes, 1, join_policy],
                invalid_quorum}},
       adk_workflow:compile(Spec)).

compile_policy(Policy, Branches) ->
    {ok, Compiled} = adk_workflow:compile(policy_spec(Policy, Branches)),
    Compiled.

policy_spec(Policy, Branches) ->
    Ids = [Id || {Id, _Run} <- Branches],
    Nodes = [#{id => <<"fork">>, type => fork,
               branches => Ids, join => <<"join">>,
               join_policy => Policy,
               merge => reject_conflicts,
               max_concurrency => 1}]
        ++ [#{id => Id, run => Run} || {Id, Run} <- Branches]
        ++ [#{id => <<"join">>, type => join}],
    BranchEdges = [{Id, <<"join">>} || Id <- Ids],
    #{version => 1,
      id => <<"join-policy">>,
      kind => graph,
      definition_revision => 1,
      entry => <<"fork">>,
      nodes => Nodes,
      edges => maps:from_list(
                 BranchEdges ++ [{<<"join">>, end_node}]),
      max_steps => 10}.

success(Id) ->
    Parent = self(),
    {Id,
     fun(_State) ->
         Parent ! {join_policy_branch, Id},
         {output, Id, #{Id => true}}
     end}.

failure(Id) ->
    Parent = self(),
    {Id,
     fun(_State) ->
         Parent ! {join_policy_branch, Id},
         {error, expected_failure}
     end}.

started_branches() ->
    started_branches([]).

started_branches(Acc) ->
    receive
        {join_policy_branch, Id} -> started_branches([Id | Acc])
    after 25 ->
        lists:reverse(Acc)
    end.

flush_branch_messages() ->
    receive
        {join_policy_branch, _Id} -> flush_branch_messages()
    after 0 ->
        ok
    end.
