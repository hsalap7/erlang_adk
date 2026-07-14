%% @doc Production JWT verifier backed by a supervised Oidcc provider worker.
-module(adk_oidcc_jwt_verifier).

-behaviour(adk_jwt_verifier).

-export([verify/2]).

-spec verify(binary(), adk_jwt_verifier:config()) ->
    {ok, adk_jwt_verifier:claims()} |
    {error, adk_jwt_verifier:error_reason()}.
verify(Token, #{provider := Provider,
                client_id := ClientId,
                signing_algs := SigningAlgs,
                trusted_audiences := TrustedAudiences})
  when is_binary(Token), is_binary(ClientId),
       is_list(SigningAlgs), is_list(TrustedAudiences) ->
    try oidcc_client_context:from_configuration_worker(
          Provider, ClientId, unauthenticated) of
        {ok, ClientContext} ->
            RefreshJwks = refresh_jwks_fun(Provider),
            Opts = #{signing_algs => SigningAlgs,
                     trusted_audiences => TrustedAudiences,
                     refresh_jwks => RefreshJwks},
            case oidcc_token:validate_jwt(Token, ClientContext, Opts) of
                {ok, Claims} when is_map(Claims) -> {ok, Claims};
                {error, _Reason} -> {error, invalid_token}
            end;
        {error, provider_not_ready} ->
            {error, provider_unavailable}
    catch
        _:_ -> {error, invalid_token}
    end;
verify(_Token, _Config) ->
    {error, invalid_token}.

refresh_jwks_fun(Provider) ->
    fun(_CurrentJwks, Kid) ->
        oidcc_provider_configuration_worker:refresh_jwks_for_unknown_kid(
          Provider, Kid),
        {ok, oidcc_provider_configuration_worker:get_jwks(Provider)}
    end.
