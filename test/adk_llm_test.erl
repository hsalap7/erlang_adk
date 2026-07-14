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
    Name = <<"StrictGeminiConfig-",
             (integer_to_binary(
                erlang:unique_integer([positive])))/binary>>,
    ?assertEqual(
       {error, {invalid_llm_config,
                {unknown_gemini_options, [temperatur]}}},
       erlang_adk:spawn_agent(
         Name,
         #{provider => adk_llm_gemini, temperatur => 0.2}, [])).
