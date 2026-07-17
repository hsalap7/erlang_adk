%% @doc Bounded OTP-native runtime for ambient/background invocations.
%%
%% Triggers are registered with an immutable Runner and an explicit session
%% policy. submit/2 performs synchronous admission into a bounded queue, then
%% returns a stable event reference while a lightweight supervised job owns the
%% invocation, retry policy, deadline, and cleanup. Repeated idempotency keys
%% return the original reference for as long as its result is retained.
-module(adk_ambient).
-behaviour(gen_server).

-export([start_link/0, start_link/1, child_spec/1,
         register_trigger/3, unregister_trigger/1,
         submit/2, run/2, run/3,
         status/1, await/1, await/2,
         cancel/1, cancel/2,
         trigger_status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_MAX_TRIGGERS, 64).
-define(DEFAULT_MAX_EVENTS, 10000).
-define(DEFAULT_MAX_CONCURRENCY, 8).
-define(DEFAULT_MAX_QUEUE, 256).
-define(DEFAULT_EVENT_TIMEOUT, 120000).
-define(DEFAULT_RETENTION_MS, 300000).
-define(DEFAULT_MAX_RETAINED, 1000).
-define(DEFAULT_MAX_WAITERS, 64).
-define(DEFAULT_MAX_EVENT_BYTES, 1048576).
-define(MAX_CONCURRENCY, 1024).
-define(MAX_QUEUE, 10000).
-define(MAX_RETAINED, 10000).
-define(MAX_WAITERS, 1024).

-type event_ref() :: binary().
-type outcome() ::
    {completed, map()}
    | {paused, map()}
    | {failed, term()}
    | {timed_out, deadline_exceeded}
    | {cancelled, term()}.
-export_type([event_ref/0, outcome/0]).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(application:get_env(erlang_adk, ambient_runtime, #{})).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Options) when is_map(Options) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Options, []).

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Options) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, [Options]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec register_trigger(binary(), adk_runner:runner(), map()) ->
    ok | {error, term()}.
register_trigger(Name, Runner, Options) ->
    safe_call({register_trigger, Name, Runner, Options}).

-spec unregister_trigger(binary()) -> ok | {error, term()}.
unregister_trigger(Name) ->
    safe_call({unregister_trigger, Name}).

-spec submit(binary(), map()) ->
    {ok, event_ref()} | {ok, event_ref(), duplicate} | {error, term()}.
submit(Name, Event) ->
    safe_call({submit, Name, Event}).

-spec run(binary(), map()) -> outcome() | {error, term()}.
run(Name, Event) ->
    run(Name, Event, infinity).

-spec run(binary(), map(), timeout()) -> outcome() | {error, term()}.
run(Name, Event, Timeout) ->
    case submit(Name, Event) of
        {ok, Ref} -> await(Ref, Timeout);
        {ok, Ref, duplicate} -> await(Ref, Timeout);
        {error, _} = Error -> Error
    end.

-spec status(event_ref()) -> {ok, map()} | {error, term()}.
status(EventRef) ->
    safe_call({status, EventRef}).

-spec await(event_ref()) -> outcome() | {error, term()}.
await(EventRef) ->
    await(EventRef, infinity).

-spec await(event_ref(), timeout()) -> outcome() | {error, term()}.
await(EventRef, Timeout)
  when Timeout =:= infinity;
       is_integer(Timeout), Timeout >= 0 ->
    WaitRef = make_ref(),
    case safe_call({subscribe, EventRef, WaitRef, self()}) of
        {terminal, Outcome} ->
            Outcome;
        ok ->
            receive
                {adk_ambient_terminal, WaitRef, EventRef, Outcome} ->
                    Outcome
            after Timeout ->
                _ = safe_call({unsubscribe, EventRef, WaitRef}),
                flush_waiter_message(WaitRef, EventRef),
                {error, timeout}
            end;
        {error, _} = Error ->
            Error
    end;
await(_EventRef, Timeout) ->
    {error, {invalid_await_timeout, Timeout}}.

-spec cancel(event_ref()) -> ok | {error, term()}.
cancel(EventRef) ->
    cancel(EventRef, user_cancelled).

-spec cancel(event_ref(), term()) -> ok | {error, term()}.
cancel(EventRef, Reason) ->
    safe_call({cancel, EventRef, Reason}).

-spec trigger_status(binary()) -> {ok, map()} | {error, term()}.
trigger_status(Name) ->
    safe_call({trigger_status, Name}).

init(Options) ->
    MaxTriggers = maps:get(max_triggers, Options, ?DEFAULT_MAX_TRIGGERS),
    MaxEvents = maps:get(max_events, Options, ?DEFAULT_MAX_EVENTS),
    case map_size(maps:without([max_triggers, max_events], Options)) =:= 0 andalso
         is_integer(MaxTriggers) andalso MaxTriggers > 0 andalso
         MaxTriggers =< 1024 andalso is_integer(MaxEvents) andalso
         MaxEvents > 0 andalso MaxEvents =< 100000 of
        true ->
            {ok, #{max_triggers => MaxTriggers,
                   max_events => MaxEvents,
                   triggers => #{},
                   jobs => #{},
                   dedupe => #{},
                   job_monitors => #{},
                   waiter_monitors => #{},
                   queue_timer => undefined}};
        false ->
            {stop, invalid_ambient_runtime_options}
    end.

handle_call({register_trigger, Name, Runner, Options}, _From, State0) ->
    State = purge_retained(State0),
    case normalize_trigger(Name, Runner, Options) of
        {ok, Config} ->
            Triggers = maps:get(triggers, State),
            MaxTriggers = maps:get(max_triggers, State),
            case maps:is_key(Name, Triggers) of
                true ->
                    {reply, {error, already_registered}, State};
                false when map_size(Triggers) >= MaxTriggers ->
                    {reply, {error, trigger_limit_reached}, State};
                false ->
                    Route = #{runner => Runner,
                              config => Config,
                              queue => queue:new(),
                              queued => 0,
                              active => 0,
                              terminal => queue:new()},
                    {reply, ok,
                     State#{triggers => Triggers#{Name => Route}}}
            end;
        {error, _} = Error ->
            {reply, Error, State}
    end;

handle_call({unregister_trigger, Name}, _From, State0) ->
    State = purge_retained(State0),
    case maps:find(Name, maps:get(triggers, State)) of
        error ->
            {reply, {error, not_found}, State};
        {ok, #{active := Active, queued := Queued}}
          when Active > 0; Queued > 0 ->
            {reply, {error, trigger_busy}, State};
        {ok, _Route} ->
            State1 = evict_trigger_jobs(Name, State),
            Triggers = maps:remove(Name, maps:get(triggers, State1)),
            {reply, ok, State1#{triggers => Triggers}}
    end;

handle_call({submit, Name, Event}, _From, State0) ->
    State1 = purge_retained(State0),
    case maps:find(Name, maps:get(triggers, State1)) of
        error ->
            {reply, {error, trigger_not_found}, State1};
        {ok, Route} ->
            case normalize_event(Name, Event, maps:get(config, Route)) of
                {ok, Job0} ->
                    DedupeKey = {Name, maps:get(idempotency_key, Job0)},
                    case maps:find(DedupeKey, maps:get(dedupe, State1)) of
                        {ok, ExistingRef} ->
                            case maps:is_key(ExistingRef,
                                             maps:get(jobs, State1)) of
                                true ->
                                    {reply, {ok, ExistingRef, duplicate}, State1};
                                false ->
                                    accept_new_job(Name, Route, Job0,
                                                   DedupeKey, State1)
                            end;
                        error ->
                            accept_new_job(Name, Route, Job0,
                                           DedupeKey, State1)
                    end;
                {error, _} = Error ->
                    {reply, Error, State1}
            end
    end;

handle_call({status, EventRef}, _From, State0) ->
    State = purge_retained(State0),
    case maps:find(EventRef, maps:get(jobs, State)) of
        {ok, Job} -> {reply, {ok, public_job(Job)}, State};
        error -> {reply, {error, not_found}, State}
    end;

handle_call({trigger_status, Name}, _From, State0) ->
    State = purge_retained(State0),
    case maps:find(Name, maps:get(triggers, State)) of
        {ok, Route} ->
            Config = maps:get(config, Route),
            {reply, {ok, #{name => Name,
                           active => maps:get(active, Route),
                           queued => maps:get(queued, Route),
                           retained => queue:len(maps:get(terminal, Route)),
                           max_concurrency => maps:get(max_concurrency, Config),
                           max_queue => maps:get(max_queue, Config),
                           session_policy => public_session_policy(
                                               maps:get(session_policy,
                                                        Config))}}, State};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call({subscribe, EventRef, WaitRef, Subscriber}, _From, State0)
  when is_reference(WaitRef), is_pid(Subscriber) ->
    State = purge_retained(State0),
    case maps:find(EventRef, maps:get(jobs, State)) of
        error ->
            {reply, {error, not_found}, State};
        {ok, #{outcome := Outcome}} when Outcome =/= undefined ->
            {reply, {terminal, Outcome}, State};
        {ok, Job} ->
            Config = route_config(maps:get(trigger, Job), State),
            Waiters = maps:get(waiters, Job),
            case map_size(Waiters) >= maps:get(max_waiters, Config) of
                true ->
                    {reply, {error, waiter_limit_reached}, State};
                false ->
                    Monitor = erlang:monitor(process, Subscriber),
                    Waiter = #{pid => Subscriber, monitor => Monitor},
                    Job1 = Job#{waiters => Waiters#{WaitRef => Waiter}},
                    Jobs = maps:get(jobs, State),
                    WaiterMonitors = maps:get(waiter_monitors, State),
                    State1 = State#{jobs => Jobs#{EventRef => Job1},
                                    waiter_monitors =>
                                        WaiterMonitors#{Monitor =>
                                                            {EventRef,
                                                             WaitRef}}},
                    {reply, ok, State1}
            end
    end;

handle_call({unsubscribe, EventRef, WaitRef}, _From, State) ->
    {reply, ok, remove_waiter(EventRef, WaitRef, State)};

handle_call({cancel, EventRef, Reason}, _From, State0) ->
    State = purge_retained(State0),
    case maps:find(EventRef, maps:get(jobs, State)) of
        error ->
            {reply, {error, not_found}, State};
        {ok, #{state := terminal}} ->
            {reply, {error, already_terminal}, State};
        {ok, #{state := queued}} ->
            State1 = complete_job(EventRef, {cancelled, Reason}, 0,
                                  undefined, State),
            {reply, ok, reschedule_queue_timer(State1)};
        {ok, #{state := cancelling}} ->
            {reply, ok, State};
        {ok, Job = #{state := running, worker := Worker}} ->
            ok = adk_ambient_job:cancel(Worker, Reason),
            Job1 = Job#{state => cancelling, cancel_reason => Reason},
            Jobs = maps:get(jobs, State),
            {reply, ok, State#{jobs => Jobs#{EventRef => Job1}}}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({adk_ambient_job, EventRef, Worker, {attempt, Attempt}},
            State0) ->
    {noreply, update_running_job(EventRef, Worker,
                                 fun(Job) -> Job#{attempts => Attempt} end,
                                 State0)};
handle_info({adk_ambient_job, EventRef, Worker,
             {run_started, Attempt, RunId}}, State0) ->
    {noreply, update_running_job(
                EventRef, Worker,
                fun(Job) -> Job#{attempts => Attempt, run_id => RunId} end,
                State0)};
handle_info({adk_ambient_job, EventRef, Worker,
             {terminal, Outcome, Attempts, RunId}}, State0) ->
    case matching_worker(EventRef, Worker, State0) of
        true ->
            State1 = complete_job(EventRef, Outcome, Attempts, RunId, State0),
            {noreply, reschedule_queue_timer(State1)};
        false ->
            {noreply, State0}
    end;

handle_info({'DOWN', Monitor, process, Worker, Reason}, State0) ->
    case maps:take(Monitor, maps:get(job_monitors, State0)) of
        {EventRef, JobMonitors} ->
            State1 = State0#{job_monitors => JobMonitors},
            case maps:find(EventRef, maps:get(jobs, State1)) of
                {ok, #{worker := Worker, state := cancelling,
                       cancel_reason := CancelReason}} ->
                    State2 = complete_job(EventRef,
                                          {cancelled, CancelReason},
                                          0, undefined, State1),
                    {noreply, reschedule_queue_timer(State2)};
                {ok, #{worker := Worker, state := running}} ->
                    State2 = complete_job(
                               EventRef, {failed, {job_process_down, Reason}},
                               0, undefined, State1),
                    {noreply, reschedule_queue_timer(State2)};
                _ ->
                    {noreply, State1}
            end;
        error ->
            case maps:take(Monitor, maps:get(waiter_monitors, State0)) of
                {{EventRef, WaitRef}, WaiterMonitors} ->
                    State1 = State0#{waiter_monitors => WaiterMonitors},
                    {noreply, remove_waiter_without_demonitor(
                                EventRef, WaitRef, State1)};
                error ->
                    {noreply, State0}
            end
    end;

handle_info({timeout, Timer, ambient_queue_deadline},
            State = #{queue_timer := Timer}) ->
    State1 = State#{queue_timer => undefined},
    State2 = expire_queued(State1),
    {noreply, reschedule_queue_timer(State2)};
handle_info({timeout, _Timer, ambient_queue_deadline}, State) ->
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    cancel_queue_timer(maps:get(queue_timer, State, undefined)),
    maps:foreach(
      fun(_Ref, Job) ->
          case maps:get(worker, Job, undefined) of
              Pid when is_pid(Pid) ->
                  adk_ambient_job:cancel(Pid, ambient_runtime_stopped);
              undefined -> ok
          end
      end, maps:get(jobs, State, #{})),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% Trigger and event validation

normalize_trigger(Name, Runner, Options)
  when is_binary(Name), byte_size(Name) > 0, byte_size(Name) =< 256,
       is_map(Options) ->
    Known = [max_concurrency, max_queue, event_timeout,
             retention_ms, max_retained, max_waiters,
             max_event_bytes, retry, session_policy, admission_id,
             run_options],
    MaxConcurrency = maps:get(max_concurrency, Options,
                              ?DEFAULT_MAX_CONCURRENCY),
    MaxQueue = maps:get(max_queue, Options, ?DEFAULT_MAX_QUEUE),
    EventTimeout = maps:get(event_timeout, Options,
                            ?DEFAULT_EVENT_TIMEOUT),
    Retention = maps:get(retention_ms, Options, ?DEFAULT_RETENTION_MS),
    MaxRetained = maps:get(max_retained, Options, ?DEFAULT_MAX_RETAINED),
    MaxWaiters = maps:get(max_waiters, Options, ?DEFAULT_MAX_WAITERS),
    MaxEventBytes = maps:get(max_event_bytes, Options,
                             ?DEFAULT_MAX_EVENT_BYTES),
    Retry0 = maps:get(retry, Options, #{}),
    Session0 = maps:get(session_policy, Options, undefined),
    AdmissionId = maps:get(admission_id, Options, Name),
    RunOptions = maps:get(run_options, Options, #{}),
    case {adk_runner:is_runner(Runner),
          map_size(maps:without(Known, Options)) =:= 0,
          valid_range(MaxConcurrency, 1, ?MAX_CONCURRENCY),
          valid_range(MaxQueue, 0, ?MAX_QUEUE),
          valid_timeout(EventTimeout),
          valid_range(Retention, 1000, 86400000),
          valid_range(MaxRetained, 1, ?MAX_RETAINED),
          valid_range(MaxWaiters, 1, ?MAX_WAITERS),
          valid_range(MaxEventBytes, 1024, 16777216),
          normalize_retry(Retry0),
          normalize_session_policy(Session0),
          valid_binary_id(AdmissionId),
          is_map(RunOptions)} of
        {true, true, true, true, true, true, true, true, true,
         {ok, Retry}, {ok, Session}, true, true} ->
            {ok, #{max_concurrency => MaxConcurrency,
                   max_queue => MaxQueue,
                   event_timeout => EventTimeout,
                   retention_ms => Retention,
                   max_retained => MaxRetained,
                   max_waiters => MaxWaiters,
                   max_event_bytes => MaxEventBytes,
                   retry => Retry,
                   session_policy => Session,
                   admission_id => AdmissionId,
                   run_options => RunOptions}};
        _ ->
            {error, invalid_trigger_options}
    end;
normalize_trigger(_Name, _Runner, _Options) ->
    {error, invalid_trigger_options}.

normalize_retry(Retry) when is_map(Retry) ->
    Known = [max_attempts, initial_delay, max_delay, backoff_factor,
             attempt_timeout, max_heap_words, jitter],
    Attempts = maps:get(max_attempts, Retry, 3),
    Initial = maps:get(initial_delay, Retry, 250),
    MaxDelay = maps:get(max_delay, Retry, 5000),
    Factor = maps:get(backoff_factor, Retry, 2.0),
    AttemptTimeout = maps:get(attempt_timeout, Retry, 30000),
    Heap = maps:get(max_heap_words, Retry, 1000000),
    Jitter = maps:get(jitter, Retry, full),
    case map_size(maps:without(Known, Retry)) =:= 0 andalso
         valid_range(Attempts, 1, 1000) andalso
         valid_range(Initial, 0, 86400000) andalso
         valid_range(MaxDelay, Initial, 86400000) andalso
         is_number(Factor) andalso Factor >= 1.0 andalso Factor =< 100.0 andalso
         valid_timeout(AttemptTimeout) andalso valid_heap(Heap) andalso
         (Jitter =:= none orelse Jitter =:= full) of
        true ->
            {ok, #{max_attempts => Attempts,
                   initial_delay => Initial,
                   max_delay => MaxDelay,
                   backoff_factor => Factor,
                   attempt_timeout => AttemptTimeout,
                   max_heap_words => Heap,
                   jitter => Jitter}};
        false ->
            {error, invalid_retry_options}
    end;
normalize_retry(_) ->
    {error, invalid_retry_options}.

normalize_session_policy(#{mode := per_event, user_id := UserId} = Policy)
  when is_binary(UserId), byte_size(UserId) > 0 ->
    Prefix = maps:get(prefix, Policy, <<"ambient-">>),
    case map_size(maps:without([mode, user_id, prefix], Policy)) =:= 0 andalso
         is_binary(Prefix) andalso byte_size(Prefix) =< 128 of
        true -> {ok, #{mode => per_event, user_id => UserId,
                       prefix => Prefix}};
        false -> {error, invalid_session_policy}
    end;
normalize_session_policy(#{mode := explicit} = Policy) ->
    case map_size(maps:without([mode], Policy)) =:= 0 of
        true -> {ok, #{mode => explicit}};
        false -> {error, invalid_session_policy}
    end;
normalize_session_policy(#{mode := shared, user_id := UserId,
                           session_id := SessionId} = Policy)
  when is_binary(UserId), byte_size(UserId) > 0,
       is_binary(SessionId), byte_size(SessionId) > 0 ->
    case map_size(maps:without([mode, user_id, session_id], Policy)) =:= 0 of
        true -> {ok, Policy};
        false -> {error, invalid_session_policy}
    end;
normalize_session_policy(_) ->
    {error, invalid_session_policy}.

normalize_event(Name, Event, Config) when is_map(Event) ->
    Known = [payload, idempotency_key, session, timeout_ms, metadata],
    Key = maps:get(idempotency_key, Event, undefined),
    Timeout = maps:get(timeout_ms, Event, maps:get(event_timeout, Config)),
    Metadata = maps:get(metadata, Event, #{}),
    MaxEventBytes = maps:get(max_event_bytes, Config),
    PublicValues = normalize_event_values(Event, Metadata),
    case {maps:is_key(payload, Event),
          map_size(maps:without(Known, Event)) =:= 0,
          valid_binary_id(Key),
          valid_event_timeout(Timeout, maps:get(event_timeout, Config)),
          is_map(Metadata),
          resolve_session(maps:get(session_policy, Config), Event, Key),
          PublicValues} of
        {true, true, true, true, true,
         {ok, UserId, SessionId},
         {ok, Payload, SafeMetadata, SafeEvent}}
          when byte_size(SafeEvent) =< MaxEventBytes ->
            Ref = generate_ref(),
            Now = erlang:system_time(millisecond),
            {ok, #{event_ref => Ref,
                   trigger => Name,
                   idempotency_key => Key,
                   payload => Payload,
                   metadata => SafeMetadata,
                   user_id => UserId,
                   session_id => SessionId,
                   deadline => deadline_after(Timeout),
                   created_at => Now,
                   started_at => undefined,
                   finished_at => undefined,
                   state => queued,
                   outcome => undefined,
                   attempts => 0,
                   run_id => undefined,
                   worker => undefined,
                   worker_monitor => undefined,
                   cancel_reason => undefined,
                   waiters => #{}}};
        _ ->
            {error, invalid_ambient_event}
    end;
normalize_event(_Name, _Event, _Config) ->
    {error, invalid_ambient_event}.

normalize_event_values(Event, Metadata) when is_map(Metadata) ->
    case adk_secret_redactor:redact(Event) =:= Event of
        false -> {error, secret_in_ambient_event};
        true ->
            case {normalize_ambient_payload(
                    maps:get(payload, Event, undefined)),
                  adk_json:normalize(Metadata)} of
                {{ok, Payload}, {ok, SafeMetadata}}
                  when is_map(SafeMetadata) ->
                    Canonical = #{payload => Payload,
                                  metadata => SafeMetadata,
                                  idempotency_key =>
                                      maps:get(idempotency_key, Event,
                                               undefined),
                                  session => maps:get(session, Event, null),
                                  timeout_ms => maps:get(timeout_ms, Event,
                                                         null)},
                    {ok, Payload, SafeMetadata,
                     term_to_binary(Canonical)};
                _ -> {error, non_json_ambient_event}
            end
    end;
normalize_event_values(_Event, _Metadata) ->
    {error, invalid_ambient_metadata}.

normalize_ambient_payload(Payload) when is_binary(Payload),
                                        byte_size(Payload) > 0 ->
    try unicode:characters_to_binary(Payload, utf8, utf8) of
        Payload -> {ok, Payload};
        _ -> {error, invalid_ambient_text}
    catch
        _:_ -> {error, invalid_ambient_text}
    end;
normalize_ambient_payload(Payload) when is_map(Payload) ->
    adk_content:validate(Payload, adk_content:safety_limits());
normalize_ambient_payload(_Payload) ->
    {error, invalid_ambient_payload}.

resolve_session(#{mode := per_event, user_id := UserId,
                  prefix := Prefix}, Event, Key) ->
    case maps:is_key(session, Event) of
        false ->
            Digest = binary:encode_hex(crypto:hash(sha256, Key), lowercase),
            {ok, UserId, <<Prefix/binary, Digest/binary>>};
        true ->
            {error, session_not_allowed_by_policy}
    end;
resolve_session(#{mode := explicit}, Event, _Key) ->
    case maps:get(session, Event, undefined) of
        Session = #{user_id := UserId, session_id := SessionId}
          when is_binary(UserId), byte_size(UserId) > 0,
               is_binary(SessionId), byte_size(SessionId) > 0,
               map_size(Session) =:= 2 ->
            {ok, UserId, SessionId};
        _ ->
            {error, invalid_explicit_session}
    end;
resolve_session(#{mode := shared, user_id := UserId,
                  session_id := SessionId}, Event, _Key) ->
    case maps:is_key(session, Event) of
        false -> {ok, UserId, SessionId};
        true -> {error, session_not_allowed_by_policy}
    end.

%% Queue and job lifecycle

accept_new_job(Name, Route, Job, DedupeKey, State) ->
    Config = maps:get(config, Route),
    Active = maps:get(active, Route),
    MaxConcurrency = maps:get(max_concurrency, Config),
    MaxQueue = maps:get(max_queue, Config),
    Queued = maps:get(queued, Route),
    AtGlobalLimit = map_size(maps:get(jobs, State)) >=
        maps:get(max_events, State),
    case {AtGlobalLimit,
          Active < MaxConcurrency orelse Queued < MaxQueue} of
        {true, _} ->
            {reply, {error, ambient_capacity_reached}, State};
        {false, false} ->
            {reply, {error, ambient_queue_full}, State};
        {false, true} ->
            Ref = maps:get(event_ref, Job),
            Jobs = maps:get(jobs, State),
            Dedupe = maps:get(dedupe, State),
            State1 = State#{jobs => Jobs#{Ref => Job},
                            dedupe => Dedupe#{DedupeKey => Ref}},
            State2 = case Active < MaxConcurrency of
                true -> start_job(Ref, State1);
                false -> enqueue_job(Name, Ref, State1)
            end,
            emit(submitted, Job),
            {reply, {ok, Ref}, reschedule_queue_timer(State2)}
    end.

enqueue_job(Name, Ref, State) ->
    Route = maps:get(Name, maps:get(triggers, State)),
    Queue = queue:in(Ref, maps:get(queue, Route)),
    Route1 = Route#{queue => Queue, queued => maps:get(queued, Route) + 1},
    put_route(Name, Route1, State).

start_job(Ref, State0) ->
    Job = maps:get(Ref, maps:get(jobs, State0)),
    case deadline_expired(maps:get(deadline, Job)) of
        true ->
            complete_job(Ref, {timed_out, deadline_exceeded}, 0,
                         undefined, State0);
        false ->
            Name = maps:get(trigger, Job),
            Route = maps:get(Name, maps:get(triggers, State0)),
            Config = maps:get(config, Route),
            Spec = #{manager => self(),
                     runner => maps:get(runner, Route),
                     payload => maps:get(payload, Job),
                     user_id => maps:get(user_id, Job),
                     session_id => maps:get(session_id, Job),
                     deadline => maps:get(deadline, Job),
                     retry => maps:get(retry, Config),
                     admission_id => maps:get(admission_id, Config),
                     run_options => maps:get(run_options, Config)},
            case adk_ambient_job_sup:start_job(Ref, Spec) of
                {ok, Pid} ->
                    monitor_started_job(Name, Ref, Pid, Route, Job, State0);
                {ok, Pid, _Info} ->
                    monitor_started_job(Name, Ref, Pid, Route, Job, State0);
                {error, Reason} ->
                    complete_job(Ref, {failed, {job_start_failed, Reason}},
                                 0, undefined, State0)
            end
    end.

monitor_started_job(Name, Ref, Pid, Route, Job, State) ->
    Monitor = erlang:monitor(process, Pid),
    Route1 = Route#{active => maps:get(active, Route) + 1},
    Job1 = Job#{state => running,
                started_at => erlang:system_time(millisecond),
                worker => Pid,
                worker_monitor => Monitor},
    Jobs = maps:get(jobs, State),
    JobMonitors = maps:get(job_monitors, State),
    put_route(Name, Route1,
              State#{jobs => Jobs#{Ref => Job1},
                     job_monitors => JobMonitors#{Monitor => Ref}}).

complete_job(Ref, Outcome, Attempts0, RunId0, State0) ->
    case maps:find(Ref, maps:get(jobs, State0)) of
        error -> State0;
        {ok, #{state := terminal}} -> State0;
        {ok, Job0} ->
            Name = maps:get(trigger, Job0),
            {Route1, State1} = release_job_slot(Job0, Name, Ref, State0),
            Attempts = case Attempts0 of
                0 -> maps:get(attempts, Job0, 0);
                _ -> Attempts0
            end,
            RunId = case RunId0 of
                undefined -> maps:get(run_id, Job0, undefined);
                _ -> RunId0
            end,
            notify_waiters(Ref, Outcome, maps:get(waiters, Job0)),
            State2 = remove_all_waiters(Ref, Job0, State1),
            Job1 = Job0#{state => terminal,
                         outcome => Outcome,
                         attempts => Attempts,
                         run_id => RunId,
                         worker => undefined,
                         worker_monitor => undefined,
                         finished_at => erlang:system_time(millisecond),
                         waiters => #{}},
            Terminal = queue:in(Ref, maps:get(terminal, Route1)),
            Route2 = Route1#{terminal => Terminal},
            Jobs = maps:get(jobs, State2),
            State3 = put_route(Name, Route2,
                               State2#{jobs => Jobs#{Ref => Job1}}),
            emit(terminal, Job1),
            State4 = enforce_retention(Name, State3),
            dispatch_trigger(Name, State4)
    end.

release_job_slot(Job, Name, Ref, State0) ->
    Route = maps:get(Name, maps:get(triggers, State0)),
    case maps:get(state, Job) of
        queued ->
            Queue = queue:from_list(
                      [Item || Item <- queue:to_list(maps:get(queue, Route)),
                               Item =/= Ref]),
            {Route#{queue => Queue,
                    queued => erlang:max(0, maps:get(queued, Route) - 1)},
             State0};
        running ->
            release_running(Route, Job, State0);
        cancelling ->
            release_running(Route, Job, State0)
    end.

release_running(Route, Job, State) ->
    case maps:get(worker_monitor, Job, undefined) of
        Ref when is_reference(Ref) ->
            erlang:demonitor(Ref, [flush]),
            JobMonitors = maps:remove(Ref, maps:get(job_monitors, State)),
            {Route#{active => erlang:max(0, maps:get(active, Route) - 1)},
             State#{job_monitors => JobMonitors}};
        undefined ->
            {Route#{active => erlang:max(0, maps:get(active, Route) - 1)},
             State}
    end.

dispatch_trigger(Name, State) ->
    case maps:find(Name, maps:get(triggers, State)) of
        error -> State;
        {ok, Route} ->
            Config = maps:get(config, Route),
            case maps:get(active, Route) < maps:get(max_concurrency, Config)
                 andalso maps:get(queued, Route) > 0 of
                false -> State;
                true ->
                    {{value, Ref}, Queue} = queue:out(maps:get(queue, Route)),
                    Route1 = Route#{queue => Queue,
                                    queued => maps:get(queued, Route) - 1},
                    State1 = put_route(Name, Route1, State),
                    dispatch_trigger(Name, start_job(Ref, State1))
            end
    end.

update_running_job(EventRef, Worker, Fun, State) ->
    case maps:find(EventRef, maps:get(jobs, State)) of
        {ok, Job = #{worker := Worker, state := JobState}}
          when JobState =:= running; JobState =:= cancelling ->
            Jobs = maps:get(jobs, State),
            State#{jobs => Jobs#{EventRef => Fun(Job)}};
        _ -> State
    end.

matching_worker(EventRef, Worker, State) ->
    case maps:find(EventRef, maps:get(jobs, State)) of
        {ok, #{worker := Worker, state := JobState}}
          when JobState =:= running; JobState =:= cancelling -> true;
        _ -> false
    end.

%% Retention, waiters, and timers

enforce_retention(Name, State0) ->
    Route = maps:get(Name, maps:get(triggers, State0)),
    Config = maps:get(config, Route),
    State1 = purge_route_by_time(Name, maps:get(retention_ms, Config), State0),
    trim_route_count(Name, maps:get(max_retained, Config), State1).

purge_retained(State) ->
    lists:foldl(fun(Name, Acc) -> enforce_retention(Name, Acc) end,
                State, maps:keys(maps:get(triggers, State))).

purge_route_by_time(Name, Retention, State) ->
    Route = maps:get(Name, maps:get(triggers, State)),
    case queue:peek(maps:get(terminal, Route)) of
        empty -> State;
        {value, Ref} ->
            case maps:find(Ref, maps:get(jobs, State)) of
                {ok, Job} ->
                    Finished = maps:get(finished_at, Job),
                    Expired = Retention =:= 0 orelse
                        erlang:system_time(millisecond) - Finished >= Retention,
                    case Expired of
                        true -> purge_route_by_time(
                                  Name, Retention,
                                  evict_terminal_head(Name, Ref, State));
                        false -> State
                    end;
                error ->
                    purge_route_by_time(
                      Name, Retention, evict_terminal_head(Name, Ref, State))
            end
    end.

trim_route_count(Name, Max, State) ->
    Route = maps:get(Name, maps:get(triggers, State)),
    case queue:len(maps:get(terminal, Route)) > Max of
        false -> State;
        true ->
            {{value, Ref}, _} = queue:out(maps:get(terminal, Route)),
            trim_route_count(Name, Max,
                             evict_terminal_head(Name, Ref, State))
    end.

evict_terminal_head(Name, Ref, State) ->
    Route = maps:get(Name, maps:get(triggers, State)),
    {{value, Ref}, Terminal} = queue:out(maps:get(terminal, Route)),
    Jobs0 = maps:get(jobs, State),
    Dedupe0 = maps:get(dedupe, State),
    Dedupe = case maps:find(Ref, Jobs0) of
        {ok, Job} ->
            maps:remove({Name, maps:get(idempotency_key, Job)}, Dedupe0);
        error -> Dedupe0
    end,
    put_route(Name, Route#{terminal => Terminal},
              State#{jobs => maps:remove(Ref, Jobs0), dedupe => Dedupe}).

evict_trigger_jobs(Name, State) ->
    Refs = [Ref || {Ref, #{trigger := SeenName}} <-
                       maps:to_list(maps:get(jobs, State)),
                   SeenName =:= Name],
    lists:foldl(
      fun(Ref, Acc) ->
          case maps:find(Ref, maps:get(jobs, Acc)) of
              {ok, Job} ->
                  Acc#{jobs => maps:remove(Ref, maps:get(jobs, Acc)),
                       dedupe => maps:remove(
                                   {Name, maps:get(idempotency_key, Job)},
                                   maps:get(dedupe, Acc))};
              error -> Acc
          end
      end, State, Refs).

notify_waiters(EventRef, Outcome, Waiters) ->
    maps:foreach(
      fun(WaitRef, #{pid := Pid}) ->
          Pid ! {adk_ambient_terminal, WaitRef, EventRef, Outcome}
      end, Waiters).

remove_all_waiters(EventRef, Job, State) ->
    lists:foldl(
      fun(WaitRef, Acc) -> remove_waiter(EventRef, WaitRef, Acc) end,
      State, maps:keys(maps:get(waiters, Job))).

remove_waiter(EventRef, WaitRef, State) ->
    case maps:find(EventRef, maps:get(jobs, State)) of
        {ok, Job} ->
            case maps:take(WaitRef, maps:get(waiters, Job)) of
                {#{monitor := Monitor}, Waiters} ->
                    erlang:demonitor(Monitor, [flush]),
                    Job1 = Job#{waiters => Waiters},
                    Jobs = maps:get(jobs, State),
                    State#{jobs => Jobs#{EventRef => Job1},
                           waiter_monitors => maps:remove(
                                                Monitor,
                                                maps:get(waiter_monitors,
                                                         State))};
                error -> State
            end;
        error -> State
    end.

remove_waiter_without_demonitor(EventRef, WaitRef, State) ->
    case maps:find(EventRef, maps:get(jobs, State)) of
        {ok, Job} ->
            Waiters = maps:remove(WaitRef, maps:get(waiters, Job)),
            Jobs = maps:get(jobs, State),
            State#{jobs => Jobs#{EventRef => Job#{waiters => Waiters}}};
        error -> State
    end.

expire_queued(State) ->
    Now = erlang:monotonic_time(millisecond),
    Expired = [Ref || {Ref, #{state := queued, deadline := Deadline}} <-
                          maps:to_list(maps:get(jobs, State)),
                      Deadline =/= infinity, Deadline =< Now],
    lists:foldl(
      fun(Ref, Acc) ->
          complete_job(Ref, {timed_out, deadline_exceeded},
                       0, undefined, Acc)
      end, State, Expired).

reschedule_queue_timer(State0) ->
    cancel_queue_timer(maps:get(queue_timer, State0, undefined)),
    Deadlines = [Deadline || #{state := queued, deadline := Deadline} <-
                                 maps:values(maps:get(jobs, State0)),
                             Deadline =/= infinity],
    case Deadlines of
        [] -> State0#{queue_timer => undefined};
        _ ->
            Earliest = lists:min(Deadlines),
            Remaining = erlang:max(
                          0, Earliest - erlang:monotonic_time(millisecond)),
            Timer = erlang:start_timer(Remaining, self(),
                                       ambient_queue_deadline),
            State0#{queue_timer => Timer}
    end.

cancel_queue_timer(undefined) -> ok;
cancel_queue_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

%% Status and scalar helpers

public_job(Job) ->
    #{event_ref => maps:get(event_ref, Job),
      trigger => maps:get(trigger, Job),
      idempotency_key => maps:get(idempotency_key, Job),
      metadata => maps:get(metadata, Job),
      user_id => maps:get(user_id, Job),
      session_id => maps:get(session_id, Job),
      state => maps:get(state, Job),
      outcome => maps:get(outcome, Job),
      attempts => maps:get(attempts, Job),
      run_id => maps:get(run_id, Job),
      deadline => maps:get(deadline, Job),
      created_at => maps:get(created_at, Job),
      started_at => maps:get(started_at, Job),
      finished_at => maps:get(finished_at, Job),
      waiter_count => map_size(maps:get(waiters, Job))}.

public_session_policy(#{mode := per_event, prefix := Prefix}) ->
    #{mode => per_event, prefix => Prefix};
public_session_policy(#{mode := explicit}) ->
    #{mode => explicit};
public_session_policy(#{mode := shared, session_id := SessionId}) ->
    #{mode => shared, session_id => SessionId}.

route_config(Name, State) ->
    maps:get(config, maps:get(Name, maps:get(triggers, State))).

put_route(Name, Route, State) ->
    Triggers = maps:get(triggers, State),
    State#{triggers => Triggers#{Name => Route}}.

safe_call(Request) ->
    try gen_server:call(?SERVER, Request, 5000) of
        Reply -> Reply
    catch
        exit:{noproc, _} -> {error, ambient_runtime_not_started};
        exit:{timeout, _} -> {error, ambient_runtime_timeout};
        exit:Reason -> {error, {ambient_runtime_failed, Reason}}
    end.

generate_ref() ->
    <<A:64, B:64>> = crypto:strong_rand_bytes(16),
    list_to_binary(io_lib:format("ambient-~16.16.0b~16.16.0b", [A, B])).

deadline_after(infinity) -> infinity;
deadline_after(Timeout) -> erlang:monotonic_time(millisecond) + Timeout.

deadline_expired(infinity) -> false;
deadline_expired(Deadline) ->
    Deadline =< erlang:monotonic_time(millisecond).

valid_range(Value, Min, Max) ->
    is_integer(Value) andalso Value >= Min andalso Value =< Max.

valid_timeout(infinity) -> true;
valid_timeout(Value) -> valid_range(Value, 1, 86400000).

valid_event_timeout(infinity, infinity) -> true;
valid_event_timeout(infinity, _Max) -> false;
valid_event_timeout(Value, infinity) -> valid_timeout(Value);
valid_event_timeout(Value, Max) ->
    valid_timeout(Value) andalso Value =< Max.

valid_heap(infinity) -> true;
valid_heap(Value) -> is_integer(Value) andalso Value >= 1000.

valid_binary_id(Value) when is_binary(Value), byte_size(Value) > 0,
                            byte_size(Value) =< 512 ->
    try unicode:characters_to_binary(Value, utf8, utf8) =:= Value
    catch _:_ -> false
    end;
valid_binary_id(_) -> false.

flush_waiter_message(WaitRef, EventRef) ->
    receive
        {adk_ambient_terminal, WaitRef, EventRef, _Outcome} -> ok
    after 0 -> ok
    end.

emit(Decision, Job) ->
    telemetry:execute(
      [erlang_adk, ambient, event],
      #{attempts => maps:get(attempts, Job, 0)},
      #{decision => Decision,
        event_ref => maps:get(event_ref, Job),
        trigger => maps:get(trigger, Job),
        state => maps:get(state, Job),
        outcome => outcome_tag(maps:get(outcome, Job, undefined))}).

outcome_tag(undefined) -> undefined;
outcome_tag({Tag, _}) -> Tag.
