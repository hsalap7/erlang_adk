%% @doc adk_mcp_client - Client for connecting to Model Context Protocol servers.
%%
%% Connects to an external MCP server (e.g. over SSE or Stdio) to discover and execute
%% tools provided by the server.
-module(adk_mcp_client).

-export([connect/2, list_tools/1, execute_tool/3, close/1]).



%% @doc Connect to an MCP server.
-spec connect(Transport :: binary(), Target :: binary()) -> {ok, pid() | map()} | {error, term()}.
connect(<<"stdio">>, Command) ->
    %% Simplified dummy implementation for now. A real implementation would spawn a port.
    io:format("Connecting to MCP server via stdio: ~p~n", [Command]),
    {ok, #{transport => <<"stdio">>, target => Command}};
connect(<<"sse">>, Url) ->
    %% Real implementation would use gun to connect via SSE.
    io:format("Connecting to MCP server via SSE: ~p~n", [Url]),
    {ok, #{transport => <<"sse">>, target => Url}}.

%% @doc List tools available on the connected server.
-spec list_tools(Client :: map()) -> {ok, [map()]} | {error, term()}.
list_tools(_Client) ->
    %% Dummy implementation: return empty toolset
    {ok, []}.

%% @doc Execute a tool on the remote server.
-spec execute_tool(Client :: map(), ToolName :: binary(), Args :: map()) -> {ok, term()} | {error, term()}.
execute_tool(_Client, ToolName, _Args) ->
    {error, {unknown_tool, ToolName}}.

%% @doc Close the connection.
-spec close(Client :: map()) -> ok.
close(_Client) ->
    ok.
