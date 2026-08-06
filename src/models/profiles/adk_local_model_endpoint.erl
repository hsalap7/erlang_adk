%% @doc Security boundary for keyless, same-machine OpenAI-compatible models.
%%
%% Ordinary compatible endpoints require HTTPS.  This module implements the
%% one explicit exception: an operator-owned HTTP endpoint on a numeric
%% loopback address, with no credential and no Live adapter.  Materialization
%% adds the transport's private-address permission together with an internal
%% policy marker; public profile callers cannot supply either value.
-module(adk_local_model_endpoint).

-export([normalize/1, is_endpoint/1, validate_profile/5,
         materialize/1, validate_runtime/1]).

-define(MAX_BASE_URL_BYTES, 8192).
-define(MAX_PATH_BYTES, 2048).

-type endpoint() :: #{scheme := http,
                      host := binary(),
                      port := pos_integer(),
                      base_path := binary(),
                      policy := loopback_keyless}.
-export_type([endpoint/0]).

-spec normalize(term()) -> {ok, endpoint()} | {error, term()}.
normalize(Endpoint) when is_map(Endpoint) ->
    Required = [scheme, host, port, base_path, policy],
    case lists:sort(maps:keys(Endpoint)) =:= lists:sort(Required) of
        true -> normalize_fields(Endpoint);
        false -> {error, invalid_local_model_endpoint}
    end;
normalize(_Endpoint) ->
    {error, invalid_local_model_endpoint}.

-spec is_endpoint(term()) -> boolean().
is_endpoint(Endpoint) ->
    case normalize(Endpoint) of
        {ok, _} -> true;
        {error, _} -> false
    end.

%% @doc Check the profile-wide invariants that cannot be established by
%% validating the endpoint map alone.
-spec validate_profile(term(), term(), term(), term(), term()) ->
    ok | {error, term()}.
validate_profile(Endpoint, RequestAdapter, LiveAdapter,
                 Credential, RequestOptions) ->
    case Endpoint of
        #{policy := loopback_keyless} ->
            case normalize(Endpoint) of
                {ok, _} ->
                    validate_profile_fields(RequestAdapter, LiveAdapter,
                                            Credential, RequestOptions);
                {error, _} = Error -> Error
            end;
        _ ->
            ok
    end.

-spec materialize(term()) -> {ok, map()} | {error, term()}.
materialize(Endpoint) ->
    case normalize(Endpoint) of
        {ok, #{host := Host, port := Port,
               base_path := Path}} ->
            Authority = authority(Host, Port),
            {ok, #{base_url => <<"http://", Authority/binary,
                                Path/binary>>,
                   allow_private_hosts => true,
                   local_endpoint_policy => loopback_keyless}};
        {error, _} = Error -> Error
    end.

%% @doc Re-check the materialized policy at the compatible adapter boundary.
%% This also protects trusted direct configurations from accidentally pairing
%% the local opt-in marker with a credential, a non-loopback URL, or the
%% default private-address rejection policy.
-spec validate_runtime(term()) -> ok | {error, term()}.
validate_runtime(Config) when is_map(Config) ->
    case maps:get(local_endpoint_policy, Config, undefined) of
        loopback_keyless ->
            validate_runtime_fields(Config);
        _ ->
            {error, invalid_local_model_endpoint_policy}
    end;
validate_runtime(_Config) ->
    {error, invalid_local_model_endpoint_policy}.

normalize_fields(#{scheme := http, host := Host, port := Port,
                   base_path := Path, policy := loopback_keyless} = Endpoint) ->
    case loopback_host(Host) andalso valid_port(Port) andalso
         valid_base_path(Path) of
        true -> {ok, Endpoint};
        false -> {error, invalid_local_model_endpoint}
    end;
normalize_fields(_Endpoint) ->
    {error, invalid_local_model_endpoint}.

validate_profile_fields(adk_llm_compatible, undefined,
                        #{source := none},
                        #{auth_scheme := none}) ->
    ok;
validate_profile_fields(_RequestAdapter, LiveAdapter,
                        _Credential, _RequestOptions)
  when LiveAdapter =/= undefined ->
    {error, local_model_endpoint_live_not_supported};
validate_profile_fields(RequestAdapter, _LiveAdapter,
                        _Credential, _RequestOptions)
  when RequestAdapter =/= adk_llm_compatible ->
    {error, local_model_endpoint_requires_compatible_adapter};
validate_profile_fields(_RequestAdapter, _LiveAdapter,
                        #{source := Source}, _RequestOptions)
  when Source =/= none ->
    {error, local_model_endpoint_requires_no_credential};
validate_profile_fields(_RequestAdapter, _LiveAdapter,
                        _Credential, _RequestOptions) ->
    {error, local_model_endpoint_requires_keyless_auth}.

validate_runtime_fields(Config) ->
    case {runtime_base_url(Config),
          maps:get(auth_scheme, Config, undefined),
          maps:is_key(api_key, Config),
          maps:get(allow_private_hosts, Config, undefined)} of
        {ok, none, false, true} -> ok;
        {{error, _} = Error, _, _, _} -> Error;
        {_, Scheme, _, _} when Scheme =/= none ->
            {error, local_model_endpoint_requires_keyless_auth};
        {_, _, true, _} ->
            {error, local_model_endpoint_requires_no_credential};
        {_, _, _, _} ->
            {error, local_model_endpoint_requires_private_host_access}
    end.

runtime_base_url(Config) ->
    case maps:get(base_url, Config, undefined) of
        Base when is_binary(Base), byte_size(Base) > 0,
                  byte_size(Base) =< ?MAX_BASE_URL_BYTES ->
            parse_runtime_base_url(Base);
        _ ->
            {error, invalid_local_model_base_url}
    end.

parse_runtime_base_url(Base) ->
    try uri_string:parse(Base) of
        #{scheme := Scheme0, host := Host,
          path := Path} = Uri
          when is_binary(Scheme0), is_binary(Host), is_binary(Path) ->
            Scheme = unicode:characters_to_binary(
                       string:lowercase(Scheme0)),
            Port = maps:get(port, Uri, 80),
            case Scheme =:= <<"http">> andalso loopback_host(Host) andalso
                 valid_port(Port) andalso valid_base_path(Path) andalso
                 not maps:is_key(userinfo, Uri) andalso
                 not maps:is_key(query, Uri) andalso
                 not maps:is_key(fragment, Uri) of
                true -> ok;
                false -> {error, local_model_endpoint_loopback_http_required}
            end;
        _ ->
            {error, invalid_local_model_base_url}
    catch
        _:_ -> {error, invalid_local_model_base_url}
    end.

authority(<<"::1">>, Port) ->
    <<"[::1]:", (integer_to_binary(Port))/binary>>;
authority(Host, Port) ->
    <<Host/binary, ":", (integer_to_binary(Port))/binary>>.

loopback_host(<<"127.0.0.1">>) -> true;
loopback_host(<<"::1">>) -> true;
loopback_host(_Host) -> false.

valid_port(Port) ->
    is_integer(Port) andalso Port > 0 andalso Port =< 65535.

valid_base_path(Path)
  when is_binary(Path), byte_size(Path) > 0,
       byte_size(Path) =< ?MAX_PATH_BYTES ->
    valid_utf8(Path) andalso binary:at(Path, 0) =:= $/ andalso
    binary:match(Path, <<"?">>) =:= nomatch andalso
    binary:match(Path, <<"#">>) =:= nomatch andalso
    canonical_path_segments(Path) andalso
    lists:all(fun safe_path_char/1, binary_to_list(Path)) andalso
    not contains_control(Path);
valid_base_path(_Path) -> false.

%% Keep the local HTTP exception deliberately narrower than a general URI
%% path. Percent escapes, backslashes, whitespace, dot segments and empty
%% interior segments can be normalized differently by clients and loopback
%% servers. Rejecting them preserves the exact operator-selected base path.
canonical_path_segments(Path) ->
    case binary:split(Path, <<"/">>, [global]) of
        [<<>> | Segments0] ->
            Segments = drop_trailing_empty(Segments0),
            lists:all(
              fun(Segment) ->
                  Segment =/= <<>> andalso Segment =/= <<".">> andalso
                      Segment =/= <<"..">>
              end, Segments);
        _ -> false
    end.

drop_trailing_empty(Segments) ->
    case lists:reverse(Segments) of
        [<<>> | Rest] -> lists:reverse(Rest);
        _ -> Segments
    end.

safe_path_char($/) -> true;
safe_path_char(Char) when Char >= $a, Char =< $z -> true;
safe_path_char(Char) when Char >= $A, Char =< $Z -> true;
safe_path_char(Char) when Char >= $0, Char =< $9 -> true;
safe_path_char(Char) -> lists:member(Char, "-._~").

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch
        _:_ -> false
    end.

contains_control(Value) ->
    lists:any(fun(Char) -> Char < 32 orelse Char =:= 127 end,
              binary_to_list(Value)).
