%% @doc Provider-neutral construction of bounded JSON model requests.
%%
%% This module owns no credentials and knows no vendor wire schema. It joins a
%% validated base URL with a fixed adapter-owned path, derives the exact
%% scheme/host allow-list, encodes only a checked JSON map, and invokes an
%% injected `adk_model_http_transport'. Redirects are always disabled.
-module(adk_model_http_client).

-export([validate_options/1, validate_https_base_url/1,
         request/4, stream/5, resolve_api_key/2,
         resolve_bound_api_key/3, resolve_explicit_api_key/1,
         base_url_matches/2]).

-define(DEFAULT_TIMEOUT_MS, 60000).
-define(DEFAULT_MAX_RESPONSE_BYTES, 33554432).
-define(MAX_REQUEST_BYTES, 33554432).
-define(MAX_BASE_URL_BYTES, 8192).
%% Leaves deterministic headroom inside the shared 64 KiB aggregate header
%% budget for the authentication scheme and adapter-owned metadata headers.
-define(MAX_API_KEY_BYTES, 32768).

-spec validate_options(map()) -> ok | {error, term()}.
validate_options(Config) when is_map(Config) ->
    case {base_target(Config), timeout(Config), max_response_bytes(Config),
          allow_private(Config), transport(Config)} of
        {{ok, _Base, _Scheme, _Host}, {ok, _Timeout}, {ok, _Max},
         {ok, _AllowPrivate}, {ok, _Transport}} -> ok;
        {{error, _} = Error, _, _, _, _} -> Error;
        {_, {error, _} = Error, _, _, _} -> Error;
        {_, _, {error, _} = Error, _, _} -> Error;
        {_, _, _, {error, _} = Error, _} -> Error;
        {_, _, _, _, {error, _} = Error} -> Error
    end;
validate_options(_Config) ->
    {error, invalid_model_http_config}.

%% @doc Require HTTPS for a credential-bearing model adapter. The generic
%% transport still supports HTTP for explicitly keyless local integrations;
%% native vendor adapters call this stricter boundary before resolving keys.
-spec validate_https_base_url(map()) ->
    ok | {error, invalid_model_https_base_url | invalid_model_base_url}.
validate_https_base_url(Config) when is_map(Config) ->
    case base_target(Config) of
        {ok, _Base, <<"https">>, _Host} -> ok;
        {ok, _Base, _Scheme, _Host} ->
            {error, invalid_model_https_base_url};
        {error, _} = Error -> Error
    end;
validate_https_base_url(_Config) ->
    {error, invalid_model_base_url}.

-spec request(map(), binary(), [{binary(), binary()}], map()) ->
    {ok, adk_model_http_transport:response()} | {error, term()}.
request(Config, Path, Headers, Payload) ->
    invoke(request, Config, Path, Headers, Payload, undefined).

-spec stream(map(), binary(), [{binary(), binary()}], map(),
             adk_model_http_transport:chunk_callback()) ->
    {ok, adk_model_http_transport:response()} | {error, term()}.
stream(Config, Path, Headers, Payload, Callback)
  when is_function(Callback, 1) ->
    invoke(stream, Config, Path, Headers, Payload, Callback);
stream(_Config, _Path, _Headers, _Payload, _Callback) ->
    {error, invalid_stream_callback}.

%% @doc Resolve a direct adapter key or its conventional environment value.
%% Error terms never contain credential material.
-spec resolve_api_key(map(), string()) ->
    {ok, binary()} | {error, missing_api_key | invalid_api_key}.
resolve_api_key(Config, EnvName) when is_map(Config), is_list(EnvName) ->
    case maps:find(api_key, Config) of
        {ok, Value} -> normalize_api_key(Value);
        error ->
            case os:getenv(EnvName) of
                false -> {error, missing_api_key};
                Value -> normalize_api_key(Value)
            end
    end.

%% @doc Resolve an environment credential only for the adapter's exact
%% official base URL. A custom HTTPS endpoint must carry an explicit key,
%% which keeps caller-controlled origins from receiving ambient credentials.
-spec resolve_bound_api_key(map(), string(), binary()) ->
    {ok, binary()} |
    {error, missing_api_key | invalid_api_key |
            custom_endpoint_requires_explicit_api_key}.
resolve_bound_api_key(Config, EnvName, OfficialBase)
  when is_map(Config), is_list(EnvName), is_binary(OfficialBase) ->
    case equivalent_base_url(maps:get(base_url, Config, undefined),
                             OfficialBase) of
        true -> resolve_api_key(Config, EnvName);
        false ->
            case maps:find(api_key, Config) of
                {ok, _Value} -> resolve_explicit_api_key(Config);
                error -> {error, custom_endpoint_requires_explicit_api_key}
            end
    end;
resolve_bound_api_key(_Config, _EnvName, _OfficialBase) ->
    {error, invalid_api_key}.

%% @doc Resolve only a key present in this request configuration. This is the
%% credential boundary for OpenAI-compatible endpoints, which have no single
%% official origin to which a process-wide environment key could be bound.
-spec resolve_explicit_api_key(map()) ->
    {ok, binary()} | {error, missing_api_key | invalid_api_key}.
resolve_explicit_api_key(Config) when is_map(Config) ->
    case maps:find(api_key, Config) of
        {ok, Value} -> normalize_api_key(Value);
        error -> {error, missing_api_key}
    end;
resolve_explicit_api_key(_Config) ->
    {error, invalid_api_key}.

-spec base_url_matches(map(), binary()) -> boolean().
base_url_matches(Config, Expected)
  when is_map(Config), is_binary(Expected) ->
    equivalent_base_url(maps:get(base_url, Config, undefined), Expected);
base_url_matches(_Config, _Expected) -> false.

invoke(Mode, Config, Path, Headers, Payload, Callback)
  when is_map(Config), is_binary(Path), is_list(Headers), is_map(Payload) ->
    case prepare_request(Config, Path, Headers, Payload) of
        {ok, {Transport, Handle}, Request} ->
            invoke_transport(Mode, Transport, Handle, Request, Callback);
        {error, _} = Error -> Error
    end;
invoke(_Mode, _Config, _Path, _Headers, _Payload, _Callback) ->
    {error, invalid_model_http_request}.

prepare_request(Config, Path, Headers, Payload) ->
    case adk_model_http_headers:validate(Headers) of
        ok -> prepare_request_with_headers(Config, Path, Headers, Payload);
        {error, _} = Error -> Error
    end.

prepare_request_with_headers(Config, Path, Headers, Payload) ->
    case {base_target(Config), timeout(Config), max_response_bytes(Config),
          allow_private(Config), transport(Config), encode_payload(Payload),
          normalize_path(Path)} of
        {{ok, Base, Scheme, Host}, {ok, Timeout}, {ok, MaxBytes},
         {ok, AllowPrivate}, {ok, Transport}, {ok, Body}, {ok, SafePath}} ->
            Url = join_url(Base, SafePath),
            Request = #{method => <<"POST">>, url => Url,
                        headers => Headers, body => Body,
                        timeout_ms => Timeout,
                        max_response_bytes => MaxBytes,
                        follow_redirects => false,
                        allowed_schemes => [Scheme],
                        allowed_hosts => [Host],
                        allow_private_hosts => AllowPrivate},
            {ok, Transport, Request};
        {{error, _} = Error, _, _, _, _, _, _} -> Error;
        {_, {error, _} = Error, _, _, _, _, _} -> Error;
        {_, _, {error, _} = Error, _, _, _, _} -> Error;
        {_, _, _, {error, _} = Error, _, _, _} -> Error;
        {_, _, _, _, {error, _} = Error, _, _} -> Error;
        {_, _, _, _, _, {error, _} = Error, _} -> Error;
        {_, _, _, _, _, _, {error, _} = Error} -> Error
    end.

invoke_transport(request, Module, Handle, Request, _Callback) ->
    try Module:request(Handle, Request) of
        {ok, Response} when is_map(Response) -> {ok, Response};
        {error, Reason} -> {error, sanitize_transport_error(Reason)};
        _ -> {error, invalid_transport_response}
    catch
        Class:_Reason -> {error, {model_transport_failed, Class}}
    end;
invoke_transport(stream, Module, Handle, Request, Callback) ->
    try Module:stream(Handle, Request, Callback) of
        {ok, Response} when is_map(Response) -> {ok, Response};
        {error, Reason} -> {error, sanitize_transport_error(Reason)};
        _ -> {error, invalid_transport_response}
    catch
        Class:_Reason -> {error, {model_transport_failed, Class}}
    end.

base_target(Config) ->
    case maps:get(base_url, Config, undefined) of
        Base when is_binary(Base), byte_size(Base) > 0,
                  byte_size(Base) =< ?MAX_BASE_URL_BYTES ->
            parse_base_target(Base);
        _ -> {error, invalid_model_base_url}
    end.

parse_base_target(Base) ->
    try uri_string:parse(Base) of
        #{scheme := Scheme0, host := Host0} = Uri
          when is_binary(Scheme0), is_binary(Host0), byte_size(Host0) > 0 ->
            Scheme = lower(Scheme0),
            Host = lower(Host0),
            case lists:member(Scheme, [<<"https">>, <<"http">>]) andalso
                 not maps:is_key(userinfo, Uri) andalso
                 not maps:is_key(query, Uri) andalso
                 not maps:is_key(fragment, Uri) andalso
                 valid_port(maps:get(port, Uri, default_port(Scheme))) of
                true -> {ok, trim_trailing_slash(Base), Scheme, Host};
                false -> {error, invalid_model_base_url}
            end;
        _ -> {error, invalid_model_base_url}
    catch
        _:_ -> {error, invalid_model_base_url}
    end.

equivalent_base_url(Left, Right)
  when is_binary(Left), is_binary(Right) ->
    case {normalized_base_url(Left), normalized_base_url(Right)} of
        {{ok, Normalized}, {ok, Normalized}} -> true;
        _ -> false
    end;
equivalent_base_url(_Left, _Right) -> false.

normalized_base_url(Base) ->
    try uri_string:parse(Base) of
        #{scheme := Scheme0, host := Host0} = Uri
          when is_binary(Scheme0), is_binary(Host0),
               byte_size(Host0) > 0 ->
            Scheme = lower(Scheme0),
            Port = maps:get(port, Uri, default_port(Scheme)),
            Path0 = maps:get(path, Uri, <<>>),
            Path = trim_trailing_slash(Path0),
            case not maps:is_key(userinfo, Uri) andalso
                 not maps:is_key(query, Uri) andalso
                 not maps:is_key(fragment, Uri) andalso
                 valid_port(Port) of
                true -> {ok, {Scheme, lower(Host0), Port, Path}};
                false -> error
            end;
        _ -> error
    catch
        _:_ -> error
    end.

normalize_path(Path) when byte_size(Path) > 0, byte_size(Path) =< 2048 ->
    case {binary:at(Path, 0), binary:match(Path, <<"?">>),
          binary:match(Path, <<"#">>), has_control(Path)} of
        {$/, nomatch, nomatch, false} -> {ok, Path};
        _ -> {error, invalid_model_request_path}
    end;
normalize_path(_Path) -> {error, invalid_model_request_path}.

timeout(Config) ->
    Value = maps:get(request_timeout, Config, ?DEFAULT_TIMEOUT_MS),
    case is_integer(Value) andalso Value > 0 andalso Value =< 3600000 of
        true -> {ok, Value};
        false -> {error, invalid_model_request_timeout}
    end.

max_response_bytes(Config) ->
    Value = maps:get(max_response_bytes, Config,
                     ?DEFAULT_MAX_RESPONSE_BYTES),
    case is_integer(Value) andalso Value > 0 andalso
         Value =< ?DEFAULT_MAX_RESPONSE_BYTES of
        true -> {ok, Value};
        false -> {error, invalid_model_response_limit}
    end.

allow_private(Config) ->
    case maps:get(allow_private_hosts, Config, false) of
        Value when is_boolean(Value) -> {ok, Value};
        _ -> {error, invalid_model_private_host_policy}
    end.

transport(Config) ->
    Value = maps:get(http_transport, Config,
                     {adk_model_gun_transport, default}),
    case Value of
        {Module, Handle} when is_atom(Module) ->
            case code:ensure_loaded(Module) of
                {module, Module} ->
                    case erlang:function_exported(Module, request, 2) andalso
                         erlang:function_exported(Module, stream, 3) of
                        true -> {ok, {Module, Handle}};
                        false -> {error, invalid_model_http_transport}
                    end;
                _ -> {error, model_http_transport_unavailable}
            end;
        _ -> {error, invalid_model_http_transport}
    end.

encode_payload(Payload) ->
    case adk_json:normalize(Payload) of
        {ok, Payload} ->
            try jsx:encode(Payload) of
                Body when byte_size(Body) =< ?MAX_REQUEST_BYTES ->
                    {ok, Body};
                _ -> {error, model_request_too_large}
            catch
                _:_ -> {error, invalid_model_request_json}
            end;
        {ok, _Coerced} -> {error, model_request_json_must_be_canonical};
        {error, _} -> {error, invalid_model_request_json}
    end.

normalize_api_key(Value) when is_binary(Value), byte_size(Value) > 0,
                              byte_size(Value) =< ?MAX_API_KEY_BYTES ->
    case has_control(Value) of
        false -> {ok, Value};
        true -> {error, invalid_api_key}
    end;
normalize_api_key(Value) when is_list(Value), Value =/= [] ->
    try normalize_api_key(unicode:characters_to_binary(Value))
    catch _:_ -> {error, invalid_api_key}
    end;
normalize_api_key(_Value) -> {error, invalid_api_key}.

sanitize_transport_error(Reason) when is_atom(Reason) -> Reason;
sanitize_transport_error({stream_callback_failed, Class})
  when is_atom(Class) -> {stream_callback_failed, Class};
sanitize_transport_error(_Reason) -> model_transport_error.

join_url(Base, Path) -> <<Base/binary, Path/binary>>.

trim_trailing_slash(Base) when byte_size(Base) > 1 ->
    case binary:last(Base) of
        $/ -> trim_trailing_slash(
                binary:part(Base, 0, byte_size(Base) - 1));
        _ -> Base
    end;
trim_trailing_slash(Base) -> Base.

default_port(<<"https">>) -> 443;
default_port(<<"http">>) -> 80;
default_port(_) -> invalid.

valid_port(Port) ->
    is_integer(Port) andalso Port > 0 andalso Port =< 65535.

has_control(Binary) ->
    lists:any(fun(Byte) -> Byte < 32 orelse Byte =:= 127 end,
              binary_to_list(Binary)).

lower(Binary) ->
    unicode:characters_to_binary(string:lowercase(Binary)).
