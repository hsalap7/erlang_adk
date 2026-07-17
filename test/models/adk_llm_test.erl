-module(adk_llm_test).
-include_lib("eunit/include/eunit.hrl").

provider_capability_discovery_test() ->
    {ok, Gemini} = adk_llm:capabilities(adk_llm_gemini),
    ?assertEqual(true, maps:get(generate, Gemini)),
    ?assertEqual(true, maps:get(streaming, Gemini)),
    ?assertEqual(true, maps:get(function_calling, Gemini)),
    ?assertEqual(true, maps:get(structured_output, Gemini)),
    ?assertEqual(true, maps:get(multimodal, Gemini)),
    ?assertEqual(true, maps:get(content_streaming, Gemini)),
    ?assertEqual(true, maps:get(thinking, Gemini)),
    ?assertEqual(1, maps:get(content_schema_version, Gemini)),
    ?assertEqual(false, maps:get(live, Gemini)),

    %% Existing third-party providers do not need the optional callbacks.
    {ok, Legacy} = adk_llm:capabilities(adk_llm_dummy),
    ?assertEqual(#{generate => true, streaming => true}, Legacy).

provider_validation_errors_are_values_test() ->
    ?assertEqual({error, missing_llm_provider},
                 adk_llm:validate_config(#{})),
    ?assertEqual({error, {invalid_llm_provider, 42}},
                 adk_llm:validate_config(#{provider => 42})),
    ?assertMatch({error, {llm_provider_unavailable, _, _}},
                 adk_llm:validate_config(
                   #{provider => adk_provider_that_does_not_exist})),
    ?assertEqual({error, {invalid_llm_config, invalid}},
                 adk_llm:validate_config(invalid)).

live_gemini_wrapper_preserves_provider_contract_test() ->
    {ok, Capabilities} =
        adk_llm:capabilities(readme_live_gemini_SUITE),
    ?assertEqual(true, maps:get(generation_config, Capabilities)),
    ?assertEqual(true, maps:get(content_streaming, Capabilities)),
    ?assertEqual(
       ok,
       adk_llm:validate_config(
         #{provider => readme_live_gemini_SUITE,
           model => <<"gemini-3.1-flash-lite">>,
           max_tokens => 512,
           request_timeout => 15000})).

live_gemini_wrapper_recognizes_both_rate_limit_shapes_test() ->
    ?assert(
       readme_live_gemini_SUITE:retryable_rate_limit(
         {error, {http_status, 429, <<"must-not-be-logged">>}})),
    ?assert(
       readme_live_gemini_SUITE:retryable_rate_limit(
         {error, {adk_failure,
                  #{component => llm_provider,
                    operation => generate,
                    class => external,
                    status => 429,
                    reason => http_status}}})),
    ?assertNot(
       readme_live_gemini_SUITE:retryable_rate_limit(
         {error, {http_status, 503, <<"unavailable">>}})).

gemini_config_validation_and_redaction_test() ->
    Valid = #{provider => adk_llm_gemini,
              model => <<"gemini-3.1-flash-lite">>,
              response_mime_type => <<"application/json">>,
              response_schema => #{<<"type">> => <<"object">>},
              stop_sequences => [<<"STOP">>],
              max_tokens => 100,
              content_limits => #{max_inline_data_bytes => 1024,
                                  max_total_inline_data_bytes => 2048},
              request_timeout => 1000},
    ?assertEqual(ok, adk_llm:validate_config(Valid)),
    ?assertEqual(
       {error, {invalid_gemini_option, max_tokens, 0}},
       adk_llm:validate_config(Valid#{max_tokens => 0})),
    ?assertEqual(
       {error, {invalid_gemini_option,
                response_schema, not_json_safe}},
       adk_llm:validate_config(
         Valid#{response_schema => #{atom_key => <<"value">>}})),
    ?assertMatch(
       {error, {invalid_gemini_option, content_limits,
                {invalid_content_limits, {unknown_keys, [unsafe]}}}},
       adk_llm:validate_config(
         Valid#{content_limits => #{unsafe => 1}})),

    Secret = {<<"seeded-secret-must-not-leak">>},
    Error = adk_llm:validate_config(Valid#{api_key => Secret}),
    ?assertEqual({error, {invalid_gemini_option, api_key, redacted}},
                 Error),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Error),
                              <<"seeded-secret-must-not-leak">>)).

gemini_agent_rejects_unknown_config_at_start_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Name = <<"StrictGeminiConfig_",
             (integer_to_binary(
                erlang:unique_integer([positive])))/binary>>,
    ?assertEqual(
       {error, {invalid_llm_config,
                {unknown_gemini_options, [temperatur]}}},
       erlang_adk:spawn_agent(
         Name,
         #{provider => adk_llm_gemini, temperatur => 0.2}, [])).

binary_profile_materializes_only_at_dispatch_test() ->
    Previous = application:get_env(erlang_adk, provider_profiles),
    Secret = <<"profile-dispatch-secret">>,
    Profile = #{request_adapter => adk_profile_llm_probe,
                endpoint =>
                    #{scheme => https,
                      host => <<"models.example.test">>,
                      port => 8443,
                      base_path => <<"/v1">>},
                models =>
                    #{<<"chat">> =>
                          #{id => <<"vendor-model-id">>,
                            capabilities => #{json_mode => true}}},
                credential => {literal, Secret},
                capabilities => #{multimodal => true}},
    ok = application:set_env(
           erlang_adk, provider_profiles, #{<<"vendor">> => Profile}),
    try
        Public = #{provider => <<"vendor">>, model => <<"chat">>,
                   test_pid => self(), temperature => 0.25},
        {ok, <<"profile response">>} = adk_llm:generate(
                                         Public,
                                         [#{role => user,
                                            content => <<"hello">>}], []),
        receive
            {profile_probe_config, Materialized} ->
                ?assertEqual(adk_profile_llm_probe,
                             maps:get(provider, Materialized)),
                ?assertEqual(<<"vendor-model-id">>,
                             maps:get(model, Materialized)),
                ?assertEqual(
                   <<"https://models.example.test:8443/v1">>,
                   maps:get(base_url, Materialized)),
                ?assertEqual(Secret, maps:get(api_key, Materialized)),
                ?assertEqual(0.25, maps:get(temperature, Materialized))
        after 1000 ->
            ?assert(false)
        end,
        {ok, Capabilities} = adk_llm:capabilities(Public),
        ?assertEqual(true, maps:get(generate, Capabilities)),
        ?assertEqual(true, maps:get(streaming, Capabilities)),
        %% Profile/model metadata is a restriction, never a way to claim
        %% behavior the adapter did not advertise as implemented.
        ?assertNot(maps:is_key(multimodal, Capabilities)),
        ?assertNot(maps:is_key(json_mode, Capabilities)),
        ?assertEqual(
           {error, provider_profile_override_not_allowed},
           adk_llm:validate_config(Public#{api_key => <<"caller-key">>}))
    after
        case Previous of
            undefined -> application:unset_env(erlang_adk, provider_profiles);
            {ok, Value} ->
                application:set_env(erlang_adk, provider_profiles, Value)
        end
    end.

profile_selected_agent_invocation_reaches_configured_adapter_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Previous = application:get_env(erlang_adk, provider_profiles),
    Secret = <<"profile-agent-secret">>,
    Profile = #{request_adapter => adk_profile_llm_probe,
                endpoint =>
                    #{scheme => https,
                      host => <<"models.example.test">>,
                      port => 443,
                      base_path => <<"/v1">>},
                models => #{<<"chat">> => <<"agent-profile-model">>},
                credential => {literal, Secret}},
    ok = application:set_env(
           erlang_adk, provider_profiles,
           #{<<"agent-profile">> => Profile}),
    Name = <<"ProfileSelectedAgent_",
             (integer_to_binary(
                erlang:unique_integer([positive, monotonic])))/binary>>,
    try
        {ok, AgentPid} = erlang_adk:spawn_agent(
                           Name,
                           #{provider => <<"agent-profile">>,
                             model => <<"chat">>,
                             test_pid => self()},
                           []),
        try
            ?assertEqual(
               {ok, <<"profile response">>},
               erlang_adk:prompt(AgentPid, <<"use the selected profile">>)),
            receive
                {profile_probe_config, Materialized} ->
                    ?assertEqual(adk_profile_llm_probe,
                                 maps:get(provider, Materialized)),
                    ?assertEqual(<<"agent-profile-model">>,
                                 maps:get(model, Materialized)),
                    ?assertEqual(
                       <<"https://models.example.test/v1">>,
                       maps:get(base_url, Materialized)),
                    ?assertEqual(Secret, maps:get(api_key, Materialized)),
                    ?assert(is_binary(maps:get(instructions,
                                               Materialized)))
            after 1000 ->
                ?assert(false)
            end
        after
            ok = erlang_adk:stop_agent(AgentPid)
        end
    after
        case Previous of
            undefined -> application:unset_env(erlang_adk,
                                                provider_profiles);
            {ok, Value} -> application:set_env(erlang_adk,
                                               provider_profiles, Value)
        end
    end.

config_sensitive_capabilities_are_used_and_cannot_be_widened_test() ->
    Direct = #{provider => adk_llm_compatible,
               base_url => <<"https://models.example.test/v1">>,
               model => <<"vendor-model">>,
               auth_scheme => none,
               response_format => unsupported},
    {ok, DirectCapabilities} = adk_llm:capabilities(Direct),
    ?assertEqual(false,
                 maps:get(structured_output, DirectCapabilities)),
    Previous = application:get_env(erlang_adk, provider_profiles),
    Profile = #{request_adapter => adk_llm_compatible,
                endpoint => #{scheme => https,
                              host => <<"models.example.test">>,
                              port => 443,
                              base_path => <<"/v1">>},
                models => #{<<"chat">> =>
                                #{id => <<"vendor-model">>,
                                  capabilities =>
                                      #{structured_output => true,
                                        invented_feature => true}}},
                credential => none,
                request_options => #{auth_scheme => none},
                capabilities => #{}},
    ok = application:set_env(
           erlang_adk, provider_profiles, #{<<"compatible">> => Profile}),
    try
        {ok, ProfileCapabilities} = adk_llm:capabilities(
                                      #{provider => <<"compatible">>,
                                        model => <<"chat">>,
                                        response_format => unsupported}),
        ?assertEqual(false,
                     maps:get(structured_output, ProfileCapabilities)),
        ?assertNot(maps:is_key(invented_feature, ProfileCapabilities))
    after
        case Previous of
            undefined -> application:unset_env(erlang_adk,
                                                provider_profiles);
            {ok, Value} -> application:set_env(erlang_adk,
                                               provider_profiles, Value)
        end
    end.
