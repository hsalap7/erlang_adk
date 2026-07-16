-module(adk_mcp_sse_fixture_handler).

-export([init/2]).

-define(SESSION, <<"deterministic-sse-session">>).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"DELETE">> ->
            Req1 = cowboy_req:reply(204, #{}, <<>>, Req0),
            {ok, Req1, State};
        <<"POST">> -> handle_post(Req0, State)
    end.

handle_post(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Message = jsx:decode(Body, [return_maps]),
    case maps:get(<<"method">>, Message) of
        <<"initialize">> ->
            Id = maps:get(<<"id">>, Message),
            Response = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                         <<"result">> =>
                             #{<<"protocolVersion">> => <<"2025-11-25">>,
                               <<"capabilities">> => #{<<"tools">> => #{}},
                               <<"serverInfo">> =>
                                   #{<<"name">> => <<"sse-fixture">>,
                                     <<"version">> => <<"1">>}}},
            Req2 = cowboy_req:reply(
                     200,
                     #{<<"content-type">> => <<"application/json">>,
                       <<"mcp-session-id">> => ?SESSION},
                     jsx:encode(Response), Req1),
            {ok, Req2, State};
        <<"notifications/initialized">> ->
            true = valid_session_headers(Req1),
            Req2 = cowboy_req:reply(202, #{}, <<>>, Req1),
            {ok, Req2, State};
        <<"tools/list">> ->
            true = valid_session_headers(Req1),
            Id = maps:get(<<"id">>, Message),
            Response = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                         <<"result">> =>
                             #{<<"tools">> =>
                                   [#{<<"name">> => <<"sse_tool">>,
                                      <<"description">> =>
                                          <<"SSE response fixture">>,
                                      <<"inputSchema">> =>
                                          #{<<"type">> => <<"object">>}}]}},
            Sse = <<"event: message\n", "data: ",
                    (jsx:encode(Response))/binary, "\n\n">>,
            Req2 = cowboy_req:reply(
                     200, #{<<"content-type">> => <<"text/event-stream">>},
                     Sse, Req1),
            {ok, Req2, State}
    end.

valid_session_headers(Req) ->
    cowboy_req:header(<<"mcp-session-id">>, Req) =:= ?SESSION andalso
    cowboy_req:header(<<"mcp-protocol-version">>, Req) =:= <<"2025-11-25">>.
