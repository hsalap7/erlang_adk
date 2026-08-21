%% @doc MCP 2026-07-28 stateless protocol foundations.
%%
%% The module is transport-independent except for validation and construction
%% of the required Streamable HTTP metadata headers.  It does not retain a
%% protocol session and it does not implement the removed GET/SSE or replay
%% mechanisms.
-module(adk_mcp_protocol_modern).

-export([version/0, request/4, validate_http_request/2,
         result_response/3, discover_result/3, cacheable_result/2,
         list_result/3, input_required/3, input_response_params/4,
         subscription_listen/3, subscription_acknowledged/3,
         subscription_event/3, subscription_complete/2,
         client_capabilities/1, server_capabilities/1,
         encode_header_value/1, decode_header_value/1]).

-define(VERSION, <<"2026-07-28">>).
-define(PROTOCOL_META,
        <<"io.modelcontextprotocol/protocolVersion">>).
-define(CLIENT_INFO_META,
        <<"io.modelcontextprotocol/clientInfo">>).
-define(CLIENT_CAPABILITIES_META,
        <<"io.modelcontextprotocol/clientCapabilities">>).
-define(SERVER_INFO_META,
        <<"io.modelcontextprotocol/serverInfo">>).
-define(SUBSCRIPTION_ID_META,
        <<"io.modelcontextprotocol/subscriptionId">>).
-define(LOG_LEVEL_META,
        <<"io.modelcontextprotocol/logLevel">>).
-define(MAX_ID_INTEGER, 9007199254740991).
-define(MAX_METHOD_BYTES, 256).
-define(MAX_NAME_BYTES, 2048).
-define(MAX_HEADER_VALUE_BYTES, 8192).
-define(MAX_REQUEST_STATE_BYTES, 8192).
-define(MAX_INPUT_REQUESTS, 32).
-define(MAX_SUBSCRIPTION_RESOURCES, 256).

-spec version() -> binary().
version() -> ?VERSION.

%% @doc Construct one self-describing modern JSON-RPC request and its mirrored
%% HTTP headers. ClientContext accepts client_info, client_capabilities, and an
%% optional map of non-reserved metadata.
-spec request(binary() | integer(), binary(), map(), map()) ->
    {ok, #{message := map(), headers := map()}} | {error, term()}.
request(Id, Method, Params0, ClientContext) when is_map(Params0),
                                                  is_map(ClientContext) ->
    case request_meta(ClientContext) of
        {ok, Meta} ->
            case maps:is_key(<<"_meta">>, Params0) of
                true -> {error, reserved_mcp_request_metadata};
                false ->
                    Params = Params0#{<<"_meta">> => Meta},
                    Message = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                                <<"method">> => Method,
                                <<"params">> => Params},
                    case request_headers(Method, Params) of
                        {ok, Headers} ->
                            case validate_http_request(Headers, Message) of
                                {ok, _Context} ->
                                    {ok, #{message => Message,
                                           headers => Headers}};
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end
            end;
        {error, _} = Error -> Error
    end;
request(_Id, _Method, _Params, _ClientContext) ->
    {error, invalid_mcp_modern_request}.

%% @doc Validate required modern Streamable HTTP headers against the body.
%% Header names are case-insensitive; header values are case-sensitive.
-spec validate_http_request(map() | [{binary(), binary()}], term()) ->
    {ok, map()} | {error, term()}.
validate_http_request(Headers0, Message0) ->
    case {normalize_headers(Headers0),
          adk_mcp_protocol_limits:validate_json(Message0)} of
        {{ok, Headers},
         {ok, #{<<"jsonrpc">> := <<"2.0">>, <<"id">> := Id,
                <<"method">> := Method, <<"params">> := Params} = Message}}
          when is_map(Params) ->
            case valid_request_shape(Message, Id, Method) of
                true -> validate_modern_envelope(Headers, Id, Method, Params);
                false -> {error, invalid_mcp_modern_request}
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error;
        _ -> {error, invalid_mcp_modern_request}
    end.

-spec result_response(binary() | integer(), map(), map()) ->
    {ok, map()} | {error, term()}.
result_response(Id, Result0, ServerInfo) when is_map(Result0) ->
    case {valid_id(Id), implementation(ServerInfo),
          add_result_type(Result0)} of
        {true, {ok, SafeServerInfo}, {ok, Result1}} ->
            case result_meta(Result1, SafeServerInfo) of
                {ok, Result} ->
                    adk_mcp_protocol_limits:validate_json(
                      #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                        <<"result">> => Result});
                {error, _} = Error -> Error
            end;
        {false, _, _} -> {error, invalid_mcp_request_id};
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end;
result_response(_Id, _Result, _ServerInfo) ->
    {error, invalid_mcp_result}.

-spec discover_result(map(), map(), map()) ->
    {ok, map()} | {error, term()}.
discover_result(ServerInfo, Capabilities, Options) when is_map(Options) ->
    Allowed = [supported_versions, ttl_ms, cache_scope, instructions],
    case maps:keys(maps:without(Allowed, Options)) of
        [] ->
            Versions = maps:get(supported_versions, Options, [?VERSION]),
            case {Versions =:= [?VERSION], server_capabilities(Capabilities),
                  implementation(ServerInfo),
                  cache_options(maps:with([ttl_ms, cache_scope], Options)),
                  optional_text(maps:get(instructions, Options, undefined),
                                16384)} of
                {true, {ok, SafeCapabilities}, {ok, SafeServerInfo},
                 {ok, Ttl, Scope}, {ok, Instructions}} ->
                    Base0 = #{<<"supportedVersions">> => Versions,
                              <<"capabilities">> => SafeCapabilities,
                              <<"resultType">> => <<"complete">>,
                              <<"ttlMs">> => Ttl,
                              <<"cacheScope">> => Scope},
                    Base = maybe_put(<<"instructions">>, Instructions, Base0),
                    result_meta(Base, SafeServerInfo);
                {false, _, _, _, _} ->
                    {error, invalid_mcp_discovery_versions};
                {_, {error, _} = Error, _, _, _} -> Error;
                {_, _, {error, _} = Error, _, _} -> Error;
                {_, _, _, {error, _} = Error, _} -> Error;
                {_, _, _, _, {error, _} = Error} -> Error
            end;
        _Unknown -> {error, invalid_mcp_discovery_options}
    end;
discover_result(_ServerInfo, _Capabilities, _Options) ->
    {error, invalid_mcp_discovery_options}.

-spec cacheable_result(map(), map()) -> {ok, map()} | {error, term()}.
cacheable_result(Result0, Options) when is_map(Result0), is_map(Options) ->
    case maps:is_key(<<"ttlMs">>, Result0) orelse
         maps:is_key(<<"cacheScope">>, Result0) of
        true -> {error, reserved_mcp_cache_fields};
        false ->
            case {cache_options(Options), add_result_type(Result0)} of
                {{ok, Ttl, Scope}, {ok, Result}} ->
                    adk_mcp_protocol_limits:validate_json(
                      Result#{<<"ttlMs">> => Ttl,
                              <<"cacheScope">> => Scope});
                {{error, _} = Error, _} -> Error;
                {_, {error, _} = Error} -> Error
            end
    end;
cacheable_result(_Result, _Options) ->
    {error, invalid_mcp_cacheable_result}.

-spec list_result(tools | resources | prompts, [map()], map()) ->
    {ok, map()} | {error, term()}.
list_result(Kind, Items0, Options) when is_list(Items0), is_map(Options) ->
    Allowed = [ttl_ms, cache_scope, next_cursor],
    case maps:keys(maps:without(Allowed, Options)) of
        [] ->
            case sort_list_items(Kind, Items0) of
                {ok, Items} ->
                    case optional_text(maps:get(next_cursor, Options,
                                                undefined), 4096) of
                        {ok, Cursor} ->
                            Field = list_field(Kind),
                            Base0 = #{Field => Items},
                            Base = maybe_put(<<"nextCursor">>, Cursor, Base0),
                            cacheable_result(
                              Base, maps:with([ttl_ms, cache_scope], Options));
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        _Unknown -> {error, invalid_mcp_list_options}
    end;
list_result(_Kind, _Items, _Options) ->
    {error, invalid_mcp_list_result}.

%% @doc Construct a bounded MRTR input_required result.  Modern foundations
%% intentionally permit elicitation only; deprecated roots and sampling remain
%% available solely through the legacy capability codec.
-spec input_required(map(), undefined | binary(), map()) ->
    {ok, map()} | {error, term()}.
input_required(InputRequests0, RequestState, ClientCapabilities)
  when is_map(InputRequests0) ->
    case {client_capabilities(ClientCapabilities),
          validate_input_requests(InputRequests0),
          validate_request_state(RequestState)} of
        {{ok, SafeCapabilities}, {ok, InputRequests}, {ok, SafeState}} ->
            case input_request_capabilities(InputRequests,
                                            SafeCapabilities) of
                ok when map_size(InputRequests) > 0;
                        SafeState =/= undefined ->
                    Base0 = #{<<"resultType">> => <<"input_required">>},
                    Base1 = maybe_put_map(<<"inputRequests">>,
                                         InputRequests, Base0),
                    Result = maybe_put(<<"requestState">>, SafeState, Base1),
                    adk_mcp_protocol_limits:validate_json(
                      Result, mrtr_limits());
                ok -> {error, empty_mcp_input_required};
                {error, _} = Error -> Error
            end;
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end;
input_required(_InputRequests, _RequestState, _ClientCapabilities) ->
    {error, invalid_mcp_input_required}.

%% @doc Attach responses to an original request for a stateless MRTR retry.
%% The response keys must exactly match the server-issued input request keys.
-spec input_response_params(map(), map(), map(), undefined | binary()) ->
    {ok, map()} | {error, term()}.
input_response_params(Params0, InputRequests0, InputResponses0, RequestState)
  when is_map(Params0), is_map(InputRequests0), is_map(InputResponses0) ->
    Reserved = [<<"_meta">>, <<"inputResponses">>, <<"requestState">>],
    case lists:any(fun(Key) -> maps:is_key(Key, Params0) end, Reserved) of
        true -> {error, reserved_mcp_retry_fields};
        false ->
            case {adk_mcp_protocol_limits:validate_json(
                    Params0, mrtr_limits()),
                  validate_input_requests(InputRequests0),
                  validate_input_responses(InputResponses0),
                  validate_request_state(RequestState)} of
                {{ok, SafeParams}, {ok, InputRequests},
                 {ok, InputResponses}, {ok, SafeState}} ->
                    case lists:sort(maps:keys(InputRequests)) =:=
                         lists:sort(maps:keys(InputResponses)) andalso
                         (map_size(InputResponses) > 0 orelse
                          SafeState =/= undefined) of
                        true ->
                            Params1 = maybe_put_map(
                                        <<"inputResponses">>,
                                        InputResponses, SafeParams),
                            Params = maybe_put(<<"requestState">>, SafeState,
                                               Params1),
                            adk_mcp_protocol_limits:validate_json(
                              Params, mrtr_limits());
                        false -> {error, mcp_input_response_mismatch}
                    end;
                {{error, _} = Error, _, _, _} -> Error;
                {_, {error, _} = Error, _, _} -> Error;
                {_, _, {error, _} = Error, _} -> Error;
                {_, _, _, {error, _} = Error} -> Error
            end
    end;
input_response_params(_Params, _InputRequests, _InputResponses,
                      _RequestState) ->
    {error, invalid_mcp_input_responses}.

-spec subscription_listen(binary() | integer(), map(), map()) ->
    {ok, #{message := map(), headers := map()}} | {error, term()}.
subscription_listen(Id, Filter0, ClientContext) ->
    case subscription_filter(Filter0) of
        {ok, Filter} ->
            request(Id, <<"subscriptions/listen">>,
                    #{<<"notifications">> => Filter}, ClientContext);
        {error, _} = Error -> Error
    end.

-spec subscription_acknowledged(binary() | integer(), map(), map()) ->
    {ok, map()} | {error, term()}.
subscription_acknowledged(SubscriptionId, Requested0, Granted0) ->
    case {valid_id(SubscriptionId), subscription_filter(Requested0),
          subscription_filter(Granted0, true)} of
        {true, {ok, Requested}, {ok, Granted}} ->
            case filter_subset(Granted, Requested) of
                true ->
                    notification_with_subscription(
                      SubscriptionId,
                      <<"notifications/subscriptions/acknowledged">>,
                      #{<<"notifications">> => Granted});
                false -> {error, mcp_subscription_grant_not_requested}
            end;
        {false, _, _} -> {error, invalid_mcp_request_id};
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end.

-spec subscription_event(binary() | integer(), binary(), map()) ->
    {ok, map()} | {error, term()}.
subscription_event(SubscriptionId, Method, Params0) when is_map(Params0) ->
    case valid_subscription_event(Method, Params0) of
        ok -> notification_with_subscription(SubscriptionId, Method, Params0);
        {error, _} = Error -> Error
    end;
subscription_event(_SubscriptionId, _Method, _Params) ->
    {error, invalid_mcp_subscription_event}.

-spec subscription_complete(binary() | integer(), map()) ->
    {ok, map()} | {error, term()}.
subscription_complete(SubscriptionId, ServerInfo) ->
    result_response(SubscriptionId, #{}, ServerInfo).

-spec client_capabilities(map()) -> {ok, map()} | {error, term()}.
client_capabilities(Capabilities) ->
    validate_capabilities(
      client, Capabilities,
      [<<"experimental">>, <<"elicitation">>, <<"extensions">>]).

-spec server_capabilities(map()) -> {ok, map()} | {error, term()}.
server_capabilities(Capabilities) ->
    validate_capabilities(
      server, Capabilities,
      [<<"experimental">>, <<"completions">>, <<"prompts">>,
       <<"resources">>, <<"tools">>, <<"extensions">>]).

-spec encode_header_value(binary()) -> {ok, binary()} | {error, term()}.
encode_header_value(Value) when is_binary(Value),
                                byte_size(Value) =< ?MAX_NAME_BYTES ->
    case valid_utf8(Value) of
        false -> {error, invalid_mcp_header_value};
        true ->
            Encoded = case plain_header_value(Value) andalso
                           not sentinel(Value) of
                true -> Value;
                false -> <<"=?base64?", (base64:encode(Value))/binary, "?=">>
            end,
            case byte_size(Encoded) =< ?MAX_HEADER_VALUE_BYTES of
                true -> {ok, Encoded};
                false -> {error, mcp_header_value_too_large}
            end
    end;
encode_header_value(_Value) ->
    {error, invalid_mcp_header_value}.

-spec decode_header_value(binary()) -> {ok, binary()} | {error, term()}.
decode_header_value(Value) when is_binary(Value),
                                byte_size(Value) =< ?MAX_HEADER_VALUE_BYTES ->
    case sentinel(Value) of
        true -> decode_sentinel(Value);
        false ->
            case plain_header_value(Value) andalso valid_utf8(Value) of
                true -> {ok, Value};
                false -> {error, invalid_mcp_header_value}
            end
    end;
decode_header_value(_Value) ->
    {error, invalid_mcp_header_value}.

request_meta(Context) ->
    Allowed = [client_info, client_capabilities, meta],
    case maps:keys(maps:without(Allowed, Context)) of
        [] ->
            Capabilities0 = maps:get(client_capabilities, Context, #{}),
            Info0 = maps:get(client_info, Context, undefined),
            Meta0 = maps:get(meta, Context, #{}),
            case {client_capabilities(Capabilities0),
                  optional_implementation(Info0), extension_meta(Meta0)} of
                {{ok, Capabilities}, {ok, Info}, {ok, ExtensionMeta}} ->
                    Meta1 = ExtensionMeta#{?PROTOCOL_META => ?VERSION,
                                           ?CLIENT_CAPABILITIES_META =>
                                               Capabilities},
                    {ok, maybe_put(?CLIENT_INFO_META, Info, Meta1)};
                {{error, _} = Error, _, _} -> Error;
                {_, {error, _} = Error, _} -> Error;
                {_, _, {error, _} = Error} -> Error
            end;
        _Unknown -> {error, invalid_mcp_client_context}
    end.

validate_modern_envelope(Headers, Id, Method,
                         #{<<"_meta">> := Meta} = Params)
  when is_map(Meta) ->
    case validate_request_meta(Meta) of
        {ok, ClientInfo, ClientCapabilities} ->
            case validate_standard_headers(Headers, Method, Params) of
                ok ->
                    {ok, #{id => Id, method => Method, params => Params,
                           client_info => ClientInfo,
                           client_capabilities => ClientCapabilities}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
validate_modern_envelope(_Headers, _Id, _Method, _Params) ->
    {error, missing_mcp_request_metadata}.

validate_request_meta(Meta) ->
    case {maps:get(?PROTOCOL_META, Meta, undefined),
          maps:get(?CLIENT_CAPABILITIES_META, Meta, undefined),
          maps:get(?CLIENT_INFO_META, Meta, undefined),
          maps:is_key(?LOG_LEVEL_META, Meta), reserved_meta_keys(Meta)} of
        {?VERSION, Capabilities0, Info0, false, ok} ->
            case {client_capabilities(Capabilities0),
                  optional_implementation(Info0)} of
                {{ok, Capabilities}, {ok, Info}} ->
                    {ok, Info, Capabilities};
                {{error, _} = Error, _} -> Error;
                {_, {error, _} = Error} -> Error
            end;
        {undefined, _, _, _, _} -> {error, missing_mcp_protocol_metadata};
        {_, undefined, _, _, _} -> {error, missing_mcp_client_capabilities};
        {_, _, _, true, _} ->
            {error, {deprecated_mcp_capability, <<"logging">>}};
        {?VERSION, _, _, false, {error, _} = Error} -> Error;
        _ -> {error, unsupported_mcp_protocol_version}
    end.

reserved_meta_keys(Meta) ->
    Allowed = [?PROTOCOL_META, ?CLIENT_CAPABILITIES_META, ?CLIENT_INFO_META],
    Reserved = [Key || Key <- maps:keys(Meta), reserved_meta_key(Key),
                       not lists:member(Key, Allowed)],
    case Reserved of
        [] -> ok;
        _ -> {error, reserved_mcp_metadata_key}
    end.

reserved_meta_key(Key) when is_binary(Key) ->
    Prefix = <<"io.modelcontextprotocol/">>,
    byte_size(Key) >= byte_size(Prefix) andalso
        binary:part(Key, 0, byte_size(Prefix)) =:= Prefix;
reserved_meta_key(_Key) -> false.

validate_standard_headers(Headers, Method, Params) ->
    case {maps:get(<<"mcp-protocol-version">>, Headers, undefined),
          maps:get(<<"mcp-method">>, Headers, undefined),
          expected_name(Method, Params)} of
        {?VERSION, Method, none} ->
            case maps:is_key(<<"mcp-name">>, Headers) of
                true -> {error, {mcp_header_mismatch, <<"mcp-name">>}};
                false -> ok
            end;
        {?VERSION, Method, {ok, Expected}} ->
            case maps:get(<<"mcp-name">>, Headers, undefined) of
                undefined -> {error, {missing_mcp_header, <<"mcp-name">>}};
                HeaderValue ->
                    case decode_header_value(HeaderValue) of
                        {ok, Expected} -> ok;
                        _ -> {error, {mcp_header_mismatch, <<"mcp-name">>}}
                    end
            end;
        {undefined, _, _} ->
            {error, {missing_mcp_header, <<"mcp-protocol-version">>}};
        {_, undefined, _} ->
            {error, {missing_mcp_header, <<"mcp-method">>}};
        {Version, _, _} when Version =/= ?VERSION ->
            {error, {mcp_header_mismatch, <<"mcp-protocol-version">>}};
        {_, OtherMethod, _} when OtherMethod =/= Method ->
            {error, {mcp_header_mismatch, <<"mcp-method">>}};
        {_, _, {error, _} = Error} -> Error
    end.

request_headers(Method, Params) ->
    case valid_method(Method) of
        false -> {error, invalid_mcp_method};
        true ->
            Base = #{<<"mcp-protocol-version">> => ?VERSION,
                     <<"mcp-method">> => Method},
            case expected_name(Method, Params) of
                none -> {ok, Base};
                {ok, Name} ->
                    case encode_header_value(Name) of
                        {ok, Encoded} ->
                            {ok, Base#{<<"mcp-name">> => Encoded}};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end
    end.

expected_name(<<"tools/call">>, Params) -> named_param(<<"name">>, Params);
expected_name(<<"prompts/get">>, Params) -> named_param(<<"name">>, Params);
expected_name(<<"resources/read">>, Params) -> named_param(<<"uri">>, Params);
expected_name(_Method, _Params) -> none.

named_param(Key, Params) ->
    case maps:get(Key, Params, undefined) of
        Value when is_binary(Value), byte_size(Value) > 0,
                   byte_size(Value) =< ?MAX_NAME_BYTES ->
            case valid_utf8(Value) of
                true -> {ok, Value};
                false -> {error, invalid_mcp_name}
            end;
        _ -> {error, invalid_mcp_name}
    end.

normalize_headers(Headers) when is_map(Headers), map_size(Headers) =< 128 ->
    normalize_header_list(maps:to_list(Headers), #{});
normalize_headers(Headers) when is_list(Headers) ->
    case bounded_list(Headers, 128) of
        true -> normalize_header_list(Headers, #{});
        false -> {error, invalid_mcp_headers}
    end;
normalize_headers(_Headers) -> {error, invalid_mcp_headers}.

normalize_header_list([], Acc) -> {ok, Acc};
normalize_header_list([{Name0, Value} | Rest], Acc)
  when is_binary(Name0), is_binary(Value),
       byte_size(Name0) > 0, byte_size(Name0) =< 256,
       byte_size(Value) =< ?MAX_HEADER_VALUE_BYTES ->
    case lower_header_name(Name0) of
        {ok, Name} ->
            case maps:is_key(Name, Acc) of
                true -> {error, duplicate_mcp_header};
                false -> normalize_header_list(Rest, Acc#{Name => Value})
            end;
        error -> {error, invalid_mcp_header_name}
    end;
normalize_header_list([_Invalid | _Rest], _Acc) ->
    {error, invalid_mcp_headers};
normalize_header_list(_Improper, _Acc) ->
    {error, invalid_mcp_headers}.

lower_header_name(Name) ->
    case lists:all(fun header_token/1, binary_to_list(Name)) of
        true ->
            {ok, list_to_binary(string:lowercase(binary_to_list(Name)))};
        false -> error
    end.

header_token(C) when C >= $a, C =< $z -> true;
header_token(C) when C >= $A, C =< $Z -> true;
header_token(C) when C >= $0, C =< $9 -> true;
header_token($!) -> true;
header_token($#) -> true;
header_token($$) -> true;
header_token($%) -> true;
header_token($&) -> true;
header_token($') -> true;
header_token($*) -> true;
header_token($+) -> true;
header_token($-) -> true;
header_token($.) -> true;
header_token($^) -> true;
header_token($_) -> true;
header_token($`) -> true;
header_token($|) -> true;
header_token($~) -> true;
header_token(_) -> false.

validate_capabilities(Role, Capabilities, Allowed)
  when is_map(Capabilities) ->
    Deprecated = case Role of
        client -> [<<"roots">>, <<"sampling">>];
        server -> [<<"logging">>]
    end,
    case first_present(Deprecated, Capabilities) of
        {ok, Key} -> {error, {deprecated_mcp_capability, Key}};
        none ->
            case adk_mcp_protocol_limits:validate_json(
                   Capabilities, capability_limits()) of
                {ok, Safe} ->
                    case lists:all(
                           fun(Key) -> lists:member(Key, Allowed) end,
                           maps:keys(Safe)) of
                        true -> {ok, Safe};
                        false -> {error, invalid_mcp_modern_capabilities}
                    end;
                {error, _} = Error -> Error
            end
    end;
validate_capabilities(_Role, _Capabilities, _Allowed) ->
    {error, invalid_mcp_modern_capabilities}.

first_present([], _Map) -> none;
first_present([Key | Rest], Map) ->
    case maps:is_key(Key, Map) of
        true -> {ok, Key};
        false -> first_present(Rest, Map)
    end.

extension_meta(Meta) when is_map(Meta) ->
    case adk_mcp_protocol_limits:validate_json(Meta, capability_limits()) of
        {ok, Safe} ->
            case lists:any(fun reserved_meta_key/1, maps:keys(Safe)) of
                true -> {error, reserved_mcp_metadata_key};
                false -> {ok, Safe}
            end;
        {error, _} = Error -> Error
    end;
extension_meta(_Meta) -> {error, invalid_mcp_request_metadata}.

result_meta(Result, ServerInfo) ->
    Meta0 = maps:get(<<"_meta">>, Result, #{}),
    case is_map(Meta0) andalso not maps:is_key(?SERVER_INFO_META, Meta0) of
        true ->
            Meta = Meta0#{?SERVER_INFO_META => ServerInfo},
            adk_mcp_protocol_limits:validate_json(
              Result#{<<"_meta">> => Meta});
        false -> {error, reserved_mcp_response_metadata}
    end.

add_result_type(Result) ->
    case maps:get(<<"resultType">>, Result, undefined) of
        undefined -> {ok, Result#{<<"resultType">> => <<"complete">>}};
        Value when is_binary(Value), byte_size(Value) > 0,
                   byte_size(Value) =< 128 ->
            case valid_utf8(Value) of
                true -> {ok, Result};
                false -> {error, invalid_mcp_result_type}
            end;
        _ -> {error, invalid_mcp_result_type}
    end.

cache_options(Options) ->
    Allowed = [ttl_ms, cache_scope],
    case maps:keys(maps:without(Allowed, Options)) of
        [] ->
            Ttl = maps:get(ttl_ms, Options, 0),
            Scope0 = maps:get(cache_scope, Options, private),
            Scope = case Scope0 of
                private -> <<"private">>;
                public -> <<"public">>;
                <<"private">> -> <<"private">>;
                <<"public">> -> <<"public">>;
                _ -> invalid
            end,
            case is_integer(Ttl) andalso Ttl >= 0 andalso
                 Ttl =< ?MAX_ID_INTEGER andalso Scope =/= invalid of
                true -> {ok, Ttl, Scope};
                false -> {error, invalid_mcp_cache_options}
            end;
        _Unknown -> {error, invalid_mcp_cache_options}
    end.

sort_list_items(Kind, Items) when length(Items) =< 1024 ->
    case list_key(Kind) of
        invalid -> {error, invalid_mcp_list_kind};
        Key -> collect_list_items(Items, Key, #{})
    end;
sort_list_items(_Kind, _Items) -> {error, mcp_list_capacity_exceeded}.

collect_list_items([], _Key, ById) ->
    {ok, [Item || {_Id, Item} <- lists:sort(maps:to_list(ById))]};
collect_list_items([Item0 | Rest], Key, ById) when is_map(Item0) ->
    case adk_mcp_protocol_limits:validate_json(
           Item0, #{max_bytes => 262144, max_depth => 32,
                    max_nodes => 10000, max_binary_bytes => 131072,
                    max_total_binary_bytes => 262144,
                    max_list_length => 2048, max_map_size => 1024,
                    max_external_bytes => 1048576}) of
        {ok, #{Key := Id} = Item} when is_binary(Id), byte_size(Id) > 0,
                                       byte_size(Id) =< ?MAX_NAME_BYTES ->
            case valid_utf8(Id) andalso not maps:is_key(Id, ById) of
                true -> collect_list_items(Rest, Key, ById#{Id => Item});
                false -> {error, duplicate_or_invalid_mcp_list_item}
            end;
        {ok, _} -> {error, invalid_mcp_list_item};
        {error, _} = Error -> Error
    end;
collect_list_items([_Invalid | _Rest], _Key, _ById) ->
    {error, invalid_mcp_list_item}.

list_key(tools) -> <<"name">>;
list_key(resources) -> <<"uri">>;
list_key(prompts) -> <<"name">>;
list_key(_) -> invalid.

list_field(tools) -> <<"tools">>;
list_field(resources) -> <<"resources">>;
list_field(prompts) -> <<"prompts">>.

validate_input_requests(Requests) when is_map(Requests),
                                       map_size(Requests) =< ?MAX_INPUT_REQUESTS ->
    case adk_mcp_protocol_limits:validate_json(Requests, mrtr_limits()) of
        {ok, Safe} -> validate_input_request_list(maps:to_list(Safe));
        {error, _} = Error -> Error
    end;
validate_input_requests(_Requests) ->
    {error, mcp_input_request_capacity_exceeded}.

validate_input_request_list([]) -> {ok, #{}};
validate_input_request_list(Pairs) ->
    validate_input_request_list(Pairs, #{}).

validate_input_request_list([], Acc) -> {ok, Acc};
validate_input_request_list([{Key, Request} | Rest], Acc) ->
    case valid_text(Key, 128) andalso is_map(Request) andalso
         exact_keys(Request, [<<"method">>, <<"params">>]) of
        true ->
            Method = maps:get(<<"method">>, Request),
            Params = maps:get(<<"params">>, Request),
            case Method of
                <<"elicitation/create">> when is_map(Params) ->
                    validate_input_request_list(Rest, Acc#{Key => Request});
                <<"sampling/createMessage">> ->
                    {error, {deprecated_mcp_capability, <<"sampling">>}};
                <<"roots/list">> ->
                    {error, {deprecated_mcp_capability, <<"roots">>}};
                _ -> {error, invalid_mcp_input_request}
            end;
        false -> {error, invalid_mcp_input_request}
    end.

input_request_capabilities(Requests, Capabilities) ->
    NeedsElicitation = lists:any(
                         fun(#{<<"method">> := Method}) ->
                             Method =:= <<"elicitation/create">>
                         end, maps:values(Requests)),
    case NeedsElicitation andalso
         not maps:is_key(<<"elicitation">>, Capabilities) of
        true -> {error, missing_mcp_elicitation_capability};
        false -> ok
    end.

validate_input_responses(Responses) when is_map(Responses),
                                         map_size(Responses) =<
                                             ?MAX_INPUT_REQUESTS ->
    case adk_mcp_protocol_limits:validate_json(Responses, mrtr_limits()) of
        {ok, Safe} ->
            case lists:all(
                   fun({Key, Response}) ->
                       valid_text(Key, 128) andalso is_map(Response) andalso
                       maps:get(<<"resultType">>, Response, undefined) =:=
                           <<"complete">>
                   end, maps:to_list(Safe)) of
                true -> {ok, Safe};
                false -> {error, invalid_mcp_input_response}
            end;
        {error, _} = Error -> Error
    end;
validate_input_responses(_Responses) ->
    {error, mcp_input_response_capacity_exceeded}.

validate_request_state(undefined) -> {ok, undefined};
validate_request_state(State) ->
    case valid_text(State, ?MAX_REQUEST_STATE_BYTES) of
        true -> {ok, State};
        false -> {error, invalid_mcp_request_state}
    end.

subscription_filter(Filter0) when is_map(Filter0) ->
    subscription_filter(Filter0, false);
subscription_filter(_Filter) ->
    {error, invalid_mcp_subscription_filter}.

subscription_filter(Filter0, AllowEmpty) when is_map(Filter0),
                                                is_boolean(AllowEmpty) ->
    Allowed = [<<"toolsListChanged">>, <<"promptsListChanged">>,
               <<"resourcesListChanged">>, <<"resourceSubscriptions">>],
    case adk_mcp_protocol_limits:validate_json(
           Filter0, #{max_bytes => 524288, max_depth => 8,
                      max_nodes => 2048, max_binary_bytes => 4096,
                      max_total_binary_bytes => 524288,
                      max_list_length => ?MAX_SUBSCRIPTION_RESOURCES,
                      max_map_size => 8, max_external_bytes => 1048576}) of
        {ok, Safe} ->
            case exact_keys_subset(Safe, Allowed) of
                true -> normalize_subscription_filter(Safe, AllowEmpty);
                false -> {error, invalid_mcp_subscription_filter}
            end;
        {error, _} = Error -> Error
    end;
subscription_filter(_Filter, _AllowEmpty) ->
    {error, invalid_mcp_subscription_filter}.

normalize_subscription_filter(Filter, AllowEmpty) ->
    Flags = [<<"toolsListChanged">>, <<"promptsListChanged">>,
             <<"resourcesListChanged">>],
    case lists:all(
           fun(Key) ->
               Value = maps:get(Key, Filter, false),
               Value =:= true orelse Value =:= false
           end, Flags) of
        false -> {error, invalid_mcp_subscription_filter};
        true ->
            Resources0 = maps:get(<<"resourceSubscriptions">>, Filter, []),
            case normalize_resource_subscriptions(Resources0) of
                {ok, Resources} ->
                    Base = lists:foldl(
                             fun(Key, Acc) ->
                                 case maps:get(Key, Filter, false) of
                                     true -> Acc#{Key => true};
                                     false -> Acc
                                 end
                             end, #{}, Flags),
                    Normalized = case Resources of
                        [] -> Base;
                        _ -> Base#{<<"resourceSubscriptions">> => Resources}
                    end,
                    case map_size(Normalized) > 0 orelse AllowEmpty of
                        true -> {ok, Normalized};
                        false -> {error, empty_mcp_subscription_filter}
                    end;
                {error, _} = Error -> Error
            end
    end.

normalize_resource_subscriptions(Resources) when is_list(Resources) ->
    case bounded_list(Resources, ?MAX_SUBSCRIPTION_RESOURCES) andalso
         lists:all(fun(Uri) -> valid_text(Uri, ?MAX_NAME_BYTES) end,
                   Resources) of
        true ->
            Sorted = lists:usort(Resources),
            case length(Sorted) =:= length(Resources) of
                true -> {ok, Sorted};
                false -> {error, duplicate_mcp_resource_subscription}
            end;
        false -> {error, invalid_mcp_resource_subscriptions}
    end;
normalize_resource_subscriptions(_Resources) ->
    {error, invalid_mcp_resource_subscriptions}.

filter_subset(Granted, Requested) ->
    Flags = [<<"toolsListChanged">>, <<"promptsListChanged">>,
             <<"resourcesListChanged">>],
    FlagsOk = lists:all(
                fun(Key) ->
                    not maps:get(Key, Granted, false) orelse
                        maps:get(Key, Requested, false)
                end, Flags),
    GrantedResources = maps:get(<<"resourceSubscriptions">>, Granted, []),
    RequestedResources = maps:get(<<"resourceSubscriptions">>, Requested, []),
    FlagsOk andalso lists:all(
                       fun(Uri) -> lists:member(Uri, RequestedResources) end,
                       GrantedResources).

notification_with_subscription(SubscriptionId, Method, Params0) ->
    case valid_id(SubscriptionId) andalso not maps:is_key(<<"_meta">>,
                                                          Params0) of
        false -> {error, invalid_mcp_subscription_notification};
        true ->
            Params = Params0#{<<"_meta">> =>
                                  #{?SUBSCRIPTION_ID_META =>
                                        SubscriptionId}},
            adk_mcp_protocol_limits:validate_json(
              #{<<"jsonrpc">> => <<"2.0">>, <<"method">> => Method,
                <<"params">> => Params})
    end.

valid_subscription_event(Method, Params) ->
    case maps:is_key(<<"_meta">>, Params) of
        true -> {error, reserved_mcp_subscription_metadata};
        false ->
            case Method of
                <<"notifications/tools/list_changed">> -> ok;
                <<"notifications/prompts/list_changed">> -> ok;
                <<"notifications/resources/list_changed">> -> ok;
                <<"notifications/resources/updated">> ->
                    case maps:get(<<"uri">>, Params, undefined) of
                        Uri when is_binary(Uri) ->
                            case valid_text(Uri, ?MAX_NAME_BYTES) of
                                true -> ok;
                                false -> {error, invalid_mcp_resource_uri}
                            end;
                        _ -> {error, invalid_mcp_resource_uri}
                    end;
                _ -> {error, invalid_mcp_subscription_event}
            end
    end.

implementation(Value) when is_map(Value) ->
    Allowed = [<<"name">>, <<"title">>, <<"version">>, <<"description">>,
               <<"websiteUrl">>, <<"icons">>],
    case adk_mcp_protocol_limits:validate_json(
           Value, #{max_bytes => 65536, max_depth => 12,
                    max_nodes => 1024, max_binary_bytes => 16384,
                    max_total_binary_bytes => 65536,
                    max_list_length => 64, max_map_size => 64,
                    max_external_bytes => 262144}) of
        {ok, #{<<"name">> := Name, <<"version">> := Version} = Safe} ->
            case exact_keys_subset(Safe, Allowed) andalso
                 valid_text(Name, 256) andalso valid_text(Version, 256) of
                true -> {ok, Safe};
                false -> {error, invalid_mcp_implementation}
            end;
        {ok, _} -> {error, invalid_mcp_implementation};
        {error, _} = Error -> Error
    end;
implementation(_Value) -> {error, invalid_mcp_implementation}.

optional_implementation(undefined) -> {ok, undefined};
optional_implementation(Value) -> implementation(Value).

valid_request_shape(Message, Id, Method) ->
    exact_keys(Message,
               [<<"jsonrpc">>, <<"id">>, <<"method">>, <<"params">>])
        andalso valid_id(Id) andalso valid_method(Method).

valid_id(Id) when is_binary(Id) -> valid_text(Id, 256);
valid_id(Id) when is_integer(Id) ->
    Id >= -?MAX_ID_INTEGER andalso Id =< ?MAX_ID_INTEGER;
valid_id(_Id) -> false.

valid_method(Method) when is_binary(Method) ->
    valid_text(Method, ?MAX_METHOD_BYTES) andalso
        lists:all(fun(C) -> C >= 16#21 andalso C =< 16#7e end,
                  binary_to_list(Method));
valid_method(_Method) -> false.

optional_text(undefined, _Max) -> {ok, undefined};
optional_text(Value, Max) ->
    case valid_text(Value, Max) of
        true -> {ok, Value};
        false -> {error, invalid_mcp_text}
    end.

valid_text(Value, Max) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< Max andalso
        valid_utf8(Value);
valid_text(_Value, _Max) -> false.

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch
        _:_ -> false
    end.

plain_header_value(<<>>) -> true;
plain_header_value(Value) ->
    First = binary:first(Value),
    Last = binary:last(Value),
    not header_whitespace(First) andalso not header_whitespace(Last) andalso
        lists:all(fun header_value_byte/1, binary_to_list(Value)).

header_whitespace($\s) -> true;
header_whitespace($\t) -> true;
header_whitespace(_) -> false.

header_value_byte($\t) -> true;
header_value_byte(C) when C >= 16#20, C =< 16#7e -> true;
header_value_byte(_) -> false.

sentinel(Value) when byte_size(Value) >= 11 ->
    Prefix = <<"=?base64?">>,
    Suffix = <<"?=">>,
    binary:part(Value, 0, byte_size(Prefix)) =:= Prefix andalso
        binary:part(Value, byte_size(Value) - byte_size(Suffix),
                    byte_size(Suffix)) =:= Suffix;
sentinel(_Value) -> false.

decode_sentinel(Value) ->
    PrefixBytes = byte_size(<<"=?base64?">>),
    PayloadBytes = byte_size(Value) - PrefixBytes - byte_size(<<"?=">>),
    Payload = binary:part(Value, PrefixBytes, PayloadBytes),
    try base64:decode(Payload) of
        Decoded when byte_size(Decoded) =< ?MAX_NAME_BYTES ->
            case base64:encode(Decoded) =:= Payload andalso
                 valid_utf8(Decoded) of
                true -> {ok, Decoded};
                false -> {error, invalid_mcp_header_value}
            end;
        _ -> {error, mcp_header_value_too_large}
    catch
        _:_ -> {error, invalid_mcp_header_value}
    end.

bounded_list(List, Max) -> bounded_list(List, Max, 0).
bounded_list([], _Max, _Count) -> true;
bounded_list([_ | Rest], Max, Count) when Count < Max ->
    bounded_list(Rest, Max, Count + 1);
bounded_list(_, _Max, _Count) -> false.

exact_keys(Map, Keys) -> lists:sort(maps:keys(Map)) =:= lists:sort(Keys).

exact_keys_subset(Map, Allowed) ->
    lists:all(fun(Key) -> lists:member(Key, Allowed) end, maps:keys(Map)).

maybe_put(_Key, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.

maybe_put_map(_Key, MapValue, Map) when map_size(MapValue) =:= 0 -> Map;
maybe_put_map(Key, MapValue, Map) -> Map#{Key => MapValue}.

capability_limits() ->
    #{max_bytes => 262144, max_depth => 16,
      max_nodes => 4096, max_binary_bytes => 65536,
      max_total_binary_bytes => 262144,
      max_list_length => 512, max_map_size => 256,
      max_external_bytes => 1048576}.

mrtr_limits() ->
    #{max_bytes => 524288, max_depth => 32,
      max_nodes => 10000, max_binary_bytes => 131072,
      max_total_binary_bytes => 524288,
      max_list_length => 1024, max_map_size => 256,
      max_external_bytes => 2097152}.
