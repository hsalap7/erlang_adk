%% @doc Internal bounded workflow execution engine.
-module(adk_workflow_engine).

-export([execute/5]).

-define(LIFECYCLE_SEQUENCE_KEY, '$adk_workflow_lifecycle_sequence').
-define(CHECKPOINT_SEQUENCE_KEY, '$adk_workflow_checkpoint_sequence').
-define(CHECKPOINT_PARENT_KEY, '$adk_workflow_checkpoint_parent').
-define(ATTEMPTS_KEY, '$adk_workflow_attempts').
-define(ATTEMPT_KEY_OVERRIDE, '$adk_workflow_attempt_key_override').

%% The engine traps worker exits so one crashing action is an error value. All
%% workers are also linked: an untrappable kill of the engine therefore cannot
%% orphan blocked branch or callback processes.
execute(Coordinator, Compiled, InitialState, Runtime, Checkpoint) ->
    process_flag(trap_exit, true),
    initialize_execution_metadata(Checkpoint),
    CoordinatorRef = erlang:monitor(process, Coordinator),
    Env0 = (env_from_checkpoint(Coordinator, Compiled, InitialState,
                                Runtime, Checkpoint))#{
               coordinator_ref => CoordinatorRef},
    emit_lifecycle(<<"workflow_started">>, #{}, Env0),
    Result = try
        case deadline_expired(maps:get(deadline, Env0)) of
            true -> {timed_out, Env0};
            false -> execute_kind(maps:get(kind, Compiled), Env0)
        end
    catch
        Class:Reason ->
            {failed, adk_workflow:exception_reason(
                       adk_workflow_engine, execute, Class, Reason), Env0}
    end,
    {Outcome0, FinalEnv0} = normalize_execution_result(Result),
    {Outcome, FinalEnv} = validate_completed_output(Outcome0, FinalEnv0),
    emit_terminal_node_failure(Outcome, FinalEnv),
    FinalCheckpoint = case Outcome of
        {completed, FinalState} ->
            terminal_checkpoint(FinalEnv#{state => FinalState}, true);
        _ -> terminal_checkpoint(FinalEnv, false)
    end,
    emit_lifecycle(<<"workflow_terminal">>,
                   #{<<"outcome">> => outcome_name(Outcome)}, FinalEnv),
    Coordinator ! {adk_workflow_terminal, self(), Outcome,
                   FinalCheckpoint},
    erlang:demonitor(CoordinatorRef, [flush]),
    ok.

validate_completed_output({completed, FinalState}, Env0) ->
    Env = Env0#{state => FinalState},
    Schema = maps:get(output_schema, maps:get(compiled, Env), undefined),
    Value = maps:get(output, Env, FinalState),
    case adk_json_schema:validate_compiled(Schema, Value) of
        {ok, _} -> {{completed, FinalState}, Env};
        {error, Reason} ->
            {{failed, {output_schema_validation_failed, Reason}}, Env}
    end;
validate_completed_output(Outcome, Env) -> {Outcome, Env}.

execute_kind(sequential, Env) -> execute_sequential(Env);
execute_kind(parallel, Env) -> execute_parallel(Env);
execute_kind(loop, Env) -> execute_loop(Env);
execute_kind(transfer, Env) -> execute_transfer(Env);
execute_kind(graph, Env) -> execute_graph(Env).

%% Sequential

execute_sequential(Env) ->
    Data = workflow_data(Env),
    Steps = maps:get(steps, Data),
    Cursor = maps:get(cursor, Env),
    Index = maps:get(<<"next_index">>, Cursor),
    case maps:get(<<"phase">>, Cursor, <<"ready">>) of
        <<"awaiting_resume">> ->
            sequential_resume_nested(Index, Steps, Env);
        _ -> sequential_from(Index, Steps, Env)
    end.

sequential_from(Index, Steps, Env) when Index > length(Steps) ->
    {completed, maps:get(state, Env), Env};
sequential_from(Index, Steps, Env0) ->
    Step = lists:nth(Index, Steps),
    Id = maps:get(id, Step),
    emit_lifecycle(<<"node_started">>,
                   #{<<"node_id">> => Id,
                     <<"node_type">> => <<"sequential_step">>}, Env0),
    case consume_action_step(Id, Env0) of
        {error, Reason, Env1} -> {failed, Reason, Env1};
        {ok, Env1} ->
            Context = action_context(Id, Env1, sequential_input(Env1)),
            case run_action(maps:get(run, Step), maps:get(state, Env1),
                            Context, action_policy(Step), Env1) of
                timed_out -> {timed_out, Env1};
                {error, Reason} ->
                    {failed, {step_failed, Id, Reason}, Env1};
                {ok, {ok, Delta}} ->
                    commit_sequential_delta(Index, Steps, Delta, Env1);
                {ok, {output, Output, Delta}} ->
                    commit_sequential_output(Index, Steps, Output, Delta,
                                             Env1);
                {ok, {stop, Output, Delta}} ->
                    complete_sequential_step(Id, Output, Delta, Env1);
                {ok, {complete, Output, Delta}} ->
                    %% Compatibility: the legacy complete result remains an
                    %% explicit terminal control. New actions should use
                    %% output when the next sequential step must run.
                    complete_sequential_step(Id, Output, Delta, Env1);
                {ok, {nested_pause, Pause, ChildCheckpoint}} ->
                    sequential_pause_nested(
                      Index, Id, Pause, ChildCheckpoint, Env1);
                {ok, {pause, Pause, Delta}} ->
                    sequential_pause_step(Index, Id, Pause, Delta, Env1);
                {ok, OtherControl} ->
                    {failed,
                     {step_failed, Id,
                      {invalid_control, control_name(OtherControl)}}, Env1}
            end
    end.

commit_sequential_delta(Index, Steps, Delta, Env1) ->
    case merge_delta(Delta, Env1) of
        {ok, Env2} ->
            Next = Index + 1,
            Cursor = #{<<"type">> => <<"sequential">>,
                       <<"next_index">> => Next},
            Env3 = commit(Cursor, Env2),
            emit_lifecycle(<<"node_completed">>,
                           #{<<"node_id">> =>
                                 maps:get(id, lists:nth(Index, Steps))},
                           Env3),
            sequential_from(Next, Steps, Env3);
        {error, Reason} ->
            Id = maps:get(id, lists:nth(Index, Steps)),
            {failed, {step_failed, Id, Reason}, Env1}
    end.

commit_sequential_output(Index, Steps, Output, Delta, Env1) ->
    case merge_delta(Delta, Env1) of
        {ok, Env2} ->
            Next = Index + 1,
            Cursor = #{<<"type">> => <<"sequential">>,
                       <<"next_index">> => Next},
            Env3 = commit(Cursor, Env2#{output => Output}),
            emit_lifecycle(<<"node_completed">>,
                           #{<<"node_id">> =>
                                 maps:get(id, lists:nth(Index, Steps))},
                           Env3),
            sequential_from(Next, Steps, Env3);
        {error, Reason} ->
            Id = maps:get(id, lists:nth(Index, Steps)),
            {failed, {step_failed, Id, Reason}, Env1}
    end.

sequential_input(Env) -> maps:get(output, Env, null).

sequential_pause_nested(Index, Id, Pause0, ChildCheckpoint, Env) ->
    Pause1 = case maps:find(<<"node_id">>, Pause0) of
        {ok, ChildNodeId} ->
            Pause0#{<<"nested_node_id">> => ChildNodeId};
        error -> Pause0
    end,
    Pause = Pause1#{<<"step_id">> => Id},
    Cursor = #{<<"type">> => <<"sequential">>,
               <<"next_index">> => Index,
               <<"phase">> => <<"awaiting_resume">>,
               <<"resume_kind">> => <<"nested_workflow">>,
               <<"pause">> => Pause,
               <<"nested_checkpoint">> => ChildCheckpoint},
    Env1 = commit(Cursor, Env),
    emit_lifecycle(<<"workflow_paused">>,
                   #{<<"node_id">> => Id,
                     <<"pause_kind">> => <<"nested_workflow">>}, Env1),
    {paused, Pause, Env1}.

sequential_pause_step(Index, Id, Pause0, Delta, Env) ->
    case normalize_delta(Delta) of
        {error, Reason} -> {failed, {step_failed, Id, Reason}, Env};
        {ok, SafeDelta} ->
            Pause = Pause0#{<<"step_id">> => Id},
            Cursor = #{<<"type">> => <<"sequential">>,
                       <<"next_index">> => Index,
                       <<"phase">> => <<"awaiting_resume">>,
                       <<"resume_kind">> =>
                           pause_resume_kind(Pause, <<"step">>),
                       <<"pause">> => Pause,
                       <<"paused_delta">> => SafeDelta},
            Env1 = commit(Cursor, Env),
            emit_lifecycle(<<"workflow_paused">>,
                           #{<<"node_id">> => Id,
                             <<"pause_kind">> => <<"step">>}, Env1),
            {paused, Pause, Env1}
    end.

sequential_resume_nested(Index, Steps, Env) ->
    Cursor = maps:get(cursor, Env),
    case maps:find(<<"resume_input">>, Cursor) of
        error -> {failed, {resume_input_required, Index}, Env};
        {ok, Input} ->
            Step = lists:nth(Index, Steps),
            Id = maps:get(id, Step),
            emit_lifecycle(<<"workflow_resumed">>,
                           #{<<"node_id">> => Id}, Env),
            case maps:get(<<"resume_kind">>, Cursor,
                          <<"nested_workflow">>) of
                <<"step">> ->
                    commit_sequential_output(
                      Index, Steps, Input,
                      maps:get(<<"paused_delta">>, Cursor, #{}), Env);
                <<"tool_confirmation">> ->
                    sequential_resume_tool_confirmation(
                      Index, Id, Step, Steps, Input, Env);
                <<"nested_workflow">> ->
                    sequential_resume_nested_workflow(
                      Index, Id, Step, Steps, Input, Env)
            end
    end.

sequential_resume_nested_workflow(Index, Id, Step, Steps, Input, Env) ->
    Cursor = maps:get(cursor, Env),
    {workflow, Child, Opts} = maps:get(run, Step),
    ChildCheckpoint = maps:get(<<"nested_checkpoint">>, Cursor),
    Context = action_context(Id, Env, sequential_input(Env)),
    Resume = fun(_State, _AttemptContext) ->
        resume_nested_workflow(Child, Opts, ChildCheckpoint, Input, Context)
    end,
    case run_action(Resume, maps:get(state, Env), Context,
                    action_policy(Step), Env) of
        timed_out -> {timed_out, Env};
        {ok, {nested_pause, Pause, NextChildCheckpoint}} ->
            sequential_pause_nested(
              Index, Id, Pause, NextChildCheckpoint, Env);
        {ok, {output, Output, Delta}} ->
            commit_sequential_output(Index, Steps, Output, Delta, Env);
        {error, Reason} -> {failed, {step_failed, Id, Reason}, Env};
        {ok, Control} ->
            {failed,
             {step_failed, Id,
             {invalid_control, control_name(Control)}}, Env}
    end.

sequential_resume_tool_confirmation(Index, Id, Step, Steps, Input, Env) ->
    case run_resumed_tool_confirmation(
           Step, Id, sequential_input(Env), Input, Env) of
        timed_out -> {timed_out, Env};
        {ok, {ok, Delta}} ->
            commit_sequential_delta(Index, Steps, Delta, Env);
        {ok, {output, Output, Delta}} ->
            commit_sequential_output(Index, Steps, Output, Delta, Env);
        {ok, {stop, Output, Delta}} ->
            complete_sequential_step(Id, Output, Delta, Env);
        {ok, {complete, Output, Delta}} ->
            complete_sequential_step(Id, Output, Delta, Env);
        {ok, {pause, Pause, Delta}} ->
            sequential_pause_step(Index, Id, Pause, Delta, Env);
        {error, Reason} -> {failed, {step_failed, Id, Reason}, Env};
        {ok, Control} ->
            {failed, {step_failed, Id,
                      {invalid_control, control_name(Control)}}, Env}
    end.

complete_sequential_step(Id, Output, Delta, Env1) ->
    case merge_delta(Delta, Env1) of
        {ok, Env2} ->
            emit_lifecycle(<<"node_completed">>,
                           #{<<"node_id">> => Id}, Env2),
            {completed, maps:get(state, Env2), Env2#{output => Output}};
        {error, Reason} ->
            {failed, {step_failed, Id, Reason}, Env1}
    end.

%% Parallel

execute_parallel(Env0) ->
    Data = workflow_data(Env0),
    Branches = maps:get(branches, Data),
    Cursor = maps:get(cursor, Env0),
    case maps:get(<<"status">>, Cursor, <<"pending">>) of
        <<"pending">> ->
            case begin_parallel(length(Branches), Env0) of
                {error, Reason, Env1} -> {failed, Reason, Env1};
                {ok, Env1} ->
                    parallel_run(Branches, #{}, Env1)
            end;
        <<"running">> ->
            parallel_run(
              Branches, maps:get(<<"results">>, Cursor, #{}), Env0);
        <<"awaiting_resume">> ->
            parallel_resume_after_pause(Branches, Env0)
    end.

parallel_run(Branches, Results, Env) ->
    BranchCount = length(Branches),
    Max = erlang:min(maps:get(max_concurrency, maps:get(runtime, Env)),
                     BranchCount),
    State = maps:get(state, Env),
    case run_parallel_branches(Branches, Results, State, Env, Max) of
        {timed_out, FinalEnv} -> {timed_out, FinalEnv};
        {paused, Pause, FinalEnv} -> {paused, Pause, FinalEnv};
        {error, BranchId, Reason, FinalEnv} ->
            {failed, {branch_failed, BranchId, Reason}, FinalEnv};
        {ok, OrderedResults, FinalEnv} ->
            complete_parallel(OrderedResults, State, FinalEnv)
    end.

complete_parallel(OrderedResults, State, Env) ->
    Data = workflow_data(Env),
    OrderedDeltas = [{Id, Delta} ||
                     {Id, _Output, Delta} <- OrderedResults],
    Outputs = maps:from_list(
                [{Id, Output} ||
                 {Id, Output, _Delta} <- OrderedResults]),
    case merge_parallel(maps:get(merge, Data), OrderedDeltas, State, Env) of
        {ok, MergedDelta} ->
            case merge_delta(MergedDelta, Env) of
                {ok, Env1} ->
                    emit_lifecycle(<<"join_completed">>,
                                   #{<<"join_id">> => <<"parallel">>,
                                     <<"branch_count">> =>
                                         length(OrderedResults)}, Env1),
                    {completed, maps:get(state, Env1),
                     Env1#{output => Outputs}};
                {error, Reason} -> {failed, Reason, Env}
            end;
        timed_out -> {timed_out, Env};
        {error, Reason} -> {failed, Reason, Env}
    end.

run_parallel_branches(Branches, Results, State, Env, Max) ->
    case deadline_expired(maps:get(deadline, Env)) of
        true -> {timed_out, Env};
        false ->
            Indexed = [{Index, Branch}
                       || {Index, Branch} <-
                              lists:zip(lists:seq(1, length(Branches)),
                                        Branches),
                          not maps:is_key(maps:get(id, Branch), Results)],
            {Pending, Active} = fill_parallel(Indexed, #{}, Max, State, Env),
            collect_parallel(Pending, Active, Results, Branches,
                             Max, State, Env)
    end.

fill_parallel(Pending, Active, Max, _State, _Env)
  when map_size(Active) >= Max; Pending =:= [] ->
    {Pending, Active};
fill_parallel([{Index, Branch} | Rest], Active, Max, State, Env) ->
    Id = maps:get(id, Branch),
    emit_lifecycle(<<"node_started">>,
                   #{<<"node_id">> => Id,
                     <<"parent">> => <<"parallel">>}, Env),
    Context = action_context(Id, Env, null),
    Job = spawn_action_worker(maps:get(run, Branch), State, Context,
                              Index, Id, action_policy(Branch)),
    fill_parallel(Rest, Active#{maps:get(job_ref, Job) => Job},
                  Max, State, Env).

collect_parallel(_Pending, Active, Results, Branches, _Max, _State, Env)
  when map_size(Active) =:= 0, map_size(Results) =:= length(Branches) ->
    {ok, [parallel_result_tuple(maps:get(maps:get(id, Branch), Results),
                                maps:get(id, Branch))
          || Branch <- Branches], Env};
collect_parallel(Pending, Active, Results, Branches, Max, State, Env) ->
    Timeout = remaining_timeout(maps:get(deadline, Env)),
    CoordinatorRef = maps:get(coordinator_ref, Env),
    Coordinator = maps:get(coordinator, Env),
    receive
        {adk_workflow_attempt_started, Pid, AttemptRef, JobRef,
         Id, Attempt}
          when is_pid(Pid), is_reference(AttemptRef),
               is_map_key(JobRef, Active) ->
            Job = maps:get(JobRef, Active),
            true = maps:get(pid, Job) =:= Pid,
            record_attempt(Job, Id, Attempt, Env),
            Pid ! {adk_workflow_attempt_ack, AttemptRef},
            collect_parallel(Pending, Active, Results, Branches,
                             Max, State, Env);
        {adk_workflow_worker, JobRef, Pid, Raw}
          when is_map_key(JobRef, Active) ->
            Job = maps:get(JobRef, Active),
            true = maps:get(pid, Job) =:= Pid,
            complete_attempt(Job, Raw),
            cleanup_job(Job),
            Active1 = maps:remove(JobRef, Active),
            case normalize_action(Raw) of
                timed_out ->
                    kill_active(Active1),
                    {timed_out, Env};
                {ok, {ok, Delta}} ->
                    parallel_continue(Pending, Active1, Results, Branches,
                                      Max, State, Env, Job, null, Delta);
                {ok, {output, Output, Delta}} ->
                    parallel_continue(Pending, Active1, Results, Branches,
                                      Max, State, Env, Job, Output, Delta);
                {ok, {stop, Output, Delta}} ->
                    %% Each parallel branch is a single bounded action, so a
                    %% terminal action result completes that branch.
                    parallel_continue(Pending, Active1, Results, Branches,
                                      Max, State, Env, Job, Output, Delta);
                {ok, {complete, Output, Delta}} ->
                    parallel_continue(Pending, Active1, Results, Branches,
                                      Max, State, Env, Job, Output, Delta);
                {ok, {pause, Pause, Delta}} ->
                    parallel_pause_branch(Job, Pause, Delta, Active1,
                                          Results, Env);
                {ok, {nested_pause, Pause, ChildCheckpoint}} ->
                    parallel_pause_nested(Job, Pause, ChildCheckpoint,
                                          Active1, Results, Env);
                {ok, Control} ->
                    kill_active(Active1),
                    {error, maps:get(id, Job),
                     {invalid_control, control_name(Control)}, Env};
                {error, Reason} ->
                    kill_active(Active1),
                    {error, maps:get(id, Job), Reason, Env}
            end;
        {'DOWN', CoordinatorRef, process, Coordinator, _Reason} ->
            kill_active(Active),
            erlang:exit(coordinator_down);
        {'DOWN', Monitor, process, _Pid, Reason} ->
            case find_job_by_monitor(Monitor, Active) of
                {ok, JobRef, Job} ->
                    Active1 = maps:remove(JobRef, Active),
                    flush_exit(maps:get(pid, Job)),
                    kill_active(Active1),
                    {error, maps:get(id, Job),
                     {worker_down,
                      adk_workflow:external_reason(
                        adk_workflow_action, process_down, Reason)}, Env};
                error ->
                    collect_parallel(Pending, Active, Results, Branches,
                                     Max, State, Env)
            end;
        {'EXIT', _Pid, _Reason} ->
            collect_parallel(Pending, Active, Results, Branches,
                             Max, State, Env)
    after Timeout ->
        kill_active(Active),
        {timed_out, Env}
    end.

parallel_continue(Pending0, Active0, Results0, Branches, Max,
                  State, Env, Job, Output, Delta) ->
    case normalize_delta(Delta) of
        {ok, SafeDelta} ->
            Id = maps:get(id, Job),
            Results = Results0#{Id => fork_result(Output, SafeDelta)},
            Env1 = commit(parallel_running_cursor(Results), Env),
            emit_lifecycle(<<"node_completed">>,
                           #{<<"node_id">> => Id,
                             <<"parent">> => <<"parallel">>}, Env1),
            {Pending, Active} = fill_parallel(Pending0, Active0, Max,
                                              State, Env1),
            collect_parallel(Pending, Active, Results, Branches,
                             Max, State, Env1);
        {error, Reason} ->
            kill_active(Active0),
            {error, maps:get(id, Job), Reason, Env}
    end.

parallel_pause_branch(Job, Pause0, Delta, Active, Results, Env) ->
    kill_active(Active),
    case normalize_delta(Delta) of
        {error, Reason} ->
            {error, maps:get(id, Job), Reason, Env};
        {ok, SafeDelta} ->
            BranchId = maps:get(id, Job),
            Pause = Pause0#{<<"branch_id">> => BranchId,
                            <<"parallel_id">> => <<"parallel">>},
            Cursor = (parallel_pause_cursor(Results, BranchId, Pause))#{
                         <<"resume_kind">> =>
                             pause_resume_kind(Pause, <<"branch">>),
                         <<"paused_delta">> => SafeDelta},
            Env1 = commit(Cursor, Env),
            emit_lifecycle(<<"workflow_paused">>,
                           #{<<"node_id">> => BranchId,
                             <<"pause_kind">> => <<"parallel_branch">>},
                           Env1),
            {paused, Pause, Env1}
    end.

parallel_pause_nested(Job, Pause0, ChildCheckpoint, Active, Results, Env) ->
    kill_active(Active),
    BranchId = maps:get(id, Job),
    Pause = Pause0#{<<"branch_id">> => BranchId,
                    <<"parallel_id">> => <<"parallel">>},
    Cursor = (parallel_pause_cursor(Results, BranchId, Pause))#{
                 <<"resume_kind">> => <<"nested_workflow">>,
                 <<"nested_checkpoint">> => ChildCheckpoint},
    Env1 = commit(Cursor, Env),
    emit_lifecycle(<<"workflow_paused">>,
                   #{<<"node_id">> => BranchId,
                     <<"pause_kind">> => <<"nested_workflow">>}, Env1),
    {paused, Pause, Env1}.

parallel_resume_after_pause(Branches, Env) ->
    Cursor = maps:get(cursor, Env),
    case maps:find(<<"resume_input">>, Cursor) of
        error -> {failed, {resume_input_required, <<"parallel">>}, Env};
        {ok, Input} ->
            BranchId = maps:get(<<"paused_branch">>, Cursor),
            Results0 = maps:get(<<"results">>, Cursor, #{}),
            emit_lifecycle(<<"workflow_resumed">>,
                           #{<<"node_id">> => BranchId}, Env),
            case maps:get(<<"resume_kind">>, Cursor) of
                <<"branch">> ->
                    Delta = maps:get(<<"paused_delta">>, Cursor, #{}),
                    Results = Results0#{BranchId =>
                                           fork_result(Input, Delta)},
                    Env1 = commit(parallel_running_cursor(Results), Env),
                    emit_lifecycle(<<"node_completed">>,
                                   #{<<"node_id">> => BranchId,
                                     <<"parent">> => <<"parallel">>}, Env1),
                    parallel_run(Branches, Results, Env1);
                <<"tool_confirmation">> ->
                    parallel_resume_tool_confirmation(
                      BranchId, Branches, Results0, Input, Env);
                <<"nested_workflow">> ->
                    parallel_resume_nested(
                      BranchId, Branches, Results0, Input, Env)
            end
    end.

parallel_resume_nested(BranchId, Branches, Results0, Input, Env) ->
    Branch = find_named_action(BranchId, Branches),
    {workflow, Child, Opts} = maps:get(run, Branch),
    Cursor = maps:get(cursor, Env),
    ChildCheckpoint = maps:get(<<"nested_checkpoint">>, Cursor),
    Context = action_context(BranchId, Env, null),
    Resume = fun(_State, _AttemptContext) ->
        resume_nested_workflow(Child, Opts, ChildCheckpoint, Input, Context)
    end,
    case run_action(Resume, maps:get(state, Env), Context,
                    action_policy(Branch), Env) of
        timed_out -> {timed_out, Env};
        {ok, {nested_pause, Pause, NextCheckpoint}} ->
            parallel_pause_nested(
              #{id => BranchId}, Pause, NextCheckpoint, #{}, Results0, Env);
        {ok, {output, Output, Delta}} ->
            case normalize_delta(Delta) of
                {ok, SafeDelta} ->
                    Results = Results0#{BranchId =>
                                           fork_result(Output, SafeDelta)},
                    Env1 = commit(parallel_running_cursor(Results), Env),
                    emit_lifecycle(<<"node_completed">>,
                                   #{<<"node_id">> => BranchId,
                                     <<"parent">> => <<"parallel">>}, Env1),
                    parallel_run(Branches, Results, Env1);
                {error, Reason} ->
                    {failed, {branch_failed, BranchId, Reason}, Env}
            end;
        {error, Reason} ->
            {failed, {branch_failed, BranchId, Reason}, Env};
        {ok, Control} ->
            {failed, {branch_failed, BranchId,
             {invalid_control, control_name(Control)}}, Env}
    end.

parallel_resume_tool_confirmation(BranchId, Branches, Results0,
                                  Input, Env) ->
    Branch = find_named_action(BranchId, Branches),
    case run_resumed_tool_confirmation(Branch, BranchId, null, Input, Env) of
        timed_out -> {timed_out, Env};
        {ok, {ok, Delta}} ->
            parallel_record_resumed(
              BranchId, null, Delta, Branches, Results0, Env);
        {ok, {output, Output, Delta}} ->
            parallel_record_resumed(
              BranchId, Output, Delta, Branches, Results0, Env);
        {ok, {stop, Output, Delta}} ->
            parallel_record_resumed(
              BranchId, Output, Delta, Branches, Results0, Env);
        {ok, {complete, Output, Delta}} ->
            parallel_record_resumed(
              BranchId, Output, Delta, Branches, Results0, Env);
        {ok, {pause, Pause, Delta}} ->
            parallel_pause_branch(
              #{id => BranchId}, Pause, Delta, #{}, Results0, Env);
        {error, Reason} ->
            {failed, {branch_failed, BranchId, Reason}, Env};
        {ok, Control} ->
            {failed, {branch_failed, BranchId,
                      {invalid_control, control_name(Control)}}, Env}
    end.

parallel_record_resumed(BranchId, Output, Delta, Branches, Results0, Env) ->
    case normalize_delta(Delta) of
        {ok, SafeDelta} ->
            Results = Results0#{BranchId => fork_result(Output, SafeDelta)},
            Env1 = commit(parallel_running_cursor(Results), Env),
            emit_lifecycle(<<"node_completed">>,
                           #{<<"node_id">> => BranchId,
                             <<"parent">> => <<"parallel">>}, Env1),
            parallel_run(Branches, Results, Env1);
        {error, Reason} ->
            {failed, {branch_failed, BranchId, Reason}, Env}
    end.

parallel_running_cursor(Results) ->
    #{<<"type">> => <<"parallel">>,
      <<"status">> => <<"running">>,
      <<"results">> => Results}.

parallel_pause_cursor(Results, BranchId, Pause) ->
    #{<<"type">> => <<"parallel">>,
      <<"status">> => <<"awaiting_resume">>,
      <<"results">> => Results,
      <<"paused_branch">> => BranchId,
      <<"pause">> => Pause}.

parallel_result_tuple(Result, Id) ->
    {Id, fork_result_output(Result), fork_result_delta(Result)}.

find_named_action(Id, Actions) ->
    hd([Action || Action <- Actions, maps:get(id, Action) =:= Id]).

merge_parallel(ordered_last_wins, OrderedDeltas, _State, _Env) ->
    {ok, lists:foldl(fun({_Id, Delta}, Acc) -> maps:merge(Acc, Delta) end,
                     #{}, OrderedDeltas)};
merge_parallel(reject_conflicts, OrderedDeltas, _State, _Env) ->
    reject_conflicts(OrderedDeltas, #{}, #{});
merge_parallel({custom, Fun}, OrderedDeltas, State, Env) ->
    Context = action_context(<<"parallel-merge">>, Env, null),
    Closure = fun(_IgnoredState, _IgnoredContext) ->
                      Fun(OrderedDeltas, State)
              end,
    case run_raw(Closure, State, Context, Env) of
        timed_out -> timed_out;
        {error, Reason} -> {error, {merge_failed, Reason}};
        {ok, {ok, Delta}} -> normalize_delta(Delta);
        {ok, Delta} when is_map(Delta) -> normalize_delta(Delta);
        {ok, {error, Reason}} ->
            {error, {merge_failed,
                     adk_workflow:external_reason(
                       adk_workflow_action, merge, Reason)}};
        {ok, _Invalid} -> {error, invalid_merge_result}
    end.

reject_conflicts([], _Owners, Acc) -> {ok, Acc};
reject_conflicts([{Id, Delta} | Rest], Owners0, Acc0) ->
    case maps:fold(
           fun(Key, Value, {ok, Owners, Acc}) ->
                   case maps:find(Key, Acc) of
                       error -> {ok, Owners#{Key => Id}, Acc#{Key => Value}};
                       {ok, Value} -> {ok, Owners, Acc};
                       {ok, _Other} ->
                           {error, {state_conflict, Key,
                                    [maps:get(Key, Owners), Id]}}
                   end;
              (_Key, _Value, Error) -> Error
           end, {ok, Owners0, Acc0}, Delta) of
        {ok, Owners, Acc} -> reject_conflicts(Rest, Owners, Acc);
        {error, _} = Error -> Error
    end.

%% Loop

execute_loop(Env) ->
    Cursor = maps:get(cursor, Env),
    Iteration = maps:get(<<"iteration">>, Cursor),
    case maps:get(<<"phase">>, Cursor, <<"ready">>) of
        <<"awaiting_resume">> -> loop_resume_after_pause(Iteration, Env);
        _ -> loop_from(Iteration, Env)
    end.

loop_from(Iteration, Env0) ->
    Data = workflow_data(Env0),
    MaxIterations = maps:get(max_iterations, Data),
    case Iteration >= MaxIterations of
        true -> {completed, maps:get(state, Env0), Env0};
        false ->
            Body = maps:get(body, Data),
            Id = maps:get(id, Body),
            emit_lifecycle(<<"node_started">>,
                           #{<<"node_id">> => Id,
                             <<"iteration">> => Iteration}, Env0),
            case consume_action_step(Id, Env0) of
                {error, Reason, Env1} -> {failed, Reason, Env1};
                {ok, Env1} ->
                    Context = action_context(Id, Env1, null),
                    case run_action(maps:get(run, Body),
                                    maps:get(state, Env1), Context,
                                    action_policy(Body), Env1) of
                        timed_out -> {timed_out, Env1};
                        {error, Reason} ->
                            {failed, {loop_body_failed, Reason}, Env1};
                        {ok, {ok, Delta}} ->
                            loop_after_body(Iteration, Delta, Env1);
                        {ok, {output, Output, Delta}} ->
                            loop_after_body(Iteration, Delta, Output, Env1);
                        {ok, {stop, Output, Delta}} ->
                            complete_loop_body(Output, Delta, Env1);
                        {ok, {complete, Output, Delta}} ->
                            complete_loop_body(Output, Delta, Env1);
                        {ok, {pause, Pause, Delta}} ->
                            loop_pause_branch(
                              Iteration, Pause, Delta, Env1);
                        {ok, {nested_pause, Pause, ChildCheckpoint}} ->
                            loop_pause_nested(
                              Iteration, Pause, ChildCheckpoint, Env1);
                        {ok, Control} ->
                            {failed,
                             {loop_body_failed,
                              {invalid_control, control_name(Control)}}, Env1}
                    end
            end
    end.

loop_after_body(Iteration, Delta, Env1) ->
    loop_after_body(Iteration, Delta, undefined, Env1).

loop_after_body(Iteration, Delta, Output, Env1) ->
    case merge_delta(Delta, Env1) of
        {error, Reason} -> {failed, {loop_body_failed, Reason}, Env1};
        {ok, MergedEnv} ->
            Env2 = case Output of
                undefined -> MergedEnv;
                _ -> MergedEnv#{output => Output}
            end,
            Data = workflow_data(Env2),
            Context = action_context(<<"loop-until">>, Env2, null),
            case run_raw(maps:get(until, Data), maps:get(state, Env2),
                         Context, Env2) of
                timed_out -> {timed_out, Env2};
                {error, Reason} ->
                    {failed, {loop_predicate_failed, Reason}, Env2};
                {ok, Reply} ->
                    case normalize_predicate(Reply) of
                        done ->
                            emit_lifecycle(<<"node_completed">>,
                                           #{<<"node_id">> =>
                                                 <<"loop-body">>,
                                             <<"iteration">> => Iteration},
                                           Env2),
                            {completed, maps:get(state, Env2), Env2};
                        continue ->
                            NextIteration = Iteration + 1,
                            Cursor = #{<<"type">> => <<"loop">>,
                                       <<"iteration">> => NextIteration},
                            Env3 = commit(Cursor, Env2),
                            emit_lifecycle(<<"node_completed">>,
                                           #{<<"node_id">> =>
                                                 <<"loop-body">>,
                                             <<"iteration">> => Iteration},
                                           Env3),
                            loop_from(NextIteration, Env3);
                        invalid ->
                            {failed, invalid_loop_predicate_result, Env2}
                    end
            end
    end.

complete_loop_body(Output, Delta, Env1) ->
    case merge_delta(Delta, Env1) of
        {ok, Env2} ->
            emit_lifecycle(<<"node_completed">>,
                           #{<<"node_id">> => <<"loop-body">>}, Env2),
            {completed, maps:get(state, Env2), Env2#{output => Output}};
        {error, Reason} ->
            {failed, {loop_body_failed, Reason}, Env1}
    end.

loop_pause_branch(Iteration, Pause0, Delta, Env) ->
    case normalize_delta(Delta) of
        {error, Reason} -> {failed, {loop_body_failed, Reason}, Env};
        {ok, SafeDelta} ->
            Pause = Pause0#{<<"node_id">> => <<"loop-body">>,
                            <<"iteration">> => Iteration},
            Cursor = #{<<"type">> => <<"loop">>,
                       <<"iteration">> => Iteration,
                       <<"phase">> => <<"awaiting_resume">>,
                       <<"resume_kind">> =>
                           pause_resume_kind(Pause, <<"body">>),
                       <<"pause">> => Pause,
                       <<"paused_delta">> => SafeDelta},
            Env1 = commit(Cursor, Env),
            emit_lifecycle(<<"workflow_paused">>,
                           #{<<"node_id">> => <<"loop-body">>,
                             <<"pause_kind">> => <<"loop_body">>}, Env1),
            {paused, Pause, Env1}
    end.

loop_pause_nested(Iteration, Pause0, ChildCheckpoint, Env) ->
    Pause = Pause0#{<<"node_id">> => <<"loop-body">>,
                    <<"iteration">> => Iteration},
    Cursor = #{<<"type">> => <<"loop">>,
               <<"iteration">> => Iteration,
               <<"phase">> => <<"awaiting_resume">>,
               <<"resume_kind">> => <<"nested_workflow">>,
               <<"pause">> => Pause,
               <<"nested_checkpoint">> => ChildCheckpoint},
    Env1 = commit(Cursor, Env),
    emit_lifecycle(<<"workflow_paused">>,
                   #{<<"node_id">> => <<"loop-body">>,
                     <<"pause_kind">> => <<"nested_workflow">>}, Env1),
    {paused, Pause, Env1}.

loop_resume_after_pause(Iteration, Env) ->
    Cursor = maps:get(cursor, Env),
    case maps:find(<<"resume_input">>, Cursor) of
        error -> {failed, {resume_input_required, <<"loop-body">>}, Env};
        {ok, Input} ->
            emit_lifecycle(<<"workflow_resumed">>,
                           #{<<"node_id">> => <<"loop-body">>}, Env),
            case maps:get(<<"resume_kind">>, Cursor) of
                <<"body">> ->
                    loop_after_body(
                      Iteration,
                      maps:get(<<"paused_delta">>, Cursor, #{}), Input, Env);
                <<"tool_confirmation">> ->
                    loop_resume_tool_confirmation(Iteration, Input, Env);
                <<"nested_workflow">> ->
                    loop_resume_nested(Iteration, Input, Env)
            end
    end.

loop_resume_nested(Iteration, Input, Env) ->
    Body = maps:get(body, workflow_data(Env)),
    {workflow, Child, Opts} = maps:get(run, Body),
    Cursor = maps:get(cursor, Env),
    ChildCheckpoint = maps:get(<<"nested_checkpoint">>, Cursor),
    Context = action_context(<<"loop-body">>, Env, null),
    Resume = fun(_State, _AttemptContext) ->
        resume_nested_workflow(Child, Opts, ChildCheckpoint, Input, Context)
    end,
    case run_action(Resume, maps:get(state, Env), Context,
                    action_policy(Body), Env) of
        timed_out -> {timed_out, Env};
        {ok, {nested_pause, Pause, NextCheckpoint}} ->
            loop_pause_nested(Iteration, Pause, NextCheckpoint, Env);
        {ok, {output, Output, Delta}} ->
            loop_after_body(Iteration, Delta, Output, Env);
        {error, Reason} -> {failed, {loop_body_failed, Reason}, Env};
        {ok, Control} ->
            {failed, {loop_body_failed,
                      {invalid_control, control_name(Control)}}, Env}
    end.

loop_resume_tool_confirmation(Iteration, Input, Env) ->
    Body = maps:get(body, workflow_data(Env)),
    case run_resumed_tool_confirmation(
           Body, <<"loop-body">>, null, Input, Env) of
        timed_out -> {timed_out, Env};
        {ok, {ok, Delta}} -> loop_after_body(Iteration, Delta, Env);
        {ok, {output, Output, Delta}} ->
            loop_after_body(Iteration, Delta, Output, Env);
        {ok, {stop, Output, Delta}} ->
            complete_loop_body(Output, Delta, Env);
        {ok, {complete, Output, Delta}} ->
            complete_loop_body(Output, Delta, Env);
        {ok, {pause, Pause, Delta}} ->
            loop_pause_branch(Iteration, Pause, Delta, Env);
        {error, Reason} -> {failed, {loop_body_failed, Reason}, Env};
        {ok, Control} ->
            {failed, {loop_body_failed,
                      {invalid_control, control_name(Control)}}, Env}
    end.

normalize_predicate(true) -> done;
normalize_predicate(done) -> done;
normalize_predicate({ok, true}) -> done;
normalize_predicate(false) -> continue;
normalize_predicate(continue) -> continue;
normalize_predicate({ok, false}) -> continue;
normalize_predicate(_) -> invalid.

%% Transfer / collaborative workflow

execute_transfer(Env) ->
    Cursor = maps:get(cursor, Env),
    Member = maps:get(<<"member">>, Cursor),
    Input = maps:get(<<"input">>, Cursor, null),
    case maps:get(<<"phase">>, Cursor, <<"ready">>) of
        <<"awaiting_resume">> -> transfer_resume_after_pause(Member, Env);
        _ -> transfer_from(Member, Input, Env)
    end.

transfer_from(MemberId, Input, Env0) ->
    Members = maps:get(members, workflow_data(Env0)),
    Member = maps:get(MemberId, Members),
    emit_lifecycle(<<"node_started">>,
                   #{<<"node_id">> => MemberId,
                     <<"node_type">> => <<"transfer_member">>}, Env0),
    case consume_action_step(MemberId, Env0) of
        {error, Reason, Env1} -> {failed, Reason, Env1};
        {ok, Env1} ->
            Context = action_context(MemberId, Env1, Input),
            case run_action(maps:get(run, Member), maps:get(state, Env1),
                            Context, action_policy(Member), Env1) of
                timed_out -> {timed_out, Env1};
                {error, Reason} ->
                    {failed, {member_failed, MemberId, Reason}, Env1};
                {ok, {complete, Output, Delta}} ->
                    complete_transfer_member(MemberId, Output, Delta, Env1);
                {ok, {stop, Output, Delta}} ->
                    complete_transfer_member(MemberId, Output, Delta, Env1);
                {ok, {output, Output, Delta}} ->
                    %% A transfer member has no implicit successor. Returning
                    %% normally therefore completes the transfer workflow;
                    %% another member is reached only through transfer.
                    complete_transfer_member(MemberId, Output, Delta, Env1);
                {ok, {ok, Delta}} ->
                    %% A plain successful member result is terminal.
                    complete_transfer_delta(MemberId, Delta, Env1);
                {ok, {transfer, Target, NextInput, Delta}} ->
                    accept_transfer(MemberId, Target, NextInput, Delta,
                                    Members, Env1);
                {ok, {pause, Pause, Delta}} ->
                    transfer_pause_member(
                      MemberId, Input, Pause, Delta, Env1);
                {ok, {nested_pause, Pause, ChildCheckpoint}} ->
                    transfer_pause_nested(
                      MemberId, Input, Pause, ChildCheckpoint, Env1);
                {ok, Control} ->
                    {failed,
                     {member_failed, MemberId,
                      {invalid_control, control_name(Control)}}, Env1}
            end
    end.

complete_transfer_member(MemberId, Output, Delta, Env1) ->
    case merge_delta(Delta, Env1) of
        {ok, Env2} ->
            emit_lifecycle(<<"node_completed">>,
                           #{<<"node_id">> => MemberId}, Env2),
            {completed, maps:get(state, Env2), Env2#{output => Output}};
        {error, Reason} ->
            {failed, {member_failed, MemberId, Reason}, Env1}
    end.

complete_transfer_delta(MemberId, Delta, Env1) ->
    case merge_delta(Delta, Env1) of
        {ok, Env2} ->
            emit_lifecycle(<<"node_completed">>,
                           #{<<"node_id">> => MemberId}, Env2),
            {completed, maps:get(state, Env2), Env2};
        {error, Reason} ->
            {failed, {member_failed, MemberId, Reason}, Env1}
    end.

accept_transfer(From, Target, NextInput, Delta, Members, Env1) ->
    case is_binary(Target) andalso maps:is_key(Target, Members) of
        false -> {failed, {unknown_transfer_target, Target}, Env1};
        true ->
            case normalize_json_value(NextInput) of
                {error, Reason} ->
                    {failed, {invalid_transfer_input, Reason}, Env1};
                {ok, SafeInput} ->
                    case merge_delta(Delta, Env1) of
                        {error, Reason} ->
                            {failed, {member_failed, From, Reason}, Env1};
                        {ok, Env2} ->
                            case consume_transfer(Env2) of
                                {error, Reason, Env3} ->
                                    {failed, Reason, Env3};
                                {ok, Env3} ->
                                    emit_lifecycle(<<"node_completed">>,
                                                   #{<<"node_id">> => From},
                                                   Env3),
                                    emit_transfer_event(From, Target, Env3),
                                    Cursor = #{<<"type">> => <<"transfer">>,
                                               <<"member">> => Target,
                                               <<"input">> => SafeInput},
                                    Env4 = commit(Cursor, Env3),
                                    transfer_from(Target, SafeInput, Env4)
                            end
                    end
            end
    end.

transfer_pause_member(MemberId, MemberInput, Pause0, Delta, Env) ->
    case normalize_delta(Delta) of
        {error, Reason} -> {failed, {member_failed, MemberId, Reason}, Env};
        {ok, SafeDelta} ->
            Pause = Pause0#{<<"member_id">> => MemberId},
            Cursor = #{<<"type">> => <<"transfer">>,
                       <<"member">> => MemberId,
                       <<"input">> => MemberInput,
                       <<"phase">> => <<"awaiting_resume">>,
                       <<"resume_kind">> =>
                           pause_resume_kind(Pause, <<"member">>),
                       <<"pause">> => Pause,
                       <<"paused_delta">> => SafeDelta},
            Env1 = commit(Cursor, Env),
            emit_lifecycle(<<"workflow_paused">>,
                           #{<<"node_id">> => MemberId,
                             <<"pause_kind">> => <<"transfer_member">>},
                           Env1),
            {paused, Pause, Env1}
    end.

transfer_pause_nested(MemberId, MemberInput, Pause0, ChildCheckpoint, Env) ->
    Pause = Pause0#{<<"member_id">> => MemberId},
    Cursor = #{<<"type">> => <<"transfer">>,
               <<"member">> => MemberId,
               <<"input">> => MemberInput,
               <<"phase">> => <<"awaiting_resume">>,
               <<"resume_kind">> => <<"nested_workflow">>,
               <<"pause">> => Pause,
               <<"nested_checkpoint">> => ChildCheckpoint},
    Env1 = commit(Cursor, Env),
    emit_lifecycle(<<"workflow_paused">>,
                   #{<<"node_id">> => MemberId,
                     <<"pause_kind">> => <<"nested_workflow">>}, Env1),
    {paused, Pause, Env1}.

transfer_resume_after_pause(MemberId, Env) ->
    Cursor = maps:get(cursor, Env),
    case maps:find(<<"resume_input">>, Cursor) of
        error -> {failed, {resume_input_required, MemberId}, Env};
        {ok, Input} ->
            emit_lifecycle(<<"workflow_resumed">>,
                           #{<<"node_id">> => MemberId}, Env),
            case maps:get(<<"resume_kind">>, Cursor) of
                <<"member">> ->
                    complete_transfer_member(
                      MemberId, Input,
                      maps:get(<<"paused_delta">>, Cursor, #{}), Env);
                <<"tool_confirmation">> ->
                    transfer_resume_tool_confirmation(MemberId, Input, Env);
                <<"nested_workflow">> ->
                    transfer_resume_nested(MemberId, Input, Env)
            end
    end.

transfer_resume_nested(MemberId, Input, Env) ->
    Member = maps:get(MemberId, maps:get(members, workflow_data(Env))),
    {workflow, Child, Opts} = maps:get(run, Member),
    Cursor = maps:get(cursor, Env),
    ChildCheckpoint = maps:get(<<"nested_checkpoint">>, Cursor),
    MemberInput = maps:get(<<"input">>, Cursor, null),
    Context = action_context(MemberId, Env, MemberInput),
    Resume = fun(_State, _AttemptContext) ->
        resume_nested_workflow(Child, Opts, ChildCheckpoint, Input, Context)
    end,
    case run_action(Resume, maps:get(state, Env), Context,
                    action_policy(Member), Env) of
        timed_out -> {timed_out, Env};
        {ok, {nested_pause, Pause, NextCheckpoint}} ->
            transfer_pause_nested(
              MemberId, MemberInput, Pause, NextCheckpoint, Env);
        {ok, {output, Output, Delta}} ->
            complete_transfer_member(MemberId, Output, Delta, Env);
        {error, Reason} -> {failed, {member_failed, MemberId, Reason}, Env};
        {ok, Control} ->
            {failed, {member_failed, MemberId,
                      {invalid_control, control_name(Control)}}, Env}
    end.

transfer_resume_tool_confirmation(MemberId, Input, Env) ->
    Member = maps:get(MemberId, maps:get(members, workflow_data(Env))),
    MemberInput = maps:get(<<"input">>, maps:get(cursor, Env), null),
    case run_resumed_tool_confirmation(
           Member, MemberId, MemberInput, Input, Env) of
        timed_out -> {timed_out, Env};
        {ok, {ok, Delta}} ->
            complete_transfer_delta(MemberId, Delta, Env);
        {ok, {output, Output, Delta}} ->
            complete_transfer_member(MemberId, Output, Delta, Env);
        {ok, {stop, Output, Delta}} ->
            complete_transfer_member(MemberId, Output, Delta, Env);
        {ok, {complete, Output, Delta}} ->
            complete_transfer_member(MemberId, Output, Delta, Env);
        {ok, {transfer, Target, NextInput, Delta}} ->
            accept_transfer(
              MemberId, Target, NextInput, Delta,
              maps:get(members, workflow_data(Env)), Env);
        {ok, {pause, Pause, Delta}} ->
            transfer_pause_member(MemberId, MemberInput, Pause, Delta, Env);
        {error, Reason} -> {failed, {member_failed, MemberId, Reason}, Env};
        {ok, Control} ->
            {failed, {member_failed, MemberId,
                      {invalid_control, control_name(Control)}}, Env}
    end.

consume_transfer(Env = #{transfers_remaining := 0}) ->
    {error, {budget_exhausted, transfers}, Env};
consume_transfer(Env) ->
    Remaining = maps:get(transfers_remaining, Env) - 1,
    Env1 = Env#{transfers_remaining => Remaining},
    notify_checkpoint(Env1),
    {ok, Env1}.

emit_transfer_event(From, Target, Env) ->
    Compiled = maps:get(compiled, Env),
    Max = maps:get(transfers_initial, maps:get(runtime, Env)),
    Remaining = maps:get(transfers_remaining, Env),
    Index = Max - Remaining,
    Text = <<"Transfer from ", From/binary, " to ", Target/binary>>,
    Event = adk_event:new(
              From, Text,
              #{invocation_id => invocation_id(Env, maps:get(id, Compiled)),
                actions =>
                    #{<<"transfer_to_agent">> => Target,
                      <<"workflow">> =>
                          #{<<"from_agent">> => From,
                            <<"transfer_index">> => Index}}}),
    maps:get(coordinator, Env) ! {adk_workflow_event, self(), Event},
    ok.

%% Graph

execute_graph(Env) ->
    Cursor = maps:get(cursor, Env),
    NodeId = maps:get(<<"node">>, Cursor),
    case maps:get(<<"phase">>, Cursor, <<"ready">>) of
        <<"ready">> -> graph_from(NodeId, Env);
        <<"routing">> -> graph_route_committed_node(NodeId, Env);
        <<"awaiting_resume">> -> graph_resume_after_pause(NodeId, Env);
        <<"fork">> -> graph_from(NodeId, Env)
    end.

graph_from(NodeId, Env0) ->
    Data = workflow_data(Env0),
    Node = maps:get(NodeId, maps:get(nodes, Data)),
    case validate_graph_node_input(Node, graph_node_input(Env0)) of
        {error, Reason} ->
            {failed, {node_input_schema_validation_failed,
                      NodeId, Reason}, Env0};
        ok ->
            emit_lifecycle(<<"node_started">>,
                           #{<<"node_id">> => NodeId,
                             <<"node_type">> =>
                                 atom_to_binary(
                                   maps:get(type, Node, action), utf8)},
                           Env0),
            case maps:get(type, Node, action) of
                fork -> graph_fork(NodeId, Node, Env0);
                branch -> graph_router(NodeId, Node, Env0);
                dynamic -> graph_router(NodeId, Node, Env0);
                loop -> graph_loop(NodeId, Node, Env0);
                _ -> graph_action(NodeId, Node, Env0)
            end
    end.

graph_action(NodeId, #{run := noop}, Env0) ->
    case consume_action_step(NodeId, Env0) of
        {error, Reason, Env1} -> {failed, Reason, Env1};
        {ok, Env1} ->
            graph_after_node(
              NodeId, default, graph_node_input(Env1), #{}, Env1)
    end;
graph_action(NodeId, Node, Env0) ->
    case consume_action_step(NodeId, Env0) of
        {error, Reason, Env1} -> {failed, Reason, Env1};
        {ok, Env1} ->
            Context = action_context(NodeId, Env1,
                                     graph_node_input(Env1)),
            case run_action(maps:get(run, Node), maps:get(state, Env1),
                            Context, action_policy(Node), Env1) of
                timed_out -> {timed_out, Env1};
                {error, Reason} ->
                    {failed, {node_failed, NodeId, Reason}, Env1};
                {ok, {ok, Delta}} ->
                    graph_after_node(NodeId, default, null, Delta, Env1);
                {ok, {route, Target, Delta}} ->
                    graph_after_node(
                      NodeId, {explicit, Target}, null, Delta, Env1);
                {ok, {pause, Pause, Delta}} ->
                    graph_pause_node(NodeId, Pause, Delta, Env1);
                {ok, {nested_pause, Pause, ChildCheckpoint}} ->
                    graph_pause_nested_workflow(
                      NodeId, Pause, ChildCheckpoint, Env1);
                {ok, {output, Output, Delta}} ->
                    graph_after_node_output(NodeId, Output, Delta, Env1);
                {ok, {stop, Output, Delta}} ->
                    complete_graph_node(NodeId, Output, Delta, Env1);
                {ok, {complete, Output, Delta}} ->
                    complete_graph_node(NodeId, Output, Delta, Env1);
                {ok, Control} ->
                    {failed,
                     {node_failed, NodeId,
                      {invalid_control, control_name(Control)}}, Env1}
            end
    end.

graph_after_node_output(NodeId, Output, Delta, Env1) ->
    graph_after_node(
      NodeId, default, Output, Delta, Env1#{output => Output}).

complete_graph_node(NodeId, Output, Delta, Env1) ->
    case validate_graph_node_output(NodeId, Output, Env1) of
        {error, Reason} ->
            {failed, {node_output_schema_validation_failed,
                      NodeId, Reason}, Env1};
        ok ->
            case merge_delta(Delta, Env1) of
                {ok, Env2} ->
                    emit_lifecycle(<<"node_completed">>,
                                   #{<<"node_id">> => NodeId}, Env2),
                    {completed, maps:get(state, Env2),
                     Env2#{output => Output}};
                {error, Reason} ->
                    {failed, {node_failed, NodeId, Reason}, Env1}
            end
    end.

graph_after_node(NodeId, RouteChoice, NodeOutput, Delta, Env1) ->
    case validate_graph_node_output(NodeId, NodeOutput, Env1) of
        {error, Reason} ->
            {failed, {node_output_schema_validation_failed,
                      NodeId, Reason}, Env1};
        ok ->
            case merge_delta(Delta, Env1) of
                {error, Reason} ->
                    {failed, {node_failed, NodeId, Reason}, Env1};
                {ok, Env2} ->
                    %% Persist the action result before invoking a potentially
                    %% blocking route callback. A resumed workflow therefore
                    %% skips the already committed action and repeats routing.
                    RoutingCursor = graph_routing_cursor(
                                      NodeId, RouteChoice, NodeOutput, Env2),
                    Env3 = commit(RoutingCursor, Env2),
                    emit_lifecycle(<<"node_completed">>,
                                   #{<<"node_id">> => NodeId}, Env3),
                    graph_route_committed_node(NodeId, Env3)
            end
    end.

graph_route_committed_node(NodeId, Env) ->
    Cursor = maps:get(cursor, Env),
    RouteChoice = case maps:find(<<"route_target">>, Cursor) of
        {ok, Target} -> {explicit, decode_end_target(Target)};
        error -> default
    end,
    NodeOutput = maps:get(<<"node_output">>, Cursor, null),
    graph_route_to_next(NodeId, RouteChoice, NodeOutput, Env).

graph_route_to_next(NodeId, RouteChoice, Input, Env) ->
    case determine_graph_target(NodeId, RouteChoice, Input, Env) of
                timed_out -> {timed_out, Env};
                {error, Reason} ->
                    {failed, {route_failed, NodeId, Reason}, Env};
                {ok, end_node} ->
                    emit_lifecycle(<<"route_selected">>,
                                   #{<<"from">> => NodeId,
                                     <<"to">> => <<"$end">>}, Env),
                    {completed, maps:get(state, Env), Env};
                {ok, Target} ->
                    emit_lifecycle(<<"route_selected">>,
                                   #{<<"from">> => NodeId,
                                     <<"to">> => Target}, Env),
                    Env1 = commit(
                             graph_ready_cursor(Target, Input, Env), Env),
                    graph_from(Target, Env1)
    end.

determine_graph_target(_NodeId, {explicit, Target}, _Input, Env) ->
    validate_graph_target(Target, Env);
determine_graph_target(NodeId, default, Input, Env) ->
    Edges = maps:get(edges, workflow_data(Env)),
    case maps:get(NodeId, Edges) of
        end_node -> {ok, end_node};
        Target when is_binary(Target) -> {ok, Target};
        {route, Predicate} ->
            Context = action_context(NodeId, Env, Input),
            case run_raw(Predicate, maps:get(state, Env), Context, Env) of
                timed_out -> timed_out;
                {error, Reason} -> {error, Reason};
                {ok, {ok, Target}} -> validate_graph_target(Target, Env);
                {ok, Target} -> validate_graph_target(Target, Env)
            end
    end.

graph_pause_node(NodeId, Pause0, Delta, Env1) ->
    case merge_delta(Delta, Env1) of
        {error, Reason} -> {failed, {node_failed, NodeId, Reason}, Env1};
        {ok, Env2} ->
            Pause = Pause0#{<<"node_id">> => NodeId},
            Cursor = graph_cursor_base(NodeId, <<"awaiting_resume">>, Env2),
            Env3 = commit(Cursor#{<<"pause">> => Pause,
                                  <<"resume_kind">> =>
                                      pause_resume_kind(Pause, <<"node">>)},
                                  Env2),
            emit_lifecycle(<<"workflow_paused">>,
                           #{<<"node_id">> => NodeId,
                             <<"pause_kind">> => <<"node">>}, Env3),
            {paused, Pause, Env3}
    end.

graph_pause_nested_workflow(NodeId, Pause0, ChildCheckpoint, Env) ->
    Pause1 = case maps:find(<<"node_id">>, Pause0) of
        {ok, ChildNodeId} ->
            Pause0#{<<"nested_node_id">> => ChildNodeId};
        error -> Pause0
    end,
    Pause = Pause1#{<<"node_id">> => NodeId},
    Cursor = graph_cursor_base(NodeId, <<"awaiting_resume">>, Env),
    Env1 = commit(Cursor#{<<"pause">> => Pause,
                           <<"resume_kind">> => <<"nested_workflow">>,
                           <<"nested_checkpoint">> => ChildCheckpoint}, Env),
    emit_lifecycle(<<"workflow_paused">>,
                   #{<<"node_id">> => NodeId,
                     <<"pause_kind">> => <<"nested_workflow">>}, Env1),
    {paused, Pause, Env1}.

graph_resume_after_pause(NodeId, Env) ->
    Cursor = maps:get(cursor, Env),
    case maps:find(<<"resume_input">>, Cursor) of
        error -> {failed, {resume_input_required, NodeId}, Env};
        {ok, Input} ->
            emit_lifecycle(<<"workflow_resumed">>,
                           #{<<"node_id">> => NodeId}, Env),
            case maps:get(<<"resume_kind">>, Cursor, <<"node">>) of
                <<"fork_branch">> ->
                    Results0 = maps:get(<<"fork_results">>, Cursor, #{}),
                    Pause = maps:get(<<"pause">>, Cursor, #{}),
                    BranchId = maps:get(
                                 <<"paused_branch">>, Cursor,
                                 maps:get(<<"node_id">>, Pause)),
                    PausedDelta = maps:get(
                                    <<"paused_delta">>, Cursor,
                                    fork_result_delta(
                                      maps:get(BranchId, Results0, #{}))),
                    case validate_fork_branch_output(
                           BranchId, Input, Env) of
                        {error, Reason} ->
                            {failed, {fork_branch_failed, BranchId,
                                      {output_schema_validation_failed,
                                       Reason}}, Env};
                        ok ->
                            Results = (maps:remove(BranchId, Results0))#{
                                        BranchId =>
                                            fork_result(Input, PausedDelta)},
                            ForkCursor = graph_fork_cursor(
                                           NodeId, Results, Env),
                            Env1 = commit(ForkCursor, Env),
                            emit_lifecycle(
                              <<"node_completed">>,
                              #{<<"node_id">> => BranchId,
                                <<"parent">> => NodeId}, Env1),
                            graph_from(NodeId, Env1)
                    end;
                <<"fork_nested_workflow">> ->
                    graph_resume_fork_nested_workflow(NodeId, Input, Env);
                <<"fork_tool_confirmation">> ->
                    graph_resume_fork_tool_confirmation(NodeId, Input, Env);
                <<"nested_workflow">> ->
                    graph_resume_nested_workflow(NodeId, Input, Env);
                <<"node">> ->
                    graph_after_node(NodeId, default, Input, #{}, Env);
                <<"tool_confirmation">> ->
                    graph_resume_tool_confirmation(NodeId, Input, Env)
            end
    end.

graph_resume_nested_workflow(NodeId, Input, Env) ->
    Cursor = maps:get(cursor, Env),
    ChildCheckpoint = maps:get(<<"nested_checkpoint">>, Cursor),
    Node = maps:get(NodeId, maps:get(nodes, workflow_data(Env))),
    {workflow, Child, Opts} = maps:get(run, Node),
    Context = action_context(NodeId, Env, graph_node_input(Env)),
    Resume = fun(_State, _AttemptContext) ->
        resume_nested_workflow(Child, Opts, ChildCheckpoint,
                               Input, Context)
    end,
    case run_action(Resume, maps:get(state, Env), Context,
                    action_policy(Node), Env) of
        timed_out -> {timed_out, Env};
        {ok, {nested_pause, Pause, NextChildCheckpoint}} ->
            graph_pause_nested_workflow(
              NodeId, Pause, NextChildCheckpoint, Env);
        {ok, {output, Output, Delta}} ->
            graph_after_node_output(NodeId, Output, Delta, Env);
        {error, Reason} ->
            {failed, {node_failed, NodeId, Reason}, Env};
        {ok, Control} ->
            {failed,
             {node_failed, NodeId,
             {invalid_control, control_name(Control)}}, Env}
    end.

graph_resume_tool_confirmation(NodeId, Input, Env) ->
    Node = maps:get(NodeId, maps:get(nodes, workflow_data(Env))),
    case run_resumed_tool_confirmation(
           Node, NodeId, graph_node_input(Env), Input, Env) of
        timed_out -> {timed_out, Env};
        {ok, {ok, Delta}} ->
            graph_after_node(NodeId, default, null, Delta, Env);
        {ok, {route, Target, Delta}} ->
            graph_after_node(NodeId, {explicit, Target}, null, Delta, Env);
        {ok, {output, Output, Delta}} ->
            graph_after_node_output(NodeId, Output, Delta, Env);
        {ok, {stop, Output, Delta}} ->
            complete_graph_node(NodeId, Output, Delta, Env);
        {ok, {complete, Output, Delta}} ->
            complete_graph_node(NodeId, Output, Delta, Env);
        {ok, {pause, Pause, Delta}} ->
            graph_pause_node(NodeId, Pause, Delta, Env);
        {error, Reason} -> {failed, {node_failed, NodeId, Reason}, Env};
        {ok, Control} ->
            {failed, {node_failed, NodeId,
                      {invalid_control, control_name(Control)}}, Env}
    end.

graph_resume_fork_nested_workflow(NodeId, Input, Env) ->
    Cursor = maps:get(cursor, Env),
    BranchId = maps:get(<<"paused_branch">>, Cursor),
    ChildCheckpoint = maps:get(<<"nested_checkpoint">>, Cursor),
    Branch = maps:get(BranchId, maps:get(nodes, workflow_data(Env))),
    {workflow, Child, Opts} = maps:get(run, Branch),
    Context = action_context(BranchId, Env, graph_node_input(Env)),
    Resume = fun(_State, _AttemptContext) ->
        resume_nested_workflow(Child, Opts, ChildCheckpoint,
                               Input, Context)
    end,
    case run_action(Resume, maps:get(state, Env), Context,
                    action_policy(Branch), Env) of
        timed_out -> {timed_out, Env};
        {ok, {nested_pause, Pause, NextChildCheckpoint}} ->
            graph_pause_fork_nested_workflow(
              NodeId, BranchId, Pause, NextChildCheckpoint,
              maps:get(<<"fork_results">>, Cursor, #{}), Env);
        {ok, {output, Output, Delta}} ->
            graph_resume_fork_record(
              NodeId, BranchId, Output, Delta,
              maps:get(<<"fork_results">>, Cursor, #{}), Env);
        {error, Reason} ->
            {failed, {fork_branch_failed, BranchId, Reason}, Env};
        {ok, Control} ->
            {failed,
             {fork_branch_failed, BranchId,
             {invalid_control, control_name(Control)}}, Env}
    end.

graph_resume_fork_tool_confirmation(NodeId, Input, Env) ->
    Cursor = maps:get(cursor, Env),
    BranchId = maps:get(<<"paused_branch">>, Cursor),
    Results0 = maps:get(<<"fork_results">>, Cursor, #{}),
    Branch = maps:get(BranchId, maps:get(nodes, workflow_data(Env))),
    case run_resumed_tool_confirmation(
           Branch, BranchId, graph_node_input(Env), Input, Env) of
        timed_out -> {timed_out, Env};
        {ok, {ok, Delta}} ->
            graph_resume_fork_record(
              NodeId, BranchId, null, Delta, Results0, Env);
        {ok, {output, Output, Delta}} ->
            graph_resume_fork_record(
              NodeId, BranchId, Output, Delta, Results0, Env);
        {ok, {stop, Output, Delta}} ->
            graph_resume_fork_record(
              NodeId, BranchId, Output, Delta, Results0, Env);
        {ok, {complete, Output, Delta}} ->
            graph_resume_fork_record(
              NodeId, BranchId, Output, Delta, Results0, Env);
        {ok, {pause, Pause0, Delta}} ->
            case normalize_delta(Delta) of
                {ok, SafeDelta} ->
                    Pause = Pause0#{<<"node_id">> => BranchId,
                                    <<"fork_id">> => NodeId},
                    PauseCursor = graph_cursor_base(
                                    NodeId, <<"awaiting_resume">>, Env),
                    Env1 = commit(
                             PauseCursor#{
                               <<"pause">> => Pause,
                               <<"resume_kind">> =>
                                   fork_pause_resume_kind(Pause),
                               <<"fork_results">> => Results0,
                               <<"failed_branches">> =>
                                   graph_failed_branches(Env),
                               <<"paused_branch">> => BranchId,
                               <<"paused_delta">> => SafeDelta}, Env),
                    {paused, Pause, Env1};
                {error, Reason} ->
                    {failed, {fork_branch_failed, BranchId, Reason}, Env}
            end;
        {error, Reason} ->
            {failed, {fork_branch_failed, BranchId, Reason}, Env};
        {ok, Control} ->
            {failed, {fork_branch_failed, BranchId,
                      {invalid_control, control_name(Control)}}, Env}
    end.

graph_resume_fork_record(NodeId, BranchId, Output, Delta, Results0, Env) ->
    case validate_fork_branch_output(BranchId, Output, Env) of
        {error, Reason} ->
            {failed, {fork_branch_failed, BranchId,
                      {output_schema_validation_failed, Reason}}, Env};
        ok ->
            case normalize_delta(Delta) of
                {error, Reason} ->
                    {failed, {fork_branch_failed, BranchId, Reason}, Env};
                {ok, SafeDelta} ->
                    Results = Results0#{
                                BranchId => fork_result(Output, SafeDelta)},
                    ForkCursor = graph_fork_cursor(NodeId, Results, Env),
                    Env1 = commit(ForkCursor, Env),
                    emit_lifecycle(<<"node_completed">>,
                                   #{<<"node_id">> => BranchId,
                                     <<"parent">> => NodeId}, Env1),
                    graph_from(NodeId, Env1)
            end
    end.

graph_router(NodeId, Node, Env0) ->
    case consume_action_step(NodeId, Env0) of
        {error, Reason, Env1} -> {failed, Reason, Env1};
        {ok, Env1} ->
            Context = action_context(NodeId, Env1,
                                     graph_node_input(Env1)),
            case run_raw(maps:get(choose, Node), maps:get(state, Env1),
                         Context, Env1) of
                timed_out -> {timed_out, Env1};
                {error, Reason} ->
                    {failed, {route_failed, NodeId, Reason}, Env1};
                {ok, Raw} -> graph_router_result(NodeId, Node, Raw, Env1)
            end
    end.

graph_router_result(NodeId, Node, {ok, Target}, Env) ->
    graph_router_result(NodeId, Node, Target, Env);
graph_router_result(NodeId, Node, {route, Target, Delta}, Env)
  when is_map(Delta) ->
    graph_router_commit(NodeId, Node, Target, Delta, Env);
graph_router_result(NodeId, Node, Target, Env) ->
    graph_router_commit(NodeId, Node, Target, #{}, Env).

graph_router_commit(NodeId, Node, Target0, Delta, Env1) ->
    Target = decode_end_target(Target0),
    case lists:member(Target0, maps:get(targets, Node))
         orelse lists:member(Target, maps:get(targets, Node)) of
        false ->
            {failed, {route_failed, NodeId,
                      {target_not_allowed, Target0}}, Env1};
        true ->
            case validate_graph_target(Target, Env1) of
                {error, Reason} ->
                    {failed, {route_failed, NodeId, Reason}, Env1};
                {ok, _} -> graph_after_routed_node(NodeId, Target, Delta, Env1)
            end
    end.

graph_after_routed_node(NodeId, Target, Delta, Env1) ->
    graph_after_node(NodeId, {explicit, Target},
                     graph_node_input(Env1), Delta, Env1).

graph_loop(NodeId, Node, Env0) ->
    case consume_action_step(NodeId, Env0) of
        {error, Reason, Env1} -> {failed, Reason, Env1};
        {ok, Env1} ->
            Context = action_context(NodeId, Env1,
                                     graph_node_input(Env1)),
            case run_raw(maps:get(decide, Node), maps:get(state, Env1),
                         Context, Env1) of
                timed_out -> {timed_out, Env1};
                {error, Reason} ->
                    {failed, {graph_loop_failed, NodeId, Reason}, Env1};
                {ok, Reply} -> graph_loop_decision(NodeId, Node, Reply, Env1)
            end
    end.

graph_loop_decision(NodeId, Node, Reply, Env) ->
    case normalize_graph_while(Reply) of
        done -> graph_loop_target(NodeId, maps:get(done, Node), Env);
        continue ->
            Visits = graph_visits(Env),
            Count = maps:get(NodeId, Visits, 0),
            Max = maps:get(max_iterations, Node),
            case Count >= Max of
                true ->
                    graph_loop_target(NodeId, maps:get(done, Node), Env);
                false ->
                    graph_loop_target(
                      NodeId, maps:get(body, Node),
                      Env#{cursor => (maps:get(cursor, Env))#{
                              <<"visits">> => Visits#{NodeId => Count + 1}}})
            end;
        invalid ->
            {failed, {graph_loop_failed, NodeId,
                      invalid_predicate_result}, Env}
    end.

normalize_graph_while(true) -> continue;
normalize_graph_while(continue) -> continue;
normalize_graph_while({ok, true}) -> continue;
normalize_graph_while(false) -> done;
normalize_graph_while(done) -> done;
normalize_graph_while({ok, false}) -> done;
normalize_graph_while(_) -> invalid.

graph_loop_target(NodeId, Target0, Env) ->
    Target = decode_end_target(Target0),
    graph_after_node(NodeId, {explicit, Target},
                     graph_node_input(Env), #{}, Env).

graph_fork(NodeId, Node, Env0) ->
    Cursor0 = maps:get(cursor, Env0),
    Results = case maps:get(<<"phase">>, Cursor0, <<"ready">>) of
        <<"fork">> -> maps:get(<<"results">>, Cursor0, #{});
        _ -> #{}
    end,
    FailedBranches = case maps:get(<<"phase">>, Cursor0, <<"ready">>) of
        <<"fork">> -> graph_failed_branches(Env0);
        _ -> #{}
    end,
    emit_lifecycle(<<"fork_started">>,
                   #{<<"node_id">> => NodeId,
                     <<"branch_count">> => length(maps:get(branches, Node)),
                     <<"completed_count">> => map_size(Results)}, Env0),
    Env1 = case maps:get(<<"phase">>, Cursor0, <<"ready">>) of
        <<"fork">> -> Env0;
        _ -> commit(graph_fork_cursor(NodeId, Results, Env0), Env0)
    end,
    Branches = maps:get(branches, Node),
    Pending0 = [{Index, Id} || {Index, Id} <-
                                  lists:zip(lists:seq(1, length(Branches)),
                                            Branches),
                              not maps:is_key(Id, Results),
                              not maps:is_key(Id, FailedBranches)],
    case fork_join_ready(Node, Results) of
        true -> graph_fork_finish(NodeId, Node, Results, Env1);
        false when Pending0 =:= [] ->
            {failed, {fork_join_unsatisfied, NodeId}, Env1};
        false ->
            RuntimeMax = maps:get(max_concurrency, maps:get(runtime, Env1)),
            Max = erlang:min(maps:get(max_concurrency, Node), RuntimeMax),
            case graph_fork_fill(Pending0, #{}, Max, Node, Env1) of
                {error, Reason, Active, Env2} ->
                    kill_active(Active),
                    {failed, Reason, Env2};
                {ok, Pending, Active, Env2} ->
                    graph_fork_collect(NodeId, Node, Pending, Active,
                                       Results, Max, Env2)
            end
    end.

graph_fork_fill(Pending, Active, Max, _Node, Env)
  when map_size(Active) >= Max; Pending =:= [] ->
    {ok, Pending, Active, Env};
graph_fork_fill([{Index, BranchId} | Rest], Active, Max, Node, Env0) ->
    Branch = maps:get(BranchId, maps:get(nodes, workflow_data(Env0))),
    case validate_graph_node_input(Branch, graph_node_input(Env0)) of
        {error, Reason} ->
            BranchReason = {input_schema_validation_failed, Reason},
            case maps:get(join_policy, Node, all) of
                first_success ->
                    Env1 = record_graph_fork_failure(
                             maps:get(id, Node), BranchId, Env0),
                    emit_lifecycle(<<"node_failed">>,
                                   #{<<"node_id">> => BranchId,
                                     <<"parent">> => maps:get(id, Node)},
                                   Env1),
                    graph_fork_fill(Rest, Active, Max, Node, Env1);
                _ ->
                    {error, {fork_branch_failed, BranchId, BranchReason},
                     Active, Env0}
            end;
        ok ->
            case consume_action_step(BranchId, Env0) of
                {error, Reason, Env1} -> {error, Reason, Active, Env1};
                {ok, Env1} ->
                    emit_lifecycle(<<"node_started">>,
                                   #{<<"node_id">> => BranchId,
                                     <<"parent">> => maps:get(id, Node)},
                                   Env1),
                    Context = action_context(BranchId, Env1,
                                             graph_node_input(Env1)),
                    Job = spawn_action_worker(maps:get(run, Branch),
                                              maps:get(state, Env1), Context,
                                              Index, BranchId,
                                              action_policy(Branch)),
                    graph_fork_fill(
                      Rest, Active#{maps:get(job_ref, Job) => Job},
                      Max, Node, Env1)
            end
    end.

graph_fork_collect(NodeId, Node, Pending, Active, Results, Max, Env) ->
    case fork_join_ready(Node, Results) of
        true ->
            cancel_active_attempts(Active),
            kill_active(Active),
            graph_fork_finish(NodeId, Node, Results, Env);
        false ->
            case {Pending, map_size(Active)} of
                {[], 0} ->
                    {failed, {fork_join_unsatisfied, NodeId}, Env};
                _ -> graph_fork_receive(NodeId, Node, Pending, Active,
                                        Results, Max, Env)
            end
    end.

graph_fork_receive(NodeId, Node, Pending, Active, Results, Max, Env) ->
    Timeout = remaining_timeout(maps:get(deadline, Env)),
    CoordinatorRef = maps:get(coordinator_ref, Env),
    Coordinator = maps:get(coordinator, Env),
    receive
        {adk_workflow_attempt_started, Pid, AttemptRef, JobRef,
         Id, Attempt}
          when is_pid(Pid), is_reference(AttemptRef),
               is_map_key(JobRef, Active) ->
            Job = maps:get(JobRef, Active),
            true = maps:get(pid, Job) =:= Pid,
            record_attempt(Job, Id, Attempt, Env),
            Pid ! {adk_workflow_attempt_ack, AttemptRef},
            graph_fork_collect(NodeId, Node, Pending, Active,
                               Results, Max, Env);
        {adk_workflow_worker, JobRef, Pid, Raw}
          when is_map_key(JobRef, Active) ->
            Job = maps:get(JobRef, Active),
            true = maps:get(pid, Job) =:= Pid,
            complete_attempt(Job, Raw),
            cleanup_job(Job),
            Active1 = maps:remove(JobRef, Active),
            graph_fork_worker_result(NodeId, Node, Pending, Active1,
                                     Results, Max, Env, Job,
                                     normalize_action(Raw));
        {'DOWN', CoordinatorRef, process, Coordinator, _Reason} ->
            kill_active(Active),
            erlang:exit(coordinator_down);
        {'DOWN', Monitor, process, _Pid, Reason} ->
            case find_job_by_monitor(Monitor, Active) of
                {ok, JobRef, Job} ->
                    Active1 = maps:remove(JobRef, Active),
                    flush_exit(maps:get(pid, Job)),
                    graph_fork_failed(
                      NodeId, Node, Pending, Active1, Results, Max, Env,
                      Job,
                      {worker_down,
                       adk_workflow:external_reason(
                         adk_workflow_action, process_down, Reason)});
                error ->
                    graph_fork_collect(NodeId, Node, Pending, Active,
                                       Results, Max, Env)
            end;
        {'EXIT', _Pid, _Reason} ->
            graph_fork_collect(NodeId, Node, Pending, Active,
                               Results, Max, Env)
    after Timeout ->
        kill_active(Active),
        {timed_out, Env}
    end.

graph_fork_worker_result(NodeId, Node, Pending, Active, Results, Max,
                         Env, Job, {ok, {ok, Delta}}) ->
    graph_fork_record(NodeId, Node, Pending, Active, Results, Max,
                      Env, Job, null, Delta);
graph_fork_worker_result(NodeId, Node, Pending, Active, Results, Max,
                         Env, Job, {ok, {output, Output, Delta}}) ->
    graph_fork_record(NodeId, Node, Pending, Active, Results, Max,
                      Env, Job, Output, Delta);
graph_fork_worker_result(NodeId, Node, Pending, Active, Results, Max,
                         Env, Job, {ok, {stop, Output, Delta}}) ->
    graph_fork_record(NodeId, Node, Pending, Active, Results, Max,
                      Env, Job, Output, Delta);
graph_fork_worker_result(NodeId, Node, Pending, Active, Results, Max,
                         Env, Job, {ok, {complete, Output, Delta}}) ->
    graph_fork_record(NodeId, Node, Pending, Active, Results, Max,
                      Env, Job, Output, Delta);
graph_fork_worker_result(NodeId, _Node, _Pending, Active, Results, _Max,
                         Env, Job, {ok, {pause, Pause0, Delta}}) ->
    kill_active(Active),
    case normalize_delta(Delta) of
        {error, Reason} ->
            {failed, {fork_branch_failed, maps:get(id, Job), Reason}, Env};
        {ok, SafeDelta} ->
            BranchId = maps:get(id, Job),
            Pause = Pause0#{<<"node_id">> => BranchId,
                            <<"fork_id">> => NodeId},
            Cursor = graph_cursor_base(NodeId, <<"awaiting_resume">>, Env),
            Env1 = commit(Cursor#{<<"pause">> => Pause,
                                  <<"resume_kind">> =>
                                      fork_pause_resume_kind(Pause),
                                  <<"fork_results">> => Results,
                                  <<"failed_branches">> =>
                                      graph_failed_branches(Env),
                                  <<"paused_branch">> => BranchId,
                                  <<"paused_delta">> => SafeDelta}, Env),
            {paused, Pause, Env1}
    end;
graph_fork_worker_result(NodeId, _Node, _Pending, Active, Results, _Max,
                         Env, Job,
                         {ok, {nested_pause, Pause, ChildCheckpoint}}) ->
    kill_active(Active),
    graph_pause_fork_nested_workflow(
      NodeId, maps:get(id, Job), Pause, ChildCheckpoint, Results, Env);
graph_fork_worker_result(NodeId, Node, Pending, Active, Results, Max,
                         Env, Job, {ok, Control}) ->
    graph_fork_failed(
      NodeId, Node, Pending, Active, Results, Max, Env, Job,
      {invalid_control, control_name(Control)});
graph_fork_worker_result(NodeId, Node, Pending, Active, Results, Max,
                         Env, Job, {error, Reason}) ->
    graph_fork_failed(NodeId, Node, Pending, Active, Results, Max,
                      Env, Job, Reason);
graph_fork_worker_result(_NodeId, _Node, _Pending, Active, _Results, _Max,
                         Env, _Job, timed_out) ->
    kill_active(Active),
    {timed_out, Env}.

graph_pause_fork_nested_workflow(NodeId, BranchId, Pause0,
                                 ChildCheckpoint, Results, Env) ->
    Pause1 = case maps:find(<<"node_id">>, Pause0) of
        {ok, ChildNodeId} ->
            Pause0#{<<"nested_node_id">> => ChildNodeId};
        error -> Pause0
    end,
    Pause = Pause1#{<<"node_id">> => BranchId,
                    <<"fork_id">> => NodeId},
    Cursor = graph_cursor_base(NodeId, <<"awaiting_resume">>, Env),
    Env1 = commit(Cursor#{<<"pause">> => Pause,
                           <<"resume_kind">> =>
                               <<"fork_nested_workflow">>,
                           <<"fork_results">> => Results,
                           <<"failed_branches">> =>
                               graph_failed_branches(Env),
                           <<"paused_branch">> => BranchId,
                           <<"nested_checkpoint">> => ChildCheckpoint}, Env),
    {paused, Pause, Env1}.

graph_fork_record(NodeId, Node, Pending0, Active0, Results0, Max,
                  Env0, Job, Output, Delta) ->
    BranchId = maps:get(id, Job),
    case validate_fork_branch_output(BranchId, Output, Env0) of
        {error, Reason} ->
            graph_fork_failed(
              NodeId, Node, Pending0, Active0, Results0, Max,
              Env0, Job, {output_schema_validation_failed, Reason});
        ok ->
            case normalize_delta(Delta) of
                {error, Reason} ->
                    graph_fork_failed(
                      NodeId, Node, Pending0, Active0, Results0, Max,
                      Env0, Job, Reason);
                {ok, SafeDelta} ->
                    Results = Results0#{
                                BranchId => fork_result(Output, SafeDelta)},
                    Cursor = graph_fork_cursor(NodeId, Results, Env0),
                    Env1 = commit(Cursor, Env0),
                    emit_lifecycle(<<"node_completed">>,
                                   #{<<"node_id">> => BranchId,
                                     <<"parent">> => NodeId}, Env1),
                    case fork_join_ready(Node, Results) of
                        true ->
                            cancel_active_attempts(Active0),
                            kill_active(Active0),
                            graph_fork_finish(
                              NodeId, Node, Results, Env1);
                        false ->
                            case graph_fork_fill(
                                   Pending0, Active0, Max, Node, Env1) of
                                {error, Reason, Active, Env2} ->
                                    kill_active(Active),
                                    {failed, Reason, Env2};
                                {ok, Pending, Active, Env2} ->
                                    graph_fork_collect(
                                      NodeId, Node, Pending, Active,
                                      Results, Max, Env2)
                            end
                    end
            end
    end.

graph_fork_failed(NodeId, Node, Pending0, Active0, Results, Max,
                  Env0, Job, Reason) ->
    fail_attempt(Job),
    case maps:get(join_policy, Node, all) of
        first_success ->
            Env1 = record_graph_fork_failure(
                     NodeId, maps:get(id, Job), Env0),
            emit_lifecycle(<<"node_failed">>,
                           #{<<"node_id">> => maps:get(id, Job),
                             <<"parent">> => NodeId}, Env1),
            case graph_fork_fill(Pending0, Active0, Max, Node, Env1) of
                {error, FillReason, Active, Env2} ->
                    kill_active(Active),
                    {failed, FillReason, Env2};
                {ok, Pending, Active, Env2} ->
                    graph_fork_collect(NodeId, Node, Pending, Active,
                                       Results, Max, Env2)
            end;
        _ ->
            kill_active(Active0),
            {failed, {fork_branch_failed, maps:get(id, Job), Reason}, Env0}
    end.

graph_fork_finish(NodeId, Node, Results, Env0) ->
    CompletedIds = [Id || Id <- maps:get(branches, Node),
                          maps:is_key(Id, Results)],
    Ordered = [{Id, fork_result_delta(maps:get(Id, Results))}
               || Id <- CompletedIds],
    Outputs = maps:from_list(
                [{Id, fork_result_output(maps:get(Id, Results))}
                 || Id <- CompletedIds]),
    case validate_graph_node_output(Node, Outputs) of
        {error, Reason} ->
            {failed, {node_output_schema_validation_failed,
                      NodeId, Reason}, Env0};
        ok ->
            graph_fork_finish_validated(
              NodeId, Node, Results, Ordered, Outputs, Env0)
    end.

graph_fork_finish_validated(NodeId, Node, Results, Ordered, Outputs, Env0) ->
    case merge_parallel(maps:get(merge, Node), Ordered,
                        maps:get(state, Env0), Env0) of
        timed_out -> {timed_out, Env0};
        {error, Reason} ->
            {failed, {fork_merge_failed, NodeId, Reason}, Env0};
        {ok, Delta} ->
            case merge_delta(Delta, Env0) of
                {error, Reason} ->
                    {failed, {fork_merge_failed, NodeId, Reason}, Env0};
                {ok, Env1} ->
                    Join = maps:get(join, Node),
                    emit_lifecycle(<<"node_completed">>,
                                   #{<<"node_id">> => NodeId}, Env1),
                    emit_lifecycle(<<"join_completed">>,
                                   #{<<"fork_id">> => NodeId,
                                     <<"join_id">> => Join,
                                     <<"branch_count">> =>
                                         map_size(Results)}, Env1),
                    EnvWithOutput = Env1#{output => Outputs},
                    Env2 = commit(
                             graph_ready_cursor(
                               Join, Outputs, EnvWithOutput),
                             EnvWithOutput),
                    graph_from(Join, Env2)
            end
    end.

fork_join_ready(Node, Results) ->
    Count = map_size(Results),
    case maps:get(join_policy, Node, all) of
        all -> Count =:= length(maps:get(branches, Node));
        any -> Count >= 1;
        first_success -> Count >= 1;
        {quorum, Required} -> Count >= Required
    end.

cancel_active_attempts(Active) ->
    lists:foreach(
      fun(Job) ->
          AttemptKey = maps:get(attempt_key, Job),
          case maps:get(AttemptKey, attempts(), undefined) of
              #{<<"status">> := <<"running">>} = Entry ->
                  put(?ATTEMPTS_KEY,
                      (attempts())#{
                        AttemptKey =>
                            Entry#{<<"status">> => <<"cancelled">>}});
              _ -> ok
          end
      end, maps:values(Active)),
    ok.

fail_attempt(Job) ->
    AttemptKey = maps:get(attempt_key, Job),
    case maps:get(AttemptKey, attempts(), undefined) of
        Entry when is_map(Entry) ->
            put(?ATTEMPTS_KEY,
                (attempts())#{AttemptKey =>
                                  Entry#{<<"status">> => <<"failed">>}}),
            ok;
        _ -> ok
    end.

fork_result(Output, Delta) ->
    #{<<"result_version">> => 1,
      <<"output">> => Output,
      <<"delta">> => Delta}.

fork_result_output(#{<<"result_version">> := 1,
                     <<"output">> := Output}) -> Output;
fork_result_output(_LegacyDelta) -> null.

fork_result_delta(#{<<"result_version">> := 1,
                    <<"delta">> := Delta}) -> Delta;
fork_result_delta(LegacyDelta) when is_map(LegacyDelta) -> LegacyDelta.

graph_cursor_base(NodeId, Phase, Env) ->
    Base = #{<<"type">> => <<"graph">>,
             <<"node">> => NodeId,
             <<"phase">> => Phase,
             <<"visits">> => graph_visits(Env)},
    case maps:find(<<"input">>, maps:get(cursor, Env)) of
        {ok, Input} -> Base#{<<"input">> => Input};
        error -> Base
    end.

graph_fork_cursor(NodeId, Results, Env) ->
    (graph_cursor_base(NodeId, <<"fork">>, Env))#{
      <<"results">> => Results,
      <<"failed_branches">> => graph_failed_branches(Env)}.

graph_failed_branches(Env) ->
    maps:get(<<"failed_branches">>, maps:get(cursor, Env), #{}).

record_graph_fork_failure(NodeId, BranchId, Env) ->
    Cursor = maps:get(cursor, Env),
    Results = maps:get(<<"results">>, Cursor,
                       maps:get(<<"fork_results">>, Cursor, #{})),
    Failed = graph_failed_branches(Env),
    commit((graph_cursor_base(NodeId, <<"fork">>, Env))#{
             <<"results">> => Results,
             <<"failed_branches">> => Failed#{BranchId => true}}, Env).

graph_ready_cursor(NodeId, Input, Env) ->
    (graph_cursor_base(NodeId, <<"ready">>, Env))#{
        <<"input">> => Input}.

graph_routing_cursor(NodeId, default, NodeOutput, Env) ->
    (graph_cursor_base(NodeId, <<"routing">>, Env))#{
        <<"node_output">> => NodeOutput};
graph_routing_cursor(NodeId, {explicit, Target}, NodeOutput, Env) ->
    (graph_cursor_base(NodeId, <<"routing">>, Env))#{
        <<"route_target">> => encode_end_target(Target),
        <<"node_output">> => NodeOutput}.

graph_node_input(Env) ->
    maps:get(<<"input">>, maps:get(cursor, Env), null).

validate_graph_node_input(Node, Input) ->
    Schema = maps:get(input_schema, Node, undefined),
    validate_graph_schema(Schema, Input).

validate_graph_node_output(NodeId, Output, Env) ->
    Node = maps:get(NodeId, maps:get(nodes, workflow_data(Env))),
    validate_graph_node_output(Node, Output).

validate_graph_node_output(Node, Output) ->
    Schema = maps:get(output_schema, Node, undefined),
    validate_graph_schema(Schema, Output).

validate_fork_branch_output(BranchId, Output, Env) ->
    Branch = maps:get(BranchId, maps:get(nodes, workflow_data(Env))),
    validate_graph_node_output(Branch, Output).

validate_graph_schema(Schema, Value) ->
    case adk_json_schema:validate_compiled(Schema, Value) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

graph_visits(Env) ->
    maps:get(<<"visits">>, maps:get(cursor, Env), #{}).

encode_end_target(end_node) -> <<"$end">>;
encode_end_target(Target) -> Target.

decode_end_target(end_node) -> end_node;
decode_end_target(<<"$end">>) -> end_node;
decode_end_target(Target) -> Target.

validate_graph_target(end_node, _Env) -> {ok, end_node};
validate_graph_target(<<"$end">>, _Env) -> {ok, end_node};
validate_graph_target(Target, Env) when is_binary(Target) ->
    case maps:is_key(Target, maps:get(nodes, workflow_data(Env))) of
        true -> {ok, Target};
        false -> {error, {invalid_route, Target}}
    end;
validate_graph_target(_Target, _Env) -> {error, invalid_route}.

%% Worker execution and result normalization

run_action(Action, State, Context, Policy, Env) ->
    case run_raw(Action, State, Context, Policy, Env) of
        {ok, Raw} -> normalize_action(Raw);
        Other -> Other
    end.

run_raw(Action, State, Context, Env) ->
    run_raw(Action, State, Context, default_action_policy(), Env).

run_raw(Action, State, Context, Policy, Env) ->
    case deadline_expired(maps:get(deadline, Env)) of
        true -> timed_out;
        false ->
            Job = spawn_action_worker(Action, State, Context, 0,
                                      maps:get(step_id, Context), Policy),
            await_job(Job, Env)
    end.

spawn_action_worker(Action, State, Context, Index, Id, Policy) ->
    Parent = self(),
    JobRef = make_ref(),
    AttemptKey = maps:get(?ATTEMPT_KEY_OVERRIDE, Context,
                          attempt_key(Id, Context)),
    AttemptStart = attempt_start(AttemptKey),
    PublicContext = maps:remove(?ATTEMPT_KEY_OVERRIDE, Context),
    WorkerContext = PublicContext#{attempt_key => AttemptKey,
                                   attempt_job_ref => JobRef,
                                   attempt_start => AttemptStart},
    {Pid, Monitor} = spawn_opt(
                       fun() ->
                           process_flag(trap_exit, true),
                           Raw = invoke_with_policy(
                                   Parent, Action, State, WorkerContext,
                                   Policy),
                           Parent ! {adk_workflow_worker, JobRef,
                                     self(), Raw}
                       end, [link, monitor]),
    #{job_ref => JobRef, pid => Pid, monitor => Monitor,
      index => Index, id => Id, attempt_key => AttemptKey,
      attempt_cursor_fingerprint =>
          attempt_cursor_fingerprint(
            maps:get(checkpoint_cursor, PublicContext, #{}))}.

default_action_policy() ->
    #{timeout => infinity, max_attempts => 1, backoff_ms => 0}.

action_policy(ActionSpec) ->
    maps:get(policy, ActionSpec, default_action_policy()).

invoke_with_policy(Engine, Action, State, Context, Policy) ->
    Start = maps:get(attempt_start, Context, 1),
    case Start =< maps:get(max_attempts, Policy) of
        true -> invoke_attempt(Engine, Action, State, Context, Policy, Start);
        false ->
            {callback_retry_exhausted, maps:get(max_attempts, Policy),
             resumed_attempt_budget_exhausted}
    end.

invoke_attempt(Engine, Action, State, Context, Policy, Attempt) ->
    ok = announce_attempt(Engine, Context, Attempt),
    Raw = run_attempt(Engine, Action, State,
                      Context#{attempt => Attempt}, Policy),
    MaxAttempts = maps:get(max_attempts, Policy),
    Retryable = retryable_attempt_result(Raw),
    case {Retryable, Attempt < MaxAttempts, Attempt > 1} of
        {true, true, _} ->
            case retry_backoff(Engine, maps:get(backoff_ms, Policy),
                               maps:get(deadline, Context, infinity)) of
                ok ->
                    invoke_attempt(Engine, Action, State, Context,
                                   Policy, Attempt + 1);
                global_timeout -> {callback_global_timeout};
                {engine_down, Reason} -> exit(Reason)
            end;
        {true, false, true} ->
            {callback_retry_exhausted, Attempt,
             attempt_failure_reason(Raw)};
        _ -> Raw
    end.

announce_attempt(Engine, Context, Attempt) ->
    Ref = make_ref(),
    Engine ! {adk_workflow_attempt_started, self(), Ref,
              maps:get(attempt_job_ref, Context),
              maps:get(step_id, Context), Attempt},
    receive
        {adk_workflow_attempt_ack, Ref} -> ok;
        {'EXIT', Engine, Reason} -> exit(Reason)
    end.

run_attempt(Engine, Action, State, Context, Policy) ->
    Owner = self(),
    Ref = make_ref(),
    {Pid, Monitor} = spawn_opt(
                       fun() ->
                           Owner ! {adk_workflow_attempt, Ref, self(),
                                    safe_invoke(Action, State, Context)}
                       end, [link, monitor]),
    Timeout = attempt_timeout(maps:get(timeout, Policy),
                              maps:get(deadline, Context, infinity)),
    await_attempt(Engine, Ref, Pid, Monitor, Timeout,
                  maps:get(timeout, Policy),
                  maps:get(deadline, Context, infinity)).

await_attempt(Engine, Ref, Pid, Monitor, Timeout, PolicyTimeout,
              Deadline) ->
    receive
        {adk_workflow_attempt, Ref, Pid, Raw} ->
            cleanup_attempt(Pid, Monitor),
            Raw;
        {'DOWN', Monitor, process, Pid, Reason} ->
            flush_exit(Pid),
            {callback_attempt_down,
             adk_workflow:external_reason(
               adk_workflow_action, process_down, Reason)};
        {'EXIT', Engine, Reason} ->
            exit(Pid, kill),
            await_attempt_down(Pid, Monitor),
            exit(Reason);
        {'EXIT', Pid, _Reason} ->
            await_attempt(Engine, Ref, Pid, Monitor, Timeout,
                          PolicyTimeout, Deadline)
    after Timeout ->
        exit(Pid, kill),
        await_attempt_down(Pid, Monitor),
        case deadline_expired(Deadline) of
            true -> {callback_global_timeout};
            false -> {callback_action_timeout, PolicyTimeout}
        end
    end.

attempt_timeout(infinity, Deadline) -> remaining_timeout(Deadline);
attempt_timeout(Timeout, infinity) -> Timeout;
attempt_timeout(Timeout, Deadline) ->
    erlang:min(Timeout, remaining_timeout(Deadline)).

retry_backoff(_Engine, 0, Deadline) ->
    case deadline_expired(Deadline) of
        true -> global_timeout;
        false -> ok
    end;
retry_backoff(Engine, BackoffMs, Deadline) ->
    Timeout = attempt_timeout(BackoffMs, Deadline),
    receive
        {'EXIT', Engine, Reason} -> {engine_down, Reason}
    after Timeout ->
        case deadline_expired(Deadline) of
            true -> global_timeout;
            false -> ok
        end
    end.

retryable_attempt_result(
  {callback_ok, {error, {tool_confirmation_requires_runner, _Details}}}) ->
    false;
retryable_attempt_result(
  {callback_ok, {error,
                 {tool_confirmation_evaluation_failed, _Failure}}}) ->
    false;
retryable_attempt_result({callback_exception, _Class, _Reason}) -> true;
retryable_attempt_result({callback_ok, {error, _Reason}}) -> true;
retryable_attempt_result({callback_action_timeout, _Timeout}) -> true;
retryable_attempt_result({callback_attempt_down, _Reason}) -> true;
retryable_attempt_result(_) -> false.

attempt_failure_reason({callback_exception, Class, Reason}) ->
    {action_exception, Class, Reason};
attempt_failure_reason({callback_ok, {error, Reason}}) ->
    {returned_error, adk_workflow:sanitize_reason(Reason)};
attempt_failure_reason({callback_action_timeout, Timeout}) ->
    {action_timed_out, Timeout};
attempt_failure_reason({callback_attempt_down, Reason}) ->
    {attempt_worker_down, Reason}.

cleanup_attempt(Pid, Monitor) ->
    _ = unlink(Pid),
    erlang:demonitor(Monitor, [flush]),
    flush_exit(Pid),
    ok.

await_attempt_down(Pid, Monitor) ->
    receive {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 1000 -> erlang:demonitor(Monitor, [flush])
    end,
    _ = unlink(Pid),
    flush_exit(Pid),
    ok.

safe_invoke(Action, State, Context) ->
    try invoke(Action, State, Context) of
        Value -> {callback_ok, Value}
    catch
        throw:{adk_pause, Reason, Summary} ->
            {callback_pause, Reason, Summary};
        Class:Reason ->
            {callback_exception, Class,
             adk_workflow:exception_reason(
               adk_workflow_action, execute, Class, Reason)}
    end.

invoke(Fun, State, Context) when is_function(Fun, 2) ->
    Fun(State, Context);
invoke(Fun, State, _Context) when is_function(Fun, 1) ->
    Fun(State);
invoke({agent, Name, PromptSpec, Decide}, State, Context) ->
    Prompt0 = resolve_agent_prompt(PromptSpec, State, Context),
    Prompt = case Prompt0 of
        Value when is_binary(Value) -> Value;
        Value when is_list(Value) -> unicode:characters_to_binary(Value);
        _ -> erlang:error(invalid_agent_prompt)
    end,
    case adk_agent_registry:lookup(Name) of
        {ok, AgentPid} ->
            case verify_workflow_agent_identity(Name, AgentPid) of
                ok ->
                    case adk_agent:invoke(AgentPid, Prompt, Context) of
                        {ok, Response} ->
                            agent_decision(
                              Decide, Response, State, Context, Name);
                        {error, Reason} ->
                            {error, {agent_error,
                                     adk_workflow:external_reason(
                                       adk_workflow_agent, invoke,
                                       Reason)}}
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, not_found} ->
            {error, {agent_not_found, Name}}
    end;
invoke({tool, Module, ArgsSpec, ResultKey}, State, Context) ->
    case resolve_tool_args(ArgsSpec, State, Context) of
        {ok, Args} ->
            execute_workflow_tool(Module, Args, Context, ResultKey);
        {error, _} = Error -> Error
    end;
invoke({workflow, Compiled, Opts}, State, Context) ->
    run_nested_workflow(Compiled, Opts, State, Context);
invoke({Module, Function, ExtraArgs}, State, Context) ->
    apply(Module, Function, [State, Context | ExtraArgs]).

%% Typed workflow tools have no Runner continuation channel. Honour the same
%% confirmation declaration as direct agents and Runner before execute/2 so a
%% protected side effect cannot silently bypass human approval.
execute_workflow_tool(Module, Args, Context, ResultKey) ->
    case adk_tool_confirmation:module_requirement(Module, Args, Context) of
        {ok, Requirement} ->
            case adk_tool_confirmation:is_required(Requirement) of
                true ->
                    execute_confirmed_workflow_tool(
                      Module, Args, Context, ResultKey, Requirement);
                false ->
                    execute_unconfirmed_workflow_tool(
                      Module, Args, Context, ResultKey)
            end;
        {error, Reason} ->
            {error,
             {tool_confirmation_evaluation_failed,
              adk_failure:sanitize(
                tool_confirmation, evaluate, Reason)}}
    end.

execute_confirmed_workflow_tool(Module, Args, Context, ResultKey,
                                Requirement) ->
    Name = atom_to_binary(Module, utf8),
    InvocationId = maps:get(invocation_id, Context,
                            maps:get(session_id, Context)),
    ActionId = adk_tool_confirmation:action_id(
                 Name, Args, InvocationId, null),
    Details0 = #{<<"type">> => <<"tool_confirmation">>,
                 <<"action_id">> => ActionId},
    Details = case maps:find(hint, Requirement) of
        {ok, Hint} -> Details0#{<<"hint">> => Hint};
        error -> Details0
    end,
    case maps:get(tool_confirmation, Context, undefined) of
        undefined ->
            {adk_pause, Details,
             adk_tool_confirmation:summary(Name, Requirement)};
        #{details := StoredDetails, input := ResumeInput} ->
            case {StoredDetails =:= Details,
                  confirmation_decision(ResumeInput)} of
                {true, approved} ->
                    execute_unconfirmed_workflow_tool(
                      Module, Args, Context, ResultKey);
                {true, rejected} ->
                    {error, {tool_confirmation_rejected, ActionId}};
                {true, invalid} ->
                    {error, invalid_tool_confirmation_input};
                {false, _} ->
                    {error, tool_confirmation_action_mismatch}
            end
    end.

confirmation_decision(#{<<"approved">> := true}) -> approved;
confirmation_decision(#{<<"approved">> := false}) -> rejected;
confirmation_decision(_) -> invalid.

pause_resume_kind(#{<<"reason">> :=
                        #{<<"type">> := <<"tool_confirmation">>}},
                  _Default) ->
    <<"tool_confirmation">>;
pause_resume_kind(_Pause, Default) -> Default.

fork_pause_resume_kind(Pause) ->
    case pause_resume_kind(Pause, <<"fork_branch">>) of
        <<"tool_confirmation">> -> <<"fork_tool_confirmation">>;
        Kind -> Kind
    end.

run_resumed_tool_confirmation(ActionSpec, Id, ActionInput, ResumeInput, Env) ->
    Cursor = maps:get(cursor, Env),
    Pause = maps:get(<<"pause">>, Cursor),
    Details = maps:get(<<"reason">>, Pause),
    Context0 = action_context(Id, Env, ActionInput),
    Context = Context0#{tool_confirmation =>
                            #{details => Details, input => ResumeInput}},
    run_action(maps:get(run, ActionSpec), maps:get(state, Env), Context,
               action_policy(ActionSpec), Env).

execute_unconfirmed_workflow_tool(Module, Args, Context, ResultKey) ->
    case Module:execute(Args, Context) of
        {ok, Value} -> tool_result(Value, ResultKey);
        {error, _} = Error -> Error;
        {adk_pause, _Reason, _Summary} = Pause -> Pause;
        Other -> {error, {invalid_tool_result,
                          adk_workflow:external_reason(
                            adk_workflow_tool, execute, Other)}}
    end.

resolve_tool_args(Args, _State, _Context) when is_map(Args) ->
    normalize_tool_args(Args);
resolve_tool_args(Fun, State, Context) when is_function(Fun, 2) ->
    normalize_tool_args(Fun(State, Context));
resolve_tool_args(Fun, State, _Context) when is_function(Fun, 1) ->
    normalize_tool_args(Fun(State));
resolve_tool_args({Module, Function, ExtraArgs}, State, Context) ->
    normalize_tool_args(apply(Module, Function,
                              [State, Context | ExtraArgs])).

normalize_tool_args(Args) when is_map(Args) ->
    case adk_json:normalize(Args) of
        {ok, SafeArgs} when is_map(SafeArgs) -> {ok, SafeArgs};
        {error, Reason} ->
            {error, {invalid_tool_args,
                     adk_workflow:external_reason(
                       adk_workflow_tool, arguments, Reason)}}
    end;
normalize_tool_args(_) -> {error, invalid_tool_args}.

tool_result(Value, undefined) when is_map(Value) ->
    {output, Value, Value};
tool_result(Value, undefined) ->
    {error, {invalid_tool_result,
             adk_workflow:external_reason(
               adk_workflow_tool, result, Value)}};
tool_result(Value, ResultKey) ->
    case normalize_json_value(Value) of
        {ok, SafeValue} ->
            {output, SafeValue, #{ResultKey => SafeValue}};
        {error, Reason} -> {error, {invalid_tool_result, Reason}}
    end.

run_nested_workflow(Compiled, Opts, State, Context) ->
    run_nested_workflow(start, Compiled, Opts, State, Context).

resume_nested_workflow(Compiled, Opts, Checkpoint, Input, Context) ->
    run_nested_workflow({resume, Checkpoint, Input}, Compiled, Opts,
                        maps:get(state, Context), Context).

run_nested_workflow(Mode, Compiled, Opts, State, Context) ->
    Owner = self(),
    Ref = make_ref(),
    {Helper, Monitor} = spawn_monitor(
                          fun() ->
                              nested_workflow_guardian(
                                Owner, Ref, Mode, Compiled, Opts, State,
                                Context)
                          end),
    receive
        {adk_nested_workflow, Ref, Helper, Result} ->
            erlang:demonitor(Monitor, [flush]),
            nested_workflow_result(
              Result, State, maps:get(state_reducers, Context, #{}));
        {'DOWN', Monitor, process, Helper, Reason} ->
            {error, {nested_workflow_guardian_down,
                     adk_workflow:external_reason(
                       adk_workflow, nested_guardian_down, Reason)}}
    end.

nested_workflow_guardian(Owner, Ref, Mode, Compiled, Opts0, State,
                         Context) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    Opts = nested_workflow_options(Opts0, Context),
    StartResult = case Mode of
        start -> adk_workflow:start(Compiled, State, Opts);
        {resume, Checkpoint, Input} ->
            adk_workflow:resume(
              Compiled, Checkpoint, Opts#{resume_input => Input})
    end,
    case StartResult of
        {error, Reason} ->
            Owner ! {adk_nested_workflow, Ref, self(),
                     {error, {nested_workflow_start_failed, Reason}}};
        {ok, Child} ->
            Guardian = self(),
            {Waiter, WaiterMonitor} = spawn_monitor(
                                        fun() ->
                                            Guardian !
                                              {adk_nested_workflow_done,
                                               self(),
                                               adk_workflow:await(
                                                 Child, infinity)}
                                        end),
            nested_workflow_wait(Owner, OwnerMonitor, Ref, Child,
                                 Waiter, WaiterMonitor,
                                 maps:get(deadline, Context, infinity))
    end.

nested_workflow_wait(Owner, OwnerMonitor, Ref, Child, Waiter,
                     WaiterMonitor, Deadline) ->
    receive
        {adk_nested_workflow_done, Waiter, Result} ->
            erlang:demonitor(WaiterMonitor, [flush]),
            Owner ! {adk_nested_workflow, Ref, self(), Result};
        {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
            _ = adk_workflow:cancel(Child, parent_workflow_stopped),
            exit(Waiter, kill),
            ok;
        {'DOWN', WaiterMonitor, process, Waiter, Reason} ->
            Owner ! {adk_nested_workflow, Ref, self(),
                     {error, {nested_workflow_waiter_down,
                              adk_workflow:external_reason(
                                adk_workflow, nested_waiter_down, Reason)}}}
    after remaining_timeout(Deadline) ->
        _ = adk_workflow:cancel(Child, parent_workflow_timed_out),
        exit(Waiter, kill),
        Owner ! {adk_nested_workflow, Ref, self(), {error, timed_out}}
    end.

nested_workflow_options(Opts0, Context) ->
    Base = Opts0#{deadline => maps:get(deadline, Context),
                  retention_ms => maps:get(retention_ms, Opts0, 0)},
    maps:remove(resume_checkpoint, Base).

nested_workflow_result({completed, ChildState, Checkpoint},
                       ParentState, StateReducers) ->
    Output = maps:get(<<"output">>, Checkpoint, ChildState),
    case nested_state_delta(ParentState, ChildState, StateReducers) of
        {ok, Delta} -> {output, Output, Delta};
        {error, _} = Error -> Error
    end;
nested_workflow_result({paused, Details, Checkpoint},
                       _ParentState, _StateReducers) ->
    {nested_pause, Details, Checkpoint};
nested_workflow_result({failed, Reason, _Checkpoint},
                       _ParentState, _StateReducers) ->
    {error, {nested_workflow_failed, Reason}};
nested_workflow_result({timed_out, _Checkpoint},
                       _ParentState, _StateReducers) ->
    {error, nested_workflow_timed_out};
nested_workflow_result({cancelled, Reason, _Checkpoint},
                       _ParentState, _StateReducers) ->
    {error, {nested_workflow_cancelled, Reason}};
nested_workflow_result({error, _} = Error,
                       _ParentState, _StateReducers) -> Error;
nested_workflow_result(Other, _ParentState, _StateReducers) ->
    {error, {invalid_nested_workflow_result,
             adk_workflow:external_reason(
               adk_workflow, nested_result, Other)}}.

nested_state_delta(ParentState, ChildState, StateReducers)
  when is_map(ParentState), is_map(ChildState), is_map(StateReducers) ->
    maps:fold(
      fun(Key, ChildValue, {ok, Delta}) ->
              case maps:find(Key, ParentState) of
                  {ok, ChildValue} -> {ok, Delta};
                  ParentValue ->
                      nested_state_delta_value(
                        maps:get(Key, StateReducers, overwrite),
                        Key, ParentValue, ChildValue, Delta)
              end;
         (_Key, _Value, {error, _} = Error) -> Error
      end, {ok, #{}}, ChildState);
nested_state_delta(_ParentState, _ChildState, _StateReducers) ->
    {error, invalid_nested_workflow_state}.

nested_state_delta_value(overwrite, Key, _Parent, ChildValue, Delta) ->
    {ok, Delta#{Key => ChildValue}};
nested_state_delta_value(sum, Key, error, ChildValue, Delta)
  when is_number(ChildValue) ->
    {ok, Delta#{Key => ChildValue}};
nested_state_delta_value(sum, Key, {ok, ParentValue}, ChildValue, Delta)
  when is_number(ParentValue), is_number(ChildValue) ->
    case safe_numeric_difference(ChildValue, ParentValue) of
        {ok, Difference} -> {ok, Delta#{Key => Difference}};
        error ->
            {error, {nested_state_reducer_incompatible, Key, sum}}
    end;
nested_state_delta_value(sum, Key, _Parent, _ChildValue, _Delta) ->
    {error, {nested_state_reducer_incompatible, Key, sum}};
nested_state_delta_value(append, Key, error, ChildValue, Delta)
  when is_list(ChildValue) ->
    {ok, Delta#{Key => ChildValue}};
nested_state_delta_value(append, Key, {ok, ParentValue}, ChildValue, Delta)
  when is_list(ParentValue), is_list(ChildValue) ->
    case list_suffix_after_prefix(ParentValue, ChildValue) of
        {ok, Suffix} -> {ok, Delta#{Key => Suffix}};
        error ->
            {error, {nested_state_reducer_incompatible, Key, append}}
    end;
nested_state_delta_value(append, Key, _Parent, _ChildValue, _Delta) ->
    {error, {nested_state_reducer_incompatible, Key, append}};
nested_state_delta_value(reject_conflict, Key, _Parent,
                         ChildValue, Delta) ->
    {ok, Delta#{Key => ChildValue}}.

safe_numeric_difference(Left, Right) ->
    try Left - Right of
        Difference ->
            case adk_json:normalize(Difference) of
                {ok, Difference} -> {ok, Difference};
                _ -> error
            end
    catch
        error:badarith -> error
    end.

list_suffix_after_prefix([], List) -> {ok, List};
list_suffix_after_prefix([Head | ParentRest], [Head | ChildRest]) ->
    list_suffix_after_prefix(ParentRest, ChildRest);
list_suffix_after_prefix(_Parent, _Child) -> error.

resolve_agent_prompt(Prompt, _State, _Context)
  when is_binary(Prompt); is_list(Prompt) -> Prompt;
resolve_agent_prompt(Fun, State, Context) when is_function(Fun, 2) ->
    Fun(State, Context);
resolve_agent_prompt(Fun, State, _Context) when is_function(Fun, 1) ->
    Fun(State);
resolve_agent_prompt({Module, Function, ExtraArgs}, State, Context) ->
    apply(Module, Function, [State, Context | ExtraArgs]).

%% Registry keys are lookup aliases, not proof of process identity. Workflows
%% compile the requested name to the same canonical identifier used by agents;
%% re-check the immutable runtime name before every invocation so a stale or
%% manually inserted alias cannot dispatch work to a different agent.
verify_workflow_agent_identity(ExpectedName, AgentPid) ->
    try adk_agent:get_runtime(AgentPid) of
        {ok, RuntimeName, _RuntimeConfig, _Tools, _SubAgents} ->
            case adk_agent_tree:validate_name(RuntimeName) of
                {ok, ExpectedName} ->
                    ok;
                {ok, ActualName} ->
                    {error, {agent_identity_mismatch,
                             ExpectedName, ActualName}};
                {error, Reason} ->
                    {error, {invalid_agent_runtime_name, Reason}}
            end;
        Other ->
            {error,
             {invalid_agent_runtime,
              adk_workflow:external_reason(
                adk_workflow_agent, get_runtime, Other)}}
    catch
        Class:Reason ->
            {error,
             {agent_runtime_unavailable,
              adk_workflow:exception_reason(
                adk_workflow_agent, get_runtime, Class, Reason)}}
    end.

agent_decision(undefined, Response, _State, _Context, Name) ->
    {output, Response,
     #{<<"last_agent">> => Name, <<"last_response">> => Response}};
agent_decision(Fun, Response, State, Context, _Name)
  when is_function(Fun, 3) ->
    Fun(Response, State, Context);
agent_decision(Fun, Response, State, _Context, _Name)
  when is_function(Fun, 2) ->
    Fun(Response, State);
agent_decision({Module, Function, ExtraArgs}, Response, State, Context,
               _Name) ->
    apply(Module, Function, [Response, State, Context | ExtraArgs]).

await_job(Job, Env) ->
    JobRef = maps:get(job_ref, Job),
    Pid = maps:get(pid, Job),
    Monitor = maps:get(monitor, Job),
    Deadline = maps:get(deadline, Env),
    CoordinatorRef = maps:get(coordinator_ref, Env),
    Coordinator = maps:get(coordinator, Env),
    Timeout = remaining_timeout(Deadline),
    receive
        {adk_workflow_attempt_started, Pid, AttemptRef, AttemptJobRef,
         Id, Attempt}
          when is_reference(AttemptRef),
               AttemptJobRef =:= JobRef ->
            record_attempt(Job, Id, Attempt, Env),
            Pid ! {adk_workflow_attempt_ack, AttemptRef},
            await_job(Job, Env);
        {adk_workflow_worker, JobRef, Pid, Raw} ->
            complete_attempt(Job, Raw),
            cleanup_job(Job),
            normalize_worker_raw(Raw);
        {'DOWN', Monitor, process, Pid, Reason} ->
            flush_exit(Pid),
            {error, {worker_down,
                     adk_workflow:external_reason(
                       adk_workflow_action, process_down, Reason)}};
        {'EXIT', Pid, _Reason} ->
            await_job(Job, Env);
        {'DOWN', CoordinatorRef, process, Coordinator, _Reason} ->
            exit(Pid, kill),
            await_worker_down(Job),
            erlang:exit(coordinator_down)
    after Timeout ->
        exit(Pid, kill),
        await_worker_down(Job),
        timed_out
    end.

normalize_worker_raw({callback_ok, Value}) -> {ok, Value};
normalize_worker_raw({callback_pause, Reason, Summary}) ->
    {ok, {adk_pause, Reason, Summary}};
normalize_worker_raw({callback_exception, Class, Reason}) ->
    {error, {action_exception, Class, Reason}};
normalize_worker_raw({callback_action_timeout, Timeout}) ->
    {error, {action_timed_out, Timeout}};
normalize_worker_raw({callback_attempt_down, Reason}) ->
    {error, {attempt_worker_down, Reason}};
normalize_worker_raw({callback_retry_exhausted, Attempts, Reason}) ->
    {error, {retry_exhausted, Attempts, Reason}};
normalize_worker_raw({callback_global_timeout}) -> timed_out;
normalize_worker_raw(_Other) -> {error, invalid_worker_result}.

normalize_action({callback_ok, Value}) -> normalize_action(Value);
normalize_action({callback_pause, Reason, Summary}) ->
    normalize_pause_action(Reason, Summary, #{});
normalize_action({callback_exception, Class, Reason}) ->
    {error, adk_workflow:exception_reason(
              adk_workflow_action, execute, Class, Reason)};
normalize_action({callback_action_timeout, Timeout}) ->
    {error, {action_timed_out, Timeout}};
normalize_action({callback_attempt_down, Reason}) ->
    {error, {attempt_worker_down, Reason}};
normalize_action({callback_retry_exhausted, Attempts, Reason}) ->
    {error, {retry_exhausted, Attempts, Reason}};
normalize_action({callback_global_timeout}) -> timed_out;
normalize_action({ok, Delta}) when is_map(Delta) ->
    {ok, {ok, Delta}};
normalize_action({output, Output, Delta}) when is_map(Delta) ->
    normalize_output_action(output, Output, Delta);
normalize_action({stop, Output, Delta}) when is_map(Delta) ->
    normalize_output_action(stop, Output, Delta);
normalize_action({complete, Delta}) when is_map(Delta) ->
    {ok, {complete, null, Delta}};
normalize_action({complete, Output, Delta}) when is_map(Delta) ->
    normalize_output_action(complete, Output, Delta);
normalize_action({route, Target, Delta}) when is_map(Delta) ->
    {ok, {route, Target, Delta}};
normalize_action({transfer, Target, Input, Delta}) when is_map(Delta) ->
    {ok, {transfer, Target, Input, Delta}};
normalize_action({adk_pause, Reason, Summary}) ->
    normalize_pause_action(Reason, Summary, #{});
normalize_action({pause, Reason, Summary, Delta}) when is_map(Delta) ->
    normalize_pause_action(Reason, Summary, Delta);
normalize_action({nested_pause, Details, Checkpoint})
  when is_map(Details), is_map(Checkpoint) ->
    case {normalize_json_value(Details), normalize_json_value(Checkpoint)} of
        {{ok, SafeDetails}, {ok, SafeCheckpoint}}
          when is_map(SafeDetails), is_map(SafeCheckpoint) ->
            {ok, {nested_pause, SafeDetails, SafeCheckpoint}};
        {{error, Reason}, _} ->
            {error, {invalid_nested_pause_details, Reason}};
        {_, {error, Reason}} ->
            {error, {invalid_nested_checkpoint, Reason}};
        _ -> {error, invalid_nested_pause}
    end;
normalize_action(
  {error, {nested_state_reducer_incompatible, Key, Policy} = Reason})
  when is_binary(Key), byte_size(Key) =< 4096,
       (Policy =:= sum orelse Policy =:= append) ->
    %% This reason is generated by the trusted nested-workflow adapter after
    %% comparing parent and child state. Preserve its bounded structural
    %% fields so operators can correct the reducer contract; arbitrary action
    %% errors still cross the external-error sanitization boundary below.
    {error, Reason};
normalize_action({error, Reason}) ->
    {error, adk_workflow:external_reason(
              adk_workflow_action, returned_error, Reason)};
normalize_action(_Other) ->
    {error, invalid_action_result}.

normalize_output_action(Control, Output, Delta) ->
    case normalize_json_value(Output) of
        {ok, SafeOutput} -> {ok, {Control, SafeOutput, Delta}};
        {error, Reason} -> {error, {invalid_output, Reason}}
    end.

normalize_pause_action(Reason0, Summary0, Delta) ->
    Reason = adk_workflow:sanitize_reason(Reason0),
    Summary = adk_workflow:sanitize_reason(Summary0),
    case {normalize_json_value(Reason), normalize_json_value(Summary)} of
        {{ok, SafeReason}, {ok, SafeSummary}} ->
            {ok, {pause, #{<<"reason">> => SafeReason,
                           <<"summary">> => SafeSummary}, Delta}};
        {{error, Error}, _} -> {error, {invalid_pause_reason, Error}};
        {_, {error, Error}} -> {error, {invalid_pause_summary, Error}}
    end.

normalize_delta(Delta) when is_map(Delta) ->
    case adk_json:normalize(Delta) of
        {ok, Safe} when is_map(Safe) -> {ok, Safe};
        {error, Reason} ->
            {error, {invalid_state_delta,
                     adk_workflow:external_reason(
                       adk_workflow_action, state_delta, Reason)}}
    end;
normalize_delta(_) -> {error, invalid_state_delta}.

normalize_json_value(Value) ->
    case adk_json:normalize(Value) of
        {ok, Safe} -> {ok, Safe};
        {error, Reason} ->
            {error, adk_workflow:external_reason(
                      adk_workflow_action, json_value, Reason)}
    end.

merge_delta(Delta, Env) ->
    case normalize_delta(Delta) of
        {ok, SafeDelta} ->
            State = maps:get(state, Env),
            Reducers = maps:get(state_reducers, workflow_data(Env), #{}),
            case reduce_state_delta(
                   maps:to_list(SafeDelta), State, Reducers) of
                {ok, NewState} -> {ok, Env#{state => NewState}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

reduce_state_delta([], State, _Reducers) -> {ok, State};
reduce_state_delta([{Key, Incoming} | Rest], State0, Reducers) ->
    Policy = maps:get(Key, Reducers, overwrite),
    case reduce_state_value(Policy, Key, Incoming, State0) of
        {ok, State} -> reduce_state_delta(Rest, State, Reducers);
        {error, _} = Error -> Error
    end.

reduce_state_value(overwrite, Key, Incoming, State) ->
    {ok, State#{Key => Incoming}};
reduce_state_value(append, Key, Incoming, State) when is_list(Incoming) ->
    case maps:find(Key, State) of
        error -> {ok, State#{Key => Incoming}};
        {ok, Current} when is_list(Current) ->
            {ok, State#{Key => Current ++ Incoming}};
        {ok, _} -> {error, {state_reducer_type_mismatch, Key, append}}
    end;
reduce_state_value(append, Key, _Incoming, _State) ->
    {error, {state_reducer_type_mismatch, Key, append}};
reduce_state_value(sum, Key, Incoming, State) when is_number(Incoming) ->
    case maps:find(Key, State) of
        error -> {ok, State#{Key => Incoming}};
        {ok, Current} when is_number(Current) ->
            case safe_numeric_sum(Current, Incoming) of
                {ok, Sum} -> {ok, State#{Key => Sum}};
                error -> {error, {state_reducer_numeric_overflow, Key}}
            end;
        {ok, _} -> {error, {state_reducer_type_mismatch, Key, sum}}
    end;
reduce_state_value(sum, Key, _Incoming, _State) ->
    {error, {state_reducer_type_mismatch, Key, sum}};
reduce_state_value(reject_conflict, Key, Incoming, State) ->
    case maps:find(Key, State) of
        error -> {ok, State#{Key => Incoming}};
        {ok, Incoming} -> {ok, State};
        {ok, _} -> {error, {state_reducer_conflict, Key}}
    end.

safe_numeric_sum(Left, Right) ->
    try Left + Right of
        Sum ->
            case adk_json:normalize(Sum) of
                {ok, Sum} -> {ok, Sum};
                _ -> error
            end
    catch
        error:badarith -> error
    end.

%% Budgets and checkpoints

begin_parallel(Count, Env) ->
    Remaining = maps:get(steps_remaining, Env),
    case Remaining >= Count of
        false -> {error, {budget_exhausted, steps}, Env};
        true ->
            %% Persist the scheduler transition and its aggregate budget debit
            %% as one boundary. A crash can therefore observe neither change
            %% or both, but never a debited `pending' cursor that is charged a
            %% second time on resume.
            Env1 = Env#{steps_remaining => Remaining - Count,
                        cursor => parallel_running_cursor(#{})},
            notify_checkpoint(Env1),
            {ok, Env1}
    end.

consume_action_step(Id, Env) ->
    case find_running_attempt(Id, Env) of
        {ok, AttemptKey} ->
            %% The budget was committed before this ambiguous in-flight
            %% attempt. Re-run the same numbered attempt without charging the
            %% logical node twice.
            put({?ATTEMPT_KEY_OVERRIDE, Id}, AttemptKey),
            {ok, Env};
        error ->
            reserve_action_step(Id, Env)
    end.

reserve_action_step(Id, Env) ->
    _ = erase({?ATTEMPT_KEY_OVERRIDE, Id}),
    Remaining = maps:get(steps_remaining, Env),
    case Remaining >= 1 of
        false -> {error, {budget_exhausted, steps}, Env};
        true ->
            Env1 = Env#{steps_remaining => Remaining - 1},
            AttemptKey = attempt_key_for_env(Id, Env1),
            Attempt = attempt_start(AttemptKey),
            Entry = #{<<"node_id">> => Id,
                      <<"count">> => Attempt,
                      <<"status">> => <<"running">>,
                      <<"cursor_fingerprint">> =>
                          attempt_cursor_fingerprint(
                            maps:get(cursor, Env1))},
            put(?ATTEMPTS_KEY, (attempts())#{AttemptKey => Entry}),
            %% The debit and reservation share one durable checkpoint. The
            %% worker cannot execute until its later attempt announcement is
            %% also acknowledged by the coordinator.
            notify_checkpoint(Env1),
            {ok, Env1}
    end.

find_running_attempt(Id, Env) ->
    Fingerprint = attempt_cursor_fingerprint(maps:get(cursor, Env)),
    Matches = [Key || {Key, Entry} <- maps:to_list(attempts()),
                      is_map(Entry),
                      maps:get(<<"node_id">>, Entry, undefined) =:= Id,
                      maps:get(<<"status">>, Entry, undefined)
                          =:= <<"running">>,
                      maps:get(<<"cursor_fingerprint">>, Entry, undefined)
                          =:= Fingerprint],
    case lists:sort(Matches) of
        [Key | _] -> {ok, Key};
        [] -> error
    end.

commit(Cursor, Env) ->
    Env1 = Env#{cursor => Cursor},
    notify_checkpoint(Env1),
    Env1.

notify_checkpoint(Env) ->
    advance_checkpoint_sequence(),
    Coordinator = maps:get(coordinator, Env),
    CoordinatorRef = maps:get(coordinator_ref, Env),
    AckRef = make_ref(),
    Coordinator ! {adk_workflow_checkpoint, self(), AckRef,
                   checkpoint(Env, false)},
    receive
        {adk_workflow_checkpoint_ack, AckRef} ->
            emit_lifecycle(
              <<"checkpoint_committed">>,
              #{<<"sequence">> => checkpoint_sequence()}, Env),
            ok;
        {'DOWN', CoordinatorRef, process, Coordinator, _Reason} ->
            erlang:exit(coordinator_down)
    end.

checkpoint(Env, Completed) ->
    Compiled = maps:get(compiled, Env),
    Cursor = case Completed of
        true -> #{<<"type">> => <<"complete">>};
        false -> maps:get(cursor, Env)
    end,
    RuntimeState = checkpoint_runtime_state(Cursor, Completed),
    Base = #{<<"schema_version">> => 2,
             <<"workflow_id">> => maps:get(id, Compiled),
             <<"workflow_version">> => maps:get(version, Compiled),
             <<"kind">> => atom_to_binary(maps:get(kind, Compiled), utf8),
             <<"definition_fingerprint">> =>
                 adk_workflow:definition_fingerprint(Compiled),
             <<"execution_id">> =>
                 maps:get(invocation_id, maps:get(runtime, Env),
                          maps:get(execution_id, maps:get(runtime, Env))),
             <<"sequence">> => checkpoint_sequence(),
             <<"parent_sequence">> => checkpoint_parent_sequence(),
             <<"created_at">> => erlang:system_time(millisecond),
             <<"cursor">> => Cursor,
             <<"state">> => maps:get(state, Env),
             <<"remaining">> =>
                 #{<<"steps">> => maps:get(steps_remaining, Env),
                   <<"transfers">> => maps:get(transfers_remaining, Env)},
             <<"attempts">> => attempts(),
             <<"node_status">> => maps:get(node_status, RuntimeState),
             <<"runnable">> => maps:get(runnable, RuntimeState),
             <<"waiting">> => maps:get(waiting, RuntimeState),
             <<"join_accumulators">> =>
                 maps:get(join_accumulators, RuntimeState),
             <<"cycle_counters">> => maps:get(cycle_counters, RuntimeState),
             <<"interruptions">> => maps:get(interruptions, RuntimeState),
             <<"completed">> => Completed},
    case maps:find(output, Env) of
        {ok, Output} -> Base#{<<"output">> => Output};
        _ -> Base
    end.

env_from_checkpoint(Coordinator, Compiled, InitialState, Runtime,
                    Checkpoint) ->
    Remaining = maps:get(<<"remaining">>, Checkpoint),
    Env = #{coordinator => Coordinator,
            compiled => Compiled,
            runtime => Runtime,
            deadline => maps:get(deadline, Runtime),
            state => InitialState,
            cursor => maps:get(<<"cursor">>, Checkpoint),
            steps_remaining => maps:get(<<"steps">>, Remaining),
            transfers_remaining => maps:get(<<"transfers">>, Remaining)},
    case maps:find(<<"output">>, Checkpoint) of
        {ok, Output} -> Env#{output => Output};
        error -> Env
    end.

initialize_execution_metadata(Checkpoint) ->
    Sequence = maps:get(<<"sequence">>, Checkpoint, 0),
    put(?CHECKPOINT_SEQUENCE_KEY, Sequence),
    put(?CHECKPOINT_PARENT_KEY,
        maps:get(<<"parent_sequence">>, Checkpoint, null)),
    put(?ATTEMPTS_KEY, maps:get(<<"attempts">>, Checkpoint, #{})),
    put(?LIFECYCLE_SEQUENCE_KEY, 0),
    ok.

terminal_checkpoint(Env, Completed) ->
    advance_checkpoint_sequence(),
    checkpoint(Env, Completed).

advance_checkpoint_sequence() ->
    Current = checkpoint_sequence(),
    put(?CHECKPOINT_PARENT_KEY, Current),
    put(?CHECKPOINT_SEQUENCE_KEY, Current + 1),
    ok.

checkpoint_sequence() ->
    case get(?CHECKPOINT_SEQUENCE_KEY) of
        Value when is_integer(Value), Value >= 0 -> Value;
        _ -> 0
    end.

checkpoint_parent_sequence() ->
    case get(?CHECKPOINT_PARENT_KEY) of
        Value when is_integer(Value), Value >= 0 -> Value;
        _ -> null
    end.

attempts() ->
    case get(?ATTEMPTS_KEY) of
        Value when is_map(Value) -> Value;
        _ -> #{}
    end.

attempt_key(Id, Context) ->
    Budgets = maps:get(budgets, Context, #{}),
    Material = {workflow_attempt_v1, Id,
                stable_attempt_cursor(
                  maps:get(checkpoint_cursor, Context, #{})),
                maps:get(steps_remaining, Budgets, 0),
                maps:get(transfers_remaining, Budgets, 0)},
    binary:encode_hex(
      crypto:hash(sha256, term_to_binary(Material, [deterministic])),
      lowercase).

attempt_key_for_env(Id, Env) ->
    attempt_key(
      Id,
      #{checkpoint_cursor => maps:get(cursor, Env),
        budgets => #{steps_remaining => maps:get(steps_remaining, Env),
                     transfers_remaining =>
                         maps:get(transfers_remaining, Env)}}).

stable_attempt_cursor(Cursor) when is_map(Cursor) ->
    %% Parallel/fork completion mutates accumulator fields while already
    %% running siblings retain their original logical attempt identity.
    maps:without([<<"results">>, <<"fork_results">>,
                  <<"failed_branches">>], Cursor);
stable_attempt_cursor(Cursor) -> Cursor.

attempt_cursor_fingerprint(Cursor) ->
    binary:encode_hex(
      crypto:hash(
        sha256,
        term_to_binary(stable_attempt_cursor(Cursor), [deterministic])),
      lowercase).

attempt_start(AttemptKey) ->
    case maps:get(AttemptKey, attempts(), undefined) of
        #{<<"count">> := Count, <<"status">> := <<"running">>}
          when is_integer(Count), Count > 0 ->
            %% A crash can leave an attempt in the ambiguous in-flight state.
            %% Re-run that same numbered attempt under the documented
            %% at-least-once boundary; only a committed failed attempt consumes
            %% the next retry slot.
            Count;
        #{<<"count">> := Count} when is_integer(Count), Count >= 0 ->
            Count + 1;
        _ -> 1
    end.

record_attempt(Job, Id, Attempt, Env) ->
    AttemptKey = maps:get(attempt_key, Job),
    Entry = #{<<"node_id">> => Id,
              <<"count">> => Attempt,
              <<"status">> => <<"running">>,
              <<"cursor_fingerprint">> =>
                  maps:get(attempt_cursor_fingerprint, Job)},
    put(?ATTEMPTS_KEY, (attempts())#{AttemptKey => Entry}),
    notify_checkpoint(Env),
    EventType = case Attempt of
        1 -> <<"attempt_started">>;
        _ -> <<"retry_started">>
    end,
    emit_lifecycle(EventType,
                   #{<<"node_id">> => Id,
                     <<"attempt">> => Attempt}, Env),
    ok.

complete_attempt(Job, Raw) ->
    AttemptKey = maps:get(attempt_key, Job),
    case maps:get(AttemptKey, attempts(), undefined) of
        Entry when is_map(Entry) ->
            Status = attempt_terminal_status(Raw),
            put(?ATTEMPTS_KEY,
                (attempts())#{AttemptKey => Entry#{<<"status">> => Status}}),
            ok;
        _ -> ok
    end.

attempt_terminal_status({callback_ok, {error, _}}) -> <<"failed">>;
attempt_terminal_status({callback_exception, _, _}) -> <<"failed">>;
attempt_terminal_status({callback_action_timeout, _}) -> <<"failed">>;
attempt_terminal_status({callback_attempt_down, _}) -> <<"failed">>;
attempt_terminal_status({callback_retry_exhausted, _, _}) -> <<"failed">>;
attempt_terminal_status({callback_global_timeout}) -> <<"failed">>;
attempt_terminal_status(_) -> <<"completed">>.

checkpoint_runtime_state(_Cursor, true) ->
    #{node_status => #{}, runnable => [], waiting => [],
      join_accumulators => #{}, cycle_counters => #{}, interruptions => []};
checkpoint_runtime_state(Cursor, false) ->
    Type = maps:get(<<"type">>, Cursor, <<"unknown">>),
    Phase = case Type of
        <<"parallel">> -> maps:get(<<"status">>, Cursor, <<"pending">>);
        _ -> maps:get(<<"phase">>, Cursor, <<"ready">>)
    end,
    Node = checkpoint_node_id(Type, Cursor),
    Status = checkpoint_node_status(Phase),
    NodeStatus = case Node of
        undefined -> #{};
        _ -> #{Node => Status}
    end,
    Runnable = case {Node, Phase} of
        {undefined, _} -> [];
        {_, <<"awaiting_resume">>} -> [];
        {_, _} -> [Node]
    end,
    Waiting = case {Node, Phase} of
        {undefined, _} -> [];
        {_, <<"awaiting_resume">>} -> [Node];
        _ -> []
    end,
    JoinAccumulators = case maps:find(<<"results">>, Cursor) of
        {ok, Results} when is_map(Results) -> #{Node => Results};
        _ -> #{}
    end,
    Interruptions = case maps:find(<<"pause">>, Cursor) of
        {ok, Pause} when is_map(Pause) -> [Pause];
        _ -> []
    end,
    #{node_status => NodeStatus,
      runnable => Runnable,
      waiting => Waiting,
      join_accumulators => JoinAccumulators,
      cycle_counters => maps:get(<<"visits">>, Cursor, #{}),
      interruptions => Interruptions}.

checkpoint_node_id(<<"graph">>, Cursor) ->
    maps:get(<<"node">>, Cursor, undefined);
checkpoint_node_id(<<"sequential">>, Cursor) ->
    <<"step-", (integer_to_binary(
                  maps:get(<<"next_index">>, Cursor, 0)))/binary>>;
checkpoint_node_id(<<"loop">>, _Cursor) -> <<"loop-body">>;
checkpoint_node_id(<<"transfer">>, Cursor) ->
    maps:get(<<"member">>, Cursor, undefined);
checkpoint_node_id(<<"parallel">>, _Cursor) -> <<"parallel">>;
checkpoint_node_id(_, _Cursor) -> undefined.

checkpoint_node_status(<<"awaiting_resume">>) -> <<"paused">>;
checkpoint_node_status(<<"fork">>) -> <<"running">>;
checkpoint_node_status(<<"routing">>) -> <<"routing">>;
checkpoint_node_status(_) -> <<"ready">>.

emit_lifecycle(Type, Fields, Env)
  when is_binary(Type), is_map(Fields) ->
    Runtime = maps:get(runtime, Env),
    case maps:get(lifecycle_receiver, Runtime, undefined) of
        undefined -> ok;
        _Receiver ->
            Sequence = lifecycle_sequence() + 1,
            put(?LIFECYCLE_SEQUENCE_KEY, Sequence),
            Compiled = maps:get(compiled, Env),
            Event0 = Fields#{
                <<"schema_version">> => 1,
                <<"type">> => Type,
                <<"sequence">> => Sequence,
                <<"timestamp">> => erlang:system_time(millisecond),
                <<"workflow_id">> => maps:get(id, Compiled),
                <<"workflow_kind">> =>
                    atom_to_binary(maps:get(kind, Compiled), utf8),
                <<"invocation_id">> =>
                    invocation_id(Env, maps:get(id, Compiled))},
            case adk_json:normalize(Event0) of
                {ok, Event} ->
                    maps:get(coordinator, Env) !
                        {adk_workflow_lifecycle, self(), Event},
                    ok;
                {error, _} -> ok
            end
    end.

emit_terminal_node_failure({failed, Reason}, Env) ->
    case terminal_failure_node(Reason) of
        {ok, NodeId} ->
            emit_lifecycle(<<"node_failed">>,
                           #{<<"node_id">> => NodeId}, Env);
        error -> ok
    end;
emit_terminal_node_failure(_Outcome, _Env) -> ok.

terminal_failure_node({step_failed, NodeId, _Reason}) -> {ok, NodeId};
terminal_failure_node({branch_failed, NodeId, _Reason}) -> {ok, NodeId};
terminal_failure_node({member_failed, NodeId, _Reason}) -> {ok, NodeId};
terminal_failure_node({node_failed, NodeId, _Reason}) -> {ok, NodeId};
terminal_failure_node({route_failed, NodeId, _Reason}) -> {ok, NodeId};
terminal_failure_node({graph_loop_failed, NodeId, _Reason}) -> {ok, NodeId};
terminal_failure_node({fork_branch_failed, NodeId, _Reason}) -> {ok, NodeId};
terminal_failure_node({fork_merge_failed, NodeId, _Reason}) -> {ok, NodeId};
terminal_failure_node(
  {node_input_schema_validation_failed, NodeId, _Reason}) -> {ok, NodeId};
terminal_failure_node(
  {node_output_schema_validation_failed, NodeId, _Reason}) -> {ok, NodeId};
terminal_failure_node({fork_join_unsatisfied, NodeId}) -> {ok, NodeId};
terminal_failure_node({loop_body_failed, _Reason}) -> {ok, <<"loop-body">>};
terminal_failure_node({loop_predicate_failed, _Reason}) ->
    {ok, <<"loop-body">>};
terminal_failure_node(invalid_loop_predicate_result) ->
    {ok, <<"loop-body">>};
terminal_failure_node(_Reason) -> error.

lifecycle_sequence() ->
    case get(?LIFECYCLE_SEQUENCE_KEY) of
        Value when is_integer(Value), Value >= 0 -> Value;
        _ -> 0
    end.

outcome_name({completed, _}) -> <<"completed">>;
outcome_name({failed, _}) -> <<"failed">>;
outcome_name(timed_out) -> <<"timed_out">>;
outcome_name({paused, _}) -> <<"paused">>.

workflow_data(Env) -> maps:get(data, maps:get(compiled, Env)).

action_context(Id, Env, Input) ->
    Runtime = maps:get(runtime, Env),
    WorkflowId = maps:get(id, maps:get(compiled, Env)),
    SessionId = maps:get(invocation_id, Runtime,
                         maps:get(execution_id, Runtime)),
    Base = #{workflow_id => WorkflowId,
             kind => maps:get(kind, maps:get(compiled, Env)),
             step_id => Id,
             state => maps:get(state, Env),
             app_name => <<"erlang_adk_workflow">>,
             user_id => WorkflowId,
             session_id => SessionId,
             checkpoint_cursor => maps:get(cursor, Env),
             deadline => maps:get(deadline, Env),
             input => Input,
             state_reducers =>
                 maps:get(state_reducers, workflow_data(Env), #{}),
             budgets => #{steps_remaining => maps:get(steps_remaining, Env),
                          transfers_remaining =>
                              maps:get(transfers_remaining, Env)}},
    WithInvocation = case maps:find(invocation_id, Runtime) of
        {ok, InvocationId} -> Base#{invocation_id => InvocationId};
        error -> Base
    end,
    case erase({?ATTEMPT_KEY_OVERRIDE, Id}) of
        AttemptKey when is_binary(AttemptKey) ->
            WithInvocation#{?ATTEMPT_KEY_OVERRIDE => AttemptKey};
        _ -> WithInvocation
    end.

invocation_id(Env, Default) ->
    Runtime = maps:get(runtime, Env),
    maps:get(invocation_id, Runtime,
             maps:get(execution_id, Runtime, Default)).

remaining_timeout(infinity) -> infinity;
remaining_timeout(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

deadline_expired(infinity) -> false;
deadline_expired(Deadline) ->
    Deadline =< erlang:monotonic_time(millisecond).

cleanup_job(Job) ->
    Pid = maps:get(pid, Job),
    _ = unlink(Pid),
    erlang:demonitor(maps:get(monitor, Job), [flush]),
    flush_exit(Pid),
    ok.

await_worker_down(Job) ->
    Monitor = maps:get(monitor, Job),
    Pid = maps:get(pid, Job),
    receive {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 1000 -> erlang:demonitor(Monitor, [flush])
    end,
    _ = unlink(Pid),
    flush_exit(Pid),
    ok.

kill_active(Active) ->
    Jobs = maps:values(Active),
    lists:foreach(fun(Job) -> exit(maps:get(pid, Job), kill) end, Jobs),
    lists:foreach(fun await_worker_down/1, Jobs),
    ok.

find_job_by_monitor(Monitor, Active) ->
    maps:fold(
      fun(JobRef, Job, error) ->
              case maps:get(monitor, Job) =:= Monitor of
                  true -> {ok, JobRef, Job};
                  false -> error
              end;
         (_JobRef, _Job, Found) -> Found
      end, error, Active).

flush_exit(Pid) ->
    receive {'EXIT', Pid, _Reason} -> flush_exit(Pid)
    after 0 -> ok
    end.

control_name(Control) when is_tuple(Control), tuple_size(Control) > 0 ->
    element(1, Control);
control_name(_) -> invalid.

normalize_execution_result({completed, State, Env}) ->
    {{completed, State}, Env};
normalize_execution_result({paused, Details, Env}) ->
    {{paused, Details}, Env};
normalize_execution_result({failed, Reason, Env}) ->
    {{failed, Reason}, Env};
normalize_execution_result({timed_out, Env}) ->
    {timed_out, Env}.
