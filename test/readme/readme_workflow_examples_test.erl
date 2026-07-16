-module(readme_workflow_examples_test).
-include_lib("eunit/include/eunit.hrl").

readme_workflow_examples_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_Started) -> ok end,
     [fun sequential_and_parallel_workflows/0,
      fun loop_transfer_and_graph_workflows/0,
      fun graph_fork_join_and_pause_resume/0,
      fun workflow_cancel_checkpoint_and_resume/0]}.

sequential_and_parallel_workflows() ->
    AddOne = fun(State, Context) ->
        null = maps:get(input, Context),
        {output, <<"counted">>,
         #{<<"count">> => maps:get(<<"count">>, State, 0) + 1}}
    end,
    MarkDone = fun(_State, Context) ->
        <<"counted">> = maps:get(input, Context),
        {output, <<"ready">>, #{<<"done">> => true}}
    end,
    SequentialSpec = #{
        version => 1,
        id => <<"readme-sequential-v1">>,
        kind => sequential,
        max_steps => 4,
        input_schema =>
            #{<<"type">> => <<"object">>,
              <<"required">> => [<<"count">>]},
        output_schema => #{<<"type">> => <<"string">>},
        steps => [
            #{id => <<"increment">>, run => AddOne},
            #{id => <<"finish">>, run => MarkDone}
        ]
    },
    {ok, Sequential} = erlang_adk:compile_workflow(SequentialSpec),
    {completed, SequentialState, SequentialCheckpoint} =
        erlang_adk:run_workflow(Sequential, #{<<"count">> => 0}),
    1 = maps:get(<<"count">>, SequentialState),
    true = maps:get(<<"done">>, SequentialState),
    true = maps:get(<<"completed">>, SequentialCheckpoint),
    <<"ready">> = maps:get(<<"output">>, SequentialCheckpoint),

    ParallelSpec = #{
        version => 1,
        id => <<"readme-parallel-v1">>,
        kind => parallel,
        max_concurrency => 2,
        merge => reject_conflicts,
        branches => [
            #{id => <<"left">>,
              run => fun(_State) ->
                  {output, <<"left-output">>, #{<<"left">> => 1}}
              end},
            #{id => <<"right">>,
              run => fun(_State) ->
                  {output, <<"right-output">>, #{<<"right">> => 2}}
              end}
        ]
    },
    {ok, Parallel} = erlang_adk:compile_workflow(ParallelSpec),
    {completed, ParallelState, ParallelCheckpoint} =
        erlang_adk:run_workflow(Parallel, #{}),
    1 = maps:get(<<"left">>, ParallelState),
    2 = maps:get(<<"right">>, ParallelState),
    #{<<"left">> := <<"left-output">>,
      <<"right">> := <<"right-output">>} =
        maps:get(<<"output">>, ParallelCheckpoint),

    RetryTable = ets:new(readme_workflow_retry, [set, public]),
    ets:insert(RetryTable, {attempts, 0}),
    RetryAction = fun(_State, Context) ->
        Attempt = ets:update_counter(RetryTable, attempts, 1),
        Attempt = maps:get(attempt, Context),
        case Attempt of
            1 -> {error, transient_failure};
            2 -> {output, <<"recovered">>, #{<<"retried">> => true}}
        end
    end,
    RetrySpec = #{
        version => 1,
        id => <<"readme-workflow-retry-v1">>,
        kind => sequential,
        max_steps => 1,
        steps => [
            #{id => <<"retryable">>, run => RetryAction,
              timeout => 1000,
              retry => #{max_attempts => 2, backoff_ms => 10}}
        ]
    },
    {ok, Retrying} = erlang_adk:compile_workflow(RetrySpec),
    {completed, #{<<"retried">> := true}, RetryCheckpoint} =
        erlang_adk:run_workflow(Retrying, #{}),
    <<"recovered">> = maps:get(<<"output">>, RetryCheckpoint),
    true = ets:delete(RetryTable).

loop_transfer_and_graph_workflows() ->
    LoopSpec = #{
        version => 1,
        id => <<"readme-loop-v1">>,
        kind => loop,
        max_iterations => 3,
        body => fun(State) ->
            Attempt = maps:get(<<"attempt">>, State, 0) + 1,
            {output, Attempt, #{<<"attempt">> => Attempt}}
        end,
        until => fun(State) -> maps:get(<<"attempt">>, State) >= 2 end
    },
    {ok, Loop} = erlang_adk:compile_workflow(LoopSpec),
    {completed, #{<<"attempt">> := 2}, LoopCheckpoint} =
        erlang_adk:run_workflow(Loop, #{}),
    2 = maps:get(<<"output">>, LoopCheckpoint),

    TransferSpec = #{
        version => 1,
        id => <<"readme-transfer-v1">>,
        kind => transfer,
        entry => <<"triage">>,
        max_transfers => 1,
        members => #{
            <<"triage">> => #{run => fun(_State, _Context) ->
                {transfer, <<"specialist">>, <<"handoff">>,
                 #{<<"triaged">> => true}}
            end},
            <<"specialist">> => #{run => fun(State, Context) ->
                true = maps:get(<<"triaged">>, State),
                <<"handoff">> = maps:get(input, Context),
                {stop, <<"resolved">>,
                 #{<<"resolved">> => true}}
            end}
        }
    },
    {ok, Transfer} = erlang_adk:compile_workflow(TransferSpec),
    {completed, #{<<"resolved">> := true}, _} =
        erlang_adk:run_workflow(Transfer, #{}),

    GraphSpec = #{
        version => 1,
        id => <<"readme-graph-v1">>,
        kind => graph,
        entry => <<"counter">>,
        max_steps => 5,
        nodes => [#{id => <<"counter">>, run => fun(State) ->
            Count = maps:get(<<"count">>, State, 0) + 1,
            {output, Count, #{<<"count">> => Count}}
        end}],
        edges => #{<<"counter">> => {route, fun(_State, Context) ->
            Count = maps:get(input, Context),
            case Count < 3 of
                true -> <<"counter">>;
                false -> end_node
            end
        end}}
    },
    {ok, Graph} = erlang_adk:compile_workflow(GraphSpec),
    {completed, #{<<"count">> := 3}, GraphCheckpoint} =
        erlang_adk:run_workflow(Graph, #{}),
    3 = maps:get(<<"output">>, GraphCheckpoint).

graph_fork_join_and_pause_resume() ->
    ForkJoinSpec = #{
        version => 1, id => <<"readme-fork-join-v1">>, kind => graph,
        entry => <<"fork">>, max_steps => 6,
        nodes => [
            #{id => <<"fork">>, type => fork,
              branches => [<<"left">>, <<"right">>], join => <<"join">>,
              merge => reject_conflicts, max_concurrency => 2},
            #{id => <<"left">>, run => fun(_) ->
                {output, <<"left-output">>, #{<<"left">> => 1}}
            end},
            #{id => <<"right">>, run => fun(_) ->
                {output, <<"right-output">>, #{<<"right">> => 2}}
            end},
            #{id => <<"join">>, type => join,
              run => fun(_State, Context) ->
                  Outputs = maps:get(input, Context),
                  <<"left-output">> = maps:get(<<"left">>, Outputs),
                  <<"right-output">> = maps:get(<<"right">>, Outputs),
                  {output, Outputs, #{<<"joined">> => true}}
              end}
        ],
        edges => #{<<"left">> => <<"join">>,
                   <<"right">> => <<"join">>,
                   <<"join">> => end_node}
    },
    {ok, ForkJoin} = erlang_adk:compile_workflow(ForkJoinSpec),
    {completed, #{<<"left">> := 1, <<"right">> := 2,
                  <<"joined">> := true}, ForkCheckpoint} =
        erlang_adk:run_workflow(ForkJoin, #{}),
    #{<<"left">> := <<"left-output">>,
      <<"right">> := <<"right-output">>} =
        maps:get(<<"output">>, ForkCheckpoint),

    ApprovalSpec = #{
        version => 1, id => <<"readme-graph-approval-v1">>, kind => graph,
        entry => <<"approval">>, max_steps => 3,
        nodes => [
            #{id => <<"approval">>, run => fun(_) ->
                {pause, human_approval, <<"Approve this action">>,
                 #{<<"approval_requested">> => true}}
            end},
            #{id => <<"accepted">>, run => fun(_) ->
                {ok, #{<<"accepted">> => true}}
            end}
        ],
        edges => #{
            <<"approval">> => {route, fun(_State, Context) ->
                true = maps:get(<<"approved">>, maps:get(input, Context)),
                <<"accepted">>
            end},
            <<"accepted">> => end_node}
    },
    {ok, Approval} = erlang_adk:compile_workflow(ApprovalSpec),
    {paused, _PauseDetails, ApprovalCheckpoint} =
        erlang_adk:run_workflow(Approval, #{}),
    {ok, ApprovalRef} = erlang_adk:resume_workflow(
        Approval, ApprovalCheckpoint,
        #{resume_input => #{<<"approved">> => true}}),
    {completed, #{<<"approval_requested">> := true,
                  <<"accepted">> := true}, _} =
        erlang_adk:await_workflow(ApprovalRef),

    {ok, LedgerHandle} = adk_invocation_ledger_mnesia:init(#{}),
    DurableOptions = #{
        ledger => {adk_invocation_ledger_mnesia, LedgerHandle},
        lease_ms => 30000,
        timeout => 120000
    },
    {ok, DurableInvocationId, DurableApprovalRef} =
        erlang_adk:start_workflow_invocation(
          Approval, #{}, DurableOptions),
    {paused, _DurablePause, _DurableCheckpoint} =
        erlang_adk:await_workflow(DurableApprovalRef),
    {ok, #{phase := paused, owned := false}} =
        erlang_adk:workflow_invocation_status(
          DurableInvocationId, DurableOptions),
    {ok, DurableResumedRef} = erlang_adk:resume_workflow_invocation(
        DurableInvocationId, Approval,
        DurableOptions#{resume_input => #{<<"approved">> => true}}),
    {completed, #{<<"approval_requested">> := true,
                  <<"accepted">> := true}, _} =
        erlang_adk:await_workflow(DurableResumedRef),
    ok = erlang_adk:delete_workflow_invocation(
           DurableInvocationId, DurableOptions).

workflow_cancel_checkpoint_and_resume() ->
    Parent = self(),
    WaitForRelease = fun(_State) ->
        Parent ! {workflow_waiting, self()},
        receive
            continue -> {ok, #{<<"released">> => true}}
        end
    end,
    ResumeSpec = #{
        version => 1,
        id => <<"readme-resume-v1">>,
        kind => sequential,
        max_steps => 2,
        steps => [#{id => <<"wait">>, run => WaitForRelease}]
    },
    {ok, ResumeCompiled} = erlang_adk:compile_workflow(ResumeSpec),
    {ok, WorkflowRef} = erlang_adk:start_workflow(ResumeCompiled, #{}),
    FirstWorker = receive {workflow_waiting, Pid1} -> Pid1 end,
    FirstWorkerMonitor = erlang:monitor(process, FirstWorker),
    {ok, #{state := running}} =
        erlang_adk:workflow_status(WorkflowRef),
    {ok, Checkpoint} = erlang_adk:workflow_checkpoint(WorkflowRef),
    ok = erlang_adk:cancel_workflow(WorkflowRef, revise_later),
    {cancelled, revise_later, Checkpoint} =
        erlang_adk:await_workflow(WorkflowRef),
    receive
        {'DOWN', FirstWorkerMonitor, process, FirstWorker, _} -> ok
    end,

    {ok, ResumedRef} =
        erlang_adk:resume_workflow(ResumeCompiled, Checkpoint),
    SecondWorker = receive {workflow_waiting, Pid2} -> Pid2 end,
    SecondWorker ! continue,
    {completed, #{<<"released">> := true}, _} =
        erlang_adk:await_workflow(ResumedRef).
