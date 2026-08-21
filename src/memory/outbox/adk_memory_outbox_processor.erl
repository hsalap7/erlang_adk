%% @doc Bounded concurrent processor for `adk_memory_outbox'.
%%
%% `submit/2' waits only for durable local admission.  It never waits for the
%% resolver or memory adapter; those calls run in bounded lightweight workers.
%% Multiple processors may share one outbox because claims are lease-fenced.
-module(adk_memory_outbox_processor).
-behaviour(gen_server).

-define(LEASE_RENEW_MARGIN_MS, 25).

-export([start_link/1, child_spec/1, submit/2, status/2, stats/1,
         semantics/1, health/1, prune_terminal/2, kick/1,
         validate_options/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-record(state, {
    outbox,
    resolver_module,
    resolver_state,
    poll_interval_ms = 100,
    lease_ms = 15000,
    call_timeout_ms = 5000,
    max_concurrency = 4,
    workers = #{},
    timer_ref = undefined
}).

start_link(Opts) when is_map(Opts) ->
    case maps:get(name, Opts, undefined) of
        undefined -> gen_server:start_link(?MODULE, Opts, []);
        Name when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, Opts, []);
        _ -> {error, invalid_memory_outbox_processor_name}
    end;
start_link(_) -> {error, invalid_memory_outbox_processor_options}.

child_spec(Opts) ->
    #{id => maps:get(name, Opts, ?MODULE),
      start => {?MODULE, start_link, [Opts]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

%% @doc Durably enqueue and wake workers.  No adapter call is made inline.
submit(Processor, Request) ->
    safe_call(Processor, {submit, Request}).

status(Processor, JobId) ->
    safe_call(Processor, {status, JobId}).

stats(Processor) -> safe_call(Processor, stats).
semantics(Processor) -> safe_call(Processor, semantics).
health(Processor) -> safe_call(Processor, health).
prune_terminal(Processor, Limit) ->
    safe_call(Processor, {prune_terminal, Limit}).

kick(Processor) ->
    gen_server:cast(Processor, kick).

init(Opts) ->
    case compile_options(Opts) of
        {ok, State} ->
            self() ! tick,
            {ok, State};
        {error, Reason} -> {stop, Reason}
    end.

handle_call({submit, Request}, _From, State) ->
    Reply = adk_memory_outbox:enqueue(State#state.outbox, Request),
    case Reply of
        {ok, _} -> self() ! tick;
        _ -> ok
    end,
    {reply, Reply, State};
handle_call({status, JobId}, _From, State) ->
    {reply, adk_memory_outbox:status(State#state.outbox, JobId), State};
handle_call(stats, _From, State) ->
    {reply, adk_memory_outbox:stats(State#state.outbox), State};
handle_call(semantics, _From, State) ->
    {reply, adk_memory_outbox:semantics(State#state.outbox), State};
handle_call(health, _From, State) ->
    {reply, adk_memory_outbox:health(State#state.outbox), State};
handle_call({prune_terminal, Limit}, _From, State) ->
    {reply, adk_memory_outbox:prune_terminal(
              State#state.outbox, now_ms(), Limit), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_memory_outbox_processor_operation}, State}.

handle_cast(kick, State) ->
    self() ! tick,
    {noreply, State};
handle_cast(_Message, State) -> {noreply, State}.

handle_info(tick, State0) ->
    cancel_timer(State0#state.timer_ref),
    State1 = fill_workers(State0#state{timer_ref = undefined}),
    {noreply, schedule_tick(State1)};
handle_info({memory_outbox_worker_result, WorkerPid, JobId, OwnerToken,
             WorkerResult}, State0) ->
    case maps:find(WorkerPid, State0#state.workers) of
        {ok, #{job_id := JobId, token := OwnerToken,
               monitor := Monitor}} ->
            erlang:demonitor(Monitor, [flush]),
            State1 = remove_worker(WorkerPid, State0),
            _ = persist_worker_result(State0#state.outbox, JobId,
                                      OwnerToken, WorkerResult),
            self() ! tick,
            {noreply, State1};
        _ -> {noreply, State0}
    end;
handle_info({'DOWN', _Monitor, process, WorkerPid, Reason}, State0) ->
    case maps:find(WorkerPid, State0#state.workers) of
        {ok, #{job_id := JobId, token := OwnerToken}} ->
            State1 = remove_worker(WorkerPid, State0),
            _ = adk_memory_outbox:retry(
                  State0#state.outbox, JobId, OwnerToken,
                  {memory_outbox_worker_down, Reason}, now_ms()),
            self() ! tick,
            {noreply, State1};
        error -> {noreply, State0}
    end;
handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, State) ->
    cancel_timer(State#state.timer_ref),
    maps:foreach(fun(Pid, _Meta) -> exit(Pid, shutdown) end,
                 State#state.workers),
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

%% Resolver state can contain credentials or provider-owned handles, while
%% worker metadata contains live lease-owner tokens. Neither may enter system
%% status output or crash reports.
format_status(Status) when is_map(Status) ->
    maps:map(
      fun(state,
          #state{poll_interval_ms = Poll,
                 lease_ms = Lease,
                 call_timeout_ms = Timeout,
                 max_concurrency = Max,
                 workers = Workers}) ->
              #{status => running,
                poll_interval_ms => Poll,
                lease_ms => Lease,
                call_timeout_ms => Timeout,
                max_concurrency => Max,
                active_workers => map_size(Workers)};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, _Value) -> adk_secret_redactor:marker()
      end, Status);
format_status(_Status) -> adk_secret_redactor:marker().

%% Validate the configurable processor tuning independently of runtime-owned
%% store and resolver references, which the supervisor injects after compile.
validate_options(Opts) when is_map(Opts) ->
    Allowed = [name, poll_interval_ms, lease_ms,
               call_timeout_ms, max_concurrency],
    Unknown = lists:sort(maps:keys(maps:without(Allowed, Opts))),
    Name = maps:get(name, Opts, undefined),
    Poll = maps:get(poll_interval_ms, Opts, 100),
    Lease = maps:get(lease_ms, Opts, 15000),
    Timeout = maps:get(call_timeout_ms, Opts, 5000),
    Concurrency = maps:get(max_concurrency, Opts, 4),
    case {Unknown, Name =:= undefined orelse is_atom(Name),
          integer_in(Poll, 5, 60000),
          integer_in(Lease, 250, 3600000),
          integer_in(Timeout, 10, 600000),
          integer_in(Concurrency, 1, 128)} of
        {[_ | _], _, _, _, _, _} ->
            {error, {invalid_memory_outbox_processor_options,
                     {unknown_keys, Unknown}}};
        {[], false, _, _, _, _} ->
            {error, invalid_memory_outbox_processor_name};
        {[], true, false, _, _, _} ->
            {error, invalid_memory_outbox_poll_interval};
        {[], true, true, false, _, _} ->
            {error, invalid_memory_outbox_lease};
        {[], true, true, true, false, _} ->
            {error, invalid_memory_outbox_call_timeout};
        {[], true, true, true, true, false} ->
            {error, invalid_memory_outbox_concurrency};
        {[], true, true, true, true, true}
          when Lease >= (2 * Timeout) + 250 -> ok;
        _ -> {error, memory_outbox_lease_too_short_for_call_timeout}
    end;
validate_options(_) ->
    {error, invalid_memory_outbox_processor_options}.

compile_options(Opts) ->
    Allowed = [name, outbox, resolver, poll_interval_ms, lease_ms,
               call_timeout_ms, max_concurrency],
    Unknown = lists:sort(maps:keys(maps:without(Allowed, Opts))),
    Outbox = maps:get(outbox, Opts, undefined),
    Resolver = maps:get(resolver, Opts, undefined),
    Poll = maps:get(poll_interval_ms, Opts, 100),
    Lease = maps:get(lease_ms, Opts, 15000),
    Timeout = maps:get(call_timeout_ms, Opts, 5000),
    Concurrency = maps:get(max_concurrency, Opts, 4),
    case {Unknown, valid_outbox(Outbox), validate_resolver(Resolver),
          integer_in(Poll, 5, 60000), integer_in(Lease, 250, 3600000),
          integer_in(Timeout, 10, 600000), integer_in(Concurrency, 1, 128)} of
        {[], true, {ok, Module, ResolverState}, true, true, true, true}
          when Lease >= (2 * Timeout) + 250 ->
            {ok, #state{outbox = Outbox,
                        resolver_module = Module,
                        resolver_state = ResolverState,
                        poll_interval_ms = Poll,
                        lease_ms = Lease,
                        call_timeout_ms = Timeout,
                        max_concurrency = Concurrency}};
        {[_ | _], _, _, _, _, _, _} ->
            {error, {invalid_memory_outbox_processor_options,
                     {unknown_keys, Unknown}}};
        {_, false, _, _, _, _, _} ->
            {error, invalid_memory_outbox_handle};
        {_, _, {error, _} = Error, _, _, _, _} -> Error;
        {_, _, _, false, _, _, _} ->
            {error, invalid_memory_outbox_poll_interval};
        {_, _, _, _, false, _, _} ->
            {error, invalid_memory_outbox_lease};
        {_, _, _, _, _, false, _} ->
            {error, invalid_memory_outbox_call_timeout};
        {_, _, _, _, _, _, false} ->
            {error, invalid_memory_outbox_concurrency};
        _ -> {error, memory_outbox_lease_too_short_for_call_timeout}
    end.

valid_outbox(#{jobs_table := Jobs, usage_table := Usage,
               schedule_table := Schedule,
               epochs_table := Epochs, limits := Limits}) ->
    is_atom(Jobs) andalso is_atom(Usage) andalso is_atom(Schedule)
        andalso is_atom(Epochs) andalso is_map(Limits);
valid_outbox(_) -> false.

validate_resolver({Module, ResolverState}) when is_atom(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, resolve, 3) of
                true -> {ok, Module, ResolverState};
                false -> {error, {invalid_memory_outbox_resolver,
                                  {missing_callback, Module, resolve, 3}}}
            end;
        {error, Reason} ->
            {error, {invalid_memory_outbox_resolver,
                     {module_unavailable, Module, Reason}}}
    end;
validate_resolver(_) ->
    {error, {invalid_memory_outbox_resolver,
             expected_module_state_tuple}}.

integer_in(Value, Min, Max) ->
    is_integer(Value) andalso Value >= Min andalso Value =< Max.

fill_workers(State) ->
    case resolver_ready(State) of
        ready ->
            case resolver_claimable_identities(State) of
                {ok, Claimable} -> fill_ready_workers(State, Claimable);
                {error, _Reason} -> State
            end;
        not_ready -> State;
        {error, _Reason} -> State
    end.

fill_ready_workers(
  #state{workers = Workers, max_concurrency = Max} = State, _Claimable)
  when map_size(Workers) >= Max -> State;
fill_ready_workers(State, Claimable) ->
    Token = crypto:strong_rand_bytes(24),
    case adk_memory_outbox:claim_due(
           State#state.outbox, Token, now_ms(), State#state.lease_ms,
           Claimable) of
        {ok, Work} ->
            Parent = self(),
            Resolver = {State#state.resolver_module,
                        State#state.resolver_state},
            Timeout = State#state.call_timeout_ms,
            Outbox = State#state.outbox,
            LeaseMs = State#state.lease_ms,
            {Pid, Monitor} = spawn_monitor(
              fun() ->
                  Result = execute_work(Work, Resolver, Timeout,
                                        Outbox, Token, LeaseMs),
                  Parent ! {memory_outbox_worker_result, self(),
                            maps:get(job_id, Work), Token, Result}
              end),
            Meta = #{monitor => Monitor,
                     job_id => maps:get(job_id, Work), token => Token},
            Workers = State#state.workers,
            fill_ready_workers(
              State#state{workers = Workers#{Pid => Meta}}, Claimable);
        none -> State;
        {error, Reason} ->
            logger:warning("Memory outbox claim failed: ~p",
                           [adk_memory_outbox_payload:safe_reason(Reason)]),
            State
    end.

resolver_claimable_identities(
  #state{resolver_module = Module,
         resolver_state = ResolverState,
         call_timeout_ms = Timeout}) ->
    case erlang:function_exported(Module, claimable_identities, 1) of
        false -> {ok, all};
        true ->
            Work = fun() ->
                try Module:claimable_identities(ResolverState) of
                    Value -> Value
                catch
                    Class:Reason ->
                        {error,
                         {memory_outbox_claimable_identities_exception,
                          Class, Reason}}
                end
            end,
            case bounded_worker_call(
                   Work, erlang:min(Timeout, 1000),
                   claimable_identities) of
                {ok, {ok, Claimable}} ->
                    validate_claimable_identities(Claimable);
                {ok, {error, _} = Error} -> Error;
                {ok, Other} ->
                    {error,
                     {invalid_memory_outbox_claimable_identities_reply,
                      Other}};
                {error, timeout} ->
                    {error, memory_outbox_claimable_identities_timeout};
                {error, Reason} ->
                    {error,
                     {memory_outbox_claimable_identities_process_down,
                      Reason}}
            end
    end.

validate_claimable_identities(all) -> {ok, all};
validate_claimable_identities(Claimable)
  when is_map(Claimable), map_size(Claimable) =< 10000 ->
    case maps:fold(
           fun({Module, StableId}, true, Acc)
                 when is_atom(Module), is_binary(StableId),
                      byte_size(StableId) > 0,
                      byte_size(StableId) =< 256 -> Acc;
              (_Identity, _Value, _Acc) -> false
           end, true, Claimable) of
        true -> {ok, Claimable};
        false -> {error, invalid_memory_outbox_claimable_identities}
    end;
validate_claimable_identities(_Claimable) ->
    {error, invalid_memory_outbox_claimable_identities}.

resolver_ready(#state{resolver_module = Module,
                      resolver_state = ResolverState,
                      call_timeout_ms = Timeout}) ->
    case erlang:function_exported(Module, ready, 1) of
        false -> ready;
        true ->
            Work = fun() ->
                try Module:ready(ResolverState) of
                    Value -> Value
                catch
                    Class:Reason ->
                        {error, {memory_outbox_resolver_ready_exception,
                                 Class, Reason}}
                end
            end,
            case bounded_worker_call(
                   Work, erlang:min(Timeout, 1000), resolver_ready) of
                {ok, ready} -> ready;
                {ok, not_ready} -> not_ready;
                {ok, {error, _} = Error} -> Error;
                {ok, Other} ->
                    {error, {invalid_memory_outbox_resolver_ready_reply,
                             Other}};
                {error, timeout} ->
                    {error, memory_outbox_resolver_ready_timeout};
                {error, Reason} ->
                    {error, {memory_outbox_resolver_ready_process_down,
                             Reason}}
            end
    end.

execute_work(Work, {ResolverModule, ResolverState}, Timeout,
             Outbox, OwnerToken, LeaseMs) ->
    try resolve_service(Work, ResolverModule, ResolverState, Timeout) of
        {ok, ServiceRef} ->
            %% Resolution and capability discovery are deliberately completed
            %% before renewing. The renewal is both an ownership revalidation
            %% and a fresh adapter-call lease; no external mutation is started
            %% unless it succeeds while the original claim is still current.
            case renew_before_adapter(Outbox, Work, OwnerToken,
                                      LeaseMs, Timeout) of
                ok -> call_adapter(ServiceRef, Work, Timeout);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    catch
        Class:Reason -> {error, {memory_outbox_worker_exception,
                                Class, Reason}}
    end.

resolve_service(Work, ResolverModule, ResolverState, Timeout) ->
    {PersistedModule, StableId} = maps:get(adapter, Work),
    Reply = bounded_resolver_call(
              ResolverModule, PersistedModule, StableId,
              ResolverState, Timeout),
    case Reply of
        {ok, {PersistedModule, _Handle} = ServiceRef} ->
            case adk_service_ref:validate(memory, ServiceRef) of
                {ok, ServiceRef} -> require_idempotent_v2(ServiceRef, Timeout);
                {error, _} = Error -> Error
            end;
        {ok, {_OtherModule, _Handle}} ->
            {error, memory_outbox_resolver_module_mismatch};
        {error, _} = Error -> Error;
        Other -> {error, {invalid_memory_outbox_resolver_reply, Other}}
    end.

bounded_resolver_call(ResolverModule, PersistedModule, StableId,
                      ResolverState, Timeout) ->
    Work = fun() ->
        try ResolverModule:resolve(PersistedModule, StableId,
                                   ResolverState) of
            Value -> Value
        catch
            Class:Reason -> {error, {memory_outbox_resolver_exception,
                                    Class, Reason}}
        end
    end,
    case bounded_worker_call(Work, Timeout, resolver) of
        {ok, Reply} -> Reply;
        {error, timeout} -> {error, memory_outbox_resolver_timeout};
        {error, Reason} ->
            {error, {memory_outbox_resolver_process_down, Reason}}
    end.

renew_before_adapter(Outbox, Work, OwnerToken, LeaseMs, Timeout) ->
    Remaining = maps:get(lease_until, Work) - now_ms()
                - ?LEASE_RENEW_MARGIN_MS,
    case Remaining > 0 of
        false -> {error, memory_outbox_lease_expired_before_adapter};
        true ->
            Budget = erlang:min(Timeout, Remaining),
            JobId = maps:get(job_id, Work),
            Renew = fun() ->
                adk_memory_outbox:renew(
                  Outbox, JobId, OwnerToken, now_ms(), LeaseMs)
            end,
            case bounded_worker_call(Renew, Budget, lease_renewal) of
                {ok, {ok, #{phase := running}}} -> ok;
                {ok, {ok, _InvalidStatus}} ->
                    {error, invalid_memory_outbox_renewal_status};
                {ok, {error, Reason}} ->
                    {error, {memory_outbox_lease_revalidation_failed,
                             Reason}};
                {ok, Other} ->
                    {error, {invalid_memory_outbox_renewal_reply, Other}};
                {error, timeout} ->
                    {error, memory_outbox_lease_renewal_timeout};
                {error, Reason} ->
                    {error, {memory_outbox_lease_renewal_process_down,
                             Reason}}
            end
    end.

%% Run callbacks which do not carry their own deadline in a linked executor.
%% Linking makes processor shutdown propagate through the outbox worker to a
%% blocked callback. We unlink before enforcing our own timeout so killing the
%% executor cannot kill the worker which must record the bounded failure.
bounded_worker_call(Fun, Timeout, Phase)
  when is_function(Fun, 0), is_integer(Timeout), Timeout > 0 ->
    Parent = self(),
    ReplyRef = make_ref(),
    ExecutorFun = fun() -> Parent ! {ReplyRef, self(), Fun()} end,
    {Executor, Monitor} = spawn_opt(ExecutorFun, [link, monitor]),
    receive
        {ReplyRef, Executor, Reply} ->
            unlink(Executor),
            erlang:demonitor(Monitor, [flush]),
            {ok, Reply};
        {'DOWN', Monitor, process, Executor, Reason} ->
            {error, {Phase, Reason}}
    after Timeout ->
        unlink(Executor),
        exit(Executor, kill),
        await_executor_down(Executor, Monitor),
        flush_executor_reply(ReplyRef, Executor),
        {error, timeout}
    end.

await_executor_down(Executor, Monitor) ->
    receive
        {'DOWN', Monitor, process, Executor, _Reason} -> ok
    after 100 ->
        erlang:demonitor(Monitor, [flush]),
        ok
    end.

flush_executor_reply(ReplyRef, Executor) ->
    receive {ReplyRef, Executor, _Reply} -> ok after 0 -> ok end.

require_idempotent_v2(ServiceRef, Timeout) ->
    case adk_service_ref:call(ServiceRef, capabilities, [], Timeout) of
        {ok, Capabilities} when is_map(Capabilities) ->
            check_capabilities(ServiceRef, Capabilities);
        Capabilities when is_map(Capabilities) ->
            check_capabilities(ServiceRef, Capabilities);
        {error, _} = Error -> Error;
        Other -> {error, {invalid_memory_outbox_capabilities, Other}}
    end.

check_capabilities(ServiceRef, Capabilities) ->
    Version = maps:get(contract_version, Capabilities,
                       maps:get(version, Capabilities, 0)),
    case is_integer(Version) andalso Version >= 2 andalso
         maps:get(idempotent_ingestion, Capabilities, false) =:= true andalso
         maps:get(incremental_events, Capabilities, false) =:= true andalso
         maps:get(erasure_epoch_fencing, Capabilities, false) =:= true of
        true -> {ok, ServiceRef};
        false ->
            {error, memory_outbox_requires_fenced_idempotent_v2_adapter}
    end.

call_adapter({Module, _} = ServiceRef, Work, Timeout) ->
    Scope = maps:get(scope, Work),
    SessionId = maps:get(session_id, Work),
    Events = maps:get(events, Work),
    Options = #{erasure_epoch => maps:get(erasure_epoch, Work)},
    Reply = case erlang:function_exported(Module, add_events, 6) of
        true ->
            adk_service_ref:call(
              ServiceRef, add_events,
              [Scope, SessionId, Events, Options,
               #{timeout_ms => Timeout}],
              Timeout);
        false ->
            adk_service_ref:call(
              ServiceRef, add_events,
              [Scope, SessionId, Events, Options], Timeout)
    end,
    case Reply of
        {ok, Result} when is_map(Result) -> {ok, Result};
        {error, _} = Error -> Error;
        Other -> {error, {invalid_memory_outbox_adapter_reply, Other}}
    end.

persist_worker_result(Outbox, JobId, OwnerToken, {ok, Result}) ->
    adk_memory_outbox:complete_batch(
      Outbox, JobId, OwnerToken, Result, now_ms());
persist_worker_result(Outbox, JobId, OwnerToken, {error, Reason}) ->
    adk_memory_outbox:retry(
      Outbox, JobId, OwnerToken, Reason, now_ms()).

remove_worker(Pid, #state{workers = Workers} = State) ->
    State#state{workers = maps:remove(Pid, Workers)}.

schedule_tick(State) ->
    Timer = erlang:send_after(State#state.poll_interval_ms, self(), tick),
    State#state{timer_ref = Timer}.

cancel_timer(undefined) -> ok;
cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

safe_call(Processor, Request) ->
    try gen_server:call(Processor, Request, 10000) of
        Reply -> Reply
    catch
        exit:{noproc, _} -> {error, memory_outbox_processor_unavailable};
        exit:{timeout, _} -> {error, memory_outbox_processor_timeout};
        exit:_Reason -> {error, memory_outbox_processor_unavailable}
    end.

now_ms() -> erlang:system_time(millisecond).
