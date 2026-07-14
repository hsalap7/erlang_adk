%% @doc Cowboy boundary for the MCP 2025-11-25 Streamable HTTP transport.
-module(adk_mcp_http_handler).

-export([init/2]).

-define(JSON, <<"application/json">>).

init(Req0, Config) ->
    case authorize_request(Req0, Config) of
        ok -> dispatch(Req0, Config);
        {error, Status} ->
            reply_empty(Status, Req0, Config)
    end.

dispatch(Req0, Config) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> handle_post(Req0, Config);
        <<"GET">> ->
            %% This bounded implementation does not expose an unsolicited SSE
            %% channel. MCP explicitly permits a 405 response for GET.
            reply_empty(405, Req0, Config);
        <<"DELETE">> -> handle_delete(Req0, Config);
        _ -> reply_empty(405, Req0, Config)
    end.

handle_post(Req0, Config) ->
    case {accepts_mcp_response(Req0), json_content_type(Req0)} of
        {false, _} -> reply_empty(406, Req0, Config);
        {true, false} -> reply_empty(415, Req0, Config);
        {true, true} ->
            Max = maps:get(max_body_bytes, Config),
            case read_body(Req0, Max, [], 0) of
                {ok, Body, Req1} -> decode_and_dispatch(Body, Req1, Config);
                {error, too_large, Req1} -> reply_empty(413, Req1, Config)
            end
    end.

decode_and_dispatch(Body, Req0, Config) ->
    case decode_message(Body) of
        {ok, Message} ->
            Session = cowboy_req:header(<<"mcp-session-id">>, Req0),
            Version = cowboy_req:header(<<"mcp-protocol-version">>, Req0),
            Server = maps:get(server, Config),
            Timeout = maps:get(request_timeout, Config),
            case safe_server_call(Server, Session, Version, Message,
                                  Timeout) of
                {json, Status, Headers, Response} ->
                    BodyOut = jsx:encode(Response),
                    Req1 = cowboy_req:reply(
                             Status,
                             maps:from_list(
                               [{<<"content-type">>, ?JSON} | Headers]),
                             BodyOut, Req0),
                    {ok, Req1, Config};
                {accepted, Headers} ->
                    Req1 = cowboy_req:reply(202, maps:from_list(Headers),
                                            <<>>, Req0),
                    {ok, Req1, Config};
                {http_error, Status, Headers} ->
                    Req1 = cowboy_req:reply(Status, maps:from_list(Headers),
                                            <<>>, Req0),
                    {ok, Req1, Config}
            end;
        error ->
            Error = jsonrpc_error(null, -32700, <<"Parse error">>),
            reply_json(400, Error, Req0, Config)
    end.

decode_message(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Message when is_map(Message) -> {ok, Message};
        _ -> error
    catch _:_ -> error
    end.

safe_server_call(Server, Session, Version, Message, Timeout) ->
    try adk_mcp_server:handle_http(Server, Session, Version,
                                   Message, Timeout) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {http_error, 504, []};
        exit:_ -> {http_error, 503, []}
    end.

handle_delete(Req0, Config) ->
    Session = cowboy_req:header(<<"mcp-session-id">>, Req0),
    Version = cowboy_req:header(<<"mcp-protocol-version">>, Req0),
    Server = maps:get(server, Config),
    case adk_mcp_server:delete_session(Server, Session, Version) of
        ok -> reply_empty(204, Req0, Config);
        {error, missing_session} -> reply_empty(400, Req0, Config);
        {error, invalid_protocol_version} -> reply_empty(400, Req0, Config);
        {error, unknown_session} -> reply_empty(404, Req0, Config)
    end.

authorize_request(Req, Config) ->
    case valid_origin(Req, Config) of
        false -> {error, 403};
        true -> authorize_header(cowboy_req:header(<<"authorization">>, Req),
                                 Req, Config)
    end.

authorize_header(Header, _Req, #{auth := none}) ->
    case Header of undefined -> ok; _ -> ok end;
authorize_header(Header, _Req, #{auth := {bearer_sha256, Expected}}) ->
    case bearer_candidate(Header) of
        {ok, Candidate} ->
            Digest = crypto:hash(sha256, Candidate),
            case adk_dev_auth:constant_time_equal(Digest, Expected) of
                true -> ok;
                false -> {error, 401}
            end;
        error -> {error, 401}
    end;
authorize_header(Header, Req, #{auth := {hook, Fun}} = Config) ->
    Meta = #{authorization => Header,
             method => cowboy_req:method(Req),
             endpoint => maps:get(path, Config),
             origin => cowboy_req:header(<<"origin">>, Req),
             peer => cowboy_req:peer(Req)},
    try Fun(Meta) of
        ok -> ok;
        true -> ok;
        _ -> {error, 401}
    catch
        _:_ -> {error, 401}
    end.

bearer_candidate(undefined) -> error;
bearer_candidate(Header) when is_binary(Header) ->
    case binary:split(Header, <<" ">>) of
        [Scheme, Candidate] when byte_size(Candidate) > 0 ->
            case {lower(Scheme), valid_token(Candidate)} of
                {<<"bearer">>, true} -> {ok, Candidate};
                _ -> error
            end;
        _ -> error
    end.

valid_token(Value) ->
    lists:all(fun(C) -> C > 16#20 andalso C =/= 16#7f end,
              binary_to_list(Value)).

valid_origin(Req, Config) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined -> true;
        Origin -> lists:member(lower(Origin), maps:get(allowed_origins,
                                                       Config, []))
    end.

accepts_mcp_response(Req) ->
    case cowboy_req:header(<<"accept">>, Req) of
        undefined -> false;
        Accept ->
            Lower = lower(Accept),
            binary:match(Lower, <<"application/json">>) =/= nomatch andalso
            binary:match(Lower, <<"text/event-stream">>) =/= nomatch
    end.

json_content_type(Req) ->
    case cowboy_req:header(<<"content-type">>, Req) of
        undefined -> false;
        Value ->
            lower(hd(binary:split(Value, <<";">>))) =:= ?JSON
    end.

read_body(Req0, Max, Acc, Size) ->
    Length = cowboy_req:header(<<"content-length">>, Req0),
    case content_length_within(Length, Max) of
        false -> {error, too_large, Req0};
        true ->
            case cowboy_req:read_body(
                   Req0, #{length => erlang:min(Max + 1, 65536),
                           period => 5000}) of
                {ok, Data, Req1} ->
                    finish_body(Data, Req1, Max, Acc, Size);
                {more, Data, Req1} ->
                    NewSize = Size + byte_size(Data),
                    case NewSize =< Max of
                        true -> read_body(Req1, Max, [Data | Acc], NewSize);
                        false -> {error, too_large, Req1}
                    end
            end
    end.

finish_body(Data, Req, Max, Acc, Size) ->
    case Size + byte_size(Data) =< Max of
        true -> {ok, iolist_to_binary(lists:reverse([Data | Acc])), Req};
        false -> {error, too_large, Req}
    end.

content_length_within(undefined, _Max) -> true;
content_length_within(Value, Max) ->
    try binary_to_integer(Value) of
        Length -> Length >= 0 andalso Length =< Max
    catch _:_ -> false
    end.

reply_empty(Status, Req0, Config) ->
    Req1 = cowboy_req:reply(Status, #{}, <<>>, Req0),
    {ok, Req1, Config}.

reply_json(Status, Message, Req0, Config) ->
    Req1 = cowboy_req:reply(Status,
                            #{<<"content-type">> => ?JSON},
                            jsx:encode(Message), Req0),
    {ok, Req1, Config}.

jsonrpc_error(Id, Code, Message) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"error">> => #{<<"code">> => Code,
                        <<"message">> => Message}}.

lower(Value) ->
    list_to_binary(string:lowercase(binary_to_list(Value))).
