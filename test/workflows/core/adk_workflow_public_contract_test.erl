-module(adk_workflow_public_contract_test).
-include_lib("eunit/include/eunit.hrl").

public_workflow_contract_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun public_argument_validation_case/0,
      fun json_decoded_workflow_kinds_case/0,
      fun compile_error_contracts_case/0,
      fun cancellation_and_call_failure_contracts_case/0,
      fun checkpoint_validation_and_resume_case/0,
      fun pause_resume_input_contract_case/0,
      fun durable_option_and_identifier_contracts_case/0,
      fun durable_query_reply_contracts_case/0,
      fun durable_resume_record_contracts_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok.

cleanup(_Setup) ->
    ok.

public_argument_validation_case() ->
    Compiled = simple_workflow(<<"public-arguments">>),
    ?assertEqual(
       {error, {invalid_workflow, [], expected_map}},
       adk_workflow:compile(not_a_map)),
    ?assertEqual({error, invalid_compiled_workflow},
                 adk_workflow:start(#{}, #{})),
    ?assertEqual({error, invalid_start_arguments},
                 adk_workflow:start(Compiled, not_a_map)),
    ?assertEqual({error, invalid_start_arguments},
                 adk_workflow:start(Compiled, #{}, not_a_map)),
    ?assertEqual({error, invalid_compiled_workflow},
                 adk_workflow:run(#{}, #{})),
    ?assertEqual({error, invalid_await_arguments},
                 adk_workflow:await(not_a_pid)),
    ?assertEqual({error, invalid_await_arguments},
                 adk_workflow:await(self(), -1)),
    ?assertEqual({error, invalid_await_arguments},
                 adk_workflow:await(self(), bad_timeout)),
    ?assertEqual({error, invalid_workflow_ref},
                 adk_workflow:cancel(not_a_pid)),
    ?assertEqual({error, invalid_workflow_ref},
                 adk_workflow:status(not_a_pid)),
    ?assertEqual({error, invalid_workflow_ref},
                 adk_workflow:checkpoint(not_a_pid)),
    ?assertEqual({error, invalid_resume_arguments},
                 adk_workflow:resume(Compiled, #{}, not_a_map)),
    ?assertEqual({error, invalid_start_invocation_arguments},
                 adk_workflow:start_invocation(Compiled, not_a_map, #{})).

json_decoded_workflow_kinds_case() ->
    Action = fun(_State) -> {ok, #{}} end,
    Predicate = fun(_State) -> true end,
    Specs =
        [#{<<"version">> => 1,
           <<"id">> => <<"binary-sequential">>,
           <<"kind">> => <<"sequential">>,
           <<"steps">> => [#{<<"id">> => <<"step">>,
                              <<"run">> => Action}]},
         #{<<"version">> => 1,
           <<"id">> => <<"binary-parallel">>,
           <<"kind">> => <<"parallel">>,
           <<"branches">> => [#{<<"id">> => <<"branch">>,
                                 <<"run">> => Action}]},
         #{<<"version">> => 1,
           <<"id">> => <<"binary-loop">>,
           <<"kind">> => <<"loop">>,
           <<"body">> => Action,
           <<"until">> => Predicate,
           <<"max_iterations">> => 0},
         #{<<"version">> => 1,
           <<"id">> => <<"binary-transfer">>,
           <<"kind">> => <<"transfer">>,
           <<"entry">> => <<"member">>,
           <<"members">> =>
               #{<<"member">> => #{<<"run">> => Action}}},
         #{<<"version">> => 1,
           <<"id">> => <<"binary-graph">>,
           <<"kind">> => <<"graph">>,
           <<"entry">> => <<"node">>,
           <<"nodes">> => [#{<<"id">> => <<"node">>,
                              <<"run">> => Action}],
           <<"edges">> => #{<<"node">> => end_node}}],
    lists:foreach(
      fun(Spec) ->
          ?assertMatch({ok, _}, adk_workflow:compile(Spec))
      end, Specs).

compile_error_contracts_case() ->
    Action = fun(_State) -> {ok, #{}} end,
    ?assertEqual(
       {error, {invalid_workflow, [id], expected_nonempty_utf8_binary}},
       adk_workflow:compile(#{version => 1, kind => sequential,
                              steps => []})),
    ?assertEqual(
       {error, {invalid_workflow, [kind], unsupported_kind}},
       adk_workflow:compile(#{version => 1, id => <<"bad-kind">>,
                              kind => unsupported})),
    ?assertEqual(
       {error, {invalid_workflow, [version], unsupported_version}},
       adk_workflow:compile(#{version => 2, id => <<"bad-version">>,
                              kind => sequential, steps => []})),
    ?assertEqual(
       {error, {invalid_workflow, [steps], empty}},
       adk_workflow:compile(spec(<<"empty-sequential">>, sequential,
                                 #{steps => []}))),
    ?assertEqual(
       {error, {invalid_workflow, [steps], expected_list}},
       adk_workflow:compile(spec(<<"bad-sequential">>, sequential,
                                 #{steps => not_a_list}))),
    ?assertEqual(
       {error, {invalid_workflow, [merge], invalid_merge_policy}},
       adk_workflow:compile(spec(<<"bad-merge">>, parallel,
                                 #{branches => [step(<<"branch">>, Action)],
                                   merge => unsupported}))),
    ?assertEqual(
       {error, {invalid_workflow, [max_concurrency],
                expected_positive_integer}},
       adk_workflow:compile(spec(<<"bad-concurrency">>, parallel,
                                 #{branches => [step(<<"branch">>, Action)],
                                   max_concurrency => 0}))),
    ?assertEqual(
       {error, {invalid_workflow, [body], invalid_action}},
       adk_workflow:compile(spec(<<"bad-loop-body">>, loop,
                                 #{body => bad_action,
                                   until => fun(_) -> true end,
                                   max_iterations => 1}))),
    ?assertEqual(
       {error, {invalid_workflow, [until], invalid_predicate}},
       adk_workflow:compile(spec(<<"bad-loop-predicate">>, loop,
                                 #{body => Action, until => bad_predicate,
                                   max_iterations => 1}))),
    ?assertEqual(
       {error, {invalid_workflow, [max_iterations],
                expected_non_negative_integer}},
       adk_workflow:compile(spec(<<"bad-loop-limit">>, loop,
                                 #{body => Action,
                                   until => fun(_) -> true end,
                                   max_iterations => -1}))),
    ?assertEqual(
       {error, {invalid_workflow, [members], empty}},
       adk_workflow:compile(spec(<<"empty-transfer">>, transfer,
                                 #{entry => <<"member">>, members => #{}}))),
    ?assertEqual(
       {error, {invalid_workflow, [entry], unknown_transfer_entry}},
       adk_workflow:compile(spec(<<"bad-transfer-entry">>, transfer,
                                 #{entry => <<"missing">>,
                                   members =>
                                       #{<<"member">> =>
                                             #{run => Action}}}))),
    ?assertEqual(
       {error, {invalid_workflow, [max_transfers],
                expected_non_negative_integer}},
       adk_workflow:compile(spec(<<"bad-transfer-limit">>, transfer,
                                 #{entry => <<"member">>,
                                   members =>
                                       #{<<"member">> =>
                                             #{run => Action}},
                                   max_transfers => -1}))),
    ?assertEqual(
       {error, {invalid_workflow, [nodes], expected_list}},
       adk_workflow:compile(spec(<<"bad-graph-nodes">>, graph,
                                 #{entry => <<"node">>, nodes => bad,
                                   edges => #{}}))),
    ?assertMatch(
       {error, {invalid_workflow, [input_schema],
                {invalid_json_schema, _, _}}},
       adk_workflow:compile(
         spec(<<"bad-input-schema">>, sequential,
              #{input_schema => #{<<"unsupported">> => true},
                steps => [step(<<"step">>, Action)]}))).

cancellation_and_call_failure_contracts_case() ->
    Parent = self(),
    Block = fun(_State) ->
        Parent ! {workflow_contract_blocked, self()},
        receive continue -> {ok, #{<<"continued">> => true}} end
    end,
    Compiled = compile_ok(
                 spec(<<"cancel-contract">>, sequential,
                      #{steps => [step(<<"block">>, Block)]})),
    {ok, Ref} = adk_workflow:start(Compiled, #{}, #{retention_ms => 100}),
    receive {workflow_contract_blocked, _Worker} -> ok
    after 1000 -> error(workflow_did_not_start)
    end,
    {ok, Running} = adk_workflow:status(Ref),
    ?assertEqual(running, maps:get(state, Running)),
    {ok, RunningCheckpoint} = adk_workflow:checkpoint(Ref),
    ?assertEqual(false, maps:get(<<"completed">>, RunningCheckpoint)),
    ok = adk_workflow:cancel(Ref),
    ?assertMatch({cancelled, user_cancelled, _}, adk_workflow:await(Ref)),

    Dead = spawn(fun() -> ok end),
    DeadMonitor = erlang:monitor(process, Dead),
    receive {'DOWN', DeadMonitor, process, Dead, _} -> ok
    after 1000 -> error(fake_process_did_not_stop)
    end,
    ?assertEqual({error, not_found}, adk_workflow:await(Dead, 10)),
    ?assertEqual({error, not_found}, adk_workflow:cancel(Dead)),
    ?assertEqual({error, not_found}, adk_workflow:status(Dead)),
    ?assertEqual({error, not_found}, adk_workflow:checkpoint(Dead)),

    Slow = spawn(fun hold/0),
    try
        ?assertEqual({error, timeout}, adk_workflow:await(Slow, 0))
    after
        exit(Slow, kill)
    end.

checkpoint_validation_and_resume_case() ->
    Compiled = simple_workflow(<<"checkpoint-contract">>),
    Checkpoint = resumable_checkpoint(Compiled),
    ?assertEqual({error, invalid_compiled_workflow},
                 adk_workflow:resume(#{}, Checkpoint)),
    ?assertEqual({error, invalid_checkpoint},
                 adk_workflow:resume(Compiled, not_a_checkpoint)),
    ?assertEqual(
       {error, checkpoint_workflow_mismatch},
       adk_workflow:resume(
         Compiled, Checkpoint#{<<"workflow_id">> => <<"other">>})),
    ?assertEqual(
       {error, checkpoint_complete},
       adk_workflow:resume(
         Compiled, Checkpoint#{<<"completed">> => true})),
    ?assertEqual(
       {error, invalid_checkpoint},
       adk_workflow:resume(Compiled, maps:remove(<<"completed">>,
                                                  Checkpoint))),
    ?assertEqual(
       {error, invalid_checkpoint_state},
       adk_workflow:resume(
         Compiled, Checkpoint#{<<"state">> => #{atom_key => true}})),
    ?assertEqual(
       {error, invalid_checkpoint_state},
       adk_workflow:resume(
         Compiled, Checkpoint#{<<"state">> => #{<<"pid">> => self()}})),
    ?assertEqual(
       {error, invalid_checkpoint},
       adk_workflow:resume(
         Compiled,
         Checkpoint#{<<"cursor">> =>
                         #{<<"type">> => <<"sequential">>,
                           <<"next_index">> => 99}})),
    {ok, Ref} = adk_workflow:resume(Compiled, Checkpoint,
                                    #{retention_ms => 100}),
    ?assertMatch({completed, _, _}, adk_workflow:await(Ref, 1000)).

pause_resume_input_contract_case() ->
    Pause = fun(_State) ->
        {pause, approval, <<"Approve the workflow">>,
         #{<<"approval_requested">> => true}}
    end,
    Compiled = compile_ok(
                 spec(<<"pause-resume-contract">>, graph,
                      #{entry => <<"pause">>,
                        nodes => [step(<<"pause">>, Pause)],
                        edges => #{<<"pause">> => end_node},
                        max_steps => 2})),
    {paused, Details, Checkpoint} =
        adk_workflow:run(Compiled, #{}, #{retention_ms => 100}),
    ?assertEqual(<<"approval">>, maps:get(<<"reason">>, Details)),
    ?assertEqual({error, resume_input_required},
                 adk_workflow:resume(Compiled, Checkpoint)),
    ?assertMatch(
       {error, {invalid_resume_input, {adk_failure, _}}},
       adk_workflow:resume(Compiled, Checkpoint,
                           #{resume_input => self()})),
    {ok, Ref} = adk_workflow:resume(
                  Compiled, Checkpoint,
                  #{resume_input => #{<<"approved">> => true},
                    retention_ms => 100}),
    ?assertMatch({completed, _, _}, adk_workflow:await(Ref, 1000)).

durable_option_and_identifier_contracts_case() ->
    Compiled = simple_workflow(<<"durable-options-contract">>),
    ValidLedger = ledger(#{}),
    ?assertEqual({error, invalid_compiled_workflow},
                 adk_workflow:start_invocation(#{}, #{}, #{})),
    ?assertEqual({error, durable_invocation_ledger_required},
                 adk_workflow:start_invocation(Compiled, #{}, #{})),
    ?assertEqual(
       {error, {invalid_invocation_id, invalid_id}},
       adk_workflow:start_invocation(
         Compiled, #{}, ValidLedger#{invocation_id => invalid_id})),
    ?assertEqual({error, invalid_compiled_workflow},
                 adk_workflow:resume_invocation(<<"inv">>, #{},
                                                ValidLedger)),
    ?assertEqual({error, durable_invocation_ledger_required},
                 adk_workflow:resume_invocation(<<"inv">>, Compiled, #{})),
    ?assertEqual(
       {error, {invalid_invocation_id, invalid_id}},
       adk_workflow:resume_invocation(invalid_id, Compiled, ValidLedger)),
    ?assertEqual({error, durable_invocation_ledger_required},
                 adk_workflow:invocation_status(<<"inv">>, #{})),
    ?assertEqual(
       {error, {invalid_invocation_id, invalid_id}},
       adk_workflow:invocation_status(invalid_id, ValidLedger)),
    ?assertEqual({error, durable_invocation_ledger_required},
                 adk_workflow:delete_invocation(<<"inv">>, #{})),
    ?assertEqual(
       {error, {invalid_invocation_id, invalid_id}},
       adk_workflow:delete_invocation(invalid_id, ValidLedger)),
    ?assertEqual(
       {error, {invalid_invocation_ledger, lists}},
       adk_workflow:invocation_status(
         <<"inv">>, #{ledger => {lists, ignored}})),
    ?assertEqual(
       {error, {invalid_invocation_ledger,
                adk_workflow_missing_ledger}},
       adk_workflow:invocation_status(
         <<"inv">>,
         #{ledger => {adk_workflow_missing_ledger, ignored}})),
    ?assertMatch(
       {error, {invalid_lease_ms, {adk_failure, _}}},
       adk_workflow:invocation_status(
         <<"inv">>, ValidLedger#{lease_ms => 0})),
    ?assertMatch(
       {error, {invalid_invocation_ledger, {adk_failure, _}}},
       adk_workflow:invocation_status(
         <<"inv">>, #{ledger => {invalid, ledger, shape}})).

durable_query_reply_contracts_case() ->
    InvocationId = <<"inv-query-contract">>,
    PublicRecord = #{invocation_id => InvocationId,
                     workflow_id => <<"query-contract">>,
                     workflow_version => 1,
                     kind => sequential,
                     checkpoint => #{},
                     phase => running,
                     outcome => undefined,
                     owned => true,
                     owner_node => node(),
                     lease_until => 10,
                     revision => 2,
                     created_at => 1,
                     updated_at => 2,
                     owner_token => <<"must-not-leak">>,
                     private_metadata => self()},
    {ok, Visible} = adk_workflow:invocation_status(
                      InvocationId, ledger(#{get => {ok, PublicRecord}})),
    ?assertEqual(InvocationId, maps:get(invocation_id, Visible)),
    ?assertEqual(false, maps:is_key(owner_token, Visible)),
    ?assertEqual(false, maps:is_key(private_metadata, Visible)),
    ?assertEqual({error, upstream_down},
                 adk_workflow:invocation_status(
                   InvocationId,
                   ledger(#{get => {error, upstream_down}}))),
    ?assertMatch(
       {error, {invalid_ledger_reply, get, {adk_failure, _}}},
       adk_workflow:invocation_status(
         InvocationId, ledger(#{get => {unexpected, reply}}))),
    ?assertMatch(
       {error, {adk_failure, _}},
       adk_workflow:invocation_status(
         InvocationId, ledger(#{get => {raise, ledger_crashed}}))),
    ?assertEqual(ok,
                 adk_workflow:delete_invocation(
                   InvocationId, ledger(#{delete => ok}))),
    ?assertEqual({error, invocation_owned},
                 adk_workflow:delete_invocation(
                   InvocationId,
                   ledger(#{delete => {error, invocation_owned}}))),
    ?assertMatch(
       {error, {invalid_ledger_reply, delete, {adk_failure, _}}},
       adk_workflow:delete_invocation(
         InvocationId, ledger(#{delete => {unexpected, reply}}))).

durable_resume_record_contracts_case() ->
    InvocationId = <<"inv-resume-contract">>,
    Compiled = simple_workflow(<<"durable-resume-contract">>),
    Checkpoint = resumable_checkpoint(Compiled),
    BaseRecord = #{workflow_id => <<"durable-resume-contract">>,
                   workflow_version => 1,
                   kind => sequential,
                   phase => paused,
                   checkpoint => Checkpoint},
    ?assertEqual(
       {error, upstream_down},
       adk_workflow:resume_invocation(
         InvocationId, Compiled,
         ledger(#{get => {error, upstream_down}}))),
    ?assertMatch(
       {error, {invalid_ledger_reply, get, {adk_failure, _}}},
       adk_workflow:resume_invocation(
         InvocationId, Compiled,
         ledger(#{get => {unexpected, reply}}))),
    ?assertEqual(
       {error, invocation_workflow_mismatch},
       adk_workflow:resume_invocation(
         InvocationId, Compiled,
         ledger(#{get => {ok, BaseRecord#{workflow_id => <<"other">>}}}))),
    ?assertEqual(
       {error, invocation_completed},
       adk_workflow:resume_invocation(
         InvocationId, Compiled,
         ledger(#{get => {ok, BaseRecord#{phase => completed}}}))),
    ?assertEqual(
       {error, invalid_durable_checkpoint},
       adk_workflow:resume_invocation(
         InvocationId, Compiled,
         ledger(#{get => {ok, BaseRecord#{checkpoint => invalid}}}))),
    ?assertEqual(
       {error, {invalid_durable_checkpoint,
                checkpoint_workflow_mismatch}},
       adk_workflow:resume_invocation(
         InvocationId, Compiled,
         ledger(#{get =>
                      {ok, BaseRecord#{checkpoint =>
                                           Checkpoint#{<<"workflow_id">> =>
                                                           <<"other">>}}}}))),
    ?assertEqual(
       {error, invocation_completed},
       adk_workflow:resume_invocation(
         InvocationId, Compiled,
         ledger(#{get =>
                      {ok, BaseRecord#{checkpoint =>
                                           Checkpoint#{<<"completed">> =>
                                                           true}}}}))),

    PauseCompiled = pause_workflow(<<"durable-paused-input-contract">>),
    {paused, _, PauseCheckpoint} =
        adk_workflow:run(PauseCompiled, #{}, #{retention_ms => 100}),
    PauseRecord = #{workflow_id => <<"durable-paused-input-contract">>,
                    workflow_version => 1,
                    kind => graph,
                    phase => paused,
                    checkpoint => PauseCheckpoint},
    ?assertEqual(
       {error, resume_input_required},
       adk_workflow:resume_invocation(
         InvocationId, PauseCompiled,
         ledger(#{get => {ok, PauseRecord}}))).

simple_workflow(Id) ->
    compile_ok(
      spec(Id, sequential,
           #{steps => [step(<<"complete">>,
                            fun(_State) ->
                                {ok, #{<<"completed">> => true}}
                            end)]})).

pause_workflow(Id) ->
    compile_ok(
      spec(Id, graph,
           #{entry => <<"pause">>,
             nodes =>
                 [step(<<"pause">>,
                       fun(_State) ->
                           {pause, approval, <<"Approve">>, #{}}
                       end)],
             edges => #{<<"pause">> => end_node},
             max_steps => 2})).

resumable_checkpoint(Compiled) ->
    #{<<"schema_version">> => 1,
      <<"workflow_id">> => maps:get(id, Compiled),
      <<"workflow_version">> => maps:get(version, Compiled),
      <<"kind">> => atom_to_binary(maps:get(kind, Compiled), utf8),
      <<"cursor">> => #{<<"type">> => <<"sequential">>,
                         <<"next_index">> => 1},
      <<"state">> => #{},
      <<"remaining">> => #{<<"steps">> => 2,
                              <<"transfers">> => 0},
      <<"completed">> => false}.

ledger(Handle) ->
    #{ledger => {adk_workflow_contract_ledger, Handle}, lease_ms => 1000}.

spec(Id, Kind, Fields) ->
    maps:merge(#{version => 1, id => Id, kind => Kind}, Fields).

step(Id, Run) ->
    #{id => Id, run => Run}.

compile_ok(Spec) ->
    {ok, Compiled} = adk_workflow:compile(Spec),
    Compiled.

hold() ->
    receive
        stop -> ok;
        _ -> hold()
    end.
