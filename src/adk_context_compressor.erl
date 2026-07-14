%% @doc Behaviour for bounded context compressors.
%%
%% Implementations receive secret-free canonical event maps. They run in an
%% isolated monitored process controlled by `adk_context_policy', so a crash or
%% timeout cannot take down the invocation process.
-module(adk_context_compressor).

-callback compress(Events :: [map()], Request :: map()) ->
    {ok, [(map() | adk_event:event())]} | {error, term()}.
