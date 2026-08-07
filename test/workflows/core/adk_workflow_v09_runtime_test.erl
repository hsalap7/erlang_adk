-module(adk_workflow_v09_runtime_test).
-include_lib("eunit/include/eunit.hrl").

workflow_v09_runtime_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun checkpoint_v2_binds_definition_and_runtime_state/0,
      fun checkpoint_v2_rejects_ambiguous_attempts_and_invalid_fork_failures/0,
      fun checkpoint_definition_mismatch_is_rejected/0,
      fun checkpoint_v1_is_migrated_on_resume/0,
      fun committed_resume_input_is_reused_and_cannot_change/0,
      fun lifecycle_receiver_observes_ordered_runtime_events/0,
      fun retry_attempts_are_persisted_in_checkpoint/0,
      fun in_flight_attempt_replay_keeps_budget_and_attempt_number/0,
      fun parallel_nested_pause_resumes_without_child_replay/0,
      fun loop_nested_pause_resumes_without_child_replay/0,
      fun transfer_nested_pause_resumes_without_child_replay/0,
      fun typed_tool_confirmation_can_be_approved_or_rejected/0,
      fun forked_tool_confirmation_resumes_exact_branch/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok.

cleanup(_Setup) ->
    persistent_term:erase({adk_tool_confirmation_test, target}),
    flush_tool_messages(),
    ok.

checkpoint_v2_binds_definition_and_runtime_state() ->
    Compiled = pausing_graph(<<"checkpoint-v2">>, 1),
    {paused, Details, Checkpoint} = adk_workflow:run(Compiled, #{}),
    ?assertEqual(<<"pause">>, maps:get(<<"node_id">>, Details)),
    assert_v2_checkpoint(Compiled, Checkpoint),
    ?assertEqual(false, maps:get(<<"completed">>, Checkpoint)),
    ?assertEqual(#{<<"pause">> => <<"paused">>},
                 maps:get(<<"node_status">>, Checkpoint)),
    ?assertEqual([], maps:get(<<"runnable">>, Checkpoint)),
    ?assertEqual([<<"pause">>], maps:get(<<"waiting">>, Checkpoint)),
    ?assertEqual([maps:get(<<"pause">>,
                           maps:get(<<"cursor">>, Checkpoint))],
                 maps:get(<<"interruptions">>, Checkpoint)),
    ?assertEqual({ok, #{<<"pause_committed">> => true}},
                 adk_workflow:validate_checkpoint(Compiled, Checkpoint)),
    Cursor = maps:get(<<"cursor">>, Checkpoint),
    Unsafe = Checkpoint#{<<"cursor">> =>
                            Cursor#{<<"unsafe">> => self()}},
    ?assertEqual({error, invalid_checkpoint},
                 adk_workflow:validate_checkpoint(Compiled, Unsafe)).

checkpoint_v2_rejects_ambiguous_attempts_and_invalid_fork_failures() ->
    Compiled = pausing_graph(<<"checkpoint-v2-attempt-validation">>, 1),
    {paused, _Details, Checkpoint} = adk_workflow:run(Compiled, #{}),
    CursorFingerprint = binary:copy(<<"c">>, 64),
    Running = #{<<"node_id">> => <<"pause">>,
                <<"count">> => 1,
                <<"status">> => <<"running">>,
                <<"cursor_fingerprint">> => CursorFingerprint},
    Ambiguous = Checkpoint#{
                  <<"attempts">> =>
                      #{binary:copy(<<"a">>, 64) => Running,
                        binary:copy(<<"b">>, 64) => Running}},
    ?assertEqual({error, invalid_checkpoint},
                 adk_workflow:validate_checkpoint(Compiled, Ambiguous)),
    UnknownNode = Checkpoint#{
                    <<"attempts">> =>
                        #{binary:copy(<<"d">>, 64) =>
                              Running#{<<"node_id">> => <<"unknown">>}}},
    ?assertEqual({error, invalid_checkpoint},
                 adk_workflow:validate_checkpoint(Compiled, UnknownNode)),

    Fork = compile_ok(
             #{version => 1,
               id => <<"checkpoint-v2-fork-failures">>,
               kind => graph,
               definition_revision => 1,
               entry => <<"fork">>,
               nodes =>
                   [#{id => <<"fork">>, type => fork,
                      branches => [<<"pause-branch">>],
                      join => <<"join">>, join_policy => first_success,
                      merge => reject_conflicts, max_concurrency => 1},
                    #{id => <<"pause-branch">>,
                      run => fun(_State) ->
                          {pause, approval, <<"Approve branch">>, #{}}
                      end},
                    #{id => <<"join">>, type => join}],
               edges => #{<<"pause-branch">> => <<"join">>,
                          <<"join">> => end_node},
               max_steps => 3}),
    {paused, _ForkDetails, ForkCheckpoint} = adk_workflow:run(Fork, #{}),
    ForkCursor = maps:get(<<"cursor">>, ForkCheckpoint),
    InvalidFailures = ForkCheckpoint#{
                        <<"cursor">> =>
                            ForkCursor#{
                              <<"failed_branches">> =>
                                  #{<<"outside-fork">> => true}}},
    ?assertEqual({error, invalid_checkpoint},
                 adk_workflow:validate_checkpoint(Fork, InvalidFailures)).

checkpoint_definition_mismatch_is_rejected() ->
    First = pausing_graph(<<"fingerprint-mismatch">>, 1),
    Second = pausing_graph(<<"fingerprint-mismatch">>, 2),
    ?assertNotEqual(adk_workflow:definition_fingerprint(First),
                    adk_workflow:definition_fingerprint(Second)),
    {paused, _Details, Checkpoint} = adk_workflow:run(First, #{}),
    ?assertEqual({error, checkpoint_definition_mismatch},
                 adk_workflow:validate_checkpoint(Second, Checkpoint)),
    ?assertEqual({error, checkpoint_definition_mismatch},
                 adk_workflow:resume(
                   Second, Checkpoint,
                   #{resume_input => <<"must-not-resume">>})),
    Data = maps:get(data, First),
    Tampered = First#{data => Data#{max_steps => 999}},
    ?assertEqual(false, adk_workflow:is_compiled(Tampered)),
    ?assertEqual({error, invalid_compiled_workflow},
                 adk_workflow:validate_checkpoint(Tampered, Checkpoint)).

checkpoint_v1_is_migrated_on_resume() ->
    Compiled = pausing_graph(<<"checkpoint-v1-migration">>, 1),
    {paused, _Details, CheckpointV2} = adk_workflow:run(Compiled, #{}),
    CheckpointV1 = downgrade_to_v1(CheckpointV2),
    ?assertEqual(1, maps:get(<<"schema_version">>, CheckpointV1)),
    ?assertEqual(false,
                 maps:is_key(<<"definition_fingerprint">>, CheckpointV1)),
    ?assertEqual({ok, #{<<"pause_committed">> => true}},
                 adk_workflow:validate_checkpoint(Compiled, CheckpointV1)),
    {ok, Ref} = adk_workflow:resume(
                  Compiled, CheckpointV1,
                  #{resume_input => <<"approved">>, retention_ms => 1000}),
    {completed, State, Migrated} = adk_workflow:await(Ref, 1000),
    ?assertEqual(true, maps:get(<<"pause_committed">>, State)),
    assert_v2_checkpoint(Compiled, Migrated),
    ?assertEqual(true, maps:get(<<"completed">>, Migrated)),
    ?assert(maps:get(<<"sequence">>, Migrated) > 0).

committed_resume_input_is_reused_and_cannot_change() ->
    Compiled = pausing_graph(<<"committed-resume-input">>, 1),
    {paused, _Details, Checkpoint} = adk_workflow:run(Compiled, #{}),
    Cursor = maps:get(<<"cursor">>, Checkpoint),
    Stored = Checkpoint#{<<"cursor">> =>
                            Cursor#{<<"resume_input">> => <<"approved">>}},
    ?assertEqual(
       {error, resume_input_mismatch},
       adk_workflow:resume(
         Compiled, Stored, #{resume_input => <<"different">>})),
    {ok, Ref} = adk_workflow:resume(Compiled, Stored),
    {completed, State, _Complete} = adk_workflow:await(Ref, 1000),
    ?assertEqual(true, maps:get(<<"pause_committed">>, State)).

lifecycle_receiver_observes_ordered_runtime_events() ->
    Compiled = compile_ok(
                 #{version => 1,
                   id => <<"lifecycle-events">>,
                   kind => sequential,
                   definition_revision => 1,
                   steps =>
                       [#{id => <<"work">>,
                          run => fun(_State) ->
                              {output, <<"done">>,
                               #{<<"work_done">> => true}}
                          end}],
                   max_steps => 2}),
    {ok, Ref} = adk_workflow:start(
                  Compiled, #{},
                  #{lifecycle_receiver => self(), retention_ms => 2000}),
    {completed, _State, Checkpoint} = adk_workflow:await(Ref, 1000),
    Events = collect_lifecycle_until_terminal(Ref, []),
    Types = [maps:get(<<"type">>, Event) || Event <- Events],
    ?assertEqual(<<"workflow_started">>, hd(Types)),
    ?assertEqual(<<"workflow_terminal">>, lists:last(Types)),
    ?assert(lists:member(<<"node_started">>, Types)),
    ?assert(lists:member(<<"attempt_started">>, Types)),
    ?assert(lists:member(<<"checkpoint_committed">>, Types)),
    ?assert(lists:member(<<"node_completed">>, Types)),
    ?assertEqual(lists:seq(1, length(Events)),
                 [maps:get(<<"sequence">>, Event) || Event <- Events]),
    InvocationIds = lists:usort(
                      [maps:get(<<"invocation_id">>, Event)
                       || Event <- Events]),
    ?assertEqual([maps:get(<<"execution_id">>, Checkpoint)],
                 InvocationIds),
    lists:foreach(
      fun(Event) ->
          ?assertEqual(1, maps:get(<<"schema_version">>, Event)),
          ?assertEqual(<<"lifecycle-events">>,
                       maps:get(<<"workflow_id">>, Event)),
          ?assertEqual(<<"sequential">>,
                       maps:get(<<"workflow_kind">>, Event)),
          ?assert(is_integer(maps:get(<<"timestamp">>, Event)))
      end, Events),
    {ok, Status} = adk_workflow:status(Ref),
    ?assertEqual(length(Events), maps:get(lifecycle_event_count, Status)).

retry_attempts_are_persisted_in_checkpoint() ->
    Retry = fun(_State, Context) ->
        case maps:get(attempt, Context) of
            Attempt when Attempt < 3 -> {error, retry_me};
            3 -> {ok, #{<<"retried">> => true}}
        end
    end,
    Compiled = compile_ok(
                 #{version => 1,
                   id => <<"durable-retry-attempts">>,
                   kind => sequential,
                   definition_revision => 1,
                   steps =>
                       [#{id => <<"retry">>, run => Retry,
                          retry => #{max_attempts => 3,
                                     backoff_ms => 0}}],
                   max_steps => 2}),
    {completed, State, Checkpoint} = adk_workflow:run(Compiled, #{}),
    ?assertEqual(true, maps:get(<<"retried">>, State)),
    Attempts = maps:get(<<"attempts">>, Checkpoint),
    ?assertEqual(1, map_size(Attempts)),
    [Entry] = maps:values(Attempts),
    ?assertEqual(<<"retry">>, maps:get(<<"node_id">>, Entry)),
    ?assertEqual(3, maps:get(<<"count">>, Entry)),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Entry)),
    assert_v2_checkpoint(Compiled, Checkpoint).

in_flight_attempt_replay_keeps_budget_and_attempt_number() ->
    Table = ets:new(workflow_attempt_replay, [set, public]),
    ets:insert(Table, [{calls, 0}, {allow_completion, false}]),
    Parent = self(),
    Action = fun(_State, Context) ->
        ets:update_counter(Table, calls, 1),
        Parent ! {attempt_action_entered, self(),
                  maps:get(attempt, Context)},
        case ets:lookup_element(Table, allow_completion, 2) of
            true -> {ok, #{<<"replayed">> => true}};
            false -> receive never -> impossible end
        end
    end,
    Compiled = compile_ok(
                 #{version => 1,
                   id => <<"in-flight-attempt-replay">>,
                   kind => sequential,
                   definition_revision => 1,
                   steps => [#{id => <<"only-step">>, run => Action,
                               retry => #{max_attempts => 1}}],
                   max_steps => 1}),
    try
        {ok, Ref} = adk_workflow:start(
                      Compiled, #{}, #{retention_ms => 1000}),
        receive
            {attempt_action_entered, _Worker, 1} -> ok
        after 1000 -> error(first_attempt_did_not_start)
        end,
        {ok, RunningCheckpoint} = adk_workflow:checkpoint(Ref),
        ?assertEqual(0,
                     maps:get(<<"steps">>,
                              maps:get(<<"remaining">>,
                                       RunningCheckpoint))),
        [RunningAttempt] = maps:values(
                             maps:get(<<"attempts">>,
                                      RunningCheckpoint)),
        ?assertEqual(1, maps:get(<<"count">>, RunningAttempt)),
        ?assertEqual(<<"running">>,
                     maps:get(<<"status">>, RunningAttempt)),
        ok = adk_workflow:cancel(Ref, crash_recovery_test),
        ?assertMatch({cancelled, _, _}, adk_workflow:await(Ref, 1000)),

        ets:insert(Table, {allow_completion, true}),
        {ok, Resumed} = adk_workflow:resume(
                          Compiled, RunningCheckpoint,
                          #{retention_ms => 1000}),
        receive
            {attempt_action_entered, _ReplayWorker, 1} -> ok
        after 1000 -> error(replayed_attempt_did_not_start)
        end,
        {completed, State, Complete} = adk_workflow:await(Resumed, 1000),
        ?assertEqual(true, maps:get(<<"replayed">>, State)),
        ?assertEqual(2, ets:lookup_element(Table, calls, 2)),
        [CompletedAttempt] = maps:values(
                               maps:get(<<"attempts">>, Complete)),
        ?assertEqual(1, maps:get(<<"count">>, CompletedAttempt)),
        ?assertEqual(<<"completed">>,
                     maps:get(<<"status">>, CompletedAttempt))
    after
        ets:delete(Table)
    end.

parallel_nested_pause_resumes_without_child_replay() ->
    with_nested_child(
      <<"parallel-child">>,
      fun(Child, Table) ->
          Parent = compile_ok(
                     #{version => 1,
                       id => <<"parallel-nested-resume">>,
                       kind => parallel,
                       definition_revision => 1,
                       branches =>
                           [#{id => <<"child">>,
                              run => {workflow, Child, #{}}}],
                       merge => reject_conflicts,
                       max_concurrency => 1,
                       max_steps => 2}),
          {paused, Details, Checkpoint} = adk_workflow:run(Parent, #{}),
          ?assertEqual(<<"child">>, maps:get(<<"branch_id">>, Details)),
          ?assertEqual(<<"nested-pause">>,
                       maps:get(<<"step_id">>, Details)),
          assert_paused_scheduler(<<"parallel">>, Checkpoint),
          {completed, State, Complete} =
              resume_and_await(Parent, Checkpoint, <<"parallel-approved">>),
          assert_nested_completion(State, Complete,
                                   <<"parallel-approved">>, Table)
      end).

loop_nested_pause_resumes_without_child_replay() ->
    with_nested_child(
      <<"loop-child">>,
      fun(Child, Table) ->
          Parent = compile_ok(
                     #{version => 1,
                       id => <<"loop-nested-resume">>,
                       kind => loop,
                       definition_revision => 1,
                       body => {workflow, Child, #{}},
                       until => fun(State) ->
                           maps:get(<<"child_done">>, State, false)
                       end,
                       max_iterations => 1,
                       max_steps => 2}),
          {paused, Details, Checkpoint} = adk_workflow:run(Parent, #{}),
          ?assertEqual(<<"loop-body">>, maps:get(<<"node_id">>, Details)),
          ?assertEqual(<<"nested-pause">>,
                       maps:get(<<"step_id">>, Details)),
          assert_paused_scheduler(<<"loop-body">>, Checkpoint),
          {completed, State, Complete} =
              resume_and_await(Parent, Checkpoint, <<"loop-approved">>),
          assert_nested_completion(State, Complete,
                                   <<"loop-approved">>, Table)
      end).

transfer_nested_pause_resumes_without_child_replay() ->
    with_nested_child(
      <<"transfer-child">>,
      fun(Child, Table) ->
          Parent = compile_ok(
                     #{version => 1,
                       id => <<"transfer-nested-resume">>,
                       kind => transfer,
                       definition_revision => 1,
                       entry => <<"member">>,
                       members =>
                           #{<<"member">> =>
                                 #{run => {workflow, Child, #{}}}},
                       max_transfers => 0,
                       max_steps => 2}),
          {paused, Details, Checkpoint} = adk_workflow:run(Parent, #{}),
          ?assertEqual(<<"member">>, maps:get(<<"member_id">>, Details)),
          ?assertEqual(<<"nested-pause">>,
                       maps:get(<<"step_id">>, Details)),
          assert_paused_scheduler(<<"member">>, Checkpoint),
          {completed, State, Complete} =
              resume_and_await(Parent, Checkpoint, <<"transfer-approved">>),
          assert_nested_completion(State, Complete,
                                   <<"transfer-approved">>, Table)
      end).

typed_tool_confirmation_can_be_approved_or_rejected() ->
    persistent_term:put({adk_tool_confirmation_test, target}, self()),
    Compiled = compile_ok(
                 #{version => 1,
                   id => <<"typed-tool-confirmation">>,
                   kind => graph,
                   definition_revision => 1,
                   entry => <<"tool">>,
                   nodes =>
                       [#{id => <<"tool">>, type => tool,
                          module => adk_static_confirmation_tool,
                          args => #{<<"id">> => <<"workflow-tool">>},
                          result_key => <<"tool_result">>}],
                   edges => #{<<"tool">> => end_node},
                   max_steps => 2}),
    try
        {paused, Details, Checkpoint} = adk_workflow:run(Compiled, #{}),
        Reason = maps:get(<<"reason">>, Details),
        ?assertEqual(<<"tool_confirmation">>,
                     maps:get(<<"type">>, Reason)),
        ?assert(adk_tool_confirmation:valid_details(Reason)),
        ?assertEqual(<<"tool_confirmation">>,
                     maps:get(<<"resume_kind">>,
                              maps:get(<<"cursor">>, Checkpoint))),
        assert_no_tool_execution(),

        {ok, RejectRef} = adk_workflow:resume(
                            Compiled, Checkpoint,
                            #{resume_input => #{<<"approved">> => false},
                              retention_ms => 1000}),
        ?assertMatch(
           {failed,
            {node_failed, <<"tool">>, {adk_failure, _}}, _},
           adk_workflow:await(RejectRef, 1000)),
        assert_no_tool_execution(),

        {ok, ApproveRef} = adk_workflow:resume(
                             Compiled, Checkpoint,
                             #{resume_input => #{<<"approved">> => true},
                               retention_ms => 1000}),
        {completed, State, Complete} =
            adk_workflow:await(ApproveRef, 1000),
        Result = maps:get(<<"tool_result">>, State),
        ?assertEqual(<<"workflow-tool">>, maps:get(<<"id">>, Result)),
        ?assertEqual(<<"static">>, maps:get(<<"kind">>, Result)),
        ?assertEqual(Result, maps:get(<<"output">>, Complete)),
        receive
            {confirmation_tool_executed, static, <<"workflow-tool">>,
             _Pid, Context} ->
                Confirmation = maps:get(tool_confirmation, Context),
                ?assertEqual(Reason, maps:get(details, Confirmation)),
                ?assertEqual(#{<<"approved">> => true},
                             maps:get(input, Confirmation))
        after 1000 ->
            error(approved_tool_was_not_executed)
        end,
        assert_no_tool_execution()
    after
        persistent_term:erase({adk_tool_confirmation_test, target}),
        flush_tool_messages()
    end.

forked_tool_confirmation_resumes_exact_branch() ->
    persistent_term:put({adk_tool_confirmation_test, target}, self()),
    Compiled = compile_ok(
                 #{version => 1,
                   id => <<"forked-tool-confirmation">>,
                   kind => graph,
                   definition_revision => 1,
                   entry => <<"fork">>,
                   nodes =>
                       [#{id => <<"fork">>, type => fork,
                          branches => [<<"tool">>], join => <<"join">>,
                          max_concurrency => 1},
                        #{id => <<"tool">>, type => tool,
                          module => adk_static_confirmation_tool,
                          args => #{<<"id">> => <<"workflow-tool">>},
                          result_key => <<"tool_result">>},
                        #{id => <<"join">>, type => join}],
                   edges => #{<<"tool">> => <<"join">>,
                              <<"join">> => end_node},
                   max_steps => 4}),
    try
        {paused, _Details, Checkpoint} = adk_workflow:run(Compiled, #{}),
        Cursor = maps:get(<<"cursor">>, Checkpoint),
        ?assertEqual(<<"fork_tool_confirmation">>,
                     maps:get(<<"resume_kind">>, Cursor)),
        ?assertEqual(<<"tool">>, maps:get(<<"paused_branch">>, Cursor)),
        assert_no_tool_execution(),
        {ok, Ref} = adk_workflow:resume(
                      Compiled, Checkpoint,
                      #{resume_input => #{<<"approved">> => true},
                        retention_ms => 1000}),
        {completed, State, Complete} = adk_workflow:await(Ref, 1000),
        Result = maps:get(<<"tool_result">>, State),
        ?assertEqual(<<"workflow-tool">>, maps:get(<<"id">>, Result)),
        ForkOutput = maps:get(<<"output">>, Complete),
        ?assertEqual(Result, maps:get(<<"tool">>, ForkOutput)),
        receive
            {confirmation_tool_executed, static, <<"workflow-tool">>,
             _Pid, _Context} -> ok
        after 1000 ->
            error(forked_approved_tool_was_not_executed)
        end,
        assert_no_tool_execution()
    after
        persistent_term:erase({adk_tool_confirmation_test, target}),
        flush_tool_messages()
    end.

pausing_graph(Id, Revision) ->
    compile_ok(
      #{version => 1,
        id => Id,
        kind => graph,
        definition_revision => Revision,
        entry => <<"pause">>,
        nodes =>
            [#{id => <<"pause">>,
               run => fun(_State) ->
                   {pause, approval, <<"Approve checkpoint resume">>,
                    #{<<"pause_committed">> => true}}
               end}],
        edges => #{<<"pause">> => end_node},
        max_steps => 2}).

downgrade_to_v1(Checkpoint) ->
    V2Only = [<<"definition_fingerprint">>, <<"execution_id">>,
              <<"sequence">>, <<"parent_sequence">>, <<"created_at">>,
              <<"attempts">>, <<"node_status">>, <<"runnable">>,
              <<"waiting">>, <<"join_accumulators">>,
              <<"cycle_counters">>, <<"interruptions">>],
    (maps:without(V2Only, Checkpoint))#{<<"schema_version">> => 1}.

assert_v2_checkpoint(Compiled, Checkpoint) ->
    ?assertEqual(2, maps:get(<<"schema_version">>, Checkpoint)),
    Fingerprint = maps:get(<<"definition_fingerprint">>, Checkpoint),
    ?assertEqual(adk_workflow:definition_fingerprint(Compiled), Fingerprint),
    ?assertEqual(64, byte_size(Fingerprint)),
    ?assert(is_binary(maps:get(<<"execution_id">>, Checkpoint))),
    Sequence = maps:get(<<"sequence">>, Checkpoint),
    ParentSequence = maps:get(<<"parent_sequence">>, Checkpoint),
    ?assert(is_integer(Sequence)),
    ?assert(Sequence >= 0),
    ?assert(ParentSequence =:= null orelse ParentSequence < Sequence),
    ?assert(is_integer(maps:get(<<"created_at">>, Checkpoint))),
    ?assert(is_map(maps:get(<<"attempts">>, Checkpoint))),
    ?assert(is_map(maps:get(<<"node_status">>, Checkpoint))),
    ?assert(is_list(maps:get(<<"runnable">>, Checkpoint))),
    ?assert(is_list(maps:get(<<"waiting">>, Checkpoint))),
    ?assert(is_map(maps:get(<<"join_accumulators">>, Checkpoint))),
    ?assert(is_map(maps:get(<<"cycle_counters">>, Checkpoint))),
    ?assert(is_list(maps:get(<<"interruptions">>, Checkpoint))).

collect_lifecycle_until_terminal(Ref, Acc) ->
    receive
        {adk_workflow_lifecycle, Ref, Event} ->
            Next = [Event | Acc],
            case maps:get(<<"type">>, Event) of
                <<"workflow_terminal">> -> lists:reverse(Next);
                _ -> collect_lifecycle_until_terminal(Ref, Next)
            end
    after 1000 ->
        error({missing_workflow_terminal_lifecycle, lists:reverse(Acc)})
    end.

with_nested_child(Id, Test) ->
    Table = ets:new(?MODULE, [set, public]),
    ets:insert(Table, [{pause_calls, 0}, {after_calls, 0}]),
    Child = compile_ok(
              #{version => 1,
                id => Id,
                kind => sequential,
                definition_revision => 1,
                steps =>
                    [#{id => <<"nested-pause">>,
                       run => fun(_State) ->
                           ets:update_counter(Table, pause_calls, 1),
                           {pause, approval, <<"Approve nested workflow">>,
                            #{<<"child_requested">> => true}}
                       end},
                     #{id => <<"nested-workflow">>,
                       run => fun(State, Context) ->
                           ets:update_counter(Table, after_calls, 1),
                           true = maps:get(<<"child_requested">>, State),
                           Output = maps:get(input, Context),
                           {output, Output,
                            #{<<"child_done">> => true,
                              <<"child_output">> => Output}}
                       end}],
                max_steps => 3}),
    try Test(Child, Table)
    after ets:delete(Table)
    end.

resume_and_await(Compiled, Checkpoint, Input) ->
    {ok, Ref} = adk_workflow:resume(
                  Compiled, Checkpoint,
                  #{resume_input => Input, retention_ms => 1000}),
    adk_workflow:await(Ref, 1000).

assert_nested_completion(State, Checkpoint, Output, Table) ->
    ?assertEqual(true, maps:get(<<"child_requested">>, State)),
    ?assertEqual(true, maps:get(<<"child_done">>, State)),
    ?assertEqual(Output, maps:get(<<"child_output">>, State)),
    ?assertEqual(1, ets:lookup_element(Table, pause_calls, 2)),
    ?assertEqual(1, ets:lookup_element(Table, after_calls, 2)),
    ?assertEqual(Output, nested_parent_output(Checkpoint)),
    ?assertEqual(true, maps:get(<<"completed">>, Checkpoint)).

nested_parent_output(#{<<"kind">> := <<"parallel">>,
                       <<"output">> := Outputs}) ->
    maps:get(<<"child">>, Outputs);
nested_parent_output(#{<<"output">> := Output}) -> Output.

assert_paused_scheduler(NodeId, Checkpoint) ->
    ?assertEqual(#{NodeId => <<"paused">>},
                 maps:get(<<"node_status">>, Checkpoint)),
    ?assertEqual([], maps:get(<<"runnable">>, Checkpoint)),
    ?assertEqual([NodeId], maps:get(<<"waiting">>, Checkpoint)),
    ?assertEqual(1, length(maps:get(<<"interruptions">>, Checkpoint))).

assert_no_tool_execution() ->
    receive
        {confirmation_tool_executed, static, <<"workflow-tool">>,
         _Pid, _Context} ->
            error(tool_executed_without_approval)
    after 0 -> ok
    end.

flush_tool_messages() ->
    receive
        {confirmation_tool_executed, _Kind, _Id, _Pid, _Context} ->
            flush_tool_messages()
    after 0 -> ok
    end.

compile_ok(Spec) ->
    {ok, Compiled} = adk_workflow:compile(Spec),
    Compiled.
