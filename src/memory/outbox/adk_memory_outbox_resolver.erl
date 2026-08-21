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

%% Resolvers backed by volatile runtime registration may expose an admission
%% barrier. A processor must not claim durable work until the resolver says
%% that its registrations have been rehydrated. Stateless resolvers can omit
%% this callback and remain immediately ready for backward compatibility.
-callback ready(ResolverState :: term()) ->
    ready | not_ready | {error, term()}.

%% Volatile registries can additionally expose the exact stable identities
%% that are currently rehydrated. The processor passes this bounded set into
%% its claim transaction so registering one adapter never opens claims for a
%% different adapter that is still unavailable after restart.
-callback claimable_identities(ResolverState :: term()) ->
    {ok, all | map()} | {error, term()}.

-optional_callbacks([ready/1, claimable_identities/1]).

-export_type([stable_id/0, service_ref/0]).
