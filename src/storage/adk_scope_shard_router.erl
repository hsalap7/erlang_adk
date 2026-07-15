%% @doc Bounded exact-scope router shared by sharded artifact and memory APIs.
%%
%% The router performs only validation and worker lookup/startup. Calls are
%% made directly to the resolved adapter process, so unrelated exact scopes do
%% not serialize behind one storage GenServer. Each router owns an anonymous
%% dynamic supervisor and stops when its creator exits.
-module(adk_scope_shard_router).
-behaviour(gen_server).

-export([start_link/4, resolve/3, capabilities/1, status/1, stop/1,
         validate_adapter/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DEFAULT_ROUTE_TIMEOUT_MS, 5000).

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
    scopes = #{} :: map(),
    monitor_to_scope = #{} :: map()
}).

-type handle() ::
    {adk_scope_shard, pid(), ets:tid(), atomics:atomics_ref(), pos_integer()}.
-export_type([handle/0]).

-spec start_link(artifact | memory, module(), map(), map()) ->
    {ok, handle()} | {error, term()}.
start_link(Kind, Adapter, AdapterConfig, Options)
  when (Kind =:= artifact orelse Kind =:= memory), is_atom(Adapter),
       is_map(AdapterConfig), is_map(Options) ->
    Owner = self(),
    case validate_start_options(Options) of
        {ok, MaxScopes, MaxQueue} ->
            case validate_adapter(Kind, Adapter) of
                ok ->
                    RouteAdmission = atomics:new(1, [{signed, true}]),
                    case gen_server:start_link(
                           ?MODULE,
                           {Owner, Kind, Adapter, AdapterConfig,
                            MaxScopes, MaxQueue, RouteAdmission}, []) of
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
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
start_link(_Kind, _Adapter, _AdapterConfig, _Options) ->
    {error, invalid_scope_shard_config}.

-spec resolve(handle(), term(), pos_integer()) ->
    {ok, module(), pid()} | {error, term()}.
resolve({adk_scope_shard, Router, RoutingTable, RouteAdmission, MaxQueue},
        Scope, Timeout)
  when is_pid(Router), is_integer(MaxQueue), MaxQueue > 0,
       is_integer(Timeout), Timeout > 0 ->
    case cached_worker(RoutingTable, Scope) of
        {ok, Adapter, Worker} -> {ok, Adapter, Worker};
        miss ->
            resolve_through_router(
              Router, Scope, Timeout, RouteAdmission, MaxQueue)
    end;
resolve(_Handle, _Scope, _Timeout) ->
    {error, invalid_scope_shard_handle}.

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
      RouteAdmission}) ->
    process_flag(trap_exit, true),
    OwnerMonitor = erlang:monitor(process, Owner),
    RoutingTable = ets:new(?MODULE, [set, protected,
                                     {read_concurrency, true}]),
    case adk_scope_shard_sup:start_link() of
        {ok, Supervisor} ->
            case probe_capabilities(
                   Kind, Supervisor, Adapter, AdapterConfig) of
                {ok, Capabilities} ->
                    {ok, #state{kind = Kind,
                                adapter = Adapter,
                                adapter_config = AdapterConfig,
                                capabilities = Capabilities,
                                supervisor = Supervisor,
                                owner = Owner,
                                owner_monitor = OwnerMonitor,
                                routing_table = RoutingTable,
                                route_admission = RouteAdmission,
                                max_active_scopes = MaxScopes,
                                max_router_queue = MaxQueue}};
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
               cold_routes_in_flight => ColdRoutesInFlight,
               max_router_queue => State#state.max_router_queue,
               cold_route_admission => strict_atomic,
               routing => exact_scope,
               worker_supervision => per_instance_dynamic,
               global_quota => false},
    {reply, {ok, Status}, State};
handle_call({resolve, Scope, Caller}, _From, State0) when is_pid(Caller) ->
    %% A cold-route guard monitors the original caller. Its queued request may
    %% still reach us after that caller dies, so recheck ownership before
    %% starting a scope worker and avoid creating abandoned shards.
    case is_process_alive(Caller) of
        false -> {reply, {error, scope_route_caller_unavailable}, State0};
        true ->
            case validate_scope(State0#state.kind, Scope) of
                ok ->
                    case live_worker(Scope, State0) of
                        {ok, Pid, State1} ->
                            {reply, {ok, State1#state.adapter, Pid}, State1};
                        {start, State1} ->
                            start_scope_worker(Scope, State1)
                    end;
                {error, _} = Error ->
                    {reply, Error, State0}
            end
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_scope_router_request}, State}.

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
    Allowed = [max_active_scopes, max_router_queue],
    Unknown = lists:sort(maps:keys(maps:without(Allowed, Options))),
    MaxScopes = maps:get(max_active_scopes, Options, 1024),
    MaxQueue = maps:get(max_router_queue, Options, 256),
    case {Unknown, positive_integer(MaxScopes), positive_integer(MaxQueue)} of
        {[], true, true} -> {ok, MaxScopes, MaxQueue};
        {[_ | _], _, _} ->
            {error, {invalid_scope_shard_config,
                     {unknown_keys, Unknown}}};
        {[], false, _} ->
            {error, {invalid_scope_shard_config, max_active_scopes}};
        {[], _, false} ->
            {error, {invalid_scope_shard_config, max_router_queue}}
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

live_worker(Scope, State0) ->
    case maps:find(Scope, State0#state.scopes) of
        {ok, #{pid := Pid}} ->
            case is_process_alive(Pid) of
                true -> {ok, Pid, State0};
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

start_scope_worker(Scope, State) ->
    case map_size(State#state.scopes) < State#state.max_active_scopes of
        false ->
            {reply, {error, max_active_scopes_reached}, State};
        true ->
            Config = scope_adapter_config(
                       State#state.kind, State#state.adapter,
                       State#state.adapter_config, Scope),
            case adk_scope_shard_sup:start_adapter(
                   State#state.supervisor, State#state.adapter, Config) of
                {ok, Pid, ChildId} ->
                    Ref = erlang:monitor(process, Pid),
                    Entry = #{pid => Pid, child_id => ChildId,
                              monitor => Ref},
                    Scopes = (State#state.scopes)#{Scope => Entry},
                    MonitorToScope =
                        (State#state.monitor_to_scope)#{Ref => Scope},
                    true = ets:insert(State#state.routing_table,
                                      {Scope, State#state.adapter, Pid}),
                    State1 = State#state{scopes = Scopes,
                                         monitor_to_scope = MonitorToScope},
                    {reply, {ok, State#state.adapter, Pid}, State1};
                {error, Reason} ->
                    {reply, {error, {scope_shard_start_failed, Reason}}, State}
            end
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
    Base#{adapter => State#state.adapter,
          sharding => sharding_capabilities(State),
          quotas => #{enforcement_scope => exact_scope_shard,
                      global_quota => false,
                      adapter_instance_limits => AdapterQuotas}};
public_capabilities(#state{kind = memory} = State) ->
    Base = maps:with(
             [contract_version, scope, durable, search,
              idempotent_ingestion, incremental_events, delete, limits],
             State#state.capabilities),
    Base#{adapter => State#state.adapter,
          sharding => sharding_capabilities(State),
          quota_scope => exact_scope_shard,
          global_quota => false}.

sharding_capabilities(State) ->
    #{strategy => exact_scope,
      same_scope_worker => stable,
      resolved_scope_execution => direct_concurrent,
      cold_scope_startup => router_serialized,
      cold_route_admission => strict_atomic,
      max_active_scopes => State#state.max_active_scopes,
      max_router_queue => State#state.max_router_queue,
      supervision => per_instance_dynamic}.

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
    try ets:lookup(RoutingTable, Scope) of
        [{Scope, Adapter, Worker}] ->
            case is_process_alive(Worker) of
                true -> {ok, Adapter, Worker};
                false -> miss
            end;
        [] -> miss
    catch
        error:badarg -> miss
    end.

resolve_through_router(Router, Scope, Timeout, RouteAdmission, MaxQueue) ->
    Caller = self(),
    ReplyRef = make_ref(),
    {Guard, GuardMonitor} = spawn_monitor(
      fun() ->
          cold_route_guard(Caller, ReplyRef, Router, Scope, Timeout,
                           RouteAdmission, MaxQueue)
      end),
    receive
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

cold_route_guard(Caller, ReplyRef, Router, Scope, Timeout,
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
                                    Scope, Timeout)
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
                    Timeout) ->
    Guard = self(),
    CallRef = make_ref(),
    {CallWorker, CallMonitor} = spawn_monitor(
      fun() ->
          Reply = safe_call(Router, {resolve, Scope, Caller}, Timeout),
          Guard ! {scope_router_call_result, CallRef, self(), Reply}
      end),
    receive
        {scope_router_call_result, CallRef, CallWorker, Reply} ->
            erlang:demonitor(CallMonitor, [flush]),
            erlang:demonitor(CallerMonitor, [flush]),
            case is_process_alive(Caller) of
                true ->
                    Caller ! {scope_route_result, ReplyRef, self(), Reply};
                false -> ok
            end;
        {'DOWN', CallerMonitor, process, Caller, _Reason} ->
            stop_route_call_worker(CallWorker, CallMonitor);
        {'DOWN', CallMonitor, process, CallWorker, Reason} ->
            erlang:demonitor(CallerMonitor, [flush]),
            Caller ! {scope_route_result, ReplyRef, self(),
                      {error, {scope_route_call_down, Reason}}}
    after Timeout + 100 ->
        erlang:demonitor(CallerMonitor, [flush]),
        stop_route_call_worker(CallWorker, CallMonitor),
        case is_process_alive(Caller) of
            true ->
                Caller ! {scope_route_result, ReplyRef, self(),
                          {error, timeout}};
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
