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

-ifdef(TEST).
-export([test_resolve_addresses/3]).
-endif.

-define(DEFAULT_TIMEOUT, 65000).
-define(DEFAULT_CONNECT_TIMEOUT, 10000).
-define(DEFAULT_MAX_BYTES, 8388608).
-define(DEFAULT_MAX_EVENTS, 1024).
-define(DEFAULT_MAX_EXTENSIONS, 32).
-define(DEFAULT_MAX_EXTENSION_HEADER_BYTES, 8192).
-define(DEFAULT_AUTH_TIMEOUT, 5000).
-define(DEFAULT_AUTH_MAX_HEAP_WORDS, 100000).
-define(MAX_AUTH_RESULT_BYTES, 300000).
-define(DNS_MAX_HEAP_WORDS, 262144).
-define(WATCHDOG_MAX_HEAP_WORDS, 8192).
-define(MAX_DNS_ADDRESSES, 64).
-define(MAX_DNS_RESULT_BYTES, 16384).
-define(WORKER_DOWN_TIMEOUT_MS, 100).

-spec discover(binary() | string()) -> {ok, map()} | {error, term()}.
discover(Location) -> discover(Location, #{}).

-spec discover(binary() | string(), map()) ->
    {ok, map()} | {error, term()}.
discover(Location, Options0) ->
    case normalize_options(Options0) of
        {ok, Options} ->
            discover_normalized(Location, start_deadline(Options));
        Error -> Error
    end.

discover_normalized(Location, Options) ->
    case discovery_url(Location) of
        {ok, Url} ->
            Headers = [{<<"accept">>, <<"application/json">>}],
            case request(<<"GET">>, Url, Headers, <<>>, Options,
                         discovery) of
                {ok, 200, RespHeaders, Body} ->
                    case content_type(RespHeaders) of
                        <<"application/json">> ->
                            case decode_card(Body) of
                                {ok, Card} ->
                                    validate_discovered_interfaces(
                                      Card, Url, Options);
                                Error -> Error
                            end;
                        _ -> {error, invalid_agent_card_content_type}
                    end;
                {ok, Status, _Headers, _Body} ->
                    {error, {agent_card_http_status, Status}};
                {error, _} = Error -> Error
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
        {ok, Options0a} ->
            Options = start_deadline(Options0a),
            case resolve_card(Target, Options) of
                {ok, Card} ->
                    {ok, Interface} = adk_a2a_v1_card:jsonrpc_interface(Card),
                    Params = maybe_tenant(Params0, Interface),
                    Id = erlang:unique_integer([positive, monotonic]),
                    Request = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                                <<"method">> => Method, <<"params">> => Params},
                    Url = maps:get(<<"url">>, Interface),
                    rpc_http(Mode, Url, Id, Request, Card, Options);
                Error -> Error
            end;
        Error -> Error
    end;
rpc(_Target, _Method, _Params, _Options, _Mode) ->
    {error, invalid_a2a_params}.

rpc_http(Mode, Url, Id, RpcRequest, Card, Options) ->
    Accept = case Mode of
        unary -> <<"application/json">>;
        stream -> <<"text/event-stream">>
    end,
    LastEvent = case {Mode, maps:get(last_event_id, Options)} of
        {stream, N} when is_integer(N), N >= 0 ->
            [{<<"last-event-id">>, integer_to_binary(N)}];
        _ -> []
    end,
    Headers0 = [{<<"accept">>, Accept},
                {<<"content-type">>, <<"application/json">>},
                {<<"a2a-version">>, <<"1.0">>}] ++ LastEvent,
    case extension_headers(Card, Options) of
        {ok, ExtensionHeaders} ->
            case rpc_auth_mode(Card, Options) of
                {ok, AuthMode} ->
                    case request(<<"POST">>, Url,
                                 Headers0 ++ ExtensionHeaders,
                                 jsx:encode(RpcRequest), Options, AuthMode) of
                        {ok, 200, RespHeaders, Body} ->
                            decode_rpc_http(
                              Mode, content_type(RespHeaders), Body,
                              Id, Options);
                        {ok, Status, _Headers, _Body} ->
                            {error, {a2a_http_status, Status}};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
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
            {error, {a2a_error, public_a2a_error(Error)}};
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
          <<"error">> := Error} when is_map(Error) ->
            {error, {a2a_error, public_a2a_error(Error)}};
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

request(Method, Url, Headers0, Body, Options, AuthMode) ->
    case parse_url(Url) of
        {ok, Endpoint} ->
            case resolve_endpoint(Endpoint, Options) of
                {ok, Target} ->
                    case dynamic_headers(AuthMode, Target, Options) of
                        {ok, Dynamic} ->
                            Headers = [{<<"host">>, host_header(Endpoint)} |
                                       Headers0 ++ maps:get(headers, Options) ++
                                       Dynamic],
                            with_connection(
                              Target, Options,
                              fun(Conn) ->
                                  Ref = gun:request(
                                          Conn, Method,
                                          maps:get(path, Endpoint),
                                          Headers, Body),
                                  await_response(Conn, Ref, Options)
                              end);
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

with_connection(Target, Options, Fun) ->
    Port = maps:get(port, Target),
    GunOptions = gun_options(Target, Options),
    case remaining(Options) of
        0 -> {error, a2a_timeout};
        _ -> open_connection(Target, Port, GunOptions, Options, Fun)
    end.

open_connection(Target, Port, GunOptions, Options, Fun) ->
    case gun:open(maps:get(address, Target), Port, GunOptions) of
        {ok, Conn} ->
            try gun:await_up(Conn, connect_remaining(Options)) of
                {ok, _Protocol} -> Fun(Conn);
                {error, timeout} -> {error, a2a_timeout};
                {error, _} -> {error, a2a_connect_failed}
            after
                _ = catch gun:close(Conn)
            end;
        {error, _} -> {error, a2a_connect_failed}
    end.

await_response(Conn, Ref, Options) ->
    case gun:await(Conn, Ref, remaining(Options)) of
        {inform, _Status, _Headers} ->
            await_response(Conn, Ref, Options);
        {response, fin, Status, Headers} ->
            {ok, Status, Headers, <<>>};
        {response, nofin, Status, Headers} ->
            case await_body(Conn, Ref, Options,
                            maps:get(max_response_bytes, Options), [], 0) of
                {ok, Body} -> {ok, Status, Headers, Body};
                Error -> Error
            end;
        {error, timeout} -> {error, a2a_timeout};
        {error, _} -> {error, a2a_transport_failed};
        _ -> {error, invalid_a2a_http_response}
    end.

await_body(Conn, Ref, Options, Max, Acc, Size) ->
    case gun:await(Conn, Ref, remaining(Options)) of
        {data, Fin, Data} when is_binary(Data) ->
            NewSize = Size + byte_size(Data),
            case NewSize =< Max of
                false ->
                    _ = catch gun:cancel(Conn, Ref),
                    {error, a2a_response_too_large};
                true when Fin =:= fin ->
                    {ok, iolist_to_binary(lists:reverse([Data | Acc]))};
                true -> await_body(Conn, Ref, Options, Max,
                                   [Data | Acc], NewSize)
            end;
        {trailers, _} -> {ok, iolist_to_binary(lists:reverse(Acc))};
        {error, timeout} -> {error, a2a_timeout};
        {error, _} -> {error, a2a_transport_failed};
        _ -> {error, invalid_a2a_http_body}
    end.

resolve_endpoint(Endpoint, Options) ->
    Host = maps:get(host, Endpoint),
    case exact_host_allowed(Host, maps:get(allowed_hosts, Options)) of
        false -> {error, a2a_destination_not_allowed};
        true ->
            case resolve_addresses(Host, Options) of
                {ok, Addresses} ->
                    validate_resolved_endpoint(Endpoint, Addresses, Options);
                Error -> Error
            end
    end.

resolve_addresses(Host, Options) ->
    resolve_addresses(Host, Options, fun resolved_addresses/1).

resolve_addresses(Host, Options, Resolver) ->
    Deadline = maps:get(deadline, Options),
    case remaining_deadline(Deadline) of
        0 -> {error, a2a_timeout};
        _ -> start_resolver(Host, Resolver, Deadline)
    end.

start_resolver(Host, Resolver, Deadline) ->
    Owner = self(),
    ReplyAlias = erlang:alias([explicit_unalias]),
    Ref = make_ref(),
    Worker = fun() ->
        case start_owner_watchdog(Owner, self(), Deadline,
                                  ?WATCHDOG_MAX_HEAP_WORDS) of
            ok ->
                Result = resolver_result(Host, Resolver),
                CompletedAt = erlang:monotonic_time(millisecond),
                _ = erlang:send(
                      ReplyAlias,
                      {a2a_dns_result, Ref, self(), CompletedAt, Result},
                      [noconnect, nosuspend]),
                ok;
            error ->
                ok
        end
    end,
    SpawnOptions =
        [monitor, {message_queue_data, off_heap},
         {max_heap_size,
          #{size => ?DNS_MAX_HEAP_WORDS, kill => true,
            error_logger => false, include_shared_binaries => true}}],
    try erlang:spawn_opt(Worker, SpawnOptions) of
        {Pid, Monitor} ->
            await_resolver(Pid, Monitor, ReplyAlias, Ref, Deadline)
    catch
        _:_ ->
            _ = erlang:unalias(ReplyAlias),
            {error, a2a_dns_resolution_failed}
    end.

await_resolver(Pid, Monitor, ReplyAlias, Ref, Deadline) ->
    receive
        {a2a_dns_result, Ref, Pid, CompletedAt, Result}
          when CompletedAt =< Deadline ->
            worker_complete(ReplyAlias, Monitor),
            completed_resolver_result(Result);
        {a2a_dns_result, Ref, Pid, _CompletedAt, _LateResult} ->
            stop_isolated_worker(Pid, Monitor, ReplyAlias),
            {error, a2a_timeout};
        {'DOWN', Monitor, process, Pid, _OpaqueReason} ->
            _ = erlang:unalias(ReplyAlias),
            %% The owner watchdog uses this same absolute deadline. If it
            %% wins the scheduler race and kills the resolver just as the
            %% receive timeout becomes eligible, preserve deadline semantics
            %% rather than misclassifying that kill as a DNS failure.
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> {error, a2a_timeout};
                false -> {error, a2a_dns_resolution_failed}
            end
    after remaining_deadline(Deadline) ->
        stop_isolated_worker(Pid, Monitor, ReplyAlias),
        {error, a2a_timeout}
    end.

completed_resolver_result({ok, []}) ->
    {error, a2a_dns_resolution_failed};
completed_resolver_result({ok, Addresses}) ->
    {ok, Addresses};
completed_resolver_result(error) ->
    {error, a2a_dns_resolution_failed}.

resolver_result(Host, Resolver) ->
    try normalize_resolved_addresses(Resolver(Host)) of
        {ok, _Addresses} = Result ->
            case bounded_term(Result, ?MAX_DNS_RESULT_BYTES) of
                true -> Result;
                false -> error
            end;
        error -> error
    catch
        _:_ -> error
    end.

-ifdef(TEST).
normalize_resolved_addresses(Addresses) when is_list(Addresses) ->
    bounded_addresses(Addresses, ?MAX_DNS_ADDRESSES, []);
normalize_resolved_addresses(_Addresses) ->
    error.

bounded_addresses([], _Remaining, Acc) ->
    {ok, lists:usort(Acc)};
bounded_addresses(_Addresses, 0, _Acc) ->
    error;
bounded_addresses([Address | Rest], Remaining, Acc) ->
    case valid_ip_address(Address) of
        true -> bounded_addresses(Rest, Remaining - 1, [Address | Acc]);
        false -> error
    end;
bounded_addresses(_Improper, _Remaining, _Acc) ->
    error.
-else.
normalize_resolved_addresses(Addresses) ->
    bounded_addresses(Addresses, ?MAX_DNS_ADDRESSES, []).

bounded_addresses([], _Remaining, Acc) ->
    {ok, lists:usort(Acc)};
bounded_addresses(_Addresses, 0, _Acc) ->
    error;
bounded_addresses([Address | Rest], Remaining, Acc) ->
    case valid_ip_address(Address) of
        true -> bounded_addresses(Rest, Remaining - 1, [Address | Acc]);
        false -> error
    end.
-endif.

resolved_addresses(Host) ->
    HostString = binary_to_list(Host),
    resolve_family(HostString, inet) ++
    resolve_family(HostString, inet6).

resolve_family(Host, Family) ->
    case inet:getaddrs(Host, Family) of
        {ok, Addresses} -> Addresses;
        {error, _} -> []
    end.

validate_resolved_endpoint(Endpoint, Addresses, Options) ->
    Host = maps:get(host, Endpoint),
    Scheme = maps:get(scheme, Endpoint),
    AllLoopback = lists:all(fun is_loopback_address/1, Addresses),
    AllPublic = lists:all(fun is_public_address/1, Addresses),
    PrivateAllowed = lists:member(
                       Host, maps:get(allowed_private_hosts, Options)),
    SchemeAllowed = case Scheme of
        <<"https">> -> AllPublic orelse PrivateAllowed;
        <<"http">> -> maps:get(allow_http_loopback, Options)
                      andalso AllLoopback
    end,
    case SchemeAllowed of
        true ->
            {ok, Endpoint#{address => hd(Addresses),
                           all_loopback => AllLoopback}};
        false when Scheme =:= <<"http">> ->
            {error, insecure_a2a_destination};
        false ->
            {error, a2a_private_destination_rejected}
    end.

parse_url(Url0) ->
    Url = to_binary(Url0),
    try uri_string:parse(Url) of
        Parsed when is_map(Parsed) ->
            Scheme = lower(to_binary(maps:get(scheme, Parsed, <<>>))),
            Host = canonical_host(to_binary(maps:get(host, Parsed, <<>>))),
            UserInfo = maps:get(userinfo, Parsed, undefined),
            Fragment = maps:get(fragment, Parsed, undefined),
            case (Scheme =:= <<"http">> orelse Scheme =:= <<"https">>)
                 andalso byte_size(Host) > 0
                 andalso UserInfo =:= undefined
                 andalso Fragment =:= undefined of
                false -> {error, invalid_a2a_url};
                true ->
                    Port = maps:get(port, Parsed,
                                    default_port(Scheme)),
                    Path0 = to_binary(maps:get(path, Parsed, <<"/">>)),
                    Path1 = case Path0 of <<>> -> <<"/">>; _ -> Path0 end,
                    Path = case maps:find(query, Parsed) of
                        {ok, Query} -> <<Path1/binary, "?",
                                         (to_binary(Query))/binary>>;
                        error -> Path1
                    end,
                    case valid_port(Port) of
                        true -> {ok, #{scheme => Scheme, host => Host,
                                      port => Port, path => Path}};
                        false -> {error, invalid_a2a_url}
                    end
            end
    catch _:_ -> {error, invalid_a2a_url}
    end.

gun_options(#{scheme := <<"http">>}, Options) ->
    #{transport => tcp, protocols => [http], retry => 0,
      connect_timeout => connect_remaining(Options)};
gun_options(#{scheme := <<"https">>, host := Host}, Options) ->
    Tls = secure_tls_opts(Host, maps:get(tls_opts, Options)),
    #{transport => tls, protocols => [http], retry => 0,
      connect_timeout => connect_remaining(Options),
      tls_handshake_timeout => connect_remaining(Options),
      tls_opts => Tls}.

valid_tls_opts(default) -> true;
valid_tls_opts(Options) when is_list(Options) ->
    lists:all(fun(Option) -> is_tuple(Option) andalso tuple_size(Option) =:= 2
              end, Options) andalso
    not lists:member({verify, verify_none}, Options);
valid_tls_opts(_) -> false.

secure_tls_opts(Host, Configured) ->
    Extra0 = case Configured of default -> []; Value -> Value end,
    Extra = lists:filter(
              fun({Key, _Value}) ->
                      not lists:member(
                            Key,
                            [verify, verify_fun, partial_chain,
                             server_name_indication,
                             customize_hostname_check]);
                 (_) -> false
              end, Extra0),
    Trust = case lists:keymember(cacerts, 1, Extra) orelse
                 lists:keymember(cacertfile, 1, Extra) of
        true -> [];
        false -> [{cacerts, public_key:cacerts_get()}]
    end,
    [{verify, verify_peer},
     {server_name_indication, binary_to_list(Host)},
     {customize_hostname_check,
      [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]
    ++ Trust ++ Extra.

%% card/options/helpers

resolve_card(Card, _Options) when is_map(Card) ->
    adk_a2a_v1_card:validate(Card);
resolve_card(Location, Options) -> discover_normalized(Location, Options).

decode_card(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Card -> adk_a2a_v1_card:validate(Card)
    catch _:_ -> {error, invalid_agent_card_json}
    end.

validate_discovered_interfaces(Card, DiscoveryUrl, Options) ->
    case parse_url(DiscoveryUrl) of
        {ok, DiscoveryEndpoint} ->
            DiscoveryOrigin = origin(DiscoveryEndpoint),
            Interfaces = maps:get(<<"supportedInterfaces">>, Card),
            Allowed = maps:get(allowed_interface_origins, Options),
            case lists:all(
                   fun(Interface) ->
                       case parse_url(maps:get(<<"url">>, Interface)) of
                           {ok, Endpoint} ->
                               InterfaceOrigin = origin(Endpoint),
                               InterfaceOrigin =:= DiscoveryOrigin orelse
                               lists:member(InterfaceOrigin, Allowed);
                           {error, _} -> false
                       end
                   end, Interfaces) of
                true -> {ok, Card};
                false -> {error, cross_origin_agent_interface_rejected}
            end;
        {error, _} -> {error, invalid_a2a_url}
    end.

extension_headers(Card, Options) ->
    Required = adk_a2a_v1_card:required_extensions(Card),
    MaxCount = maps:get(max_extensions, Options),
    case length(Required) =< MaxCount of
        false -> {error, too_many_required_a2a_extensions};
        true ->
            Value = iolist_to_binary(lists:join(<<",">>, Required)),
            case byte_size(Value) =<
                 maps:get(max_extension_header_bytes, Options) of
                false -> {error, a2a_extension_header_too_large};
                true when Value =:= <<>> -> {ok, []};
                true -> {ok, [{<<"a2a-extensions">>, Value}]}
            end
    end.

rpc_auth_mode(Card, Options) ->
    case maps:get(<<"securityRequirements">>, Card, undefined) of
        Requirements when is_list(Requirements), Requirements =/= [] ->
            declared_rpc_auth_mode(Requirements, Options);
        _ ->
            case maps:get(allow_undeclared_auth, Options) of
                true -> {ok, rpc_local_compatibility};
                false -> {ok, none}
            end
    end.

declared_rpc_auth_mode(_Requirements, #{auth_fun := undefined}) ->
    {error, a2a_auth_required};
declared_rpc_auth_mode(_Requirements, #{auth_scheme := undefined}) ->
    {error, a2a_auth_scheme_required};
declared_rpc_auth_mode(Requirements, #{auth_scheme := Scheme}) ->
    Declared = lists:any(
                 fun(#{<<"schemes">> := Schemes}) ->
                         maps:is_key(Scheme, Schemes)
                 end, Requirements),
    SingleSchemeAlternative = lists:any(
                                fun(#{<<"schemes">> := Schemes}) ->
                                    map_size(Schemes) =:= 1 andalso
                                    maps:is_key(Scheme, Schemes)
                                end, Requirements),
    case {SingleSchemeAlternative, Declared} of
        {true, _} -> {ok, rpc};
        {false, true} -> {error, a2a_compound_auth_not_supported};
        {false, false} -> {error, a2a_auth_scheme_not_declared}
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
                    AuthorityHost = authority_host(Host),
                    Authority = case Default of
                        true -> AuthorityHost;
                        false -> <<AuthorityHost/binary, ":",
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
    AuthScheme = maps:get(auth_scheme, Options, undefined),
    DiscoveryAuthFun = maps:get(discovery_auth_fun, Options, undefined),
    TlsOpts = maps:get(tls_opts, Options, default),
    LastEvent = maps:get(last_event_id, Options, undefined),
    AllowHttpLoopback = maps:get(allow_http_loopback, Options, false),
    AllowUndeclaredAuth = maps:get(allow_undeclared_auth, Options, false),
    AllowedHosts0 = maps:get(allowed_hosts, Options, any),
    AllowedPrivate0 = maps:get(allowed_private_hosts, Options, []),
    AllowedOrigins0 = maps:get(allowed_interface_origins, Options, []),
    MaxExtensions = maps:get(max_extensions, Options,
                             ?DEFAULT_MAX_EXTENSIONS),
    MaxExtensionBytes = maps:get(max_extension_header_bytes, Options,
                                  ?DEFAULT_MAX_EXTENSION_HEADER_BYTES),
    AuthTimeout = maps:get(auth_timeout, Options, ?DEFAULT_AUTH_TIMEOUT),
    AuthMaxHeap = maps:get(auth_max_heap_words, Options,
                           ?DEFAULT_AUTH_MAX_HEAP_WORDS),
    case positive_integer(Timeout) andalso positive_integer(Connect)
         andalso positive_integer(MaxBytes) andalso positive_integer(MaxEvents)
         andalso positive_integer(MaxExtensions)
         andalso MaxExtensions =< ?DEFAULT_MAX_EXTENSIONS
         andalso positive_integer(MaxExtensionBytes)
         andalso MaxExtensionBytes =< ?DEFAULT_MAX_EXTENSION_HEADER_BYTES
         andalso positive_integer(AuthTimeout)
         andalso AuthTimeout =< 30000
         andalso is_integer(AuthMaxHeap)
         andalso AuthMaxHeap >= 1000
         andalso AuthMaxHeap =< 1000000
         andalso valid_static_headers(Headers)
         andalso (AuthFun =:= undefined orelse is_function(AuthFun, 0))
         andalso valid_optional_auth_scheme(AuthScheme)
         andalso (DiscoveryAuthFun =:= undefined orelse
                  is_function(DiscoveryAuthFun, 0))
         andalso valid_tls_opts(TlsOpts)
         andalso is_boolean(AllowHttpLoopback)
         andalso is_boolean(AllowUndeclaredAuth)
         andalso (not AllowUndeclaredAuth orelse AllowHttpLoopback)
         andalso valid_host_policy(AllowedHosts0)
         andalso valid_host_list(AllowedPrivate0)
         andalso valid_origin_list(AllowedOrigins0)
         andalso (LastEvent =:= undefined orelse
                  (is_integer(LastEvent) andalso LastEvent >= 0)) of
        true ->
            {ok, Options#{timeout => Timeout, connect_timeout => Connect,
                          max_response_bytes => MaxBytes,
                          max_events => MaxEvents, headers => Headers,
                          max_extensions => MaxExtensions,
                          max_extension_header_bytes => MaxExtensionBytes,
                          auth_timeout => AuthTimeout,
                          auth_max_heap_words => AuthMaxHeap,
                          auth_fun => AuthFun,
                          auth_scheme => AuthScheme,
                          discovery_auth_fun => DiscoveryAuthFun,
                          tls_opts => TlsOpts,
                          last_event_id => LastEvent,
                          allow_http_loopback => AllowHttpLoopback,
                          allow_undeclared_auth => AllowUndeclaredAuth,
                          allowed_hosts => normalize_host_policy(AllowedHosts0),
                          allowed_private_hosts =>
                              normalize_hosts(AllowedPrivate0),
                          allowed_interface_origins =>
                              normalize_origins(AllowedOrigins0)}};
        false -> {error, invalid_a2a_client_options}
    end;
normalize_options(_) -> {error, invalid_a2a_client_options}.

dynamic_headers(none, _Target, _Options) -> {ok, []};
dynamic_headers(discovery, _Target, #{discovery_auth_fun := undefined}) ->
    {ok, []};
dynamic_headers(discovery, _Target,
                #{discovery_auth_fun := Fun} = Options) ->
    invoke_auth_fun(Fun, Options);
dynamic_headers(rpc, _Target, #{auth_fun := undefined}) -> {ok, []};
dynamic_headers(rpc, _Target, #{auth_fun := Fun} = Options) ->
    invoke_auth_fun(Fun, Options);
dynamic_headers(rpc_local_compatibility,
                #{all_loopback := false}, _Options) ->
    {error, undeclared_a2a_auth_not_allowed};
dynamic_headers(rpc_local_compatibility,
                #{all_loopback := true}, #{auth_fun := undefined}) ->
    {ok, []};
dynamic_headers(rpc_local_compatibility,
                #{all_loopback := true}, #{auth_fun := Fun} = Options) ->
    invoke_auth_fun(Fun, Options).

invoke_auth_fun(Fun, Options) ->
    OperationDeadline = maps:get(deadline, Options),
    case remaining_deadline(OperationDeadline) of
        0 -> {error, a2a_timeout};
        _ ->
            Now = erlang:monotonic_time(millisecond),
            CallbackDeadline = erlang:min(
                                 OperationDeadline,
                                 Now + maps:get(auth_timeout, Options)),
            start_auth_worker(Fun, Options, CallbackDeadline,
                              OperationDeadline)
    end.

start_auth_worker(Fun, Options, CallbackDeadline, OperationDeadline) ->
    Owner = self(),
    ReplyAlias = erlang:alias([explicit_unalias]),
    Ref = make_ref(),
    MaxHeap = maps:get(auth_max_heap_words, Options),
    Worker = fun() ->
        case start_owner_watchdog(Owner, self(), CallbackDeadline,
                                  ?WATCHDOG_MAX_HEAP_WORDS) of
            ok ->
                Result = auth_fun_result(Fun),
                CompletedAt = erlang:monotonic_time(millisecond),
                _ = erlang:send(
                      ReplyAlias,
                      {a2a_auth_result, Ref, self(), CompletedAt, Result},
                      [noconnect, nosuspend]),
                ok;
            error ->
                ok
        end
    end,
    SpawnOptions =
        [monitor, {message_queue_data, off_heap},
         {max_heap_size,
          #{size => MaxHeap, kill => true, error_logger => false,
            include_shared_binaries => true}}],
    try erlang:spawn_opt(Worker, SpawnOptions) of
        {Pid, Monitor} ->
            await_auth_worker(Pid, Monitor, ReplyAlias, Ref,
                              CallbackDeadline, OperationDeadline)
    catch
        _:_ ->
            _ = erlang:unalias(ReplyAlias),
            {error, a2a_auth_provider_failed}
    end.

await_auth_worker(Pid, Monitor, ReplyAlias, Ref, CallbackDeadline,
                  OperationDeadline) ->
    receive
        {a2a_auth_result, Ref, Pid, CompletedAt, Result}
          when CompletedAt =< CallbackDeadline ->
            worker_complete(ReplyAlias, Monitor),
            Result;
        {a2a_auth_result, Ref, Pid, _CompletedAt, _LateResult} ->
            stop_isolated_worker(Pid, Monitor, ReplyAlias),
            auth_timeout_error(CallbackDeadline, OperationDeadline);
        {'DOWN', Monitor, process, Pid, _OpaqueReason} ->
            _ = erlang:unalias(ReplyAlias),
            case erlang:monotonic_time(millisecond) >= CallbackDeadline of
                true -> auth_timeout_error(CallbackDeadline,
                                           OperationDeadline);
                false -> {error, a2a_auth_provider_failed}
            end
    after remaining_deadline(CallbackDeadline) ->
        stop_isolated_worker(Pid, Monitor, ReplyAlias),
        auth_timeout_error(CallbackDeadline, OperationDeadline)
    end.

auth_timeout_error(CallbackDeadline, OperationDeadline)
  when CallbackDeadline >= OperationDeadline ->
    {error, a2a_timeout};
auth_timeout_error(_CallbackDeadline, _OperationDeadline) ->
    {error, a2a_auth_provider_timeout}.

auth_fun_result(Fun) ->
    try Fun() of
        Headers when is_list(Headers) ->
            case length_at_most(Headers, 32) andalso
                 lists:all(fun valid_dynamic_header/1, Headers) of
                true ->
                    Result = {ok, Headers},
                    case bounded_term(Result, ?MAX_AUTH_RESULT_BYTES) of
                        true -> Result;
                        false -> {error, invalid_a2a_auth_headers}
                    end;
                false -> {error, invalid_a2a_auth_headers}
            end;
        _ -> {error, invalid_a2a_auth_headers}
    catch _:_ -> {error, a2a_auth_provider_failed}
    end.

worker_complete(ReplyAlias, Monitor) ->
    _ = erlang:unalias(ReplyAlias),
    _ = erlang:demonitor(Monitor, [flush]),
    ok.

stop_isolated_worker(Pid, Monitor, ReplyAlias) ->
    _ = erlang:unalias(ReplyAlias),
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, _OpaqueReason} -> ok
    after ?WORKER_DOWN_TIMEOUT_MS ->
        _ = erlang:demonitor(Monitor, [flush])
    end.

start_owner_watchdog(Owner, Worker, Deadline, MaxHeap) ->
    Watchdog = fun() -> owner_watchdog(Owner, Worker, Deadline) end,
    SpawnOptions =
        [{message_queue_data, off_heap},
         {max_heap_size,
          #{size => MaxHeap, kill => true, error_logger => false,
            include_shared_binaries => true}}],
    try erlang:spawn_opt(Watchdog, SpawnOptions) of
        Pid when is_pid(Pid) -> ok
    catch
        _:_ -> error
    end.

owner_watchdog(Owner, Worker, Deadline) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    WorkerMonitor = erlang:monitor(process, Worker),
    receive
        {'DOWN', OwnerMonitor, process, Owner, _OpaqueReason} ->
            exit(Worker, kill),
            _ = erlang:demonitor(WorkerMonitor, [flush]),
            ok;
        {'DOWN', WorkerMonitor, process, Worker, _OpaqueReason} ->
            _ = erlang:demonitor(OwnerMonitor, [flush]),
            ok
    after remaining_deadline(Deadline) ->
        exit(Worker, kill),
        _ = erlang:demonitor(OwnerMonitor, [flush]),
        _ = erlang:demonitor(WorkerMonitor, [flush]),
        ok
    end.

bounded_term(Term, Maximum) ->
    try erlang:external_size(Term) =< Maximum
    catch
        _:_ -> false
    end.

length_at_most(_List, Remaining) when Remaining < 0 -> false;
length_at_most([], _Remaining) -> true;
length_at_most([_ | Rest], Remaining) ->
    length_at_most(Rest, Remaining - 1);
length_at_most(_Improper, _Remaining) -> false.

start_deadline(Options) ->
    Options#{deadline => erlang:monotonic_time(millisecond) +
                         maps:get(timeout, Options)}.

remaining(Options) ->
    erlang:max(0, maps:get(deadline, Options) -
                  erlang:monotonic_time(millisecond)).

remaining_deadline(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

connect_remaining(Options) ->
    erlang:min(maps:get(connect_timeout, Options), remaining(Options)).

valid_host_policy(any) -> true;
valid_host_policy(Hosts) -> valid_host_list(Hosts).

valid_host_list(Hosts) when is_list(Hosts) ->
    lists:all(
      fun(Host0) ->
          Host = canonical_host(to_binary(Host0)),
          byte_size(Host) > 0 andalso no_controls(Host)
      end, Hosts);
valid_host_list(_) -> false.

normalize_host_policy(any) -> any;
normalize_host_policy(Hosts) -> normalize_hosts(Hosts).

normalize_hosts(Hosts) ->
    lists:usort([canonical_host(to_binary(Host)) || Host <- Hosts]).

exact_host_allowed(_Host, any) -> true;
exact_host_allowed(Host, Hosts) -> lists:member(Host, Hosts).

valid_origin_list(Origins) when is_list(Origins) ->
    lists:all(
      fun(Origin0) ->
          case parse_origin(Origin0) of
              {ok, _} -> true;
              {error, _} -> false
          end
      end, Origins);
valid_origin_list(_) -> false.

normalize_origins(Origins) ->
    lists:usort([Parsed || Origin0 <- Origins,
                          {ok, Parsed} <- [parse_origin(Origin0)]]).

parse_origin(Origin0) ->
    try uri_string:parse(to_binary(Origin0)) of
        Parsed when is_map(Parsed) ->
            Scheme = lower(to_binary(maps:get(scheme, Parsed, <<>>))),
            Host = canonical_host(to_binary(maps:get(host, Parsed, <<>>))),
            Port = maps:get(port, Parsed, default_port(Scheme)),
            Path = to_binary(maps:get(path, Parsed, <<>>)),
            case lists:member(Scheme, [<<"http">>, <<"https">>])
                 andalso byte_size(Host) > 0 andalso valid_port(Port)
                 andalso (Path =:= <<>> orelse Path =:= <<"/">>)
                 andalso maps:get(query, Parsed, undefined) =:= undefined
                 andalso maps:get(fragment, Parsed, undefined) =:= undefined
                 andalso maps:get(userinfo, Parsed, undefined) =:= undefined of
                true -> {ok, {Scheme, Host, Port}};
                false -> {error, invalid_origin}
            end;
        _ -> {error, invalid_origin}
    catch _:_ -> {error, invalid_origin}
    end.

origin(#{scheme := Scheme, host := Host, port := Port}) ->
    {Scheme, Host, Port}.

host_header(#{scheme := <<"https">>, host := Host, port := 443}) ->
    authority_host(Host);
host_header(#{scheme := <<"http">>, host := Host, port := 80}) ->
    authority_host(Host);
host_header(#{host := Host, port := Port}) ->
    AuthorityHost = authority_host(Host),
    <<AuthorityHost/binary, ":", (integer_to_binary(Port))/binary>>.

authority_host(Host) ->
    case binary:match(Host, <<":">>) of
        nomatch -> Host;
        _ -> <<"[", Host/binary, "]">>
    end.

default_port(<<"https">>) -> 443;
default_port(<<"http">>) -> 80;
default_port(_) -> 0.

valid_port(Port) -> is_integer(Port) andalso Port > 0 andalso Port =< 65535.

canonical_host(Host0) ->
    Host1 = lower(Host0),
    case Host1 of
        <<>> -> <<>>;
        _ ->
            case binary:last(Host1) of
                $. -> binary:part(Host1, 0, byte_size(Host1) - 1);
                _ -> Host1
            end
    end.

public_a2a_error(Error) ->
    Code = maps:get(<<"code">>, Error, -32603),
    #{<<"code">> => case is_integer(Code) of true -> Code; false -> -32603 end,
      <<"message">> => <<"A2A request failed">>}.

valid_static_headers(Headers) when is_list(Headers) ->
    length(Headers) =< 32 andalso
    lists:all(fun({Name, _Value} = Header) ->
                      valid_header(Header) andalso
                      not sensitive_header(lower(Name));
                 (_) -> false
              end, Headers);
valid_static_headers(_) -> false.

valid_header({Name, Value}) ->
    is_binary(Name) andalso byte_size(Name) > 0
    andalso byte_size(Name) =< 128 andalso
    is_binary(Value) andalso byte_size(Value) =< 8192
    andalso no_controls(Name) andalso no_controls(Value).

valid_dynamic_header({Name, _Value} = Header) ->
    valid_header(Header) andalso
    not connection_control_header(lower(Name));
valid_dynamic_header(_) -> false.

connection_control_header(<<"host">>) -> true;
connection_control_header(<<"content-length">>) -> true;
connection_control_header(<<"transfer-encoding">>) -> true;
connection_control_header(<<"connection">>) -> true;
connection_control_header(<<"a2a-extensions">>) -> true;
connection_control_header(<<"a2a-version">>) -> true;
connection_control_header(<<"last-event-id">>) -> true;
connection_control_header(<<"content-type">>) -> true;
connection_control_header(_) -> false.

sensitive_header(<<"authorization">>) -> true;
sensitive_header(<<"proxy-authorization">>) -> true;
sensitive_header(<<"cookie">>) -> true;
sensitive_header(<<"x-api-key">>) -> true;
sensitive_header(<<"host">>) -> true;
sensitive_header(<<"content-length">>) -> true;
sensitive_header(<<"transfer-encoding">>) -> true;
sensitive_header(<<"connection">>) -> true;
sensitive_header(<<"a2a-extensions">>) -> true;
sensitive_header(<<"a2a-version">>) -> true;
sensitive_header(<<"last-event-id">>) -> true;
sensitive_header(<<"content-type">>) -> true;
sensitive_header(_) -> false.

no_controls(Binary) ->
    lists:all(fun(C) -> C >= 16#20 andalso C =/= 16#7f end,
              binary_to_list(Binary)).

positive_integer(Value) -> is_integer(Value) andalso Value > 0.

valid_optional_auth_scheme(undefined) -> true;
valid_optional_auth_scheme(Scheme) ->
    is_binary(Scheme) andalso byte_size(Scheme) > 0
    andalso byte_size(Scheme) =< 128 andalso no_controls(Scheme).

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

valid_ip_address(Address) when is_tuple(Address), tuple_size(Address) =:= 4 ->
    lists:all(fun valid_ipv4_octet/1, tuple_to_list(Address));
valid_ip_address(Address) when is_tuple(Address), tuple_size(Address) =:= 8 ->
    lists:all(fun valid_ipv6_segment/1, tuple_to_list(Address));
valid_ip_address(_) -> false.

valid_ipv4_octet(Value) ->
    is_integer(Value) andalso Value >= 0 andalso Value =< 16#ff.

valid_ipv6_segment(Value) ->
    is_integer(Value) andalso Value >= 0 andalso Value =< 16#ffff.

is_loopback_address({127, _B, _C, _D}) -> true;
is_loopback_address({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_loopback_address({0, 0, 0, 0, 0, 16#ffff, C, D}) ->
    is_loopback_address({C bsr 8, C band 16#ff,
                         D bsr 8, D band 16#ff});
is_loopback_address(_) -> false.

%% Reject every non-global class relevant to server-side request forgery:
%% loopback, private, link-local, carrier-grade NAT, documentation,
%% benchmarking, protocol-assignment, multicast, and reserved ranges.
is_public_address({A, _B, _C, _D}) when A =:= 0; A =:= 10; A =:= 127 -> false;
is_public_address({100, B, _C, _D}) when B >= 64, B =< 127 -> false;
is_public_address({169, 254, _C, _D}) -> false;
is_public_address({172, B, _C, _D}) when B >= 16, B =< 31 -> false;
is_public_address({192, 0, 0, _D}) -> false;
is_public_address({192, 0, 2, _D}) -> false;
is_public_address({192, 31, 196, _D}) -> false;
is_public_address({192, 52, 193, _D}) -> false;
is_public_address({192, 88, 99, _D}) -> false;
is_public_address({192, 168, _C, _D}) -> false;
is_public_address({198, B, _C, _D}) when B =:= 18; B =:= 19 -> false;
is_public_address({198, 51, 100, _D}) -> false;
is_public_address({203, 0, 113, _D}) -> false;
is_public_address({A, _B, _C, _D}) when A >= 224 -> false;
is_public_address({_A, _B, _C, _D}) -> true;
is_public_address({0, 0, 0, 0, 0, 16#ffff, C, D}) ->
    is_public_address({C bsr 8, C band 16#ff,
                       D bsr 8, D band 16#ff});
is_public_address({0, _B, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#0100, 0, 0, 0, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, 0, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, 2, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, 16#0db8, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, A, _C, _D, _E, _F, _G, _H})
  when A >= 16#0010, A =< 16#002f -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#fe00) =:= 16#fc00 -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#ffc0) =:= 16#fe80 -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#ffc0) =:= 16#fec0 -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#ff00) =:= 16#ff00 -> false;
is_public_address({_A, _B, _C, _D, _E, _F, _G, _H}) -> true;
is_public_address(_) -> false.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(_) -> <<>>.

-ifdef(TEST).
test_resolve_addresses(Host, Timeout, Resolver)
  when is_binary(Host), is_integer(Timeout), Timeout > 0,
       is_function(Resolver, 1) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    resolve_addresses(Host, #{deadline => Deadline}, Resolver).
-endif.
