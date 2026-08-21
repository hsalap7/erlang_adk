%% @doc Optional supervised durable memory-ingestion runtime.
%%
%% The supervisor owns only runtime registry/processor processes. Durable job
%% state is held in bounded Mnesia tables created by adk_memory_outbox. Runner
%% instances register restartable service references under stable adapter IDs;
%% neither pids nor handles are written to the outbox.
-module(adk_memory_outbox_sup).
-behaviour(supervisor).
-behaviour(adk_memory_outbox_resolver).

-export([start_link/1, child_spec/1, stop/1, validate_options/1,
         runtime/1, health/1,
         register_adapter/2, register_adapter/3,
         submit/1, submit/2, status/1, status/2,
         stats/0, stats/1, semantics/0, semantics/1,
         prune_terminal/1, prune_terminal/2,
         resolve/3, ready/1, claimable_identities/1]).
-export([init/1]).

-define(REGISTRY, adk_memory_outbox_registry).
-define(PROCESSOR, adk_memory_outbox_processor).

start_link(Options) when is_map(Options) ->
    case maps:get(name, Options, ?MODULE) of
        undefined -> supervisor:start_link(?MODULE, Options);
        Name when is_atom(Name) ->
            supervisor:start_link({local, Name}, ?MODULE, Options);
        _ -> {error, invalid_memory_outbox_supervisor_name}
    end.

child_spec(Options) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, [Options]},
      restart => permanent,
      shutdown => infinity,
      type => supervisor,
      modules => [?MODULE]}.

stop(Supervisor) when is_pid(Supervisor); is_atom(Supervisor) ->
    try gen_server:stop(Supervisor, normal, 15000) of
        ok -> ok
    catch
        exit:{noproc, _} -> ok;
        exit:normal -> ok;
        exit:Reason -> {error, {memory_outbox_supervisor_stop_failed, Reason}}
    end;
stop(_) -> {error, invalid_memory_outbox_supervisor}.

%% @doc Pure validation used by named runtime-service profiles before startup.
validate_options(Options) when is_map(Options) ->
    Allowed = [name, outbox, registry, processor],
    Unknown = lists:sort(maps:keys(maps:without(Allowed, Options))),
    Name = maps:get(name, Options, ?MODULE),
    OutboxOptions = maps:get(outbox, Options, #{}),
    RegistryOptions = maps:get(registry, Options, #{}),
    ProcessorOptions = maps:get(processor, Options, #{}),
    case {Unknown, valid_name(Name), is_map(OutboxOptions),
          is_map(RegistryOptions), is_map(ProcessorOptions)} of
        {[_ | _], _, _, _, _} ->
            {error, {invalid_memory_outbox_supervisor_options,
                     {unknown_keys, Unknown}}};
        {[], false, _, _, _} ->
            {error, invalid_memory_outbox_supervisor_name};
        {[], true, false, _, _} ->
            {error, invalid_memory_outbox_supervisor_options};
        {[], true, true, false, _} ->
            {error, invalid_memory_outbox_supervisor_options};
        {[], true, true, true, false} ->
            {error, invalid_memory_outbox_supervisor_options};
        {[], true, true, true, true} ->
            case adk_memory_outbox:compile_config(OutboxOptions) of
                {ok, _Handle} ->
                    case adk_memory_outbox_registry:validate_options(
                           RegistryOptions) of
                        ok ->
                            adk_memory_outbox_processor:validate_options(
                              ProcessorOptions);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end
    end;
validate_options(_) ->
    {error, invalid_memory_outbox_supervisor_options}.

valid_name(undefined) -> true;
valid_name(Name) -> is_atom(Name).

%% @doc Resolve the currently live registry and processor below a supervisor.
runtime(Supervisor0) when is_pid(Supervisor0); is_atom(Supervisor0) ->
    case runtime_supervisor(Supervisor0) of
        {ok, Supervisor} -> runtime_children(Supervisor);
        {error, _} = Error -> Error
    end;
runtime(_) -> {error, invalid_memory_outbox_supervisor}.

runtime_supervisor(?MODULE) ->
    case whereis(?MODULE) of
        Pid when is_pid(Pid) -> {ok, Pid};
        undefined -> configured_bundle_supervisor()
    end;
runtime_supervisor(Supervisor) -> {ok, Supervisor}.

%% `memory_outbox_enabled=true' historically exposed the module-named
%% convenience API. A durable profile now owns the only processor privately;
%% resolve that owned runtime rather than starting a duplicate table consumer.
configured_bundle_supervisor() ->
    case whereis(adk_runtime_service_bundle) of
        Pid when is_pid(Pid) ->
            case adk_runtime_service_bundle:services(Pid) of
                {ok, #{memory_outbox := #{supervisor := Supervisor}}}
                  when is_pid(Supervisor) -> {ok, Supervisor};
                {ok, _} -> {error, memory_outbox_supervisor_unavailable};
                {error, _} = Error -> Error
            end;
        undefined -> {error, memory_outbox_supervisor_unavailable}
    end.

runtime_children(Supervisor) ->
    try supervisor:which_children(Supervisor) of
        Children ->
            case {child_pid(?REGISTRY, Children),
                  child_pid(?PROCESSOR, Children)} of
                {{ok, Registry}, {ok, Processor}} ->
                    {ok, #{supervisor => Supervisor,
                           registry => Registry,
                           processor => Processor}};
                {{error, _} = Error, _} -> Error;
                {_, {error, _} = Error} -> Error
            end
    catch
        exit:{noproc, _} -> {error, memory_outbox_supervisor_unavailable};
        exit:Reason -> {error, {memory_outbox_supervisor_down, Reason}}
    end.

child_pid(Id, Children) ->
    case [Pid || {ChildId, Pid, _Type, _Modules} <- Children,
                 ChildId =:= Id, is_pid(Pid)] of
        [Pid] -> {ok, Pid};
        [] -> {error, {memory_outbox_child_unavailable, Id}};
        _ -> {error, {memory_outbox_child_ambiguous, Id}}
    end.

%% @doc Transaction-backed health for either the global or an owned runtime.
health(Supervisor) ->
    case runtime(Supervisor) of
        {ok, #{registry := Registry, processor := Processor}} ->
            case {is_process_alive(Registry), is_process_alive(Processor)} of
                {false, _} -> {error, memory_outbox_registry_unavailable};
                {_, false} -> {error, memory_outbox_processor_unavailable};
                {true, true} ->
                    case adk_memory_outbox_registry:ready(Registry) of
                        ready -> store_health(Processor);
                        not_ready ->
                            {error, memory_outbox_registry_not_rehydrated};
                        {error, Reason} ->
                            {error, {memory_outbox_registry_unhealthy,
                                     Reason}};
                        Other ->
                            {error, {invalid_memory_outbox_registry_health,
                                     Other}}
                    end
            end;
        {error, _} = Error -> Error
    end.

store_health(Processor) ->
    case adk_memory_outbox_processor:health(Processor) of
        {ok, Health} when is_map(Health) ->
            {ok, Health#{status => ready, persistence => mnesia}};
        {error, Reason} ->
            {error, {memory_outbox_store_unhealthy, Reason}};
        Other -> {error, {invalid_memory_outbox_store_health, Other}}
    end.

register_adapter(Identity, ServiceRef) ->
    register_adapter(?MODULE, Identity, ServiceRef).

register_adapter(Supervisor, Identity, ServiceRef) ->
    case runtime(Supervisor) of
        {ok, #{registry := Registry, processor := Processor}} ->
            case adk_memory_outbox_registry:register(
                   Registry, Identity, ServiceRef) of
                ok ->
                    adk_memory_outbox_processor:kick(Processor),
                    ok;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

submit(Request) ->
    submit(?MODULE, Request).

submit(Supervisor, Request) ->
    with_processor(
      Supervisor,
      fun(Processor) ->
          adk_memory_outbox_processor:submit(Processor, Request)
      end).

status(JobId) ->
    status(?MODULE, JobId).

status(Supervisor, JobId) ->
    with_processor(
      Supervisor,
      fun(Processor) ->
          adk_memory_outbox_processor:status(Processor, JobId)
      end).

stats() -> stats(?MODULE).
stats(Supervisor) ->
    with_processor(
      Supervisor, fun adk_memory_outbox_processor:stats/1).

semantics() -> semantics(?MODULE).
semantics(Supervisor) ->
    with_processor(
      Supervisor, fun adk_memory_outbox_processor:semantics/1).

prune_terminal(Limit) ->
    prune_terminal(?MODULE, Limit).

prune_terminal(Supervisor, Limit) ->
    with_processor(
      Supervisor,
      fun(Processor) ->
          adk_memory_outbox_processor:prune_terminal(Processor, Limit)
      end).

with_processor(Supervisor, Fun) ->
    case runtime(Supervisor) of
        {ok, #{processor := Processor}} -> Fun(Processor);
        {error, _} = Error -> Error
    end.

%% adk_memory_outbox_resolver callback used by private owned supervisors.
resolve(Module, StableId, Supervisor) ->
    case runtime(Supervisor) of
        {ok, #{registry := Registry}} ->
            adk_memory_outbox_registry:resolve(
              Module, StableId, Registry);
        {error, _} = Error -> Error
    end.

%% adk_memory_outbox_resolver readiness callback. The processor invokes this
%% before claiming work, so an empty replacement registry cannot consume retry
%% attempts while its runtime identities are being restored.
ready(Supervisor) ->
    case runtime(Supervisor) of
        {ok, #{registry := Registry}} ->
            adk_memory_outbox_registry:ready(Registry);
        {error, _} = Error -> Error
    end.

claimable_identities(Supervisor) ->
    case runtime(Supervisor) of
        {ok, #{registry := Registry}} ->
            adk_memory_outbox_registry:claimable_identities(Registry);
        {error, _} = Error -> Error
    end.

init(Options) ->
    case validate_options(Options) of
        ok -> initialize_children(Options);
        {error, Reason} -> {stop, Reason}
    end.

initialize_children(Options) ->
    SupervisorName = maps:get(name, Options, ?MODULE),
    OutboxOptions = maps:get(outbox, Options, #{}),
    RegistryOptions0 = maps:get(registry, Options, #{}),
    ProcessorOptions0 = maps:get(processor, Options, #{}),
    case {is_map(OutboxOptions), is_map(RegistryOptions0),
          is_map(ProcessorOptions0)} of
        {true, true, true} ->
            case adk_memory_outbox:init(OutboxOptions) of
                {ok, Outbox} ->
                    {RegistryName, ProcessorName} = child_names(SupervisorName),
                    RegistryOptions = RegistryOptions0#{name => RegistryName},
                    ProcessorOptions = ProcessorOptions0#{
                      name => ProcessorName,
                      outbox => Outbox,
                      resolver => {?MODULE, self()}},
                    Registry = (adk_memory_outbox_registry:child_spec(
                                  RegistryOptions))#{id => ?REGISTRY},
                    Processor = (adk_memory_outbox_processor:child_spec(
                                   ProcessorOptions))#{id => ?PROCESSOR},
                    {ok, {#{strategy => rest_for_one,
                            intensity => 5, period => 10},
                          [Registry, Processor]}};
                {error, Reason} ->
                    {stop, {memory_outbox_initialization_failed, Reason}}
            end;
        _ -> {stop, invalid_memory_outbox_supervisor_options}
    end.

child_names(?MODULE) -> {?REGISTRY, ?PROCESSOR};
child_names(_PrivateOrCustom) -> {undefined, undefined}.
