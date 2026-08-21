%% @doc Optional hybrid lexical/vector ranking contract.
-module(adk_memory_hybrid_adapter).

-callback hybrid_search(Handle :: term(),
                        Scope :: adk_memory_service:scope(),
                        Query :: #{text := binary(), vector := [number()]},
                        Options :: map()) ->
    {ok, [map()]} | {error, term()}.
