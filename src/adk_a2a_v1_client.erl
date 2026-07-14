%% @doc Bounded outbound client for the A2A 1.0 JSON-RPC binding.
%%
%% The client discovers and validates the Agent Card before selecting the first
%% JSONRPC/1.0 interface. Authentication headers are obtained just-in-time from
%% `auth_fun`; they are never retained in returned values or error terms.
-module(adk_a2a_v1_client).

-export([discover/1, discover/2,
         send/3, send_stream/3,
         get_task/3, list_tasks/3, cancel_task/3,
         subscribe/3]).

-define(DEFAULT_TIMEOUT, 65000).
-define(DEFAULT_CONNECT_TIMEOUT, 10000).
-define(DEFAULT_MAX_BYTES, 8388608).
-define(DEFAULT_MAX_EVENTS, 1024).

-spec discover(binary() | string()) -> {ok, map()} | {error, term()}.
discover(Location) -> discover(Location, #{}).

-spec discover(binary() | string(), map()) ->
    {ok, map()} | {error, term()}.
discover(Location, Options0) ->
    case normalize_options(Options0) of
        {ok, Options} ->
            case discovery_url(Location) of
                {ok, Url} ->
                    Headers = [{<<"accept">>, <<"application/json">>}],
                    case request(<<"GET">>, Url, Headers, <<>>, Options) of
                        {ok, 200, RespHeaders, Body} ->
                            case content_type(RespHeaders) of
                                <<"application/json">> -> decode_card(Body);
                                _ -> {error, invalid_agent_card_content_type}
                            end;
                        {ok, Status, _Headers, _Body} ->
                            {error, {agent_card_http_status, Status}};
                        {error, _} = Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

-spec send(map() | binary() | string(), map(), map()) ->
    {ok, map()} | {error, term()}.
send(Target, Message, Options) ->
    rpc_message(Target, <<"SendMessage">>, Message, Options, unary).

-spec send_stream(map() | binary() | string(), map(), map()) ->
    {ok, [map()]} | {error, term()}.
send_stream(Target, Message, Options) ->
    rpc_message(Target, <<"SendStreamingMessage">>, Message,
                Options, stream).

-spec get_task(map() | binary() | string(), binary(), map()) ->
    {ok, map()} | {error, term()}.
get_task(Target, TaskId, Options) ->
    rpc(Target, <<"GetTask">>, #{<<"id">> => TaskId}, Options, unary).

-spec list_tasks(map() | binary() | string(), map(), map()) ->
    {ok, map()} | {error, term()}.
list_tasks(Target, Params, Options) ->
    rpc(Target, <<"ListTasks">>, Params, Options, unary).

-spec cancel_task(map() | binary() | string(), binary(), map()) ->
    {ok, map()} | {error, term()}.
cancel_task(Target, TaskId, Options) ->
    rpc(Target, <<"CancelTask">>, #{<<"id">> => TaskId}, Options, unary).

-spec subscribe(map() | binary() | string(), binary(), map()) ->
    {ok, [map()]} | {error, term()}.
subscribe(Target, TaskId, Options) ->
    rpc(Target, <<"SubscribeToTask">>, #{<<"id">> => TaskId},
        Options, stream).

rpc_message(Target, Method, Message0, Options, Mode) ->
    case adk_a2a_v1_codec:validate_message(Message0) of
        {ok, Message} ->
            Config = maps:get(configuration, Options, #{}),
            Metadata = maps:get(metadata, Options, #{}),
            Params0 = #{<<"message">> => Message},
            Params1 = case Config of
                Map when is_map(Map), map_size(Map) > 0 ->
                    Params0#{<<"configuration">> => Map};
                _ -> Params0
            end,
            Params = case Metadata of
                Map2 when is_map(Map2), map_size(Map2) > 0 ->
                    Params1#{<<"metadata">> => Map2};
                _ -> Params1
            end,
            rpc(Target, Method, Params, Options, Mode);
        {error, Reason} -> {error, Reason}
    end.

rpc(Target, Method, Params0, Options0, Mode) when is_map(Params0) ->
    case normalize_options(Options0) of
        {ok, Options} ->
            case resolve_card(Target, Options) of
                {ok, Card} ->
                    {ok, Interface} = adk_a2a_v1_card:jsonrpc_interface(Card),
                    Params = maybe_tenant(Params0, Interface),
                    Id = erlang:unique_integer([positive, monotonic]),
                    Request = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                                <<"method">> => Method, <<"params">> => Params},
                    Url = maps:get(<<"url">>, Interface),
                    rpc_http(Mode, Url, Id, Request, Options);
                Error -> Error
            end;
        Error -> Error
    end;
rpc(_Target, _Method, _Params, _Options, _Mode) ->
    {error, invalid_a2a_params}.

rpc_http(Mode, Url, Id, RpcRequest, Options) ->
    Accept = case Mode of
        unary -> <<"application/json">>;
        stream -> <<"text/event-stream">>
    end,
    LastEvent = case {Mode, maps:get(last_event_id, Options)} of
        {stream, N} when is_integer(N), N >= 0 ->
            [{<<"last-event-id">>, integer_to_binary(N)}];
        _ -> []
    end,
    Headers = [{<<"accept">>, Accept},
               {<<"content-type">>, <<"application/json">>},
               {<<"a2a-version">>, <<"1.0">>}] ++ LastEvent,
    case request(<<"POST">>, Url, Headers, jsx:encode(RpcRequest), Options) of
        {ok, 200, RespHeaders, Body} ->
            decode_rpc_http(Mode, content_type(RespHeaders), Body, Id, Options);
        {ok, Status, _Headers, _Body} ->
            {error, {a2a_http_status, Status}};
        {error, _} = Error -> Error
    end.

decode_rpc_http(unary, <<"application/json">>, Body, Id, _Options) ->
    decode_unary(Body, Id);
decode_rpc_http(stream, <<"text/event-stream">>, Body, Id, Options) ->
    decode_sse(Body, Id, maps:get(max_events, Options));
decode_rpc_http(_Mode, _Type, _Body, _Id, _Options) ->
    {error, invalid_a2a_response_content_type}.

decode_unary(Body, Id) ->
    try jsx:decode(Body, [return_maps]) of
        #{<<"jsonrpc">> := <<"2.0">>, <<"id">> := Id,
          <<"result">> := Result} -> {ok, Result};
        #{<<"jsonrpc">> := <<"2.0">>, <<"id">> := Id,
          <<"error">> := Error} when is_map(Error) ->
            {error, {a2a_error, Error}};
        _ -> {error, invalid_a2a_jsonrpc_response}
    catch _:_ -> {error, invalid_a2a_json_response}
    end.

decode_sse(Body, Id, MaxEvents) ->
    Blocks = [Block || Block <- binary:split(normalize_newlines(Body),
                                              <<"\n\n">>, [global]),
                       byte_size(Block) > 0],
    case length(Blocks) =< MaxEvents of
        false -> {error, too_many_a2a_stream_events};
        true -> decode_sse_blocks(Blocks, Id, undefined, [], first)
    end.

decode_sse_blocks([], _Id, _LastSeq, Acc, _Position) ->
    case Acc of
        [] -> {error, empty_a2a_stream};
        _ -> {ok, lists:reverse(Acc)}
    end;
decode_sse_blocks([Block | Rest], Id, LastSeq, Acc, Position) ->
    case sse_block(Block) of
        comment -> decode_sse_blocks(Rest, Id, LastSeq, Acc, Position);
        {ok, Seq, Data} ->
            case valid_sequence(LastSeq, Seq) of
                false -> {error, invalid_a2a_stream_order};
                true ->
                    case decode_stream_envelope(Data, Id) of
                        {ok, Payload} ->
                            case valid_stream_position(Position, Payload) of
                                true ->
                                    decode_sse_blocks(Rest, Id, Seq,
                                                      [Payload | Acc], next);
                                false ->
                                    {error, invalid_a2a_stream_sequence}
                            end;
                        Error -> Error
                    end
            end;
        {error, _} = Error -> Error
    end.

sse_block(Block) ->
    Lines = binary:split(Block, <<"\n">>, [global]),
    DataLines = [trim_left(binary:part(Line, 5, byte_size(Line) - 5))
                 || Line <- Lines, has_prefix(Line, <<"data:">>)],
    IdLines = [trim_left(binary:part(Line, 3, byte_size(Line) - 3))
               || Line <- Lines, has_prefix(Line, <<"id:">>)],
    case {DataLines, IdLines} of
        {[], _} -> comment;
        {_, [SeqBinary]} ->
            try binary_to_integer(SeqBinary) of
                Seq when Seq >= 0 ->
                    {ok, Seq, iolist_to_binary(lists:join(<<"\n">>,
                                                         DataLines))};
                _ -> {error, invalid_a2a_sse_id}
            catch _:_ -> {error, invalid_a2a_sse_id}
            end;
        _ -> {error, invalid_a2a_sse_event}
    end.

decode_stream_envelope(Data, Id) ->
    try jsx:decode(Data, [return_maps]) of
        #{<<"jsonrpc">> := <<"2.0">>, <<"id">> := Id,
          <<"result">> := Payload} ->
            adk_a2a_v1_codec:validate_stream_response(Payload);
        #{<<"jsonrpc">> := <<"2.0">>, <<"id">> := Id,
          <<"error">> := Error} -> {error, {a2a_error, Error}};
        _ -> {error, invalid_a2a_stream_envelope}
    catch _:_ -> {error, invalid_a2a_stream_json}
    end.

valid_stream_position(first, Payload) ->
    maps:is_key(<<"task">>, Payload) orelse maps:is_key(<<"message">>, Payload);
valid_stream_position(next, Payload) ->
    maps:is_key(<<"statusUpdate">>, Payload) orelse
    maps:is_key(<<"artifactUpdate">>, Payload).

valid_sequence(undefined, _Seq) -> true;
valid_sequence(Previous, Seq) -> Seq > Previous.

%% HTTP transport

request(Method, Url, Headers0, Body, Options) ->
    case parse_url(Url) of
        {ok, Endpoint} ->
            case dynamic_headers(Options) of
                {ok, Dynamic} ->
                    Headers = Headers0 ++ maps:get(headers, Options) ++ Dynamic,
                    with_connection(
                      Endpoint, Options,
                      fun(Conn) ->
                          Ref = gun:request(Conn, Method,
                                            maps:get(path, Endpoint),
                                            Headers, Body),
                          await_response(Conn, Ref, Options)
                      end);
                Error -> Error
            end;
        Error -> Error
    end.

with_connection(Endpoint, Options, Fun) ->
    Host = binary_to_list(maps:get(host, Endpoint)),
    Port = maps:get(port, Endpoint),
    GunOptions = gun_options(maps:get(scheme, Endpoint), Options),
    case gun:open(Host, Port, GunOptions) of
        {ok, Conn} ->
            try gun:await_up(Conn, maps:get(connect_timeout, Options)) of
                {ok, _Protocol} -> Fun(Conn);
                {error, _} -> {error, a2a_connect_failed}
            after
                _ = catch gun:close(Conn)
            end;
        {error, _} -> {error, a2a_connect_failed}
    end.

await_response(Conn, Ref, Options) ->
    Timeout = maps:get(timeout, Options),
    case gun:await(Conn, Ref, Timeout) of
        {response, fin, Status, Headers} ->
            {ok, Status, Headers, <<>>};
        {response, nofin, Status, Headers} ->
            case await_body(Conn, Ref, Timeout,
                            maps:get(max_response_bytes, Options), [], 0) of
                {ok, Body} -> {ok, Status, Headers, Body};
                Error -> Error
            end;
        {error, _} -> {error, a2a_transport_failed};
        _ -> {error, invalid_a2a_http_response}
    end.

await_body(Conn, Ref, Timeout, Max, Acc, Size) ->
    case gun:await(Conn, Ref, Timeout) of
        {data, Fin, Data} when is_binary(Data) ->
            NewSize = Size + byte_size(Data),
            case NewSize =< Max of
                false ->
                    _ = catch gun:cancel(Conn, Ref),
                    {error, a2a_response_too_large};
                true when Fin =:= fin ->
                    {ok, iolist_to_binary(lists:reverse([Data | Acc]))};
                true -> await_body(Conn, Ref, Timeout, Max,
                                   [Data | Acc], NewSize)
            end;
        {trailers, _} -> {ok, iolist_to_binary(lists:reverse(Acc))};
        {error, _} -> {error, a2a_transport_failed};
        _ -> {error, invalid_a2a_http_body}
    end.

parse_url(Url0) ->
    Url = to_binary(Url0),
    try uri_string:parse(Url) of
        Parsed when is_map(Parsed) ->
            Scheme = to_binary(maps:get(scheme, Parsed, <<>>)),
            Host = to_binary(maps:get(host, Parsed, <<>>)),
            UserInfo = maps:get(userinfo, Parsed, undefined),
            Fragment = maps:get(fragment, Parsed, undefined),
            case (Scheme =:= <<"http">> orelse Scheme =:= <<"https">>)
                 andalso byte_size(Host) > 0
                 andalso UserInfo =:= undefined
                 andalso Fragment =:= undefined of
                false -> {error, invalid_a2a_url};
                true ->
                    Port = maps:get(port, Parsed,
                                    case Scheme of <<"https">> -> 443;
                                                   _ -> 80 end),
                    Path0 = to_binary(maps:get(path, Parsed, <<"/">>)),
                    Path1 = case Path0 of <<>> -> <<"/">>; _ -> Path0 end,
                    Path = case maps:find(query, Parsed) of
                        {ok, Query} -> <<Path1/binary, "?",
                                         (to_binary(Query))/binary>>;
                        error -> Path1
                    end,
                    {ok, #{scheme => Scheme, host => Host,
                           port => Port, path => Path}}
            end
    catch _:_ -> {error, invalid_a2a_url}
    end.

gun_options(<<"http">>, _Options) -> #{transport => tcp};
gun_options(<<"https">>, Options) ->
    Tls = case maps:get(tls_opts, Options) of
        default ->
            [{verify, verify_peer},
             {cacerts, public_key:cacerts_get()},
             {customize_hostname_check,
              [{match_fun,
                public_key:pkix_verify_hostname_match_fun(https)}]}];
        Value -> Value
    end,
    #{transport => tls, tls_opts => Tls}.

%% card/options/helpers

resolve_card(Card, _Options) when is_map(Card) ->
    adk_a2a_v1_card:validate(Card);
resolve_card(Location, Options) -> discover(Location, Options).

decode_card(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Card -> adk_a2a_v1_card:validate(Card)
    catch _:_ -> {error, invalid_agent_card_json}
    end.

discovery_url(Location0) ->
    Location = to_binary(Location0),
    case parse_url(Location) of
        {ok, Endpoint} ->
            case maps:get(path, Endpoint) of
                <<"/.well-known/agent-card.json">> -> {ok, Location};
                _ ->
                    Scheme = maps:get(scheme, Endpoint),
                    Host = maps:get(host, Endpoint),
                    Port = maps:get(port, Endpoint),
                    Default = (Scheme =:= <<"http">> andalso Port =:= 80)
                              orelse (Scheme =:= <<"https">> andalso
                                      Port =:= 443),
                    Authority = case Default of
                        true -> Host;
                        false -> <<Host/binary, ":",
                                   (integer_to_binary(Port))/binary>>
                    end,
                    {ok, <<Scheme/binary, "://", Authority/binary,
                           "/.well-known/agent-card.json">>}
            end;
        Error -> Error
    end.

maybe_tenant(Params, Interface) ->
    case maps:find(<<"tenant">>, Interface) of
        {ok, Tenant} -> Params#{<<"tenant">> => Tenant};
        error -> Params
    end.

normalize_options(Options) when is_map(Options) ->
    Timeout = maps:get(timeout, Options, ?DEFAULT_TIMEOUT),
    Connect = maps:get(connect_timeout, Options,
                       ?DEFAULT_CONNECT_TIMEOUT),
    MaxBytes = maps:get(max_response_bytes, Options, ?DEFAULT_MAX_BYTES),
    MaxEvents = maps:get(max_events, Options, ?DEFAULT_MAX_EVENTS),
    Headers = maps:get(headers, Options, []),
    AuthFun = maps:get(auth_fun, Options, undefined),
    TlsOpts = maps:get(tls_opts, Options, default),
    LastEvent = maps:get(last_event_id, Options, undefined),
    case positive_integer(Timeout) andalso positive_integer(Connect)
         andalso positive_integer(MaxBytes) andalso positive_integer(MaxEvents)
         andalso valid_static_headers(Headers)
         andalso (AuthFun =:= undefined orelse is_function(AuthFun, 0))
         andalso (TlsOpts =:= default orelse is_list(TlsOpts))
         andalso (LastEvent =:= undefined orelse
                  (is_integer(LastEvent) andalso LastEvent >= 0)) of
        true ->
            {ok, Options#{timeout => Timeout, connect_timeout => Connect,
                          max_response_bytes => MaxBytes,
                          max_events => MaxEvents, headers => Headers,
                          auth_fun => AuthFun, tls_opts => TlsOpts,
                          last_event_id => LastEvent}};
        false -> {error, invalid_a2a_client_options}
    end;
normalize_options(_) -> {error, invalid_a2a_client_options}.

dynamic_headers(#{auth_fun := undefined}) -> {ok, []};
dynamic_headers(#{auth_fun := Fun}) ->
    try Fun() of
        Headers when is_list(Headers) ->
            case lists:all(fun valid_header/1, Headers) of
                true -> {ok, Headers};
                false -> {error, invalid_a2a_auth_headers}
            end;
        _ -> {error, invalid_a2a_auth_headers}
    catch _:_ -> {error, a2a_auth_provider_failed}
    end.

valid_static_headers(Headers) when is_list(Headers) ->
    lists:all(fun({Name, _Value} = Header) ->
                      valid_header(Header) andalso
                      not sensitive_header(lower(Name));
                 (_) -> false
              end, Headers);
valid_static_headers(_) -> false.

valid_header({Name, Value}) ->
    is_binary(Name) andalso byte_size(Name) > 0 andalso
    is_binary(Value) andalso no_controls(Name) andalso no_controls(Value);
valid_header(_) -> false.

sensitive_header(<<"authorization">>) -> true;
sensitive_header(<<"proxy-authorization">>) -> true;
sensitive_header(<<"cookie">>) -> true;
sensitive_header(<<"x-api-key">>) -> true;
sensitive_header(_) -> false.

no_controls(Binary) ->
    lists:all(fun(C) -> C >= 16#20 andalso C =/= 16#7f end,
              binary_to_list(Binary)).

positive_integer(Value) -> is_integer(Value) andalso Value > 0.

content_type(Headers) ->
    case header_value(<<"content-type">>, Headers) of
        undefined -> undefined;
        Value -> lower(hd(binary:split(Value, <<";">>)))
    end.

header_value(Name, Headers) ->
    case lists:dropwhile(fun({Key, _}) -> lower(Key) =/= Name end, Headers) of
        [{_, Value} | _] -> Value;
        [] -> undefined
    end.

has_prefix(Binary, Prefix) ->
    byte_size(Binary) >= byte_size(Prefix) andalso
    binary:part(Binary, 0, byte_size(Prefix)) =:= Prefix.

trim_left(<<" ", Rest/binary>>) -> trim_left(Rest);
trim_left(<<"\t", Rest/binary>>) -> trim_left(Rest);
trim_left(Value) -> Value.

normalize_newlines(Binary) ->
    binary:replace(binary:replace(Binary, <<"\r\n">>, <<"\n">>, [global]),
                   <<"\r">>, <<"\n">>, [global]).

lower(Value) when is_binary(Value) ->
    list_to_binary(string:lowercase(binary_to_list(Value))).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(_) -> <<>>.
