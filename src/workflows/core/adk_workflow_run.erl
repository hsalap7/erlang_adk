%% @doc Responsive coordinator for one workflow execution.
-module(adk_workflow_run).
-behaviour(gen_server).

-export([start_link/1, handoff/5]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(DEFAULT_TIMEOUT, 30000).
-define(DEFAULT_RETENTION_MS, 60000).
-define(DURABLE_OPT, '$adk_durable_invocation').
-define(HANDOFF_TIMEOUT, 5000).

-spec start_link(reference()) -> gen_server:start_ret().
start_link(LaunchRef) ->
    gen_server:start_link(?MODULE, LaunchRef, []).

-spec handoff(pid(), reference(), map(), map(), map()) ->
    ok | {error, term()}.
handoff(Pid, LaunchRef, Compiled, InitialState, Opts) ->
    try gen_server:call(
          Pid, {handoff, LaunchRef, Compiled, InitialState, Opts},
          ?HANDOFF_TIMEOUT) of
        Reply -> Reply
    catch
        exit:_ -> {error, workflow_handoff_failed}
    end.

init(LaunchRef) when is_reference(LaunchRef) ->
    process_flag(trap_exit, true),
    {ok, #{launch_ref => LaunchRef,
           state => awaiting_handoff,
           engine => undefined,
           engine_ref => undefined,
           deadline_timer => undefined,
           lease_timer => undefined,
           terminal_timer => undefined,
           durable => undefined,
           waiters => #{},
           started_at => erlang:system_time(millisecond),
           finished_at => undefined,
           event_count => 0}};
init(_Invalid) ->
    {stop, invalid_workflow_launch_ref}.

handle_call({handoff, LaunchRef, Compiled, InitialState0, Opts0}, _From,
            State = #{state := awaiting_handoff,
                      launch_ref := ExpectedLaunchRef}) ->
    case LaunchRef =:= ExpectedLaunchRef
         andalso is_map(Compiled)
         andalso is_map(InitialState0)
         andalso is_map(Opts0) of
        false ->
            {reply, {error, invalid_workflow_handoff}, State};
        true ->
            case initialize_run(Compiled, InitialState0, Opts0, State) of
                {ok, RunningState} -> {reply, ok, RunningState};
                {error, Reason} -> {reply, {error, Reason}, State}
            end
    end;
handle_call({handoff, _LaunchRef, _Compiled, _InitialState, _Opts}, _From,
            State) ->
    {reply, {error, handoff_already_completed}, State};
handle_call(status, _From, State = #{state := awaiting_handoff}) ->
    {reply, #{state => awaiting_handoff}, State};
handle_call(checkpoint, _From, State = #{state := awaiting_handoff}) ->
    {reply, {error, workflow_not_initialized}, State};
handle_call(await, _From, State = #{state := awaiting_handoff}) ->
    {reply, {error, workflow_not_initialized}, State};
handle_call({cancel, _Reason}, _From,
            State = #{state := awaiting_handoff}) ->
    {reply, {error, workflow_not_initialized}, State};
handle_call(status, _From, State) ->
    {reply, status_map(State), State};
handle_call(checkpoint, _From, State) ->
    {reply, maps:get(checkpoint, State), State};
handle_call(await, From, State = #{state := running}) ->
    Waiter = element(1, From),
    Ref = erlang:monitor(process, Waiter),
    Waiters = maps:get(waiters, State),
    {noreply, State#{waiters => Waiters#{Ref => From}}};
handle_call(await, _From, State) ->
    {reply, maps:get(outcome, State), State};
handle_call({cancel, Reason0}, _From, State = #{state := running}) ->
    Reason = adk_workflow:external_reason(adk_workflow, cancel, Reason0),
    stop_engine(State),
    Outcome = {cancelled, Reason, maps:get(checkpoint, State)},
    {reply, ok, finish(Outcome, State)};
handle_call({cancel, _Reason}, _From, State) ->
    {reply, {error, already_terminal}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

initialize_run(Compiled, InitialState0, Opts0, BaseState) ->
    case normalize_init(Compiled, InitialState0, Opts0) of
        {ok, InitialState0, Runtime0, Checkpoint0} ->
            case prepare_durable(Compiled, InitialState0, Runtime0,
                                 Checkpoint0, Opts0) of
                {ok, InitialState, Runtime, Checkpoint, Durable} ->
                    Parent = self(),
                    {Engine, EngineRef} = spawn_monitor(
                                            fun() ->
                                                adk_workflow_engine:execute(
                                                  Parent, Compiled,
                                                  InitialState, Runtime,
                                                  Checkpoint)
                                            end),
                    DeadlineTimer = deadline_timer(
                                      maps:get(deadline, Runtime)),
                    LeaseTimer = lease_timer(Durable),
                    {ok, BaseState#{compiled => Compiled,
                           runtime => Runtime,
                           engine => Engine,
                           engine_ref => EngineRef,
                           deadline_timer => DeadlineTimer,
                           lease_timer => LeaseTimer,
                           durable => Durable,
                           state => running,
                           outcome => undefined,
                           checkpoint => Checkpoint,
                           waiters => #{},
                           event_count => 0}};
                {error, Reason} ->
                    {error, public_init_error(Reason)}
            end;
        {error, Reason} ->
            {error, public_init_error(Reason)}
    end.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({adk_workflow_checkpoint, Engine, AckRef, Checkpoint},
            State = #{state := running, engine := Engine}) ->
    case persist_checkpoint(Checkpoint, State) of
        {ok, State1} ->
            %% The engine cannot begin the next action until this ACK.  For a
            %% durable invocation the ledger transaction above therefore is
            %% the commit boundary.
            Engine ! {adk_workflow_checkpoint_ack, AckRef},
            {noreply, State1};
        {error, Reason, State1} ->
            stop_engine(State1),
            Outcome = {failed,
                       {durable_checkpoint_failed,
                        adk_workflow:external_reason(
                          adk_workflow_ledger, checkpoint, Reason)},
                       maps:get(checkpoint, State1)},
            {noreply, finish_local(Outcome, State1)}
    end;
handle_info({adk_workflow_event, Engine, Event},
            State = #{state := running, engine := Engine}) ->
    Runtime = maps:get(runtime, State),
    notify_event(maps:get(event_receiver, Runtime), self(), Event),
    {noreply, State#{event_count => maps:get(event_count, State) + 1}};
handle_info({adk_workflow_terminal, Engine, Result, Checkpoint},
            State = #{state := running, engine := Engine}) ->
    Outcome = normalize_engine_outcome(Result, Checkpoint),
    {noreply, finish(Outcome, State#{checkpoint => Checkpoint})};
handle_info({'DOWN', Ref, process, Engine, Reason},
            State = #{state := running,
                      engine := Engine, engine_ref := Ref}) ->
    PublicReason = {engine_process_down,
                    adk_workflow:external_reason(
                      adk_workflow_engine, process_down, Reason)},
    Outcome = {failed, PublicReason, maps:get(checkpoint, State)},
    {noreply, finish(Outcome,
                     State#{engine => undefined, engine_ref => undefined})};
handle_info({'DOWN', Ref, process, Engine, _Reason},
            State = #{engine := Engine, engine_ref := Ref}) ->
    {noreply, State#{engine => undefined, engine_ref => undefined}};
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State) ->
    Waiters = maps:get(waiters, State),
    {noreply, State#{waiters => maps:remove(Ref, Waiters)}};
handle_info(adk_workflow_deadline, State = #{state := running}) ->
    stop_engine(State),
    Outcome = {timed_out, maps:get(checkpoint, State)},
    {noreply, finish(Outcome, State)};
handle_info(adk_workflow_deadline, State) ->
    {noreply, State};
handle_info(adk_workflow_lease_renew, State = #{state := running}) ->
    case renew_lease(State) of
        {ok, State1} -> {noreply, State1};
        {error, Reason, State1} ->
            %% A failed renewal may mean another node owns a newer fencing
            %% token. Stop before accepting any more action results.
            stop_engine(State1),
            Outcome = {failed,
                       {durable_lease_lost,
                        adk_workflow:external_reason(
                          adk_workflow_ledger, renew, Reason)},
                       maps:get(checkpoint, State1)},
            {noreply, finish_local(Outcome, State1)}
    end;
handle_info(adk_workflow_lease_renew, State) ->
    {noreply, State};
handle_info(adk_workflow_expire, State = #{state := running}) ->
    {noreply, State};
handle_info(adk_workflow_expire, State) ->
    {stop, normal, State};
handle_info({'EXIT', _Pid, _Reason}, State) ->
    {noreply, State};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    cancel_timer(maps:get(deadline_timer, State, undefined)),
    cancel_timer(maps:get(lease_timer, State, undefined)),
    cancel_timer(maps:get(terminal_timer, State, undefined)),
    stop_engine(State),
    reply_waiters({failed, coordinator_stopped,
                   maps:get(checkpoint, State, #{})},
                  maps:get(waiters, State, #{})),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% Compiled closures, workflow state, checkpoints, outcomes, waiter From terms,
%% ledger handles/tokens, and in-flight messages are all application data.
%% Expose only bounded operational counters to sys/OTP diagnostics.
format_status(Status) ->
    maps:map(
      fun(state, Data) when is_map(Data) ->
              #{phase => maps:get(state, Data, unknown),
                started_at => maps:get(started_at, Data, undefined),
                finished_at => maps:get(finished_at, Data, undefined),
                engine_running => is_pid(maps:get(engine, Data, undefined)),
                durable => maps:get(durable, Data, undefined) =/= undefined,
                waiter_count => map_size(maps:get(waiters, Data, #{})),
                event_count => maps:get(event_count, Data, 0)};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, _Value) -> adk_secret_redactor:marker()
      end, Status).

public_init_error(Reason) when is_atom(Reason) -> Reason;
public_init_error(Failure = {adk_failure, Metadata}) when is_map(Metadata) ->
    Failure;
public_init_error(Reason) ->
    adk_workflow:external_reason(adk_workflow, initialize, Reason).

normalize_init(Compiled, InitialState0, Opts) when is_map(Opts) ->
    case adk_workflow:is_compiled(Compiled) of
        false -> {error, invalid_compiled_workflow};
        true ->
            case normalize_state(InitialState0) of
                {ok, InitialState} ->
                    case normalize_runtime(Compiled, Opts) of
                        {ok, Runtime0} ->
                            case maps:get(resume_checkpoint, Opts, undefined) of
                                undefined ->
                                    Checkpoint = adk_workflow:initial_checkpoint(
                                                   Compiled, InitialState,
                                                   Runtime0),
                                    {ok, InitialState, Runtime0, Checkpoint};
                                Checkpoint ->
                                    case adk_workflow:validate_checkpoint(
                                           Compiled, Checkpoint) of
                                        {ok, InitialState} ->
                                            Remaining = maps:get(
                                                <<"remaining">>, Checkpoint),
                                            Runtime = Runtime0#{
                                                steps_remaining => maps:get(
                                                    <<"steps">>, Remaining),
                                                transfers_remaining => maps:get(
                                                    <<"transfers">>, Remaining)},
                                            {ok, InitialState, Runtime, Checkpoint};
                                        {error, Reason} -> {error, Reason}
                                    end
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end
    end;
normalize_init(_Compiled, _InitialState, _Opts) ->
    {error, invalid_workflow_options}.

normalize_state(State) when is_map(State) ->
    case adk_json:normalize(State) of
        {ok, Normalized} when is_map(Normalized) -> {ok, Normalized};
        {error, Reason} ->
            {error, {invalid_initial_state,
                     adk_workflow:external_reason(
                       adk_workflow, initial_state, Reason)}}
    end;
normalize_state(_) ->
    {error, invalid_initial_state}.

prepare_durable(Compiled, InitialState, Runtime, Checkpoint, Opts) ->
    case maps:get(?DURABLE_OPT, Opts, undefined) of
        undefined ->
            {ok, InitialState, Runtime, Checkpoint, undefined};
        #{mode := Mode, invocation_id := InvocationId,
          ledger := {Module, Handle} = Ledger,
          lease_ms := LeaseMs}
          when (Mode =:= create orelse Mode =:= resume),
               is_binary(InvocationId), byte_size(InvocationId) > 0,
               is_atom(Module), is_integer(LeaseMs), LeaseMs > 0 ->
            Metadata = #{workflow_id => maps:get(id, Compiled),
                         workflow_version => maps:get(version, Compiled),
                         kind => maps:get(kind, Compiled)},
            case maybe_create_durable(Mode, Module, Handle, InvocationId,
                                      Metadata, Checkpoint) of
                ok ->
                    Token = crypto:strong_rand_bytes(32),
                    Now = erlang:system_time(millisecond),
                    case ledger_call(
                           Module, claim,
                           [Handle, InvocationId, self(), Token,
                            Now, LeaseMs]) of
                        {ok, Record} when is_map(Record) ->
                            adopt_claimed_checkpoint(
                              Compiled, InitialState, Runtime, Checkpoint,
                              Record, Opts,
                              #{invocation_id => InvocationId,
                                ledger => Ledger,
                                owner_token => Token,
                                lease_ms => LeaseMs});
                        {error, Reason} -> {error, Reason};
                        Other ->
                            {error, {invalid_ledger_reply, claim,
                                     adk_workflow:external_reason(
                                       adk_workflow_ledger, claim, Other)}}
                    end;
                {error, _} = Error -> Error
            end;
        Invalid ->
            {error, {invalid_durable_invocation_options,
                     adk_workflow:external_reason(
                       adk_workflow, durable_options, Invalid)}}
    end.

maybe_create_durable(resume, _Module, _Handle, _InvocationId,
                     _Metadata, _Checkpoint) ->
    ok;
maybe_create_durable(create, Module, Handle, InvocationId,
                     Metadata, Checkpoint) ->
    case ledger_call(Module, create,
                     [Handle, InvocationId, Metadata, Checkpoint]) of
        ok -> ok;
        {error, Reason} -> {error, Reason};
        Other ->
            {error, {invalid_ledger_reply, create,
                     adk_workflow:external_reason(
                       adk_workflow_ledger, create, Other)}}
    end.

adopt_claimed_checkpoint(Compiled, _InitialState, Runtime, _Checkpoint,
                         Record, Opts, Durable) ->
    StoredCheckpoint = maps:get(checkpoint, Record, undefined),
    case adk_workflow:validate_checkpoint(Compiled, StoredCheckpoint) of
        {ok, ClaimedState} ->
            %% Repeat resume-input preparation after the atomic claim. If a
            %% previous owner committed a newer pause between the public read
            %% and this claim, we must use that newest stored checkpoint.
            case adk_workflow:prepare_resume_checkpoint(
                   Compiled, StoredCheckpoint, Opts) of
                {ok, ClaimedCheckpoint} ->
                    Remaining = maps:get(<<"remaining">>,
                                         ClaimedCheckpoint),
                    Runtime1 = Runtime#{
                        invocation_id => maps:get(invocation_id, Durable),
                        steps_remaining => maps:get(<<"steps">>, Remaining),
                        transfers_remaining =>
                            maps:get(<<"transfers">>, Remaining)},
                    {ok, ClaimedState, Runtime1, ClaimedCheckpoint, Durable};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, {invalid_durable_checkpoint, Reason}}
    end.

normalize_runtime(Compiled, Opts) ->
    Data = maps:get(data, Compiled),
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    Deadline = maps:get(deadline, Opts, deadline_from_timeout(Timeout)),
    MaxSteps = maps:get(max_steps, Opts, maps:get(max_steps, Data)),
    MaxTransfers = maps:get(max_transfers, Opts,
                            maps:get(max_transfers, Data, 0)),
    MaxConcurrency = maps:get(max_concurrency, Opts,
                              maps:get(max_concurrency, Data, 1)),
    Retention = maps:get(retention_ms, Opts, ?DEFAULT_RETENTION_MS),
    EventReceiver = maps:get(event_receiver, Opts, undefined),
    case valid_runtime(Deadline, MaxSteps, MaxTransfers,
                       MaxConcurrency, Retention, EventReceiver) of
        true ->
            {ok, #{deadline => Deadline,
                   execution_id => workflow_execution_id(),
                   steps_remaining => MaxSteps,
                   transfers_remaining => MaxTransfers,
                   transfers_initial => MaxTransfers,
                   max_concurrency => MaxConcurrency,
                   retention_ms => Retention,
                   event_receiver => EventReceiver}};
        false -> {error, invalid_workflow_options}
    end.

workflow_execution_id() ->
    Counter = erlang:unique_integer([positive, monotonic]),
    <<"workflow-", (integer_to_binary(Counter))/binary>>.

valid_runtime(Deadline, Steps, Transfers, Concurrency, Retention, Receiver) ->
    (Deadline =:= infinity orelse is_integer(Deadline))
    andalso is_integer(Steps) andalso Steps > 0
    andalso is_integer(Transfers) andalso Transfers >= 0
    andalso is_integer(Concurrency) andalso Concurrency > 0
    andalso is_integer(Retention) andalso Retention >= 0
    andalso (Receiver =:= undefined orelse is_pid(Receiver)).

persist_checkpoint(Checkpoint, State = #{durable := undefined}) ->
    {ok, State#{checkpoint => Checkpoint}};
persist_checkpoint(Checkpoint,
                   State = #{durable := Durable}) ->
    {Module, Handle} = maps:get(ledger, Durable),
    InvocationId = maps:get(invocation_id, Durable),
    Token = maps:get(owner_token, Durable),
    LeaseMs = maps:get(lease_ms, Durable),
    Now = erlang:system_time(millisecond),
    case ledger_call(Module, checkpoint,
                     [Handle, InvocationId, Token, Checkpoint,
                      Now, LeaseMs]) of
        ok -> {ok, State#{checkpoint => Checkpoint}};
        {error, Reason} -> {error, Reason, State};
        Other ->
            {error, {invalid_ledger_reply, checkpoint,
                     adk_workflow:external_reason(
                       adk_workflow_ledger, checkpoint, Other)}, State}
    end.

persist_terminal(_Outcome, State = #{durable := undefined}) ->
    {ok, State};
persist_terminal(Outcome, State = #{durable := Durable}) ->
    {Module, Handle} = maps:get(ledger, Durable),
    InvocationId = maps:get(invocation_id, Durable),
    Token = maps:get(owner_token, Durable),
    Checkpoint = maps:get(checkpoint, State),
    Phase = outcome_state(Outcome),
    SafeOutcome = adk_workflow:terminal_outcome(
                    Phase, Outcome, Checkpoint),
    Now = erlang:system_time(millisecond),
    case ledger_call(Module, finish,
                     [Handle, InvocationId, Token, Phase, SafeOutcome,
                      Checkpoint, Now]) of
        ok -> {ok, State};
        {error, Reason} -> {error, Reason, State};
        Other ->
            {error, {invalid_ledger_reply, finish,
                     adk_workflow:external_reason(
                       adk_workflow_ledger, finish, Other)}, State}
    end.

renew_lease(State = #{durable := undefined}) ->
    {ok, State#{lease_timer => undefined}};
renew_lease(State = #{durable := Durable}) ->
    {Module, Handle} = maps:get(ledger, Durable),
    InvocationId = maps:get(invocation_id, Durable),
    Token = maps:get(owner_token, Durable),
    LeaseMs = maps:get(lease_ms, Durable),
    Now = erlang:system_time(millisecond),
    case ledger_call(Module, renew,
                     [Handle, InvocationId, Token, Now, LeaseMs]) of
        ok -> {ok, State#{lease_timer => lease_timer(Durable)}};
        {error, Reason} ->
            {error, Reason, State#{lease_timer => undefined}};
        Other ->
            {error, {invalid_ledger_reply, renew,
                     adk_workflow:external_reason(
                       adk_workflow_ledger, renew, Other)},
             State#{lease_timer => undefined}}
    end.

lease_timer(undefined) -> undefined;
lease_timer(Durable) ->
    LeaseMs = maps:get(lease_ms, Durable),
    Interval = erlang:max(1, LeaseMs div 3),
    erlang:send_after(Interval, self(), adk_workflow_lease_renew).

ledger_call(Module, Function, Args) ->
    try apply(Module, Function, Args) of
        Reply -> Reply
    catch
        Class:Reason ->
            {error, adk_workflow:exception_reason(
                      adk_workflow_ledger, Function, Class, Reason)}
    end.

deadline_from_timeout(infinity) -> infinity;
deadline_from_timeout(Timeout) when is_integer(Timeout), Timeout >= 0 ->
    erlang:monotonic_time(millisecond) + Timeout;
deadline_from_timeout(_Invalid) -> invalid.

deadline_timer(infinity) -> undefined;
deadline_timer(Deadline) ->
    Remaining = erlang:max(0,
                           Deadline - erlang:monotonic_time(millisecond)),
    erlang:send_after(Remaining, self(), adk_workflow_deadline).

normalize_engine_outcome({completed, State}, Checkpoint) ->
    {completed, State, Checkpoint};
normalize_engine_outcome({failed, Reason}, Checkpoint) ->
    {failed, adk_workflow:failure_reason(Reason), Checkpoint};
normalize_engine_outcome(timed_out, Checkpoint) ->
    {timed_out, Checkpoint};
normalize_engine_outcome({cancelled, Reason}, Checkpoint) ->
    {cancelled,
     adk_workflow:external_reason(adk_workflow, cancel, Reason), Checkpoint};
normalize_engine_outcome({paused, Details}, Checkpoint) ->
    {paused, Details, Checkpoint};
normalize_engine_outcome(_Invalid, Checkpoint) ->
    {failed, invalid_engine_outcome, Checkpoint}.

finish(Outcome, State = #{state := running}) ->
    case persist_terminal(Outcome, State) of
        {ok, State1} ->
            finish_local(Outcome, State1);
        {error, Reason, State1} ->
            LedgerFailure =
                {failed,
                 {durable_terminal_failed,
                  adk_workflow:external_reason(
                    adk_workflow_ledger, finish, Reason)},
                 maps:get(checkpoint, State1)},
            finish_local(LedgerFailure, State1)
    end.

finish_local(Outcome, State = #{state := running}) ->
    cancel_timer(maps:get(deadline_timer, State)),
    cancel_timer(maps:get(lease_timer, State, undefined)),
    reply_waiters(Outcome, maps:get(waiters, State)),
    Runtime = maps:get(runtime, State),
    TerminalTimer = erlang:send_after(maps:get(retention_ms, Runtime),
                                      self(), adk_workflow_expire),
    State#{state => outcome_state(Outcome),
           outcome => Outcome,
           finished_at => erlang:system_time(millisecond),
           waiters => #{},
           deadline_timer => undefined,
           lease_timer => undefined,
           terminal_timer => TerminalTimer}.

reply_waiters(Outcome, Waiters) ->
    maps:foreach(
      fun(Ref, From) ->
          erlang:demonitor(Ref, [flush]),
          gen_server:reply(From, Outcome)
      end, Waiters).

status_map(State) ->
    Compiled = maps:get(compiled, State),
    Runtime = maps:get(runtime, State),
    Base = #{workflow_ref => self(),
      workflow_id => maps:get(id, Compiled),
      kind => maps:get(kind, Compiled),
      state => maps:get(state, State),
      outcome => maps:get(outcome, State),
      deadline => maps:get(deadline, Runtime),
      started_at => maps:get(started_at, State),
      finished_at => maps:get(finished_at, State),
      checkpoint => maps:get(checkpoint, State),
      waiter_count => map_size(maps:get(waiters, State)),
      event_count => maps:get(event_count, State)},
    case maps:get(durable, State, undefined) of
        undefined -> Base;
        Durable -> Base#{invocation_id => maps:get(invocation_id, Durable),
                         durable => true}
    end.

outcome_state({completed, _, _}) -> completed;
outcome_state({failed, _, _}) -> failed;
outcome_state({timed_out, _}) -> timed_out;
outcome_state({cancelled, _, _}) -> cancelled;
outcome_state({paused, _, _}) -> paused.

stop_engine(State) ->
    case maps:get(engine, State, undefined) of
        Engine when is_pid(Engine) ->
            exit(Engine, kill),
            ok;
        undefined -> ok
    end.

notify_event(undefined, _Ref, _Event) -> ok;
notify_event(Receiver, Ref, Event) ->
    Receiver ! {adk_workflow_event, Ref, Event},
    ok.

cancel_timer(undefined) -> ok;
cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.
