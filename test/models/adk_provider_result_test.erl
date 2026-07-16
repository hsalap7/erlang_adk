-module(adk_provider_result_test).
-include_lib("eunit/include/eunit.hrl").

round_trip_provider_result_test() ->
    Metadata = #{<<"webSearchQueries">> => [<<"erlang otp">>]},
    {ok, Result} = adk_provider_result:new(
                     <<"gemini">>, <<"google_search_grounding">>,
                     {ok, <<"answer">>}, Metadata),
    ?assertMatch({provider_result, _}, Result),
    {ok, {ok, <<"answer">>}, Action} =
        adk_provider_result:decode(Result),
    ?assertEqual(1, maps:get(<<"schema_version">>, Action)),
    ?assertEqual(<<"gemini">>, maps:get(<<"provider">>, Action)),
    ?assertEqual(<<"google_search_grounding">>,
                 maps:get(<<"type">>, Action)),
    ?assertEqual(Metadata, maps:get(<<"metadata">>, Action)).

reject_non_json_metadata_test() ->
    ?assertEqual(
       {error, metadata_must_be_json},
       adk_provider_result:new(
         <<"gemini">>, <<"grounding">>, streamed,
         #{atom_key => <<"not strict JSON">>})),
    ?assertMatch(
       {error, {invalid_metadata_json,
                {unsupported_json_term, _, pid}}},
       adk_provider_result:new(
         <<"gemini">>, <<"grounding">>, streamed,
         #{<<"pid">> => self()})).

reject_oversize_metadata_test() ->
    Oversize = binary:copy(
                 <<"x">>, adk_provider_result:max_metadata_bytes()),
    ?assertMatch(
       {error, {metadata_too_large, _, 262144}},
       adk_provider_result:new(
         <<"gemini">>, <<"grounding">>, streamed,
         #{<<"renderedContent">> => Oversize})).

reject_malformed_envelope_test() ->
    ?assertEqual(
       {error, {invalid_provider_result, invalid_envelope_keys}},
       adk_provider_result:decode(
         {provider_result,
          #{version => 1, provider => <<"gemini">>,
            type => <<"grounding">>, outcome => streamed,
            metadata => #{}, injected => true}})),
    ?assertEqual(
       {error,
        {invalid_provider_result, {unsupported_schema_version, 2}}},
       adk_provider_result:decode(
         {provider_result,
          #{version => 2, provider => <<"gemini">>,
            type => <<"grounding">>, outcome => streamed,
            metadata => #{}}})).
