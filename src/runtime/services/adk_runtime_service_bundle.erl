%% @doc Bundle of the built-in session, artifact, and memory services selected
%% by an `adk_runtime_service_profile'. `start_link/2' is the supervised OTP
%% entry point; `start/2' is available for explicitly managed local use.
%%
%% Owned service routers are one atomic generation. If either router exits,
%% this process exits abnormally instead of replacing a child behind service
%% references already held by a Runner. Place the bundle under an OTP
%% supervisor (or use child_spec/1); an abnormal bundle restart then creates a
%% fresh, internally consistent generation.
-module(adk_runtime_service_bundle).
-behaviour(gen_server).

-export([profiles/0, child_spec/1,
         start/2, start/3, start_link/2, start_link/3, stop/1,
         services/1, runner_spec/1, configured_runner_spec/0, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(CALL_TIMEOUT_MS, 15000).
-define(HEALTH_INTERVAL_MS, 1000).

-record(state, {
    profile :: adk_runtime_service_profile:profile(),
    durability :: ephemeral | durable,
    session_service :: module(),
    artifact_module :: module(),
    artifact_adapter :: module(),
    artifact_handle :: term(),
    artifact_pid :: pid(),
    artifact_capabilities :: map(),
    artifact_effect_journal = undefined :: map() | undefined,
    memory_module :: module(),
    memory_adapter :: module(),
    memory_handle :: term(),
    memory_pid :: pid(),
    memory_capabilities :: map(),
    memory_outbox = undefined :: map() | undefined,
    mnesia_pid = undefined :: pid() | undefined,
    mnesia_monitor = undefined :: reference() | undefined,
    health_timer = undefined :: reference() | undefined,
    health_tables = [] :: [atom()]
}).

-spec profiles() -> [adk_runtime_service_profile:profile()].
profiles() -> adk_runtime_service_profile:profiles().

%% @doc Build a strict child specification. A named, application-managed
%% bundle is permanent so a normal stop also replaces every downstream
%% consumer under a `rest_for_one' supervisor. An anonymous explicitly-managed
%% bundle remains transient.
-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Options) when is_map(Options) ->
    Allowed = [profile, config, id, name],
    Unknown = lists:sort(maps:keys(maps:without(Allowed, Options))),
    Profile = maps:get(profile, Options, undefined),
    Config = maps:get(config, Options, #{}),
    Name = maps:get(name, Options, undefined),
    case {Unknown, valid_name(Name),
          adk_runtime_service_profile:compile(Profile, Config)} of
        {[], true, {ok, _Plan}} ->
            #{id => maps:get(id, Options, {?MODULE, Profile}),
              start => {?MODULE, start_link, [Name, Profile, Config]},
              restart => child_restart(Name),
              shutdown => 15000,
              type => worker,
              modules => [?MODULE]};
        {[_ | _], _, _} ->
            erlang:error(
              {invalid_runtime_service_child_spec,
               {unknown_keys, Unknown}});
        {[], false, _} ->
            erlang:error(
              {invalid_runtime_service_child_spec, invalid_name});
        {[], true, {error, Reason}} ->
            erlang:error({invalid_runtime_service_child_spec, Reason})
    end;
child_spec(_Options) ->
    erlang:error({invalid_runtime_service_child_spec, expected_map}).

child_restart(undefined) -> transient;
child_restart(_Name) -> permanent.

-spec start_link(adk_runtime_service_profile:profile(), map()) ->
    {ok, pid()} | {error, term()}.
start_link(Profile, Config) ->
    start_link(undefined, Profile, Config).

-spec start_link(atom() | undefined,
                 adk_runtime_service_profile:profile(), map()) ->
    {ok, pid()} | {error, term()}.
start_link(Name, Profile, Config) ->
    start_with(start_link, Name, Profile, Config).

-spec start(adk_runtime_service_profile:profile(), map()) ->
    {ok, pid()} | {error, term()}.
start(Profile, Config) ->
    start(undefined, Profile, Config).

-spec start(atom() | undefined,
            adk_runtime_service_profile:profile(), map()) ->
    {ok, pid()} | {error, term()}.
start(Name, Profile, Config) ->
    start_with(start, Name, Profile, Config).

start_with(Function, Name, Profile, Config) ->
    case {valid_name(Name),
          adk_runtime_service_profile:compile(Profile, Config)} of
        {true, {ok, Plan}} -> start_server(Function, Name, Plan);
        {false, _} -> {error, invalid_runtime_service_bundle_name};
        {_, {error, _} = Error} -> Error
    end.

start_server(start_link, undefined, Plan) ->
    gen_server:start_link(?MODULE, Plan, []);
start_server(start_link, Name, Plan) ->
    gen_server:start_link({local, Name}, ?MODULE, Plan, []);
start_server(start, undefined, Plan) ->
    gen_server:start(?MODULE, Plan, []);
start_server(start, Name, Plan) ->
    gen_server:start({local, Name}, ?MODULE, Plan, []).

valid_name(undefined) -> true;
valid_name(Name) -> is_atom(Name).

-spec stop(pid() | atom()) -> ok | {error, term()}.
stop(Bundle) -> safe_call(Bundle, stop).

%% @doc Return validated references in their native service shapes.
-spec services(pid() | atom()) -> {ok, map()} | {error, term()}.
services(Bundle) -> safe_call(Bundle, services).

%% @doc Return the exact split consumed by adk_runner:new/4.
-spec runner_spec(pid() | atom()) -> {ok, map()} | {error, term()}.
runner_spec(Bundle) -> safe_call(Bundle, runner_spec).

%% @doc Resolve the application-managed runtime profile, with the released
%% in-memory session service as the explicit disabled-profile fallback.
-spec configured_runner_spec() -> {ok, map()} | {error, term()}.
configured_runner_spec() ->
    Profile = application:get_env(
                erlang_adk, runtime_service_profile, disabled),
    Base = case {Profile, whereis(?MODULE)} of
        {disabled, _} ->
            {ok, #{profile => disabled,
                   session_service => erlang_adk_session,
                   runner_options => #{}}};
        {Enabled, Pid}
          when (Enabled =:= ephemeral_local orelse
                Enabled =:= durable_local), is_pid(Pid) ->
            case runner_spec(?MODULE) of
                {ok, #{profile := Enabled} = Spec} -> {ok, Spec};
                {ok, _Mismatched} ->
                    {error, runtime_service_profile_mismatch};
                {error, _} = Error -> Error
            end;
        {Enabled, undefined}
          when Enabled =:= ephemeral_local; Enabled =:= durable_local ->
            {error, runtime_service_bundle_unavailable};
        {_Invalid, _} -> {error, invalid_runtime_service_profile}
    end,
    with_trace_runner_options(Base).

with_trace_runner_options(
  {ok, #{runner_options := RunnerOptions} = Spec})
  when is_map(RunnerOptions) ->
    case adk_trace_runtime:runner_options() of
        {ok, TraceOptions} ->
            {ok, Spec#{runner_options =>
                           maps:merge(RunnerOptions, TraceOptions)}};
        {error, _} = Error -> Error
    end;
with_trace_runner_options({error, _} = Error) -> Error;
with_trace_runner_options(_Invalid) ->
    {error, invalid_runtime_runner_spec}.

-spec status(pid() | atom()) -> {ok, map()} | {error, term()}.
status(Bundle) -> safe_call(Bundle, status).

init(Plan) ->
    process_flag(trap_exit, true),
    case initialize_session(maps:get(session_service, Plan)) of
        ok ->
            case initialize_artifact_journal(Plan) of
                {ok, Journal} -> start_owned_services(Plan, Journal);
                {error, Reason} ->
                    {stop, {runtime_service_bundle_start_failed,
                            artifact_journal, Reason}}
            end;
        {error, Reason} ->
            {stop, {runtime_service_bundle_start_failed,
                    session, Reason}}
    end.

start_owned_services(Plan, Journal) ->
    ArtifactPlan = maps:get(artifact, Plan),
    case start_component(artifact, ArtifactPlan) of
        {ok, Artifact} ->
            MemoryPlan = maps:get(memory, Plan),
            case start_component(memory, MemoryPlan) of
                {ok, Memory} ->
                    case start_memory_outbox(Plan, Memory) of
                        {ok, MemoryOutbox} ->
                            State0 = state(
                                       Plan, Artifact, Memory, Journal,
                                       MemoryOutbox),
                            case initialize_health(State0) of
                                {ok, State1} -> {ok, State1};
                                {error, Reason} ->
                                    stop_memory_outbox(MemoryOutbox),
                                    stop_component(memory, Memory),
                                    stop_component(artifact, Artifact),
                                    {stop,
                                     {runtime_service_bundle_start_failed,
                                      durable_health, Reason}}
                            end;
                        {error, Reason} ->
                            stop_component(memory, Memory),
                            stop_component(artifact, Artifact),
                            {stop, {runtime_service_bundle_start_failed,
                                    memory_outbox, Reason}}
                    end;
                {error, Reason} ->
                    stop_component(artifact, Artifact),
                    {stop, {runtime_service_bundle_start_failed,
                            memory, Reason}}
            end;
        {error, Reason} ->
            {stop, {runtime_service_bundle_start_failed,
                    artifact, Reason}}
    end.

handle_call(services, _From, State) ->
    case checked_services(State) of
        {ok, Services} -> {reply, {ok, Services}, State};
        {error, Reason} -> fail_component_call(Reason, State)
    end;
handle_call(runner_spec, _From, State) ->
    case checked_services(State) of
        {ok, Services} ->
            RunnerOptions0 =
                #{artifact_svc =>
                      maps:get(artifact_service, Services),
                  memory_svc => maps:get(memory_service, Services)},
            RunnerOptions1 = maybe_put_defined(
                               memory_ingestion,
                               memory_ingestion_option(Services),
                               RunnerOptions0),
            RunnerOptions = maybe_put_defined(
                              artifact_effect_journal,
                              maps:get(artifact_effect_journal, Services,
                                       undefined),
                              RunnerOptions1),
            Reply =
                #{profile => State#state.profile,
                  session_service => maps:get(session_service, Services),
                  runner_options => RunnerOptions},
            {reply, {ok, Reply}, State};
        {error, Reason} -> fail_component_call(Reason, State)
    end;
handle_call(status, _From, State) ->
    case component_status(State) of
        {ok, ArtifactStatus, MemoryStatus, OutboxStatus} ->
            Reply =
                #{status => running,
                  profile => State#state.profile,
                  durability => State#state.durability,
                  session_service => State#state.session_service,
                  artifact => public_component_status(
                                State#state.artifact_adapter,
                                State#state.artifact_capabilities,
                                ArtifactStatus),
                  memory => public_component_status(
                              State#state.memory_adapter,
                              State#state.memory_capabilities,
                              MemoryStatus),
                  memory_outbox => OutboxStatus,
                  artifact_effect_journal =>
                      journal_status(State#state.artifact_effect_journal),
                  restart_semantics => atomic_generation_fail_stop},
            {reply, {ok, Reply}, State};
        {error, Reason} -> fail_component_call(Reason, State)
    end;
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_runtime_service_bundle_request}, State}.

handle_cast(_Request, State) -> {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State)
  when Pid =:= State#state.artifact_pid ->
    {stop, {runtime_service_child_down, artifact, Reason}, State};
handle_info({'EXIT', Pid, Reason}, State)
  when Pid =:= State#state.memory_pid ->
    {stop, {runtime_service_child_down, memory, Reason}, State};
handle_info({'EXIT', Pid, Reason},
            #state{memory_outbox = #{supervisor := Pid}} = State) ->
    {stop, {runtime_service_child_down, memory_outbox, Reason}, State};
handle_info({'DOWN', Ref, process, Pid, Reason},
            #state{mnesia_monitor = Ref, mnesia_pid = Pid} = State) ->
    {stop, {runtime_service_dependency_down, mnesia, Reason}, State};
handle_info(runtime_service_health_check, State0) ->
    case durable_health(State0) of
        ok -> {noreply, schedule_health_check(State0)};
        {error, Reason} ->
            Dependency = health_dependency(Reason),
            {stop, {runtime_service_dependency_unavailable,
                    Dependency, Reason}, State0}
    end;
handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, State) ->
    cancel_health_check(State#state.health_timer),
    demonitor_if_present(State#state.mnesia_monitor),
    stop_memory_outbox(State#state.memory_outbox),
    stop_component(
      memory,
      #{module => State#state.memory_module,
        handle => State#state.memory_handle}),
    stop_component(
      artifact,
      #{module => State#state.artifact_module,
        handle => State#state.artifact_handle}),
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

initialize_session(Module) when is_atom(Module) ->
    Required = [{create_session, 3}, {get_session, 3},
                {list_sessions, 2}, {delete_session, 3},
                {update_state, 4}, {add_event, 4},
                {clear_temp_state, 3}, {take_state, 4}],
    case code:ensure_loaded(Module) of
        {module, Module} ->
            Missing = [{Function, Arity}
                       || {Function, Arity} <- Required,
                          not erlang:function_exported(
                                Module, Function, Arity)],
            case Missing of
                [] -> call_session_init(Module);
                _ -> {error, {invalid_session_service,
                              Module, {missing_callbacks, Missing}}}
            end;
        {error, Reason} ->
            {error, {invalid_session_service,
                     Module, {module_unavailable, Reason}}}
    end.

initialize_artifact_journal(Plan) ->
    case maps:get(artifact_effect_journal, Plan, undefined) of
        undefined -> {ok, undefined};
        #{config := Config} when is_map(Config) ->
            adk_artifact_effect_journal:init(Config);
        _ -> {error, invalid_artifact_journal_plan}
    end.

call_session_init(Module) ->
    case erlang:function_exported(Module, init, 0) of
        false -> ok;
        true ->
            try Module:init() of
                ok -> ok;
                {atomic, ok} -> ok;
                {error, Reason} -> {error, Reason};
                Other -> {error, {invalid_session_init_reply, Other}}
            catch
                Class:Reason -> {error, {session_init_exception,
                                         Class, Reason}}
            end
    end.

start_component(Kind, Plan) ->
    Module = maps:get(module, Plan),
    Adapter = maps:get(adapter, Plan),
    Config = maps:get(config, Plan),
    try Module:start_link(Config) of
        {ok, Handle} ->
            Component = #{module => Module, adapter => Adapter,
                          handle => Handle},
            validate_started_component(Kind, Component);
        {error, Reason} -> {error, Reason};
        Other -> {error, {invalid_component_start_reply, Other}}
    catch
        Class:Reason -> {error, {component_start_exception,
                                 Class, Reason}}
    end.

validate_started_component(Kind, Component) ->
    Module = maps:get(module, Component),
    Handle = maps:get(handle, Component),
    Ref = {Module, Handle},
    case adk_service_ref:validate(Kind, Ref) of
        {ok, Ref} ->
            case component_capabilities(Kind, Module, Handle) of
                {ok, Capabilities} ->
                    ExpectedAdapter = maps:get(adapter, Component),
                    case maps:get(adapter, Capabilities, undefined) of
                        ExpectedAdapter ->
                            case router_pid(Handle) of
                                {ok, Pid} ->
                                    {ok, Component#{pid => Pid,
                                                    capabilities =>
                                                        Capabilities}};
                                {error, _} = Error ->
                                    stop_component(Kind, Component),
                                    Error
                            end;
                        Actual ->
                            stop_component(Kind, Component),
                            {error, {component_adapter_mismatch,
                                     ExpectedAdapter, Actual}}
                    end;
                {error, _} = Error ->
                    stop_component(Kind, Component),
                    Error
            end;
        {error, _} = Error ->
            stop_component(Kind, Component),
            Error
    end.

component_capabilities(artifact, Module, Handle) ->
    case Module:capabilities(Handle) of
        {ok, Capabilities} when is_map(Capabilities) ->
            {ok, Capabilities};
        {error, _} = Error -> Error;
        Other -> {error, {invalid_artifact_capabilities, Other}}
    end;
component_capabilities(memory, Module, Handle) ->
    case Module:capabilities(Handle) of
        Capabilities when is_map(Capabilities) -> {ok, Capabilities};
        {error, _} = Error -> Error;
        Other -> {error, {invalid_memory_capabilities, Other}}
    end.

start_memory_outbox(#{durability := ephemeral}, _Memory) ->
    {ok, undefined};
start_memory_outbox(
  #{durability := durable,
    memory_outbox := #{options := Options0,
                       store := Store,
                       ingestion := Ingestion}}, Memory) ->
    Capabilities = maps:get(capabilities, Memory),
    case memory_outbox_compatible(Capabilities) of
        ok ->
            Options = private_memory_outbox_options(Options0),
            case adk_memory_outbox_sup:start_link(Options) of
                {ok, Supervisor} ->
                    MemoryRef = {maps:get(module, Memory),
                                 maps:get(handle, Memory)},
                    Identity = {maps:get(module, Memory),
                                maps:get(adapter_id, Ingestion)},
                    case adk_memory_outbox_sup:register_adapter(
                           Supervisor, Identity, MemoryRef) of
                        ok ->
                            {ok, #{supervisor => Supervisor,
                                   store => Store,
                                   ingestion => Ingestion,
                                   adapter => Identity}};
                        {error, Reason} ->
                            _ = adk_memory_outbox_sup:stop(Supervisor),
                            {error, {memory_outbox_adapter_registration_failed,
                                     Reason}}
                    end;
                {error, Reason} -> {error, Reason};
                Other ->
                    {error, {invalid_memory_outbox_start_reply, Other}}
            end;
        {error, _} = Error -> Error
    end;
start_memory_outbox(#{durability := durable}, _Memory) ->
    {error, memory_outbox_plan_required}.

memory_outbox_compatible(Capabilities) ->
    Version = maps:get(contract_version, Capabilities,
                       maps:get(version, Capabilities, 0)),
    case is_integer(Version) andalso Version >= 2 andalso
         maps:get(idempotent_ingestion, Capabilities, false) =:= true andalso
         maps:get(incremental_events, Capabilities, false) =:= true andalso
         maps:get(erasure_epoch_fencing, Capabilities, false) =:= true of
        true -> ok;
        false ->
            {error, memory_outbox_requires_fenced_idempotent_v2_adapter}
    end.

private_memory_outbox_options(Options) ->
    Registry = maps:get(registry, Options, #{}),
    Processor = maps:get(processor, Options, #{}),
    Options#{name => undefined,
             registry => Registry#{name => undefined},
             processor => Processor#{name => undefined}}.

router_pid({adk_scope_shard, Pid, _Table, _Admission, _MaxQueue})
  when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> {ok, Pid};
        false -> {error, component_router_unavailable}
    end;
router_pid(_Handle) -> {error, invalid_component_router_handle}.

state(Plan, Artifact, Memory, Journal, MemoryOutbox) ->
    #state{
       profile = maps:get(profile, Plan),
       durability = maps:get(durability, Plan),
       session_service = maps:get(session_service, Plan),
       artifact_module = maps:get(module, Artifact),
       artifact_adapter = maps:get(adapter, Artifact),
       artifact_handle = maps:get(handle, Artifact),
       artifact_pid = maps:get(pid, Artifact),
       artifact_capabilities = maps:get(capabilities, Artifact),
       artifact_effect_journal = Journal,
       memory_module = maps:get(module, Memory),
       memory_adapter = maps:get(adapter, Memory),
       memory_handle = maps:get(handle, Memory),
       memory_pid = maps:get(pid, Memory),
       memory_capabilities = maps:get(capabilities, Memory),
       memory_outbox = MemoryOutbox
    }.

checked_services(State) ->
    ArtifactRef = {State#state.artifact_module,
                   State#state.artifact_handle},
    MemoryRef = {State#state.memory_module, State#state.memory_handle},
    case {durable_health(State),
          is_process_alive(State#state.artifact_pid),
          is_process_alive(State#state.memory_pid),
          adk_service_ref:validate(artifact, ArtifactRef),
          adk_service_ref:validate(memory, MemoryRef)} of
        {ok, true, true, {ok, ArtifactRef}, {ok, MemoryRef}} ->
            Base = #{profile => State#state.profile,
                     session_service => State#state.session_service,
                     artifact_service => ArtifactRef,
                     memory_service => MemoryRef},
            WithOutbox = maybe_put_defined(
                           memory_outbox,
                           public_memory_outbox_service(
                             State#state.memory_outbox), Base),
            {ok, maybe_put_defined(
                   artifact_effect_journal,
                   State#state.artifact_effect_journal, WithOutbox)};
        {{error, Reason}, _, _, _, _} -> {error, Reason};
        {_, false, _, _, _} -> {error, artifact_service_unavailable};
        {_, _, false, _, _} -> {error, memory_service_unavailable};
        {_, _, _, {error, Reason}, _} -> {error, Reason};
        {_, _, _, _, {error, Reason}} -> {error, Reason}
    end.

component_status(State) ->
    case durable_health(State) of
        ok -> component_status_healthy(State);
        {error, _} = Error -> Error
    end.

component_status_healthy(State) ->
    case (State#state.artifact_module):status(
           State#state.artifact_handle) of
        {ok, ArtifactStatus} when is_map(ArtifactStatus) ->
            case (State#state.memory_module):status(
                   State#state.memory_handle) of
                {ok, MemoryStatus} when is_map(MemoryStatus) ->
                    case memory_outbox_status(State#state.memory_outbox) of
                        {ok, OutboxStatus} ->
                            {ok, ArtifactStatus, MemoryStatus, OutboxStatus};
                        {error, _} = Error -> Error
                    end;
                {error, Reason} ->
                    {error, {memory_status_failed, Reason}};
                Other ->
                    {error, {invalid_memory_status, Other}}
            end;
        {error, Reason} ->
            {error, {artifact_status_failed, Reason}};
        Other ->
            {error, {invalid_artifact_status, Other}}
    end.

initialize_health(#state{durability = ephemeral} = State) ->
    {ok, State};
initialize_health(#state{durability = durable} = State0) ->
    JournalTables = case State0#state.artifact_effect_journal of
        undefined -> [];
        Journal -> adk_artifact_effect_journal:table_names(Journal)
    end,
    OutboxTables = memory_outbox_tables(State0#state.memory_outbox),
    Tables = lists:usort(
               [adk_sessions_mnesia, adk_session_v2,
                adk_session_scope |
                adk_memory_mnesia:table_names() ++ JournalTables ++
                OutboxTables]),
    case {whereis(mnesia_sup), mnesia_tables_available(Tables)} of
        {Pid, ok} when is_pid(Pid) ->
            Monitor = erlang:monitor(process, Pid),
            State1 = State0#state{mnesia_pid = Pid,
                                  mnesia_monitor = Monitor,
                                  health_tables = Tables},
            case memory_outbox_health(State1) of
                ok -> {ok, schedule_health_check(State1)};
                {error, _} = Error ->
                    erlang:demonitor(Monitor, [flush]),
                    Error
            end;
        {undefined, _} -> {error, mnesia_not_running};
        {_Pid, {error, _} = Error} -> Error
    end.

durable_health(#state{durability = ephemeral}) -> ok;
durable_health(#state{durability = durable,
                      mnesia_pid = Pid,
                      health_tables = Tables} = State) ->
    case is_pid(Pid) andalso is_process_alive(Pid) andalso
         whereis(mnesia_sup) =:= Pid of
        true ->
            case mnesia_tables_available(Tables) of
                ok -> memory_outbox_health(State);
                {error, _} = Error -> Error
            end;
        false -> {error, mnesia_not_running}
    end.

memory_outbox_health(
  #state{memory_outbox =
             #{supervisor := Supervisor,
               adapter := Identity},
         memory_module = Module,
         memory_handle = Handle}) ->
    MemoryRef = {Module, Handle},
    %% Registration is the readiness handshake for the volatile resolver.
    %% Perform it before health so a replacement registry is deterministically
    %% rehydrated before its replacement processor may claim durable work.
    case adk_memory_outbox_sup:register_adapter(
           Supervisor, Identity, MemoryRef) of
        ok ->
            case adk_memory_outbox_sup:health(Supervisor) of
                {ok, _Health} -> ok;
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, {memory_outbox_adapter_unavailable, Reason}}
    end;
memory_outbox_health(_State) ->
    {error, memory_outbox_unavailable}.

health_dependency(mnesia_not_running) -> mnesia;
health_dependency({mnesia_tables_unavailable, _}) -> mnesia;
health_dependency({mnesia_health_failed, _}) -> mnesia;
health_dependency({mnesia_health_exception, _, _}) -> mnesia;
health_dependency(_) -> memory_outbox.

mnesia_tables_available(Tables) ->
    try mnesia:wait_for_tables(Tables, 0) of
        ok -> ok;
        {timeout, Missing} -> {error, {mnesia_tables_unavailable, Missing}};
        {error, Reason} -> {error, {mnesia_health_failed, Reason}}
    catch
        Class:Reason -> {error, {mnesia_health_exception, Class, Reason}}
    end.

schedule_health_check(#state{durability = ephemeral} = State) -> State;
schedule_health_check(State0) ->
    cancel_health_check(State0#state.health_timer),
    Timer = erlang:send_after(?HEALTH_INTERVAL_MS, self(),
                              runtime_service_health_check),
    State0#state{health_timer = Timer}.

cancel_health_check(undefined) -> ok;
cancel_health_check(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

demonitor_if_present(undefined) -> ok;
demonitor_if_present(Monitor) -> erlang:demonitor(Monitor, [flush]).

public_component_status(Adapter, Capabilities, RouterStatus) ->
    Base = maps:with(
             [status, active_scopes, max_active_scopes,
              cold_routes_in_flight, max_router_queue,
              routing, global_quota, idle_scope_timeout_ms,
              idle_reclamation, idle_evictions], RouterStatus),
    Base#{adapter => Adapter,
          capabilities => public_capabilities(Capabilities)}.

public_capabilities(Capabilities) ->
    maps:with(
      [api_version, contract_version, immutable_versions,
       scopes, scope, persistence, durable, search,
       idempotent_ingestion, incremental_events,
       erasure_epoch_fencing], Capabilities).

maybe_put_defined(_Key, undefined, Map) -> Map;
maybe_put_defined(Key, Value, Map) -> Map#{Key => Value}.

memory_ingestion_option(Services) ->
    case maps:get(memory_outbox, Services, undefined) of
        #{supervisor := Supervisor, ingestion := Ingestion} ->
            Ingestion#{outbox => Supervisor};
        undefined -> undefined
    end.

public_memory_outbox_service(undefined) -> undefined;
public_memory_outbox_service(
  #{supervisor := Supervisor, store := Store,
    ingestion := Ingestion, adapter := Identity}) ->
    #{module => adk_memory_outbox_sup,
      supervisor => Supervisor,
      persistence => mnesia,
      tables => adk_memory_outbox:table_names(Store),
      ingestion => Ingestion,
      adapter => Identity}.

memory_outbox_tables(undefined) -> [];
memory_outbox_tables(#{store := Store}) ->
    adk_memory_outbox:table_names(Store).

memory_outbox_status(undefined) -> {ok, disabled};
memory_outbox_status(#{supervisor := Supervisor, store := Store}) ->
    case adk_memory_outbox_sup:health(Supervisor) of
        {ok, Health} ->
            {ok, Health#{tables => adk_memory_outbox:table_names(Store)}};
        {error, Reason} ->
            {error, {memory_outbox_status_failed, Reason}}
    end.

journal_status(undefined) -> disabled;
journal_status(Journal) ->
    #{status => ready,
      persistence => mnesia,
      tables => length(adk_artifact_effect_journal:table_names(Journal)),
      reconciliation => operator_handler_required}.

stop_memory_outbox(undefined) -> ok;
stop_memory_outbox(#{supervisor := Supervisor}) ->
    _ = catch adk_memory_outbox_sup:stop(Supervisor),
    ok.

fail_component_call(Reason, State) ->
    {stop, {runtime_service_component_unavailable, Reason},
     {error, Reason}, State}.

stop_component(artifact, #{module := Module, handle := Handle}) ->
    _ = catch Module:stop(Handle),
    ok;
stop_component(memory, #{module := Module, handle := Handle}) ->
    _ = catch Module:stop(Handle),
    ok.

safe_call(Bundle, Request)
  when is_pid(Bundle); is_atom(Bundle), Bundle =/= undefined ->
    try gen_server:call(Bundle, Request, ?CALL_TIMEOUT_MS) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, runtime_service_bundle_timeout};
        exit:{noproc, _} -> {error, runtime_service_bundle_unavailable};
        exit:{normal, _} -> {error, runtime_service_bundle_unavailable};
        exit:Reason -> {error, {runtime_service_bundle_down, Reason}}
    end;
safe_call(_Bundle, _Request) ->
    {error, invalid_runtime_service_bundle}.
