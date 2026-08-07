-module(adk_workflow_first_success_recovery_test).
-include_lib("eunit/include/eunit.hrl").

workflow_first_success_recovery_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_Setup) -> flush_test_messages() end,
     [fun failed_branch_is_not_replayed_after_resume/0,
      fun concurrent_failure_keeps_running_sibling_identity/0,
      fun input_schema_failure_is_tolerated/0,
      fun terminal_failure_emits_node_failed_before_terminal/0]}.

failed_branch_is_not_replayed_after_resume() ->
    Parent = self(),
    Failed = fun(_State) ->
        Parent ! {first_success_branch, failed, self()},
        {error, expected_failure}
    end,
    Waiting = fun(_State, Context) ->
        Parent ! {first_success_branch, waiting, self(),
                  maps:get(attempt, Context)},
        receive
            release ->
                {output, <<"winner">>, #{<<"winner">> => true}}
        end
    end,
    Compiled = compile_first_success(
                 <<"first-success-recovery">>,
                 [#{id => <<"failed">>, run => Failed},
                  #{id => <<"waiting">>, run => Waiting}]),
    {ok, Ref1} = adk_workflow:start(
                   Compiled, #{},
                   #{max_concurrency => 1, retention_ms => 2000}),
    receive
        {first_success_branch, failed, _Pid} -> ok
    after 1000 ->
        error(failed_branch_did_not_start)
    end,
    receive
        {first_success_branch, waiting, _Pid1, 1} -> ok
    after 1000 ->
        error(waiting_branch_did_not_start)
    end,
    {ok, Checkpoint} = adk_workflow:checkpoint(Ref1),
    Cursor = maps:get(<<"cursor">>, Checkpoint),
    ?assertEqual(<<"fork">>, maps:get(<<"phase">>, Cursor)),
    ?assertEqual(#{<<"failed">> => true},
                 maps:get(<<"failed_branches">>, Cursor)),
    FailedEntry = attempt_entry(<<"failed">>, Checkpoint),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, FailedEntry)),
    ?assertEqual(1, maps:get(<<"count">>, FailedEntry)),
    RemainingBefore = maps:get(
                        <<"steps">>, maps:get(<<"remaining">>, Checkpoint)),
    ok = adk_workflow:cancel(Ref1, test_recovery),

    {ok, Ref2} = adk_workflow:resume(
                   Compiled, Checkpoint,
                   #{max_concurrency => 1, retention_ms => 2000}),
    WaitingPid = receive
        {first_success_branch, waiting, Pid2, 1} -> Pid2
    after 1000 ->
        error(waiting_branch_was_not_replayed)
    end,
    assert_failed_branch_not_replayed(),
    WaitingPid ! release,
    {completed, State, FinalCheckpoint} = adk_workflow:await(Ref2, 1000),
    ?assertEqual(true, maps:get(<<"winner">>, State)),
    assert_failed_branch_not_replayed(),
    RemainingAfter = maps:get(
                       <<"steps">>,
                       maps:get(<<"remaining">>, FinalCheckpoint)),
    %% Only the join node is a new logical action after recovery. The running
    %% winner keeps its original budget debit and one-based attempt number.
    ?assertEqual(RemainingBefore - 1, RemainingAfter),
    ?assertEqual(<<"failed">>,
                 maps:get(<<"status">>,
                          attempt_entry(<<"failed">>, FinalCheckpoint))).

concurrent_failure_keeps_running_sibling_identity() ->
    Parent = self(),
    Failure = fun(_State) ->
        Parent ! {controlled_failure, self()},
        receive fail -> {error, expected_failure} end
    end,
    Winner = fun(_State, Context) ->
        Parent ! {controlled_winner, self(), maps:get(attempt, Context)},
        receive release -> {ok, #{<<"winner">> => true}} end
    end,
    Compiled = compile_first_success(
                 <<"concurrent-first-success-recovery">>,
                 [#{id => <<"failed">>, run => Failure},
                  #{id => <<"winner">>, run => Winner}], 2),
    {ok, Ref1} = adk_workflow:start(
                   Compiled, #{},
                   #{max_concurrency => 2, retention_ms => 2000}),
    FailurePid = receive
        {controlled_failure, Pid1} -> Pid1
    after 1000 -> error(controlled_failure_did_not_start)
    end,
    receive
        {controlled_winner, _Pid2, 1} -> ok
    after 1000 -> error(controlled_winner_did_not_start)
    end,
    FailurePid ! fail,
    Checkpoint = wait_for_failed_checkpoint(Ref1, 50),
    RemainingBefore = maps:get(
                        <<"steps">>, maps:get(<<"remaining">>, Checkpoint)),
    ok = adk_workflow:cancel(Ref1, test_recovery),
    {ok, Ref2} = adk_workflow:resume(
                   Compiled, Checkpoint,
                   #{max_concurrency => 2, retention_ms => 2000}),
    WinnerPid = receive
        {controlled_winner, Pid3, 1} -> Pid3
    after 1000 -> error(controlled_winner_was_not_replayed)
    end,
    WinnerPid ! release,
    {completed, _State, FinalCheckpoint} = adk_workflow:await(Ref2, 1000),
    RemainingAfter = maps:get(
                       <<"steps">>,
                       maps:get(<<"remaining">>, FinalCheckpoint)),
    ?assertEqual(RemainingBefore - 1, RemainingAfter),
    ?assertEqual(1, maps:get(<<"count">>,
                            attempt_entry(<<"winner">>, FinalCheckpoint))).

input_schema_failure_is_tolerated() ->
    Parent = self(),
    Invalid = fun(_State) ->
        Parent ! invalid_schema_branch_ran,
        {output, <<"invalid">>, #{<<"invalid">> => true}}
    end,
    Winner = fun(_State) ->
        Parent ! valid_schema_branch_ran,
        {output, <<"winner">>, #{<<"winner">> => true}}
    end,
    Compiled = compile_first_success(
                 <<"first-success-input-schema">>,
                 [#{id => <<"integer-only">>, run => Invalid,
                    input_schema => #{<<"type">> => <<"integer">>}},
                  #{id => <<"winner">>, run => Winner}]),
    {completed, State, _Checkpoint} = adk_workflow:run(
                                        Compiled, #{},
                                        #{max_concurrency => 1,
                                          lifecycle_receiver => self(),
                                          retention_ms => 1000}),
    ?assertEqual(true, maps:get(<<"winner">>, State)),
    receive invalid_schema_branch_ran -> error(invalid_branch_executed)
    after 0 -> ok
    end,
    receive valid_schema_branch_ran -> ok
    after 1000 -> error(valid_branch_not_executed)
    end,
    Events = collect_lifecycle_any_ref([]),
    ?assert(lists:any(
              fun(#{<<"type">> := <<"node_failed">>,
                    <<"node_id">> := <<"integer-only">>}) -> true;
                 (_) -> false
              end, Events)).

terminal_failure_emits_node_failed_before_terminal() ->
    {ok, Compiled} = adk_workflow:compile(
                       #{version => 1,
                         id => <<"terminal-node-failure-lifecycle">>,
                         kind => sequential,
                         definition_revision => 1,
                         steps =>
                             [#{id => <<"broken">>,
                                run => fun(_State) ->
                                    {error, expected_failure}
                                end}],
                         max_steps => 2}),
    {ok, Ref} = adk_workflow:start(
                  Compiled, #{},
                  #{lifecycle_receiver => self(), retention_ms => 1000}),
    ?assertMatch({failed, {step_failed, <<"broken">>, _}, _},
                 adk_workflow:await(Ref, 1000)),
    Events = collect_lifecycle(Ref, []),
    Types = [maps:get(<<"type">>, Event) || Event <- Events],
    FailedIndex = index_of(<<"node_failed">>, Types),
    TerminalIndex = index_of(<<"workflow_terminal">>, Types),
    ?assert(FailedIndex < TerminalIndex),
    FailedEvent = lists:nth(FailedIndex, Events),
    ?assertEqual(<<"broken">>, maps:get(<<"node_id">>, FailedEvent)),
    ?assertEqual(false, maps:is_key(<<"reason">>, FailedEvent)).

compile_first_success(Id, BranchNodes) ->
    compile_first_success(Id, BranchNodes, 1).

compile_first_success(Id, BranchNodes, MaxConcurrency) ->
    BranchIds = [maps:get(id, Node) || Node <- BranchNodes],
    Nodes = [#{id => <<"fork">>, type => fork,
               branches => BranchIds,
               join => <<"join">>,
               join_policy => first_success,
               merge => reject_conflicts,
               max_concurrency => MaxConcurrency}]
        ++ BranchNodes
        ++ [#{id => <<"join">>, type => join}],
    Edges = maps:from_list(
              [{BranchId, <<"join">>} || BranchId <- BranchIds]
              ++ [{<<"join">>, end_node}]),
    {ok, Compiled} = adk_workflow:compile(
                       #{version => 1,
                         id => Id,
                         kind => graph,
                         definition_revision => 1,
                         entry => <<"fork">>,
                         nodes => Nodes,
                         edges => Edges,
                         max_steps => 5}),
    Compiled.

wait_for_failed_checkpoint(_Ref, 0) ->
    error(failed_branch_was_not_checkpointed);
wait_for_failed_checkpoint(Ref, AttemptsLeft) ->
    {ok, Checkpoint} = adk_workflow:checkpoint(Ref),
    Cursor = maps:get(<<"cursor">>, Checkpoint),
    case maps:is_key(
           <<"failed">>, maps:get(<<"failed_branches">>, Cursor, #{})) of
        true -> Checkpoint;
        false ->
            receive after 5 -> ok end,
            wait_for_failed_checkpoint(Ref, AttemptsLeft - 1)
    end.

attempt_entry(NodeId, Checkpoint) ->
    Matches = [Entry || Entry <- maps:values(
                                  (maps:get(<<"attempts">>, Checkpoint))),
                        maps:get(<<"node_id">>, Entry) =:= NodeId],
    case Matches of
        [Entry] -> Entry;
        _ -> error({unexpected_attempt_entries, NodeId, Matches})
    end.

assert_failed_branch_not_replayed() ->
    receive
        {first_success_branch, failed, _Pid} ->
            error(failed_branch_replayed)
    after 50 ->
        ok
    end.

collect_lifecycle(Ref, Acc) ->
    receive
        {adk_workflow_lifecycle, Ref, Event} ->
            Next = [Event | Acc],
            case maps:get(<<"type">>, Event) of
                <<"workflow_terminal">> -> lists:reverse(Next);
                _ -> collect_lifecycle(Ref, Next)
            end
    after 1000 ->
        error({missing_terminal_lifecycle, lists:reverse(Acc)})
    end.

collect_lifecycle_any_ref(Acc) ->
    receive
        {adk_workflow_lifecycle, _Ref, Event} ->
            Next = [Event | Acc],
            case maps:get(<<"type">>, Event) of
                <<"workflow_terminal">> -> lists:reverse(Next);
                _ -> collect_lifecycle_any_ref(Next)
            end
    after 1000 ->
        error({missing_terminal_lifecycle, lists:reverse(Acc)})
    end.

index_of(Item, List) -> index_of(Item, List, 1).

index_of(Item, [Item | _], Index) -> Index;
index_of(Item, [_ | Rest], Index) -> index_of(Item, Rest, Index + 1);
index_of(Item, [], _Index) -> error({missing_item, Item}).

flush_test_messages() ->
    receive
        {first_success_branch, _Kind, _Pid} -> flush_test_messages();
        {first_success_branch, _Kind, _Pid, _Attempt} ->
            flush_test_messages();
        invalid_schema_branch_ran -> flush_test_messages();
        valid_schema_branch_ran -> flush_test_messages();
        {controlled_failure, _Pid} -> flush_test_messages();
        {controlled_winner, _Pid, _Attempt} -> flush_test_messages();
        {adk_workflow_lifecycle, _Ref, _Event} -> flush_test_messages()
    after 0 ->
        ok
    end.
