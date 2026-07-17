%% @private
%% @doc Shared, deterministic Oidcc adapter policy.
%%
%% Both production adapters call this module for request-option translation
%% and validated-token projection. Keeping these pure decisions outside the
%% network boundary lets deterministic tests exercise the exact code shipped
%% in release builds without conditional test exports.
-module(adk_oidcc_adapter_policy).

-include_lib("oidcc/include/oidcc_token.hrl").

-export([oauth_opts/1, normalize_oauth_token/1,
         validated_refresh_credential/3]).

-define(MAX_REFRESH_TOKEN_BYTES, 65536).
-define(MAX_ACCESS_TOKEN_BYTES, 131072).
-define(MAX_ID_TOKEN_BYTES, 131072).
-define(MAX_SUBJECT_BYTES, 4096).
-define(MAX_TOKEN_TERM_BYTES, 1048576).

-spec oauth_opts(map()) -> map().
oauth_opts(#{scope := Scopes} = Opts) ->
    Base = #{scope => Scopes},
    case maps:find(resource, Opts) of
        {ok, Resource} ->
            %% Oidcc exposes RFC 8707 extension parameters through the token
            %% endpoint body_extension option.
            Base#{body_extension => [{<<"resource">>, Resource}]};
        error ->
            Base
    end.

-spec normalize_oauth_token(term()) -> {ok, map()} | {error, invalid_token_response}.
normalize_oauth_token(
  #oidcc_token{
     access = #oidcc_token_access{token = AccessToken,
                                  expires = ExpiresIn,
                                  type = TokenType},
     refresh = Refresh})
  when is_binary(AccessToken), byte_size(AccessToken) > 0,
       is_integer(ExpiresIn), ExpiresIn > 0,
       is_binary(TokenType), byte_size(TokenType) > 0 ->
    Token0 = #{access_token => AccessToken,
               expires_in_ms => ExpiresIn * 1000,
               token_type => TokenType},
    case Refresh of
        #oidcc_token_refresh{token = NewRefreshToken}
          when is_binary(NewRefreshToken), byte_size(NewRefreshToken) > 0 ->
            {ok, Token0#{refresh_token => NewRefreshToken}};
        none ->
            {ok, Token0};
        _ ->
            {error, invalid_token_response}
    end;
normalize_oauth_token(_TokenRecord) ->
    {error, invalid_token_response}.

-spec validated_refresh_credential(term(), binary(), binary()) ->
    {ok, map()} | {error, authorization_failed}.
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
    %% Claims are trusted only after oidcc:retrieve_token/5 validates the ID
    %% token with the exact nonce supplied by the authorization flow.
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

safe_external_size(Term) ->
    try erlang:external_size(Term) catch _:_ -> invalid end.
