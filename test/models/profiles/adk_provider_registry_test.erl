-module(adk_provider_registry_test).

-include_lib("eunit/include/eunit.hrl").

configured_binary_profile_resolves_alias_test() ->
    with_profiles(
      #{<<"openai-prod">> => base_profile()},
      fun() ->
          {ok, Profiles} = adk_provider_registry:profiles(),
          ?assertEqual([<<"openai-prod">>], maps:keys(Profiles)),
          {ok, Resolved} = adk_provider_registry:resolve(
                             <<"openai-prod">>, <<"chat">>),
          ?assertEqual(profile, maps:get(kind, Resolved)),
          ?assertEqual(adk_llm_dummy, maps:get(adapter, Resolved)),
          ?assertEqual(<<"model-from-profile">>,
                       maps:get(model, Resolved))
      end).

profile_config_keeps_operator_authority_test() ->
    with_profiles(
      #{<<"openai-prod">> => base_profile()},
      fun() ->
          {ok, Resolved} = adk_provider_registry:resolve_config(
                             #{provider => <<"openai-prod">>,
                               model => <<"chat">>,
                               temperature => 0.2}),
          ?assertEqual(#{temperature => 0.2},
                       maps:get(options, Resolved)),
          ?assertEqual(
             {error, provider_profile_override_not_allowed},
             adk_provider_registry:resolve_config(
               #{provider => <<"openai-prod">>,
                 model => <<"chat">>,
                 endpoint => anthropic})),
          ?assertEqual(
             {error, provider_profile_override_not_allowed},
             adk_provider_registry:resolve_config(
               #{provider => <<"openai-prod">>,
                 model => <<"chat">>,
                 api_key => <<"caller-secret">>}))
      end).

atom_provider_configuration_remains_legacy_test() ->
    Config = #{provider => adk_llm_dummy,
               model => <<"legacy-model">>},
    ?assertEqual(
       {ok, #{kind => legacy, adapter => adk_llm_dummy,
              config => Config}},
       adk_provider_registry:resolve_config(Config)).

unknown_binary_does_not_create_an_atom_test() ->
    Unknown = <<"provider_id_that_must_never_become_an_atom_918273645">>,
    ?assertError(badarg, binary_to_existing_atom(Unknown, utf8)),
    with_profiles(
      #{<<"openai-prod">> => base_profile()},
      fun() ->
          ?assertEqual({error, unknown_provider_profile},
                       adk_provider_registry:lookup(Unknown)),
          ?assertError(badarg, binary_to_existing_atom(Unknown, utf8))
      end).

invalid_application_profiles_fail_without_echoing_profile_test() ->
    Secret = <<"invalid-profile-secret-must-not-leak">>,
    with_profiles(
      #{<<"bad">> => (base_profile())#{
                         credential => {literal, Secret},
                         endpoint => <<"https://invalid">>}},
      fun() ->
          Result = adk_provider_registry:profiles(),
          ?assertMatch({error, {invalid_provider_profile,
                                <<"bad">>, invalid_provider_endpoint}},
                       Result),
          ?assertEqual(nomatch,
                       binary:match(term_to_binary(Result), Secret))
      end).

missing_alias_is_explicit_test() ->
    with_profiles(
      #{<<"openai-prod">> => base_profile()},
      fun() ->
          ?assertEqual(
             {error, missing_provider_model_alias},
             adk_provider_registry:resolve_config(
               #{provider => <<"openai-prod">>}))
      end).

base_profile() ->
    #{request_adapter => adk_llm_dummy,
      endpoint => openai,
      models => #{<<"chat">> => <<"model-from-profile">>},
      credential => {env, "ERLANG_ADK_TEST_PROVIDER_KEY"}}.

with_profiles(Profiles, Fun) ->
    Previous = application:get_env(erlang_adk, provider_profiles),
    ok = application:set_env(erlang_adk, provider_profiles, Profiles),
    try Fun()
    after restore_env(provider_profiles, Previous)
    end.

restore_env(Key, undefined) -> application:unset_env(erlang_adk, Key);
restore_env(Key, {ok, Value}) -> application:set_env(erlang_adk, Key, Value).
