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
                trusted_audiences := TrustedAudiences,
                adapter_options := AdapterOptions})
  when is_binary(Token), is_binary(ClientId),
       is_list(SigningAlgs), is_list(TrustedAudiences),
       is_map(AdapterOptions) ->
    case normalize_adapter_options(AdapterOptions) of
        {ok, SafeAdapterOptions} ->
            verify_with_oidcc(Token, Provider, ClientId, SigningAlgs,
                              TrustedAudiences, SafeAdapterOptions);
        error ->
            {error, invalid_token}
    end;
verify(_Token, _Config) ->
    {error, invalid_token}.

verify_with_oidcc(Token, Provider, ClientId, SigningAlgs,
                  TrustedAudiences, SafeAdapterOptions) ->
    try oidcc_client_context:from_configuration_worker(
          Provider, ClientId, unauthenticated) of
        {ok, ClientContext} ->
            RefreshJwks = refresh_jwks_fun(Provider),
            %% The policy-owned values always win. Adapter options are limited
            %% to Oidcc's JWE algorithm allow-lists; callers cannot replace the
            %% JWS, audience, or JWKS-refresh policy.
            Opts = SafeAdapterOptions#{signing_algs => SigningAlgs,
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
    end.

normalize_adapter_options(Options) ->
    Allowed = [encryption_algs, encryption_encs],
    case lists:all(fun(Key) -> lists:member(Key, Allowed) end,
                   maps:keys(Options)) andalso
         valid_optional_algorithm_list(encryption_algs, Options) andalso
         valid_optional_algorithm_list(encryption_encs, Options) of
        true -> {ok, Options};
        false -> error
    end.

valid_optional_algorithm_list(Key, Options) ->
    case maps:find(Key, Options) of
        error -> true;
        {ok, Values} -> valid_algorithm_list(Values)
    end.

valid_algorithm_list([Value | Rest]) when is_binary(Value),
                                          byte_size(Value) > 0,
                                          byte_size(Value) =< 64 ->
    valid_algorithm(Value) andalso
    valid_algorithm_list_tail(Rest);
valid_algorithm_list(_Values) -> false.

valid_algorithm_list_tail([]) -> true;
valid_algorithm_list_tail([Value | Rest]) when is_binary(Value),
                                               byte_size(Value) > 0,
                                               byte_size(Value) =< 64 ->
    valid_algorithm(Value) andalso
    valid_algorithm_list_tail(Rest);
valid_algorithm_list_tail(_Values) -> false.

valid_algorithm(Value) ->
    try string:lowercase(Value) of
        <<"none">> -> false;
        Lower when is_binary(Lower) ->
            lists:all(fun valid_algorithm_char/1,
                      binary_to_list(Value));
        _ -> false
    catch
        _:_ -> false
    end.

valid_algorithm_char(Char) when Char >= $a, Char =< $z -> true;
valid_algorithm_char(Char) when Char >= $A, Char =< $Z -> true;
valid_algorithm_char(Char) when Char >= $0, Char =< $9 -> true;
valid_algorithm_char($-) -> true;
valid_algorithm_char($_) -> true;
valid_algorithm_char($+) -> true;
valid_algorithm_char($.) -> true;
valid_algorithm_char(_) -> false.

refresh_jwks_fun(Provider) ->
    fun(_CurrentJwks, Kid) ->
        oidcc_provider_configuration_worker:refresh_jwks_for_unknown_kid(
          Provider, Kid),
        {ok, oidcc_provider_configuration_worker:get_jwks(Provider)}
    end.
