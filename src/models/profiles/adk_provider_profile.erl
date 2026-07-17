%% @doc Validation and secret-free projection for operator-owned model profiles.
%%
%% A profile binds a public binary identifier to pre-existing adapter modules,
%% an HTTPS endpoint/preset, model aliases, and a credential source. Callers
%% can select only the identifier and an alias: they cannot choose modules,
%% endpoint URLs, headers, environment names, concrete model identifiers, or
%% operator-owned request authority/privacy defaults.
-module(adk_provider_profile).

-export([validate/2, normalize/2, resolve_model/2,
         request_config/2, live_config/2]).

-define(MAX_PROFILE_BYTES, 262144).
-define(MAX_PROFILE_ID_BYTES, 128).
-define(MAX_MODELS, 64).
-define(MAX_MODEL_ALIAS_BYTES, 128).
-define(MAX_MODEL_ID_BYTES, 512).
-define(MAX_HOST_BYTES, 253).
-define(MAX_PATH_BYTES, 2048).
-define(MAX_REQUEST_OPTIONS_BYTES, 16384).
-define(MAX_LOCKED_HEADER_BYTES, 1024).
-define(MAX_ANTHROPIC_VERSION_BYTES, 256).

-type profile_id() :: binary().
-type endpoint() :: gemini | openai | anthropic | local |
                    #{scheme := https, host := binary(),
                      port := pos_integer(), base_path := binary()}.
-type normalized_profile() :: map().
-export_type([profile_id/0, endpoint/0, normalized_profile/0]).

-spec validate(term(), term()) -> ok | {error, term()}.
validate(ProfileId, Profile) ->
    case normalize(ProfileId, Profile) of
        {ok, _SafeProfile} -> ok;
        {error, _} = Error -> Error
    end.

%% @doc Return the operator profile without credential material. A literal
%% source is represented only as `#{source => literal}'.
-spec normalize(term(), term()) ->
    {ok, normalized_profile()} | {error, term()}.
normalize(ProfileId, Profile)
  when is_binary(ProfileId), is_map(Profile) ->
    case valid_profile_id(ProfileId) andalso
         bounded_term(Profile, ?MAX_PROFILE_BYTES) of
        false -> {error, invalid_provider_profile};
        true ->
            case normalize_profile(ProfileId, Profile) of
                {ok, Normalized} ->
                    {ok, Normalized#{profile_snapshot =>
                                         adk_provider_credential:
                                           snapshot_token(
                                             ProfileId, Profile)}};
                {error, _} = Error -> Error
            end
    end;
normalize(_ProfileId, _Profile) ->
    {error, invalid_provider_profile}.

-spec resolve_model(normalized_profile(), term()) ->
    {ok, map()} | {error, term()}.
resolve_model(#{models := Models, capabilities := ProfileCapabilities}, Alias)
  when is_map(Models), is_binary(Alias) ->
    case maps:find(Alias, Models) of
        {ok, #{id := ModelId, capabilities := ModelCapabilities}} ->
            case adk_provider_capabilities:merge(
                   ProfileCapabilities, ModelCapabilities) of
                {ok, Capabilities} ->
                    {ok, #{alias => Alias, id => ModelId,
                           capabilities => Capabilities}};
                {error, _} ->
                    {error, invalid_provider_capabilities}
            end;
        error ->
            {error, unknown_provider_model_alias}
    end;
resolve_model(_Profile, _Alias) ->
    {error, invalid_provider_model_alias}.

-spec request_config(normalized_profile(), term()) ->
    {ok, map()} | {error, term()}.
request_config(Profile, Alias) ->
    adapter_config(request, request_adapter, Profile, Alias).

-spec live_config(normalized_profile(), term()) ->
    {ok, map()} | {error, term()}.
live_config(Profile, Alias) ->
    adapter_config(live, live_adapter, Profile, Alias).

normalize_profile(ProfileId, Profile) ->
    Allowed = [request_adapter, live_adapter, endpoint, models,
               credential, capabilities, request_options],
    case lists:sort(maps:keys(Profile) -- Allowed) of
        [] -> normalize_profile_fields(ProfileId, Profile);
        Unknown -> {error, {unknown_provider_profile_options, Unknown}}
    end.

normalize_profile_fields(ProfileId, Profile) ->
    RequestAdapter = maps:get(request_adapter, Profile, undefined),
    LiveAdapter = maps:get(live_adapter, Profile, undefined),
    case {normalize_request_adapter(RequestAdapter),
          normalize_live_adapter(LiveAdapter),
          normalize_endpoint(maps:get(endpoint, Profile, undefined)),
          normalize_models(maps:get(models, Profile, undefined)),
          normalize_credential(maps:get(credential, Profile, none)),
          normalize_request_options(
            RequestAdapter, maps:get(request_options, Profile, #{})),
          adk_provider_capabilities:normalize(
            maps:get(capabilities, Profile, #{}))} of
        {{ok, undefined}, {ok, undefined}, _, _, _, _, _} ->
            {error, missing_provider_adapter};
        {{ok, CheckedRequest}, {ok, CheckedLive},
         {ok, Endpoint}, {ok, Models}, {ok, Credential},
         {ok, RequestOptions}, {ok, Capabilities}} ->
            case request_endpoint_allowed(CheckedRequest, Endpoint) of
                false -> {error, provider_request_endpoint_mismatch};
                true ->
                    Base = #{id => ProfileId,
                             endpoint => Endpoint,
                             models => Models,
                             credential => Credential,
                             request_options => RequestOptions,
                             capabilities => Capabilities},
                    WithRequest = put_optional(
                                    request_adapter, CheckedRequest, Base),
                    {ok, put_optional(
                           live_adapter, CheckedLive, WithRequest)}
            end;
        {{error, Reason}, _, _, _, _, _, _} -> {error, Reason};
        {_, {error, Reason}, _, _, _, _, _} -> {error, Reason};
        {_, _, {error, Reason}, _, _, _, _} -> {error, Reason};
        {_, _, _, {error, Reason}, _, _, _} -> {error, Reason};
        {_, _, _, _, {error, Reason}, _, _} -> {error, Reason};
        {_, _, _, _, _, {error, Reason}, _} -> {error, Reason};
        {_, _, _, _, _, _, {error, Reason}} -> {error, Reason}
    end.

normalize_request_adapter(undefined) -> {ok, undefined};
normalize_request_adapter(Adapter) when is_atom(Adapter), Adapter =/= undefined ->
    case code:ensure_loaded(Adapter) of
        {module, Adapter} ->
            case erlang:function_exported(Adapter, generate, 3) andalso
                 erlang:function_exported(Adapter, stream, 4) of
                true -> {ok, Adapter};
                false -> {error, invalid_request_adapter}
            end;
        _ -> {error, request_adapter_unavailable}
    end;
normalize_request_adapter(_Adapter) -> {error, invalid_request_adapter}.

normalize_live_adapter(undefined) -> {ok, undefined};
normalize_live_adapter(Adapter) when is_atom(Adapter), Adapter =/= undefined ->
    case code:ensure_loaded(Adapter) of
        {module, Adapter} ->
            Required = [{capabilities, 0}, {validate_config, 1},
                        {setup_frame, 1}, {encode_client, 2},
                        {decode_server, 2}],
            case lists:all(
                   fun({Function, Arity}) ->
                           erlang:function_exported(Adapter, Function, Arity)
                   end, Required) of
                true -> {ok, Adapter};
                false -> {error, invalid_live_adapter}
            end;
        _ -> {error, live_adapter_unavailable}
    end;
normalize_live_adapter(_Adapter) -> {error, invalid_live_adapter}.

request_endpoint_allowed(undefined, _Endpoint) -> true;
request_endpoint_allowed(adk_llm_openai, openai) -> true;
request_endpoint_allowed(adk_llm_openai, Endpoint) when is_map(Endpoint) ->
    true;
request_endpoint_allowed(adk_llm_anthropic, anthropic) -> true;
request_endpoint_allowed(adk_llm_anthropic, Endpoint) when is_map(Endpoint) ->
    true;
request_endpoint_allowed(adk_llm_gemini, gemini) -> true;
request_endpoint_allowed(adk_llm_gemini, Endpoint) when is_map(Endpoint) ->
    true;
request_endpoint_allowed(adk_llm_compatible, Endpoint)
  when is_map(Endpoint) -> true;
request_endpoint_allowed(Adapter, _Endpoint)
  when Adapter =:= adk_llm_openai;
       Adapter =:= adk_llm_anthropic;
       Adapter =:= adk_llm_gemini;
       Adapter =:= adk_llm_compatible -> false;
request_endpoint_allowed(_CustomAdapter, _Endpoint) -> true.

normalize_endpoint(Endpoint)
  when Endpoint =:= gemini; Endpoint =:= openai;
       Endpoint =:= anthropic; Endpoint =:= local ->
    {ok, Endpoint};
normalize_endpoint(Endpoint) when is_map(Endpoint) ->
    Allowed = [scheme, host, port, base_path],
    case lists:sort(maps:keys(Endpoint)) =:= lists:sort(Allowed) of
        true -> normalize_custom_endpoint(Endpoint);
        false -> {error, invalid_provider_endpoint}
    end;
normalize_endpoint(_Endpoint) ->
    {error, invalid_provider_endpoint}.

normalize_custom_endpoint(#{scheme := https, host := Host,
                            port := Port, base_path := Path})
  when is_binary(Host), is_integer(Port), Port > 0, Port =< 65535,
       is_binary(Path) ->
    case valid_host(Host) andalso valid_base_path(Path) of
        true -> {ok, #{scheme => https, host => Host,
                       port => Port, base_path => Path}};
        false -> {error, invalid_provider_endpoint}
    end;
normalize_custom_endpoint(_Endpoint) ->
    {error, invalid_provider_endpoint}.

normalize_models(Models)
  when is_map(Models), map_size(Models) > 0,
       map_size(Models) =< ?MAX_MODELS ->
    normalize_model_pairs(maps:to_list(Models), #{});
normalize_models(_Models) ->
    {error, invalid_provider_models}.

normalize_model_pairs([], Acc) -> {ok, Acc};
normalize_model_pairs([{Alias, Value} | Rest], Acc) ->
    case valid_model_alias(Alias) of
        false -> {error, invalid_provider_model_alias};
        true ->
            case normalize_model(Value) of
                {ok, Model} ->
                    normalize_model_pairs(Rest, maps:put(Alias, Model, Acc));
                {error, _} = Error -> Error
            end
    end.

normalize_model(ModelId) when is_binary(ModelId) ->
    normalize_model(#{id => ModelId});
normalize_model(Model) when is_map(Model) ->
    Allowed = [id, capabilities],
    case lists:sort(maps:keys(Model) -- Allowed) of
        [] ->
            ModelId = maps:get(id, Model, undefined),
            case {valid_model_id(ModelId),
                  adk_provider_capabilities:normalize(
                    maps:get(capabilities, Model, #{}))} of
                {true, {ok, Capabilities}} ->
                    {ok, #{id => ModelId, capabilities => Capabilities}};
                {false, _} -> {error, invalid_provider_model_id};
                {_, {error, _}} ->
                    {error, invalid_provider_model_capabilities}
            end;
        _ -> {error, invalid_provider_model}
    end;
normalize_model(_Model) ->
    {error, invalid_provider_model}.

normalize_credential(Source) ->
    case adk_provider_credential:describe(Source) of
        {ok, Descriptor} -> {ok, Descriptor};
        {error, _} -> {error, invalid_provider_credential_source}
    end.

normalize_request_options(Adapter, Options)
  when is_map(Options) ->
    case bounded_term(Options, ?MAX_REQUEST_OPTIONS_BYTES) of
        false -> {error, invalid_provider_request_options};
        true -> normalize_adapter_request_options(Adapter, Options)
    end;
normalize_request_options(_Adapter, _Options) ->
    {error, invalid_provider_request_options}.

normalize_adapter_request_options(_Adapter, Options)
  when map_size(Options) =:= 0 ->
    {ok, #{}};
normalize_adapter_request_options(adk_llm_openai, Options) ->
    case lists:sort(maps:keys(Options)) --
         [organization, project, store] of
        [] ->
            case valid_locked_header(
                   maps:get(organization, Options, undefined), optional)
                 andalso valid_locked_header(
                           maps:get(project, Options, undefined), optional)
                 andalso valid_optional_boolean(store, Options) of
                true -> {ok, Options};
                false -> {error, invalid_provider_request_options}
            end;
        _ -> {error, invalid_provider_request_options}
    end;
normalize_adapter_request_options(adk_llm_anthropic, Options) ->
    case maps:keys(Options) of
        [anthropic_version] ->
            case valid_locked_text(
                   maps:get(anthropic_version, Options),
                   ?MAX_ANTHROPIC_VERSION_BYTES) of
                true -> {ok, Options};
                false -> {error, invalid_provider_request_options}
            end;
        _ -> {error, invalid_provider_request_options}
    end;
normalize_adapter_request_options(adk_llm_compatible, Options) ->
    case lists:sort(maps:keys(Options) --
                    [auth_scheme, response_format]) of
        [] ->
            Scheme = maps:get(auth_scheme, Options, undefined),
            Format = maps:get(response_format, Options, auto),
            case (Scheme =:= bearer orelse Scheme =:= x_api_key orelse
                  Scheme =:= none) andalso
                 lists:member(Format,
                              [auto, text, json_object, json_schema,
                               unsupported]) of
                true -> {ok, Options};
                false -> {error, invalid_provider_request_options}
            end;
        _ -> {error, invalid_provider_request_options}
    end;
normalize_adapter_request_options(_Adapter, _Options) ->
    {error, invalid_provider_request_options}.

valid_locked_header(undefined, optional) -> true;
valid_locked_header(Value, optional) ->
    valid_locked_text(Value, ?MAX_LOCKED_HEADER_BYTES).

valid_locked_text(Value, Maximum)
  when is_binary(Value), byte_size(Value) > 0,
       byte_size(Value) =< Maximum ->
    not contains_control(Value);
valid_locked_text(_Value, _Maximum) -> false.

valid_optional_boolean(Key, Options) ->
    case maps:find(Key, Options) of
        error -> true;
        {ok, Value} -> is_boolean(Value)
    end.

adapter_config(Mode, AdapterKey,
               #{id := ProfileId, endpoint := Endpoint,
                 credential := Credential,
                 profile_snapshot := Snapshot} = Profile, Alias) ->
    case {maps:find(AdapterKey, Profile), resolve_model(Profile, Alias)} of
        {{ok, Adapter}, {ok, Model}} ->
            Resolved = #{kind => profile,
                         mode => Mode,
                         profile => ProfileId,
                         adapter => Adapter,
                         endpoint => Endpoint,
                         model_alias => maps:get(alias, Model),
                         model => maps:get(id, Model),
                         credential => Credential,
                         profile_snapshot => Snapshot,
                         capabilities => maps:get(capabilities, Model)},
            case Mode of
                request ->
                    {ok, Resolved#{request_options =>
                                      maps:get(request_options,
                                               Profile, #{})}};
                live -> {ok, Resolved}
            end;
        {error, _} ->
            {error, {provider_profile_capability_unavailable, Mode}};
        {_, {error, _} = Error} -> Error
    end;
adapter_config(_Mode, _AdapterKey, _Profile, _Alias) ->
    {error, invalid_provider_profile}.

put_optional(_Key, undefined, Map) -> Map;
put_optional(Key, Value, Map) -> maps:put(Key, Value, Map).

valid_profile_id(Value) ->
    valid_text(Value, ?MAX_PROFILE_ID_BYTES) andalso
    valid_identifier(Value).

valid_model_alias(Value) ->
    valid_text(Value, ?MAX_MODEL_ALIAS_BYTES) andalso
    valid_identifier(Value).

valid_model_id(Value) ->
    valid_text(Value, ?MAX_MODEL_ID_BYTES) andalso
    not contains_control(Value).

valid_identifier(Value) ->
    lists:all(
      fun(Char) ->
              (Char >= $a andalso Char =< $z) orelse
              (Char >= $A andalso Char =< $Z) orelse
              (Char >= $0 andalso Char =< $9) orelse
              lists:member(Char, "._-")
      end, binary_to_list(Value)).

valid_host(Host) ->
    valid_text(Host, ?MAX_HOST_BYTES) andalso
    lists:all(
      fun(Char) ->
              (Char >= $a andalso Char =< $z) orelse
              (Char >= $A andalso Char =< $Z) orelse
              (Char >= $0 andalso Char =< $9) orelse
              lists:member(Char, ".-:[]")
      end, binary_to_list(Host)).

valid_base_path(Path) ->
    valid_text(Path, ?MAX_PATH_BYTES) andalso
    binary:at(Path, 0) =:= $/ andalso
    binary:match(Path, <<"?">>) =:= nomatch andalso
    binary:match(Path, <<"#">>) =:= nomatch andalso
    not lists:member(<<"..">>, binary:split(Path, <<"/">>, [global])) andalso
    not contains_control(Path).

contains_control(Value) ->
    lists:any(fun(Char) -> Char < 32 orelse Char =:= 127 end,
              binary_to_list(Value)).

valid_text(Value, Maximum) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< Maximum andalso
    try
        case unicode:characters_to_binary(Value, utf8, utf8) of
            Value -> true;
            _ -> false
        end
    catch _:_ -> false
    end;
valid_text(_Value, _Maximum) -> false.

bounded_term(Term, Maximum) ->
    try erlang:external_size(Term) =< Maximum
    catch _:_ -> false
    end.
