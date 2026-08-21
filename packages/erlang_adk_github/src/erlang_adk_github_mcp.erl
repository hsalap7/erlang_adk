%% @doc Minimal MCP execution boundary used by the GitHub connector.
-module(erlang_adk_github_mcp).

-callback execute_tool(Handle :: term(), Name :: binary(), Args :: map()) ->
    {ok, map()} | {error, term()}.
