-module(adk_workflow_failure_security_test).

-include_lib("eunit/include/eunit.hrl").

-define(TABLE, adk_workflow_failure_security_mnesia).

workflow_failure_security_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Ledger) ->
         [?_test(supervisor_metadata_and_sys_status_hide_launch_data()),
          ?_test(one_shot_handoff_rejects_secret_payloads()),
          ?_test(public_failure_and_cancel_outcomes_hide_seed()),
          ?_test(mnesia_failure_and_cancel_outcomes_hide_seed(Ledger))]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    {ok, Ledger} = adk_invocation_ledger_mnesia:init(#{table => ?TABLE}),
    {atomic, ok} = mnesia:clear_table(?TABLE),
    Ledger.

cleanup(_Ledger) ->
    _ = application:ensure_all_started(mnesia),
    _ = mnesia:delete_table(?TABLE),
    ok.

supervisor_metadata_and_sys_status_hide_launch_data() ->
    Seed = seed(),
    Parent = self(),
    Action = blocking_action(Parent, launch_action_started, Seed),
    Compiled = compile_sequential(<<"security-launch">>, Action),
    {ok, Ref} = adk_workflow:start(
                  Compiled, #{<<"initial-secret">> => Seed},
                  #{private_launch_option => Seed, retention_ms => 10}),
    Worker = receive {launch_action_started, Pid} -> Pid
             after 1000 -> error(launch_action_not_started)
             end,
    WorkerMonitor = erlang:monitor(process, Worker),
    assert_opaque_supervision(Ref, Seed),
    ok = adk_workflow:cancel(Ref, metadata_test_complete),
    ?assertMatch({cancelled, metadata_test_complete, _},
                 adk_workflow:await(Ref, 1000)),
    receive {'DOWN', WorkerMonitor, process, Worker, _} -> ok
    after 1000 -> error(launch_action_not_stopped)
    end,
    wait_child_gone(Ref, 100),

    %% Exercise the same boundary with an opaque ledger handle containing the
    %% seed. The handle is transferred after child start and never appears in
    %% the supervisor child specification or sys diagnostics.
    Table = ets:new(workflow_security_launch_ledger, [set, public]),
    Handle = #{table => Table, seed => Seed},
    DurableAction = blocking_action(
                      Parent, durable_launch_action_started, Seed),
    DurableCompiled = compile_sequential(
                        <<"security-durable-launch">>, DurableAction),
    InvocationId = <<"security-launch-invocation">>,
    try
        {ok, InvocationId, DurableRef} = adk_workflow:start_invocation(
                                          DurableCompiled, #{},
                                          #{ledger =>
                                                {adk_workflow_security_ledger,
                                                 Handle},
                                            invocation_id => InvocationId,
                                            lease_ms => 1000,
                                            timeout => 5000,
                                            retention_ms => 10}),
        DurableWorker = receive
            {durable_launch_action_started, Pid2} -> Pid2
        after 1000 -> error(durable_launch_action_not_started)
        end,
        DurableMonitor = erlang:monitor(process, DurableWorker),
        assert_opaque_supervision(DurableRef, Seed),
        ok = adk_workflow:cancel(DurableRef, metadata_test_complete),
        ?assertMatch({cancelled, metadata_test_complete, _},
                     adk_workflow:await(DurableRef, 1000)),
        receive {'DOWN', DurableMonitor, process, DurableWorker, _} -> ok
        after 1000 -> error(durable_launch_action_not_stopped)
        end,
        assert_seed_absent(Seed, ets:tab2list(Table)),
        ok = adk_workflow:delete_invocation(
               InvocationId,
               #{ledger => {adk_workflow_security_ledger, Handle},
                 lease_ms => 1000})
    after
        ets:delete(Table)
    end.

one_shot_handoff_rejects_secret_payloads() ->
    Seed = seed(),
    Parent = self(),
    LaunchRef = make_ref(),
    {ok, Coordinator} = adk_workflow_run:start_link(LaunchRef),
    unlink(Coordinator),
    Compiled = compile_sequential(
                 <<"security-handoff">>,
                 blocking_action(Parent, handoff_action_started, Seed)),
    ?assertEqual(
       {error, invalid_workflow_handoff},
       adk_workflow_run:handoff(
         Coordinator, make_ref(), Compiled,
         #{<<"wrong-secret">> => Seed}, #{private => Seed})),
    assert_seed_absent(Seed, sys:get_status(Coordinator)),
    ok = adk_workflow_run:handoff(
           Coordinator, LaunchRef, Compiled, #{},
           #{retention_ms => 100}),
    Worker = receive {handoff_action_started, Pid} -> Pid
             after 1000 -> error(handoff_action_not_started)
             end,
    ?assertEqual(
       {error, handoff_already_completed},
       adk_workflow_run:handoff(
         Coordinator, LaunchRef, Compiled,
         #{<<"duplicate-secret">> => Seed}, #{private => Seed})),
    assert_seed_absent(Seed, sys:get_status(Coordinator)),
    Monitor = erlang:monitor(process, Worker),
    ok = adk_workflow:cancel(Coordinator, handoff_test_complete),
    ?assertMatch({cancelled, handoff_test_complete, _},
                 adk_workflow:await(Coordinator, 1000)),
    receive {'DOWN', Monitor, process, Worker, _} -> ok
    after 1000 -> error(handoff_action_not_stopped)
    end.

public_failure_and_cancel_outcomes_hide_seed() ->
    Seed = seed(),
    FailureAction = fun(_State) ->
        {error, {http_error, 503,
                 #{body => Seed, authorization => Seed,
                   request_id => <<"security-request">>}}}
    end,
    FailureCompiled = compile_sequential(
                        <<"security-public-failure">>, FailureAction),
    {ok, FailureRef} = adk_workflow:start(
                         FailureCompiled, #{}, #{retention_ms => 1000}),
    FailureOutcome = adk_workflow:await(FailureRef, 1000),
    {failed, {step_failed, <<"step">>,
              {adk_failure, FailureMetadata}}, FailureCheckpoint} =
        FailureOutcome,
    ?assertEqual(http_error, maps:get(reason, FailureMetadata)),
    ?assertEqual(503, maps:get(status, FailureMetadata)),
    {ok, FailureStatus} = adk_workflow:status(FailureRef),
    {ok, FailureCheckpoint} = adk_workflow:checkpoint(FailureRef),
    assert_seed_absent(
      Seed, {FailureOutcome, FailureStatus, FailureCheckpoint}),

    Parent = self(),
    CancelCompiled = compile_sequential(
                       <<"security-public-cancel">>,
                       blocking_action(Parent, cancel_action_started, Seed)),
    {ok, CancelRef} = adk_workflow:start(
                        CancelCompiled, #{}, #{retention_ms => 1000}),
    CancelWorker = receive {cancel_action_started, Pid} -> Pid
                   after 1000 -> error(cancel_action_not_started)
                   end,
    CancelMonitor = erlang:monitor(process, CancelWorker),
    CancelReason = #{body => Seed, authorization => Seed,
                     request_id => <<"security-cancel">>},
    ok = adk_workflow:cancel(CancelRef, CancelReason),
    CancelOutcome = adk_workflow:await(CancelRef, 1000),
    {cancelled, {adk_failure, CancelMetadata}, CancelCheckpoint} =
        CancelOutcome,
    ?assertEqual(cancel, maps:get(operation, CancelMetadata)),
    {ok, CancelStatus} = adk_workflow:status(CancelRef),
    {ok, CancelCheckpoint} = adk_workflow:checkpoint(CancelRef),
    assert_seed_absent(Seed, {CancelOutcome, CancelStatus, CancelCheckpoint}),
    receive {'DOWN', CancelMonitor, process, CancelWorker, _} -> ok
    after 1000 -> error(cancel_action_not_stopped)
    end.

mnesia_failure_and_cancel_outcomes_hide_seed(Ledger = #{table := Table}) ->
    Seed = seed(),
    Opts = #{ledger => {adk_invocation_ledger_mnesia, Ledger},
             lease_ms => 1000, timeout => 5000, retention_ms => 1000},
    FailureId = <<"security-persisted-failure">>,
    FailureCompiled = compile_sequential(
                        <<"security-persisted-failure-workflow">>,
                        fun(_State) ->
                            {error, {provider_body,
                                     #{body => Seed,
                                       authorization => Seed}}}
                        end),
    {ok, FailureId, FailureRef} = adk_workflow:start_invocation(
                                    FailureCompiled, #{},
                                    Opts#{invocation_id => FailureId}),
    FailureOutcome = adk_workflow:await(FailureRef, 1000),
    {ok, FailureRecord} = adk_workflow:invocation_status(FailureId, Opts),
    FailureRaw = mnesia:dirty_read(Table, FailureId),
    assert_seed_absent(Seed, {FailureOutcome, FailureRecord, FailureRaw}),
    ?assertMatch({failed, _, _}, maps:get(outcome, FailureRecord)),

    Parent = self(),
    CancelId = <<"security-persisted-cancel">>,
    CancelCompiled = compile_sequential(
                       <<"security-persisted-cancel-workflow">>,
                       blocking_action(
                         Parent, persisted_cancel_action_started, Seed)),
    {ok, CancelId, CancelRef} = adk_workflow:start_invocation(
                                  CancelCompiled, #{},
                                  Opts#{invocation_id => CancelId}),
    CancelWorker = receive
        {persisted_cancel_action_started, Pid} -> Pid
    after 1000 -> error(persisted_cancel_action_not_started)
    end,
    CancelMonitor = erlang:monitor(process, CancelWorker),
    ok = adk_workflow:cancel(
           CancelRef, {cancel_secret, #{body => Seed, token => Seed}}),
    CancelOutcome = adk_workflow:await(CancelRef, 1000),
    {ok, CancelRecord} = adk_workflow:invocation_status(CancelId, Opts),
    CancelRaw = mnesia:dirty_read(Table, CancelId),
    assert_seed_absent(Seed, {CancelOutcome, CancelRecord, CancelRaw}),
    ?assertMatch({cancelled, {adk_failure, _}, _},
                 maps:get(outcome, CancelRecord)),
    receive {'DOWN', CancelMonitor, process, CancelWorker, _} -> ok
    after 1000 -> error(persisted_cancel_action_not_stopped)
    end,
    ok = adk_workflow:delete_invocation(FailureId, Opts),
    ok = adk_workflow:delete_invocation(CancelId, Opts).

compile_sequential(Id, Action) ->
    {ok, Compiled} = adk_workflow:compile(
                       #{version => 1, id => Id, kind => sequential,
                         max_steps => 4,
                         steps => [#{id => <<"step">>, run => Action}]}),
    Compiled.

blocking_action(Parent, Tag, Seed) ->
    fun(_State) ->
        _Captured = Seed,
        Parent ! {Tag, self()},
        receive release -> {ok, #{}} end
    end.

assert_opaque_supervision(Ref, Seed) ->
    [{ChildId, Ref, worker, [adk_workflow_run]}] =
        [Child || Child = {_Id, Pid, worker, [adk_workflow_run]}
                      <- supervisor:which_children(adk_workflow_sup),
                  Pid =:= Ref],
    {ok, ChildSpec} = supervisor:get_childspec(adk_workflow_sup, ChildId),
    #{start := {adk_workflow_run, start_link, StartArgs}} = ChildSpec,
    ?assert(StartArgs =:= [ChildId] orelse StartArgs =:= undefined),
    assert_seed_absent(Seed, ChildSpec),
    assert_seed_absent(Seed, sys:get_status(Ref)).

wait_child_gone(_Ref, 0) ->
    error(workflow_child_not_cleaned_up);
wait_child_gone(Ref, Attempts) ->
    case lists:any(
           fun({_Id, Pid, _Type, _Modules}) -> Pid =:= Ref end,
           supervisor:which_children(adk_workflow_sup)) of
        false -> ok;
        true ->
            receive after 10 -> ok end,
            wait_child_gone(Ref, Attempts - 1)
    end.

seed() ->
    <<"seeded-workflow-secret-DO-NOT-LEAK">>.

assert_seed_absent(Seed, Term) ->
    ?assertEqual(nomatch, binary:match(term_to_binary(Term), Seed)).
