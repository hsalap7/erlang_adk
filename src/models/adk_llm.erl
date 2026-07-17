-module(adk_llm).

-type config() :: map().
-type memory() :: list(map()).
-type tools() :: list(module() | map()).
-type provider_outcome() :: {ok, binary() | string() |
                                  adk_content:content()}
                          | {tool_calls, list()}
                          | streamed.
-type provider_result() ::
    {provider_result,
     #{version := 1,
       provider := binary(),
       type := binary(),
       outcome := provider_outcome(),
       metadata := map()}}.

-export_type([config/0, memory/0, tools/0,
              provider_outcome/0, provider_result/0]).

-callback generate(Config :: config(), Memory :: memory(), Tools :: tools()) ->
    {ok, binary() | string() | adk_content:content()}
    | {tool_calls, list()} | provider_result() | {error, term()}.

-callback stream(Config :: config(), Memory :: memory(), Tools :: tools(), Callback :: fun((binary()) -> ok)) ->
    ok | {tool_calls, list()} | provider_result() | {error, term()}.

-callback stream_content(Config :: config(), Memory :: memory(),
                         Tools :: tools(),
                         Callback :: fun((adk_content:content()) -> ok)) ->
    ok | {tool_calls, list()} | provider_result() | {error, term()}.

%% Providers may expose these callbacks without forcing older/custom providers
%% to change.  Capabilities describe this adapter's implemented behavior, not
%% every feature the remote model might support.
-callback capabilities() -> map().
-callback capabilities(Config :: config()) -> map().
-callback validate_config(Config :: config()) -> ok | {error, term()}.
-optional_callbacks([stream_content/4, capabilities/0, capabilities/1,
                     validate_config/1]).

-export([generate/3, stream/4, stream_content/4,
         capabilities/1, validate_config/1]).

%% @doc Dispatch the call to the specified provider.
generate(Config, Memory, Tools) ->
    dispatch(Config, generate, [Memory, Tools]).

%% @doc Dispatch the streaming call to the specified provider.
stream(Config, Memory, Tools, Callback) ->
    dispatch(Config, stream, [Memory, Tools, Callback]).

%% @doc Dispatch the optional canonical content-delta stream. Providers which
%% implement text streaming only fail explicitly instead of coercing maps to
%% text or silently dropping parts.
stream_content(Config, Memory, Tools, Callback) ->
    dispatch_optional(Config, stream_content,
                      [Memory, Tools, Callback], content_streaming).

%% @doc Return normalized adapter capabilities. Unknown custom providers remain
%% usable and conservatively report only the two required behavior callbacks.
-spec capabilities(config() | module()) -> {ok, map()} | {error, term()}.
capabilities(Provider) when is_atom(Provider) ->
    provider_capabilities(Provider);
capabilities(Config) when is_map(Config) ->
    case provider_description(Config) of
        {ok, #{adapter := Provider, kind := legacy}} ->
            provider_capabilities(Provider, Config);
        {ok, #{adapter := Provider, kind := profile,
               capabilities := ProfileCapabilities} = Description} ->
            case profile_capability_config(Description) of
                {ok, AdapterConfig} ->
                    case provider_capabilities(Provider, AdapterConfig) of
                        {ok, AdapterCapabilities} ->
                            adk_provider_capabilities:constrain(
                              AdapterCapabilities, ProfileCapabilities);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
capabilities(Value) ->
    {error, {invalid_llm_config, Value}}.

%% @doc Validate the provider reference and invoke its optional validator.
-spec validate_config(config()) -> ok | {error, term()}.
validate_config(Config) when is_map(Config) ->
    case runtime_config(Config) of
        {ok, Provider, ResolvedConfig} ->
            validate_provider_config(Provider, ResolvedConfig);
        {error, _} = Error -> Error
    end;
validate_config(Value) ->
    {error, {invalid_llm_config, Value}}.

dispatch(Config, Function, Args) ->
    case runtime_config(Config) of
        {ok, Provider, ResolvedConfig} ->
            case validate_provider_config(Provider, ResolvedConfig) of
                ok -> invoke_provider(
                        Provider, Function, [ResolvedConfig | Args]);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

dispatch_optional(Config, Function, Args, Capability) ->
    case runtime_config(Config) of
        {ok, Provider, ResolvedConfig} ->
            case validate_provider_config(Provider, ResolvedConfig) of
                {error, _} = Error -> Error;
                ok ->
                    case erlang:function_exported(
                           Provider, Function, length(Args) + 1) of
                        true ->
                            invoke_provider(
                              Provider, Function,
                              [ResolvedConfig | Args]);
                        false ->
                            {error,
                             {unsupported_provider_capability, Capability}}
                    end
            end;
        {error, _} = Error -> Error
    end.

invoke_provider(Provider, Function, Args) ->
    try apply(Provider, Function, Args) of
        {error, Reason} ->
            {error, provider_error(Function, Reason)};
        Result -> Result
    catch
        Class:Reason ->
            {error, adk_failure:exception(
                      llm_provider, Function, Class, Reason)}
    end.

validate_provider_config(Provider, Config) ->
    case erlang:function_exported(Provider, validate_config, 1) of
        true ->
            try Provider:validate_config(Config) of
                ok -> ok;
                {error, _} = Error -> Error;
                Other -> {error, {invalid_provider_validation, Other}}
            catch
                Class:Reason ->
                    {error, adk_failure:exception(
                              llm_provider, validate_config, Class, Reason)}
            end;
        false -> ok
    end.

runtime_config(Config) ->
    case provider_description(Config) of
        {ok, #{kind := legacy, adapter := Provider}} ->
            {ok, Provider, Config};
        {ok, #{kind := profile, adapter := Provider} = Description} ->
            case materialize_profile_config(Description) of
                {ok, ResolvedConfig} ->
                    {ok, Provider, ResolvedConfig};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

provider_description(Config) ->
    case maps:find(provider, Config) of
        {ok, Provider} when is_atom(Provider) ->
            case provider(Config) of
                {ok, Provider} ->
                    {ok, #{kind => legacy, adapter => Provider}};
                {error, _} = Error -> Error
            end;
        {ok, ProfileId} when is_binary(ProfileId) ->
            adk_provider_registry:resolve_config(Config);
        {ok, Invalid} -> {error, {invalid_llm_provider, Invalid}};
        error -> {error, missing_llm_provider}
    end.

materialize_profile_config(
  #{profile := ProfileId, adapter := Provider, endpoint := Endpoint,
    model := Model, options := Options,
    profile_snapshot := ProfileSnapshot}) ->
    case {adk_provider_credential:resolve_snapshot(
            ProfileId, ProfileSnapshot),
          endpoint_config(Endpoint)} of
        {{ok, Credential}, {ok, EndpointConfig}} ->
            Base = maps:merge(
                     Options,
                     maps:merge(EndpointConfig,
                                #{provider => Provider, model => Model})),
            {ok, put_profile_credential(Credential, Base)};
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

put_profile_credential(none, Config) -> Config;
put_profile_credential(Credential, Config) when is_binary(Credential) ->
    Config#{api_key => Credential}.

endpoint_config(gemini) ->
    {ok, #{base_url =>
               <<"https://generativelanguage.googleapis.com">>}};
endpoint_config(openai) ->
    {ok, #{base_url => <<"https://api.openai.com/v1">>}};
endpoint_config(anthropic) ->
    {ok, #{base_url => <<"https://api.anthropic.com/v1">>}};
endpoint_config(local) ->
    %% The trusted local adapter owns its loopback URL and port. Public
    %% profile selection still cannot override it.
    {ok, #{}};
endpoint_config(#{scheme := https, host := Host, port := Port,
                  base_path := BasePath}) ->
    Authority = endpoint_authority(Host, Port),
    {ok, #{base_url => <<"https://", Authority/binary,
                           BasePath/binary>>}};
endpoint_config(_Endpoint) ->
    {error, invalid_provider_endpoint}.

endpoint_authority(Host, 443) -> Host;
endpoint_authority(Host, Port) ->
    <<Host/binary, ":", (integer_to_binary(Port))/binary>>.

profile_capability_config(
  #{adapter := Provider, endpoint := Endpoint, model := Model,
    options := Options}) ->
    case endpoint_config(Endpoint) of
        {ok, EndpointConfig} ->
            {ok, maps:merge(
                   Options,
                   maps:merge(EndpointConfig,
                              #{provider => Provider, model => Model}))};
        {error, _} = Error -> Error
    end.

provider(Config) ->
    case maps:find(provider, Config) of
        {ok, Provider} when is_atom(Provider) ->
            case code:ensure_loaded(Provider) of
                {module, Provider} ->
                    case erlang:function_exported(Provider, generate, 3)
                         andalso erlang:function_exported(
                                   Provider, stream, 4) of
                        true -> {ok, Provider};
                        false -> {error, {invalid_llm_provider, Provider}}
                    end;
                {error, Reason} ->
                    {error, {llm_provider_unavailable, Provider,
                             adk_failure:external(
                               llm_provider, load, Reason)}}
            end;
        {ok, Invalid} -> {error, {invalid_llm_provider, Invalid}};
        error -> {error, missing_llm_provider}
    end.

provider_capabilities(Provider) when is_atom(Provider) ->
    provider_capabilities(Provider, undefined).

provider_capabilities(Provider, Config) when is_atom(Provider) ->
    case code:ensure_loaded(Provider) of
        {module, Provider} ->
            Required = #{generate => erlang:function_exported(
                                      Provider, generate, 3),
                         streaming => erlang:function_exported(
                                       Provider, stream, 4)},
            case maps:get(generate, Required)
                 andalso maps:get(streaming, Required) of
                false -> {error, {invalid_llm_provider, Provider}};
                true ->
                    case declared_provider_capabilities(
                           Provider, Required) of
                        {ok, Ceiling} ->
                            configured_provider_capabilities(
                              Provider, Config, Required, Ceiling);
                        {error, _} = Error -> Error
                    end
            end;
        {error, Reason} ->
            {error, {llm_provider_unavailable, Provider,
                     adk_failure:external(
                       llm_provider, load, Reason)}}
    end.

declared_provider_capabilities(Provider, Required) ->
    case erlang:function_exported(Provider, capabilities, 0) of
        false -> {ok, Required};
        true ->
            try Provider:capabilities() of
                Capabilities when is_map(Capabilities) ->
                    normalize_provider_capabilities(
                      Provider, maps:merge(Capabilities, Required));
                _Other ->
                    {error, {invalid_provider_capabilities, Provider}}
            catch
                Class:Reason ->
                    {error, adk_failure:exception(
                              llm_provider, capabilities, Class, Reason)}
            end
    end.

configured_provider_capabilities(_Provider, undefined, _Required, Ceiling) ->
    {ok, Ceiling};
configured_provider_capabilities(Provider, Config, Required, Ceiling) ->
    case erlang:function_exported(Provider, capabilities, 1) of
        false -> {ok, Ceiling};
        true ->
            try Provider:capabilities(Config) of
                Capabilities when is_map(Capabilities) ->
                    case normalize_provider_capabilities(
                           Provider, maps:merge(Capabilities, Required)) of
                        {ok, Configured} ->
                            adk_provider_capabilities:constrain(
                              Ceiling, Configured);
                        {error, _} = Error -> Error
                    end;
                _Other ->
                    {error, {invalid_provider_capabilities, Provider}}
            catch
                Class:Reason ->
                    {error, adk_failure:exception(
                              llm_provider, capabilities, Class, Reason)}
            end
    end.

normalize_provider_capabilities(Provider, Capabilities) ->
    case adk_provider_capabilities:normalize(Capabilities) of
        {ok, Checked} -> {ok, Checked};
        {error, _} -> {error, {invalid_provider_capabilities, Provider}}
    end.

%% Data-free provider status atoms are part of the documented adapter
%% contract. Any compound term may carry a response body or credential and is
%% therefore replaced by structural metadata.
provider_error(_Function, Reason) when is_atom(Reason) -> Reason;
provider_error(Function, Reason) ->
    adk_failure:external(llm_provider, Function, Reason).
