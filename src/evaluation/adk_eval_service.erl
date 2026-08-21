%% @doc Supervised, bounded evaluation-job service.
%%
%% The service owns scheduling while an `adk_eval_store' owns immutable sets,
%% lifecycle state, terminal results, and baselines.  Runtime adapter handles
%% remain only in this process and supervised task workers; they are never
%% persisted.  After a service restart, previously queued/running jobs are
%% deterministically marked failed instead of being silently replayed.
-module(adk_eval_service).
-behaviour(gen_server).

-export([start_link/1, child_spec/1, stop/1,
         submit/3, status/3, result/3, cancel/3,
         list_jobs/3, get_set/4, list_sets/3,
         put_baseline/4, get_baseline/3, prune/3, capabilities/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(DEFAULT_MAX_CONCURRENCY, 4).
-define(DEFAULT_MAX_QUEUE, 1000).
-define(DEFAULT_MAX_QUEUE_BYTES, 67108864).
-define(MAX_REQUEST_BYTES, 2097152).
-define(DEFAULT_TASK_TIMEOUT_MS, 3600000).
-define(DEFAULT_TASK_RETENTION_MS, 30000).
-define(CALL_TIMEOUT, 30000).
-define(VALIDATION_TIMEOUT_MS, 1000).
-define(VALIDATION_MAX_HEAP_WORDS, 1048576).
-define(MAX_PENDING_VALIDATIONS, 64).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Options) when is_map(Options) ->
    case maps:get(name, Options, undefined) of
        undefined -> gen_server:start_link(?MODULE, Options, []);
        Name when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, Options, []);
        _ -> {error, invalid_eval_service_name}
    end;
start_link(_Options) -> {error, invalid_eval_service_options}.

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Options) ->
    #{id => maps:get(name, Options, ?MODULE),
      start => {?MODULE, start_link, [Options]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec stop(gen_server:server_ref()) -> ok.
stop(Service) -> gen_server:stop(Service).

-spec submit(gen_server:server_ref(), adk_eval_store:scope(), map()) ->
    {ok, map()} | {error, term()}.
submit(Service, Scope, Request) -> call(Service, {submit, Scope, Request}).

-spec status(gen_server:server_ref(), adk_eval_store:scope(), binary()) ->
    {ok, map()} | {error, term()}.
status(Service, Scope, JobId) -> call(Service, {status, Scope, JobId}).

-spec result(gen_server:server_ref(), adk_eval_store:scope(), binary()) ->
    {ok, map()} | {error, term()}.
result(Service, Scope, JobId) -> call(Service, {result, Scope, JobId}).

-spec cancel(gen_server:server_ref(), adk_eval_store:scope(), binary()) ->
    ok | {error, term()}.
cancel(Service, Scope, JobId) -> call(Service, {cancel, Scope, JobId}).

-spec list_jobs(gen_server:server_ref(), adk_eval_store:scope(), map()) ->
    {ok, map()} | {error, term()}.
list_jobs(Service, Scope, Options) ->
    call(Service, {list_jobs, Scope, Options}).

-spec get_set(gen_server:server_ref(), adk_eval_store:scope(), binary(),
              binary()) -> {ok, map()} | {error, term()}.
get_set(Service, Scope, Id, Version) ->
    call(Service, {get_set, Scope, Id, Version}).

-spec list_sets(gen_server:server_ref(), adk_eval_store:scope(), map()) ->
    {ok, map()} | {error, term()}.
list_sets(Service, Scope, Options) ->
    call(Service, {list_sets, Scope, Options}).

-spec put_baseline(gen_server:server_ref(), adk_eval_store:scope(), binary(),
                   binary()) -> {ok, map()} | {error, term()}.
put_baseline(Service, Scope, Name, JobId) ->
    call(Service, {put_baseline, Scope, Name, JobId}).

-spec get_baseline(gen_server:server_ref(), adk_eval_store:scope(), binary()) ->
    {ok, map()} | {error, term()}.
get_baseline(Service, Scope, Name) ->
    call(Service, {get_baseline, Scope, Name}).

-spec prune(gen_server:server_ref(), adk_eval_store:scope(), map()) ->
    {ok, map()} | {error, term()}.
prune(Service, Scope, Options) ->
    call(Service, {prune, Scope, Options}).

-spec capabilities(gen_server:server_ref()) -> {ok, map()} | {error, term()}.
capabilities(Service) -> call(Service, capabilities).

init(Options0) ->
    process_flag(trap_exit, true),
    process_flag(message_queue_data, off_heap),
    case normalize_options(Options0) of
        {ok, Options} ->
            case open_store(maps:get(store, Options)) of
                {ok, Store, Owned, StoreLock} ->
                    case store_call(
                           Store, recover_active,
                           [<<"evaluation_service_restarted">>]) of
                        {ok, Recovered} ->
                            {ok, #{options => Options, store => Store,
                                   store_lock => StoreLock,
                                   owned_store => Owned,
                                   recovered_jobs => Recovered,
                                   active => #{}, queue => queue:new(),
                                   queued_bytes => 0,
                                   validations => #{},
                                   validation_monitors => #{}}};
                        {error, Reason} ->
                            release_store_lock(StoreLock),
                            close_owned_store(Store, Owned),
                            {stop,
                             {eval_store_recovery_failed, Reason}}
                    end;
                {error, Reason} -> {stop, Reason}
            end;
        {error, Reason} -> {stop, Reason}
    end.

handle_call(capabilities, _From, State) ->
    StoreCapabilities = store_call(maps:get(store, State), capabilities, []),
    Options = maps:get(options, State),
    Reply = case StoreCapabilities of
        Capabilities when is_map(Capabilities) ->
            {ok, #{contract_version => 1,
                   max_concurrency => maps:get(max_concurrency, Options),
                   max_queue => maps:get(max_queue, Options),
                   active_jobs => map_size(maps:get(active, State)),
                   queued_jobs => queue:len(maps:get(queue, State)),
                   queued_bytes => maps:get(queued_bytes, State),
                   pending_submissions =>
                       map_size(maps:get(validations, State, #{})),
                   recovered_jobs => maps:get(recovered_jobs, State),
                   worker => worker_capabilities(
                               maps:get(worker, Options)),
                   store => Capabilities}};
        {error, _} = Error -> Error
    end,
    {reply, Reply, State};
handle_call({submit, Scope, Request0}, From, State0) ->
    start_request_validation(Scope, Request0, From, State0);
handle_call({status, Scope, JobId}, _From, State) ->
    Reply = case store_call(maps:get(store, State), get_job, [Scope, JobId]) of
        {ok, Job} -> {ok, adk_eval_store:public_job(Job)};
        {error, _} = Error -> Error
    end,
    {reply, Reply, State};
handle_call({result, Scope, JobId}, _From, State) ->
    Reply = case store_call(maps:get(store, State), get_job, [Scope, JobId]) of
        {ok, #{phase := completed, result := Result}} -> {ok, Result};
        {ok, #{phase := Phase}} when Phase =:= queued; Phase =:= running ->
            {error, result_not_ready};
        {ok, #{phase := Phase, reason := Reason}} ->
            {error, {evaluation_job_terminal, Phase, Reason}};
        {error, _} = Error -> Error
    end,
    {reply, Reply, State};
handle_call({cancel, Scope, JobId}, _From, State0) ->
    case store_call(maps:get(store, State0), get_job, [Scope, JobId]) of
        {ok, #{phase := queued}} ->
            {Removed, RemovedBytes, Queue} =
                remove_queued(Scope, JobId, maps:get(queue, State0)),
            case Removed of
                false ->
                    %% The task may be between admission and the running
                    %% transition. Treat it as active if present.
                    cancel_active(Scope, JobId, State0);
                true ->
                    Reply = transition_terminal(
                              maps:get(store, State0), Scope, JobId,
                              [queued], cancelled, <<"user_cancelled">>),
                    case Reply of
                        {ok, _} ->
                            {reply, ok,
                             State0#{queue => Queue,
                                     queued_bytes =>
                                         maps:get(queued_bytes, State0) -
                                         RemovedBytes}};
                        {error, Reason} ->
                            cancel_persistence_stop(Reason, State0)
                    end
            end;
        {ok, #{phase := running}} -> cancel_active(Scope, JobId, State0);
        {ok, #{phase := Phase}} ->
            {reply, {error, {already_terminal, Phase}}, State0};
        {error, _} = Error -> {reply, Error, State0}
    end;
handle_call({list_jobs, Scope, Options}, _From, State) ->
    {reply, store_call(maps:get(store, State), list_jobs, [Scope, Options]),
     State};
handle_call({get_set, Scope, Id, Version}, _From, State) ->
    {reply, store_call(maps:get(store, State), get_set,
                       [Scope, Id, Version]), State};
handle_call({list_sets, Scope, Options}, _From, State) ->
    {reply, store_call(maps:get(store, State), list_sets, [Scope, Options]),
     State};
handle_call({put_baseline, Scope, Name, JobId}, _From, State) ->
    {reply, store_call(maps:get(store, State), put_baseline,
                       [Scope, Name, JobId]), State};
handle_call({get_baseline, Scope, Name}, _From, State) ->
    {reply, store_call(maps:get(store, State), get_baseline,
                       [Scope, Name]), State};
handle_call({prune, Scope, Options}, _From, State) ->
    {reply, store_call(maps:get(store, State), prune, [Scope, Options]), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_eval_service_call}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info({adk_eval_request_validated, Ref, Pid, Result}, State0) ->
    case take_validation(Ref, Pid, State0) of
        error -> {noreply, State0};
        {Entry, State1} ->
            finish_request_validation(Entry, Result, State1)
    end;
handle_info({adk_eval_request_validation_timeout, Ref}, State0) ->
    case take_validation(Ref, any, State0) of
        error -> {noreply, State0};
        {Entry, State1} ->
            exit(maps:get(pid, Entry), kill),
            erlang:demonitor(maps:get(monitor, Entry), [flush]),
            gen_server:reply(
              maps:get(from, Entry),
              {error, evaluation_request_validation_timeout}),
            {noreply, State1}
    end;
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State0) ->
    Monitors = maps:get(validation_monitors, State0, #{}),
    case maps:find(Monitor, Monitors) of
        error -> {noreply, State0};
        {ok, Ref} ->
            case take_validation(Ref, any, State0) of
                error -> {noreply, State0};
                {Entry, State1} ->
                    gen_server:reply(
                      maps:get(from, Entry),
                      {error, evaluation_request_validation_failed}),
                    {noreply, State1}
            end
    end;
handle_info({adk_task_terminal, TaskRef, Outcome}, State0) ->
    finish_active({local, TaskRef}, Outcome, State0);
handle_info({adk_eval_worker_terminal, Module, Ref, Outcome}, State0)
  when is_atom(Module), is_reference(Ref) ->
    finish_active({worker, Module, Ref}, Outcome, State0);
handle_info({'EXIT', Pid, Reason}, State) ->
    %% A linked owned ETS store is part of this service's consistency
    %% boundary. An unexpected exit must restart the service and recover jobs.
    case maps:get(owned_store, State, false) of
        {process, Pid} -> {stop, {eval_store_down, safe_reason(Reason)}, State};
        _ when Reason =:= normal; Reason =:= shutdown -> {noreply, State};
        _ ->
            case Reason of
                {shutdown, _} -> {noreply, State};
                _ -> {noreply, State}
            end
    end;
handle_info(_Message, State) -> {noreply, State}.

finish_active({local, TaskRef} = TaskKey, Outcome, State0) ->
    Active = maps:get(active, State0),
    case maps:is_key(TaskKey, Active) of
        true -> finish_active_key(TaskKey, Outcome, State0);
        false -> finish_active_key(TaskRef, Outcome, State0)
    end;
finish_active(TaskKey, Outcome, State0) ->
    finish_active_key(TaskKey, Outcome, State0).

finish_active_key(TaskKey, Outcome, State0) ->
    Active0 = maps:get(active, State0),
    case maps:take(TaskKey, Active0) of
        error -> {noreply, State0};
        {#{scope := Scope, job_id := JobId}, Active} ->
            Store = maps:get(store, State0),
            case persist_outcome(Store, Scope, JobId, Outcome) of
                {ok, _Status} ->
                    State1 = State0#{active => Active},
                    case start_queued(State1) of
                        {ok, State} -> {noreply, State};
                        {error, Reason, FailedState} ->
                            {stop, Reason, FailedState}
                    end;
                {error, Reason} ->
                    %% A terminal task result must never be acknowledged and
                    %% forgotten while durable state still says `running'. A
                    %% supervised restart deterministically recovers the job.
                    {stop,
                     {evaluation_result_persistence_failed,
                     safe_reason(Reason)}, State0}
            end
    end.

terminate(_Reason, State) ->
    maps:foreach(
      fun(_Ref, Validation) ->
          erlang:cancel_timer(maps:get(timer, Validation)),
          exit(maps:get(pid, Validation), kill)
      end, maps:get(validations, State, #{})),
    maps:foreach(fun(TaskKey, Entry) ->
        _ = catch cancel_execution(
                    TaskKey, Entry, evaluation_service_stopping)
    end, maps:get(active, State, #{})),
    release_store_lock(maps:get(store_lock, State, undefined)),
    close_owned_store(maps:get(store, State, undefined),
                      maps:get(owned_store, State, false)),
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

format_status(Status) ->
    maps:map(
      fun(state, State) when is_map(State) ->
              #{active_jobs => map_size(maps:get(active, State, #{})),
                queued_jobs => queue:len(maps:get(queue, State, queue:new())),
                queued_bytes => maps:get(queued_bytes, State, 0),
                pending_submissions =>
                    map_size(maps:get(validations, State, #{})),
                recovered_jobs => maps:get(recovered_jobs, State, 0),
                store_owned => maps:get(owned_store, State, false) =/= false};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, _Value) -> adk_secret_redactor:marker()
      end, Status).

normalize_options(Options) ->
    Defaults = #{name => undefined,
                 max_concurrency => ?DEFAULT_MAX_CONCURRENCY,
                 max_queue => ?DEFAULT_MAX_QUEUE,
                 max_queue_bytes => ?DEFAULT_MAX_QUEUE_BYTES,
                 task_timeout_ms => ?DEFAULT_TASK_TIMEOUT_MS,
                 task_retention_ms => ?DEFAULT_TASK_RETENTION_MS,
                 worker => local},
    Allowed = [store | maps:keys(Defaults)],
    Unknown = maps:keys(maps:without(Allowed, Options)),
    Merged = maps:merge(Defaults, Options),
    case {Unknown, maps:find(store, Merged), valid_options(Merged),
          normalize_worker(maps:get(worker, Merged))} of
        {[], {ok, Store}, true, {ok, Worker}} ->
            {ok, Merged#{store => Store, worker => Worker}};
        {[_ | _], _, _, _} ->
            {error, {unknown_eval_service_options, lists:sort(Unknown)}};
        {_, error, _, _} -> {error, eval_store_required};
        {_, _, _, {error, _} = Error} -> Error;
        _ -> {error, invalid_eval_service_options}
    end.

valid_options(Options) ->
    valid_name_option(maps:get(name, Options)) andalso
    valid_bounded(maps:get(max_concurrency, Options), 1, 256) andalso
    valid_bounded(maps:get(max_queue, Options), 0, 100000) andalso
    valid_bounded(maps:get(max_queue_bytes, Options), 1, 1073741824) andalso
    valid_bounded(maps:get(task_timeout_ms, Options), 1, 86400000) andalso
    valid_bounded(maps:get(task_retention_ms, Options), 0, 3600000).

valid_name_option(undefined) -> true;
valid_name_option(Name) -> is_atom(Name).
valid_bounded(Value, Min, Max) ->
    is_integer(Value) andalso Value >= Min andalso Value =< Max.

normalize_worker(local) -> {ok, local};
normalize_worker(#{module := Module} = Worker) when is_atom(Module) ->
    Unknown = maps:keys(maps:without([module, config], Worker)),
    Config = maps:get(config, Worker, #{}),
    case {Unknown, is_map(Config), code:ensure_loaded(Module)} of
        {[], true, {module, Module}} ->
            case erlang:function_exported(Module, start, 3) andalso
                 erlang:function_exported(Module, cancel, 2) of
                true -> {ok, #{module => Module, config => Config}};
                false -> {error, invalid_eval_worker_module}
            end;
        {[_ | _], _, _} ->
            {error, {unknown_eval_worker_fields, lists:sort(Unknown)}};
        _ -> {error, invalid_eval_worker}
    end;
normalize_worker(_) -> {error, invalid_eval_worker}.

worker_capabilities(local) ->
    #{transport => local, contract_version => 1,
      cancellation => owner_bound_task};
worker_capabilities(#{module := Module, config := Config}) ->
    case erlang:function_exported(Module, capabilities, 1) of
        true ->
            try Module:capabilities(Config) of
                Value when is_map(Value) -> Value;
                _ -> #{transport => external, status => invalid_capabilities}
            catch
                _:_ -> #{transport => external, status => unavailable}
            end;
        false -> #{transport => external, module => Module}
    end.

open_store({Module, Handle}) when is_atom(Module) ->
    case validate_store(Module) of
        ok ->
            case store_call({Module, Handle}, capabilities, []) of
                Capabilities when is_map(Capabilities), map_size(Capabilities) > 0 ->
                    case store_identity(Module, Handle) of
                        {ok, Identity} ->
                            case acquire_store_lock(Module, Identity) of
                                {ok, Lock} ->
                                    {ok, {Module, Handle}, false, Lock};
                                {error, _} = Error -> Error
                            end;
                        _ -> {error, invalid_eval_store_identity}
                    end;
                _ -> {error, invalid_eval_store_handle}
            end;
        {error, _} = Error -> Error
    end;
open_store({owned, Module, Config}) when is_atom(Module), is_map(Config) ->
    case validate_store(Module) of
        ok -> open_owned_store_locked(Module, Config);
        {error, _} = Error -> Error
    end;
open_store(_Store) -> {error, invalid_eval_store_reference}.

open_owned_store_locked(Module, Config) ->
    case preacquire_store_lock(Module, Config) of
        {ok, PreIdentity, PreLock} ->
            case open_owned_store(Module, Config) of
                {ok, Store, Owned} ->
                    finish_open_owned_store(
                      Module, Store, Owned, PreIdentity, PreLock);
                {error, _} = Error ->
                    release_store_lock(PreLock),
                    Error
            end;
        {error, _} = Error -> Error
    end.

preacquire_store_lock(Module, Config) ->
    case store_identity(Module, Config) of
        {ok, Identity} ->
            case acquire_store_lock(Module, Identity) of
                {ok, Lock} -> {ok, Identity, Lock};
                {error, _} = Error -> Error
            end;
        defer ->
            case erlang:function_exported(Module, start_link, 1) of
                true -> {ok, defer, undefined};
                false -> {error, eval_store_preinit_identity_required}
            end;
        {error, _} -> {error, invalid_eval_store_identity}
    end.

finish_open_owned_store(Module, {Module, Handle} = Store, Owned,
                        PreIdentity, PreLock) ->
    case store_identity(Module, Handle) of
        {ok, Identity} when PreIdentity =:= defer ->
            case acquire_store_lock(Module, Identity) of
                {ok, Lock} -> validate_open_owned_store(Store, Owned, Lock);
                {error, _} = Error ->
                    close_owned_store(Store, Owned),
                    Error
            end;
        {ok, Identity} when Identity =:= PreIdentity ->
            validate_open_owned_store(Store, Owned, PreLock);
        {ok, _DifferentIdentity} ->
            release_store_lock(PreLock),
            close_owned_store(Store, Owned),
            {error, eval_store_identity_changed_during_init};
        _ ->
            release_store_lock(PreLock),
            close_owned_store(Store, Owned),
            {error, invalid_eval_store_identity}
    end.

validate_open_owned_store({Module, Handle} = Store, Owned, Lock) ->
    case store_call({Module, Handle}, capabilities, []) of
        Capabilities when is_map(Capabilities), map_size(Capabilities) > 0 ->
            {ok, Store, Owned, Lock};
        _ ->
            release_store_lock(Lock),
            close_owned_store(Store, Owned),
            {error, invalid_eval_store_handle}
    end.

open_owned_store(Module, Config) ->
    case erlang:function_exported(Module, start_link, 1) of
        true ->
            case Module:start_link(Config) of
                {ok, Handle} when is_pid(Handle) ->
                    {ok, {Module, Handle}, {process, Handle}};
                {error, Reason} -> {error, {eval_store_start_failed, Reason}};
                _ -> {error, invalid_eval_store_start_reply}
            end;
        false ->
            case erlang:function_exported(Module, init, 1) of
                true ->
                    case Module:init(Config) of
                        {ok, Handle} -> {ok, {Module, Handle}, durable_handle};
                        {error, Reason} ->
                            {error, {eval_store_init_failed, Reason}};
                        _ -> {error, invalid_eval_store_init_reply}
                    end;
                false -> {error, eval_store_lifecycle_unsupported}
            end
    end.

validate_store(Module) ->
    Callbacks = [{ownership_identity, 1}, {capabilities, 1},
                 {put_set, 3}, {get_set, 4},
                 {list_sets, 3}, {create_job, 3}, {create_evaluation, 4},
                 {transition_job, 6},
                 {get_job, 3}, {list_jobs, 3}, {put_baseline, 4},
                 {get_baseline, 3}, {recover_active, 2}, {prune, 3}],
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case lists:all(fun({Name, Arity}) ->
                     erlang:function_exported(Module, Name, Arity)
                 end, Callbacks) of
                true -> ok;
                false -> {error, invalid_eval_store_module}
            end;
        _ -> {error, eval_store_module_unavailable}
    end.

close_owned_store({Module, Handle}, {process, Handle}) ->
    case erlang:function_exported(Module, stop, 1) of
        true -> _ = catch Module:stop(Handle);
        false -> _ = catch gen_server:stop(Handle)
    end,
    ok;
close_owned_store(_Store, _Owned) -> ok.

store_identity(Module, ConfigOrHandle) ->
    try Module:ownership_identity(ConfigOrHandle) of
        {ok, Identity} -> {ok, Identity};
        defer -> defer;
        {error, _} = Error -> Error;
        _ -> {error, invalid_eval_store_identity}
    catch
        _:_ -> {error, invalid_eval_store_identity}
    end.

acquire_store_lock(_Module, StoreIdentity) ->
    Identity = crypto:hash(
                 sha256, term_to_binary(StoreIdentity, [deterministic])),
    Name = {adk_eval_service_store_owner, Identity},
    case global:register_name(Name, self()) of
        yes -> {ok, Name};
        no -> {error, eval_store_already_owned}
    end.

release_store_lock(undefined) -> ok;
release_store_lock(Name) ->
    _ = global:unregister_name(Name),
    ok.

start_request_validation(Scope, Request0, From, State0) ->
    Validations0 = maps:get(validations, State0, #{}),
    case map_size(Validations0) < ?MAX_PENDING_VALIDATIONS of
        false ->
            {reply, {error, evaluation_request_validation_busy}, State0};
        true ->
            Owner = self(),
            Ref = make_ref(),
            Worker = fun() ->
                Result = try prepare_request(Scope, Request0) of
                    Prepared -> Prepared
                catch
                    _:_ -> {error, evaluation_request_validation_failed}
                end,
                _ = erlang:send(
                      Owner,
                      {adk_eval_request_validated, Ref, self(), Result},
                      [nosuspend]),
                ok
            end,
            SpawnOptions =
                [monitor, {message_queue_data, off_heap},
                 {max_heap_size,
                  #{size => ?VALIDATION_MAX_HEAP_WORDS,
                    kill => true, error_logger => false,
                    include_shared_binaries => true}}],
            try spawn_opt(Worker, SpawnOptions) of
                {Pid, Monitor} ->
                    Timer = erlang:send_after(
                              ?VALIDATION_TIMEOUT_MS, self(),
                              {adk_eval_request_validation_timeout, Ref}),
                    Entry = #{from => From, pid => Pid,
                              monitor => Monitor, timer => Timer},
                    Monitors0 = maps:get(validation_monitors, State0, #{}),
                    {noreply,
                     State0#{validations => Validations0#{Ref => Entry},
                             validation_monitors =>
                                 Monitors0#{Monitor => Ref}}}
            catch
                _:_ ->
                    {reply,
                     {error, evaluation_request_validation_unavailable},
                     State0}
            end
    end.

take_validation(Ref, ExpectedPid, State0) ->
    Validations0 = maps:get(validations, State0, #{}),
    case maps:find(Ref, Validations0) of
        {ok, #{pid := Pid} = Entry}
          when ExpectedPid =:= any; ExpectedPid =:= Pid ->
            erlang:cancel_timer(maps:get(timer, Entry)),
            Monitor = maps:get(monitor, Entry),
            erlang:demonitor(Monitor, [flush]),
            Monitors0 = maps:get(validation_monitors, State0, #{}),
            State = State0#{validations => maps:remove(Ref, Validations0),
                            validation_monitors =>
                                maps:remove(Monitor, Monitors0)},
            {Entry, State};
        _ -> error
    end.

finish_request_validation(Entry, Result, State0) ->
    From = maps:get(from, Entry),
    case validated_submission(Result, State0) of
        {reply, Reply, State} ->
            gen_server:reply(From, Reply),
            {noreply, State};
        {stop, Reason, Reply, State} ->
            gen_server:reply(From, Reply),
            {stop, Reason, State}
    end.

validated_submission(
  {ok, Scope, Request, RequestBytes, Set, SetId, SetVersion, Metadata},
  State0) ->
    case admission_available(RequestBytes, State0) of
        false ->
            {reply, {error, evaluation_queue_full}, State0};
        true ->
            Store = maps:get(store, State0),
            JobId = generate_job_id(),
            Job = #{job_id => JobId, eval_set_id => SetId,
                    eval_set_version => SetVersion, metadata => Metadata},
            case store_call(Store, create_evaluation, [Scope, Set, Job]) of
                {ok, #{job := Status}} ->
                    QueueEntry = #{scope => Scope, job_id => JobId,
                                   bytes => RequestBytes,
                                   request => Request},
                    case admit(QueueEntry, State0) of
                        {ok, State} -> {reply, {ok, Status}, State};
                        {error, Reason, State} ->
                            admission_failure_reply(
                              Store, Scope, JobId, Reason, State)
                    end;
                {ok, _Invalid} ->
                    {stop, invalid_eval_store_create_reply,
                     {error, invalid_eval_store_create_reply}, State0};
                {error, _} = Error -> {reply, Error, State0}
            end
    end;
validated_submission({error, _} = Error, State) ->
    {reply, Error, State};
validated_submission(_Invalid, State) ->
    {reply, {error, invalid_eval_request}, State}.

prepare_request(Scope, Request0) when is_map(Request0) ->
    Allowed = [set, adapter, metrics, options, metadata],
    Unknown = maps:keys(maps:without(Allowed, Request0)),
    Set0 = maps:get(set, Request0, undefined),
    Adapter = maps:get(adapter, Request0, undefined),
    Metrics = maps:get(metrics, Request0, undefined),
    Options = maps:get(options, Request0, #{}),
    Metadata0 = maps:get(metadata, Request0, #{}),
    case {Unknown, adk_eval_store:validate_scope(Scope),
          adk_eval_store:prepare_set(Set0), is_map(Adapter),
          valid_metrics_list(Metrics), is_map(Options),
          adk_eval_store:prepare_metadata(Metadata0)} of
        {[], ok, {ok, Set, SetId, SetVersion, _Digest}, true, true, true,
         {ok, Metadata}} ->
            Request = #{adapter => Adapter, metrics => Metrics,
                        options => Options, set => Set},
            case request_size(Request) of
                {ok, RequestBytes} ->
                    {ok, Scope, Request, RequestBytes, Set, SetId, SetVersion,
                     Metadata};
                {error, _} = Error -> Error
            end;
        {[_ | _], _, _, _, _, _, _} ->
            {error, {unknown_eval_request_fields, lists:sort(Unknown)}};
        {_, {error, _} = Error, _, _, _, _, _} -> Error;
        {_, _, {error, _} = Error, _, _, _, _} -> Error;
        {_, _, _, _, _, _, {error, _} = Error} -> Error;
        _ -> {error, invalid_eval_request}
    end;
prepare_request(_Scope, _Request) -> {error, invalid_eval_request}.

valid_metrics_list(Metrics) ->
    proper_list_within(Metrics, 0, 10000).

proper_list_within([], _Length, _Maximum) -> true;
proper_list_within([_Head | Tail], Length, Maximum)
  when Length < Maximum ->
    proper_list_within(Tail, Length + 1, Maximum);
proper_list_within(_List, _Length, _Maximum) -> false.

request_size(Request) ->
    Limits = #{max_depth => 64, max_nodes => 50000,
               max_binary_bytes => ?MAX_REQUEST_BYTES,
               max_total_binary_bytes => ?MAX_REQUEST_BYTES,
               max_list_length => 10000, max_map_size => 10000,
               max_external_bytes => ?MAX_REQUEST_BYTES},
    case adk_eval_limits:check(Request, Limits) of
        ok ->
            try erlang:external_size(Request) of
                Bytes -> {ok, Bytes}
            catch
                _:_ -> {error, invalid_eval_request_size}
            end;
        {error, Reason} ->
            {error, {evaluation_request_limit_exceeded,
                     request_limit_reason(Reason)}}
    end.

request_limit_reason({Tag, _}) when is_atom(Tag) -> Tag;
request_limit_reason({Tag, _, _}) when is_atom(Tag) -> Tag;
request_limit_reason(Tag) when is_atom(Tag) -> Tag.

admit(Entry, State0) ->
    Active = maps:get(active, State0),
    Max = maps:get(max_concurrency, maps:get(options, State0)),
    case map_size(Active) < Max of
        true -> start_entry(Entry, State0);
        false ->
            Queue0 = maps:get(queue, State0),
            MaxQueue = maps:get(max_queue, maps:get(options, State0)),
            Bytes = maps:get(bytes, Entry),
            QueuedBytes = maps:get(queued_bytes, State0),
            MaxQueueBytes = maps:get(
                              max_queue_bytes, maps:get(options, State0)),
            case queue:len(Queue0) < MaxQueue andalso
                 QueuedBytes + Bytes =< MaxQueueBytes of
                true ->
                    {ok, State0#{queue => queue:in(Entry, Queue0),
                                 queued_bytes => QueuedBytes + Bytes}};
                false -> {error, evaluation_queue_full, State0}
            end
    end.

admission_available(RequestBytes, State) ->
    Active = maps:get(active, State),
    Options = maps:get(options, State),
    case map_size(Active) < maps:get(max_concurrency, Options) of
        true -> true;
        false ->
            queue:len(maps:get(queue, State)) < maps:get(max_queue, Options)
            andalso maps:get(queued_bytes, State) + RequestBytes =<
                        maps:get(max_queue_bytes, Options)
    end.

start_entry(#{scope := Scope, job_id := JobId, request := Request} = Entry,
            State0) ->
    Options = maps:get(options, State0),
    case start_execution(Request, Options) of
        {ok, TaskKey, Runtime} ->
            Store = maps:get(store, State0),
            case store_call(Store, transition_job,
                            [Scope, JobId, [queued], running,
                             #{started_at => now_ms()}]) of
                {ok, _} ->
                    Active = maps:get(active, State0),
                    ActiveEntry = maps:merge(
                                    maps:without([request], Entry), Runtime),
                    {ok, State0#{active => Active#{TaskKey => ActiveEntry}}};
                {error, Reason} ->
                    _ = cancel_execution(
                          TaskKey, Runtime,
                          evaluation_store_transition_failed),
                    {error, Reason, State0}
            end;
        {error, Reason} ->
            {error, {evaluation_task_start_failed, safe_reason(Reason)}, State0}
    end.

start_execution(Request, #{worker := local} = Options) ->
    Work = fun() ->
        adk_eval_set:run(maps:get(adapter, Request), maps:get(set, Request),
                         maps:get(metrics, Request), maps:get(options, Request))
    end,
    TaskOptions = #{timeout => maps:get(task_timeout_ms, Options),
                    retention_ms => maps:get(task_retention_ms, Options),
                    notify => self(), owner => self(),
                    cancel_on_owner_down => true},
    case adk_task:start(Work, TaskOptions) of
        {ok, TaskRef} -> {ok, {local, TaskRef}, #{executor => local}};
        {error, _} = Error -> Error
    end;
start_execution(Request, #{worker := #{module := Module,
                                       config := Config0}} = Options) ->
    Config = Config0#{timeout_ms => maps:get(task_timeout_ms, Options)},
    try Module:start(Request, self(), Config) of
        {ok, Ref, Handle} when is_reference(Ref) ->
            {ok, {worker, Module, Ref},
             #{executor => worker, worker_module => Module,
               worker_handle => Handle}};
        {error, _} = Error -> Error;
        _ -> {error, invalid_eval_worker_start_reply}
    catch
        _:_ -> {error, eval_worker_start_failed}
    end.

start_queued(State0) ->
    Active = maps:get(active, State0),
    Max = maps:get(max_concurrency, maps:get(options, State0)),
    case map_size(Active) < Max of
        false -> {ok, State0};
        true ->
            case queue:out(maps:get(queue, State0)) of
                {empty, _} -> {ok, State0};
                {{value, Entry}, Queue} ->
                    State1 = State0#{
                               queue => Queue,
                               queued_bytes =>
                                   maps:get(queued_bytes, State0) -
                                   maps:get(bytes, Entry)},
                    case start_entry(Entry, State1) of
                        {ok, State2} -> start_queued(State2);
                        {error, Reason, State2} ->
                            case fail_queued(
                                   maps:get(store, State2),
                                   maps:get(scope, Entry),
                                   maps:get(job_id, Entry), Reason) of
                                {ok, _} -> start_queued(State2);
                                {error, PersistReason} ->
                                    {error,
                                     {evaluation_compensation_failed,
                                      safe_reason(PersistReason)}, State2}
                            end
                    end
            end
    end.

cancel_active(Scope, JobId, State0) ->
    case find_task(Scope, JobId, maps:get(active, State0)) of
        {ok, TaskKey, Entry} ->
            case cancel_execution(TaskKey, Entry, user_cancelled) of
                ok -> {reply, ok, State0};
                {error, already_terminal} -> {reply, ok, State0};
                {error, not_found} ->
                    cancel_missing_active(
                      TaskKey, Scope, JobId, State0);
                {error, Reason} -> {reply, {error, Reason}, State0}
            end;
        error ->
            Reply = transition_terminal(
                      maps:get(store, State0), Scope, JobId,
                      [running, queued], cancelled, <<"task_not_found">>),
            {reply, terminal_reply(Reply), State0}
    end.

cancel_missing_active(TaskRef, Scope, JobId, State0) ->
    Store = maps:get(store, State0),
    Reply = transition_terminal(
              Store, Scope, JobId, [running, queued], cancelled,
              <<"task_not_found">>),
    case Reply of
        {ok, _} ->
            finish_missing_active_cancel(TaskRef, State0, ok);
        {error, stale_phase} ->
            case store_call(Store, get_job, [Scope, JobId]) of
                {ok, #{phase := Phase}} ->
                    case adk_eval_store:terminal_phase(Phase) of
                        true -> finish_missing_active_cancel(
                                  TaskRef, State0,
                                  {error, {already_terminal, Phase}});
                        false -> cancel_persistence_stop(
                                   stale_phase, State0)
                    end;
                {error, Reason} -> cancel_persistence_stop(Reason, State0)
            end;
        {error, Reason} -> cancel_persistence_stop(Reason, State0)
    end.

finish_missing_active_cancel(TaskRef, State0, Reply) ->
    Active = maps:remove(TaskRef, maps:get(active, State0)),
    State1 = State0#{active => Active},
    case start_queued(State1) of
        {ok, State} -> {reply, Reply, State};
        {error, Reason, State} -> {stop, Reason, Reply, State}
    end.

cancel_persistence_stop(Reason, State) ->
    Failure = {evaluation_cancel_persistence_failed, safe_reason(Reason)},
    {stop, Failure, {error, Failure}, State}.

find_task(Scope, JobId, Active) ->
    maps:fold(fun(TaskKey, Entry, Acc) ->
        case Acc of
            {ok, _, _} -> Acc;
            error ->
                case maps:get(scope, Entry) =:= Scope andalso
                     maps:get(job_id, Entry) =:= JobId of
                    true -> {ok, TaskKey, Entry};
                    false -> error
                end
        end
    end, error, Active).

cancel_execution({local, TaskRef}, _Entry, Reason) ->
    adk_task:cancel(TaskRef, Reason);
cancel_execution({worker, Module, _Ref}, Entry, Reason) ->
    try Module:cancel(maps:get(worker_handle, Entry), Reason) of
        Reply -> Reply
    catch
        _:_ -> {error, eval_worker_cancel_failed}
    end;
%% Retain compatibility with pre-worker in-memory state during hot upgrades
%% and with the recovery-path regression fixture that injects a missing task.
cancel_execution(TaskRef, _Entry, Reason)
  when is_binary(TaskRef); is_reference(TaskRef) ->
    adk_task:cancel(TaskRef, Reason).

remove_queued(Scope, JobId, Queue0) ->
    {Removed, RemovedBytes, Items} = lists:foldl(
      fun(Entry, {Found, Bytes, Acc}) ->
          case not Found andalso maps:get(scope, Entry) =:= Scope andalso
               maps:get(job_id, Entry) =:= JobId of
              true -> {true, maps:get(bytes, Entry), Acc};
              false -> {Found, Bytes, [Entry | Acc]}
          end
      end, {false, 0, []}, queue:to_list(Queue0)),
    {Removed, RemovedBytes, queue:from_list(lists:reverse(Items))}.

persist_outcome(Store, Scope, JobId, {completed, {ok, Result}}) ->
    store_call(Store, transition_job,
               [Scope, JobId, [running], completed,
                #{result => Result, finished_at => now_ms()}]);
persist_outcome(Store, Scope, JobId, {completed, {error, Reason}}) ->
    transition_terminal(Store, Scope, JobId, [running], failed, Reason);
persist_outcome(Store, Scope, JobId, {failed, Reason}) ->
    transition_terminal(Store, Scope, JobId, [running], failed, Reason);
persist_outcome(Store, Scope, JobId, {timed_out, _Reason}) ->
    transition_terminal(Store, Scope, JobId, [running], timed_out,
                        <<"deadline_exceeded">>);
persist_outcome(Store, Scope, JobId, {cancelled, Reason}) ->
    transition_terminal(Store, Scope, JobId, [running], cancelled, Reason);
persist_outcome(Store, Scope, JobId, Outcome) ->
    transition_terminal(Store, Scope, JobId, [running], failed, Outcome).

transition_terminal(Store, Scope, JobId, Expected, Phase, Reason) ->
    store_call(Store, transition_job,
               [Scope, JobId, Expected, Phase,
                #{reason => safe_reason(Reason), finished_at => now_ms()}]).

fail_queued(Store, Scope, JobId, Reason) ->
    transition_terminal(Store, Scope, JobId, [queued], failed, Reason).

admission_failure_reply(Store, Scope, JobId, Reason, State) ->
    Failure = {evaluation_job_admission_failed,
               JobId, safe_reason(Reason)},
    case fail_queued(Store, Scope, JobId, Reason) of
        {ok, _} -> {reply, {error, Failure}, State};
        {error, PersistReason} ->
            StopReason = {evaluation_compensation_failed,
                          safe_reason(PersistReason)},
            {stop, StopReason, {error, Failure}, State}
    end.

terminal_reply({ok, _}) -> ok;
terminal_reply({error, _} = Error) -> Error.

store_call({Module, Handle}, Function, Args) ->
    try apply(Module, Function, [Handle | Args]) of
        Reply -> Reply
    catch
        Class:Reason ->
            {error, {eval_store_call_failed, Function,
                     safe_reason({Class, Reason})}}
    end.

call(Service, Request) ->
    try gen_server:call(Service, Request, ?CALL_TIMEOUT) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:Reason -> {error, {eval_service_unavailable, safe_reason(Reason)}}
    end.

generate_job_id() ->
    Random = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
    <<"eval-", Random/binary>>.

safe_reason(Reason) ->
    Redacted = adk_secret_redactor:redact(Reason),
    case adk_json:normalize(Redacted) of
        {ok, Binary} when is_binary(Binary), byte_size(Binary) > 0,
                          byte_size(Binary) =< 4096 -> Binary;
        {ok, Value} ->
            Encoded = iolist_to_binary(io_lib:format("~0p", [Value])),
            binary:part(Encoded, 0, min(byte_size(Encoded), 4096));
        {error, _} -> <<"evaluation_failed">>
    end.

now_ms() -> erlang:system_time(millisecond).
