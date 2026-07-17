-module(adk_provider_credential_test).

-include_lib("eunit/include/eunit.hrl").

profile_environment_source_resolves_test() ->
    EnvName = "ERLANG_ADK_TEST_PROVIDER_CREDENTIAL_918273",
    Secret = <<"environment-provider-secret">>,
    with_os_env(
      EnvName, binary_to_list(Secret),
      fun() ->
          with_profiles(
            #{<<"env-provider">> => base_profile({env, EnvName})},
            fun() ->
                ?assertEqual({ok, Secret},
                             adk_provider_credential:resolve(
                               <<"env-provider">>))
            end)
      end).

profile_application_source_resolves_test() ->
    Secret = <<"application-provider-secret">>,
    Previous = application:get_env(
                 erlang_adk, adk_provider_credential_test_key),
    ok = application:set_env(
           erlang_adk, adk_provider_credential_test_key, Secret),
    try
        with_profiles(
          #{<<"app-provider">> =>
                base_profile(
                  {application_env, erlang_adk,
                   adk_provider_credential_test_key})},
          fun() ->
              ?assertEqual({ok, Secret},
                           adk_provider_credential:resolve(
                             <<"app-provider">>))
          end)
    after
        restore_app_env(adk_provider_credential_test_key, Previous)
    end.

literal_is_trusted_only_and_public_profile_is_redacted_test() ->
    Secret = <<"trusted-literal-provider-secret">>,
    ?assertEqual({ok, Secret},
                 adk_provider_credential:resolve(
                   {literal, Secret}, trusted)),
    Untrusted = adk_provider_credential:resolve(
                  {literal, Secret}, untrusted),
    ?assertEqual({error, credential_source_not_allowed}, Untrusted),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Untrusted), Secret)),
    with_profiles(
      #{<<"literal-provider">> => base_profile({literal, Secret})},
      fun() ->
          {ok, Public} = adk_provider_registry:lookup(
                           <<"literal-provider">>),
          ?assertEqual(#{source => literal}, maps:get(credential, Public)),
          ?assertEqual(nomatch,
                       binary:match(term_to_binary(Public), Secret)),
          ?assertEqual({ok, Secret},
                       adk_provider_credential:resolve(
                         <<"literal-provider">>))
      end).

untrusted_sources_cannot_probe_environment_test() ->
    ?assertEqual(
       {error, credential_source_not_allowed},
       adk_provider_credential:resolve(
         {env, "HOME"}, untrusted)),
    ?assertEqual(
       {error, credential_source_not_allowed},
       adk_provider_credential:resolve(
         {application_env, erlang_adk, provider_profiles}, untrusted)).

environment_names_are_strict_test() ->
    Invalid = ["lowercase", "HAS-DASH", "../SECRET", "", 42],
    lists:foreach(
      fun(Name) ->
          ?assertEqual(
             {error, invalid_provider_credential_source},
             adk_provider_credential:describe({env, Name}))
      end, Invalid).

missing_and_invalid_credentials_have_data_free_errors_test() ->
    MissingName = "ERLANG_ADK_CREDENTIAL_THAT_DOES_NOT_EXIST_918273",
    with_os_env(
      MissingName, unset,
      fun() ->
          ?assertEqual(
             {error, provider_credential_not_configured},
             adk_provider_credential:resolve(
               {env, MissingName}, trusted))
      end),
    ?assertEqual(
       {error, invalid_provider_credential_source},
       adk_provider_credential:resolve({literal, <<>>}, trusted)),
    ?assertEqual(
       {error, unknown_provider_profile},
       with_profiles(
         #{},
         fun() -> adk_provider_credential:resolve(<<"unknown">>) end)).

base_profile(Credential) ->
    #{request_adapter => adk_llm_dummy,
      endpoint => openai,
      models => #{<<"chat">> => <<"provider-model">>},
      credential => Credential}.

with_profiles(Profiles, Fun) ->
    Previous = application:get_env(erlang_adk, provider_profiles),
    ok = application:set_env(erlang_adk, provider_profiles, Profiles),
    try Fun()
    after restore_app_env(provider_profiles, Previous)
    end.

with_os_env(Name, Value, Fun) ->
    Previous = os:getenv(Name),
    set_os_env(Name, Value),
    try Fun()
    after set_os_env(Name, Previous)
    end.

set_os_env(Name, false) -> os:unsetenv(Name);
set_os_env(Name, unset) -> os:unsetenv(Name);
set_os_env(Name, Value) -> os:putenv(Name, Value).

restore_app_env(Key, undefined) -> application:unset_env(erlang_adk, Key);
restore_app_env(Key, {ok, Value}) ->
    application:set_env(erlang_adk, Key, Value).
