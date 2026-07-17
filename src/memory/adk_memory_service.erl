%% @doc Versioned contract for cross-session long-term memory.
%%
%% Version 2 makes the application/user authority explicit.  Implementations
%% must never infer a principal from caller supplied metadata.  The old
%% add/search/delete/session callbacks remain as compatibility entry points;
%% new runtime code should feature-detect `contract_version => 2' and use the
%% scoped operations.
-module(adk_memory_service).

-type handle() :: term().
-type scope() :: {user, AppName :: binary(), UserId :: binary()}.
-type query() :: binary().
-type filter() :: map().
-type provenance() :: #{
    session_id => binary(),
    event_ids => [binary()],
    author => binary(),
    timestamp => integer()
}.
-type entry_input() :: #{
    content := binary(),
    metadata => map(),
    provenance => provenance()
}.
-type entry() :: #{
    schema_version := pos_integer(),
    id := binary(),
    scope := scope(),
    content := binary(),
    metadata := map(),
    provenance := map(),
    digest := binary(),
    timestamp := integer()
}.
-type hit() :: entry() | #{
    id := binary(),
    scope := scope(),
    content := binary(),
    metadata := map(),
    provenance := map(),
    score := float(),
    score_type := lexical_overlap,
    timestamp := integer()
}.
-type ingest_result() :: #{added := non_neg_integer(),
                           duplicates := non_neg_integer(),
                           skipped := non_neg_integer()}.
-type call_options() :: #{timeout_ms => pos_integer()}.

-export_type([handle/0, scope/0, query/0, filter/0, provenance/0,
              entry_input/0, entry/0, hit/0, ingest_result/0,
              call_options/0]).

%% Version 2 API.  `Opts' carries bounded filter/limit/idempotency options;
%% adapters reject unknown options rather than silently changing semantics.
-callback capabilities(Handle :: handle()) -> map().
-callback add_entry(Handle :: handle(), Scope :: scope(),
                    Input :: entry_input(), Opts :: map()) ->
    {ok, entry()} | {error, term()}.
-callback add_events(Handle :: handle(), Scope :: scope(),
                     SessionId :: binary(), Events :: [adk_event:event()],
                     Opts :: map()) ->
    {ok, ingest_result()} | {error, term()}.
-callback add_session_to_memory(Handle :: handle(), Scope :: scope(),
                                SessionId :: binary(),
                                Events :: [adk_event:event()], Opts :: map()) ->
    {ok, ingest_result()} | {error, term()}.
-callback search(Handle :: handle(), ScopeOrQuery :: scope() | query(),
                 QueryOrFilter :: query() | filter(), OptsOrLimit :: map() | pos_integer()) ->
    {ok, [hit()]} | {error, term()}.
-callback delete_entry(Handle :: handle(), Scope :: scope(), Id :: binary()) ->
    ok | {error, not_found | term()}.
-callback delete_session(Handle :: handle(), Scope :: scope(),
                         SessionId :: binary()) ->
    ok | {error, not_found | term()}.
-callback delete_user(Handle :: handle(), Scope :: scope()) ->
    ok | {error, not_found | term()}.

%% Deadline-aware variants are used by least-authority contexts. The adapter
%% must embed the deadline in queued work so a timed-out caller cannot observe
%% a later invisible mutation.
-callback add_entry(Handle :: handle(), Scope :: scope(),
                    Input :: entry_input(), Opts :: map(),
                    CallOptions :: call_options()) ->
    {ok, entry()} | {error, term()}.
-callback add_events(Handle :: handle(), Scope :: scope(),
                     SessionId :: binary(), Events :: [adk_event:event()],
                     Opts :: map(), CallOptions :: call_options()) ->
    {ok, ingest_result()} | {error, term()}.
-callback search(Handle :: handle(), Scope :: scope(), Query :: query(),
                 Opts :: map(), CallOptions :: call_options()) ->
    {ok, [hit()]} | {error, term()}.
-callback delete_entry(Handle :: handle(), Scope :: scope(), Id :: binary(),
                       CallOptions :: call_options()) ->
    ok | {error, not_found | term()}.
-callback delete_session(Handle :: handle(), Scope :: scope(),
                         SessionId :: binary(),
                         CallOptions :: call_options()) ->
    ok | {error, not_found | term()}.
-callback delete_user(Handle :: handle(), Scope :: scope(),
                      CallOptions :: call_options()) ->
    ok | {error, not_found | term()}.

%% Version 1 compatibility API.  Constructors are deliberately not callbacks:
%% OTP adapters use `init/1' for their process callback while older adapters
%% may still expose an `init/1' convenience function.
-callback add(Handle :: handle(), Content :: binary(), Metadata :: map()) ->
    {ok, binary()} | {error, term()}.
-callback delete(Handle :: handle(), Id :: binary()) ->
    ok | {error, term()}.
-callback add_session_to_memory(Handle :: handle(), SessionId :: binary(),
                                Events :: [adk_event:event()]) ->
    ok | {error, term()}.

%% Erlang behaviours cannot express "implement either the v2 set or the v1
%% set".  Keep the callbacks that distinguish each contract optional and let
%% `adk_service_ref:validate/2' enforce one complete set at the integration
%% boundary. `search/4' is shared by both contracts and remains mandatory.
-optional_callbacks([capabilities/1, add_entry/4, add_events/5,
                     add_session_to_memory/5, delete_entry/3,
                     delete_session/3, delete_user/2,
                     add/3, delete/2, add_session_to_memory/3,
                     add_entry/5, add_events/6, search/5,
                     delete_entry/4, delete_session/4, delete_user/3]).
