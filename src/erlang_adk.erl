-module(erlang_adk).

-export([spawn_agent/3, stop_agent/1, prompt/2, delegate/2, delegate/3,
         delegate/4, sequential/2, parallel/2, parallel/3, loop/4,
         compile_workflow/1,
         start_workflow/2, start_workflow/3,
         run_workflow/2, run_workflow/3,
         await_workflow/1, await_workflow/2,
         cancel_workflow/1, cancel_workflow/2,
         workflow_status/1, workflow_checkpoint/1,
         resume_workflow/2, resume_workflow/3,
         start_workflow_invocation/3,
         resume_workflow_invocation/3,
         workflow_invocation_status/2,
         delete_workflow_invocation/2,
         run_planning/4, run_planning/5,
         start_planning/4, start_planning/5,
         await_planning/1, await_planning/2,
         cancel_planning/1, cancel_planning/2]).

-export_type([planning_ref/0]).

-define(PLANNING_REF, adk_planning_ref).

-opaque planning_ref() :: {?PLANNING_REF, pid(), pid(), reference()}.

%% @doc Spawn a new agent.
spawn_agent(Name, LLMConfig, Tools) ->
    adk_agent_sup:start_agent(Name, LLMConfig, Tools).

%% @doc Stop an agent gracefully so its name can be reused.
stop_agent(AgentPid) ->
    adk_agent:stop(AgentPid).

%% @doc Synchronously prompt an agent.
prompt(AgentPid, Message) ->
    adk_agent:prompt(AgentPid, Message).

%% @doc Asynchronously delegate a task to an agent (fire and forget).
delegate(Pid, Message) ->
    adk_agent:delegate(Pid, Message).

%% @doc Asynchronously delegate a task to an agent and receive a message when done.
delegate(Pid, Message, ReplyToPid) ->
    adk_agent:delegate(Pid, Message, ReplyToPid).

%% @doc Asynchronously delegate and correlate the reply with Ref.
delegate(Pid, Message, ReplyToPid, Ref) ->
    adk_agent:delegate(Pid, Message, ReplyToPid, Ref).

%% Orchestrators
sequential(Pids, Prompt) ->
    erlang_adk_orchestrator:sequential(Pids, Prompt).

parallel(Pids, Prompt) ->
    erlang_adk_orchestrator:parallel(Pids, Prompt).

parallel(Pids, Prompt, Timeout) ->
    erlang_adk_orchestrator:parallel(Pids, Prompt, Timeout).

loop(WorkerPid, ReviewerPid, Prompt, MaxIterations) ->
    erlang_adk_orchestrator:loop(WorkerPid, ReviewerPid, Prompt, MaxIterations).

%% First-class bounded workflows

%% @doc Validate and compile a declarative workflow specification.
compile_workflow(Spec) ->
    adk_workflow:compile(Spec).

%% @doc Start an independently supervised workflow coordinator.
start_workflow(Compiled, InitialState) ->
    adk_workflow:start(Compiled, InitialState).

start_workflow(Compiled, InitialState, Opts) ->
    adk_workflow:start(Compiled, InitialState, Opts).

%% @doc Run a compiled workflow synchronously to one terminal outcome.
run_workflow(Compiled, InitialState) ->
    adk_workflow:run(Compiled, InitialState).

run_workflow(Compiled, InitialState, Opts) ->
    adk_workflow:run(Compiled, InitialState, Opts).

await_workflow(WorkflowRef) ->
    adk_workflow:await(WorkflowRef).

await_workflow(WorkflowRef, Timeout) ->
    adk_workflow:await(WorkflowRef, Timeout).

cancel_workflow(WorkflowRef) ->
    adk_workflow:cancel(WorkflowRef).

cancel_workflow(WorkflowRef, Reason) ->
    adk_workflow:cancel(WorkflowRef, Reason).

workflow_status(WorkflowRef) ->
    adk_workflow:status(WorkflowRef).

workflow_checkpoint(WorkflowRef) ->
    adk_workflow:checkpoint(WorkflowRef).

resume_workflow(Compiled, Checkpoint) ->
    adk_workflow:resume(Compiled, Checkpoint).

resume_workflow(Compiled, Checkpoint, Opts) ->
    adk_workflow:resume(Compiled, Checkpoint, Opts).

%% @doc Start a durably checkpointed workflow and return its stable invocation
%% ID together with the current supervised coordinator pid.
start_workflow_invocation(Compiled, InitialState, Opts) ->
    adk_workflow:start_invocation(Compiled, InitialState, Opts).

%% @doc Resume a durable workflow by invocation ID after coordinator or
%% application failure.
resume_workflow_invocation(InvocationId, Compiled, Opts) ->
    adk_workflow:resume_invocation(InvocationId, Compiled, Opts).

workflow_invocation_status(InvocationId, Opts) ->
    adk_workflow:invocation_status(InvocationId, Opts).

delete_workflow_invocation(InvocationId, Opts) ->
    adk_workflow:delete_invocation(InvocationId, Opts).

%% Provider-neutral explicit planning

%% @doc Run a trusted planner and executor synchronously with default limits.
-spec run_planning(adk_planner:descriptor(),
                   adk_plan_executor:descriptor(), term(), map()) ->
    {ok, adk_planning_runtime:result()} | {error, term()}.
run_planning(Planner, Executor, Goal, Context) ->
    run_planning(Planner, Executor, Goal, Context, #{}).

%% @doc Run explicit planning synchronously with bounded runtime options.
-spec run_planning(adk_planner:descriptor(),
                   adk_plan_executor:descriptor(), term(), map(), map()) ->
    {ok, adk_planning_runtime:result()} | {error, term()}.
run_planning(Planner, Executor, Goal, Context, Opts) ->
    adk_planning_runtime:run(Planner, Executor, Goal, Context, Opts).

%% @doc Start owner-bound explicit planning with default limits.
-spec start_planning(adk_planner:descriptor(),
                     adk_plan_executor:descriptor(), term(), map()) ->
    {ok, planning_ref()} | {error, term()}.
start_planning(Planner, Executor, Goal, Context) ->
    start_planning(Planner, Executor, Goal, Context, #{}).

%% @doc Start owner-bound explicit planning with bounded runtime options.
-spec start_planning(adk_planner:descriptor(),
                     adk_plan_executor:descriptor(), term(), map(), map()) ->
    {ok, planning_ref()} | {error, term()}.
start_planning(Planner, Executor, Goal, Context, Opts) ->
    Owner = self(),
    case adk_planning_runtime:start(
           Planner, Executor, Goal, Context, Opts) of
        {ok, RuntimePid, RunRef} ->
            {ok, {?PLANNING_REF, Owner, RuntimePid, RunRef}};
        {error, _} = Error -> Error
    end.

%% @doc Await a planning result without an additional caller timeout.
-spec await_planning(planning_ref()) ->
    {ok, adk_planning_runtime:result()} | {error, term()}.
await_planning(PlanningRef) ->
    await_planning(PlanningRef, infinity).

%% @doc Await a planning result for at most `Timeout' milliseconds.
-spec await_planning(planning_ref(), timeout()) ->
    {ok, adk_planning_runtime:result()} | {error, term()}.
await_planning({?PLANNING_REF, Owner, RuntimePid, RunRef}, Timeout)
  when Owner =:= self(), is_pid(RuntimePid), is_reference(RunRef) ->
    case adk_planning_runtime:validate_ref(RuntimePid, RunRef) of
        ok ->
            adk_planning_runtime:await(RuntimePid, RunRef, Timeout);
        {error, {planning_process_down, _}} ->
            %% A fast runtime may have delivered its terminal result before
            %% this validation round trip. `await/3' consumes that exact
            %% owner/correlation message or reports the process failure.
            adk_planning_runtime:await(RuntimePid, RunRef, Timeout);
        {error, _} = Error -> Error
    end;
await_planning({?PLANNING_REF, Owner, RuntimePid, RunRef}, _Timeout)
  when is_pid(Owner), is_pid(RuntimePid), is_reference(RunRef) ->
    {error, not_planning_owner};
await_planning(_PlanningRef, _Timeout) ->
    {error, invalid_planning_ref}.

%% @doc Cancel planning with the default `user_cancelled' reason.
-spec cancel_planning(planning_ref()) -> ok | {error, term()}.
cancel_planning(PlanningRef) ->
    cancel_planning(PlanningRef, user_cancelled).

%% @doc Cancel planning with an application-supplied reason.
-spec cancel_planning(planning_ref(), term()) -> ok | {error, term()}.
cancel_planning({?PLANNING_REF, Owner, RuntimePid, RunRef}, Reason)
  when Owner =:= self(), is_pid(RuntimePid), is_reference(RunRef) ->
    adk_planning_runtime:cancel(RuntimePid, RunRef, Reason);
cancel_planning({?PLANNING_REF, Owner, RuntimePid, RunRef}, _Reason)
  when is_pid(Owner), is_pid(RuntimePid), is_reference(RunRef) ->
    {error, not_planning_owner};
cancel_planning(_PlanningRef, _Reason) ->
    {error, invalid_planning_ref}.
