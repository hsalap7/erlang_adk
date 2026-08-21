%% @doc MCP 2025-11-25 handshake-era message helpers.
%%
%% Legacy capabilities such as roots, sampling, and logging are intentionally
%% confined to this module.  The modern codec never advertises them.
-module(adk_mcp_protocol_legacy).

-export([version/0, initialize_request/3, initialize_result/4,
         request/3, result_response/2, validate_request/1,
         client_capabilities/1, server_capabilities/1]).

-define(VERSION, <<"2025-11-25">>).
-define(MAX_ID_INTEGER, 9007199254740991).
-define(MAX_METHOD_BYTES, 256).

-spec version() -> binary().
version() -> ?VERSION.

-spec initialize_request(binary() | integer(), map(), map()) ->
    {ok, map()} | {error, term()}.
initialize_request(Id, ClientInfo, Capabilities) ->
    case {valid_id(Id), implementation(ClientInfo),
          client_capabilities(Capabilities)} of
        {true, {ok, SafeInfo}, {ok, SafeCapabilities}} ->
            request(
              Id, <<"initialize">>,
              #{<<"protocolVersion">> => ?VERSION,
                <<"capabilities">> => SafeCapabilities,
                <<"clientInfo">> => SafeInfo});
        {false, _, _} -> {error, invalid_mcp_request_id};
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end.

-spec initialize_result(binary() | integer(), map(), map(), map()) ->
    {ok, map()} | {error, term()}.
initialize_result(Id, ServerInfo, Capabilities, Options)
  when is_map(Options) ->
    Allowed = [instructions],
    case maps:keys(maps:without(Allowed, Options)) of
        [] ->
            case {implementation(ServerInfo),
                  server_capabilities(Capabilities),
                  optional_text(maps:get(instructions, Options, undefined),
                                16384)} of
                {{ok, SafeInfo}, {ok, SafeCapabilities}, {ok, Instructions}} ->
                    Base = #{<<"protocolVersion">> => ?VERSION,
                             <<"capabilities">> => SafeCapabilities,
                             <<"serverInfo">> => SafeInfo},
                    Result = maybe_put(<<"instructions">>, Instructions, Base),
                    result_response(Id, Result);
                {{error, _} = Error, _, _} -> Error;
                {_, {error, _} = Error, _} -> Error;
                {_, _, {error, _} = Error} -> Error
            end;
        _Unknown -> {error, invalid_mcp_initialize_options}
    end;
initialize_result(_Id, _ServerInfo, _Capabilities, _Options) ->
    {error, invalid_mcp_initialize_options}.

-spec request(binary() | integer(), binary(), map()) ->
    {ok, map()} | {error, term()}.
request(Id, Method, Params) ->
    Message = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                <<"method">> => Method, <<"params">> => Params},
    validate_request(Message).

-spec result_response(binary() | integer(), map()) ->
    {ok, map()} | {error, term()}.
result_response(Id, Result) when is_map(Result) ->
    Response = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                 <<"result">> => Result},
    case valid_id(Id) of
        false -> {error, invalid_mcp_request_id};
        true -> adk_mcp_protocol_limits:validate_json(Response)
    end;
result_response(_Id, _Result) ->
    {error, invalid_mcp_result}.

-spec validate_request(term()) -> {ok, map()} | {error, term()}.
validate_request(Message) ->
    case adk_mcp_protocol_limits:validate_json(Message) of
        {ok, #{<<"jsonrpc">> := <<"2.0">>, <<"id">> := Id,
               <<"method">> := Method, <<"params">> := Params} = Safe}
          when is_map(Params) ->
            case valid_id(Id) andalso valid_method(Method) andalso
                 exact_keys(Safe,
                            [<<"jsonrpc">>, <<"id">>, <<"method">>,
                             <<"params">>]) of
                true -> {ok, Safe};
                false -> {error, invalid_mcp_legacy_request}
            end;
        {ok, _Other} -> {error, invalid_mcp_legacy_request};
        {error, _} = Error -> Error
    end.

-spec client_capabilities(map()) -> {ok, map()} | {error, term()}.
client_capabilities(Capabilities) ->
    validate_capabilities(
      Capabilities,
      [<<"experimental">>, <<"roots">>, <<"sampling">>,
       <<"elicitation">>, <<"extensions">>]).

-spec server_capabilities(map()) -> {ok, map()} | {error, term()}.
server_capabilities(Capabilities) ->
    validate_capabilities(
      Capabilities,
      [<<"experimental">>, <<"logging">>, <<"completions">>,
       <<"prompts">>, <<"resources">>, <<"tools">>, <<"tasks">>,
       <<"extensions">>]).

validate_capabilities(Capabilities, Allowed) when is_map(Capabilities) ->
    case adk_mcp_protocol_limits:validate_json(
           Capabilities,
           #{max_bytes => 262144, max_depth => 16,
             max_nodes => 4096, max_binary_bytes => 65536,
             max_total_binary_bytes => 262144,
             max_list_length => 512, max_map_size => 256,
             max_external_bytes => 1048576}) of
        {ok, Safe} ->
            case lists:all(
                   fun(Key) -> lists:member(Key, Allowed) end,
                   maps:keys(Safe)) of
                true -> {ok, Safe};
                false -> {error, invalid_mcp_legacy_capabilities}
            end;
        {error, _} = Error -> Error
    end;
validate_capabilities(_Capabilities, _Allowed) ->
    {error, invalid_mcp_legacy_capabilities}.

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
implementation(_Value) ->
    {error, invalid_mcp_implementation}.

valid_id(Id) when is_binary(Id) ->
    byte_size(Id) > 0 andalso byte_size(Id) =< 256 andalso valid_utf8(Id);
valid_id(Id) when is_integer(Id) ->
    Id >= -?MAX_ID_INTEGER andalso Id =< ?MAX_ID_INTEGER;
valid_id(_Id) -> false.

valid_method(Method) -> valid_text(Method, ?MAX_METHOD_BYTES).

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

exact_keys(Map, Keys) -> lists:sort(maps:keys(Map)) =:= lists:sort(Keys).

exact_keys_subset(Map, Allowed) ->
    lists:all(fun(Key) -> lists:member(Key, Allowed) end, maps:keys(Map)).

maybe_put(_Key, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.
