%% @doc Public RFC 9728 OAuth protected-resource metadata endpoint for MCP.
%%
%% The document contains only deployment metadata and is intentionally served
%% without bearer authentication so an MCP client can discover an authorization
%% server before it has a token.
-module(adk_mcp_oauth_metadata_handler).

-export([init/2]).

init(Req0, Document) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            Req = cowboy_req:reply(
                    200,
                    #{<<"content-type">> => <<"application/json">>,
                      <<"cache-control">> => <<"public, max-age=300">>},
                    jsx:encode(Document), Req0),
            {ok, Req, Document};
        <<"HEAD">> ->
            Req = cowboy_req:reply(
                    200,
                    #{<<"content-type">> => <<"application/json">>,
                      <<"cache-control">> => <<"public, max-age=300">>},
                    <<>>, Req0),
            {ok, Req, Document};
        _ ->
            Req = cowboy_req:reply(
                    405, #{<<"allow">> => <<"GET, HEAD">>}, <<>>, Req0),
            {ok, Req, Document}
    end.
