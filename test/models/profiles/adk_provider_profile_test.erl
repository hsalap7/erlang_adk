-module(adk_provider_profile_test).

-include_lib("eunit/include/eunit.hrl").

normalizes_trusted_profile_without_credential_value_test() ->
    Secret = <<"literal-profile-secret-must-not-leak">>,
    Profile = (base_profile())#{
                live_adapter => adk_live_gemini,
                credential => {literal, Secret},
                capabilities => #{streaming => true, live => false},
                models =>
                    #{<<"chat">> => <<"provider-chat-model">>,
                      <<"voice">> =>
                          #{id => <<"provider-live-model">>,
                            capabilities =>
                                #{live => true,
                                  input_modalities => [audio, text]}}}},
    {ok, Normalized} = adk_provider_profile:normalize(
                         <<"vendor-prod">>, Profile),
    ?assertEqual(#{source => literal},
                 maps:get(credential, Normalized)),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Normalized), Secret)),

    {ok, Request} = adk_provider_profile:request_config(
                      Normalized, <<"chat">>),
    ?assertEqual(adk_llm_dummy, maps:get(adapter, Request)),
    ?assertEqual(<<"provider-chat-model">>, maps:get(model, Request)),
    ?assertEqual(false, maps:get(live, maps:get(capabilities, Request))),

    {ok, Live} = adk_provider_profile:live_config(
                   Normalized, <<"voice">>),
    ?assertEqual(adk_live_gemini, maps:get(adapter, Live)),
    ?assertEqual(true, maps:get(live, maps:get(capabilities, Live))),
    ?assertEqual([audio, text],
                 maps:get(input_modalities,
                          maps:get(capabilities, Live))).

custom_endpoint_is_structured_https_only_test() ->
    Endpoint = #{scheme => https,
                 host => <<"api.vendor.example">>,
                 port => 443,
                 base_path => <<"/openai/v1">>},
    {ok, Profile} = adk_provider_profile:normalize(
                      <<"compatible">>,
                      (base_profile())#{endpoint => Endpoint}),
    ?assertEqual(Endpoint, maps:get(endpoint, Profile)),
    ?assertEqual(
       {error, invalid_provider_endpoint},
       adk_provider_profile:validate(
         <<"compatible">>,
         (base_profile())#{endpoint =>
                             <<"https://caller.example/v1">>})),
    ?assertEqual(
       {error, invalid_provider_endpoint},
       adk_provider_profile:validate(
         <<"compatible">>,
         (base_profile())#{endpoint =>
                             Endpoint#{base_path => <<"/v1/../admin">>}})).

keyless_loopback_http_is_an_explicit_compatible_only_profile_test() ->
    Endpoint = local_endpoint(),
    Profile = #{request_adapter => adk_llm_compatible,
                endpoint => Endpoint,
                models => #{<<"chat">> => <<"local-chat-model">>},
                credential => none,
                request_options => #{auth_scheme => none}},
    {ok, Normalized} = adk_provider_profile:normalize(
                         <<"local-compatible">>, Profile),
    ?assertEqual(Endpoint, maps:get(endpoint, Normalized)),
    ?assertEqual(
       {error, invalid_provider_endpoint},
       adk_provider_profile:validate(
         <<"local-compatible">>,
         Profile#{endpoint => Endpoint#{host => <<"localhost">>}})),
    ?assertEqual(
       {error, provider_request_endpoint_mismatch},
       adk_provider_profile:validate(
         <<"local-native">>,
         Profile#{request_adapter => adk_llm_openai,
                  request_options => #{}})),
    ?assertEqual(
       {error, local_model_endpoint_requires_no_credential},
       adk_provider_profile:validate(
         <<"local-authenticated">>,
         Profile#{credential => {env, "LOCAL_MODEL_KEY"}})),
    ?assertEqual(
       {error, local_model_endpoint_requires_keyless_auth},
       adk_provider_profile:validate(
         <<"local-bearer">>,
         Profile#{request_options => #{auth_scheme => bearer}})),
    ?assertEqual(
       {error, local_model_endpoint_live_not_supported},
       adk_provider_profile:validate(
         <<"local-live">>, Profile#{live_adapter => adk_live_openai})).

rejects_dynamic_or_incompatible_adapters_test() ->
    ?assertEqual(
       {error, invalid_request_adapter},
       adk_provider_profile:validate(
         <<"bad-adapter">>,
         (base_profile())#{request_adapter => <<"adk_llm_dummy">>})),
    ?assertEqual(
       {error, invalid_request_adapter},
       adk_provider_profile:validate(
         <<"bad-adapter">>,
         (base_profile())#{request_adapter => lists})),
    ?assertEqual(
       {error, request_adapter_unavailable},
       adk_provider_profile:validate(
         <<"bad-adapter">>,
         (base_profile())#{request_adapter =>
                             adk_provider_profile_missing_adapter})).

model_aliases_are_explicit_and_bounded_test() ->
    {ok, Profile} = adk_provider_profile:normalize(
                      <<"models">>, base_profile()),
    ?assertEqual(
       {error, unknown_provider_model_alias},
       adk_provider_profile:resolve_model(Profile, <<"raw-model-id">>)),
    ?assertEqual(
       {error, invalid_provider_model_alias},
       adk_provider_profile:resolve_model(Profile, raw_model_id)),
    ?assertEqual(
       {error, invalid_provider_model_alias},
       adk_provider_profile:validate(
         <<"models">>,
         (base_profile())#{models => #{<<"not/an/alias">> => <<"m">>}})).

unknown_profile_keys_fail_closed_test() ->
    ?assertEqual(
       {error, {unknown_provider_profile_options, [headers]}},
       adk_provider_profile:validate(
         <<"unknown">>, (base_profile())#{headers => []})).

base_profile() ->
    #{request_adapter => adk_llm_dummy,
      endpoint => openai,
      models => #{<<"chat">> => <<"provider-chat-model">>},
      credential => {env, "ERLANG_ADK_TEST_PROVIDER_KEY"}}.

local_endpoint() ->
    #{scheme => http,
      host => <<"127.0.0.1">>,
      port => 11434,
      base_path => <<"/v1">>,
      policy => loopback_keyless}.
