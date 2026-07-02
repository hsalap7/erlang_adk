%% @doc adk_mcp_server - Serve ADK tools via the Model Context Protocol.
%%
%% Allows exposing Erlang ADK tools to other clients (like Claude Desktop)
%% over stdio or SSE.
-module(adk_mcp_server).

-export([start/2, stop/1]).



%% @doc Start an MCP server to expose the given tools.
-spec start(Transport :: binary(), Tools :: [module()]) -> {ok, map()} | {error, term()}.
start(<<"stdio">>, Tools) ->
    io:format("Starting MCP server via stdio~n"),
    %% A real implementation would listen on standard input and write to standard output
    {ok, #{transport => <<"stdio">>, tools => Tools}};
start(<<"sse">>, Tools) ->
    io:format("Starting MCP server via SSE~n"),
    %% A real implementation would start a cowboy web server
    {ok, #{transport => <<"sse">>, tools => Tools}}.

%% @doc Stop the MCP server.
-spec stop(Server :: map()) -> ok.
stop(_Server) ->
    ok.
