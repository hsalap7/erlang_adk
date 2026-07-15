%% @doc Behaviour for provider-managed model-request prefix caches.
%%
%% This is deliberately not a response-cache contract. `create/2' stores or
%% registers a sanitized provider-request prefix and returns a private resource
%% name. The lifecycle registry keeps that name behind an ephemeral lease.
%% Providers obtain credentials through their own adapter configuration; the
%% request map passed here never contains credentials.
-module(adk_context_cache_provider).

-callback create(Prefix :: map(), Request :: map()) ->
    {ok, ResourceName :: binary()}
    | {ok, ResourceName :: binary(), Metadata :: map()}
    | {error, term()}.

-callback delete(ResourceName :: binary(), Request :: map()) ->
    ok | {error, term()}.

-callback capabilities() -> map().
-optional_callbacks([capabilities/0]).
