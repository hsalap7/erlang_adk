%% @doc Cowboy boundary for the A2A 1.0 Agent Card and JSON-RPC/SSE binding.
-module(adk_a2a_v1_handler).

-export([init/2]).

-define(JSON, <<"application/json">>).
-define(SSE, <<"text/event-stream">>).

init(Req0, Config = #{endpoint := card}) ->
    handle_card(Req0, Config);
init(Req0, Config = #{endpoint := jsonrpc}) ->
    handle_rpc(Req0, Config).

handle_card(Req0, Config) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            case adk_a2a_v1_server:card(maps:get(server, Config)) of
                {ok, Card} ->
                    {ok, Body} = adk_a2a_v1_card:json(Card),
                    Req1 = cowboy_req:reply(
                             200, #{<<"content-type">> => ?JSON,
                                    <<"cache-control">> =>
                                        <<"public, max-age=300">>},
                             Body, Req0),
                    {ok, Req1, Config}
            end;
        _ -> method_not_allowed(<<"GET">>, Req0, Config)
    end.

handle_rpc(Req0, Config) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            case json_content_type(Req0) of
                true -> read_rpc_body(Req0, Config);
                false -> reply_empty(415, Req0, Config)
            end;
        _ -> method_not_allowed(<<"POST">>, Req0, Config)
    end.

read_rpc_body(Req0, Config) ->
    Max = maps:get(max_body_bytes, Config, 1048576),
    case read_body(Req0, Max, [], 0) of
        {ok, Body, Req1} -> decode_rpc(Body, Req1, Config);
        {error, too_large, Req1} -> reply_empty(413, Req1, Config)
    end.

decode_rpc(Body, Req0, Config) ->
    try jsx:decode(Body, [return_maps]) of
        Request ->
            case adk_a2a_v1_codec:validate_jsonrpc_request(Request) of
                {ok, Id, Method, Params} ->
                    dispatch_versioned(Id, Method, Params, Req0, Config);
                {error, Id, Code, Message} ->
                    reply_json(400,
                               adk_a2a_v1_codec:error_response(
                                 Id, Code, Message), Req0, Config)
            end
    catch
        _:_ ->
            reply_json(400,
                       adk_a2a_v1_codec:error_response(
                         null, -32700, <<"Invalid JSON payload">>),
                       Req0, Config)
    end.

dispatch_versioned(Id, Method, Params, Req0, Config) ->
    case cowboy_req:header(<<"a2a-version">>, Req0) of
        <<"1.0">> -> authorize_and_dispatch(Id, Method, Params, Req0, Config);
        _ ->
            Error = adk_a2a_v1_codec:error_response(
                      Id, -32009, <<"A2A protocol version not supported">>,
                      [#{<<"@type">> =>
                             <<"type.googleapis.com/google.rpc.ErrorInfo">>,
                         <<"reason">> => <<"VERSION_NOT_SUPPORTED">>,
                         <<"domain">> => <<"a2a-protocol.org">>}]),
            reply_json(200, Error, Req0, Config)
    end.

authorize_and_dispatch(Id, Method, Params, Req0, Config) ->
    Headers = cowboy_req:headers(Req0),
    Summary = #{method => Method,
                path => cowboy_req:path(Req0),
                peer => peer_ip(Req0)},
    Hook = maps:get(auth, Config, none),
    case adk_a2a_v1_auth:authorize(Hook, Method, Headers, Summary) of
        {ok, Auth} ->
            dispatch_authorized(Id, Method, Params, Auth, Req0, Config);
        {error, unauthenticated} ->
            Req1 = cowboy_req:reply(
                     401, #{<<"www-authenticate">> => <<"Bearer">>},
                     <<>>, Req0),
            {ok, Req1, Config};
        {error, forbidden} -> reply_empty(403, Req0, Config)
    end.

dispatch_authorized(Id, Method, Params, Auth, Req0, Config) ->
    case adk_a2a_v1_rpc:method_type(Method) of
        unary ->
            Server = maps:get(server, Config),
            case adk_a2a_v1_rpc:dispatch(Server, Auth, Id, Method, Params) of
                {ok, Response} -> reply_json(200, Response, Req0, Config);
                {error, Response} -> reply_json(200, Response, Req0, Config)
            end;
        stream ->
            case streaming_enabled(Config) andalso accepts_sse(Req0) of
                true -> open_stream(Id, Method, Params, Auth, Req0, Config);
                false ->
                    Error = adk_a2a_v1_rpc:rpc_error(
                              Id, stream_method_requires_sse),
                    reply_json(200, Error, Req0, Config)
            end;
        unknown ->
            reply_json(200,
                       adk_a2a_v1_codec:error_response(
                         Id, -32601, <<"Method not found">>),
                       Req0, Config)
    end.

open_stream(Id, <<"SendStreamingMessage">>, Params, Auth, Req0, Config) ->
    Server = maps:get(server, Config),
    case adk_a2a_v1_server:send_message(Server, Auth, Params, self()) of
        {ok, #{task_id := TaskId, frames := Frames}} ->
            stream_frames(Id, TaskId, Frames, Req0, Config);
        {error, {execution_start_failed, _Reason,
                 #{task_id := TaskId, frames := Frames}}} ->
            stream_frames(Id, TaskId, Frames, Req0, Config);
        {error, Reason} ->
            reply_json(200, adk_a2a_v1_rpc:rpc_error(Id, Reason),
                       Req0, Config)
    end;
open_stream(Id, <<"SubscribeToTask">>, Params0, Auth, Req0, Config) ->
    case last_event_id(Req0) of
        {error, _} ->
            reply_json(400, adk_a2a_v1_rpc:rpc_error(
                              Id, invalid_last_event_id), Req0, Config);
        {ok, Cursor} ->
            Params = Params0#{last_event_id => Cursor},
            Server = maps:get(server, Config),
            case adk_a2a_v1_server:subscribe(
                   Server, maps:get(scope, Auth), Params, self()) of
                {ok, TaskId, Frames} ->
                    stream_frames(Id, TaskId, Frames, Req0, Config);
                {error, Reason} ->
                    reply_json(200, adk_a2a_v1_rpc:rpc_error(Id, Reason),
                               Req0, Config)
            end
    end.

stream_frames(Id, TaskId, Frames, Req0, Config) ->
    Headers = #{<<"content-type">> => ?SSE,
                <<"cache-control">> => <<"no-cache, no-transform">>,
                <<"x-accel-buffering">> => <<"no">>},
    Req1 = cowboy_req:stream_reply(200, Headers, Req0),
    try send_initial_frames(Id, Frames, Req1) of
        {closed, _Terminal} -> {ok, Req1, Config};
        {ok, true} ->
            _ = safe_stream_body(<<>>, fin, Req1),
            {ok, Req1, Config};
        {ok, false} ->
            Req2 = sse_loop(Id, TaskId,
                            maps:get(sse_heartbeat_ms, Config, 15000), Req1),
            {ok, Req2, Config}
    after
        _ = catch adk_a2a_v1_server:unsubscribe(
                    maps:get(server, Config), TaskId, self())
    end.

send_initial_frames(_Id, [], _Req) -> {ok, false};
send_initial_frames(Id, [{Seq, Payload} | Rest], Req) ->
    Terminal = payload_terminal(Payload),
    case stream_sse(Id, Seq, Payload, nofin, Req) of
        ok ->
            case {Terminal, Rest} of
                {true, _} -> {ok, true};
                {false, []} -> {ok, false};
                {false, _} -> send_initial_frames(Id, Rest, Req)
            end;
        closed -> {closed, Terminal}
    end.

sse_loop(Id, TaskId, Heartbeat, Req) ->
    receive
        {adk_a2a_v1_event, TaskId, Seq, Payload, Terminal} ->
            Fin = case Terminal of true -> fin; false -> nofin end,
            case stream_sse(Id, Seq, Payload, Fin, Req) of
                ok when Terminal -> Req;
                ok -> sse_loop(Id, TaskId, Heartbeat, Req);
                closed -> Req
            end
    after Heartbeat ->
        case safe_stream_body(<<": heartbeat\n\n">>, nofin, Req) of
            ok -> sse_loop(Id, TaskId, Heartbeat, Req);
            closed -> Req
        end
    end.

stream_sse(Id, Seq, Payload, Fin, Req) ->
    Json = jsx:encode(adk_a2a_v1_codec:result(Id, Payload)),
    Body = <<"id: ", (integer_to_binary(Seq))/binary,
             "\ndata: ", Json/binary, "\n\n">>,
    safe_stream_body(Body, Fin, Req).

payload_terminal(#{<<"task">> := Task}) ->
    adk_a2a_v1_codec:terminal_state(adk_a2a_v1_rpc:task_state(Task));
payload_terminal(#{<<"statusUpdate">> :=
                       #{<<"status">> := #{<<"state">> := State}}}) ->
    adk_a2a_v1_codec:terminal_state(State);
payload_terminal(_) -> false.

streaming_enabled(Config) ->
    {ok, Card} = adk_a2a_v1_server:card(maps:get(server, Config)),
    maps:get(<<"streaming">>, maps:get(<<"capabilities">>, Card), false).

accepts_sse(Req) ->
    case cowboy_req:header(<<"accept">>, Req) of
        undefined -> true;
        Value -> binary:match(lower(Value), ?SSE) =/= nomatch
    end.

last_event_id(Req) ->
    case cowboy_req:header(<<"last-event-id">>, Req) of
        undefined -> {ok, 0};
        <<>> -> {ok, 0};
        Value ->
            try binary_to_integer(Value) of
                N when N >= 0 -> {ok, N};
                _ -> {error, invalid_last_event_id}
            catch _:_ -> {error, invalid_last_event_id}
            end
    end.

json_content_type(Req) ->
    case cowboy_req:header(<<"content-type">>, Req) of
        undefined -> false;
        Value -> lower(hd(binary:split(Value, <<";">>))) =:= ?JSON
    end.

read_body(Req0, Max, Acc, Size) ->
    case content_length_within(cowboy_req:header(<<"content-length">>, Req0),
                               Max) of
        false -> {error, too_large, Req0};
        true ->
            case cowboy_req:read_body(
                   Req0, #{length => erlang:min(Max + 1, 65536),
                           period => 5000}) of
                {ok, Data, Req1} -> finish_body(Data, Req1, Max, Acc, Size);
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

reply_json(Status, Message, Req0, Config) ->
    Req1 = cowboy_req:reply(
             Status, #{<<"content-type">> => ?JSON,
                       <<"cache-control">> => <<"no-store">>},
             jsx:encode(Message), Req0),
    {ok, Req1, Config}.

reply_empty(Status, Req0, Config) ->
    Req1 = cowboy_req:reply(Status, #{<<"cache-control">> => <<"no-store">>},
                            <<>>, Req0),
    {ok, Req1, Config}.

method_not_allowed(Allowed, Req0, Config) ->
    Req1 = cowboy_req:reply(405, #{<<"allow">> => Allowed}, <<>>, Req0),
    {ok, Req1, Config}.

safe_stream_body(Body, Fin, Req) ->
    try cowboy_req:stream_body(Body, Fin, Req) of
        ok -> ok
    catch _:_ -> closed
    end.

peer_ip(Req) ->
    {Ip, _Port} = cowboy_req:peer(Req),
    Ip.

lower(Value) -> list_to_binary(string:lowercase(binary_to_list(Value))).
