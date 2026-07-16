-module(adk_durable_workflow_test).
-include_lib("eunit/include/eunit.hrl").

-define(TABLE, adk_durable_invocation_test).

durable_workflow_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Ledger) ->
         [?_test(coordinator_crash_resumes_from_persisted_checkpoint(Ledger)),
          ?_test(worker_crash_resumes_from_persisted_checkpoint(Ledger)),
          ?_test(concurrent_resume_has_one_fenced_owner(Ledger)),
          ?_test(application_restart_resumes_by_invocation_id(Ledger)),
          ?_test(durable_graph_pause_consumes_resume_input(Ledger)),
          ?_test(active_coordinator_renews_lease(Ledger)),
          ?_test(stale_fencing_token_cannot_commit(Ledger)),
          ?_test(expired_owner_cannot_write_without_takeover(Ledger)),
          ?_test(expired_live_local_owner_is_claimable(Ledger)),
          ?_test(concurrent_expiry_claim_has_single_winner(Ledger)),
          ?_test(ledger_restart_preserves_expiry_fence(Ledger))]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    {ok, Ledger} = adk_invocation_ledger_mnesia:init(#{table => ?TABLE}),
    true = mnesia:table_info(?TABLE, majority),
    {atomic, ok} = mnesia:clear_table(?TABLE),
    Ledger.

cleanup(_Ledger) ->
    _ = application:ensure_all_started(erlang_adk),
    _ = mnesia:delete_table(?TABLE),
    ok.

coordinator_crash_resumes_from_persisted_checkpoint(Ledger) ->
    {Table, Compiled, InvocationId, Ref, SecondPid} =
        start_blocked(Ledger, <<"coordinator-crash">>),
    try
        {ok, Persisted} = status(InvocationId, Ledger),
        assert_second_checkpoint(Persisted),
        RefMonitor = erlang:monitor(process, Ref),
        exit(Ref, kill),
        receive {'DOWN', RefMonitor, process, Ref, killed} -> ok
        after 1000 -> ?assert(false)
        end,
        await_dead(SecondPid),

        ets:insert(Table, {allow_second, true}),
        {ok, Resumed} = adk_workflow:resume_invocation(
                          InvocationId, Compiled, opts(Ledger)),
        {completed, State, CompleteCheckpoint} =
            adk_workflow:await(Resumed, 2000),
        ?assertEqual(true, maps:get(<<"first_committed">>, State)),
        ?assertEqual(true, maps:get(<<"second_committed">>, State)),
        ?assertEqual(true, maps:get(<<"completed">>, CompleteCheckpoint)),
        ?assertEqual(1, ets:lookup_element(Table, first_calls, 2)),
        {ok, Final} = status(InvocationId, Ledger),
        ?assertEqual(completed, maps:get(phase, Final)),
        ?assertEqual({error, invocation_completed},
                     adk_workflow:resume_invocation(
                       InvocationId, Compiled, opts(Ledger)))
    after
        cleanup_invocation(InvocationId, Ledger),
        ets:delete(Table)
    end.

worker_crash_resumes_from_persisted_checkpoint(Ledger) ->
    {Table, Compiled, InvocationId, Ref, SecondPid} =
        start_blocked(Ledger, <<"worker-crash">>),
    try
        WorkerMonitor = erlang:monitor(process, SecondPid),
        exit(SecondPid, kill),
        receive {'DOWN', WorkerMonitor, process, SecondPid, killed} -> ok
        after 1000 -> ?assert(false)
        end,
        ?assertMatch({failed, {step_failed, <<"second">>, _}, _},
                     adk_workflow:await(Ref, 2000)),
        {ok, Failed} = status(InvocationId, Ledger),
        ?assertEqual(failed, maps:get(phase, Failed)),
        assert_second_checkpoint(Failed),

        ets:insert(Table, {allow_second, true}),
        {ok, Resumed} = adk_workflow:resume_invocation(
                          InvocationId, Compiled, opts(Ledger)),
        ?assertMatch({completed, _, _},
                     adk_workflow:await(Resumed, 2000)),
        ?assertEqual(1, ets:lookup_element(Table, first_calls, 2)),
        ?assertEqual(1, ets:lookup_element(Table, second_calls, 2))
    after
        cleanup_invocation(InvocationId, Ledger),
        ets:delete(Table)
    end.

concurrent_resume_has_one_fenced_owner(Ledger) ->
    {Table, Compiled, InvocationId, Ref, SecondPid} =
        start_blocked(Ledger, <<"concurrent-claim">>),
    try
        RefMonitor = erlang:monitor(process, Ref),
        exit(Ref, kill),
        receive {'DOWN', RefMonitor, process, Ref, killed} -> ok
        after 1000 -> ?assert(false)
        end,
        await_dead(SecondPid),
        Parent = self(),
        Gate = make_ref(),
        Starters =
            [spawn(fun() ->
                       receive Gate -> ok end,
                       Parent ! {resume_result, self(),
                                 adk_workflow:resume_invocation(
                                   InvocationId, Compiled, opts(Ledger))}
                   end) || _ <- lists:seq(1, 2)],
        [Pid ! Gate || Pid <- Starters],
        Results = collect_resume_results(2, []),
        Winners = [Winner || {ok, Winner} <- Results],
        Losers = [Reason || {error, Reason} <- Results],
        ?assertEqual(1, length(Winners)),
        ?assertEqual(1, length(Losers)),
        ?assert(lists:all(fun is_invocation_owned_error/1, Losers)),
        [Winner] = Winners,
        WinnerSecond = receive
            {durable_second_started, Table, Pid, Context} ->
                assert_invocation_context(InvocationId, Context),
                Pid
        after 1000 -> ?assert(false)
        end,
        WinnerSecond ! continue,
        ?assertMatch({completed, _, _},
                     adk_workflow:await(Winner, 2000)),
        ?assertEqual(1, ets:lookup_element(Table, first_calls, 2))
    after
        cleanup_invocation(InvocationId, Ledger),
        ets:delete(Table)
    end.

application_restart_resumes_by_invocation_id(Ledger) ->
    {Table, Compiled, InvocationId, _Ref, SecondPid} =
        start_blocked(Ledger, <<"application-restart">>),
    try
        SecondMonitor = erlang:monitor(process, SecondPid),
        ok = application:stop(erlang_adk),
        receive {'DOWN', SecondMonitor, process, SecondPid, _} -> ok
        after 2000 -> ?assert(false)
        end,
        %% Restart the durable backend as well. The disc_copies record, not a
        %% surviving ETS/process owner, is the recovery source.
        ok = application:stop(mnesia),
        {ok, RestartedLedger} =
            adk_invocation_ledger_mnesia:init(#{table => ?TABLE}),
        {ok, _} = application:ensure_all_started(erlang_adk),
        ets:insert(Table, {allow_second, true}),
        {ok, Resumed} = adk_workflow:resume_invocation(
                          InvocationId, Compiled, opts(RestartedLedger)),
        ?assertMatch({completed, _, _},
                     adk_workflow:await(Resumed, 2000)),
        ?assertEqual(1, ets:lookup_element(Table, first_calls, 2)),
        {ok, Final} = status(InvocationId, RestartedLedger),
        ?assertEqual(completed, maps:get(phase, Final))
    after
        _ = application:ensure_all_started(erlang_adk),
        cleanup_invocation(InvocationId, Ledger),
        ets:delete(Table)
    end.

durable_graph_pause_consumes_resume_input(Ledger) ->
    Table = ets:new(durable_graph_pause_counter, [set, public]),
    true = ets:insert(Table, {pause_calls, 0}),
    Parent = self(),
    InvocationId = <<"inv-test-durable-graph-pause">>,
    Route = fun(_State, Context) ->
        Parent ! {durable_resume_input_seen,
                  maps:get(input, Context)},
        end_node
    end,
    Spec = #{version => 1,
             id => <<"durable-graph-pause">>,
             kind => graph,
             entry => <<"pause">>,
             max_steps => 3,
             nodes => [
                 #{id => <<"pause">>, type => action,
                   run => {adk_durable_workflow_test_actions, pause,
                           [Table, Parent]}}
             ],
             edges => #{<<"pause">> => {route, Route}}},
    {ok, Compiled} = adk_workflow:compile(Spec),
    try
        {ok, InvocationId, Ref} = adk_workflow:start_invocation(
                                    Compiled, #{},
                                    (opts(Ledger))#{
                                      invocation_id => InvocationId}),
        {paused, Pause, PauseCheckpoint} =
            adk_workflow:await(Ref, 1000),
        ?assertEqual(<<"pause">>, maps:get(<<"node_id">>, Pause)),
        ?assertEqual(<<"awaiting_resume">>,
                     maps:get(<<"phase">>,
                              maps:get(<<"cursor">>, PauseCheckpoint))),
        receive
            {durable_pause_started, Table, 1, PauseContext} ->
                assert_invocation_context(InvocationId, PauseContext)
        after 1000 -> ?assert(false)
        end,
        ?assertEqual(
           {error, resume_input_required},
           adk_workflow:resume_invocation(
             InvocationId, Compiled, opts(Ledger))),
        {ok, PausedRecord} = status(InvocationId, Ledger),
        ?assertEqual(paused, maps:get(phase, PausedRecord)),
        ?assertEqual(false, maps:get(owned, PausedRecord)),

        ResumeInput = #{<<"answer">> => <<"yes">>},
        {ok, Resumed} = adk_workflow:resume_invocation(
                          InvocationId, Compiled,
                          (opts(Ledger))#{resume_input => ResumeInput}),
        ?assertMatch({completed, _, _},
                     adk_workflow:await(Resumed, 1000)),
        receive
            {durable_resume_input_seen, ResumeInput} -> ok
        after 1000 -> ?assert(false)
        end,
        ?assertEqual(1, ets:lookup_element(Table, pause_calls, 2)),
        {ok, CompleteRecord} = status(InvocationId, Ledger),
        ?assertEqual(completed, maps:get(phase, CompleteRecord))
    after
        cleanup_invocation(InvocationId, Ledger),
        ets:delete(Table)
    end.

stale_fencing_token_cannot_commit(Ledger) ->
    InvocationId = <<"inv-test-fencing">>,
    Module = adk_invocation_ledger_mnesia,
    Metadata = #{workflow_id => <<"fencing-workflow">>,
                 workflow_version => 1,
                 kind => sequential},
    Checkpoint0 = #{<<"revision">> => 0},
    Checkpoint1 = #{<<"revision">> => 1},
    Token1 = crypto:strong_rand_bytes(32),
    Token2 = crypto:strong_rand_bytes(32),
    Owner1 = spawn(fun() -> receive stop -> ok end end),
    try
        ok = Module:create(Ledger, InvocationId, Metadata, Checkpoint0),
        Now = erlang:system_time(millisecond),
        {ok, _} = Module:claim(Ledger, InvocationId, Owner1, Token1,
                               Now, 10000),
        OwnerMonitor = erlang:monitor(process, Owner1),
        exit(Owner1, kill),
        receive {'DOWN', OwnerMonitor, process, Owner1, killed} -> ok
        after 1000 -> ?assert(false)
        end,
        {ok, _} = Module:claim(Ledger, InvocationId, self(), Token2,
                               Now + 1, 10000),
        ?assertEqual(
           {error, stale_owner},
           Module:checkpoint(Ledger, InvocationId, Token1, Checkpoint1,
                             Now + 2, 10000)),
        ?assertEqual(
           {error, stale_owner},
           Module:finish(Ledger, InvocationId, Token1, failed,
                         stale_result, Checkpoint1, Now + 2)),
        ok = Module:finish(Ledger, InvocationId, Token2, failed,
                           test_complete, Checkpoint1, Now + 3),
        {ok, Final} = Module:get(Ledger, InvocationId),
        ?assertEqual(Checkpoint1, maps:get(checkpoint, Final)),
        ?assertEqual(false, maps:get(owned, Final))
    after
        case erlang:is_process_alive(Owner1) of
            true -> exit(Owner1, kill);
            false -> ok
        end,
        _ = Module:delete(Ledger, InvocationId)
    end.

active_coordinator_renews_lease(Ledger) ->
    {Table, _Compiled, InvocationId, Ref, _SecondPid} =
        start_blocked(Ledger, <<"lease-renewal">>),
    try
        {ok, Before} = status(InvocationId, Ledger),
        After = await_new_revision(InvocationId, Ledger,
                                   maps:get(revision, Before), 100),
        ?assert(maps:get(lease_until, After) >
                maps:get(lease_until, Before)),
        ?assert(maps:get(revision, After) > maps:get(revision, Before)),
        ok = adk_workflow:cancel(Ref, lease_test_complete),
        ?assertMatch({cancelled, lease_test_complete, _},
                     adk_workflow:await(Ref, 1000))
    after
        cleanup_invocation(InvocationId, Ledger),
        ets:delete(Table)
    end.

expired_owner_cannot_write_without_takeover(Ledger) ->
    Module = adk_invocation_ledger_mnesia,
    InvocationId = <<"inv-test-expired-write-fence">>,
    Checkpoint0 = #{<<"revision">> => 0},
    Checkpoint1 = #{<<"revision">> => 1},
    Token = crypto:strong_rand_bytes(32),
    Now = 1000000,
    LeaseMs = 10,
    try
        ok = Module:create(Ledger, InvocationId, ledger_metadata(),
                           Checkpoint0),
        {ok, Claimed} = Module:claim(
                          Ledger, InvocationId, self(), Token, Now, LeaseMs),
        Revision = maps:get(revision, Claimed),
        LeaseUntil = Now + LeaseMs,
        %% Equality is expired.  Lack of a replacement claimant does not let
        %% this token revive itself or commit after its fencing deadline.
        ?assertEqual(
           {error, lease_expired},
           Module:renew(Ledger, InvocationId, Token,
                        LeaseUntil, LeaseMs)),
        ?assertEqual(
           {error, lease_expired},
           Module:checkpoint(Ledger, InvocationId, Token, Checkpoint1,
                             LeaseUntil, LeaseMs)),
        ?assertEqual(
           {error, lease_expired},
           Module:finish(Ledger, InvocationId, Token, completed,
                         should_not_commit, Checkpoint1, LeaseUntil)),
        {ok, Unchanged} = Module:get(Ledger, InvocationId),
        ?assertEqual(running, maps:get(phase, Unchanged)),
        ?assertEqual(Checkpoint0, maps:get(checkpoint, Unchanged)),
        ?assertEqual(Revision, maps:get(revision, Unchanged)),
        ?assertEqual(LeaseUntil, maps:get(lease_until, Unchanged))
    after
        _ = Module:delete(Ledger, InvocationId)
    end.

expired_live_local_owner_is_claimable(Ledger) ->
    Module = adk_invocation_ledger_mnesia,
    InvocationId = <<"inv-test-expired-live-owner">>,
    Checkpoint = #{<<"revision">> => 0},
    Token1 = crypto:strong_rand_bytes(32),
    Token2 = crypto:strong_rand_bytes(32),
    Owner1 = live_owner(),
    Now = 2000000,
    LeaseMs = 10,
    try
        ok = Module:create(Ledger, InvocationId, ledger_metadata(),
                           Checkpoint),
        {ok, _} = Module:claim(
                    Ledger, InvocationId, Owner1, Token1, Now, LeaseMs),
        ?assert(erlang:is_process_alive(Owner1)),
        ?assertEqual(
           {error, invocation_owned},
           Module:claim(Ledger, InvocationId, self(), Token2,
                        Now + LeaseMs - 1, 30)),
        {ok, Claimed2} = Module:claim(
                           Ledger, InvocationId, self(), Token2,
                           Now + LeaseMs, 30),
        ?assertEqual(Now + LeaseMs + 30,
                     maps:get(lease_until, Claimed2)),
        ?assertEqual(
           {error, stale_owner},
           Module:renew(Ledger, InvocationId, Token1,
                        Now + LeaseMs + 1, 30)),
        ok = Module:finish(Ledger, InvocationId, Token2, completed,
                           claimed_after_expiry, Checkpoint,
                           Now + LeaseMs + 1)
    after
        Owner1 ! stop,
        _ = Module:delete(Ledger, InvocationId)
    end.

concurrent_expiry_claim_has_single_winner(Ledger) ->
    Module = adk_invocation_ledger_mnesia,
    InvocationId = <<"inv-test-concurrent-expiry-claim">>,
    Checkpoint = #{<<"revision">> => 0},
    Token0 = crypto:strong_rand_bytes(32),
    Owner0 = live_owner(),
    Now = 3000000,
    LeaseMs = 10,
    Parent = self(),
    Gate = make_ref(),
    Contenders =
        [spawn(fun() ->
                   Token = crypto:strong_rand_bytes(32),
                   receive
                       Gate ->
                           Result = Module:claim(
                                      Ledger, InvocationId, self(), Token,
                                      Now + LeaseMs, 100),
                           Parent ! {expiry_claim_result, self(), Token,
                                     Result},
                           receive stop -> ok end;
                       stop -> ok
                   end
               end) || _ <- lists:seq(1, 2)],
    try
        ok = Module:create(Ledger, InvocationId, ledger_metadata(),
                           Checkpoint),
        {ok, _} = Module:claim(
                    Ledger, InvocationId, Owner0, Token0, Now, LeaseMs),
        [Pid ! Gate || Pid <- Contenders],
        Results = collect_expiry_claim_results(2, []),
        Winners = [{Pid, Token, Record}
                   || {Pid, Token, {ok, Record}} <- Results],
        Losers = [Reason || {_Pid, _Token, {error, Reason}} <- Results],
        ?assertEqual(1, length(Winners)),
        ?assertEqual([invocation_owned], Losers),
        [{_WinnerPid, WinnerToken, _}] = Winners,
        ok = Module:finish(
               Ledger, InvocationId, WinnerToken, completed,
               concurrent_claim_complete, Checkpoint, Now + LeaseMs + 1)
    after
        [Pid ! stop || Pid <- Contenders],
        Owner0 ! stop,
        _ = Module:delete(Ledger, InvocationId)
    end.

ledger_restart_preserves_expiry_fence(Ledger) ->
    Module = adk_invocation_ledger_mnesia,
    InvocationId = <<"inv-test-ledger-restart-expiry">>,
    Checkpoint0 = #{<<"revision">> => 0},
    Checkpoint1 = #{<<"revision">> => 1},
    Token1 = crypto:strong_rand_bytes(32),
    Token2 = crypto:strong_rand_bytes(32),
    Owner1 = live_owner(),
    Now = 4000000,
    LeaseMs = 10,
    try
        ok = Module:create(Ledger, InvocationId, ledger_metadata(),
                           Checkpoint0),
        {ok, _} = Module:claim(
                    Ledger, InvocationId, Owner1, Token1, Now, LeaseMs),
        ok = Module:checkpoint(Ledger, InvocationId, Token1, Checkpoint1,
                               Now + 5, LeaseMs),
        LeaseUntil = Now + 5 + LeaseMs,
        ok = application:stop(mnesia),
        {ok, RestartedLedger} = Module:init(#{table => ?TABLE}),
        {ok, Recovered} = Module:get(RestartedLedger, InvocationId),
        ?assertEqual(Checkpoint1, maps:get(checkpoint, Recovered)),
        ?assertEqual(LeaseUntil, maps:get(lease_until, Recovered)),
        ?assert(erlang:is_process_alive(Owner1)),
        ?assertEqual(
           {error, lease_expired},
           Module:finish(RestartedLedger, InvocationId, Token1, completed,
                         expired_after_restart, Checkpoint1, LeaseUntil)),
        {ok, _} = Module:claim(
                    RestartedLedger, InvocationId, self(), Token2,
                    LeaseUntil, LeaseMs),
        ?assertEqual(
           {error, stale_owner},
           Module:checkpoint(RestartedLedger, InvocationId, Token1,
                             Checkpoint0, LeaseUntil + 1, LeaseMs)),
        ok = Module:finish(
               RestartedLedger, InvocationId, Token2, completed,
               recovered, Checkpoint1, LeaseUntil + 1),
        {ok, Final} = Module:get(RestartedLedger, InvocationId),
        ?assertEqual(completed, maps:get(phase, Final)),
        ?assertEqual(Checkpoint1, maps:get(checkpoint, Final))
    after
        Owner1 ! stop,
        _ = application:ensure_all_started(mnesia),
        _ = Module:delete(Ledger, InvocationId)
    end.

start_blocked(Ledger, Suffix) ->
    Table = ets:new(durable_workflow_counter, [set, public]),
    true = ets:insert(Table, [{first_calls, 0}, {second_calls, 0},
                              {allow_second, false}]),
    Parent = self(),
    WorkflowId = <<"durable-workflow-", Suffix/binary>>,
    InvocationId = <<"inv-test-", Suffix/binary>>,
    Spec = #{version => 1,
             id => WorkflowId,
             kind => sequential,
             max_steps => 4,
             steps => [
                 #{id => <<"first">>,
                   run => {adk_durable_workflow_test_actions, first,
                           [Table, Parent]}},
                 #{id => <<"second">>,
                   run => {adk_durable_workflow_test_actions, second,
                           [Table, Parent]}}
             ]},
    {ok, Compiled} = adk_workflow:compile(Spec),
    {ok, InvocationId, Ref} = adk_workflow:start_invocation(
                                Compiled, #{},
                                (opts(Ledger))#{invocation_id => InvocationId}),
    receive
        {durable_first_finished, Table, _FirstPid, 1, Context1} ->
            assert_invocation_context(InvocationId, Context1)
    after 1000 -> ?assert(false)
    end,
    SecondPid = receive
        {durable_second_started, Table, Pid, Context2} ->
            assert_invocation_context(InvocationId, Context2),
            Pid
    after 1000 -> ?assert(false)
    end,
    {Table, Compiled, InvocationId, Ref, SecondPid}.

opts(Ledger) ->
    #{ledger => {adk_invocation_ledger_mnesia, Ledger},
      lease_ms => 300,
      timeout => 5000,
      retention_ms => 100}.

status(InvocationId, Ledger) ->
    adk_workflow:invocation_status(InvocationId, opts(Ledger)).

assert_second_checkpoint(Record) ->
    Checkpoint = maps:get(checkpoint, Record),
    Cursor = maps:get(<<"cursor">>, Checkpoint),
    ?assertEqual(2, maps:get(<<"next_index">>, Cursor)),
    ?assertEqual(true,
                 maps:get(<<"first_committed">>,
                          maps:get(<<"state">>, Checkpoint))).

assert_invocation_context(InvocationId, Context) ->
    ?assertEqual(InvocationId, maps:get(invocation_id, Context)),
    ?assert(is_map(maps:get(checkpoint_cursor, Context))).

collect_resume_results(0, Acc) -> lists:reverse(Acc);
collect_resume_results(Remaining, Acc) ->
    receive
        {resume_result, _Pid, Result} ->
            collect_resume_results(Remaining - 1, [Result | Acc])
    after 2000 ->
        erlang:error(resume_results_timeout)
    end.

collect_expiry_claim_results(0, Acc) -> lists:reverse(Acc);
collect_expiry_claim_results(Remaining, Acc) ->
    receive
        {expiry_claim_result, Pid, Token, Result} ->
            collect_expiry_claim_results(
              Remaining - 1, [{Pid, Token, Result} | Acc])
    after 2000 ->
        erlang:error(expiry_claim_results_timeout)
    end.

ledger_metadata() ->
    #{workflow_id => <<"lease-workflow">>,
      workflow_version => 1,
      kind => sequential}.

live_owner() ->
    spawn(fun() ->
              receive stop -> ok end
          end).

await_dead(Pid) ->
    case erlang:is_process_alive(Pid) of
        false -> ok;
        true ->
            Monitor = erlang:monitor(process, Pid),
            receive {'DOWN', Monitor, process, Pid, _} -> ok
            after 1000 -> ?assert(false)
            end
    end.

cleanup_invocation(InvocationId, Ledger) ->
    case adk_workflow:delete_invocation(InvocationId, opts(Ledger)) of
        ok -> ok;
        {error, not_found} -> ok;
        {error, invocation_owned} ->
            receive after 150 -> ok end,
            _ = adk_workflow:delete_invocation(InvocationId, opts(Ledger)),
            ok
    end.

await_new_revision(_InvocationId, _Ledger, _Revision, 0) ->
    erlang:error(lease_was_not_renewed);
await_new_revision(InvocationId, Ledger, Revision, Attempts) ->
    {ok, Current} = status(InvocationId, Ledger),
    case maps:get(revision, Current) > Revision of
        true -> Current;
        false ->
            receive after 10 -> ok end,
            await_new_revision(InvocationId, Ledger, Revision,
                               Attempts - 1)
    end.

is_invocation_owned_error({workflow_start_failed, invocation_owned}) -> true;
is_invocation_owned_error(
  {workflow_start_failed, {invocation_owned, _Child}}) -> true;
is_invocation_owned_error(_) -> false.
