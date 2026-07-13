%% @doc adk_mcp_server - Placeholder for a future MCP server.
%%
%% No server transport is implemented yet. start/2 fails explicitly instead
%% of returning a descriptor that could be mistaken for a listening server.
-module(adk_mcp_server).

-export([start/2, stop/1]).



%% @doc Report that the requested server transport is not implemented.
-spec start(Transport :: binary(), Tools :: [module()]) -> {ok, map()} | {error, term()}.
start(<<"stdio">>, _Tools) ->
    {error, {not_implemented, mcp_server_stdio}};
start(<<"sse">>, _Tools) ->
    {error, {not_implemented, mcp_server_sse}};
start(Transport, _Tools) ->
    {error, {unsupported_transport, Transport}}.

%% @doc Stop the MCP server.
-spec stop(Server :: map()) -> ok.
stop(_Server) ->
    ok.
