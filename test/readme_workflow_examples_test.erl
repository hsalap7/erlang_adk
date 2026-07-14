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
    AddOne = fun(State) ->
        {ok, #{<<"count">> => maps:get(<<"count">>, State, 0) + 1}}
    end,
    MarkDone = fun(_State) ->
        {complete, <<"ready">>, #{<<"done">> => true}}
    end,
    SequentialSpec = #{
        version => 1,
        id => <<"readme-sequential-v1">>,
        kind => sequential,
        max_steps => 4,
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

    ParallelSpec = #{
        version => 1,
        id => <<"readme-parallel-v1">>,
        kind => parallel,
        max_concurrency => 2,
        merge => reject_conflicts,
        branches => [
            #{id => <<"left">>,
              run => fun(_State) -> {ok, #{<<"left">> => 1}} end},
            #{id => <<"right">>,
              run => fun(_State) -> {ok, #{<<"right">> => 2}} end}
        ]
    },
    {ok, Parallel} = erlang_adk:compile_workflow(ParallelSpec),
    {completed, ParallelState, _ParallelCheckpoint} =
        erlang_adk:run_workflow(Parallel, #{}),
    1 = maps:get(<<"left">>, ParallelState),
    2 = maps:get(<<"right">>, ParallelState).

loop_transfer_and_graph_workflows() ->
    LoopSpec = #{
        version => 1,
        id => <<"readme-loop-v1">>,
        kind => loop,
        max_iterations => 3,
        body => fun(State) ->
            {ok, #{<<"attempt">> =>
                       maps:get(<<"attempt">>, State, 0) + 1}}
        end,
        until => fun(State) -> maps:get(<<"attempt">>, State) >= 2 end
    },
    {ok, Loop} = erlang_adk:compile_workflow(LoopSpec),
    {completed, #{<<"attempt">> := 2}, _} =
        erlang_adk:run_workflow(Loop, #{}),

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
                {complete, <<"resolved">>,
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
            {ok, #{<<"count">> => maps:get(<<"count">>, State, 0) + 1}}
        end}],
        edges => #{<<"counter">> => {route, fun(State) ->
            case maps:get(<<"count">>, State) < 3 of
                true -> <<"counter">>;
                false -> end_node
            end
        end}}
    },
    {ok, Graph} = erlang_adk:compile_workflow(GraphSpec),
    {completed, #{<<"count">> := 3}, _} =
        erlang_adk:run_workflow(Graph, #{}).

graph_fork_join_and_pause_resume() ->
    ForkJoinSpec = #{
        version => 1, id => <<"readme-fork-join-v1">>, kind => graph,
        entry => <<"fork">>, max_steps => 6,
        nodes => [
            #{id => <<"fork">>, type => fork,
              branches => [<<"left">>, <<"right">>], join => <<"join">>,
              merge => reject_conflicts, max_concurrency => 2},
            #{id => <<"left">>, run => fun(_) ->
                {ok, #{<<"left">> => 1}}
            end},
            #{id => <<"right">>, run => fun(_) ->
                {ok, #{<<"right">> => 2}}
            end},
            #{id => <<"join">>, type => join}
        ],
        edges => #{<<"left">> => <<"join">>,
                   <<"right">> => <<"join">>,
                   <<"join">> => end_node}
    },
    {ok, ForkJoin} = erlang_adk:compile_workflow(ForkJoinSpec),
    {completed, #{<<"left">> := 1, <<"right">> := 2}, _} =
        erlang_adk:run_workflow(ForkJoin, #{}),

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
