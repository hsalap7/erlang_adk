-module(adk_provider_vertex_test).

-include_lib("eunit/include/eunit.hrl").

-define(RESOURCE,
        <<"projects/adk-demo/locations/us-central1/",
          "publishers/google/models/gemini-test">>).

vertex_profile_is_secret_free_and_snapshot_resolves_adc_marker_test() ->
    Profile = vertex_profile(),
    with_profiles(
      #{<<"vertex-prod">> => Profile},
      fun() ->
          {ok, Normalized} = adk_provider_registry:lookup(
                               <<"vertex-prod">>),
          ?assertEqual(vertex, maps:get(endpoint, Normalized)),
          ?assertEqual(#{source => google_adc},
                       maps:get(credential, Normalized)),
          Snapshot = maps:get(profile_snapshot, Normalized),
          ?assertEqual(
             {ok, google_adc},
             adk_provider_credential:resolve_snapshot(
               <<"vertex-prod">>, Snapshot)),
          ok = application:set_env(
                 erlang_adk, provider_profiles,
                 #{<<"vertex-prod">> =>
                       Profile#{capabilities => #{streaming => false}}}),
          ?assertEqual(
             {error, provider_profile_changed},
             adk_provider_credential:resolve_snapshot(
               <<"vertex-prod">>, Snapshot))
      end).

profile_validation_materializes_adc_lazily_test() ->
    with_profiles(
      #{<<"vertex-prod">> => vertex_profile()},
      fun() ->
          Config = #{provider => <<"vertex-prod">>,
                     model => <<"chat">>, temperature => 0.2},
          ?assertEqual(ok, adk_llm:validate_config(Config)),
          %% Config validation checks the ADC contract but must never invoke
          %% gcloud or a token provider.
          receive google_adc_requested -> ?assert(false) after 0 -> ok end,
          {ok, Resolved} = adk_provider_registry:resolve_config(Config),
          ?assertEqual(adk_llm_vertex, maps:get(adapter, Resolved)),
          ?assertEqual(?RESOURCE, maps:get(model, Resolved)),
          ?assertEqual(#{temperature => 0.2},
                       maps:get(options, Resolved))
      end).

profile_callers_cannot_override_vertex_authority_test() ->
    with_profiles(
      #{<<"vertex-prod">> => vertex_profile()},
      fun() ->
          Base = #{provider => <<"vertex-prod">>, model => <<"chat">>},
          lists:foreach(
            fun({Key, Value}) ->
                ?assertEqual(
                   {error, provider_profile_override_not_allowed},
                   adk_provider_registry:resolve_config(Base#{Key => Value}))
            end,
            [{base_url, <<"https://attacker.invalid">>},
             {http_transport, {adk_model_fixture_transport, ignored}},
             {adc_token_provider, {adk_google_adc_fixture, ignored}},
             {credential_source, google_adc},
             {allow_private_hosts, true},
             {candidate_count, 2},
             {thinking_config, #{thinking_level => high}},
             {builtin_tools, [google_search]},
             {context_cache, #{}}])
      end).

vertex_profile_capabilities_cannot_raise_adapter_ceiling_test() ->
    Profile = (vertex_profile())#
      {capabilities =>
           #{streaming => true,
             live => true,
             context_caching => true,
             google_search_grounding => true}},
    with_profiles(
      #{<<"vertex-prod">> => Profile},
      fun() ->
          {ok, Capabilities} = adk_llm:capabilities(
                                 #{provider => <<"vertex-prod">>,
                                   model => <<"chat">>}),
          ?assertEqual(true, maps:get(streaming, Capabilities)),
          ?assertEqual(false, maps:get(live, Capabilities)),
          ?assertEqual(false, maps:get(context_caching, Capabilities)),
          ?assertEqual(false,
                       maps:is_key(google_search_grounding, Capabilities))
      end).

vertex_endpoint_credential_and_resource_contract_is_strict_test() ->
    Profile = vertex_profile(),
    Custom = #{scheme => https, host => <<"aiplatform.googleapis.com">>,
               port => 443, base_path => <<"/v1">>},
    Invalid = [
        {Profile#{endpoint => gemini}, provider_request_endpoint_mismatch},
        {Profile#{endpoint => Custom}, provider_request_endpoint_mismatch},
        {Profile#{credential => none}, vertex_oauth_credential_required},
        {Profile#{live_adapter => adk_live_gemini},
         vertex_live_not_supported},
        {Profile#{models => #{<<"chat">> => <<"gemini-test">>}},
         invalid_vertex_model_resource},
        {#{request_adapter => adk_llm_gemini,
           endpoint => gemini,
           models => #{<<"chat">> => <<"gemini-test">>},
           credential => google_adc},
         google_adc_requires_vertex_request_adapter}
    ],
    lists:foreach(
      fun({Candidate, Reason}) ->
          ?assertEqual(
             {error, Reason},
             adk_provider_profile:validate(<<"vertex-invalid">>, Candidate))
      end, Invalid).

vertex_profile() ->
    #{request_adapter => adk_llm_vertex,
      endpoint => vertex,
      models => #{<<"chat">> => ?RESOURCE},
      credential => google_adc}.

with_profiles(Profiles, Fun) ->
    Previous = application:get_env(erlang_adk, provider_profiles),
    ok = application:set_env(erlang_adk, provider_profiles, Profiles),
    try Fun()
    after restore_app_env(provider_profiles, Previous)
    end.

restore_app_env(Key, undefined) -> application:unset_env(erlang_adk, Key);
restore_app_env(Key, {ok, Value}) ->
    application:set_env(erlang_adk, Key, Value).
