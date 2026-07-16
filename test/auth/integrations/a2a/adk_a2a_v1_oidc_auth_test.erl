-module(adk_a2a_v1_oidc_auth_test).

-include_lib("eunit/include/eunit.hrl").

-define(ENV_KEY, a2a_v1_jwt_policy).
-define(NOW, 1000).
-define(ISSUER, <<"https://a2a-issuer.example">>).
-define(AUDIENCE, <<"erlang-adk-a2a">>).

a2a_oidc_auth_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun missing_policy_is_unauthenticated/0,
      fun valid_bearer_token_returns_policy_identity/0,
      fun insufficient_scope_is_forbidden/0,
      fun authentication_failures_are_unauthenticated/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Previous = application:get_env(erlang_adk, ?ENV_KEY),
    ok = application:unset_env(erlang_adk, ?ENV_KEY),
    Previous.

cleanup(Previous) ->
    restore_env(Previous),
    ok.

missing_policy_is_unauthenticated() ->
    ok = application:unset_env(erlang_adk, ?ENV_KEY),
    ?assertEqual(
       {error, unauthenticated},
       authorize(#{})).

valid_bearer_token_returns_policy_identity() ->
    set_policy(),
    Token = token(claims(#{<<"sub">> => <<"alice">>})),
    {ok, Identity, PrincipalId} = authorize(bearer(Token)),
    ?assertEqual(<<"alice">>, maps:get(subject, Identity)),
    ?assertEqual(?ISSUER, maps:get(issuer, Identity)),
    ?assertEqual(maps:get(principal, Identity), PrincipalId).

insufficient_scope_is_forbidden() ->
    set_policy(),
    Token = token(claims(#{<<"scope">> => <<"profile">>})),
    ?assertEqual({error, forbidden}, authorize(bearer(Token))).

authentication_failures_are_unauthenticated() ->
    set_policy(),
    ?assertEqual({error, unauthenticated}, authorize(#{})),
    WrongIssuer = token(
                    claims(#{<<"iss">> =>
                                 <<"https://attacker.example">>})),
    ?assertEqual(
       {error, unauthenticated},
       authorize(bearer(WrongIssuer))),
    ok = application:set_env(erlang_adk, ?ENV_KEY, not_a_policy),
    ?assertEqual(
       {error, unauthenticated},
       authorize(bearer(token(claims(#{}))))).

set_policy() ->
    {ok, Policy} = adk_jwt_policy:new(
                     #{issuer => ?ISSUER,
                       audience => ?AUDIENCE,
                       trusted_audiences => [],
                       signing_algs => [<<"RS256">>],
                       clock_skew_seconds => 0,
                       required_scopes => [<<"agent.run">>],
                       provider => a2a_oidc_fixture_provider,
                       verifier => adk_oidc_fake_verifier,
                       now_fun => fun() -> ?NOW end}),
    application:set_env(erlang_adk, ?ENV_KEY, Policy).

authorize(Headers) ->
    adk_a2a_v1_oidc_auth:authorize(
      <<"SendMessage">>, Headers, #{message_bytes => 32}).

bearer(Token) ->
    #{<<"authorization">> => <<"Bearer ", Token/binary>>}.

claims(Overrides) ->
    maps:merge(
      #{<<"iss">> => ?ISSUER,
        <<"aud">> => ?AUDIENCE,
        <<"sub">> => <<"alice">>,
        <<"exp">> => ?NOW + 60,
        <<"nbf">> => ?NOW - 1,
        <<"iat">> => ?NOW - 1,
        <<"scope">> => <<"agent.run profile">>},
      Overrides).

token(Claims) ->
    Header = jsx:encode(#{<<"alg">> => <<"RS256">>,
                          <<"typ">> => <<"JWT">>}),
    Payload = jsx:encode(Claims),
    <<(base64url(Header))/binary, ".", (base64url(Payload))/binary,
      ".fixture">>.

base64url(Binary) ->
    Encoded0 = base64:encode(Binary),
    Encoded1 = binary:replace(Encoded0, <<"+">>, <<"-">>, [global]),
    Encoded2 = binary:replace(Encoded1, <<"/">>, <<"_">>, [global]),
    binary:replace(Encoded2, <<"=">>, <<>>, [global]).

restore_env(undefined) ->
    application:unset_env(erlang_adk, ?ENV_KEY);
restore_env({ok, Value}) ->
    application:set_env(erlang_adk, ?ENV_KEY, Value).
