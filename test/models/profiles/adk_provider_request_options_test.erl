-module(adk_provider_request_options_test).

-include_lib("eunit/include/eunit.hrl").

openai_caller_options_and_locked_privacy_defaults_test() ->
    Secret = <<"openai-profile-request-secret">>,
    Profile = #{request_adapter => adk_llm_openai,
                endpoint => openai,
                models => #{<<"chat">> => <<"gpt-5-mini">>},
                credential => {literal, Secret},
                request_options =>
                    #{organization => <<"org-operator">>,
                      project => <<"project-operator">>,
                      store => false}},
    with_profiles(
      #{<<"openai-prod">> => Profile},
      fun() ->
          Public = #{provider => <<"openai-prod">>, model => <<"chat">>,
                     temperature => 0.2, max_tokens => 128,
                     request_timeout => 5000,
                     instructions => <<"Answer briefly">>},
          {ok, Resolved} = adk_provider_registry:resolve_config(Public),
          Options = maps:get(options, Resolved),
          ?assertEqual(0.2, maps:get(temperature, Options)),
          ?assertEqual(128, maps:get(max_tokens, Options)),
          ?assertEqual(<<"org-operator">>,
                       maps:get(organization, Options)),
          ?assertEqual(<<"project-operator">>,
                       maps:get(project, Options)),
          ?assertEqual(false, maps:get(store, Options)),
          ?assertEqual(maps:get(request_options, Resolved),
                       maps:with([organization, project, store], Options)),
          ?assertEqual(nomatch,
                       binary:match(term_to_binary(Resolved), Secret)),
          ?assertEqual(ok, adk_llm:validate_config(Public))
      end).

caller_cannot_override_locked_or_unknown_request_options_test() ->
    Secret = <<"locked-request-option-secret">>,
    Profile = #{request_adapter => adk_llm_openai,
                endpoint => openai,
                models => #{<<"chat">> => <<"gpt-5-mini">>},
                credential => {literal, Secret},
                request_options => #{store => false}},
    with_profiles(
      #{<<"locked">> => Profile},
      fun() ->
          Base = #{provider => <<"locked">>, model => <<"chat">>},
          Overrides =
              [#{store => true},
               #{organization => <<"caller-org">>},
               #{project => <<"caller-project">>},
               #{auth_scheme => none},
               #{anthropic_version => <<"caller-version">>},
               #{base_url => <<"https://attacker.example">>},
               #{api_key => <<"caller-secret">>},
               #{http_transport => adk_model_fixture_transport},
               #{allow_private_hosts => true},
               #{temperatur => 0.2}],
          lists:foreach(
            fun(Override) ->
                Result = adk_provider_registry:resolve_config(
                           maps:merge(Base, Override)),
                ?assertEqual(
                   {error, provider_profile_override_not_allowed}, Result),
                ?assertEqual(nomatch,
                             binary:match(term_to_binary(Result), Secret))
            end, Overrides)
      end).

anthropic_version_is_locked_while_inference_options_remain_public_test() ->
    Secret = <<"anthropic-profile-request-secret">>,
    Profile = #{request_adapter => adk_llm_anthropic,
                endpoint => anthropic,
                models => #{<<"reasoning">> => <<"claude-sonnet-4-5">>},
                credential => {literal, Secret},
                request_options =>
                    #{anthropic_version => <<"2023-06-01">>}},
    with_profiles(
      #{<<"anthropic-prod">> => Profile},
      fun() ->
          Public = #{provider => <<"anthropic-prod">>,
                     model => <<"reasoning">>, max_tokens => 256,
                     temperature => 0.1, request_timeout => 5000},
          {ok, Resolved} = adk_provider_registry:resolve_config(Public),
          ?assertEqual(<<"2023-06-01">>,
                       maps:get(anthropic_version,
                                maps:get(options, Resolved))),
          ?assertEqual(ok, adk_llm:validate_config(Public)),
          ?assertEqual(
             {error, provider_profile_override_not_allowed},
             adk_provider_registry:resolve_config(
               Public#{anthropic_version => <<"2099-01-01">>}))
      end).

compatible_profile_locks_auth_scheme_format_and_https_endpoint_test() ->
    Secret = <<"compatible-profile-request-secret">>,
    Endpoint = #{scheme => https, host => <<"api.compat.example">>,
                 port => 443, base_path => <<"/v1">>},
    Profile = #{request_adapter => adk_llm_compatible,
                endpoint => Endpoint,
                models => #{<<"chat">> => <<"vendor-chat">>},
                credential => {literal, Secret},
                request_options => #{auth_scheme => x_api_key,
                                     response_format => unsupported}},
    with_profiles(
      #{<<"compatible-prod">> => Profile},
      fun() ->
          Public = #{provider => <<"compatible-prod">>,
                     model => <<"chat">>, temperature => 0.3,
                     max_tokens => 128, request_timeout => 5000},
          {ok, Resolved} = adk_provider_registry:resolve_config(Public),
          ?assertEqual(x_api_key,
                       maps:get(auth_scheme, maps:get(options, Resolved))),
          ?assertEqual(unsupported,
                       maps:get(response_format,
                                maps:get(options, Resolved))),
          ?assertEqual(ok, adk_llm:validate_config(Public)),
          ?assertEqual(
             {error, provider_profile_override_not_allowed},
             adk_provider_registry:resolve_config(
               Public#{auth_scheme => bearer})),
          {ok, Locked} = adk_provider_registry:resolve_config(
                           Public#{response_format => json_schema}),
          ?assertEqual(unsupported,
                       maps:get(response_format,
                                maps:get(options, Locked)))
      end).

invalid_compatible_locked_response_format_is_rejected_test() ->
    Profile = #{request_adapter => adk_llm_compatible,
                endpoint => #{scheme => https,
                              host => <<"api.compat.example">>,
                              port => 443, base_path => <<"/v1">>},
                models => #{<<"chat">> => <<"vendor-chat">>},
                credential => none,
                request_options => #{auth_scheme => none,
                                     response_format => arbitrary_wire_map}},
    ?assertEqual(
       {error, invalid_provider_request_options},
       adk_provider_profile:validate(<<"compatible">>, Profile)).

invalid_operator_request_options_are_bounded_and_data_free_test() ->
    Secret = <<"operator-request-option-secret-must-not-leak">>,
    Base = #{request_adapter => adk_llm_openai,
             endpoint => openai,
             models => #{<<"chat">> => <<"gpt-5-mini">>},
             credential => {literal, <<"credential">>}},
    Invalid = [#{api_key => Secret},
               #{base_url => <<"https://attacker.example">>},
               #{allow_private_hosts => true},
               #{store => not_boolean},
               #{organization => <<"bad\nheader">>},
               #{unknown => Secret}],
    lists:foreach(
      fun(RequestOptions) ->
          Result = adk_provider_profile:normalize(
                     <<"invalid-options">>,
                     Base#{request_options => RequestOptions}),
          ?assertEqual({error, invalid_provider_request_options}, Result),
          ?assertEqual(nomatch,
                       binary:match(term_to_binary(Result), Secret))
      end, Invalid),
    Oversized = #{organization => binary:copy(<<"a">>, 17000)},
    ?assertEqual(
       {error, invalid_provider_request_options},
       adk_provider_profile:normalize(
         <<"oversized-options">>, Base#{request_options => Oversized})).

bundled_request_adapters_reject_wrong_presets_test() ->
    Models = #{<<"chat">> => <<"provider-model">>},
    Credential = {literal, <<"preset-secret">>},
    Mismatches =
        [{adk_llm_openai, anthropic},
         {adk_llm_anthropic, openai},
         {adk_llm_gemini, openai},
         {adk_llm_compatible, openai}],
    lists:foreach(
      fun({Adapter, Endpoint}) ->
          ?assertEqual(
             {error, provider_request_endpoint_mismatch},
             adk_provider_profile:normalize(
               <<"mismatch">>,
               #{request_adapter => Adapter, endpoint => Endpoint,
                 models => Models, credential => Credential}))
      end, Mismatches),
    CustomEndpoint = #{scheme => https, host => <<"proxy.example">>,
                       port => 443, base_path => <<"/v1">>},
    lists:foreach(
      fun(Adapter) ->
          ?assertMatch(
             {ok, _},
             adk_provider_profile:normalize(
               <<"custom-endpoint">>,
               #{request_adapter => Adapter, endpoint => CustomEndpoint,
                 models => Models, credential => Credential}))
      end,
      [adk_llm_openai, adk_llm_anthropic,
       adk_llm_gemini, adk_llm_compatible]).

with_profiles(Profiles, Fun) ->
    Previous = application:get_env(erlang_adk, provider_profiles),
    ok = application:set_env(erlang_adk, provider_profiles, Profiles),
    try Fun()
    after restore_env(provider_profiles, Previous)
    end.

restore_env(Key, undefined) -> application:unset_env(erlang_adk, Key);
restore_env(Key, {ok, Value}) -> application:set_env(erlang_adk, Key, Value).
