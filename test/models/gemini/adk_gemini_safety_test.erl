-module(adk_gemini_safety_test).

-include_lib("eunit/include/eunit.hrl").

all_categories_and_thresholds_encode_without_losing_policy_test() ->
    First =
        [#{category => harassment, threshold => off},
         #{category => hate_speech, threshold => block_none},
         #{category => sexually_explicit,
           threshold => block_medium_and_above},
         #{category => dangerous_content, threshold => unspecified}],
    ?assertEqual(
       {ok,
        [#{<<"category">> => <<"HARM_CATEGORY_HARASSMENT">>,
           <<"threshold">> => <<"OFF">>},
         #{<<"category">> => <<"HARM_CATEGORY_HATE_SPEECH">>,
           <<"threshold">> => <<"BLOCK_NONE">>},
         #{<<"category">> => <<"HARM_CATEGORY_SEXUALLY_EXPLICIT">>,
           <<"threshold">> => <<"BLOCK_MEDIUM_AND_ABOVE">>},
         #{<<"category">> => <<"HARM_CATEGORY_DANGEROUS_CONTENT">>,
           <<"threshold">> => <<"HARM_BLOCK_THRESHOLD_UNSPECIFIED">>}]},
       adk_gemini_safety:encode(First)),

    Second =
        [#{category => harassment, threshold => block_only_high},
         #{category => hate_speech, threshold => block_low_and_above}],
    ?assertEqual(
       {ok,
        [#{<<"category">> => <<"HARM_CATEGORY_HARASSMENT">>,
           <<"threshold">> => <<"BLOCK_ONLY_HIGH">>},
         #{<<"category">> => <<"HARM_CATEGORY_HATE_SPEECH">>,
           <<"threshold">> => <<"BLOCK_LOW_AND_ABOVE">>}]},
       adk_gemini_safety:encode(Second)).

wire_vocabulary_is_normalized_before_encoding_test() ->
    ?assertEqual(
       {ok,
        [#{<<"category">> => <<"HARM_CATEGORY_DANGEROUS_CONTENT">>,
           <<"threshold">> => <<"BLOCK_NONE">>}]},
       adk_gemini_safety:encode(
         [#{category => <<"HARM_CATEGORY_DANGEROUS_CONTENT">>,
            threshold => <<"BLOCK_NONE">>}])).

invalid_policy_is_rejected_without_emitting_a_partial_request_test() ->
    ?assertEqual({error, expected_list},
                 adk_gemini_safety:encode(not_a_list)),
    ?assertEqual(
       {error, {invalid_setting, 1, invalid_threshold}},
       adk_gemini_safety:encode(
         [#{category => harassment, threshold => off},
          #{category => hate_speech, threshold => invalid}])).
