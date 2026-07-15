%% @doc Supervised coordinator for a blocking direct agent turn.
%%
%% The coordinator never executes provider/tool work itself. Its linked
%% executor may block, while the coordinator remains able to observe owner
%% death and deadlines and kill that executor deterministically.
-module(adk_agent_turn_worker).
-behaviour(gen_server).

-export([start_link/3, assign_work/2, begin_work/1, cancel/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-record(state, {
    owner :: pid(),
    owner_monitor :: reference(),
    turn_ref :: reference(),
    work :: undefined | fun(() -> term()),
    timeout :: infinity | non_neg_integer(),
    executor = undefined :: undefined | pid(),
    executor_monitor = undefined :: undefined | reference(),
    timer = undefined :: undefined | reference()
}).

-spec start_link(pid(), reference(), infinity | non_neg_integer()) ->
    gen_server:start_ret().
start_link(Owner, TurnRef, Timeout) ->
    gen_server:start_link(?MODULE, {Owner, TurnRef, Timeout}, []).

-spec assign_work(pid(), fun(() -> term())) -> ok | {error, term()}.
assign_work(Pid, Work) when is_pid(Pid), is_function(Work, 0) ->
    gen_server:call(Pid, {assign_work, Work}, 5000).

-spec cancel(pid()) -> ok.
cancel(Pid) when is_pid(Pid) ->
    gen_server:cast(Pid, cancel).

-spec begin_work(pid()) -> ok.
begin_work(Pid) when is_pid(Pid) ->
    gen_server:cast(Pid, begin_work).

init({Owner, TurnRef, Timeout}) ->
    process_flag(trap_exit, true),
    OwnerMonitor = erlang:monitor(process, Owner),
    {ok, #state{owner = Owner,
                owner_monitor = OwnerMonitor,
                turn_ref = TurnRef,
                timeout = Timeout}}.

handle_call({assign_work, Work}, _From,
            State = #state{work = undefined, executor = undefined})
  when is_function(Work, 0) ->
    {reply, ok, State#state{work = Work}};
handle_call({assign_work, _Work}, _From, State) ->
    {reply, {error, work_already_assigned}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(begin_work,
            State = #state{work = Work, timeout = 0,
                           owner = Owner, turn_ref = TurnRef})
  when is_function(Work, 0) ->
    Owner ! {agent_turn_failure, TurnRef, self(), {timeout, 0}},
    {stop, normal, State};
handle_cast(begin_work, State = #state{work = Work})
  when is_function(Work, 0) ->
    self() ! execute,
    {noreply, State};
handle_cast(begin_work, State) ->
    {noreply, State};
handle_cast(cancel, State) ->
    {stop, normal, State};
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(execute, State0 = #state{work = Work})
  when is_function(Work, 0) ->
    Parent = self(),
    {Executor, Monitor} = spawn_opt(
                            fun() -> execute(Parent, Work) end,
                            [link, monitor]),
    Timer = start_timer(State0#state.timeout),
    {noreply, State0#state{work = undefined,
                           executor = Executor,
                           executor_monitor = Monitor,
                           timer = Timer}};
handle_info({agent_turn_execution_result, Executor, Result},
            State = #state{owner = Owner,
                           turn_ref = TurnRef,
                           executor = Executor}) ->
    Owner ! {agent_turn_result, TurnRef, self(), Result},
    {stop, normal, State};
handle_info({agent_turn_execution_failure, Executor, Class, Reason},
            State = #state{owner = Owner,
                           turn_ref = TurnRef,
                           executor = Executor}) ->
    Owner ! {agent_turn_failure, TurnRef, self(),
             {crashed, {Class, Reason}}},
    {stop, normal, State};
handle_info(agent_turn_timeout,
            State = #state{owner = Owner,
                           turn_ref = TurnRef,
                           timeout = Timeout}) ->
    Owner ! {agent_turn_failure, TurnRef, self(), {timeout, Timeout}},
    {stop, normal, State};
handle_info({'DOWN', OwnerMonitor, process, _Owner, _Reason},
            State = #state{owner_monitor = OwnerMonitor}) ->
    {stop, normal, State};
handle_info({'DOWN', ExecutorMonitor, process, Executor, Reason},
            State = #state{owner = Owner,
                           turn_ref = TurnRef,
                           executor = Executor,
                           executor_monitor = ExecutorMonitor}) ->
    Owner ! {agent_turn_failure, TurnRef, self(),
             {worker_exited, safe_reason(Reason)}},
    {stop, normal, State};
handle_info({'EXIT', Executor, _Reason},
            State = #state{executor = Executor}) ->
    %% The monitor carries the definitive outcome. The linked exit makes sure
    %% an untrappable coordinator death also terminates the executor.
    {noreply, State};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    cancel_timer(State#state.timer),
    demonitor_ref(State#state.owner_monitor),
    demonitor_ref(State#state.executor_monitor),
    kill_executor(State#state.executor),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% Work closures and in-flight result messages can retain provider config,
%% credentials, prompts, and tool outputs. Never expose them through status or
%% crash formatting.
format_status(Status) ->
    maps:map(
      fun(state, State = #state{}) ->
              #{active => is_pid(State#state.executor),
                timeout => State#state.timeout};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, _Value) -> adk_secret_redactor:marker()
      end, Status).

execute(Parent, Work) ->
    try Work() of
        Result -> Parent ! {agent_turn_execution_result, self(), Result}
    catch
        Class:Reason:_Stacktrace ->
            Parent ! {agent_turn_execution_failure, self(), Class,
                      safe_reason(Reason)}
    end.

safe_reason(Reason) ->
    adk_secret_redactor:redact(Reason).

start_timer(infinity) -> undefined;
start_timer(Timeout) ->
    erlang:send_after(Timeout, self(), agent_turn_timeout).

cancel_timer(undefined) -> ok;
cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

kill_executor(undefined) -> ok;
kill_executor(Pid) when is_pid(Pid) ->
    exit(Pid, kill),
    ok.

demonitor_ref(undefined) -> ok;
demonitor_ref(Monitor) ->
    _ = erlang:demonitor(Monitor, [flush]),
    ok.
