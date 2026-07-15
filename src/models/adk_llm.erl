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
-callback validate_config(Config :: config()) -> ok | {error, term()}.
-optional_callbacks([stream_content/4, capabilities/0, validate_config/1]).

-export([generate/3, stream/4, stream_content/4,
         capabilities/1, validate_config/1]).

%% @doc Dispatch the call to the specified provider.
generate(Config, Memory, Tools) ->
    dispatch(Config, generate, [Config, Memory, Tools]).

%% @doc Dispatch the streaming call to the specified provider.
stream(Config, Memory, Tools, Callback) ->
    dispatch(Config, stream, [Config, Memory, Tools, Callback]).

%% @doc Dispatch the optional canonical content-delta stream. Providers which
%% implement text streaming only fail explicitly instead of coercing maps to
%% text or silently dropping parts.
stream_content(Config, Memory, Tools, Callback) ->
    dispatch_optional(Config, stream_content,
                      [Config, Memory, Tools, Callback], content_streaming).

%% @doc Return normalized adapter capabilities. Unknown custom providers remain
%% usable and conservatively report only the two required behavior callbacks.
-spec capabilities(config() | module()) -> {ok, map()} | {error, term()}.
capabilities(Provider) when is_atom(Provider) ->
    provider_capabilities(Provider);
capabilities(Config) when is_map(Config) ->
    case provider(Config) of
        {ok, Provider} -> provider_capabilities(Provider);
        {error, _} = Error -> Error
    end;
capabilities(Value) ->
    {error, {invalid_llm_config, Value}}.

%% @doc Validate the provider reference and invoke its optional validator.
-spec validate_config(config()) -> ok | {error, term()}.
validate_config(Config) when is_map(Config) ->
    case provider(Config) of
        {ok, Provider} ->
            case erlang:function_exported(Provider, validate_config, 1) of
                true ->
                    try Provider:validate_config(Config) of
                        ok -> ok;
                        {error, _} = Error -> Error;
                        Other -> {error, {invalid_provider_validation, Other}}
                    catch
                        Class:Reason ->
                            {error, adk_failure:exception(
                                      llm_provider, validate_config,
                                      Class, Reason)}
                    end;
                false -> ok
            end;
        {error, _} = Error -> Error
    end;
validate_config(Value) ->
    {error, {invalid_llm_config, Value}}.

dispatch(Config, Function, Args) ->
    case validate_config(Config) of
        ok ->
            {ok, Provider} = provider(Config),
            try apply(Provider, Function, Args) of
                {error, Reason} ->
                    {error, provider_error(Function, Reason)};
                Result -> Result
            catch
                Class:Reason ->
                    {error, adk_failure:exception(
                              llm_provider, Function, Class, Reason)}
            end;
        {error, _} = Error -> Error
    end.

dispatch_optional(Config, Function, Args, Capability) ->
    case validate_config(Config) of
        ok ->
            {ok, Provider} = provider(Config),
            case erlang:function_exported(Provider, Function, length(Args)) of
                true ->
                    try apply(Provider, Function, Args) of
                        {error, Reason} ->
                            {error, provider_error(Function, Reason)};
                        Result -> Result
                    catch
                        Class:Reason ->
                            {error, adk_failure:exception(
                                      llm_provider, Function,
                                      Class, Reason)}
                    end;
                false ->
                    {error, {unsupported_provider_capability, Capability}}
            end;
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
                    case erlang:function_exported(
                           Provider, capabilities, 0) of
                        false -> {ok, Required};
                        true ->
                            try Provider:capabilities() of
                                Capabilities when is_map(Capabilities) ->
                                    {ok, maps:merge(Required, Capabilities)};
                                Other ->
                                    {error, {invalid_provider_capabilities,
                                             Provider, Other}}
                            catch
                                Class:Reason ->
                                    {error, adk_failure:exception(
                                              llm_provider, capabilities,
                                              Class, Reason)}
                            end
                    end
            end;
        {error, Reason} ->
            {error, {llm_provider_unavailable, Provider,
                     adk_failure:external(
                       llm_provider, load, Reason)}}
    end.

%% Data-free provider status atoms are part of the documented adapter
%% contract. Any compound term may carry a response body or credential and is
%% therefore replaced by structural metadata.
provider_error(_Function, Reason) when is_atom(Reason) -> Reason;
provider_error(Function, Reason) ->
    adk_failure:external(llm_provider, Function, Reason).
