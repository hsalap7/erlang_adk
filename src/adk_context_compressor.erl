%% @doc Behaviour for bounded context compressors.
%%
%% Implementations receive secret-free canonical event maps. They run in an
%% isolated owner-bound process controlled by `adk_context_policy', so a crash
%% or timeout cannot take down the invocation process and caller death cannot
%% leave an orphan compressor.  Output must retain the current event exactly,
%% keep retained source events unchanged and ordered, use unique event IDs and
%% chronological timestamps, and never split a complete tool exchange.
-module(adk_context_compressor).

-callback compress(Events :: [map()], Request :: map()) ->
    {ok, [(map() | adk_event:event())]} | {error, term()}.
