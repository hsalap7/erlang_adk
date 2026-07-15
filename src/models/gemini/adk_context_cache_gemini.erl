%% @doc Gemini GenerateContent explicit cached-content adapter.
%%
%% The adapter stores provider request prefixes, never model responses. It is
%% deliberately usable only with the stable `gemini-3.1-flash-lite' model.
%% The opaque binary returned from `create/2' is a local private descriptor;
%% callers must use `cached_content_name/2' immediately before a Gemini
%% request. Neither that descriptor nor Google's `cachedContents/*' name is
%% suitable for events, logs, diagnostics, or persisted configuration.
%%
%% Transport configuration is read from the `erlang_adk' application
%% environment key `gemini_context_cache'. The value is a strict map with
%% optional `base_url', `api_key', and `request_timeout_ms' keys. `api_key'
%% falls back to `GEMINI_API_KEY'. Validation errors never echo credentials.
%%
%% Google's current model page declares caching support for 3.1 Flash-Lite,
%% but the current caching guide does not publish an explicit-cache minimum
%% for this model. We therefore use a conservative 4096 estimated-token local
%% floor and still treat the service response as authoritative.
-module(adk_context_cache_gemini).

-behaviour(adk_context_cache_provider).

-export([capabilities/0, supports_model/1, minimum_prefix_tokens/1,
         validate_options/1,
         create/2, get/2, update/3, delete/2,
         cached_content_name/2]).

-define(MODEL, <<"gemini-3.1-flash-lite">>).
-define(MIN_PREFIX_TOKENS, 4096).
-define(DEFAULT_BASE_URL,
        <<"https://generativelanguage.googleapis.com">>).
-define(DEFAULT_TIMEOUT_MS, 5000).
-define(HANDLE_MAGIC, <<"adk-gemini-cached-content-v1">>).
-define(MAX_RESOURCE_NAME_BYTES, 2048).

-spec capabilities() -> map().
capabilities() ->
    #{context_cache => true,
      semantics => provider_request_prefix_cache,
      response_cache => false,
      models => [?MODEL],
      minimum_prefix_tokens => #{?MODEL => ?MIN_PREFIX_TOKENS},
      operations => [create, get, update_ttl, delete],
      resource_names => private,
      credentials => application_environment_or_os_environment}.

-spec supports_model(binary()) -> boolean().
supports_model(?MODEL) -> true;
supports_model(_) -> false.

-spec minimum_prefix_tokens(binary()) ->
    {ok, pos_integer()} | {error, unsupported_context_cache_model}.
minimum_prefix_tokens(?MODEL) -> {ok, ?MIN_PREFIX_TOKENS};
minimum_prefix_tokens(_) -> {error, unsupported_context_cache_model}.

%% @doc Validate transport options without returning the compiled secret.
-spec validate_options(map()) -> ok | {error, term()}.
validate_options(Options) ->
    case compile_options(Options) of
        {ok, _} -> ok;
        {error, _} = Error -> Error
    end.

-spec create(map(), map()) ->
    {ok, binary(), map()} | {error, term()}.
create(Prefix, Request) ->
    case {validate_create_request(Request), validate_prefix(Prefix),
          configured_options()} of
        {{ok, RequestInfo}, {ok, PrefixInfo}, {ok, Options}} ->
            create_checked(PrefixInfo, RequestInfo, Options);
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end.

-spec get(binary(), map()) -> {ok, map()} | {error, term()}.
get(Resource, Request) ->
    lifecycle_request(get, Resource, undefined, Request).

-spec update(binary(), pos_integer(), map()) ->
    {ok, map()} | {error, term()}.
update(Resource, TtlMs, Request) ->
    lifecycle_request(patch, Resource, TtlMs, Request).

-spec delete(binary(), map()) -> ok | {error, term()}.
delete(Resource, Request) ->
    case lifecycle_request(delete, Resource, undefined, Request) of
        ok -> ok;
        {error, {gemini_cache_http_status, 404}} -> ok;
        {error, _} = Error -> Error
    end.

%% @doc Resolve a registry-private descriptor for one immediate model call.
-spec cached_content_name(binary(), binary()) ->
    {ok, binary()} | {error, term()}.
cached_content_name(Resource, ExpectedModel) ->
    case unpack_resource(Resource) of
        {ok, ExpectedModel, Name} -> {ok, Name};
        {ok, _OtherModel, _Name} ->
            {error, context_cache_model_mismatch};
        {error, _} = Error -> Error
    end.

create_checked(Prefix, Request, Options) ->
    Model = maps:get(model, Request),
    Estimated = maps:get(estimated_tokens, Request),
    case {maps:get(model, Prefix) =:= Model,
          minimum_prefix_tokens(Model)} of
        {false, _} ->
            {error, context_cache_model_mismatch};
        {true, {ok, Minimum}} when Estimated < Minimum ->
            {error, {context_cache_prefix_below_model_minimum,
                     Estimated, Minimum}};
        {true, {ok, _Minimum}} ->
            Body = create_body(Prefix, Model, maps:get(ttl_ms, Request)),
            case http_json(post, <<"/v1beta/cachedContents">>, Body,
                           maps:get(deadline_ms, Request), Options) of
                {ok, Response} -> normalize_created(Response, Model);
                {error, _} = Error -> Error
            end;
        {true, {error, _} = Error} -> Error
    end.

lifecycle_request(Method, Resource, TtlMs, Request) ->
    case {unpack_resource(Resource),
          validate_lifecycle_request(Request),
          validate_lifecycle_ttl(Method, TtlMs),
          configured_options()} of
        {{ok, HandleModel, Name}, {ok, RequestInfo}, ok, {ok, Options}} ->
            ScopeModel = maps:get(model, RequestInfo),
            case HandleModel =:= ScopeModel of
                true ->
                    Path = <<"/v1beta/", Name/binary>>,
                    Body = case Method of
                        patch -> #{<<"ttl">> => duration(TtlMs)};
                        _ -> undefined
                    end,
                    case http_json(Method, Path, Body,
                                   maps:get(deadline_ms, RequestInfo),
                                   Options) of
                        {ok, _Response} when Method =:= delete -> ok;
                        {ok, Response} -> normalize_metadata(Response,
                                                             HandleModel);
                        {error, _} = Error -> Error
                    end;
                false -> {error, context_cache_model_mismatch}
            end;
        {{error, _} = Error, _, _, _} -> Error;
        {_, {error, _} = Error, _, _} -> Error;
        {_, _, {error, _} = Error, _} -> Error;
        {_, _, _, {error, _} = Error} -> Error
    end.

validate_lifecycle_ttl(patch, TtlMs)
  when is_integer(TtlMs), TtlMs > 0, TtlMs =< 86400000 -> ok;
validate_lifecycle_ttl(patch, _) ->
    {error, invalid_gemini_context_cache_ttl};
validate_lifecycle_ttl(_Method, undefined) -> ok;
validate_lifecycle_ttl(_Method, _) ->
    {error, invalid_gemini_context_cache_ttl}.

validate_create_request(Request) when is_map(Request) ->
    Expected = [<<"deadline_ms">>, <<"estimated_context_units">>,
                <<"schema_version">>, <<"scope">>, <<"ttl_ms">>],
    case lists:sort(maps:keys(Request)) =:= Expected of
        true ->
            validate_request_fields(
              Request, true,
              maps:get(<<"ttl_ms">>, Request),
              maps:get(<<"estimated_context_units">>, Request));
        false -> {error, invalid_gemini_context_cache_request}
    end;
validate_create_request(_) ->
    {error, invalid_gemini_context_cache_request}.

validate_lifecycle_request(Request) when is_map(Request) ->
    Expected = [<<"deadline_ms">>, <<"schema_version">>, <<"scope">>],
    case lists:sort(maps:keys(Request)) =:= Expected of
        true -> validate_request_fields(Request, false, undefined, undefined);
        false -> {error, invalid_gemini_context_cache_request}
    end;
validate_lifecycle_request(_) ->
    {error, invalid_gemini_context_cache_request}.

validate_request_fields(Request, IsCreate, TtlMs, Estimated) ->
    Schema = maps:get(<<"schema_version">>, Request),
    Deadline = maps:get(<<"deadline_ms">>, Request),
    Scope = maps:get(<<"scope">>, Request),
    case validate_scope(Scope) of
        {ok, Model} ->
            ValidCreate = not IsCreate orelse
                (is_integer(TtlMs) andalso TtlMs > 0
                 andalso TtlMs =< 86400000
                 andalso is_integer(Estimated) andalso Estimated >= 0),
            case Schema =:= adk_context_cache:version()
                 andalso is_integer(Deadline) andalso ValidCreate of
                true ->
                    Base = #{model => Model, deadline_ms => Deadline},
                    case IsCreate of
                        true -> {ok, Base#{ttl_ms => TtlMs,
                                          estimated_tokens => Estimated}};
                        false -> {ok, Base}
                    end;
                false -> {error, invalid_gemini_context_cache_request}
            end;
        {error, _} = Error -> Error
    end.

validate_scope(Scope) when is_map(Scope) ->
    Expected = [<<"app">>, <<"model">>, <<"policy">>, <<"user">>],
    case lists:sort(maps:keys(Scope)) =:= Expected of
        true ->
            Model = maps:get(<<"model">>, Scope),
            App = maps:get(<<"app">>, Scope),
            User = maps:get(<<"user">>, Scope),
            Policy = maps:get(<<"policy">>, Scope),
            case supports_model(Model) of
                false -> {error, unsupported_context_cache_model};
                true ->
                    case valid_identity(App) andalso valid_identity(User)
                         andalso is_map(Policy) of
                        true -> {ok, Model};
                        false ->
                            {error, invalid_gemini_context_cache_scope}
                    end
            end;
        false -> {error, invalid_gemini_context_cache_scope}
    end;
validate_scope(_) -> {error, invalid_gemini_context_cache_scope}.

validate_prefix(Prefix) when is_map(Prefix) ->
    Expected = [<<"history_prefix">>, <<"model">>,
                <<"system_instruction">>, <<"tools">>],
    case lists:sort(maps:keys(Prefix)) =:= Expected of
        false -> {error, invalid_gemini_context_cache_prefix};
        true ->
            Model = maps:get(<<"model">>, Prefix),
            History = maps:get(<<"history_prefix">>, Prefix),
            System = maps:get(<<"system_instruction">>, Prefix),
            Tools = maps:get(<<"tools">>, Prefix),
            case supports_model(Model) andalso is_list(History)
                 andalso lists:all(fun valid_content/1, History)
                 andalso valid_system_instruction(System)
                 andalso is_list(Tools)
                 andalso lists:all(fun json_map/1, Tools) of
                true ->
                    {ok, #{model => Model,
                           history => History,
                           system_instruction => System,
                           tools => Tools}};
                false -> {error, invalid_gemini_context_cache_prefix}
            end
    end;
validate_prefix(_) -> {error, invalid_gemini_context_cache_prefix}.

valid_content(Content) when is_map(Content) ->
    Keys = lists:sort(maps:keys(Content)),
    lists:member(Keys, [[<<"parts">>], [<<"parts">>, <<"role">>]])
    andalso is_list(maps:get(<<"parts">>, Content, invalid))
    andalso maps:get(<<"parts">>, Content, []) =/= []
    andalso json_map(Content);
valid_content(_) -> false.

valid_system_instruction(null) -> true;
valid_system_instruction(Instruction) when is_map(Instruction) ->
    maps:keys(Instruction) =:= [<<"parts">>]
    andalso is_list(maps:get(<<"parts">>, Instruction, invalid))
    andalso maps:get(<<"parts">>, Instruction, []) =/= []
    andalso json_map(Instruction);
valid_system_instruction(_) -> false.

create_body(Prefix, Model, TtlMs) ->
    Body0 = #{<<"model">> => <<"models/", Model/binary>>,
              <<"ttl">> => duration(TtlMs)},
    History = maps:get(history, Prefix),
    System = maps:get(system_instruction, Prefix),
    Tools = maps:get(tools, Prefix),
    Body1 = case History of
        [] -> Body0;
        _ -> Body0#{<<"contents">> => History}
    end,
    Body2 = case System of
        null -> Body1;
        _ -> Body1#{<<"systemInstruction">> => System}
    end,
    case Tools of
        [] -> Body2;
        _ -> Body2#{<<"tools">> => Tools}
    end.

normalize_created(Response, Model) when is_map(Response) ->
    case {maps:find(<<"name">>, Response),
          response_model(Response), normalize_metadata(Response, Model)} of
        {{ok, Name}, {ok, Model}, {ok, Metadata}}
          when is_binary(Name) ->
            case valid_resource_name(Name) of
                true -> {ok, pack_resource(Model, Name), Metadata};
                false -> {error, invalid_gemini_context_cache_response}
            end;
        _ -> {error, invalid_gemini_context_cache_response}
    end.

normalize_metadata(Response, ExpectedModel) when is_map(Response) ->
    case {response_model(Response),
          maps:find(<<"expireTime">>, Response),
          maps:find(<<"usageMetadata">>, Response)} of
        {{ok, ExpectedModel}, {ok, ExpireTime},
         {ok, #{<<"totalTokenCount">> := Tokens}}}
          when is_binary(ExpireTime), is_integer(Tokens), Tokens >= 0 ->
            {ok, #{<<"model">> => ExpectedModel,
                   <<"expire_time">> => ExpireTime,
                   <<"cached_token_count">> => Tokens}};
        _ -> {error, invalid_gemini_context_cache_response}
    end.

response_model(#{<<"model">> := <<"models/", Model/binary>>}) ->
    {ok, Model};
response_model(_) -> error.

pack_resource(Model, Name) ->
    ModelBytes = byte_size(Model),
    NameBytes = byte_size(Name),
    <<?HANDLE_MAGIC/binary, ModelBytes:16/unsigned-big,
      NameBytes:16/unsigned-big, Model/binary, Name/binary>>.

unpack_resource(<<"adk-gemini-cached-content-v1",
                  ModelBytes:16/unsigned-big,
                  NameBytes:16/unsigned-big, Rest/binary>>)
  when ModelBytes > 0, NameBytes > 0,
       NameBytes =< ?MAX_RESOURCE_NAME_BYTES,
       byte_size(Rest) =:= ModelBytes + NameBytes ->
    <<Model:ModelBytes/binary, Name:NameBytes/binary>> = Rest,
    case supports_model(Model) andalso valid_resource_name(Name) of
        true -> {ok, Model, Name};
        false -> {error, invalid_gemini_context_cache_resource}
    end;
unpack_resource(_) ->
    {error, invalid_gemini_context_cache_resource}.

valid_resource_name(<<"cachedContents/", Id/binary>>) ->
    byte_size(Id) > 0 andalso byte_size(Id) =< 512
    andalso lists:all(fun valid_resource_char/1, binary_to_list(Id));
valid_resource_name(_) -> false.

valid_resource_char(Char) when Char >= $a, Char =< $z -> true;
valid_resource_char(Char) when Char >= $A, Char =< $Z -> true;
valid_resource_char(Char) when Char >= $0, Char =< $9 -> true;
valid_resource_char($-) -> true;
valid_resource_char($_) -> true;
valid_resource_char(_) -> false.

configured_options() ->
    Value = case application:get_env(erlang_adk, gemini_context_cache) of
        {ok, Options} -> Options;
        undefined -> #{}
    end,
    compile_options(Value).

compile_options(Options) when is_map(Options) ->
    Unknown = maps:without([base_url, api_key, request_timeout_ms], Options),
    case map_size(Unknown) of
        0 -> compile_known_options(Options);
        _ ->
            {error, {invalid_gemini_context_cache_options,
                     {unknown_keys, lists:sort(maps:keys(Unknown))}}}
    end;
compile_options(_) ->
    {error, {invalid_gemini_context_cache_options, expected_map}}.

compile_known_options(Options) ->
    BaseUrl = maps:get(base_url, Options, ?DEFAULT_BASE_URL),
    Timeout = maps:get(request_timeout_ms, Options, ?DEFAULT_TIMEOUT_MS),
    case {validate_base_url(BaseUrl), validate_api_key(Options),
          is_integer(Timeout) andalso Timeout > 0 andalso Timeout =< 300000} of
        {{ok, NormalizedBase}, {ok, ApiKey}, true} ->
            {ok, #{base_url => NormalizedBase, api_key => ApiKey,
                   request_timeout_ms => Timeout}};
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, false} ->
            {error, {invalid_gemini_context_cache_options,
                     request_timeout_ms}}
    end.

validate_api_key(Options) ->
    case maps:find(api_key, Options) of
        {ok, Key} when is_binary(Key), byte_size(Key) > 0 -> {ok, Key};
        {ok, Key} when is_list(Key), Key =/= [] ->
            try unicode:characters_to_binary(Key) of
                Binary when byte_size(Binary) > 0 -> {ok, Binary};
                _ -> {error, {invalid_gemini_context_cache_options,
                              api_key_redacted}}
            catch _:_ ->
                {error, {invalid_gemini_context_cache_options,
                         api_key_redacted}}
            end;
        {ok, _} ->
            {error, {invalid_gemini_context_cache_options,
                     api_key_redacted}};
        error ->
            case os:getenv("GEMINI_API_KEY") of
                false -> {error, missing_api_key};
                [] -> {error, missing_api_key};
                Value -> {ok, unicode:characters_to_binary(Value)}
            end
    end.

validate_base_url(BaseUrl) when is_binary(BaseUrl), byte_size(BaseUrl) > 0 ->
    try uri_string:parse(BaseUrl) of
        #{scheme := Scheme, host := Host} = Uri
          when (Scheme =:= <<"http">> orelse Scheme =:= <<"https">>),
               is_binary(Host), byte_size(Host) > 0 ->
            case maps:is_key(userinfo, Uri) orelse maps:is_key(query, Uri)
                 orelse maps:is_key(fragment, Uri) of
                true ->
                    {error, {invalid_gemini_context_cache_options, base_url}};
                false -> {ok, trim_trailing_slash(BaseUrl)}
            end;
        _ -> {error, {invalid_gemini_context_cache_options, base_url}}
    catch _:_ ->
        {error, {invalid_gemini_context_cache_options, base_url}}
    end;
validate_base_url(_) ->
    {error, {invalid_gemini_context_cache_options, base_url}}.

trim_trailing_slash(Value) when byte_size(Value) > 0 ->
    case binary:last(Value) of
        $/ ->
            trim_trailing_slash(
              binary:part(Value, 0, byte_size(Value) - 1));
        _ -> Value
    end;
trim_trailing_slash(Value) -> Value.

http_json(Method, Path, Body, Deadline, Options) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    Timeout = erlang:min(Remaining, maps:get(request_timeout_ms, Options)),
    case Timeout > 0 of
        false -> {error, provider_deadline_exceeded};
        true ->
            BaseUrl = maps:get(base_url, Options),
            Url = binary_to_list(<<BaseUrl/binary, Path/binary>>),
            Headers = [{"Content-Type", "application/json"},
                       {"x-goog-api-key",
                        binary_to_list(maps:get(api_key, Options))}],
            Request = case Method of
                get -> {Url, Headers};
                delete -> {Url, Headers};
                _ -> {Url, Headers, "application/json", jsx:encode(Body)}
            end,
            case ssl_options(BaseUrl) of
                {ok, SslOptions} ->
                    HttpOptions = [{timeout, Timeout}, {ssl, SslOptions}],
                    normalize_http_result(
                      httpc:request(Method, Request, HttpOptions,
                                    [{body_format, binary}]), Method);
                {error, _} = Error -> Error
            end
    end.

normalize_http_result(
  {ok, {{_Version, Status, _Phrase}, _Headers, Body}}, Method)
  when Status >= 200, Status < 300 ->
    case {Method, Body} of
        {delete, _} -> {ok, #{}};
        {_, <<>>} -> {error, invalid_gemini_context_cache_response};
        _ ->
            try jsx:decode(Body, [return_maps]) of
                Map when is_map(Map) -> {ok, Map};
                _ -> {error, invalid_gemini_context_cache_response}
            catch _:_ -> {error, invalid_gemini_context_cache_response}
            end
    end;
normalize_http_result(
  {ok, {{_Version, 429, _Phrase}, _Headers, _Body}}, _Method) ->
    {error, gemini_cache_rate_limited};
normalize_http_result(
  {ok, {{_Version, Status, _Phrase}, _Headers, _Body}}, _Method) ->
    %% Provider response bodies are intentionally excluded from returned
    %% errors because they can echo request fragments or resource names.
    {error, {gemini_cache_http_status, Status}};
normalize_http_result({error, _Reason}, _Method) ->
    {error, gemini_cache_transport_error}.

ssl_options(<<"http://", _/binary>>) -> {ok, []};
ssl_options(BaseUrl) ->
    case uri_string:parse(BaseUrl) of
        #{scheme := <<"https">>, host := Host} ->
            tls_options(binary_to_list(Host));
        _ -> {error, invalid_gemini_context_cache_base_url}
    end.

tls_options(Host) ->
    try public_key:cacerts_get() of
        Certs ->
            MatchFun = public_key:pkix_verify_hostname_match_fun(https),
            {ok, [{verify, verify_peer}, {cacerts, Certs},
                  {server_name_indication, Host},
                  {customize_hostname_check, [{match_fun, MatchFun}]}]}
    catch _:_ -> {error, gemini_cache_ca_certificates_unavailable}
    end.

duration(TtlMs) ->
    Seconds = TtlMs div 1000,
    Remainder = TtlMs rem 1000,
    case Remainder of
        0 -> <<(integer_to_binary(Seconds))/binary, "s">>;
        _ -> <<(integer_to_binary(Seconds))/binary, ".",
               (pad_milliseconds(Remainder))/binary, "s">>
    end.

pad_milliseconds(Value) when Value < 10 ->
    <<"00", (integer_to_binary(Value))/binary>>;
pad_milliseconds(Value) when Value < 100 ->
    <<"0", (integer_to_binary(Value))/binary>>;
pad_milliseconds(Value) -> integer_to_binary(Value).

valid_identity(Value) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< 256
    andalso valid_utf8(Value);
valid_identity(_) -> false.

json_map(Value) when is_map(Value) -> json_safe(Value);
json_map(_) -> false.

json_safe(Value) when is_binary(Value); is_integer(Value); is_float(Value) ->
    true;
json_safe(true) -> true;
json_safe(false) -> true;
json_safe(null) -> true;
json_safe(Value) when is_list(Value) -> lists:all(fun json_safe/1, Value);
json_safe(Value) when is_map(Value) ->
    lists:all(fun({Key, Item}) ->
                  is_binary(Key) andalso json_safe(Item)
              end, maps:to_list(Value));
json_safe(_) -> false.

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.
