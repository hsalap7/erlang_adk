-module(adk_provider_capabilities_test).

-include_lib("eunit/include/eunit.hrl").

normalizes_rich_capabilities_test() ->
    Capabilities = #{generate => true,
                     function_calling => synchronous,
                     input_modalities => [text, audio],
                     context_cache => #{explicit => true,
                                        models => [<<"model-a">>]}},
    ?assertEqual({ok, Capabilities},
                 adk_provider_capabilities:normalize(Capabilities)),
    ?assert(adk_provider_capabilities:supports(
              Capabilities, function_calling)),
    ?assertNot(adk_provider_capabilities:supports(
                 Capabilities#{live => false}, live)),
    ?assertNot(adk_provider_capabilities:supports(
                 Capabilities, missing)).

model_capabilities_override_profile_defaults_test() ->
    {ok, Merged} = adk_provider_capabilities:merge(
                     #{streaming => true, live => false},
                     #{live => true, input_modalities => [audio]}),
    ?assertEqual(true, maps:get(streaming, Merged)),
    ?assertEqual(true, maps:get(live, Merged)),
    ?assertEqual([audio], maps:get(input_modalities, Merged)).

profile_metadata_can_only_narrow_adapter_ceiling_test() ->
    Ceiling = #{generate => true,
                streaming => true,
                structured_output => false,
                input_modalities => [text, audio, image],
                function_calling => synchronous,
                nested => #{tools => true, live => false}},
    Restrictions = #{generate => false,
                     structured_output => true,
                     input_modalities => [audio, video, audio],
                     function_calling => asynchronous,
                     nested => #{tools => false, live => true,
                                 unknown => true},
                     profile_only_claim => true},
    {ok, Constrained} = adk_provider_capabilities:constrain(
                          Ceiling, Restrictions),
    ?assertEqual(false, maps:get(generate, Constrained)),
    ?assertEqual(true, maps:get(streaming, Constrained)),
    ?assertEqual(false, maps:get(structured_output, Constrained)),
    ?assertEqual([audio], maps:get(input_modalities, Constrained)),
    ?assertEqual(false, maps:get(function_calling, Constrained)),
    ?assertEqual(#{tools => false, live => false},
                 maps:get(nested, Constrained)),
    ?assertNot(maps:is_key(profile_only_claim, Constrained)).

rejects_secret_bearing_and_opaque_metadata_test() ->
    Secret = <<"capability-secret-must-not-leak">>,
    ?assertEqual(
       {error, invalid_provider_capabilities},
       adk_provider_capabilities:normalize(#{api_key => Secret})),
    ?assertEqual(
       {error, invalid_provider_capabilities},
       adk_provider_capabilities:normalize(#{worker => self()})),
    ?assertEqual(
       {error, invalid_provider_capabilities},
       adk_provider_capabilities:normalize(
         #{nested => #{credential_hint => <<"present">>}})).

rejects_unbounded_metadata_test() ->
    TooMany = maps:from_list(
                [{<<"bounded_cap_", (integer_to_binary(Index))/binary>>, true}
                 || Index <- lists:seq(1, 129)]),
    ?assertEqual({error, invalid_provider_capabilities},
                 adk_provider_capabilities:normalize(TooMany)),
    ?assertEqual({error, invalid_provider_capabilities},
                 adk_provider_capabilities:normalize(
                   #{modes => lists:duplicate(129, audio)})).
