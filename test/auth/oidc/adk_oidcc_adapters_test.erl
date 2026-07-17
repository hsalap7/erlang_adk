-module(adk_oidcc_adapters_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("oidcc/include/oidcc_token.hrl").

-define(ISSUER, <<"https://oidcc-adapter.example">>).
-define(CLIENT_ID, <<"erlang-adk-client">>).
-define(CLIENT_SECRET, <<"client-secret">>).

oauth_adapter_test_() ->
    [fun oauth_options_are_translated_without_untrusted_extras/0,
     fun oauth_provider_failures_are_opaque_and_classified/0,
     fun oauth_tokens_are_normalized_and_bounded/0].

authorization_code_adapter_test_() ->
    [fun authorization_context_is_exact_and_bounded/0,
     fun authorization_uri_uses_s256_pkce_and_resource/0,
     fun authorization_failures_are_opaque/0,
     fun exchange_failures_are_opaque/0,
     fun validated_exchange_token_becomes_refresh_credential/0,
     fun malformed_exchange_tokens_fail_closed/0].

oauth_options_are_translated_without_untrusted_extras() ->
    ?assertEqual(
       #{scope => [<<"agent.run">>]},
       adk_oidcc_adapter_policy:oauth_opts(
         #{scope => [<<"agent.run">>], ignored => <<"value">>})),
    ?assertEqual(
       #{scope => [<<"agent.run">>],
         body_extension =>
             [{<<"resource">>, <<"https://api.example">>}]},
       adk_oidcc_adapter_policy:oauth_opts(
         #{scope => [<<"agent.run">>],
           resource => <<"https://api.example">>})).

oauth_provider_failures_are_opaque_and_classified() ->
    MissingProvider = unique_provider(),
    ?assertEqual(
       {error, provider_unavailable},
       adk_oidcc_oauth_adapter:client_credentials(
         MissingProvider, ?CLIENT_ID, ?CLIENT_SECRET,
         #{scope => [<<"agent.run">>]})),
    ?assertEqual(
       {error, provider_unavailable},
       adk_oidcc_oauth_adapter:refresh_token(
         MissingProvider, ?CLIENT_ID, ?CLIENT_SECRET,
         <<"refresh-token">>, <<"subject">>,
         #{scope => [<<"agent.run">>],
           resource => <<"https://api.example">>})),
    ?assertEqual(
       {error, oauth_request_failed},
       adk_oidcc_oauth_adapter:client_credentials(
         {invalid, provider}, ?CLIENT_ID, ?CLIENT_SECRET,
         #{scope => []})),
    with_provider(
      fun(Provider) ->
          %% The offline fixture intentionally advertises no client-
          %% credentials grant, so Oidcc rejects it before any HTTP request.
          ?assertEqual(
             {error, oauth_request_failed},
             adk_oidcc_oauth_adapter:client_credentials(
               Provider, ?CLIENT_ID, ?CLIENT_SECRET,
               #{scope => [<<"agent.run">>]}))
      end).

oauth_tokens_are_normalized_and_bounded() ->
    Base = #oidcc_token{
              access = #oidcc_token_access{
                          token = <<"access-token">>,
                          expires = 60,
                          type = <<"Bearer">>},
              refresh = none},
    ?assertEqual(
       {ok, #{access_token => <<"access-token">>,
              expires_in_ms => 60000,
              token_type => <<"Bearer">>}},
       adk_oidcc_adapter_policy:normalize_oauth_token(Base)),
    Rotated = Base#oidcc_token{
                refresh = #oidcc_token_refresh{token = <<"new-refresh">>}},
    ?assertEqual(
       {ok, #{access_token => <<"access-token">>,
              expires_in_ms => 60000,
              token_type => <<"Bearer">>,
              refresh_token => <<"new-refresh">>}},
       adk_oidcc_adapter_policy:normalize_oauth_token(Rotated)),
    InvalidTokens =
        [not_a_token,
         #oidcc_token{access = none, refresh = none},
         Base#oidcc_token{
           access = #oidcc_token_access{
                       token = <<>>, expires = 60, type = <<"Bearer">>}},
         Base#oidcc_token{
           access = #oidcc_token_access{
                       token = <<"access">>, expires = 0,
                       type = <<"Bearer">>}},
         Base#oidcc_token{
           access = #oidcc_token_access{
                       token = <<"access">>, expires = 60, type = <<>>}},
         Base#oidcc_token{
           refresh = #oidcc_token_refresh{token = <<>>}},
         Base#oidcc_token{refresh = invalid_refresh_record}],
    lists:foreach(
      fun(Token) ->
          ?assertEqual(
             {error, invalid_token_response},
             adk_oidcc_adapter_policy:normalize_oauth_token(Token))
      end, InvalidTokens).

authorization_context_is_exact_and_bounded() ->
    Valid = #{provider_worker => unique_provider(),
              client_id => ?CLIENT_ID,
              client_secret => ?CLIENT_SECRET},
    ?assertEqual(ok,
                 adk_oidcc_authorization_code_adapter:validate_context(Valid)),
    with_provider(
      fun(Provider) ->
          ?assertEqual(
             ok,
             adk_oidcc_authorization_code_adapter:validate_context(
               Valid#{provider_worker => Provider}))
      end),
    Invalid =
        [undefined,
         #{},
         Valid#{provider_worker => undefined},
         Valid#{provider_worker => <<"provider">>},
         Valid#{client_id => not_binary},
         Valid#{client_id => <<>>},
         Valid#{client_secret => <<>>},
         Valid#{client_id => binary:copy(<<"i">>, 4097)},
         Valid#{client_secret => binary:copy(<<"s">>, 16385)},
         Valid#{extra => not_allowed}],
    lists:foreach(
      fun(Context) ->
          ?assertEqual(
             {error, invalid_adapter_context},
             adk_oidcc_authorization_code_adapter:validate_context(Context))
      end, Invalid).

authorization_uri_uses_s256_pkce_and_resource() ->
    with_provider(
      fun(Provider) ->
          Verifier = binary:copy(<<"v">>, 64),
          Resource = <<"https://api.example/agents">>,
          Opts = (flow_opts())#{pkce_verifier => Verifier,
                                resource => Resource},
          {ok, Uri} =
              adk_oidcc_authorization_code_adapter:authorization_uri(
                context(Provider), Opts),
          ?assert(is_binary(Uri)),
          Query = query_map(Uri),
          ?assertEqual(?CLIENT_ID, maps:get(<<"client_id">>, Query)),
          ?assertEqual(maps:get(state, Opts), maps:get(<<"state">>, Query)),
          ?assertEqual(maps:get(nonce, Opts), maps:get(<<"nonce">>, Query)),
          ?assertEqual(Resource, maps:get(<<"resource">>, Query)),
          ?assertEqual(<<"S256">>,
                       maps:get(<<"code_challenge_method">>, Query)),
          ExpectedChallenge =
              base64:encode(crypto:hash(sha256, Verifier),
                            #{mode => urlsafe, padding => false}),
          ?assertEqual(ExpectedChallenge,
                       maps:get(<<"code_challenge">>, Query)),
          ?assertNot(maps:is_key(<<"pkce_verifier">>, Query))
      end).

authorization_failures_are_opaque() ->
    ?assertEqual(
       {error, authorization_unavailable},
       adk_oidcc_authorization_code_adapter:authorization_uri(
         invalid_context, flow_opts())),
    ?assertEqual(
       {error, authorization_unavailable},
       adk_oidcc_authorization_code_adapter:authorization_uri(
         context(unique_provider()), flow_opts())),
    ?assertEqual(
       {error, authorization_unavailable},
       adk_oidcc_authorization_code_adapter:authorization_uri(
         context({invalid, provider}), flow_opts())),
    with_provider(
      fun(Provider) ->
          Oversized =
              (flow_opts())#{redirect_uri => binary:copy(<<"x">>, 8193)},
          ?assertEqual(
             {error, authorization_unavailable},
             adk_oidcc_authorization_code_adapter:authorization_uri(
               context(Provider), Oversized))
      end).

exchange_failures_are_opaque() ->
    ?assertEqual(
       {error, authorization_failed},
       adk_oidcc_authorization_code_adapter:exchange_code(
         invalid_context, <<"code">>, flow_opts())),
    ?assertEqual(
       {error, authorization_failed},
       adk_oidcc_authorization_code_adapter:exchange_code(
         context(unique_provider()), <<"code">>, flow_opts())),
    ?assertEqual(
       {error, authorization_failed},
       adk_oidcc_authorization_code_adapter:exchange_code(
         context({invalid, provider}), <<"code">>,
         (flow_opts())#{resource => <<"https://api.example">>})),
    ?assertEqual(
       {error, authorization_failed},
       adk_oidcc_authorization_code_adapter:exchange_code(
         context(unique_provider()), <<>>, flow_opts())).

validated_exchange_token_becomes_refresh_credential() ->
    Token = exchange_token(#{<<"sub">> => <<"provider-subject">>}),
    ?assertEqual(
       {ok, #{kind => oauth_refresh_token,
              client_id => ?CLIENT_ID,
              client_secret => ?CLIENT_SECRET,
              refresh_token => <<"refresh-token">>,
              expected_subject => <<"provider-subject">>}},
       adk_oidcc_adapter_policy:validated_refresh_credential(
           Token, ?CLIENT_ID, ?CLIENT_SECRET)).

malformed_exchange_tokens_fail_closed() ->
    Base = exchange_token(#{<<"sub">> => <<"provider-subject">>}),
    #oidcc_token{id = Id, access = Access, refresh = Refresh} = Base,
    InvalidTokens =
        [not_a_token,
         Base#oidcc_token{id = none},
         Base#oidcc_token{id = Id#oidcc_token_id{token = <<>>}},
         Base#oidcc_token{id = Id#oidcc_token_id{claims = not_a_map}},
         Base#oidcc_token{id =
             Id#oidcc_token_id{claims = #{<<"missing-sub">> => true}}},
         Base#oidcc_token{id =
             Id#oidcc_token_id{claims = #{<<"sub">> => <<>>}}},
         Base#oidcc_token{id =
             Id#oidcc_token_id{
               claims = #{<<"sub">> => binary:copy(<<"s">>, 4097)}}},
         Base#oidcc_token{access = none},
         Base#oidcc_token{access =
             Access#oidcc_token_access{token = <<>>}},
         Base#oidcc_token{access =
             Access#oidcc_token_access{type = <<>>}},
         Base#oidcc_token{access =
             Access#oidcc_token_access{type = binary:copy(<<"t">>, 129)}},
         Base#oidcc_token{refresh = none},
         Base#oidcc_token{refresh =
             Refresh#oidcc_token_refresh{token = <<>>}},
         Base#oidcc_token{refresh =
             Refresh#oidcc_token_refresh{
               token = binary:copy(<<"r">>, 65537)}},
         Base#oidcc_token{id =
             Id#oidcc_token_id{
               claims = #{<<"sub">> => <<"provider-subject">>,
                          <<"padding">> =>
                              binary:copy(<<"x">>, 1048576)}}}],
    lists:foreach(
      fun(Token) ->
          ?assertEqual(
             {error, authorization_failed},
             adk_oidcc_adapter_policy:validated_refresh_credential(
                 Token, ?CLIENT_ID, ?CLIENT_SECRET))
      end, InvalidTokens).

context(Provider) ->
    #{provider_worker => Provider,
      client_id => ?CLIENT_ID,
      client_secret => ?CLIENT_SECRET}.

flow_opts() ->
    #{state => <<"state-binding">>,
      nonce => <<"nonce-binding">>,
      pkce_verifier => binary:copy(<<"p">>, 64),
      redirect_uri => <<"https://client.example/callback">>,
      scopes => [<<"openid">>, <<"profile">>]}.

exchange_token(Claims) ->
    #oidcc_token{
       id = #oidcc_token_id{token = <<"validated-id-token">>,
                            claims = Claims},
       access = #oidcc_token_access{token = <<"access-token">>,
                                    expires = 60,
                                    type = <<"Bearer">>},
       refresh = #oidcc_token_refresh{token = <<"refresh-token">>},
       scope = [<<"openid">>]}.

query_map(Uri) ->
    Parsed = uri_string:parse(Uri),
    maps:from_list(uri_string:dissect_query(maps:get(query, Parsed))).

with_provider(Fun) ->
    Jwks = jose_jwk:generate_key({rsa, 2048}),
    {ok, Provider} = adk_oidcc_fixture_provider:start_link(?ISSUER, Jwks),
    try Fun(Provider)
    after
        gen_server:stop(Provider)
    end.

unique_provider() ->
    missing_oidcc_adapter_provider.
