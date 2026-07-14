-module(adk_a2a_v1_client_fixture_handler).

-export([init/2]).

init(Req0, Options) ->
    Endpoint = maps:get(endpoint, Options),
    Parent = maps:get(parent, Options),
    Parent ! {a2a_client_fixture_request, Endpoint,
              cowboy_req:header(<<"authorization">>, Req0, undefined),
              cowboy_req:header(<<"a2a-extensions">>, Req0, undefined)},
    handle(Endpoint, Req0, Options).

handle(card, Req0, Options) ->
    maybe_delay(maps:get(card_delay_ms, Options, 0)),
    Card = maps:get(card, Options),
    {ok, Body} = adk_a2a_v1_card:json(Card),
    Req = cowboy_req:reply(
            200, #{<<"content-type">> => <<"application/json">>},
            Body, Req0),
    {ok, Req, Options};
handle(rpc, Req0, Options) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Request = jsx:decode(Body, [return_maps]),
    Id = maps:get(<<"id">>, Request),
    maybe_delay(maps:get(rpc_delay_ms, Options, 0)),
    Response = case maps:get(rpc_error, Options, undefined) of
        undefined ->
            #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
              <<"result">> => #{<<"fixture">> => true}};
        Error ->
            #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
              <<"error">> => Error}
    end,
    Encoded = jsx:encode(Response),
    case maps:get(slow_chunks, Options, false) of
        false ->
            Req = cowboy_req:reply(
                    200, #{<<"content-type">> => <<"application/json">>},
                    Encoded, Req1),
            {ok, Req, Options};
        true ->
            stream_slowly(Encoded, Req1, Options)
    end;
handle(redirect, Req0, Options) ->
    Req = cowboy_req:reply(
            302, #{<<"location">> => maps:get(location, Options)},
            <<>>, Req0),
    {ok, Req, Options}.

stream_slowly(Body, Req0, Options) ->
    Req = cowboy_req:stream_reply(
            200, #{<<"content-type">> => <<"application/json">>}, Req0),
    Size = byte_size(Body),
    FirstSize = erlang:max(1, Size div 3),
    SecondSize = erlang:max(1, (Size - FirstSize) div 2),
    <<First:FirstSize/binary, Second:SecondSize/binary, Last/binary>> = Body,
    ok = cowboy_req:stream_body(First, nofin, Req),
    Delay = maps:get(chunk_delay_ms, Options, 80),
    timer:sleep(Delay),
    ok = cowboy_req:stream_body(Second, nofin, Req),
    timer:sleep(Delay),
    _ = cowboy_req:stream_body(Last, fin, Req),
    {ok, Req, Options}.

maybe_delay(0) -> ok;
maybe_delay(Milliseconds) -> timer:sleep(Milliseconds).
