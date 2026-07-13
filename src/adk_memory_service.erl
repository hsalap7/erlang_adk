%% @doc adk_memory_service - Behaviour for long-term, semantic memory.
%%
%% Erlang ADK separates short-term working memory (sessions) from long-term
%% semantic/vector memory. This behaviour defines the interface for
%% querying and updating long-term knowledge.
-module(adk_memory_service).

-type query() :: binary().
-type filter() :: map().
-type result() :: #{
    id => binary(),
    content => binary(),
    metadata => map(),
    score => float()
}.

-export_type([query/0, filter/0, result/0]).

-callback init(Config :: map()) -> {ok, pid()} | {error, term()}.
-callback add(Pid :: pid(), Content :: binary(), Metadata :: map()) -> {ok, binary()} | {error, term()}.
-callback search(Pid :: pid(), Query :: query(), Filter :: filter(), Limit :: pos_integer()) -> {ok, [result()]} | {error, term()}.
-callback delete(Pid :: pid(), Id :: binary()) -> ok | {error, term()}.

%% Helper to index an entire session's events into long term memory.
-callback add_session_to_memory(Pid :: pid(), SessionId :: binary(), Events :: [adk_event:event()]) -> ok | {error, term()}.
