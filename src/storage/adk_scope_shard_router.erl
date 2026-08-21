%% @doc Bounded exact-scope router shared by sharded artifact and memory APIs.
%%
%% The router performs only validation and worker lookup/startup. Calls are
%% made directly to the resolved adapter process, so unrelated exact scopes do
%% not serialize behind one storage GenServer. Each router owns an anonymous
%% dynamic supervisor and stops when its creator exits.
-module(adk_scope_shard_router).
-behaviour(gen_server).

-export([start_link/4, resolve/3, release/2,
         capabilities/1, status/1, stop/1,
         validate_adapter/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DEFAULT_ROUTE_TIMEOUT_MS, 5000).
-define(LEASE_CONTROL_TIMEOUT_MS, 1000).
-define(LEASE_HANDOFF_TIMEOUT_MS, 250).
-define(SHARED_SCOPE, '$adk_shared_scope_worker').

-record(state, {
    kind :: artifact | memory,
    adapter :: module(),
    adapter_config :: map(),
    capabilities :: map(),
    supervisor :: pid(),
    owner :: pid(),
    owner_monitor :: reference(),
    routing_table :: ets:tid(),
    route_admission :: atomics:atomics_ref(),
    max_active_scopes :: pos_integer(),
    max_router_queue :: pos_integer(),
    scope_strategy = exact_scope :: exact_scope | shared,
    idle_scope_timeout_ms :: pos_integer(),
    idle_reclamation = false :: boolean(),
    idle_evictions = 0 :: non_neg_integer(),
    scopes = #{} :: map(),
    monitor_to_scope = #{} :: map()
}).

-type handle() ::
    {adk_scope_shard, pid(), ets:tid(), atomics:atomics_ref(), pos_integer()}.
-type operation_lease() ::
    {adk_scope_operation_lease, pid(), reference()}.
-export_type([handle/0]).

-spec start_link(artifact | memory, module(), map(), map()) ->
    {ok, handle()} | {error, term()}.
start_link(Kind, Adapter, AdapterConfig, Options)
  when (Kind =:= artifact orelse Kind =:= memory), is_atom(Adapter),
       is_map(AdapterConfig), is_map(Options) ->
    Owner = self(),
    case validate_start_options(Options) of
        {ok, MaxScopes, MaxQueue, IdleTimeout, Strategy} ->
            case validate_adapter(Kind, Adapter) of
                ok ->
                    case valid_strategy_adapter(Strategy, Kind, Adapter) of
                        true ->
                            RouteAdmission = atomics:new(
                                               1, [{signed, true}]),
                            case gen_server:start_link(
                                   ?MODULE,
                                   {Owner, Kind, Adapter, AdapterConfig,
                                    MaxScopes, MaxQueue, IdleTimeout,
                                    Strategy, RouteAdmission}, []) of
                        {ok, Router} ->
                            case safe_call(Router, routing_table,
                                           ?DEFAULT_ROUTE_TIMEOUT_MS) of
                                {ok, RoutingTable} ->
                                    {ok, {adk_scope_shard, Router,
                                          RoutingTable, RouteAdmission,
                                          MaxQueue}};
                                {error, _} = Error ->
                                    _ = safe_stop(Router),
                                    Error
                            end;
                                {error, _} = Error -> Error
                            end;
                        false ->
                            {error, {invalid_scope_shard_config,
                                     unsupported_shared_adapter}}
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
start_link(_Kind, _Adapter, _AdapterConfig, _Options) ->
    {error, invalid_scope_shard_config}.

-spec resolve(handle(), term(), pos_integer()) ->
    {ok, module(), pid(), operation_lease()} | {error, term()}.
resolve({adk_scope_shard, Router, RoutingTable, RouteAdmission, MaxQueue},
        Scope, Timeout)
  when is_pid(Router), is_integer(MaxQueue), MaxQueue > 0,
       is_integer(Timeout), Timeout > 0 ->
    case cached_worker(RoutingTable, Scope) of
        {ok, Adapter, Worker, WorkerLease} ->
            case start_operation_lease(WorkerLease, self()) of
                {ok, OperationLease} ->
                    {ok, Adapter, Worker, OperationLease};
                {error, worker_lease_unavailable} ->
                    resolve_through_router(
                      Router, Scope, Timeout, RouteAdmission, MaxQueue);
                {error, _} = Error -> Error
            end;
        miss ->
            resolve_through_router(
              Router, Scope, Timeout, RouteAdmission, MaxQueue)
    end;
resolve(_Handle, _Scope, _Timeout) ->
    {error, invalid_scope_shard_handle}.

%% @doc Release the exact per-operation lease returned by resolve/3. Passing
%% the token rather than looking it up by scope prevents a crashed worker's
%% late cleanup from decrementing a replacement worker's lease.
-spec release(handle(), term()) -> ok.
release({adk_scope_shard, _Router, _RoutingTable,
         _RouteAdmission, _MaxQueue},
        {adk_scope_operation_lease, _Guard, _Ref} = Lease) ->
    release_operation_lease(Lease);
release({adk_scope_shard, _Router, _RoutingTable,
         _RouteAdmission, _MaxQueue}, WorkerLease) ->
    %% Compatibility for a lease returned before an in-place code upgrade.
    safe_release_worker_lease(WorkerLease);
release(_Handle, _Scope) -> ok.

-spec capabilities(handle()) -> {ok, map()} | {error, term()}.
capabilities({adk_scope_shard, Router, _RoutingTable,
              _RouteAdmission, _MaxQueue})
  when is_pid(Router) ->
    safe_call(Router, capabilities, ?DEFAULT_ROUTE_TIMEOUT_MS);
capabilities(_Handle) ->
    {error, invalid_scope_shard_handle}.

-spec status(handle()) -> {ok, map()} | {error, term()}.
status({adk_scope_shard, Router, _RoutingTable,
        _RouteAdmission, _MaxQueue})
  when is_pid(Router) ->
    safe_call(Router, status, ?DEFAULT_ROUTE_TIMEOUT_MS);
status(_Handle) ->
    {error, invalid_scope_shard_handle}.

-spec stop(handle()) -> ok | {error, term()}.
stop({adk_scope_shard, Router, _RoutingTable,
      _RouteAdmission, _MaxQueue})
  when is_pid(Router) ->
    safe_stop(Router);
stop(_Handle) ->
    {error, invalid_scope_shard_handle}.

-spec validate_adapter(artifact | memory, module()) -> ok | {error, term()}.
validate_adapter(Kind, Adapter) when is_atom(Adapter) ->
    case code:ensure_loaded(Adapter) of
        {module, Adapter} ->
            Required = required_callbacks(Kind),
            Missing = [{Function, Arity}
                       || {Function, Arity} <- Required,
                          not erlang:function_exported(
                                Adapter, Function, Arity)],
            case Missing of
                [] -> ok;
                _ -> {error, {invalid_scope_shard_adapter,
                              Adapter, {missing_callbacks, Missing}}}
            end;
        {error, Reason} ->
            {error, {invalid_scope_shard_adapter,
                     Adapter, {module_unavailable, Reason}}}
    end;
validate_adapter(_Kind, Adapter) ->
    {error, {invalid_scope_shard_adapter, Adapter}}.

init({Owner, Kind, Adapter, AdapterConfig, MaxScopes, MaxQueue,
      IdleTimeout, Strategy, RouteAdmission}) ->
    process_flag(trap_exit, true),
    OwnerMonitor = erlang:monitor(process, Owner),
    RoutingTable = ets:new(?MODULE, [set, protected,
                                     {read_concurrency, true}]),
    case adk_scope_shard_sup:start_link() of
        {ok, Supervisor} ->
            case probe_capabilities(
                   Kind, Supervisor, Adapter, AdapterConfig) of
                {ok, Capabilities} ->
                    State0 = #state{
                               kind = Kind,
                               adapter = Adapter,
                               adapter_config = AdapterConfig,
                               capabilities = Capabilities,
                               supervisor = Supervisor,
                               owner = Owner,
                               owner_monitor = OwnerMonitor,
                               routing_table = RoutingTable,
                               route_admission = RouteAdmission,
                               max_active_scopes =
                                   effective_max_scopes(
                                     Strategy, MaxScopes),
                               max_router_queue = MaxQueue,
                               scope_strategy = Strategy,
                               idle_scope_timeout_ms = IdleTimeout,
                               idle_reclamation =
                                   durable_adapter(Kind, Capabilities)},
                    initialize_strategy(State0);
                {error, Reason} ->
                    exit(Supervisor, shutdown),
                    {stop, Reason}
            end;
        {error, Reason} ->
            {stop, {scope_shard_supervisor_start_failed, Reason}}
    end.

handle_call(capabilities, _From, State) ->
    {reply, {ok, public_capabilities(State)}, State};
handle_call(routing_table, _From, State) ->
    {reply, {ok, State#state.routing_table}, State};
handle_call(status, _From, State) ->
    ColdRoutesInFlight = atomics:get(State#state.route_admission, 1),
    Status = #{status => running,
               kind => State#state.kind,
               adapter => State#state.adapter,
               active_scopes => map_size(State#state.scopes),
               max_active_scopes => State#state.max_active_scopes,
               idle_scope_timeout_ms => State#state.idle_scope_timeout_ms,
               idle_reclamation => State#state.idle_reclamation,
               idle_evictions => State#state.idle_evictions,
               cold_routes_in_flight => ColdRoutesInFlight,
               max_router_queue => State#state.max_router_queue,
               cold_route_admission => strict_atomic,
               routing => State#state.scope_strategy,
               worker_supervision => per_instance_dynamic,
               global_quota => State#state.scope_strategy =:= shared},
    {reply, {ok, Status}, State};
handle_call({resolve, Scope, Caller}, {LeaseOwner, _Tag}, State0)
  when is_pid(Caller), is_pid(LeaseOwner) ->
    resolve_scope(Scope, Caller, LeaseOwner, infinity, State0);
handle_call({resolve, Scope, Caller, LeaseOwner}, _From, State0)
  when is_pid(Caller), is_pid(LeaseOwner) ->
    resolve_scope(Scope, Caller, LeaseOwner, infinity, State0);
handle_call({resolve, Scope, Caller, LeaseOwner, Deadline}, _From, State0)
  when is_pid(Caller), is_pid(LeaseOwner), is_integer(Deadline) ->
    resolve_scope(Scope, Caller, LeaseOwner, Deadline, State0);
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_scope_router_request}, State}.

resolve_scope(Scope, Caller, LeaseOwner, Deadline, State0) ->
    %% A cold-route guard monitors the original caller. Its queued request may
    %% still reach us after that caller dies, so recheck ownership before
    %% starting a scope worker and avoid creating abandoned shards.
    case route_request_status(Caller, LeaseOwner, Deadline) of
        {error, Reason} -> {reply, {error, Reason}, State0};
        ok ->
            case validate_scope(State0#state.kind, Scope) of
                ok ->
                    case live_worker(Scope, LeaseOwner, State0) of
                        {ok, Pid, OperationLease, State1} ->
                            case route_deadline_valid(Deadline) of
                                true ->
                                    {reply,
                                     {ok, State1#state.adapter, Pid,
                                      OperationLease}, State1};
                                false ->
                                    release_operation_lease(OperationLease),
                                    {reply, {error, timeout}, State1}
                            end;
                        {start, State1} ->
                            start_scope_worker(
                              Scope, LeaseOwner, Deadline, State1);
                        {error, Reason, State1} ->
                            {reply, {error, Reason}, State1}
                    end;
                {error, _} = Error ->
                    {reply, Error, State0}
            end
    end.

route_request_status(Caller, LeaseOwner, Deadline) ->
    case route_deadline_valid(Deadline) of
        false -> {error, timeout};
        true ->
            case is_process_alive(Caller) andalso
                 is_process_alive(LeaseOwner) of
                true -> ok;
                false -> {error, scope_route_caller_unavailable}
            end
    end.

route_deadline_valid(infinity) -> true;
route_deadline_valid(Deadline) ->
    erlang:monotonic_time(millisecond) < Deadline.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason},
            #state{owner_monitor = Ref} = State) ->
    {stop, normal, State};
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State0) ->
    case maps:take(Ref, State0#state.monitor_to_scope) of
        {Scope, MonitorToScope} ->
            Scopes = maps:remove(Scope, State0#state.scopes),
            true = ets:delete(State0#state.routing_table, Scope),
            {noreply, State0#state{scopes = Scopes,
                                   monitor_to_scope = MonitorToScope}};
        error ->
            {noreply, State0}
    end;
handle_info({'EXIT', Supervisor, Reason},
            #state{supervisor = Supervisor} = State) ->
    {stop, {scope_shard_supervisor_down, Reason}, State};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    erlang:demonitor(State#state.owner_monitor, [flush]),
    lists:foreach(
      fun(#{monitor := Ref}) -> erlang:demonitor(Ref, [flush]) end,
      maps:values(State#state.scopes)),
    stop_supervisor(State#state.supervisor),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

validate_start_options(Options) ->
    Allowed = [max_active_scopes, max_router_queue,
               idle_scope_timeout_ms, scope_strategy],
    Unknown = lists:sort(maps:keys(maps:without(Allowed, Options))),
    MaxScopes = maps:get(max_active_scopes, Options, 1024),
    MaxQueue = maps:get(max_router_queue, Options, 256),
    IdleTimeout = maps:get(idle_scope_timeout_ms, Options, 60000),
    Strategy = maps:get(scope_strategy, Options, exact_scope),
    ValidIdle = positive_integer(IdleTimeout) andalso
                IdleTimeout =< 86400000,
    ValidStrategy = Strategy =:= exact_scope orelse Strategy =:= shared,
    case {Unknown, positive_integer(MaxScopes), positive_integer(MaxQueue),
          ValidIdle, ValidStrategy} of
        {[], true, true, true, true} ->
            {ok, MaxScopes, MaxQueue, IdleTimeout, Strategy};
        {[_ | _], _, _, _, _} ->
            {error, {invalid_scope_shard_config,
                     {unknown_keys, Unknown}}};
        {[], false, _, _, _} ->
            {error, {invalid_scope_shard_config, max_active_scopes}};
        {[], _, false, _, _} ->
            {error, {invalid_scope_shard_config, max_router_queue}};
        {[], _, _, false, _} ->
            {error, {invalid_scope_shard_config,
                     idle_scope_timeout_ms}};
        {[], _, _, _, false} ->
            {error, {invalid_scope_shard_config, scope_strategy}}
    end.

positive_integer(Value) -> is_integer(Value) andalso Value > 0.

required_callbacks(artifact) ->
    [{start_link, 1}, {stop, 1}, {capabilities, 1},
     {put, 5}, {put, 6}, {get, 4}, {get, 5}, {list, 2},
     {list_names, 3}, {list_versions, 4}, {delete, 4}, {delete, 5}];
required_callbacks(memory) ->
    [{start_link, 1}, {stop, 1}, {capabilities, 1},
     {add_entry, 4}, {add_entry, 5}, {add_events, 5}, {add_events, 6},
     {add_session_to_memory, 5}, {search, 4}, {search, 5},
     {delete_entry, 3}, {delete_entry, 4},
     {delete_session, 3}, {delete_session, 4},
     {delete_user, 2}, {delete_user, 3}].

probe_capabilities(Kind, Supervisor, Adapter, AdapterConfig) ->
    ProbeScope = probe_scope(Kind),
    Config = scope_adapter_config(Kind, Adapter, AdapterConfig, ProbeScope),
    case adk_scope_shard_sup:start_adapter(Supervisor, Adapter, Config) of
        {ok, Pid, ChildId} ->
            Result = adapter_capabilities(Kind, Adapter, Pid),
            ok = adk_scope_shard_sup:stop_adapter(Supervisor, ChildId),
            Result;
        {error, Reason} ->
            {error, {scope_shard_adapter_config_invalid, Reason}}
    end.

initialize_strategy(State = #state{scope_strategy = exact_scope}) ->
    {ok, State};
initialize_strategy(State = #state{scope_strategy = shared}) ->
    %% The eagerly-started shared worker has no operation borrower yet.
    case start_shared_worker(State) of
        {ok, State1} -> {ok, State1};
        {error, Reason} -> {stop, Reason}
    end.

valid_strategy_adapter(exact_scope, _Kind, _Adapter) -> true;
valid_strategy_adapter(shared, artifact, adk_artifact_ets) -> true;
valid_strategy_adapter(shared, memory, adk_memory_ets) -> true;
valid_strategy_adapter(_Strategy, _Kind, _Adapter) -> false.

effective_max_scopes(shared, _Configured) -> 1;
effective_max_scopes(exact_scope, Configured) -> Configured.

probe_scope(artifact) ->
    {session, <<"$adk-capability-probe">>, <<"probe">>, <<"probe">>};
probe_scope(memory) ->
    {user, <<"$adk-capability-probe">>, <<"probe">>}.

adapter_capabilities(artifact, Adapter, Pid) ->
    try Adapter:capabilities(Pid) of
        {ok, Capabilities} when is_map(Capabilities) ->
            {ok, Capabilities};
        _ -> {error, invalid_artifact_adapter_capabilities}
    catch
        _:_ -> {error, artifact_adapter_capabilities_failed}
    end;
adapter_capabilities(memory, Adapter, Pid) ->
    try Adapter:capabilities(Pid) of
        Capabilities when is_map(Capabilities) -> {ok, Capabilities};
        _ -> {error, invalid_memory_adapter_capabilities}
    catch
        _:_ -> {error, memory_adapter_capabilities_failed}
    end.

validate_scope(artifact, Scope) ->
    adk_artifact_core:validate_scope(Scope);
validate_scope(memory, Scope) ->
    case adk_memory_contract:validate_scope(Scope) of
        {ok, _Canonical} -> ok;
        {error, _} = Error -> Error
    end.

live_worker(_Scope, LeaseOwner,
            State0 = #state{scope_strategy = shared}) ->
    live_worker_key(?SHARED_SCOPE, LeaseOwner, State0);
live_worker(Scope, LeaseOwner, State0) ->
    live_worker_key(Scope, LeaseOwner, State0).

live_worker_key(Scope, LeaseOwner, State0) ->
    case maps:find(Scope, State0#state.scopes) of
        {ok, #{pid := Pid, lease := WorkerLease}} ->
            case is_process_alive(Pid) of
                true ->
                    case start_operation_lease(
                           WorkerLease, LeaseOwner) of
                        {ok, OperationLease} ->
                            {ok, Pid, OperationLease, State0};
                        {error, worker_lease_unavailable} ->
                            {start, evict_scope(Scope, State0)};
                        {error, Reason} ->
                            {error, Reason, State0}
                    end;
                false ->
                    {start, remove_scope(Scope, State0)}
            end;
        error -> {start, State0}
    end.

remove_scope(Scope, State0) ->
    case maps:take(Scope, State0#state.scopes) of
        {#{monitor := Ref}, Scopes} ->
            erlang:demonitor(Ref, [flush]),
            true = ets:delete(State0#state.routing_table, Scope),
            State0#state{scopes = Scopes,
                         monitor_to_scope =
                             maps:remove(Ref, State0#state.monitor_to_scope)};
        error -> State0
    end.

start_scope_worker(_Scope, LeaseOwner, Deadline,
                   State = #state{scope_strategy = shared}) ->
    case start_shared_worker(State) of
        {ok, State1} ->
            #{pid := Pid, lease := WorkerLease} =
                maps:get(?SHARED_SCOPE, State1#state.scopes),
            reply_with_operation_lease(
              State1#state.adapter, Pid, WorkerLease,
              LeaseOwner, Deadline, keep_worker, State1);
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
start_scope_worker(Scope, LeaseOwner, Deadline, State) ->
    State0 = reclaim_idle_scope(State),
    case map_size(State0#state.scopes) < State0#state.max_active_scopes of
        false ->
            {reply, {error, max_active_scopes_reached}, State0};
        true ->
            Config = scope_adapter_config(
                       State0#state.kind, State0#state.adapter,
                       State0#state.adapter_config, Scope),
            case adk_scope_shard_sup:start_adapter(
                   State0#state.supervisor, State0#state.adapter, Config) of
                {ok, Pid, ChildId} ->
                    Ref = erlang:monitor(process, Pid),
                    WorkerLease = new_worker_lease(0),
                    Entry = #{pid => Pid, child_id => ChildId,
                              monitor => Ref, lease => WorkerLease},
                    Scopes = (State0#state.scopes)#{Scope => Entry},
                    MonitorToScope =
                        (State0#state.monitor_to_scope)#{Ref => Scope},
                    true = ets:insert(State0#state.routing_table,
                                      {Scope, State0#state.adapter,
                                       Pid, WorkerLease}),
                    State1 = State0#state{
                               scopes = Scopes,
                               monitor_to_scope = MonitorToScope},
                    reply_with_operation_lease(
                      State0#state.adapter, Pid, WorkerLease,
                      LeaseOwner, Deadline, {evict_worker, Scope}, State1);
                {error, Reason} ->
                    {reply, {error, {scope_shard_start_failed, Reason}},
                     State0}
            end
    end.

start_shared_worker(State0) ->
    case adk_scope_shard_sup:start_adapter(
           State0#state.supervisor, State0#state.adapter,
           State0#state.adapter_config) of
        {ok, Pid, ChildId} ->
            Ref = erlang:monitor(process, Pid),
            WorkerLease = new_worker_lease(0),
            Entry = #{pid => Pid, child_id => ChildId,
                      monitor => Ref, lease => WorkerLease},
            true = ets:insert(
                     State0#state.routing_table,
                     {?SHARED_SCOPE, State0#state.adapter, Pid,
                      WorkerLease}),
            {ok, State0#state{
                   scopes = (State0#state.scopes)#{?SHARED_SCOPE => Entry},
                   monitor_to_scope =
                       (State0#state.monitor_to_scope)#{Ref =>
                                                           ?SHARED_SCOPE}}};
        {error, Reason} ->
            {error, {scope_shard_start_failed, Reason}}
    end.

reply_with_operation_lease(Adapter, Pid, WorkerLease, LeaseOwner,
                           Deadline, FailureAction, State) ->
    case route_request_status(LeaseOwner, LeaseOwner, Deadline) of
        {error, Reason} ->
            operation_lease_failure_reply(Reason, FailureAction, State);
        ok ->
            case start_operation_lease(WorkerLease, LeaseOwner) of
                {ok, OperationLease} ->
                    case route_deadline_valid(Deadline) of
                        true ->
                            {reply, {ok, Adapter, Pid, OperationLease},
                             State};
                        false ->
                            release_operation_lease(OperationLease),
                            operation_lease_failure_reply(
                              timeout, FailureAction, State)
                    end;
                {error, Reason} ->
                    operation_lease_failure_reply(
                      Reason, FailureAction, State)
            end
    end.

operation_lease_failure_reply(Reason, keep_worker, State) ->
    {reply, {error, Reason}, State};
operation_lease_failure_reply(Reason, {evict_worker, Scope}, State) ->
    {reply, {error, Reason}, evict_scope(Scope, State)}.

reclaim_idle_scope(State = #state{idle_reclamation = false}) -> State;
reclaim_idle_scope(State = #state{scopes = Scopes,
                                  max_active_scopes = Max})
  when map_size(Scopes) < Max -> State;
reclaim_idle_scope(State0) ->
    Now = erlang:monotonic_time(millisecond),
    IdleTimeout = State0#state.idle_scope_timeout_ms,
    Candidates = lists:sort(
                   [{atomics:get(maps:get(lease, Entry), 3), Scope}
                    || {Scope, Entry} <- maps:to_list(State0#state.scopes)]),
    reclaim_idle_candidate(Candidates, Now, IdleTimeout, State0).

reclaim_idle_candidate([], _Now, _IdleTimeout, State) -> State;
reclaim_idle_candidate([{LastAccess, Scope} | Rest], Now, IdleTimeout,
                       State0) ->
    case LastAccess + IdleTimeout =< Now of
        false -> State0;
        true ->
            Entry = maps:get(Scope, State0#state.scopes),
            Lease = maps:get(lease, Entry),
            case claim_idle_lease(Lease, LastAccess, Now, IdleTimeout) of
                true ->
                    State1 = evict_scope(Scope, State0),
                    State1#state{
                      idle_evictions = State1#state.idle_evictions + 1};
                false ->
                    reclaim_idle_candidate(
                      Rest, Now, IdleTimeout, State0)
            end
    end.

claim_idle_lease(Lease, ExpectedLast, Now, IdleTimeout) ->
    case atomics:compare_exchange(Lease, 1, 0, 1) of
        ok ->
            Idle = atomics:get(Lease, 2) =:= 0 andalso
                   atomics:get(Lease, 3) =:= ExpectedLast andalso
                   ExpectedLast + IdleTimeout =< Now,
            case Idle of
                true -> true;
                false ->
                    atomics:put(Lease, 1, 0),
                    false
            end;
        _ -> false
    end.

evict_scope(Scope, State0) ->
    case maps:take(Scope, State0#state.scopes) of
        {#{monitor := Ref, child_id := ChildId}, Scopes} ->
            true = ets:delete(State0#state.routing_table, Scope),
            erlang:demonitor(Ref, [flush]),
            _ = adk_scope_shard_sup:stop_adapter(
                  State0#state.supervisor, ChildId),
            State0#state{
              scopes = Scopes,
              monitor_to_scope = maps:remove(
                                   Ref, State0#state.monitor_to_scope)};
        error -> State0
    end.

scope_adapter_config(artifact, adk_artifact_fs, Config, Scope) ->
    case maps:find(root, Config) of
        {ok, Root} ->
            Config#{root => filename:join(
                              normalize_root_for_join(Root),
                              ["scope-shards", scope_hash(Scope)])};
        error -> Config
    end;
scope_adapter_config(_Kind, _Adapter, Config, _Scope) ->
    Config.

normalize_root_for_join(Root) when is_binary(Root) ->
    binary_to_list(Root);
normalize_root_for_join(Root) -> Root.

scope_hash(Scope) ->
    binary_to_list(
      binary:encode_hex(
        crypto:hash(sha256, term_to_binary(Scope)), lowercase)).

public_capabilities(#state{kind = artifact} = State) ->
    Base = maps:with(
             [api_version, immutable_versions, scopes, pagination,
              deadlines, cancellation, persistence, atomic_publication,
              recovery, validation_limits], State#state.capabilities),
    AdapterQuotas = maps:get(quotas, State#state.capabilities, #{}),
    Shared = State#state.scope_strategy =:= shared,
    QuotaScope = quota_scope(Shared),
    Base#{adapter => State#state.adapter,
          sharding => sharding_capabilities(State),
          quotas => #{enforcement_scope => QuotaScope,
                      global_quota => Shared,
                      adapter_instance_limits => AdapterQuotas}};
public_capabilities(#state{kind = memory} = State) ->
    Base = maps:with(
             [contract_version, scope, durable, search,
              idempotent_ingestion, incremental_events,
              erasure_epoch_fencing, delete, limits],
             State#state.capabilities),
    Shared = State#state.scope_strategy =:= shared,
    Base#{adapter => State#state.adapter,
          sharding => sharding_capabilities(State),
          quota_scope => quota_scope(Shared),
          global_quota => Shared}.

quota_scope(true) -> shared_adapter;
quota_scope(false) -> exact_scope_shard.

sharding_capabilities(State) ->
    #{strategy => State#state.scope_strategy,
      same_scope_worker => stable,
      resolved_scope_execution => direct_concurrent,
      cold_scope_startup => router_serialized,
      cold_route_admission => strict_atomic,
      max_active_scopes => State#state.max_active_scopes,
      max_router_queue => State#state.max_router_queue,
      idle_scope_timeout_ms => State#state.idle_scope_timeout_ms,
      idle_reclamation => case {State#state.scope_strategy,
                                State#state.idle_reclamation} of
          {shared, _} -> not_required_shared_adapter;
          {exact_scope, true} -> lru_on_capacity;
          {exact_scope, false} -> disabled_for_volatile_adapter
      end,
      supervision => per_instance_dynamic}.

durable_adapter(artifact, Capabilities) ->
    maps:get(persistence, Capabilities, volatile) =/= volatile;
durable_adapter(memory, Capabilities) ->
    maps:get(durable, Capabilities, false) =:= true.

safe_call(Router, Request, Timeout) ->
    try gen_server:call(Router, Request, Timeout) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, scope_router_unavailable};
        exit:{normal, _} -> {error, scope_router_unavailable};
        exit:_ -> {error, scope_router_unavailable}
    end.

cached_worker(RoutingTable, Scope) ->
    try lookup_route(RoutingTable, Scope) of
        {ok, Adapter, Worker, WorkerLease} ->
            case is_process_alive(Worker) of
                true -> {ok, Adapter, Worker, WorkerLease};
                false -> miss
            end;
        miss -> miss
    catch
        error:badarg -> miss
    end.

lookup_route(RoutingTable, Scope) ->
    case ets:lookup(RoutingTable, Scope) of
        [{Scope, Adapter, Worker, Lease}] ->
            {ok, Adapter, Worker, Lease};
        [] ->
            case ets:lookup(RoutingTable, ?SHARED_SCOPE) of
                [{?SHARED_SCOPE, Adapter, Worker, Lease}] ->
                    {ok, Adapter, Worker, Lease};
                [] -> miss
            end
    end.

new_worker_lease(InitialLeases) ->
    Lease = atomics:new(3, [{signed, true}]),
    atomics:put(Lease, 2, InitialLeases),
    atomics:put(Lease, 3, erlang:monotonic_time(millisecond)),
    Lease.

acquire_worker_lease(Lease) ->
    case atomics:get(Lease, 1) of
        0 ->
            _ = atomics:add_get(Lease, 2, 1),
            case atomics:get(Lease, 1) of
                0 ->
                    atomics:put(
                      Lease, 3, erlang:monotonic_time(millisecond)),
                    true;
                _Evicting ->
                    _ = atomics:add_get(Lease, 2, -1),
                    false
            end;
        _Evicting -> false
    end.

release_worker_lease(Lease) ->
    Current = atomics:get(Lease, 2),
    case Current =< 0 of
        true -> ok;
        false ->
            case atomics:compare_exchange(
                   Lease, 2, Current, Current - 1) of
                ok ->
                    atomics:put(
                      Lease, 3, erlang:monotonic_time(millisecond)),
                    ok;
                _Actual -> release_worker_lease(Lease)
            end
    end.

safe_release_worker_lease(Lease) ->
    try release_worker_lease(Lease)
    catch
        error:badarg -> ok
    end.

%% Each operation lease is owned by a tiny monitor process. It performs the
%% worker-lease increment itself, so there is no kill window between acquiring
%% the counter and installing the borrower monitor. Either an explicit release
%% or borrower DOWN decrements the worker lease exactly once.
start_operation_lease(WorkerLease, Borrower) when is_pid(Borrower) ->
    Coordinator = self(),
    TokenRef = make_ref(),
    {Guard, GuardMonitor} = spawn_monitor(
      fun() ->
          operation_lease_init(
            Coordinator, TokenRef, WorkerLease, Borrower)
      end),
    receive
        {operation_lease_ready, TokenRef, Guard} ->
            erlang:demonitor(GuardMonitor, [flush]),
            {ok, {adk_scope_operation_lease, Guard, TokenRef}};
        {operation_lease_unavailable, TokenRef, Guard} ->
            erlang:demonitor(GuardMonitor, [flush]),
            {error, worker_lease_unavailable};
        {'DOWN', GuardMonitor, process, Guard, _Reason} ->
            {error, operation_lease_guard_unavailable}
    after ?LEASE_CONTROL_TIMEOUT_MS ->
        Guard ! {cancel_operation_lease, TokenRef},
        await_operation_guard_down(Guard, GuardMonitor),
        {error, operation_lease_timeout}
    end.

operation_lease_init(Coordinator, TokenRef, WorkerLease, Borrower) ->
    BorrowerMonitor = erlang:monitor(process, Borrower),
    case acquire_worker_lease(WorkerLease) of
        true ->
            Coordinator ! {operation_lease_ready, TokenRef, self()},
            operation_lease_loop(
              TokenRef, WorkerLease, Borrower, BorrowerMonitor);
        false ->
            erlang:demonitor(BorrowerMonitor, [flush]),
            Coordinator ! {operation_lease_unavailable, TokenRef, self()}
    end.

operation_lease_loop(TokenRef, WorkerLease, Borrower, BorrowerMonitor) ->
    receive
        {release_operation_lease, TokenRef, Requester, AckRef} ->
            safe_release_worker_lease(WorkerLease),
            Requester ! {operation_lease_released, AckRef, self()};
        {transfer_operation_lease, TokenRef, Borrower, NewBorrower,
         Requester, AckRef} when is_pid(NewBorrower) ->
            NewMonitor = erlang:monitor(process, NewBorrower),
            erlang:demonitor(BorrowerMonitor, [flush]),
            Requester ! {operation_lease_transferred, AckRef, self()},
            operation_lease_loop(
              TokenRef, WorkerLease, NewBorrower, NewMonitor);
        {transfer_operation_lease, TokenRef, _WrongBorrower, _NewBorrower,
         Requester, AckRef} ->
            Requester ! {operation_lease_transfer_rejected, AckRef, self()},
            operation_lease_loop(
              TokenRef, WorkerLease, Borrower, BorrowerMonitor);
        {cancel_operation_lease, TokenRef} ->
            safe_release_worker_lease(WorkerLease);
        {'DOWN', BorrowerMonitor, process, Borrower, _Reason} ->
            safe_release_worker_lease(WorkerLease);
        _Other ->
            operation_lease_loop(
              TokenRef, WorkerLease, Borrower, BorrowerMonitor)
    end.

release_operation_lease(
  {adk_scope_operation_lease, Guard, TokenRef})
  when is_pid(Guard), is_reference(TokenRef) ->
    Requester = self(),
    AckRef = make_ref(),
    GuardMonitor = erlang:monitor(process, Guard),
    Guard ! {release_operation_lease, TokenRef, Requester, AckRef},
    receive
        {operation_lease_released, AckRef, Guard} ->
            erlang:demonitor(GuardMonitor, [flush]),
            ok;
        {'DOWN', GuardMonitor, process, Guard, _Reason} -> ok
    after ?LEASE_CONTROL_TIMEOUT_MS ->
        erlang:demonitor(GuardMonitor, [flush]),
        ok
    end;
release_operation_lease(_Lease) -> ok.

transfer_operation_lease(
  {adk_scope_operation_lease, Guard, TokenRef},
  CurrentBorrower, NewBorrower)
  when is_pid(Guard), is_reference(TokenRef), is_pid(CurrentBorrower),
       is_pid(NewBorrower) ->
    Requester = self(),
    AckRef = make_ref(),
    GuardMonitor = erlang:monitor(process, Guard),
    Guard ! {transfer_operation_lease, TokenRef, CurrentBorrower,
             NewBorrower, Requester, AckRef},
    receive
        {operation_lease_transferred, AckRef, Guard} ->
            erlang:demonitor(GuardMonitor, [flush]),
            ok;
        {operation_lease_transfer_rejected, AckRef, Guard} ->
            erlang:demonitor(GuardMonitor, [flush]),
            {error, operation_lease_transfer_rejected};
        {'DOWN', GuardMonitor, process, Guard, _Reason} ->
            {error, operation_lease_guard_unavailable}
    after ?LEASE_CONTROL_TIMEOUT_MS ->
        erlang:demonitor(GuardMonitor, [flush]),
        {error, operation_lease_transfer_timeout}
    end.

await_operation_guard_down(Guard, GuardMonitor) ->
    receive
        {'DOWN', GuardMonitor, process, Guard, _Reason} -> ok
    after ?LEASE_CONTROL_TIMEOUT_MS ->
        erlang:demonitor(GuardMonitor, [flush]),
        ok
    end.

resolve_through_router(Router, Scope, Timeout, RouteAdmission, MaxQueue) ->
    Caller = self(),
    ReplyRef = make_ref(),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    {Guard, GuardMonitor} = spawn_monitor(
      fun() ->
          cold_route_guard(Caller, ReplyRef, Router, Scope, Deadline,
                           RouteAdmission, MaxQueue)
      end),
    receive
        {scope_route_result, ReplyRef, Guard,
         {ok, _Adapter, _Worker, OperationLease} = Reply} ->
            complete_cold_route_handoff(
              Guard, GuardMonitor, ReplyRef, OperationLease, Reply);
        {scope_route_result, ReplyRef, Guard, Reply} ->
            erlang:demonitor(GuardMonitor, [flush]),
            Reply;
        {'DOWN', GuardMonitor, process, Guard, Reason} ->
            {error, {scope_route_guard_down, Reason}}
    after Timeout + 250 ->
        %% The guard owns and eventually releases any permit. Do not kill it:
        %% an untrappable kill would skip its after-clause. It independently
        %% monitors this caller and has the same bounded route deadline.
        erlang:demonitor(GuardMonitor, [flush]),
        {error, timeout}
    end.

complete_cold_route_handoff(Guard, GuardMonitor, ReplyRef,
                            OperationLease, Reply) ->
    Guard ! {scope_route_accept, ReplyRef, self()},
    receive
        {scope_route_accepted, ReplyRef, Guard} ->
            erlang:demonitor(GuardMonitor, [flush]),
            Reply;
        {scope_route_rejected, ReplyRef, Guard, Reason} ->
            erlang:demonitor(GuardMonitor, [flush]),
            release_operation_lease(OperationLease),
            {error, Reason};
        {'DOWN', GuardMonitor, process, Guard, Reason} ->
            release_operation_lease(OperationLease),
            {error, {scope_route_guard_down, Reason}}
    after ?LEASE_HANDOFF_TIMEOUT_MS ->
        Guard ! {scope_route_abort, ReplyRef, self()},
        erlang:demonitor(GuardMonitor, [flush]),
        release_operation_lease(OperationLease),
        {error, timeout}
    end.

cold_route_guard(Caller, ReplyRef, Router, Scope, Deadline,
                 RouteAdmission, MaxQueue) ->
    CallerMonitor = erlang:monitor(process, Caller),
    case acquire_route_permit(RouteAdmission, MaxQueue) of
        false ->
            erlang:demonitor(CallerMonitor, [flush]),
            Caller ! {scope_route_result, ReplyRef, self(),
                      {error, scope_router_overloaded}};
        true ->
            try
                guarded_router_call(Caller, CallerMonitor, ReplyRef, Router,
                                    Scope, Deadline)
            after
                _ = atomics:add_get(RouteAdmission, 1, -1)
            end
    end.

acquire_route_permit(RouteAdmission, MaxQueue) ->
    Current = atomics:get(RouteAdmission, 1),
    case Current >= MaxQueue of
        true -> false;
        false ->
            case atomics:compare_exchange(
                   RouteAdmission, 1, Current, Current + 1) of
                ok -> true;
                _Actual -> acquire_route_permit(RouteAdmission, MaxQueue)
            end
    end.

guarded_router_call(Caller, CallerMonitor, ReplyRef, Router, Scope,
                    Deadline) ->
    case remaining_route_timeout(Deadline) of
        0 ->
            erlang:demonitor(CallerMonitor, [flush]),
            Caller ! {scope_route_result, ReplyRef, self(),
                      {error, timeout}};
        Remaining ->
            guarded_router_call_with_timeout(
              Caller, CallerMonitor, ReplyRef, Router, Scope,
              Deadline, Remaining)
    end.

guarded_router_call_with_timeout(Caller, CallerMonitor, ReplyRef, Router,
                                 Scope, Deadline, Remaining) ->
    Guard = self(),
    CallRef = make_ref(),
    {CallWorker, CallMonitor} = spawn_monitor(
      fun() ->
          Reply = safe_call(
                    Router,
                    {resolve, Scope, Caller, Guard, Deadline},
                    Remaining),
          Guard ! {scope_router_call_result, CallRef, self(), Reply}
      end),
    receive
        {scope_router_call_result, CallRef, CallWorker, Reply} ->
            erlang:demonitor(CallMonitor, [flush]),
            deliver_guarded_route_reply(
              Caller, CallerMonitor, ReplyRef, Reply);
        {'DOWN', CallerMonitor, process, Caller, _Reason} ->
            stop_route_call_worker(CallWorker, CallMonitor);
        {'DOWN', CallMonitor, process, CallWorker, Reason} ->
            erlang:demonitor(CallerMonitor, [flush]),
            Caller ! {scope_route_result, ReplyRef, self(),
                      {error, {scope_route_call_down, Reason}}}
    after Remaining + 100 ->
        erlang:demonitor(CallerMonitor, [flush]),
        stop_route_call_worker(CallWorker, CallMonitor),
        case is_process_alive(Caller) of
            true ->
                Caller ! {scope_route_result, ReplyRef, self(),
                          {error, timeout}};
            false -> ok
        end
    end.

remaining_route_timeout(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

deliver_guarded_route_reply(
  Caller, CallerMonitor, ReplyRef,
  {ok, _Adapter, _Worker, OperationLease} = Reply) ->
    case is_process_alive(Caller) of
        false ->
            erlang:demonitor(CallerMonitor, [flush]),
            release_operation_lease(OperationLease);
        true ->
            Caller ! {scope_route_result, ReplyRef, self(), Reply},
            await_cold_route_accept(
              Caller, CallerMonitor, ReplyRef, OperationLease)
    end;
deliver_guarded_route_reply(Caller, CallerMonitor, ReplyRef, Reply) ->
    erlang:demonitor(CallerMonitor, [flush]),
    case is_process_alive(Caller) of
        true -> Caller ! {scope_route_result, ReplyRef, self(), Reply};
        false -> ok
    end.

await_cold_route_accept(Caller, CallerMonitor, ReplyRef, OperationLease) ->
    receive
        {scope_route_accept, ReplyRef, Caller} ->
            case transfer_operation_lease(
                   OperationLease, self(), Caller) of
                ok ->
                    erlang:demonitor(CallerMonitor, [flush]),
                    Caller ! {scope_route_accepted, ReplyRef, self()};
                {error, Reason} ->
                    erlang:demonitor(CallerMonitor, [flush]),
                    release_operation_lease(OperationLease),
                    Caller ! {scope_route_rejected, ReplyRef, self(), Reason}
            end;
        {scope_route_abort, ReplyRef, Caller} ->
            erlang:demonitor(CallerMonitor, [flush]),
            release_operation_lease(OperationLease);
        {'DOWN', CallerMonitor, process, Caller, _Reason} ->
            release_operation_lease(OperationLease)
    after ?LEASE_HANDOFF_TIMEOUT_MS ->
        erlang:demonitor(CallerMonitor, [flush]),
        release_operation_lease(OperationLease),
        case is_process_alive(Caller) of
            true ->
                Caller ! {scope_route_rejected, ReplyRef, self(),
                          scope_route_handoff_timeout};
            false -> ok
        end
    end.

stop_route_call_worker(CallWorker, CallMonitor) ->
    exit(CallWorker, kill),
    receive
        {'DOWN', CallMonitor, process, CallWorker, _Reason} -> ok
    after 100 ->
        erlang:demonitor(CallMonitor, [flush]),
        ok
    end.

stop_supervisor(Supervisor) when is_pid(Supervisor) ->
    case is_process_alive(Supervisor) of
        true ->
            Monitor = erlang:monitor(process, Supervisor),
            unlink(Supervisor),
            exit(Supervisor, shutdown),
            receive
                {'DOWN', Monitor, process, Supervisor, _Reason} -> ok
            after 5000 ->
                erlang:demonitor(Monitor, [flush]),
                ok
            end;
        false -> ok
    end.

safe_stop(Router) ->
    try gen_server:stop(Router, normal, 6000) of
        ok -> ok
    catch
        exit:{noproc, _} -> ok;
        exit:noproc -> ok;
        exit:{normal, _} -> ok;
        exit:{timeout, _} -> {error, timeout};
        exit:_ -> {error, scope_router_unavailable}
    end.
