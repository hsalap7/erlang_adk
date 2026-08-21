%% @doc Contract for scoped vector memory indexes.
-module(adk_memory_vector_adapter).

-export_type([document/0, hit/0]).

-type document() :: #{id := binary(), content := binary(),
                      vector := [number()], metadata => map()}.
-type hit() :: #{id := binary(), content := binary(), metadata := map(),
                 score := float(), score_type := cosine_similarity}.

-callback capabilities(Handle :: term()) -> map() | {ok, map()}.
-callback upsert(Handle :: term(), Scope :: adk_memory_service:scope(),
                 Documents :: [document()], Options :: map()) ->
    {ok, map()} | {error, term()}.
-callback vector_search(Handle :: term(),
                        Scope :: adk_memory_service:scope(),
                        Vector :: [number()], Options :: map()) ->
    {ok, [hit()]} | {error, term()}.
-callback delete_scope(Handle :: term(),
                       Scope :: adk_memory_service:scope()) ->
    {ok, non_neg_integer()} | {error, term()}.
