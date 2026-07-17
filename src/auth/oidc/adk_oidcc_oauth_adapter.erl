%% @doc Production outbound OAuth adapter backed by Oidcc.
-module(adk_oidcc_oauth_adapter).

-behaviour(adk_oauth_adapter).

-export([client_credentials/4, refresh_token/6]).

-spec client_credentials(adk_oauth_adapter:provider(), binary(), binary(),
                         adk_oauth_adapter:opts()) ->
    {ok, adk_oauth_adapter:token()} | {error, term()}.
client_credentials(Provider, ClientId, ClientSecret, Opts) ->
    safe_request(
      fun() ->
          oidcc:client_credentials_token(
            Provider, ClientId, ClientSecret,
            adk_oidcc_adapter_policy:oauth_opts(Opts))
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
            (adk_oidcc_adapter_policy:oauth_opts(Opts))#{
              expected_subject => ExpectedSubject})
      end).

safe_request(RequestFun) ->
    try RequestFun() of
        {ok, TokenRecord} ->
            adk_oidcc_adapter_policy:normalize_oauth_token(TokenRecord);
        {error, provider_not_ready} -> {error, provider_unavailable};
        {error, _Reason} -> {error, oauth_request_failed}
    catch
        _:_ -> {error, oauth_request_failed}
    end.
