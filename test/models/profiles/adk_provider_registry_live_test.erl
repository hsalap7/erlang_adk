-module(adk_provider_registry_live_test).

-include_lib("eunit/include/eunit.hrl").

live_profile_resolution_is_operator_owned_test() ->
    Secret = <<"live-profile-secret-must-not-leak">>,
    with_profiles(
      #{<<"openai-live">> => openai_profile(Secret)},
      fun() ->
          {ok, Resolved} = adk_provider_registry:resolve_live_config(
                             <<"openai-live">>,
                             #{model => <<"voice">>,
                               response_modalities => [text],
                               system_instruction => <<"Be concise">>}),
          ?assertEqual(adk_live_openai, maps:get(adapter, Resolved)),
          ?assertEqual(adk_live_openai_gun_transport,
                       maps:get(transport, Resolved)),
          ?assertEqual(openai, maps:get(endpoint, Resolved)),
          ?assertEqual(<<"gpt-realtime-profile-id">>,
                       maps:get(model, Resolved)),
          ?assertEqual(
             #{response_modalities => [text],
               system_instruction => <<"Be concise">>},
             maps:get(options, Resolved)),
          ?assertEqual(#{source => literal},
                       maps:get(credential, Resolved)),
          ?assertEqual(nomatch,
                       binary:match(term_to_binary(Resolved), Secret))
      end).

live_profile_authority_overrides_are_rejected_test() ->
    Secret = <<"profile-authority-secret">>,
    with_profiles(
      #{<<"openai-live">> => openai_profile(Secret)},
      fun() ->
          Base = #{model => <<"voice">>},
          lists:foreach(
            fun(Override) ->
                ?assertEqual(
                   {error, provider_profile_override_not_allowed},
                   adk_provider_registry:resolve_live_config(
                     <<"openai-live">>, maps:merge(Base, Override)))
            end,
            [#{api_key => <<"caller-key">>},
             #{credential_ref => make_ref()},
             #{endpoint => anthropic},
             #{transport => adk_live_fake_transport},
             #{model_id => <<"caller-model-id">>},
             #{input_audio_sample_rate => 8000}]),
          ?assertEqual(
             {error, missing_provider_model_alias},
             adk_provider_registry:resolve_live_config(
               <<"openai-live">>, #{}))
      end).

live_profile_endpoint_mismatch_fails_closed_test() ->
    Profile = (openai_profile(<<"secret">>))#{endpoint => anthropic},
    with_profiles(
      #{<<"mismatched-live">> => Profile},
      fun() ->
          ?assertEqual(
             {error, provider_profile_live_endpoint_not_supported},
             adk_provider_registry:resolve_live_config(
               <<"mismatched-live">>, #{model => <<"voice">>}))
      end).

unknown_live_profile_never_creates_an_atom_test() ->
    Unknown = <<"unknown_live_profile_that_must_not_become_atom_73519">>,
    ?assertError(badarg, binary_to_existing_atom(Unknown, utf8)),
    with_profiles(
      #{<<"openai-live">> => openai_profile(<<"secret">>)},
      fun() ->
          ?assertEqual(
             {error, unknown_provider_profile},
             adk_provider_registry:resolve_live_config(
               Unknown, #{model => <<"voice">>})),
          ?assertError(badarg, binary_to_existing_atom(Unknown, utf8))
      end).

openai_profile(Secret) ->
    #{live_adapter => adk_live_openai,
      endpoint => openai,
      models => #{<<"voice">> => <<"gpt-realtime-profile-id">>},
      credential => {literal, Secret},
      capabilities => #{live => true}}.

with_profiles(Profiles, Fun) ->
    Previous = application:get_env(erlang_adk, provider_profiles),
    ok = application:set_env(erlang_adk, provider_profiles, Profiles),
    try Fun()
    after restore_env(provider_profiles, Previous)
    end.

restore_env(Key, undefined) -> application:unset_env(erlang_adk, Key);
restore_env(Key, {ok, Value}) -> application:set_env(erlang_adk, Key, Value).
