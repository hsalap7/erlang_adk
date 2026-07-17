%% @doc Oidcc 3.7 authorization-code adapter with mandatory S256 PKCE.
%%
%% oidcc:retrieve_token/5 validates issuer, signature, audience, time claims,
%% authorization-party and the bound nonce before it returns.  This adapter
%% extracts the validated provider subject and retains only the refresh
%% credential needed by the existing token manager. The local principal is a
%% separate issuer-bound identity and remains the credential-store scope; it
%% must not be compared to the provider's raw sub claim.
-module(adk_oidcc_authorization_code_adapter).

-behaviour(adk_authorization_code_adapter).

-include_lib("oidcc/include/oidcc_token.hrl").

-export([validate_context/1, authorization_uri/2, exchange_code/3]).

-ifdef(TEST).
-export([test_validated_refresh_credential/3]).
-endif.

-define(MAX_CLIENT_ID_BYTES, 4096).
-define(MAX_CLIENT_SECRET_BYTES, 16384).
-define(MAX_REFRESH_TOKEN_BYTES, 65536).
-define(MAX_ACCESS_TOKEN_BYTES, 131072).
-define(MAX_ID_TOKEN_BYTES, 131072).
-define(MAX_SUBJECT_BYTES, 4096).
-define(MAX_TOKEN_TERM_BYTES, 1048576).

-spec validate_context(map()) -> ok | {error, invalid_adapter_context}.
validate_context(#{provider_worker := Provider,
                   client_id := ClientId,
                   client_secret := ClientSecret} = Context) ->
    case exact_keys(Context, [provider_worker, client_id, client_secret])
         andalso valid_provider(Provider)
         andalso valid_text(ClientId, ?MAX_CLIENT_ID_BYTES)
         andalso valid_text(ClientSecret, ?MAX_CLIENT_SECRET_BYTES) of
        true -> ok;
        false -> {error, invalid_adapter_context}
    end;
validate_context(_Context) ->
    {error, invalid_adapter_context}.

-spec authorization_uri(map(),
                        adk_authorization_code_adapter:authorization_opts()) ->
    {ok, binary()} | {error, authorization_unavailable}.
authorization_uri(#{provider_worker := Provider,
                    client_id := ClientId,
                    client_secret := ClientSecret}, Opts) ->
    OidccOpts0 = #{state => maps:get(state, Opts),
                   nonce => maps:get(nonce, Opts),
                   pkce_verifier => maps:get(pkce_verifier, Opts),
                   require_pkce => true,
                   redirect_uri => maps:get(redirect_uri, Opts),
                   scopes => maps:get(scopes, Opts)},
    OidccOpts = resource_extension(url_extension, Opts, OidccOpts0),
    try oidcc:create_redirect_url(
          Provider, ClientId, ClientSecret, OidccOpts) of
        {ok, Uri0} ->
            case safe_binary(Uri0) of
                {ok, Uri} -> {ok, Uri};
                error -> {error, authorization_unavailable}
            end;
        {error, _Reason} ->
            {error, authorization_unavailable}
    catch
        _:_ -> {error, authorization_unavailable}
    end;
authorization_uri(_Context, _Opts) ->
    {error, authorization_unavailable}.

-spec exchange_code(map(), binary(),
                    adk_authorization_code_adapter:exchange_opts()) ->
    {ok, adk_credential_store:credential()} |
    {error, authorization_failed}.
exchange_code(#{provider_worker := Provider,
                client_id := ClientId,
                client_secret := ClientSecret}, Code, Opts)
  when is_binary(Code), byte_size(Code) > 0 ->
    OidccOpts0 = #{nonce => maps:get(nonce, Opts),
                   pkce_verifier => maps:get(pkce_verifier, Opts),
                   require_pkce => true,
                   redirect_uri => maps:get(redirect_uri, Opts),
                   scope => maps:get(scopes, Opts)},
    OidccOpts = resource_extension(body_extension, Opts, OidccOpts0),
    try oidcc:retrieve_token(
          Code, Provider, ClientId, ClientSecret, OidccOpts) of
        {ok, Token} ->
            validated_refresh_credential(Token, ClientId, ClientSecret);
        {error, _Reason} ->
            {error, authorization_failed}
    catch
        _:_ -> {error, authorization_failed}
    end;
exchange_code(_Context, _Code, _Opts) ->
    {error, authorization_failed}.

validated_refresh_credential(
  Token = #oidcc_token{id = #oidcc_token_id{token = IdToken,
                                            claims = Claims},
                       access = #oidcc_token_access{token = AccessToken,
                                                    type = TokenType},
                       refresh = #oidcc_token_refresh{token = RefreshToken}},
  ClientId, ClientSecret)
  when is_map(Claims),
       is_binary(IdToken), byte_size(IdToken) > 0,
       byte_size(IdToken) =< ?MAX_ID_TOKEN_BYTES,
       is_binary(AccessToken), byte_size(AccessToken) > 0,
       byte_size(AccessToken) =< ?MAX_ACCESS_TOKEN_BYTES,
       is_binary(TokenType), byte_size(TokenType) > 0,
       byte_size(TokenType) =< 128,
       is_binary(RefreshToken), byte_size(RefreshToken) > 0,
       byte_size(RefreshToken) =< ?MAX_REFRESH_TOKEN_BYTES ->
    %% Claims are trusted only because oidcc:retrieve_token/5 already
    %% performed ID-token validation with the exact nonce passed above.
    case {maps:get(<<"sub">>, Claims, undefined),
          safe_external_size(Token)} of
        {Subject, Size}
          when is_binary(Subject), byte_size(Subject) > 0,
               byte_size(Subject) =< ?MAX_SUBJECT_BYTES,
               is_integer(Size), Size =< ?MAX_TOKEN_TERM_BYTES ->
            {ok, #{kind => oauth_refresh_token,
                   client_id => ClientId,
                   client_secret => ClientSecret,
                   refresh_token => RefreshToken,
                   expected_subject => Subject}};
        _ ->
            {error, authorization_failed}
    end;
validated_refresh_credential(_Token, _ClientId, _ClientSecret) ->
    {error, authorization_failed}.

resource_extension(Key, #{resource := Resource}, Opts)
  when is_binary(Resource), byte_size(Resource) > 0 ->
    Opts#{Key => [{<<"resource">>, Resource}]};
resource_extension(_Key, _FlowOpts, Opts) ->
    Opts.

valid_provider(Provider) when is_pid(Provider) -> true;
valid_provider(Provider) when is_atom(Provider) -> Provider =/= undefined;
valid_provider(_) -> false.

valid_text(Value, Max) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< Max;
valid_text(_, _) -> false.

exact_keys(Map, Allowed) ->
    lists:sort(maps:keys(Map)) =:= lists:sort(Allowed).

safe_binary(Value) ->
    try erlang:iolist_size(Value) of
        Size when Size > 0, Size =< 8192 -> {ok, iolist_to_binary(Value)};
        _ -> error
    catch
        _:_ -> error
    end.

safe_external_size(Term) ->
    try erlang:external_size(Term) catch _:_ -> invalid end.

-ifdef(TEST).
test_validated_refresh_credential(Token, ClientId, ClientSecret) ->
    validated_refresh_credential(Token, ClientId, ClientSecret).
-endif.
