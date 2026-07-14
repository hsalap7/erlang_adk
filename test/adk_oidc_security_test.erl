-module(adk_oidc_security_test).

-include_lib("eunit/include/eunit.hrl").

-define(NOW, 1000).
-define(ISSUER, <<"https://issuer.example">>).
-define(AUDIENCE, <<"erlang-adk">>).

jwt_authentication_policy_test_() ->
    [fun valid_token_returns_issuer_bound_principal/0,
     fun wrong_issuer_is_rejected/0,
     fun wrong_audience_is_rejected/0,
     fun unknown_co_audience_is_rejected/0,
     fun wrong_signing_algorithm_is_rejected_before_adapter/0,
     fun expired_token_is_rejected/0,
     fun future_token_is_rejected/0,
     fun missing_scope_is_rejected/0,
     fun verifier_failures_are_opaque/0,
     fun real_oidcc_verifies_signed_offline_fixture/0,
     fun bearer_header_is_strict/0,
     fun malformed_auth_inputs_fail_closed/0,
     fun unsafe_policies_are_rejected/0,
     fun missing_oidcc_worker_is_reported_without_network/0].

oauth_service_credentials_test_() ->
    [fun client_credentials_grant_is_normalized/0,
     fun refresh_grant_requires_subject_and_is_normalized/0,
     fun api_keys_and_bearer_tokens_are_distinct/0,
     fun oauth_adapter_failure_is_redacted/0,
     fun opaque_credentials_remain_user_isolated/0].

provider_supervision_test_() ->
    [fun provider_child_is_explicit_and_secret_free/0,
     fun insecure_or_secret_bearing_provider_config_is_rejected/0,
     fun empty_provider_supervisor_is_network_free/0].

valid_token_returns_issuer_bound_principal() ->
    Policy = policy(#{}),
    AliceToken = token(<<"RS256">>, claims(#{<<"sub">> => <<"alice">>})),
    BobToken = token(<<"RS256">>, claims(#{<<"sub">> => <<"bob">>})),
    {ok, Alice} = authenticate(Policy, AliceToken),
    {ok, Bob} = authenticate(Policy, BobToken),
    ?assertEqual(<<"alice">>, maps:get(subject, Alice)),
    ?assertEqual(?ISSUER, maps:get(issuer, Alice)),
    ?assertEqual([<<"agent.run">>, <<"profile">>], maps:get(scopes, Alice)),
    ?assertNotEqual(maps:get(principal, Alice), maps:get(principal, Bob)),
    ?assertMatch(<<"oidc_", _/binary>>, maps:get(principal, Alice)),
    ?assertNot(maps:is_key(<<"unapproved">>, maps:get(claims, Alice))),
    OtherPolicy = policy(#{issuer => <<"https://other-issuer.example">>}),
    OtherToken = token(
                   <<"RS256">>,
                   claims(#{<<"iss">> => <<"https://other-issuer.example">>,
                            <<"sub">> => <<"alice">>})),
    {ok, OtherAlice} = authenticate(OtherPolicy, OtherToken),
    ?assertNotEqual(maps:get(principal, Alice),
                    maps:get(principal, OtherAlice)).

wrong_issuer_is_rejected() ->
    Policy = policy(#{}),
    Token = token(<<"RS256">>,
                  claims(#{<<"iss">> => <<"https://attacker.example">>})),
    ?assertEqual({error, invalid_issuer}, authenticate(Policy, Token)).

wrong_audience_is_rejected() ->
    Policy = policy(#{}),
    Token = token(<<"RS256">>, claims(#{<<"aud">> => <<"other-api">>})),
    ?assertEqual({error, invalid_audience}, authenticate(Policy, Token)).

unknown_co_audience_is_rejected() ->
    Policy = policy(#{}),
    Token = token(<<"RS256">>,
                  claims(#{<<"aud">> => [?AUDIENCE, <<"untrusted-api">>]})),
    ?assertEqual({error, invalid_audience}, authenticate(Policy, Token)).

wrong_signing_algorithm_is_rejected_before_adapter() ->
    Policy = policy(#{}),
    Token = token(<<"HS256">>, claims(#{})),
    ?assertEqual({error, disallowed_signing_algorithm},
                 authenticate(Policy, Token)),
    NoneToken = token(<<"none">>, claims(#{})),
    ?assertEqual({error, disallowed_signing_algorithm},
                 authenticate(Policy, NoneToken)).

expired_token_is_rejected() ->
    Policy = policy(#{}),
    Token = token(<<"RS256">>, claims(#{<<"exp">> => ?NOW - 6})),
    ?assertEqual({error, token_expired}, authenticate(Policy, Token)).

future_token_is_rejected() ->
    Policy = policy(#{}),
    NbfToken = token(<<"RS256">>, claims(#{<<"nbf">> => ?NOW + 6})),
    ?assertEqual({error, token_not_yet_valid},
                 authenticate(Policy, NbfToken)),
    IatToken = token(<<"RS256">>, claims(#{<<"iat">> => ?NOW + 6})),
    ?assertEqual({error, token_not_yet_valid},
                 authenticate(Policy, IatToken)).

missing_scope_is_rejected() ->
    Policy = policy(#{}),
    Token = token(<<"RS256">>, claims(#{<<"scope">> => <<"profile">>})),
    ?assertEqual({error, insufficient_scope}, authenticate(Policy, Token)).

verifier_failures_are_opaque() ->
    Secret = <<"verifier-secret-f32a">>,
    Policy = policy(#{adapter_options => #{mode => throw,
                                           secret => Secret}}),
    Token = token(<<"RS256">>, claims(#{})),
    Result = authenticate(Policy, Token),
    ?assertEqual({error, invalid_token}, Result),
    assert_absent(Secret, Result),
    assert_absent(Token, Result).

real_oidcc_verifies_signed_offline_fixture() ->
    PrivateKey = jose_jwk:generate_key({rsa, 2048}),
    PublicKey = jose_jwk:to_public(PrivateKey),
    {ok, Provider} = adk_oidcc_fixture_provider:start_link(?ISSUER, PublicKey),
    try
        Now = erlang:system_time(second),
        Claims = #{<<"iss">> => ?ISSUER,
                   <<"aud">> => ?AUDIENCE,
                   <<"sub">> => <<"signed-alice">>,
                   <<"exp">> => Now + 120,
                   <<"nbf">> => Now - 1,
                   <<"iat">> => Now - 1,
                   <<"scope">> => <<"agent.run">>},
        Signed = signed_token(PrivateKey, Claims),
        {ok, Policy} = adk_jwt_policy:new(
                         (policy_config(#{}))#{
                           provider => Provider,
                           verifier => adk_oidcc_jwt_verifier,
                           clock_skew_seconds => 0,
                           now_fun => fun() -> erlang:system_time(second) end}),
        {ok, Identity} = authenticate(Policy, Signed),
        ?assertEqual(<<"signed-alice">>, maps:get(subject, Identity)),
        Tampered = tamper_subject(Signed),
        ?assertEqual({error, invalid_token},
                     authenticate(Policy, Tampered))
    after
        gen_server:stop(Provider)
    end.

bearer_header_is_strict() ->
    Token = token(<<"RS256">>, claims(#{})),
    ?assertEqual({ok, Token},
                 adk_bearer_auth:extract(
                   #{<<"Authorization">> => <<"bEaReR ", Token/binary>>})),
    ?assertEqual({error, missing_bearer_token},
                 adk_bearer_auth:extract(
                   #{<<"access_token">> => Token})),
    ?assertEqual({error, multiple_authorization_headers},
                 adk_bearer_auth:extract(
                   [{<<"authorization">>, <<"Bearer ", Token/binary>>},
                    {<<"Authorization">>, <<"Bearer ", Token/binary>>}])),
    ?assertEqual({error, malformed_authorization_header},
                 adk_bearer_auth:extract(
                   #{<<"authorization">> => <<"Bearer bad token">>})),
    ?assertEqual({error, unsupported_authorization_scheme},
                 adk_bearer_auth:extract(
                   #{<<"authorization">> => <<"Basic abc">>})),
    ?assertEqual({error, malformed_authorization_header},
                 adk_bearer_auth:extract(
                   #{<<255>> => <<"Bearer abc">>})).

malformed_auth_inputs_fail_closed() ->
    HeaderInputs = [undefined,
                    42,
                    [invalid_pair | improper_tail],
                    #{<<"authorization">> => [<<"Bearer abc">> | bad]},
                    #{<<"authorization">> => <<0, 1, 2>>}],
    lists:foreach(
      fun(Input) ->
          Result = catch adk_bearer_auth:extract(Input),
          ?assertMatch({error, _}, Result)
      end, HeaderInputs),
    Base = policy_config(#{}),
    ?assertEqual({error, invalid_policy},
                 adk_jwt_policy:new(
                   Base#{required_scopes => [<<"agent.run">> | bad]})),
    ?assertEqual({error, invalid_policy},
                 adk_jwt_policy:new(
                   Base#{trusted_audiences => [<<"shared">> | bad]})),
    ?assertEqual({error, invalid_context},
                 adk_auth_provider_oidcc:refresh(
                   #{kind => oauth_client_credentials,
                     client_id => <<"service">>,
                     client_secret => <<"secret">>},
                   (oauth_context())#{scopes => [<<"scope">> | bad]})).

unsafe_policies_are_rejected() ->
    Base = policy_config(#{}),
    ?assertEqual({error, invalid_policy},
                 adk_jwt_policy:new(Base#{issuer => <<"http://issuer.example">>})),
    ?assertEqual({error, invalid_policy},
                 adk_jwt_policy:new(Base#{signing_algs => [<<"HS256">>]})),
    ?assertEqual({error, invalid_policy},
                 adk_jwt_policy:new(Base#{signing_algs => [<<"none">>]})),
    ?assertEqual({error, invalid_policy},
                 adk_jwt_policy:new(Base#{clock_skew_seconds => 301})),
    ?assertEqual({error, invalid_policy},
                 adk_jwt_policy:new(
                   Base#{claim_allowlist => [<<"sub">>, <<"access_token">>]})),
    ?assertEqual({error, invalid_policy},
                 adk_jwt_policy:new(Base#{provider => <<"dynamic-name">>})).

missing_oidcc_worker_is_reported_without_network() ->
    {ok, Policy} = adk_jwt_policy:new(
                     (policy_config(#{}))#{
                       verifier => adk_oidcc_jwt_verifier,
                       provider => adk_oidc_missing_provider_fixture}),
    Token = token(<<"RS256">>, claims(#{})),
    ?assertEqual({error, provider_unavailable},
                 authenticate(Policy, Token)).

client_credentials_grant_is_normalized() ->
    Credential = #{kind => oauth_client_credentials,
                   client_id => <<"service-a">>,
                   client_secret => <<"service-a-secret">>},
    {ok, Token} = adk_auth_provider_oidcc:refresh(
                    Credential, oauth_context()),
    ?assertEqual(<<"cc:service-a">>, maps:get(access_token, Token)),
    ?assertEqual(60000, maps:get(expires_in_ms, Token)),
    ?assertEqual(<<"Bearer">>, maps:get(token_type, Token)).

refresh_grant_requires_subject_and_is_normalized() ->
    Credential = #{kind => oauth_refresh_token,
                   client_id => <<"service-b">>,
                   client_secret => <<"service-b-secret">>,
                   refresh_token => <<"stored-refresh-token">>,
                   expected_subject => <<"subject-b">>},
    Context = (oauth_context())#{credential_rotator =>
                                    fun(_Expected, _NewRefreshToken) -> ok end},
    {ok, Token} = adk_auth_provider_oidcc:refresh(Credential, Context),
    ?assertEqual(<<"refresh:service-b:subject-b">>,
                 maps:get(access_token, Token)),
    ?assertNot(maps:is_key(refresh_token, Token)),
    ?assertEqual({error, invalid_credential},
                 adk_auth_provider_oidcc:refresh(
                   maps:remove(expected_subject, Credential),
                   oauth_context())).

api_keys_and_bearer_tokens_are_distinct() ->
    ?assertEqual({error, unsupported_credential_kind},
                 adk_auth_provider_oidcc:refresh(
                   #{kind => api_key, api_key => <<"not-oauth">>},
                   oauth_context())),
    ?assertEqual({error, unsupported_credential_kind},
                 adk_auth_provider_oidcc:refresh(
                   #{kind => bearer_token, access_token => <<"incoming">>},
                   oauth_context())),
    ?assertEqual({error, invalid_credential},
                 adk_auth_provider_oidcc:refresh(
                   #{kind => oauth_client_credentials,
                     client_id => <<"mixed">>,
                     client_secret => <<"service-secret">>,
                     api_key => <<"must-not-mix">>},
                   oauth_context())).

oauth_adapter_failure_is_redacted() ->
    Secret = <<"leaky-client-secret">>,
    Credential = #{kind => oauth_client_credentials,
                   client_id => <<"service-c">>,
                   client_secret => Secret},
    {error, Reason} = adk_auth_provider_oidcc:refresh(
                        Credential, oauth_context()),
    assert_absent(Secret, Reason),
    ?assertNotEqual(nomatch,
                    binary:match(term_to_binary(Reason),
                                 adk_secret_redactor:marker())).

opaque_credentials_remain_user_isolated() ->
    Store = adk_oidc_security_store,
    RefreshSup = adk_oidc_security_refresh_sup,
    Manager = adk_oidc_security_token_manager,
    {ok, Supervisor} = adk_auth_sup:start_link(
                         #{name => undefined,
                           credential_store_name => Store,
                           refresh_sup_name => RefreshSup,
                           token_manager_name => Manager}),
    unlink(Supervisor),
    try
        {ok, AliceRef} = adk_credential_store_ets:put(
                           Store, <<"alice">>, <<"oidc-service">>,
                           #{kind => oauth_client_credentials,
                             client_id => <<"alice-service">>,
                             client_secret => <<"alice-secret">>}),
        Request = #{principal => <<"alice">>,
                    provider => <<"oidc-service">>,
                    provider_module => adk_auth_provider_oidcc,
                    credential_ref => AliceRef,
                    scopes => [<<"agent.run">>],
                    context => oauth_context()},
        {ok, #{access_token := <<"cc:alice-service">>}} =
            adk_token_manager:get_token(Manager, Request, 1000),
        BobRequest = Request#{principal => <<"bob">>},
        ?assertEqual({error, credential_not_found},
                     adk_token_manager:get_token(
                       Manager, BobRequest, 1000)),
        ?assert(adk_credential_store:is_ref(AliceRef)),
        assert_absent(<<"alice-secret">>, AliceRef)
    after
        stop_supervisor(Supervisor)
    end.

provider_child_is_explicit_and_secret_free() ->
    {ok, [Child]} = adk_oidc_provider_sup:provider_children(
                      [#{name => oidc_google_fixture,
                         issuer => <<"https://accounts.google.com">>}]),
    ?assertEqual({oidcc_provider_configuration, oidc_google_fixture},
                 maps:get(id, Child)),
    {oidcc_provider_configuration_worker, start_link, [WorkerOpts]} =
        maps:get(start, Child),
    ?assertEqual({local, oidc_google_fixture}, maps:get(name, WorkerOpts)),
    ?assertEqual(random_exponential, maps:get(backoff_type, WorkerOpts)),
    ?assertNot(maps:is_key(client_secret, WorkerOpts)).

insecure_or_secret_bearing_provider_config_is_rejected() ->
    ?assertEqual({error, invalid_provider_config},
                 adk_oidc_provider_sup:provider_children(
                   [#{name => insecure_oidc_fixture,
                      issuer => <<"http://issuer.example">>}])),
    ?assertEqual({error, invalid_provider_config},
                 adk_oidc_provider_sup:provider_children(
                   [#{name => secret_oidc_fixture,
                      issuer => ?ISSUER,
                      provider_configuration_opts =>
                          #{request_opts =>
                                #{headers =>
                                      #{<<"authorization">> =>
                                            <<"Bearer secret">>}}}}])),
    ?assertEqual({error, invalid_provider_config},
                 adk_oidc_provider_sup:provider_children(
                   [#{name => duplicate_oidc_fixture, issuer => ?ISSUER},
                    #{name => duplicate_oidc_fixture,
                      issuer => <<"https://other.example">>}])).

empty_provider_supervisor_is_network_free() ->
    {ok, Supervisor} = adk_oidc_provider_sup:start_link(#{name => undefined}),
    unlink(Supervisor),
    try
        ?assertEqual([], supervisor:which_children(Supervisor))
    after
        stop_supervisor(Supervisor)
    end.

policy(Overrides) ->
    {ok, Policy} = adk_jwt_policy:new(policy_config(Overrides)),
    Policy.

policy_config(Overrides) ->
    Base = #{issuer => ?ISSUER,
             audience => ?AUDIENCE,
             trusted_audiences => [<<"shared-api">>],
             signing_algs => [<<"RS256">>, <<"PS256">>],
             clock_skew_seconds => 5,
             required_scopes => [<<"agent.run">>],
             provider => oidc_fixture_provider,
             verifier => adk_oidc_fake_verifier,
             now_fun => fun() -> ?NOW end},
    maps:merge(Base, Overrides).

claims(Overrides) ->
    Base = #{<<"iss">> => ?ISSUER,
             <<"aud">> => ?AUDIENCE,
             <<"sub">> => <<"alice">>,
             <<"exp">> => ?NOW + 100,
             <<"nbf">> => ?NOW - 100,
             <<"iat">> => ?NOW - 100,
             <<"scope">> => <<"agent.run profile">>,
             <<"unapproved">> => <<"not-returned">>},
    maps:merge(Base, Overrides).

token(Algorithm, Claims) ->
    Header = jsx:encode(#{<<"alg">> => Algorithm, <<"typ">> => <<"JWT">>}),
    Payload = jsx:encode(Claims),
    <<(base64url(Header))/binary, ".", (base64url(Payload))/binary,
      ".fixture">>.

signed_token(PrivateKey, Claims) ->
    Jwt = jose_jwt:from(Claims),
    {_Modules, Compact} = jose_jws:compact(
                            jose_jwt:sign(
                              PrivateKey,
                              #{<<"alg">> => <<"RS256">>,
                                <<"typ">> => <<"JWT">>},
                              Jwt)),
    Compact.

tamper_subject(Signed) ->
    [Header, _Payload, Signature] = binary:split(Signed, <<".">>, [global]),
    Now = erlang:system_time(second),
    TamperedClaims = #{<<"iss">> => ?ISSUER,
                       <<"aud">> => ?AUDIENCE,
                       <<"sub">> => <<"tampered">>,
                       <<"exp">> => Now + 120,
                       <<"iat">> => Now - 1,
                       <<"scope">> => <<"agent.run">>},
    Payload = base64url(jsx:encode(TamperedClaims)),
    <<Header/binary, ".", Payload/binary, ".", Signature/binary>>.

base64url(Binary) ->
    Encoded0 = base64:encode(Binary),
    Encoded1 = binary:replace(Encoded0, <<"+">>, <<"-">>, [global]),
    Encoded2 = binary:replace(Encoded1, <<"/">>, <<"_">>, [global]),
    binary:replace(Encoded2, <<"=">>, <<>>, [global]).

authenticate(Policy, Token) ->
    adk_jwt_policy:authenticate(
      Policy, #{<<"authorization">> => <<"Bearer ", Token/binary>>}).

oauth_context() ->
    #{provider_worker => oidc_fixture_provider,
      oauth_adapter => adk_oidc_fake_oauth_adapter,
      scopes => [<<"agent.run">>]}.

stop_supervisor(Supervisor) ->
    Monitor = erlang:monitor(process, Supervisor),
    exit(Supervisor, shutdown),
    receive
        {'DOWN', Monitor, process, Supervisor, _Reason} -> ok
    after 1000 ->
        error(supervisor_did_not_stop)
    end.

assert_absent(Secret, Term) ->
    ?assertEqual(nomatch, binary:match(term_to_binary(Term), Secret)).
