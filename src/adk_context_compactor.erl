%% @doc Provider-neutral callback for automatic context compaction.
%%
%% A compactor receives only the canonical, secret-pruned events selected for
%% replacement.  It returns summary content; the lifecycle core, not the
%% callback, constructs the durable versioned summary event and checkpoint.
%% This keeps event identity, retained-history invariants and persistence
%% metadata under ADK control.
-module(adk_context_compactor).

-callback compact(Events :: [map()], Request :: map()) ->
    {ok, binary() | adk_content:content()} | {error, term()}.

