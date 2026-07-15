%% @doc Optional supervised durable memory-ingestion runtime.
%%
%% The supervisor owns only runtime registry/processor processes. Durable job
%% state is held in bounded Mnesia tables created by adk_memory_outbox. Runner
%% instances register restartable service references under stable adapter IDs;
%% neither pids nor handles are written to the outbox.
-module(adk_memory_outbox_sup).
-behaviour(supervisor).

-export([start_link/1, child_spec/1, register_adapter/2, submit/1, status/1]).
-export([init/1]).

-define(REGISTRY, adk_memory_outbox_registry).
-define(PROCESSOR, adk_memory_outbox_processor).

start_link(Options) when is_map(Options) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Options).

child_spec(Options) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, [Options]},
      restart => permanent,
      shutdown => infinity,
      type => supervisor,
      modules => [?MODULE]}.

register_adapter(Identity, ServiceRef) ->
    adk_memory_outbox_registry:register(?REGISTRY, Identity, ServiceRef).

submit(Request) ->
    adk_memory_outbox_processor:submit(?PROCESSOR, Request).

status(JobId) ->
    adk_memory_outbox_processor:status(?PROCESSOR, JobId).

init(Options) ->
    Allowed = [outbox, registry, processor],
    case maps:keys(maps:without(Allowed, Options)) of
        [] -> initialize_children(Options);
        Unknown ->
            {stop, {invalid_memory_outbox_supervisor_options,
                    {unknown_keys, lists:sort(Unknown)}}}
    end.

initialize_children(Options) ->
    OutboxOptions = maps:get(outbox, Options, #{}),
    RegistryOptions0 = maps:get(registry, Options, #{}),
    ProcessorOptions0 = maps:get(processor, Options, #{}),
    case {is_map(OutboxOptions), is_map(RegistryOptions0),
          is_map(ProcessorOptions0)} of
        {true, true, true} ->
            case adk_memory_outbox:init(OutboxOptions) of
                {ok, Outbox} ->
                    RegistryOptions = RegistryOptions0#{name => ?REGISTRY},
                    ProcessorOptions = ProcessorOptions0#{
                      name => ?PROCESSOR,
                      outbox => Outbox,
                      resolver => {adk_memory_outbox_registry, ?REGISTRY}},
                    Registry = adk_memory_outbox_registry:child_spec(
                                 RegistryOptions),
                    Processor = adk_memory_outbox_processor:child_spec(
                                  ProcessorOptions),
                    {ok, {#{strategy => rest_for_one,
                            intensity => 5, period => 10},
                          [Registry, Processor]}};
                {error, Reason} ->
                    {stop, {memory_outbox_initialization_failed, Reason}}
            end;
        _ -> {stop, invalid_memory_outbox_supervisor_options}
    end.
