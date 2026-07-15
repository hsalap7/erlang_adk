%% @doc Opt-in behaviour for tools that are safe to execute concurrently.
%%
%% Existing adk_tool implementations require no change and remain serial. A
%% tool may additionally implement this behaviour and return true, or a
%% resolved tool call may carry parallel_safe => true metadata.
-module(adk_parallel_tool).

-callback parallel_safe() -> boolean().
