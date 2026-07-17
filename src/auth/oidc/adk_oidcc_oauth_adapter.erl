%% @doc Production outbound OAuth adapter backed by Oidcc.
-module(adk_oidcc_oauth_adapter).

-behaviour(adk_oauth_adapter).

-include_lib("oidcc/include/oidcc_token.hrl").

-export([client_credentials/4, refresh_token/6]).

-ifdef(TEST).
-export([test_normalize_token/1, test_oidcc_opts/1]).
-endif.

-spec client_credentials(adk_oauth_adapter:provider(), binary(), binary(),
                         adk_oauth_adapter:opts()) ->
    {ok, adk_oauth_adapter:token()} | {error, term()}.
client_credentials(Provider, ClientId, ClientSecret, Opts) ->
    safe_request(
      fun() ->
          oidcc:client_credentials_token(
            Provider, ClientId, ClientSecret, oidcc_opts(Opts))
      end).

-spec refresh_token(adk_oauth_adapter:provider(), binary(), binary(), binary(),
                    binary(), adk_oauth_adapter:opts()) ->
    {ok, adk_oauth_adapter:token()} | {error, term()}.
refresh_token(Provider, ClientId, ClientSecret, RefreshToken,
              ExpectedSubject, Opts) ->
    safe_request(
      fun() ->
          oidcc:refresh_token(
            RefreshToken, Provider, ClientId, ClientSecret,
            (oidcc_opts(Opts))#{expected_subject => ExpectedSubject})
      end).

safe_request(RequestFun) ->
    try RequestFun() of
        {ok, TokenRecord} -> normalize_token(TokenRecord);
        {error, provider_not_ready} -> {error, provider_unavailable};
        {error, _Reason} -> {error, oauth_request_failed}
    catch
        _:_ -> {error, oauth_request_failed}
    end.

normalize_token(#oidcc_token{
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
normalize_token(_TokenRecord) ->
    {error, invalid_token_response}.

oidcc_opts(#{scope := Scopes} = Opts) ->
    Base = #{scope => Scopes},
    case maps:find(resource, Opts) of
        {ok, Resource} ->
            %% Oidcc exposes RFC 8707 extension parameters through the token
            %% endpoint body_extension option.
            Base#{body_extension => [{<<"resource">>, Resource}]};
        error ->
            Base
    end.

-ifdef(TEST).
test_normalize_token(Token) -> normalize_token(Token).
test_oidcc_opts(Opts) -> oidcc_opts(Opts).
-endif.
