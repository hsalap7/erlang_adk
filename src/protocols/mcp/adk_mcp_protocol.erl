%% @doc Explicit MCP protocol-era dispatch.
%%
%% MCP 2025-11-25 is a handshake/session era. MCP 2026-07-28 is a stateless,
%% per-request-metadata era.  Callers must select an era explicitly; this
%% module never guesses from the presence of a session or silently negotiates
%% a modern version through the legacy initialize exchange.
-module(adk_mcp_protocol).

-export([legacy_version/0, modern_version/0, supported_versions/0, era/1,
         request/5, validate_http_request/3, result_response/4,
         client_capabilities/2, server_capabilities/2,
         initialize_request/3, initialize_result/4,
         discover_result/3]).

-type era() :: legacy | modern.
-export_type([era/0]).

-spec legacy_version() -> binary().
legacy_version() -> adk_mcp_protocol_legacy:version().

-spec modern_version() -> binary().
modern_version() -> adk_mcp_protocol_modern:version().

-spec supported_versions() -> [binary()].
supported_versions() -> [modern_version(), legacy_version()].

-spec era(era() | binary()) -> {ok, era()} | {error, term()}.
era(legacy) -> {ok, legacy};
era(modern) -> {ok, modern};
era(<<"2025-11-25">>) -> {ok, legacy};
era(<<"2026-07-28">>) -> {ok, modern};
era(_Version) -> {error, unsupported_mcp_protocol_version}.

-spec request(era() | binary(), binary() | integer(), binary(), map(), map()) ->
    {ok, #{message := map(), headers := map()}} | {error, term()}.
request(Era0, Id, Method, Params, Context) when is_map(Context) ->
    case era(Era0) of
        {ok, modern} ->
            adk_mcp_protocol_modern:request(
              Id, Method, Params, Context);
        {ok, legacy} ->
            case map_size(Context) of
                0 ->
                    case adk_mcp_protocol_legacy:request(Id, Method, Params) of
                        {ok, Message} ->
                            {ok, #{message => Message, headers => #{}}};
                        {error, _} = Error -> Error
                    end;
                _ -> {error, invalid_mcp_legacy_request_context}
            end;
        {error, _} = Error -> Error
    end;
request(_Era, _Id, _Method, _Params, _Context) ->
    {error, invalid_mcp_request_context}.

-spec validate_http_request(era() | binary(),
                            map() | [{binary(), binary()}], term()) ->
    {ok, map()} | {error, term()}.
validate_http_request(Era0, Headers, Message) ->
    case era(Era0) of
        {ok, modern} ->
            adk_mcp_protocol_modern:validate_http_request(Headers, Message);
        {ok, legacy} ->
            adk_mcp_protocol_legacy:validate_request(Message);
        {error, _} = Error -> Error
    end.

-spec result_response(era() | binary(), binary() | integer(), map(), map()) ->
    {ok, map()} | {error, term()}.
result_response(Era0, Id, Result, ServerInfo) when is_map(ServerInfo) ->
    case era(Era0) of
        {ok, modern} ->
            adk_mcp_protocol_modern:result_response(Id, Result, ServerInfo);
        {ok, legacy} ->
            case map_size(ServerInfo) =:= 0 of
                true -> adk_mcp_protocol_legacy:result_response(Id, Result);
                false -> {error, invalid_mcp_legacy_result_context}
            end;
        {error, _} = Error -> Error
    end;
result_response(_Era, _Id, _Result, _ServerInfo) ->
    {error, invalid_mcp_result_context}.

-spec client_capabilities(era() | binary(), map()) ->
    {ok, map()} | {error, term()}.
client_capabilities(Era0, Capabilities) ->
    case era(Era0) of
        {ok, modern} ->
            adk_mcp_protocol_modern:client_capabilities(Capabilities);
        {ok, legacy} ->
            adk_mcp_protocol_legacy:client_capabilities(Capabilities);
        {error, _} = Error -> Error
    end.

-spec server_capabilities(era() | binary(), map()) ->
    {ok, map()} | {error, term()}.
server_capabilities(Era0, Capabilities) ->
    case era(Era0) of
        {ok, modern} ->
            adk_mcp_protocol_modern:server_capabilities(Capabilities);
        {ok, legacy} ->
            adk_mcp_protocol_legacy:server_capabilities(Capabilities);
        {error, _} = Error -> Error
    end.

-spec initialize_request(binary() | integer(), map(), map()) ->
    {ok, map()} | {error, term()}.
initialize_request(Id, ClientInfo, Capabilities) ->
    adk_mcp_protocol_legacy:initialize_request(
      Id, ClientInfo, Capabilities).

-spec initialize_result(binary() | integer(), map(), map(), map()) ->
    {ok, map()} | {error, term()}.
initialize_result(Id, ServerInfo, Capabilities, Options) ->
    adk_mcp_protocol_legacy:initialize_result(
      Id, ServerInfo, Capabilities, Options).

-spec discover_result(map(), map(), map()) ->
    {ok, map()} | {error, term()}.
discover_result(ServerInfo, Capabilities, Options) ->
    adk_mcp_protocol_modern:discover_result(
      ServerInfo, Capabilities, Options).
