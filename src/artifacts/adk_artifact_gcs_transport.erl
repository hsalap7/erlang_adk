%% @doc Narrow object operations required by the GCS artifact adapter.
%%
%% This boundary is intentionally lower-level than the artifact service. A
%% deterministic in-memory implementation can be injected in tests, while the
%% first-party implementation maps these calls onto the fixed Google Cloud
%% Storage JSON API. Handles are operator-trusted configuration, never values
%% derived from an agent request.
-module(adk_artifact_gcs_transport).

-type handle() :: term().
-type context() :: #{
    bucket := binary(),
    project := binary(),
    credential := {module(), term()},
    deadline := integer(),
    max_response_bytes := pos_integer()
}.
-type page() :: #{items := [binary()],
                  next_cursor := binary() | undefined}.

-export_type([handle/0, context/0, page/0]).

-callback put_if_absent(Handle :: handle(), Object :: binary(),
                        Data :: binary(), Context :: context()) ->
    ok | {error, exists | term()}.
-callback get(Handle :: handle(), Object :: binary(), Context :: context()) ->
    {ok, binary()} | {error, not_found | term()}.
-callback get_range(Handle :: handle(), Object :: binary(),
                    Offset :: non_neg_integer(), Length :: pos_integer(),
                    Context :: context()) ->
    {ok, binary()} | {error, not_found | term()}.
-callback list(Handle :: handle(), Prefix :: binary(),
               Cursor :: binary() | undefined, Limit :: pos_integer(),
               Context :: context()) ->
    {ok, page()} | {error, term()}.
-callback delete(Handle :: handle(), Object :: binary(),
                 Context :: context()) ->
    ok | {error, not_found | term()}.
