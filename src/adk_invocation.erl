%% @doc One supervised, reconnectable ADK invocation.
%%
%% The invocation owns the legacy Runner stream, monitors it, buffers a bounded
%% replay, monitors subscribers/waiters, and commits exactly one terminal
%% outcome. It deliberately has no link or monitor to the API caller which
%% created the run.
-module(adk_invocation).
-behaviour(gen_statem).

-include("../include/adk_event.hrl").

-export([start_link/1, start_link/3, handoff/5]).
-export([init/1, callback_mode/0, handle_event/4,
         terminate/3, code_change/4, format_status/1]).

-define(DEFAULT_RETENTION_MS, 60000).
-define(DEFAULT_MAX_BUFFERED_EVENTS, 256).
-define(DEFAULT_CANCEL_GRACE_MS, 250).
-define(HANDOFF_TIMEOUT_MS, 5000).

-spec start_link(reference()) -> gen_statem:start_ret().
start_link(InvocationRef) when is_reference(InvocationRef) ->
    gen_statem:start_link(?MODULE, InvocationRef, []).

%% Compatibility entry point for direct callers. Sensitive values are still
%% transferred after init and never become proc_lib/supervisor start args.
-spec start_link(binary(), map(), map()) -> gen_statem:start_ret().
start_link(RunId, Request, Opts) ->
    InvocationRef = make_ref(),
    case start_link(InvocationRef) of
        {ok, Pid} = Started ->
            complete_direct_handoff(
              Started, Pid, InvocationRef, RunId, Request, Opts);
        Error ->
            Error
    end.

-spec handoff(pid(), reference(), binary(), map(), map()) ->
    ok | {error, term()}.
handoff(Pid, InvocationRef, RunId, Request, Opts)
  when is_pid(Pid), is_reference(InvocationRef), is_binary(RunId),
       is_map(Request), is_map(Opts) ->
    try gen_statem:call(
          Pid, {handoff, InvocationRef, RunId, Request, Opts}, 5000) of
        Reply -> Reply
    catch
        exit:_ -> {error, invocation_handoff_failed}
    end;
handoff(_Pid, _InvocationRef, _RunId, _Request, _Opts) ->
    {error, invalid_invocation_handoff}.

callback_mode() ->
    handle_event_function.

init(InvocationRef) when is_reference(InvocationRef) ->
    {ok, awaiting_handoff,
     #{invocation_ref => InvocationRef},
     [{state_timeout, ?HANDOFF_TIMEOUT_MS, handoff_timeout}]}.

accept_handoff(From, RunId, Request, Opts) ->
    case validate_init(RunId, Request, Opts) of
        {ok, Config} ->
            OwnerScope = maps:get(owner_scope, Config, undefined),
            RegistryMetadata = case OwnerScope of
                undefined -> #{};
                Scope -> #{owner_scope => Scope}
            end,
            case adk_run_registry:register(
                   RunId, self(), RegistryMetadata) of
                ok ->
                    Data = #{
                        run_id => RunId,
                        request => Request,
                        resume_context =>
                            maps:with([runner, user_id, session_id], Request),
                        started_at => erlang:system_time(millisecond),
                        finished_at => undefined,
                        outcome => undefined,
                        seq => 0,
                        event_count => 0,
                        output => undefined,
                        buffer => queue:new(),
                        max_buffered_events =>
                            maps:get(max_buffered_events, Config),
                        retention_ms => maps:get(retention_ms, Config),
                        cancel_grace_ms => maps:get(cancel_grace_ms, Config),
                        subscribers => #{},
                        subscriber_refs => #{},
                        waiters => #{},
                        worker => undefined,
                        worker_ref => undefined,
                        cancel_reason => undefined,
                        cancel_timer => undefined,
                        parent_run_id => maps:get(parent_run_id, Request,
                                                  undefined),
                        owner_scope => OwnerScope,
                        resumed_to => undefined
                    },
                    {next_state, running, Data,
                     [{reply, From, ok},
                      {next_event, internal, start_worker}]};
                {error, Reason} ->
                    Failure = adk_failure:external(
                                invocation, registry_registration, Reason),
                    {stop_and_reply, normal,
                     [{reply, From, {error, Failure}}]}
            end;
        {error, Reason} ->
            {keep_state_and_data,
             [{reply, From, {error, Reason}}]}
    end.

complete_direct_handoff(Started, Pid, InvocationRef,
                        RunId, Request, Opts) ->
    case handoff(Pid, InvocationRef, RunId, Request, Opts) of
        ok ->
            Started;
        {error, _} = Error ->
            unlink(Pid),
            exit(Pid, shutdown),
            Error
    end.

handle_event({call, From},
             {handoff, InvocationRef, RunId, Request, Opts},
             awaiting_handoff,
             #{invocation_ref := ExpectedRef}) ->
    case InvocationRef =:= ExpectedRef of
        true ->
            accept_handoff(From, RunId, Request, Opts);
        false ->
            {keep_state_and_data,
             [{reply, From, {error, invalid_invocation_handoff}}]}
    end;
handle_event({call, From}, {handoff, _InvocationRef, _RunId,
                            _Request, _Opts},
             awaiting_handoff, _Data) ->
    {keep_state_and_data,
     [{reply, From, {error, invalid_invocation_handoff}}]};
handle_event({call, From}, {handoff, _InvocationRef, _RunId,
                            _Request, _Opts},
             _State, _Data) ->
    {keep_state_and_data,
     [{reply, From, {error, handoff_already_completed}}]};

handle_event(state_timeout, handoff_timeout, awaiting_handoff, Data) ->
    %% A caller may die between start_child/2 and the one-shot handoff. Bound
    %% that race so an empty temporary process cannot remain supervised.
    {stop, normal, Data};

%% Start the Runner stream from inside this process. adk_runner:run_async/4
%% captures self() as its destination, making this invocation, rather than a
%% browser or transient API caller, the stream owner.
handle_event(internal, start_worker, running, Data0) ->
    Request = maps:get(request, Data0),
    %% The prompt/resume response is only required to launch the Runner. It is
    %% not retained for the run's replay/status lifetime.
    Data = drop_start_request(Data0),
    Runner = maps:get(runner, Request),
    UserId = maps:get(user_id, Request),
    SessionId = maps:get(session_id, Request),
    Operation = maps:get(operation, Request, run),
    try start_runner_operation(
          Operation, Request, Runner, UserId, SessionId) of
        {ok, Worker} when is_pid(Worker) ->
            Ref = erlang:monitor(process, Worker),
            {keep_state, Data#{worker => Worker, worker_ref => Ref}};
        {error, Reason} ->
            finish({failed, adk_failure:sanitize(
                              invocation, runner_operation, Reason)}, Data)
    catch
        Class:Reason ->
            finish({failed, adk_failure:exception(
                              invocation, runner_start, Class, Reason)}, Data)
    end;

handle_event({call, From}, status, _State, Data) ->
    {keep_state_and_data, [{reply, From, status_map(Data)}]};

handle_event({call, From}, {subscribe, Subscriber}, _State, Data0)
  when is_pid(Subscriber) ->
    Data1 = subscribe_process(Subscriber, Data0),
    {keep_state, Data1, [{reply, From, ok}]};

handle_event({call, From}, {subscribe_credit, Subscriber, Cursor},
             _State, Data0)
  when is_pid(Subscriber), is_integer(Cursor), Cursor >= 0 ->
    case subscribe_credit_process(Subscriber, Cursor, Data0) of
        {ok, Info, Data1} ->
            {keep_state, Data1, [{reply, From, {ok, Info}}]};
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end;

handle_event({call, From}, {ack, Subscriber, Sequence}, _State, Data0)
  when is_pid(Subscriber), is_integer(Sequence), Sequence >= 0 ->
    case acknowledge_credit(Subscriber, Sequence, Data0) of
        {ok, Data1} ->
            {keep_state, Data1, [{reply, From, ok}]};
        {error, Reason, Data1} ->
            {keep_state, Data1, [{reply, From, {error, Reason}}]}
    end;

handle_event({call, From}, {unsubscribe, Subscriber}, _State, Data0)
  when is_pid(Subscriber) ->
    Data1 = unsubscribe_process(Subscriber, Data0),
    {keep_state, Data1, [{reply, From, ok}]};

handle_event({call, From}, await, running, Data0) ->
    WaiterPid = element(1, From),
    Ref = erlang:monitor(process, WaiterPid),
    Waiters = maps:get(waiters, Data0),
    {keep_state, Data0#{waiters => Waiters#{Ref => From}}};
handle_event({call, From}, await, terminal, Data) ->
    {keep_state_and_data,
     [{reply, From, maps:get(outcome, Data)}]};

handle_event({call, From}, {cancel, _Reason}, running,
             _Data = #{cancel_reason := Existing})
  when Existing =/= undefined ->
    %% Cancellation is idempotent. The first reason is the committed reason.
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, From}, {cancel, Reason}, running,
             Data0 = #{worker := undefined}) ->
    gen_statem:reply(From, ok),
    Failure = adk_failure:external(invocation, cancel, Reason),
    Data = drop_start_request(Data0),
    finish({cancelled, Failure}, Data#{cancel_reason => Failure});
handle_event({call, From}, {cancel, Reason}, running,
             Data = #{worker := Worker,
                      worker_ref := WorkerRef,
                      cancel_grace_ms := Grace}) ->
    Failure = adk_failure:external(invocation, cancel, Reason),
    ok = adk_runner:cancel(Worker, Failure),
    Timer = erlang:send_after(
              Grace, self(), {force_cancel, Worker, WorkerRef}),
    {keep_state,
     Data#{cancel_reason => Failure, cancel_timer => Timer},
     [{reply, From, ok}]};
handle_event({call, From}, {cancel, _Reason}, terminal, _Data) ->
    {keep_state_and_data,
     [{reply, From, {error, already_terminal}}]};

handle_event({call, From},
             {resume, NewRunId, ToolResponse, Opts}, terminal,
             Data = #{outcome := {paused, PauseEvent},
                      resumed_to := undefined})
  when is_binary(NewRunId), is_map(Opts) ->
    case pause_invocation_id(PauseEvent) of
        {ok, InvocationId} ->
            Request0 = maps:get(resume_context, Data),
            ResumeRequest = Request0#{operation => resume,
                                      invocation_id => InvocationId,
                                      tool_response => ToolResponse,
                                      parent_run_id => maps:get(run_id,
                                                                Data)},
            Runner = maps:get(runner, ResumeRequest),
            UserId = maps:get(user_id, ResumeRequest),
            SessionId = maps:get(session_id, ResumeRequest),
            case adk_runner:validate_resume(
                   Runner, UserId, SessionId, InvocationId,
                   ToolResponse) of
                ok ->
                    ResumeOpts = inherit_owner_scope(Opts, Data),
                    case safe_start_resumed_invocation(
                           NewRunId, ResumeRequest, ResumeOpts) of
                        ok ->
                            {keep_state, Data#{resumed_to => NewRunId},
                             [{reply, From, {ok, NewRunId}}]};
                        {error, Reason} ->
                            {keep_state_and_data,
                             [{reply, From, {error, Reason}}]}
                    end;
                {error, Reason} ->
                    {keep_state_and_data,
                     [{reply, From, {error, Reason}}]}
            end;
        {error, Reason} ->
            {keep_state_and_data,
             [{reply, From, {error, Reason}}]}
    end;
handle_event({call, From}, {resume, _NewRunId, _ToolResponse, _Opts},
             terminal, #{outcome := {paused, _PauseEvent},
                         resumed_to := ExistingRunId})
  when ExistingRunId =/= undefined ->
    {keep_state_and_data,
     [{reply, From, {error, {already_resumed, ExistingRunId}}}]};
handle_event({call, From}, {resume, _NewRunId, _ToolResponse, _Opts},
             terminal, _Data) ->
    {keep_state_and_data,
     [{reply, From, {error, run_not_paused}}]};
handle_event({call, From}, {resume, _NewRunId, _ToolResponse, _Opts},
             running, _Data) ->
    {keep_state_and_data,
     [{reply, From, {error, run_not_paused}}]};

handle_event(info, {adk_event, Worker, Event}, running,
             Data = #{worker := Worker}) ->
    {keep_state, record_event(Event, Data)};
handle_event(info, {adk_done, Worker}, running,
             Data = #{worker := Worker, cancel_reason := undefined}) ->
    finish({completed, completed_output(Data)}, Data);
handle_event(info, {adk_done, Worker}, running,
             Data = #{worker := Worker, cancel_reason := CancelReason}) ->
    finish({cancelled, CancelReason}, Data);
handle_event(info, {adk_paused, Worker, PauseEvent}, running,
             Data = #{worker := Worker, cancel_reason := undefined}) ->
    finish({paused, PauseEvent}, Data);
handle_event(info, {adk_paused, Worker, _PauseEvent}, running,
             Data = #{worker := Worker, cancel_reason := CancelReason}) ->
    finish({cancelled, CancelReason}, Data);
handle_event(info, {adk_error, Worker, {cancelled, WorkerReason}}, running,
             Data = #{worker := Worker, cancel_reason := CancelReason}) ->
    Reason = case CancelReason of
        undefined -> adk_failure:sanitize(
                       invocation, runner_cancel, WorkerReason);
        _ -> CancelReason
    end,
    finish({cancelled, Reason}, Data);
handle_event(info, {adk_error, Worker, Reason}, running,
             Data = #{worker := Worker, cancel_reason := undefined}) ->
    finish({failed, adk_failure:sanitize(
                      invocation, runner_error, Reason)}, Data);
handle_event(info, {adk_error, Worker, _Reason}, running,
             Data = #{worker := Worker, cancel_reason := CancelReason}) ->
    finish({cancelled, CancelReason}, Data);

handle_event(info, {'DOWN', Ref, process, Worker, DownReason}, running,
             Data = #{worker := Worker, worker_ref := Ref,
                      cancel_reason := CancelReason}) ->
    Data1 = Data#{worker => undefined, worker_ref => undefined},
    case CancelReason of
        undefined when DownReason =:= normal ->
            finish({failed, stream_ended_without_terminal_message}, Data1);
        undefined ->
            finish({failed, adk_failure:external(
                              invocation, stream_process_down,
                              DownReason)}, Data1);
        _ ->
            finish({cancelled, CancelReason}, Data1)
    end;
handle_event(info, {'DOWN', Ref, process, Worker, _Reason}, terminal,
             Data = #{worker := Worker, worker_ref := Ref}) ->
    {keep_state, Data#{worker => undefined, worker_ref => undefined}};
handle_event(info, {'DOWN', Ref, process, _Pid, _Reason}, State, Data0) ->
    Data1 = remove_monitored_client(Ref, Data0),
    {next_state, State, Data1};

handle_event(info, {force_cancel, Worker, WorkerRef}, running,
             Data = #{worker := Worker, worker_ref := WorkerRef,
                      cancel_reason := CancelReason})
  when CancelReason =/= undefined ->
    exit(Worker, kill),
    finish({cancelled, CancelReason},
           Data#{cancel_timer => undefined});
handle_event(info, {force_cancel, _Worker, _WorkerRef}, _State, _Data) ->
    keep_state_and_data;

handle_event(info, {adk_event, _Worker, _Event}, terminal, _Data) ->
    keep_state_and_data;
handle_event(info, {adk_done, _Worker}, terminal, _Data) ->
    keep_state_and_data;
handle_event(info, {adk_paused, _Worker, _PauseEvent}, terminal, _Data) ->
    keep_state_and_data;
handle_event(info, {adk_error, _Worker, _Reason}, terminal, _Data) ->
    keep_state_and_data;
handle_event(info, adk_expire, terminal, Data) ->
    {stop, normal, Data};
handle_event(info, adk_expire, running, _Data) ->
    %% The registry only evicts terminal processes. Ignore a stale message
    %% rather than allowing it to terminate active work.
    keep_state_and_data;

handle_event(state_timeout, expire, terminal, Data) ->
    {stop, normal, Data};
handle_event(_Type, _Event, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, Data) ->
    cancel_timer(maps:get(cancel_timer, Data, undefined)),
    case maps:get(worker, Data, undefined) of
        Worker when is_pid(Worker) ->
            %% A supervisor shutdown or unexpected invocation crash must not
            %% orphan the Runner coordinator or its linked execution worker.
            _ = catch adk_runner:cancel(Worker, invocation_stopped),
            exit(Worker, kill),
            ok;
        undefined ->
            ok
    end.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%% Request, replay events, terminal output, and in-flight messages can contain
%% user/model data. Keep them out of sys and OTP diagnostics.
format_status(Status) ->
    maps:map(
      fun(state, Data) when is_map(Data) ->
              #{state => diagnostic_state(Data),
                started_at => maps:get(started_at, Data, undefined),
                finished_at => maps:get(finished_at, Data, undefined),
                event_count => maps:get(event_count, Data, 0),
                buffered_event_count =>
                    safe_queue_len(maps:get(buffer, Data, queue:new())),
                subscriber_count =>
                    map_size(maps:get(subscribers, Data, #{})),
                worker_running => is_pid(
                                    maps:get(worker, Data, undefined))};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, _Value) -> adk_secret_redactor:marker()
      end, Status).

diagnostic_state(Data) ->
    case maps:is_key(run_id, Data) of
        false -> awaiting_handoff;
        true -> outcome_state(maps:get(outcome, Data, undefined))
    end.

safe_queue_len(Queue) ->
    try queue:len(Queue)
    catch _:_ -> 0
    end.

validate_init(RunId, Request, Opts)
  when is_binary(RunId), is_map(Request), is_map(Opts) ->
    Required = case maps:get(operation, Request, run) of
        run -> [runner, user_id, session_id, message];
        resume -> [runner, user_id, session_id,
                   invocation_id, tool_response, parent_run_id];
        _ -> invalid
    end,
    case Required =/= invalid andalso
         lists:all(fun(Key) -> maps:is_key(Key, Request) end, Required) of
        false ->
            {error, invalid_invocation_request};
        true ->
            Retention = maps:get(
                          retention_ms, Opts,
                          application:get_env(
                            erlang_adk, run_retention_ms,
                            ?DEFAULT_RETENTION_MS)),
            MaxBuffered = maps:get(
                            max_buffered_events, Opts,
                            application:get_env(
                              erlang_adk, run_max_buffered_events,
                              ?DEFAULT_MAX_BUFFERED_EVENTS)),
            CancelGrace = maps:get(cancel_grace_ms, Opts,
                                   ?DEFAULT_CANCEL_GRACE_MS),
            OwnerScope = maps:get(owner_scope, Opts, undefined),
            validate_options(Retention, MaxBuffered, CancelGrace,
                             OwnerScope)
    end;
validate_init(_RunId, _Request, _Opts) ->
    {error, invalid_invocation_arguments}.

validate_options(Retention, MaxBuffered, CancelGrace, OwnerScope)
  when is_integer(Retention), Retention >= 0,
       is_integer(MaxBuffered), MaxBuffered >= 0,
       is_integer(CancelGrace), CancelGrace >= 0,
       (OwnerScope =:= undefined orelse
        (is_binary(OwnerScope) andalso byte_size(OwnerScope) =:= 32)) ->
    {ok, #{retention_ms => Retention,
           max_buffered_events => MaxBuffered,
           cancel_grace_ms => CancelGrace,
           owner_scope => OwnerScope}};
validate_options(_Retention, _MaxBuffered, _CancelGrace, _OwnerScope) ->
    {error, invalid_invocation_options}.

record_event(Event, Data0) ->
    Seq = maps:get(seq, Data0) + 1,
    RunId = maps:get(run_id, Data0),
    Message = {adk_run_event, RunId, Seq, Event},
    Buffer0 = maps:get(buffer, Data0),
    Max = maps:get(max_buffered_events, Data0),
    Buffer1 = trim_buffer(queue:in(Message, Buffer0), Max),
    Output1 = update_event_output(Event, maps:get(output, Data0)),
    Data1 = Data0#{seq => Seq,
                   event_count => maps:get(event_count, Data0) + 1,
                   buffer => Buffer1,
                   output => Output1},
    deliver_new_message(Message, Data1).

%% Partial events are replayable progress, not fragments of the terminal
%% outcome. Every successful invocation publishes one full final agent event;
%% that immutable snapshot is therefore the sole completed output.
update_event_output(#adk_event{author = <<"user">>}, Acc) ->
    Acc;
update_event_output(#adk_event{author = <<"tool">>}, Acc) ->
    Acc;
update_event_output(#adk_event{is_final = true, content = Content}, _Acc) ->
    Content;
update_event_output(_Event, Acc) ->
    Acc.

completed_output(#{output := undefined}) -> <<>>;
completed_output(#{output := Output}) -> Output.

drop_start_request(Data) ->
    maps:remove(request, Data).

finish(Outcome, Data0) ->
    cancel_timer(maps:get(cancel_timer, Data0)),
    Seq = maps:get(seq, Data0) + 1,
    RunId = maps:get(run_id, Data0),
    TerminalMessage = {adk_run_terminal, RunId, Seq, Outcome},
    reply_waiters(Outcome, maps:get(waiters, Data0)),
    ok = adk_run_registry:terminal(RunId, self()),
    Data1 = Data0#{seq => Seq,
                   finished_at => erlang:system_time(millisecond),
                   outcome => Outcome,
                   waiters => #{},
                   cancel_timer => undefined},
    Data2 = deliver_new_message(TerminalMessage, Data1),
    Retention = maps:get(retention_ms, Data2),
    {next_state, terminal, Data2,
     [{state_timeout, Retention, expire}]}.

subscribe_process(Subscriber, Data = #{subscribers := Subscribers}) ->
    case maps:get(Subscriber, Subscribers, undefined) of
        #{mode := push} ->
            Data;
        #{mode := credit} ->
            %% An explicit legacy subscribe call switches the caller back to
            %% the documented push protocol.
            subscribe_process(Subscriber,
                              unsubscribe_process(Subscriber, Data));
        undefined ->
            Ref = erlang:monitor(process, Subscriber),
            replay_to(Subscriber, Data),
            SubscriberRefs = maps:get(subscriber_refs, Data),
            Entry = #{ref => Ref, mode => push},
            Data#{subscribers => Subscribers#{Subscriber => Entry},
                  subscriber_refs => SubscriberRefs#{Ref => Subscriber}}
    end.

subscribe_credit_process(Subscriber, Cursor, Data0) ->
    Data1 = unsubscribe_process(Subscriber, Data0),
    case next_delivery(Cursor, Data1) of
        {error, Reason} ->
            {error, Reason};
        {caught_up, true} ->
            %% Nothing else can arrive on an immutable terminal run. Avoid
            %% retaining an idle monitored subscription merely to close HTTP.
            {ok, subscription_info(Data1), Data1};
        Delivery ->
            Ref = erlang:monitor(process, Subscriber),
            Entry0 = #{ref => Ref, mode => credit, cursor => Cursor,
                       inflight => undefined},
            Subscribers0 = maps:get(subscribers, Data1),
            SubscriberRefs0 = maps:get(subscriber_refs, Data1),
            Data2 = Data1#{
                      subscribers => Subscribers0#{Subscriber => Entry0},
                      subscriber_refs => SubscriberRefs0#{Ref => Subscriber}},
            {Entry1, _Delivered} = deliver_credit_result(
                                    Subscriber, Delivery, Entry0, Data2),
            Subscribers1 = maps:get(subscribers, Data2),
            {ok, subscription_info(Data2),
             Data2#{subscribers => Subscribers1#{Subscriber => Entry1}}}
    end.

subscription_info(Data) ->
    #{latest_sequence => maps:get(seq, Data),
      terminal => maps:get(outcome, Data) =/= undefined}.

acknowledge_credit(Subscriber, Sequence,
                   Data0 = #{subscribers := Subscribers0}) ->
    case maps:get(Subscriber, Subscribers0, undefined) of
        #{mode := credit, cursor := Sequence, inflight := undefined} ->
            %% Idempotent retry after a successful acknowledgement.
            {ok, Data0};
        #{mode := credit, inflight := Sequence} = Entry0 ->
            Entry1 = Entry0#{cursor => Sequence, inflight => undefined},
            Data1 = Data0#{subscribers =>
                              Subscribers0#{Subscriber => Entry1}},
            case next_delivery(Sequence, Data1) of
                {error, Reason} ->
                    {error, Reason, Data1};
                Delivery ->
                    {Entry2, _Delivered} = deliver_credit_result(
                                            Subscriber, Delivery, Entry1,
                                            Data1),
                    Subscribers1 = maps:get(subscribers, Data1),
                    {ok, Data1#{subscribers =>
                                   Subscribers1#{Subscriber => Entry2}}}
            end;
        #{mode := credit, inflight := Inflight, cursor := Cursor} ->
            {error, {invalid_credit_ack,
                     #{sequence => Sequence, inflight => Inflight,
                       cursor => Cursor}}, Data0};
        #{mode := push} ->
            {error, not_credit_subscriber, Data0};
        undefined ->
            {error, not_subscribed, Data0}
    end.

unsubscribe_process(Subscriber, Data = #{subscribers := Subscribers}) ->
    case maps:take(Subscriber, Subscribers) of
        {Entry, Subscribers1} ->
            Ref = maps:get(ref, Entry),
            erlang:demonitor(Ref, [flush]),
            SubscriberRefs = maps:get(subscriber_refs, Data),
            Data#{subscribers => Subscribers1,
                  subscriber_refs => maps:remove(Ref, SubscriberRefs)};
        error ->
            Data
    end.

remove_monitored_client(Ref, Data0) ->
    SubscriberRefs0 = maps:get(subscriber_refs, Data0),
    case maps:take(Ref, SubscriberRefs0) of
        {Subscriber, SubscriberRefs1} ->
            Subscribers0 = maps:get(subscribers, Data0),
            Data0#{subscriber_refs => SubscriberRefs1,
                   subscribers => maps:remove(Subscriber, Subscribers0)};
        error ->
            Waiters0 = maps:get(waiters, Data0),
            Data0#{waiters => maps:remove(Ref, Waiters0)}
    end.

replay_to(Subscriber, Data) ->
    lists:foreach(
      fun(Message) -> Subscriber ! Message end,
      queue:to_list(maps:get(buffer, Data))),
    case maps:get(outcome, Data) of
        undefined -> ok;
        Outcome ->
            Subscriber ! {adk_run_terminal,
                          maps:get(run_id, Data),
                          maps:get(seq, Data), Outcome},
            ok
    end.

deliver_new_message(Message, Data0 = #{subscribers := Subscribers0}) ->
    MessageSeq = message_sequence(Message),
    Subscribers1 = maps:map(
      fun(Pid, #{mode := push} = Entry) ->
              Pid ! Message,
              Entry;
         (Pid, #{mode := credit, inflight := undefined,
                 cursor := Cursor} = Entry) when Cursor + 1 =:= MessageSeq ->
              Pid ! Message,
              Entry#{inflight => MessageSeq};
         (Pid, #{mode := credit, inflight := undefined,
                 cursor := Cursor} = Entry) when Cursor + 1 < MessageSeq ->
              Gap = replay_gap(Cursor, Data0),
              Pid ! {adk_run_replay_gap, maps:get(run_id, Data0), Gap},
              Entry#{inflight => replay_gap};
         (_Pid, Entry) ->
              Entry
      end, Subscribers0),
    Data0#{subscribers => Subscribers1}.

deliver_credit_result(_Subscriber, {caught_up, _Terminal}, Entry, _Data) ->
    {Entry, false};
deliver_credit_result(Subscriber, {message, Message}, Entry, _Data) ->
    Seq = message_sequence(Message),
    Subscriber ! Message,
    {Entry#{inflight => Seq}, true}.

next_delivery(Cursor, Data) ->
    Latest = maps:get(seq, Data),
    case Cursor > Latest of
        true ->
            {error, {cursor_ahead,
                     #{after_sequence => Cursor,
                       latest_sequence => Latest}}};
        false when Cursor =:= Latest ->
            {caught_up, maps:get(outcome, Data) =/= undefined};
        false ->
            Messages = available_messages(Data),
            case first_after(Cursor, Messages) of
                {ok, Message} ->
                    case message_sequence(Message) of
                        Next when Next =:= Cursor + 1 -> {message, Message};
                        _ -> {error, {replay_gap, replay_gap(Cursor, Data)}}
                    end;
                none ->
                    {error, {replay_gap, replay_gap(Cursor, Data)}}
            end
    end.

available_messages(Data) ->
    Events = queue:to_list(maps:get(buffer, Data)),
    case maps:get(outcome, Data) of
        undefined -> Events;
        Outcome ->
            Events ++ [{adk_run_terminal, maps:get(run_id, Data),
                        maps:get(seq, Data), Outcome}]
    end.

first_after(_Cursor, []) -> none;
first_after(Cursor, [Message | Rest]) ->
    case message_sequence(Message) > Cursor of
        true -> {ok, Message};
        false -> first_after(Cursor, Rest)
    end.

message_sequence({adk_run_event, _RunId, Seq, _Event}) -> Seq;
message_sequence({adk_run_terminal, _RunId, Seq, _Outcome}) -> Seq.

replay_gap(Cursor, Data) ->
    Available = available_messages(Data),
    Oldest = case Available of
        [] -> undefined;
        [First | _] -> message_sequence(First)
    end,
    #{after_sequence => Cursor,
      oldest_available_sequence => Oldest,
      latest_sequence => maps:get(seq, Data),
      terminal => maps:get(outcome, Data) =/= undefined}.

reply_waiters(Outcome, Waiters) ->
    maps:foreach(
      fun(Ref, From) ->
          erlang:demonitor(Ref, [flush]),
          gen_statem:reply(From, Outcome)
      end, Waiters).

trim_buffer(_Queue, 0) ->
    queue:new();
trim_buffer(Queue, Max) ->
    case queue:len(Queue) =< Max of
        true -> Queue;
        false ->
            {{value, _Dropped}, Queue1} = queue:out(Queue),
            trim_buffer(Queue1, Max)
    end.

status_map(Data) ->
    Outcome = maps:get(outcome, Data),
    #{run_id => maps:get(run_id, Data),
      state => outcome_state(Outcome),
      outcome => Outcome,
      started_at => maps:get(started_at, Data),
      finished_at => maps:get(finished_at, Data),
      event_count => maps:get(event_count, Data),
      buffered_event_count => queue:len(maps:get(buffer, Data)),
      subscriber_count => map_size(maps:get(subscribers, Data)),
      parent_run_id => maps:get(parent_run_id, Data),
      resumed_to => maps:get(resumed_to, Data)}.

start_runner_operation(run, Request, Runner, UserId, SessionId) ->
    adk_runner:run_async(
      Runner, UserId, SessionId, maps:get(message, Request));
start_runner_operation(resume, Request, Runner, UserId, SessionId) ->
    adk_runner:resume(
      Runner, UserId, SessionId,
      maps:get(invocation_id, Request),
      maps:get(tool_response, Request)).

pause_invocation_id(#adk_event{invocation_id = InvocationId})
  when is_binary(InvocationId), byte_size(InvocationId) > 0 ->
    {ok, InvocationId};
pause_invocation_id(_PauseEvent) ->
    {error, invalid_pause_event}.

safe_start_resumed_invocation(NewRunId, Request, Opts) ->
    try adk_invocation_sup:start_invocation(NewRunId, Request, Opts) of
        {ok, Pid} when is_pid(Pid) -> ok;
        {ok, Pid, _Info} when is_pid(Pid) -> ok;
        {error, Reason} ->
            {error, adk_failure:external(
                      invocation, resume_start, Reason)};
        Other ->
            {error, adk_failure:external(
                      invocation, invalid_resume_start, Other)}
    catch
        exit:{noproc, _} -> {error, invocation_supervisor_not_started};
        Class:Reason ->
            {error, adk_failure:exception(
                      invocation, resume_start, Class, Reason)}
    end.

outcome_state(undefined) -> running;
outcome_state({completed, _}) -> completed;
outcome_state({paused, _}) -> paused;
outcome_state({cancelled, _}) -> cancelled;
outcome_state({failed, _}) -> failed.

cancel_timer(undefined) ->
    ok;
cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

inherit_owner_scope(Opts, #{owner_scope := undefined}) ->
    maps:remove(owner_scope, Opts);
inherit_owner_scope(Opts, #{owner_scope := OwnerScope}) ->
    Opts#{owner_scope => OwnerScope}.
