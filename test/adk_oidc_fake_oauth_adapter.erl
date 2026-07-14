-module(adk_oidc_fake_oauth_adapter).

-behaviour(adk_oauth_adapter).

-export([client_credentials/4, refresh_token/6]).

client_credentials(_Provider, _ClientId, <<"leaky-client-secret">>, _Opts) ->
    {error, {token_endpoint_error,
             <<"client secret leaky-client-secret access_token=leaked">>}};
client_credentials(_Provider, ClientId, _ClientSecret, _Opts) ->
    {ok, #{access_token => <<"cc:", ClientId/binary>>,
           expires_in_ms => 60000,
           token_type => <<"Bearer">>}}.

refresh_token(_Provider, ClientId, _ClientSecret, _RefreshToken,
              ExpectedSubject, Opts) ->
    Scopes = maps:get(scope, Opts, []),
    maybe_delay_rotation_race(Scopes),
    ScopeSuffix = iolist_to_binary(lists:join(<<",">>, Scopes)),
    {ok, #{access_token => <<"refresh:", ClientId/binary, ":",
                            ExpectedSubject/binary>>,
           expires_in_ms => 30000,
           token_type => <<"Bearer">>,
           refresh_token => <<"rotated:", ScopeSuffix/binary>>}}.

maybe_delay_rotation_race([<<"rotation-race-a">>]) -> timer:sleep(100);
maybe_delay_rotation_race([<<"rotation-race-b">>]) -> timer:sleep(100);
maybe_delay_rotation_race(_Scopes) -> ok.
