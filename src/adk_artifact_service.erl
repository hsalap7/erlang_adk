%% @doc Behaviour for immutable, versioned binary artifacts.
%%
%% Artifact names are logical names within an explicit application, user, or
%% session scope. Implementations must create a new positive version on every
%% successful put; an existing version is never overwritten.
-module(adk_artifact_service).

-type handle() :: term().
-type scope() ::
    {app, binary()}
    | {user, binary(), binary()}
    | {session, binary(), binary(), binary()}.
-type selector() :: pos_integer() | latest.
-type delete_selector() :: selector() | all.
-type artifact_meta() :: #{
    scope := scope(),
    name := binary(),
    version := pos_integer(),
    mime_type := binary(),
    digest := binary(),
    size := non_neg_integer(),
    created_at := integer(),
    metadata := map()
}.
-type artifact() :: #{
    scope := scope(),
    name := binary(),
    version := pos_integer(),
    mime_type := binary(),
    digest := binary(),
    size := non_neg_integer(),
    created_at := integer(),
    metadata := map(),
    data := binary()
}.

-export_type([
    handle/0,
    scope/0,
    selector/0,
    delete_selector/0,
    artifact_meta/0,
    artifact/0
]).

-callback start_link(Config :: map()) -> {ok, handle()} | {error, term()}.
-callback put(Handle :: handle(), Scope :: scope(), Name :: binary(),
              Data :: binary(), Options :: map()) ->
    {ok, artifact_meta()} | {error, term()}.
-callback get(Handle :: handle(), Scope :: scope(), Name :: binary(),
              Selector :: selector()) ->
    {ok, artifact()} | {error, not_found | term()}.
-callback list(Handle :: handle(), Scope :: scope()) ->
    {ok, [artifact_meta()]} | {error, term()}.
-callback delete(Handle :: handle(), Scope :: scope(), Name :: binary(),
                 Selector :: delete_selector()) ->
    ok | {error, not_found | term()}.
