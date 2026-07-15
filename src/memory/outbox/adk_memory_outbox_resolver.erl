%% @doc Runtime resolver for durable memory-outbox adapter identities.
%%
%% The outbox persists only `{AdapterModule, StableId}'.  A processor invokes
%% this callback for each attempt to obtain the current runtime service
%% reference.  Resolver state and the returned handle are never written to
%% Mnesia.
-module(adk_memory_outbox_resolver).

-type stable_id() :: binary().
-type service_ref() :: {module(), term()}.

-callback resolve(AdapterModule :: module(), StableId :: stable_id(),
                  ResolverState :: term()) ->
    {ok, service_ref()} | {error, term()}.

-export_type([stable_id/0, service_ref/0]).
