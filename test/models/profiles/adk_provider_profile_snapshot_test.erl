-module(adk_provider_profile_snapshot_test).

-include_lib("eunit/include/eunit.hrl").

request_rotation_never_resolves_a_cross_generation_credential_test() ->
    ProfileId = <<"rotating-request">>,
    SecretA = <<"request-generation-a-secret">>,
    SecretB = <<"request-generation-b-secret">>,
    ProfileA = request_profile(openai, <<"model-a">>, SecretA),
    ProfileB = request_profile(anthropic, <<"model-b">>, SecretB),
    with_profiles(
      #{ProfileId => ProfileA},
      fun() ->
          {ok, ResolvedA} = adk_provider_registry:resolve_config(
                              #{provider => ProfileId,
                                model => <<"chat">>,
                                temperature => 0.2}),
          SnapshotA = maps:get(profile_snapshot, ResolvedA),
          ?assertEqual(openai, maps:get(endpoint, ResolvedA)),
          ?assertEqual(<<"model-a">>, maps:get(model, ResolvedA)),
          ?assertEqual(nomatch,
                       binary:match(term_to_binary(ResolvedA), SecretA)),

          ok = application:set_env(
                 erlang_adk, provider_profiles,
                 #{ProfileId => ProfileB}),
          Changed = adk_provider_credential:resolve_snapshot(
                      ProfileId, SnapshotA),
          ?assertEqual({error, provider_profile_changed}, Changed),
          ?assertEqual(nomatch,
                       binary:match(term_to_binary(Changed), SecretA)),
          ?assertEqual(nomatch,
                       binary:match(term_to_binary(Changed), SecretB)),

          {ok, ResolvedB} = adk_provider_registry:resolve_config(
                              #{provider => ProfileId,
                                model => <<"chat">>,
                                temperature => 0.2}),
          SnapshotB = maps:get(profile_snapshot, ResolvedB),
          ?assertNotEqual(SnapshotA, SnapshotB),
          ?assertEqual({ok, SecretB},
                       adk_provider_credential:resolve_snapshot(
                         ProfileId, SnapshotB))
      end).

live_rotation_never_resolves_a_cross_generation_credential_test() ->
    ProfileId = <<"rotating-live">>,
    SecretA = <<"live-generation-a-secret">>,
    SecretB = <<"live-generation-b-secret">>,
    ProfileA = live_profile(<<"gpt-realtime-a">>, SecretA),
    ProfileB = live_profile(<<"gpt-realtime-b">>, SecretB),
    with_profiles(
      #{ProfileId => ProfileA},
      fun() ->
          {ok, ResolvedA} = adk_provider_registry:resolve_live_config(
                              ProfileId, #{model => <<"voice">>}),
          SnapshotA = maps:get(profile_snapshot, ResolvedA),
          ?assertEqual(<<"gpt-realtime-a">>,
                       maps:get(model, ResolvedA)),
          ok = application:set_env(
                 erlang_adk, provider_profiles,
                 #{ProfileId => ProfileB}),
          ?assertEqual(
             {error, provider_profile_changed},
             adk_provider_credential:resolve_snapshot(
               ProfileId, SnapshotA)),
          {ok, ResolvedB} = adk_provider_registry:resolve_live_config(
                              ProfileId, #{model => <<"voice">>}),
          SnapshotB = maps:get(profile_snapshot, ResolvedB),
          ?assertNotEqual(SnapshotA, SnapshotB),
          ?assertEqual({ok, SecretB},
                       adk_provider_credential:resolve_snapshot(
                         ProfileId, SnapshotB))
      end).

opaque_snapshot_exposes_neither_secret_nor_unkeyed_digest_test() ->
    ProfileId = <<"opaque-snapshot">>,
    Secret = <<"low-entropy-literal">>,
    Profile = request_profile(openai, <<"model-a">>, Secret),
    OldRawDigest = crypto:hash(
                     sha256,
                     term_to_binary(
                       {provider_profile, ProfileId, Profile},
                       [deterministic])),
    SecretDigest = crypto:hash(sha256, Secret),
    with_profiles(
      #{ProfileId => Profile},
      fun() ->
          {ok, Resolved} = adk_provider_registry:resolve_config(
                             #{provider => ProfileId,
                               model => <<"chat">>, temperature => 0.2}),
          Projection = term_to_binary(Resolved),
          ?assertEqual(nomatch, binary:match(Projection, Secret)),
          ?assertEqual(nomatch, binary:match(Projection, OldRawDigest)),
          ?assertEqual(nomatch, binary:match(Projection, SecretDigest)),
          Snapshot = maps:get(profile_snapshot, Resolved),
          ?assertNotEqual(OldRawDigest, Snapshot),
          ?assertEqual({ok, Secret},
                       adk_provider_credential:resolve_snapshot(
                         ProfileId, Snapshot))
      end).

request_profile(Endpoint, Model, Secret) ->
    #{request_adapter => adk_llm_dummy,
      endpoint => Endpoint,
      models => #{<<"chat">> => Model},
      credential => {literal, Secret}}.

live_profile(Model, Secret) ->
    #{live_adapter => adk_live_openai,
      endpoint => openai,
      models => #{<<"voice">> => Model},
      credential => {literal, Secret}}.

with_profiles(Profiles, Fun) ->
    Previous = application:get_env(erlang_adk, provider_profiles),
    ok = application:set_env(erlang_adk, provider_profiles, Profiles),
    try Fun()
    after restore_env(provider_profiles, Previous)
    end.

restore_env(Key, undefined) -> application:unset_env(erlang_adk, Key);
restore_env(Key, {ok, Value}) -> application:set_env(erlang_adk, Key, Value).
