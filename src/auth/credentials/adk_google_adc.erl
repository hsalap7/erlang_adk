%% @doc Bounded OAuth bearer acquisition for the Vertex request adapter.
%%
%% A direct `api_key' is treated as an already-minted OAuth access token. The
%% `google_adc' source invokes either a trusted injected provider (for managed
%% integrations/tests) or the fixed gcloud Application Default Credentials
%% command. No shell, caller-supplied executable, arguments, or output-derived
%% error term crosses this boundary.
-module(adk_google_adc).

-export([access_token/1, validate_config/1]).

-define(ADC_TIMEOUT_MS, 10000).
-define(MAX_COMMAND_OUTPUT_BYTES, 65536).

-spec validate_config(term()) -> ok | {error, term()}.
validate_config(Config) when is_map(Config) ->
    case {maps:find(api_key, Config),
          maps:get(credential_source, Config, undefined),
          maps:find(adc_token_provider, Config)} of
        {{ok, Token}, undefined, error} -> validate_token(Token);
        {{ok, _Token}, google_adc, _} ->
            {error, conflicting_vertex_oauth_credentials};
        {{ok, _Token}, _Other, _} ->
            {error, invalid_vertex_credential_source};
        {error, google_adc, error} -> ok;
        {error, google_adc, {ok, Provider}} ->
            validate_provider(Provider);
        {error, undefined, {ok, _Provider}} ->
            {error, invalid_vertex_adc_token_provider};
        {error, undefined, error} ->
            {error, vertex_oauth_credential_required};
        {error, _Other, _} ->
            {error, invalid_vertex_credential_source}
    end;
validate_config(_Config) ->
    {error, invalid_vertex_oauth_config}.

-spec access_token(map()) -> {ok, binary()} | {error, term()}.
access_token(Config) when is_map(Config) ->
    case validate_config(Config) of
        ok -> acquire_validated(Config);
        {error, _} = Error -> Error
    end;
access_token(_Config) ->
    {error, invalid_vertex_oauth_config}.

acquire_validated(#{api_key := Token}) ->
    normalize_token(Token);
acquire_validated(#{credential_source := google_adc} = Config) ->
    case maps:find(adc_token_provider, Config) of
        {ok, {Module, Handle}} -> provider_token(Module, Handle);
        error -> gcloud_token()
    end.

validate_provider({Module, _Handle}) when is_atom(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, access_token, 1) of
                true -> ok;
                false -> {error, invalid_vertex_adc_token_provider}
            end;
        _ -> {error, invalid_vertex_adc_token_provider}
    end;
validate_provider(_Provider) ->
    {error, invalid_vertex_adc_token_provider}.

provider_token(Module, Handle) ->
    try Module:access_token(Handle) of
        {ok, Token} when is_binary(Token); is_list(Token) ->
            provider_token_result(Token);
        {ok, #{access_token := Token}} ->
            provider_token_result(Token);
        _ -> {error, vertex_adc_token_unavailable}
    catch
        _:_ -> {error, vertex_adc_token_unavailable}
    end.

provider_token_result(Token) ->
    case normalize_token(Token) of
        {ok, _} = Ok -> Ok;
        {error, _} -> {error, vertex_adc_token_unavailable}
    end.

gcloud_token() ->
    case os:find_executable("gcloud") of
        false -> {error, vertex_adc_token_unavailable};
        Executable -> run_gcloud(Executable)
    end.

run_gcloud(Executable) ->
    Options = [binary, exit_status, use_stdio, stderr_to_stdout,
               {args, ["auth", "application-default", "print-access-token",
                       "--quiet"]}],
    try erlang:open_port({spawn_executable, Executable}, Options) of
        Port -> collect_gcloud(Port, <<>>, deadline())
    catch
        _:_ -> {error, vertex_adc_token_unavailable}
    end.

collect_gcloud(Port, Output, Deadline) ->
    Remaining = erlang:max(0, Deadline - monotonic_ms()),
    receive
        {Port, {data, Data}} when is_binary(Data) ->
            case byte_size(Output) + byte_size(Data) =<
                 ?MAX_COMMAND_OUTPUT_BYTES of
                true -> collect_gcloud(
                          Port, <<Output/binary, Data/binary>>, Deadline);
                false -> close_port(Port)
            end;
        {Port, {exit_status, 0}} ->
            normalize_gcloud_output(Output);
        {Port, {exit_status, _Status}} ->
            {error, vertex_adc_token_unavailable}
    after Remaining ->
        close_port(Port)
    end.

normalize_gcloud_output(Output) ->
    try string:trim(Output) of
        Token ->
            case normalize_token(Token) of
                {ok, _} = Ok -> Ok;
                {error, _} -> {error, vertex_adc_token_unavailable}
            end
    catch
        _:_ -> {error, vertex_adc_token_unavailable}
    end.

close_port(Port) ->
    _ = catch erlang:port_close(Port),
    {error, vertex_adc_token_unavailable}.

validate_token(Token) ->
    case normalize_token(Token) of
        {ok, _} -> ok;
        {error, _} -> {error, invalid_vertex_oauth_token}
    end.

normalize_token(Token) ->
    case adk_model_http_client:resolve_explicit_api_key(
           #{api_key => Token}) of
        {ok, Checked} -> {ok, Checked};
        {error, _} -> {error, invalid_vertex_oauth_token}
    end.

deadline() -> monotonic_ms() + ?ADC_TIMEOUT_MS.

monotonic_ms() -> erlang:monotonic_time(millisecond).
