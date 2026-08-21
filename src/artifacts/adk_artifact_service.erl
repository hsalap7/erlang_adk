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
-type call_options() :: #{timeout_ms => pos_integer()}.
-type byte_range() :: #{offset := non_neg_integer(),
                        length := pos_integer()}.
-type transfer_options() :: #{timeout_ms => pos_integer(),
                              owner => pid(),
                              chunk_bytes => pos_integer(),
                              max_bytes => pos_integer(),
                              range => byte_range()}.
-type stream() :: term().
-type name_page_options() :: #{limit => pos_integer(), cursor => binary()}.
-type version_page_options() :: #{limit => pos_integer(),
                                  cursor => pos_integer()}.
-type name_page() :: #{scope := scope(),
                       items := [binary()],
                       next_cursor := binary() | undefined}.
-type version_page() :: #{items := [artifact_meta()],
                          next_cursor := pos_integer() | undefined}.
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
-type ranged_artifact() :: #{
    scope := scope(),
    name := binary(),
    version := pos_integer(),
    mime_type := binary(),
    digest := binary(),
    size := non_neg_integer(),
    created_at := integer(),
    metadata := map(),
    range := #{offset := non_neg_integer(),
               length := pos_integer(),
               total_size := non_neg_integer()},
    data := binary()
}.

-export_type([
    handle/0,
    scope/0,
    selector/0,
    delete_selector/0,
    call_options/0,
    byte_range/0,
    transfer_options/0,
    stream/0,
    name_page_options/0,
    version_page_options/0,
    name_page/0,
    version_page/0,
    artifact_meta/0,
    artifact/0,
    ranged_artifact/0
]).

-callback start_link(Config :: map()) -> {ok, handle()} | {error, term()}.
-callback capabilities(Handle :: handle()) ->
    {ok, map()} | {error, term()}.
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

%% Optional transfer contract. Implementations advertise it under the
%% `transfer' capability before callers use these callbacks. Streams use an
%% explicit credit/ack protocol so neither peer can create an unbounded
%% mailbox or binary queue.
-callback start_upload(Handle :: handle(), Scope :: scope(), Name :: binary(),
                       PutOptions :: map(),
                       TransferOptions :: transfer_options()) ->
    {ok, stream(), map()} | {error, term()}.
-callback start_download(Handle :: handle(), Scope :: scope(), Name :: binary(),
                         Selector :: selector(),
                         TransferOptions :: transfer_options()) ->
    {ok, stream(), artifact_meta()} | {error, not_found | term()}.
-callback get_range(Handle :: handle(), Scope :: scope(), Name :: binary(),
                    Selector :: selector(), Range :: byte_range(),
                    CallOptions :: call_options()) ->
    {ok, ranged_artifact()} | {error, not_found | term()}.

-optional_callbacks([start_upload/5, start_download/5, get_range/6]).
-callback put(Handle :: handle(), Scope :: scope(), Name :: binary(),
              Data :: binary(), Options :: map(),
              CallOptions :: call_options()) ->
    {ok, artifact_meta()} | {error, term()}.
-callback get(Handle :: handle(), Scope :: scope(), Name :: binary(),
              Selector :: selector(), CallOptions :: call_options()) ->
    {ok, artifact()} | {error, not_found | term()}.
-callback list_names(Handle :: handle(), Scope :: scope(),
                     Options :: name_page_options()) ->
    {ok, name_page()} | {error, term()}.
-callback list_versions(Handle :: handle(), Scope :: scope(), Name :: binary(),
                        Options :: version_page_options()) ->
    {ok, version_page()} | {error, term()}.
-callback delete(Handle :: handle(), Scope :: scope(), Name :: binary(),
                 Selector :: delete_selector(),
                 CallOptions :: call_options()) ->
    ok | {error, not_found | term()}.
