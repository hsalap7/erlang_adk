%% @doc One isolated ambient event execution with bounded retry.
-module(adk_ambient_job).
-behaviour(gen_statem).

-export([start_link/2, cancel/2]).
-export([init/1, callback_mode/0, handle_event/4,
         terminate/3, code_change/4]).

-define(CANCEL_GRACE_MS, 500).

-spec start_link(binary(), map()) -> gen_statem:start_ret().
start_link(EventRef, Spec) ->
    gen_statem:start_link(?MODULE, {EventRef, Spec}, []).

-spec cancel(pid(), term()) -> ok.
cancel(Pid, Reason) when is_pid(Pid) ->
    gen_statem:cast(Pid, {cancel, Reason}),
    ok.

callback_mode() ->
    handle_event_function.

init({EventRef, Spec}) ->
    Data = #{event_ref => EventRef,
             spec => Spec,
             manager => maps:get(manager, Spec),
             retry_pid => undefined,
             retry_ref => undefined,
             admission_permit => undefined,
             current_run => undefined,
             attempts => 0,
             cancel_reason => undefined,
             cancel_timer => undefined,
             result_seen => false},
    {ok, running, Data, [{next_event, internal, start_retry}]}.

handle_event(internal, start_retry, running, Data) ->
    Spec = maps:get(spec, Data),
    Admission = #{owner => self(), overflow => reject,
                  deadline => maps:get(deadline, Spec)},
    case adk_admission_control:acquire(
           maps:get(admission_id, Spec), Admission) of
        {ok, Permit} ->
            Parent = self(),
            {Pid, Ref} = spawn_monitor(
                           fun() -> execute_retry(Parent, Spec) end),
            {keep_state, Data#{retry_pid => Pid,
                               retry_ref => Ref,
                               admission_permit => Permit}};
        {error, Reason} ->
            finish({failed, {admission_failed, Reason}}, Data)
    end;

handle_event(cast, {cancel, Reason}, running,
             Data = #{cancel_reason := undefined}) ->
    cancel_run(maps:get(current_run, Data), Reason),
    stop_retry(maps:get(retry_pid, Data)),
    Timer = erlang:send_after(?CANCEL_GRACE_MS, self(), force_cancel),
    {keep_state, Data#{cancel_reason => Reason, cancel_timer => Timer}};
handle_event(cast, {cancel, _Reason}, running, _Data) ->
    keep_state_and_data;

handle_event(info, {ambient_attempt, RetryPid, Attempt}, running,
             Data = #{retry_pid := RetryPid,
                      cancel_reason := undefined}) ->
    notify_manager(Data, {attempt, Attempt}),
    {keep_state, Data#{attempts => Attempt, current_run => undefined}};
handle_event(info, {ambient_run_started, RetryPid, Attempt, RunId}, running,
             Data = #{retry_pid := RetryPid,
                      cancel_reason := undefined}) ->
    notify_manager(Data, {run_started, Attempt, RunId}),
    {keep_state, Data#{attempts => Attempt, current_run => RunId}};
handle_event(info, {ambient_run_started, RetryPid, _Attempt, RunId}, running,
             Data = #{retry_pid := RetryPid, cancel_reason := Reason})
  when Reason =/= undefined ->
    cancel_run(RunId, Reason),
    {keep_state, Data#{current_run => RunId}};
handle_event(info, {ambient_run_finished, RetryPid, RunId}, running,
             Data = #{retry_pid := RetryPid, current_run := RunId}) ->
    {keep_state, Data#{current_run => undefined}};

handle_event(info, {ambient_retry_result, RetryPid, Result}, running,
             Data = #{retry_pid := RetryPid,
                      cancel_reason := undefined}) ->
    Data1 = settle_retry_result(Data),
    finish(normalize_result(Result), Data1#{result_seen => true});
handle_event(info, {ambient_retry_result, RetryPid, _Result}, running,
             Data = #{retry_pid := RetryPid, cancel_reason := Reason})
  when Reason =/= undefined ->
    finish({cancelled, Reason}, Data#{result_seen => true});

handle_event(info, {'DOWN', Ref, process, RetryPid, Reason}, running,
             Data = #{retry_pid := RetryPid, retry_ref := Ref,
                      result_seen := false, cancel_reason := undefined}) ->
    finish({failed, {retry_process_down, Reason}},
           Data#{retry_pid => undefined, retry_ref => undefined});
handle_event(info, {'DOWN', Ref, process, RetryPid, _Reason}, running,
             Data = #{retry_pid := RetryPid, retry_ref := Ref,
                      cancel_reason := CancelReason})
  when CancelReason =/= undefined ->
    Data1 = settle_cancelled_run(CancelReason, Data),
    finish({cancelled, CancelReason},
           Data1#{retry_pid => undefined, retry_ref => undefined});
handle_event(info, {'DOWN', Ref, process, RetryPid, _Reason}, terminal,
             Data = #{retry_pid := RetryPid, retry_ref := Ref}) ->
    {keep_state, Data#{retry_pid => undefined, retry_ref => undefined}};

handle_event(info, force_cancel, running,
             Data = #{cancel_reason := Reason})
  when Reason =/= undefined ->
    Data1 = settle_cancelled_run(Reason, Data),
    finish({cancelled, Reason}, Data1#{cancel_timer => undefined});
handle_event(_Type, _Event, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, Data) ->
    cancel_timer(maps:get(cancel_timer, Data, undefined)),
    cancel_run(maps:get(current_run, Data, undefined), ambient_job_stopped),
    stop_retry(maps:get(retry_pid, Data, undefined)),
    release_admission(maps:get(admission_permit, Data, undefined)),
    ok.

code_change(_OldVersion, State, Data, _Extra) ->
    {ok, State, Data}.

execute_retry(Coordinator, Spec) ->
    RetryPid = self(),
    Counter = atomics:new(1, []),
    AttemptFun = fun() ->
        Attempt = atomics:add_get(Counter, 1, 1),
        Coordinator ! {ambient_attempt, RetryPid, Attempt},
        execute_attempt(Coordinator, RetryPid, Attempt, Spec)
    end,
    Retry0 = maps:get(retry, Spec),
    Retry = Retry0#{deadline => maps:get(deadline, Spec)},
    Result = adk_retry:execute(AttemptFun, Retry),
    Coordinator ! {ambient_retry_result, RetryPid, Result}.

execute_attempt(Coordinator, RetryPid, Attempt, Spec) ->
    start_and_await_run(Coordinator, RetryPid, Attempt, Spec).

start_and_await_run(Coordinator, RetryPid, Attempt, Spec) ->
    Runner = maps:get(runner, Spec),
    UserId = maps:get(user_id, Spec),
    SessionId = maps:get(session_id, Spec),
    Payload = maps:get(payload, Spec),
    RunOpts = maps:get(run_options, Spec, #{}),
    case adk_run:start(Runner, UserId, SessionId, Payload, RunOpts) of
        {ok, RunId} ->
            Coordinator ! {ambient_run_started, RetryPid, Attempt, RunId},
            AttemptPid = self(),
            Guard = spawn(fun() ->
                guard_run(AttemptPid, RetryPid, RunId)
            end),
            Result = adk_run:await(RunId, infinity),
            Guard ! {attempt_finished, self()},
            Coordinator ! {ambient_run_finished, RetryPid, RunId},
            normalize_run_result(RunId, Result);
        {error, Reason} ->
            {error, {run_start_failed, Reason}}
    end.

%% The guard makes adk_retry's hard attempt timeout and ambient cancellation
%% cleanup-safe. It cancels the independently supervised adk_run if either the
%% attempt or its retry coordinator disappears before the await completes.
guard_run(AttemptPid, RetryPid, RunId) ->
    AttemptRef = erlang:monitor(process, AttemptPid),
    RetryRef = erlang:monitor(process, RetryPid),
    receive
        {attempt_finished, AttemptPid} ->
            erlang:demonitor(AttemptRef, [flush]),
            erlang:demonitor(RetryRef, [flush]),
            ok;
        {'DOWN', AttemptRef, process, AttemptPid, _Reason} ->
            erlang:demonitor(RetryRef, [flush]),
            _ = adk_run:cancel(RunId, ambient_attempt_stopped),
            ok;
        {'DOWN', RetryRef, process, RetryPid, _Reason} ->
            erlang:demonitor(AttemptRef, [flush]),
            _ = adk_run:cancel(RunId, ambient_retry_stopped),
            exit(AttemptPid, kill),
            ok
    end.

normalize_run_result(RunId, {completed, Output}) ->
    {ok, {completed, #{run_id => RunId, output => Output}}};
normalize_run_result(RunId, {paused, Pause}) ->
    {ok, {paused, #{run_id => RunId, event => Pause}}};
normalize_run_result(_RunId, {failed, Reason}) ->
    {error, {run_failed, Reason}};
normalize_run_result(_RunId, {cancelled, Reason}) ->
    {error, {run_cancelled, Reason}};
normalize_run_result(_RunId, {error, Reason}) ->
    {error, {run_await_failed, Reason}}.

normalize_result({ok, {completed, Result}}) ->
    {completed, Result};
normalize_result({ok, {paused, Result}}) ->
    {paused, Result};
normalize_result({error, retry_deadline_exceeded}) ->
    {timed_out, deadline_exceeded};
normalize_result({error, Reason}) ->
    {failed, Reason}.

finish(Outcome, Data) ->
    cancel_timer(maps:get(cancel_timer, Data, undefined)),
    release_admission(maps:get(admission_permit, Data, undefined)),
    Data1 = Data#{cancel_timer => undefined,
                  admission_permit => undefined},
    notify_manager(Data1, {terminal, Outcome, maps:get(attempts, Data1),
                           maps:get(current_run, Data1)}),
    {stop, normal, Data1}.

notify_manager(Data, Message) ->
    maps:get(manager, Data) !
        {adk_ambient_job, maps:get(event_ref, Data), self(), Message},
    ok.

cancel_run(undefined, _Reason) -> ok;
cancel_run(RunId, Reason) ->
    _ = adk_run:cancel(RunId, Reason),
    ok.

settle_cancelled_run(Reason, Data) ->
    case maps:get(current_run, Data, undefined) of
        undefined -> Data;
        RunId ->
            cancel_run(RunId, Reason),
            %% adk_invocation has its own bounded force-cancel path. Waiting
            %% here prevents an ambient terminal result from racing ahead of
            %% the underlying run's terminal cleanup.
            _ = adk_run:await(RunId, ?CANCEL_GRACE_MS),
            Data#{current_run => undefined}
    end.

settle_retry_result(Data) ->
    case maps:get(current_run, Data, undefined) of
        undefined -> Data;
        RunId ->
            case adk_run:status(RunId) of
                {ok, #{state := running}} ->
                    cancel_run(RunId, ambient_attempt_finished),
                    _ = adk_run:await(RunId, ?CANCEL_GRACE_MS);
                _ ->
                    ok
            end,
            Data#{current_run => undefined}
    end.

stop_retry(undefined) -> ok;
stop_retry(Pid) when is_pid(Pid) ->
    exit(Pid, kill),
    ok.

release_admission(undefined) -> ok;
release_admission(Permit) ->
    _ = adk_admission_control:release(Permit),
    ok.

cancel_timer(undefined) -> ok;
cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.
