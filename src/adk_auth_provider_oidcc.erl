%% @doc Oidcc-backed service credential provider for adk_token_manager.
%%
%% Credentials are deliberately typed. This provider accepts only OAuth
%% client-credential and refresh-token service credentials; API keys and
%% incoming bearer credentials are rejected before an adapter is invoked.
-module(adk_auth_provider_oidcc).

-behaviour(adk_auth_provider).

-export([refresh/2]).

-spec refresh(adk_auth_provider:credential(), adk_auth_provider:context()) ->
    {ok, adk_auth_provider:token()} | {error, term()}.
refresh(Credential, Context) when is_map(Credential), is_map(Context) ->
    Seeds = safe_seeds(Credential),
    case normalize_context(Context) of
        {ok, Provider, Adapter, Opts, Rotator} ->
            Result = invoke_grant(Credential, Provider, Adapter, Opts,
                                  Rotator),
            redact_failure(Result, Seeds);
        {error, _Reason} = Error ->
            Error
    end;
refresh(_Credential, _Context) ->
    {error, invalid_credential}.

invoke_grant(#{kind := oauth_client_credentials,
               client_id := ClientId,
               client_secret := ClientSecret} = Credential,
             Provider, Adapter, Opts, _Rotator)
  when is_binary(ClientId), byte_size(ClientId) > 0,
       is_binary(ClientSecret), byte_size(ClientSecret) > 0 ->
    case exact_keys(Credential, [kind, client_id, client_secret]) of
        true ->
            safe_adapter_call(
              fun() -> Adapter:client_credentials(
                         Provider, ClientId, ClientSecret, Opts)
              end, no_rotation);
        false ->
            {error, invalid_credential}
    end;
invoke_grant(#{kind := oauth_refresh_token,
               client_id := ClientId,
               client_secret := ClientSecret,
               refresh_token := RefreshToken,
               expected_subject := ExpectedSubject} = Credential,
             Provider, Adapter, Opts, Rotator)
  when is_binary(ClientId), byte_size(ClientId) > 0,
       is_binary(ClientSecret), byte_size(ClientSecret) > 0,
       is_binary(RefreshToken), byte_size(RefreshToken) > 0,
       is_binary(ExpectedSubject), byte_size(ExpectedSubject) > 0 ->
    case exact_keys(Credential,
                    [kind, client_id, client_secret, refresh_token,
                     expected_subject]) of
        true ->
            case is_function(Rotator, 2) of
                true ->
                    safe_adapter_call(
                      fun() -> Adapter:refresh_token(
                                 Provider, ClientId, ClientSecret,
                                 RefreshToken, ExpectedSubject, Opts)
                      end, {rotation, Rotator, Credential});
                false ->
                    {error, credential_rotation_failed}
            end;
        false ->
            {error, invalid_credential}
    end;
invoke_grant(#{kind := Kind}, _Provider, _Adapter, _Opts, _Rotator)
  when Kind =:= api_key; Kind =:= bearer_token ->
    {error, unsupported_credential_kind};
invoke_grant(_Credential, _Provider, _Adapter, _Opts, _Rotator) ->
    {error, invalid_credential}.

safe_adapter_call(Call, RotationPolicy) ->
    try Call() of
        {ok, Token} -> normalize_token(Token, RotationPolicy);
        {error, Reason} -> {error, Reason};
        _Other -> {error, invalid_provider_response}
    catch
        _:_ -> {error, oauth_request_failed}
    end.

normalize_token(#{access_token := AccessToken,
                  expires_in_ms := ExpiresIn} = Token, RotationPolicy)
  when is_binary(AccessToken), byte_size(AccessToken) > 0,
       is_integer(ExpiresIn), ExpiresIn > 0 ->
    TokenType = maps:get(token_type, Token, <<"Bearer">>),
    case is_binary(TokenType) andalso byte_size(TokenType) > 0 of
        true ->
            Sanitized = #{access_token => AccessToken,
                          expires_in_ms => ExpiresIn,
                          token_type => TokenType},
            apply_rotation(Token, Sanitized, RotationPolicy);
        false ->
            {error, invalid_provider_response}
    end;
normalize_token(_Token, _RotationPolicy) ->
    {error, invalid_provider_response}.

apply_rotation(Token, Sanitized, no_rotation) ->
    case maps:is_key(refresh_token, Token) of
        false -> {ok, Sanitized};
        true -> {error, invalid_provider_response}
    end;
apply_rotation(Token, Sanitized,
               {rotation, Rotator, ExpectedCredential})
  when is_function(Rotator, 2), is_map(ExpectedCredential) ->
    case maps:find(refresh_token, Token) of
        error ->
            {ok, Sanitized};
        {ok, RefreshToken} when is_binary(RefreshToken),
                                byte_size(RefreshToken) > 0 ->
            case safe_rotate(Rotator, ExpectedCredential, RefreshToken) of
                ok -> {ok, Sanitized};
                {error, conflict} -> {error, credential_rotation_conflict};
                {error, _Reason} -> {error, credential_rotation_failed}
            end;
        {ok, _Invalid} ->
            {error, invalid_provider_response}
    end.

safe_rotate(Rotator, ExpectedCredential, RefreshToken) ->
    try Rotator(ExpectedCredential, RefreshToken) of
        ok -> ok;
        {error, conflict} -> {error, conflict};
        {error, _Reason} -> {error, failed};
        _Other -> {error, failed}
    catch
        _:_ -> {error, failed}
    end.

normalize_context(Context) ->
    Provider = maps:get(provider_worker, Context, undefined),
    Adapter = maps:get(oauth_adapter, Context, adk_oidcc_oauth_adapter),
    Scopes = maps:get(scopes, Context, []),
    Rotator = maps:get(credential_rotator, Context, undefined),
    case valid_server_ref(Provider) andalso is_atom(Adapter) andalso
         Adapter =/= undefined andalso valid_scopes(Scopes) andalso
         valid_rotator(Rotator) of
        true -> {ok, Provider, Adapter, #{scope => lists:usort(Scopes)},
                 Rotator};
        false -> {error, invalid_context}
    end.

redact_failure({error, Reason}, Seeds) ->
    {error, safe_redact(Reason, Seeds)};
redact_failure(Result, _Seeds) -> Result.

safe_seeds(Credential) ->
    try adk_secret_redactor:seed_values(Credential)
    catch _:_ -> []
    end.

safe_redact(Reason, Seeds) ->
    try adk_secret_redactor:redact(Reason, Seeds)
    catch _:_ -> adk_secret_redactor:marker()
    end.

valid_server_ref(Ref) when is_pid(Ref) -> true;
valid_server_ref(Ref) when is_atom(Ref) -> Ref =/= undefined;
valid_server_ref(_Ref) -> false.

valid_scopes([]) -> true;
valid_scopes([Scope | Rest]) when is_binary(Scope), byte_size(Scope) > 0 ->
    valid_scopes(Rest);
valid_scopes(_Scopes) -> false.

valid_rotator(undefined) -> true;
valid_rotator(Rotator) -> is_function(Rotator, 2).

exact_keys(Map, Keys) ->
    lists:sort(maps:keys(Map)) =:= lists:sort(Keys).
