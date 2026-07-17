%% @doc Supervised coordinator for one bounded unit of work.
-module(adk_task_worker).
-behaviour(gen_statem).

-export([start_link/1, handoff/4]).
-export([init/1, callback_mode/0, handle_event/4,
         terminate/3, code_change/4, format_status/1]).

-spec start_link(binary()) -> gen_statem:start_ret().
start_link(TaskRef) ->
    gen_statem:start_link(?MODULE, TaskRef, []).

-spec handoff(pid(), binary(),
              fun(() -> term()) | {module(), atom(), [term()]}, map()) ->
    ok | {error, term()}.
handoff(Pid, TaskRef, Work, Opts) ->
    try gen_statem:call(Pid, {handoff, TaskRef, Work, Opts}, 5000) of
        Reply -> Reply
    catch
        exit:_ -> {error, task_handoff_failed}
    end.

callback_mode() ->
    handle_event_function.

init(TaskRef) ->
    {ok, awaiting_handoff,
     #{task_ref => TaskRef,
       started_at => erlang:system_time(millisecond),
       finished_at => undefined,
       outcome => undefined,
       execution => undefined,
       execution_ref => undefined,
       deadline_timer => undefined,
       waiters => #{}}}.

handle_event({call, From}, {handoff, TaskRef, Work, Opts},
             awaiting_handoff, Data0 = #{task_ref := ExpectedTaskRef}) ->
    case TaskRef =:= ExpectedTaskRef andalso
         valid_handoff_work(Work) andalso valid_handoff_opts(Opts) of
        false ->
            {keep_state_and_data,
             [{reply, From, {error, invalid_task_handoff}}]};
        true ->
            case adk_task_registry:register(TaskRef, self()) of
                ok ->
                    OwnerRef = monitor_owner(Opts),
                    Data = Data0#{work => Work,
                                  deadline => maps:get(deadline, Opts),
                                  retention_ms =>
                                      maps:get(retention_ms, Opts),
                                  notify => maps:get(notify, Opts),
                                  owner => maps:get(owner, Opts),
                                  owner_ref => OwnerRef},
                    {next_state, running, Data,
                     [{reply, From, ok},
                      {next_event, internal, start_execution}]};
                {error, Reason} ->
                    Failure = adk_failure:external(
                                adk_task, registry_registration, Reason),
                    {stop_and_reply, normal,
                     [{reply, From, {error, Failure}}]}
            end
    end;
handle_event({call, From}, {handoff, _TaskRef, _Work, _Opts},
             awaiting_handoff, _Data) ->
    {keep_state_and_data, [{reply, From, {error, invalid_task_handoff}}]};
handle_event({call, From}, {handoff, _TaskRef, _Work, _Opts},
             _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, handoff_already_completed}}]};

handle_event(internal, start_execution, running, Data) ->
    case remaining_time(maps:get(deadline, Data)) of
        expired ->
            finish({timed_out, deadline_exceeded}, Data);
        Remaining ->
            Parent = self(),
            Work = maps:get(work, Data),
            {Pid, Ref} = spawn_monitor(
                           fun() -> execute_work(Parent, Work) end),
            Timer = start_deadline_timer(Remaining),
            {keep_state,
             (maps:remove(work, Data))#{execution => Pid,
                                        execution_ref => Ref,
                                        deadline_timer => Timer}}
    end;

handle_event({call, From}, status, _State, Data) ->
    {keep_state_and_data, [{reply, From, status_map(Data)}]};

handle_event({call, From}, await, running, Data0) ->
    WaiterPid = element(1, From),
    Ref = erlang:monitor(process, WaiterPid),
    Waiters = maps:get(waiters, Data0),
    {keep_state, Data0#{waiters => Waiters#{Ref => From}}};
handle_event({call, From}, await, terminal, Data) ->
    {keep_state_and_data,
     [{reply, From, maps:get(outcome, Data)}]};

handle_event({call, From}, {cancel, Reason}, running, Data0) ->
    stop_execution(Data0),
    gen_statem:reply(From, ok),
    Failure = adk_failure:external(adk_task, cancel, Reason),
    finish({cancelled, Failure}, clear_execution(Data0));
handle_event({call, From}, {cancel, _Reason}, terminal, _Data) ->
    {keep_state_and_data,
     [{reply, From, {error, already_terminal}}]};

handle_event(info, {adk_task_result, Execution, Result}, running,
             Data = #{execution := Execution}) ->
    finish({completed, Result}, Data);
handle_event(info,
             {adk_task_exception, Execution, Class, Reason},
             running, Data = #{execution := Execution}) ->
    finish({failed, adk_failure:exception(
                      adk_task, execute, Class, Reason)}, Data);

handle_event(info, {timeout, Timer, deadline}, running,
             Data = #{deadline_timer := Timer}) ->
    stop_execution(Data),
    finish({timed_out, deadline_exceeded},
           clear_execution(Data#{deadline_timer => undefined}));

handle_event(info, {'DOWN', Ref, process, Execution, Reason}, running,
             Data = #{execution := Execution, execution_ref := Ref}) ->
    finish({failed, adk_failure:external(
                      adk_task, execution_process_down, Reason)},
           clear_execution(Data));
handle_event(info, {'DOWN', Ref, process, Owner, Reason}, running,
             Data = #{owner := Owner, owner_ref := Ref}) ->
    stop_execution(Data),
    finish({cancelled, adk_failure:external(
                         adk_task, owner_down, Reason)},
           clear_execution(Data#{owner_ref => undefined}));
handle_event(info, {'DOWN', Ref, process, Execution, _Reason}, terminal,
             Data = #{execution := Execution, execution_ref := Ref}) ->
    {keep_state, clear_execution(Data)};
handle_event(info, {'DOWN', Ref, process, Owner, _Reason}, terminal,
             Data = #{owner := Owner, owner_ref := Ref}) ->
    {keep_state, Data#{owner_ref => undefined}};
handle_event(info, {'DOWN', Ref, process, _Pid, _Reason}, State, Data0) ->
    Waiters = maps:get(waiters, Data0),
    {next_state, State,
     Data0#{waiters => maps:remove(Ref, Waiters)}};

handle_event(info, {adk_task_result, _Execution, _Result}, terminal, _Data) ->
    keep_state_and_data;
handle_event(info,
             {adk_task_exception, _Execution, _Class, _Reason},
             terminal, _Data) ->
    keep_state_and_data;
handle_event(info, {timeout, _Timer, deadline}, terminal, _Data) ->
    keep_state_and_data;

handle_event(state_timeout, expire, terminal, Data) ->
    {stop, normal, Data};
handle_event(_Type, _Event, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, Data) ->
    cancel_deadline_timer(maps:get(deadline_timer, Data, undefined)),
    stop_execution(Data),
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%% Work, current messages, outcomes, and waiter From terms can all contain
%% application data. Expose only bounded operational counters to sys/OTP.
format_status(Status) ->
    maps:map(
      fun(state, Data) when is_map(Data) ->
              #{task_ref => maps:get(task_ref, Data, undefined),
                state => outcome_state(maps:get(outcome, Data, undefined)),
                started_at => maps:get(started_at, Data, undefined),
                finished_at => maps:get(finished_at, Data, undefined),
                execution_running => is_pid(
                                       maps:get(execution, Data, undefined)),
                waiter_count => map_size(maps:get(waiters, Data, #{}))};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, _Value) -> adk_secret_redactor:marker()
      end, Status).

execute_work(Parent, Work) ->
    try invoke(Work) of
        Result ->
            Parent ! {adk_task_result, self(), Result}
    catch
        Class:Reason:_Stacktrace ->
            %% Stacktraces may contain arguments, credentials, or other
            %% process-local data. They are intentionally not retained in the
            %% public task outcome.
            Parent ! {adk_task_exception, self(), Class, Reason}
    end.

invoke(Fun) when is_function(Fun, 0) ->
    Fun();
invoke({Module, Function, Args}) ->
    apply(Module, Function, Args).

finish(Outcome, Data0) ->
    cancel_deadline_timer(maps:get(deadline_timer, Data0)),
    reply_waiters(Outcome, maps:get(waiters, Data0)),
    notify(maps:get(notify, Data0),
           maps:get(task_ref, Data0), Outcome),
    Data1 = Data0#{outcome => Outcome,
                   finished_at => erlang:system_time(millisecond),
                   deadline_timer => undefined,
                   waiters => #{}},
    {next_state, terminal, Data1,
     [{state_timeout, maps:get(retention_ms, Data1), expire}]}.

reply_waiters(Outcome, Waiters) ->
    maps:foreach(
      fun(Ref, From) ->
          erlang:demonitor(Ref, [flush]),
          gen_statem:reply(From, Outcome)
      end, Waiters).

notify(undefined, _TaskRef, _Outcome) ->
    ok;
notify(Pid, TaskRef, Outcome) ->
    Pid ! {adk_task_terminal, TaskRef, Outcome},
    ok.

monitor_owner(#{cancel_on_owner_down := true, owner := Owner})
  when is_pid(Owner) ->
    erlang:monitor(process, Owner);
monitor_owner(_Opts) ->
    undefined.

remaining_time(infinity) ->
    infinity;
remaining_time(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining =< 0 -> expired;
        Remaining -> Remaining
    end.

start_deadline_timer(infinity) ->
    undefined;
start_deadline_timer(Remaining) ->
    erlang:start_timer(Remaining, self(), deadline).

cancel_deadline_timer(undefined) ->
    ok;
cancel_deadline_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

stop_execution(Data) ->
    case maps:get(execution, Data, undefined) of
        Pid when is_pid(Pid) ->
            exit(Pid, kill),
            ok;
        undefined ->
            ok
    end.

clear_execution(Data) ->
    case maps:get(execution_ref, Data, undefined) of
        Ref when is_reference(Ref) ->
            erlang:demonitor(Ref, [flush]);
        undefined ->
            ok
    end,
    Data#{execution => undefined, execution_ref => undefined}.

valid_handoff_work(Work) when is_function(Work, 0) -> true;
valid_handoff_work({Module, Function, Args}) ->
    is_atom(Module) andalso is_atom(Function) andalso is_list(Args);
valid_handoff_work(_) -> false.

valid_handoff_opts(Opts) when is_map(Opts) ->
    Deadline = maps:get(deadline, Opts, invalid),
    Retention = maps:get(retention_ms, Opts, invalid),
    Notify = maps:get(notify, Opts, invalid),
    Owner = maps:get(owner, Opts, invalid),
    CancelOnOwnerDown = maps:get(cancel_on_owner_down, Opts, invalid),
    (Deadline =:= infinity orelse is_integer(Deadline)) andalso
    is_integer(Retention) andalso Retention >= 0 andalso
    (Notify =:= undefined orelse is_pid(Notify)) andalso
    (Owner =:= undefined orelse is_pid(Owner)) andalso
    is_boolean(CancelOnOwnerDown) andalso
    (CancelOnOwnerDown =:= false orelse is_pid(Owner));
valid_handoff_opts(_) -> false.

status_map(Data) ->
    Outcome = maps:get(outcome, Data),
    #{task_ref => maps:get(task_ref, Data),
      state => outcome_state(Outcome),
      outcome => Outcome,
      deadline => maps:get(deadline, Data),
      started_at => maps:get(started_at, Data),
      finished_at => maps:get(finished_at, Data),
      waiter_count => map_size(maps:get(waiters, Data))}.

outcome_state(undefined) -> running;
outcome_state({completed, _}) -> completed;
outcome_state({failed, _}) -> failed;
outcome_state({timed_out, _}) -> timed_out;
outcome_state({cancelled, _}) -> cancelled.
