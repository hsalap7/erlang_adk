-module(adk_mcp_client_security_fixture_handler).

-export([init/2]).

-define(SESSION, <<"mcp-security-fixture-session">>).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"DELETE">> ->
            Req = cowboy_req:reply(204, #{}, <<>>, Req0),
            {ok, Req, State};
        <<"POST">> -> handle_post(Req0, State)
    end.

handle_post(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Message = jsx:decode(Body, [return_maps]),
    Method = maps:get(<<"method">>, Message),
    notify_request(Method, Req1, State),
    case maps:get(mode, State, normal) of
        redirect ->
            Req = cowboy_req:reply(
                    302,
                    #{<<"location">> => maps:get(location, State)},
                    <<>>, Req1),
            {ok, Req, State};
        _ -> handle_message(Method, Message, Req1, State)
    end.

handle_message(<<"initialize">>, Message, Req0, State) ->
    Id = maps:get(<<"id">>, Message),
    Response = rpc_result(
                 Id,
                 #{<<"protocolVersion">> => <<"2025-11-25">>,
                   <<"capabilities">> => #{<<"tools">> => #{}},
                   <<"serverInfo">> =>
                       #{<<"name">> => <<"security-fixture">>,
                         <<"version">> => <<"1">>}}),
    Req = cowboy_req:reply(
            200,
            #{<<"content-type">> => <<"application/json">>,
              <<"mcp-session-id">> => ?SESSION},
            jsx:encode(Response), Req0),
    {ok, Req, State};
handle_message(<<"notifications/initialized">>, _Message, Req0, State) ->
    Req = cowboy_req:reply(202, #{}, <<>>, Req0),
    {ok, Req, State};
handle_message(<<"tools/list">>, Message, Req0, State) ->
    Id = maps:get(<<"id">>, Message),
    Response = rpc_result(
                 Id,
                 #{<<"tools">> =>
                       [#{<<"name">> => <<"secure_tool">>,
                          <<"description">> => <<"Security fixture">>,
                          <<"inputSchema">> => #{<<"type">> => <<"object">>}}]}),
    Encoded = jsx:encode(Response),
    case maps:get(mode, State, normal) of
        slow_chunks -> stream_slowly(Encoded, Req0, State);
        _ ->
            Req = cowboy_req:reply(
                    200, #{<<"content-type">> => <<"application/json">>},
                    Encoded, Req0),
            {ok, Req, State}
    end.

notify_request(Method, Req, State) ->
    maps:get(parent, State) !
        {mcp_security_fixture_request,
         maps:get(ref, State), Method,
         cowboy_req:header(<<"host">>, Req, undefined),
         cowboy_req:header(<<"authorization">>, Req, undefined),
         cowboy_req:header(<<"proxy-authorization">>, Req, undefined)},
    ok.

stream_slowly(Body, Req0, State) ->
    Req = cowboy_req:stream_reply(
            200, #{<<"content-type">> => <<"application/json">>}, Req0),
    Size = byte_size(Body),
    FirstSize = erlang:max(1, Size div 3),
    SecondSize = erlang:max(1, (Size - FirstSize) div 2),
    <<First:FirstSize/binary, Second:SecondSize/binary, Last/binary>> = Body,
    ok = cowboy_req:stream_body(First, nofin, Req),
    Delay = maps:get(chunk_delay_ms, State, 80),
    timer:sleep(Delay),
    ok = cowboy_req:stream_body(Second, nofin, Req),
    timer:sleep(Delay),
    _ = cowboy_req:stream_body(Last, fin, Req),
    {ok, Req, State}.

rpc_result(Id, Result) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"result">> => Result}.
