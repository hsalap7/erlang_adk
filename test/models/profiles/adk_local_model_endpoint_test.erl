-module(adk_local_model_endpoint_test).

-include_lib("eunit/include/eunit.hrl").

normalizes_and_materializes_numeric_loopback_endpoints_test() ->
    IPv4 = endpoint(<<"127.0.0.1">>, 11434, <<"/v1">>),
    ?assertEqual({ok, IPv4}, adk_local_model_endpoint:normalize(IPv4)),
    ?assertEqual(
       {ok, #{base_url => <<"http://127.0.0.1:11434/v1">>,
              allow_private_hosts => true,
              local_endpoint_policy => loopback_keyless}},
       adk_local_model_endpoint:materialize(IPv4)),
    IPv6 = endpoint(<<"::1">>, 8000, <<"/openai/v1">>),
    ?assertEqual(
       {ok, #{base_url => <<"http://[::1]:8000/openai/v1">>,
              allow_private_hosts => true,
              local_endpoint_policy => loopback_keyless}},
       adk_local_model_endpoint:materialize(IPv6)).

rejects_hostnames_non_loopback_and_ambiguous_endpoint_shapes_test() ->
    Base = endpoint(<<"127.0.0.1">>, 11434, <<"/v1">>),
    Invalid = [Base#{host => <<"localhost">>},
               Base#{host => <<"127.0.0.2">>},
               Base#{host => <<"0.0.0.0">>},
               Base#{scheme => https},
               Base#{policy => private_http},
               Base#{port => 0},
               Base#{base_path => <<"/v1/../admin">>},
               Base#{base_path => <<"/%2e%2e/admin">>},
               Base#{base_path => <<"/v1\\..\\admin">>},
               Base#{base_path => <<"/v1//admin">>},
               Base#{base_path => <<"//admin">>},
               Base#{base_path => <<"/v1 ">>},
               Base#{base_path => <<"/v1?admin=true">>},
               Base#{base_path => <<"/v1", 255>>},
               Base#{headers => []},
               maps:remove(policy, Base)],
    lists:foreach(
      fun(Value) ->
          ?assertEqual(
             {error, invalid_local_model_endpoint},
             adk_local_model_endpoint:normalize(Value))
      end, Invalid),
    ?assertEqual(
       {error, invalid_local_model_endpoint},
       adk_local_model_endpoint:validate_profile(
         Base#{host => <<"localhost">>}, adk_llm_compatible, undefined,
         #{source => none}, #{auth_scheme => none})).

profile_policy_is_compatible_keyless_request_only_test() ->
    Endpoint = endpoint(<<"127.0.0.1">>, 11434, <<"/v1">>),
    ?assertEqual(
       ok,
       adk_local_model_endpoint:validate_profile(
         Endpoint, adk_llm_compatible, undefined,
         #{source => none}, #{auth_scheme => none})),
    ?assertEqual(
       {error, local_model_endpoint_live_not_supported},
       adk_local_model_endpoint:validate_profile(
         Endpoint, adk_llm_compatible, adk_live_openai,
         #{source => none}, #{auth_scheme => none})),
    ?assertEqual(
       {error, local_model_endpoint_requires_compatible_adapter},
       adk_local_model_endpoint:validate_profile(
         Endpoint, adk_llm_openai, undefined,
         #{source => none}, #{auth_scheme => none})),
    ?assertEqual(
       {error, local_model_endpoint_requires_no_credential},
       adk_local_model_endpoint:validate_profile(
         Endpoint, adk_llm_compatible, undefined,
         #{source => env}, #{auth_scheme => none})),
    ?assertEqual(
       {error, local_model_endpoint_requires_keyless_auth},
       adk_local_model_endpoint:validate_profile(
         Endpoint, adk_llm_compatible, undefined,
         #{source => none}, #{auth_scheme => bearer})).

runtime_policy_rechecks_loopback_auth_and_private_access_test() ->
    Base = #{base_url => <<"http://127.0.0.1:11434/v1">>,
             auth_scheme => none,
             allow_private_hosts => true,
             local_endpoint_policy => loopback_keyless},
    ?assertEqual(ok, adk_local_model_endpoint:validate_runtime(Base)),
    ?assertEqual(
       ok,
       adk_local_model_endpoint:validate_runtime(
         Base#{base_url => <<"http://[::1]:8000/v1">>})),
    ?assertEqual(
       {error, local_model_endpoint_loopback_http_required},
       adk_local_model_endpoint:validate_runtime(
         Base#{base_url => <<"http://localhost:11434/v1">>})),
    ?assertEqual(
       {error, local_model_endpoint_loopback_http_required},
       adk_local_model_endpoint:validate_runtime(
         Base#{base_url => <<"https://127.0.0.1:11434/v1">>})),
    ?assertEqual(
       {error, local_model_endpoint_requires_keyless_auth},
       adk_local_model_endpoint:validate_runtime(
         Base#{auth_scheme => bearer})),
    ?assertEqual(
       {error, local_model_endpoint_requires_no_credential},
       adk_local_model_endpoint:validate_runtime(
         Base#{api_key => <<"must-not-be-used">>})),
    ?assertEqual(
       {error, local_model_endpoint_requires_private_host_access},
       adk_local_model_endpoint:validate_runtime(
         Base#{allow_private_hosts => false})).

endpoint(Host, Port, Path) ->
    #{scheme => http,
      host => Host,
      port => Port,
      base_path => Path,
      policy => loopback_keyless}.
