-module(adk_content_test).
-include_lib("eunit/include/eunit.hrl").

versioned_json_round_trip_test() ->
    {ok, Text} = adk_content:text(<<"Describe this image.">>),
    {ok, Image} = adk_content:inline_data(<<"image/png">>, <<0, 1, 2, 255>>),
    {ok, File} = adk_content:file_data(
                   <<"audio/mpeg">>, <<"gs://adk-fixtures/sample.mp3">>),
    {ok, Content} = adk_content:new([Text, Image, File]),
    ?assertEqual(1, maps:get(<<"schema_version">>, Content)),
    Encoded = jsx:encode(Content),
    Decoded = jsx:decode(Encoded, [return_maps]),
    ?assertEqual({ok, Content}, adk_content:validate(Decoded)),
    [_, Inline, _] = adk_content:parts(Content),
    ?assertEqual(base64:encode(<<0, 1, 2, 255>>),
                 maps:get(<<"data">>, Inline)).

function_parts_are_json_safe_test() ->
    {ok, Call} = adk_content:function_call(
                   <<"lookup_weather">>, #{<<"city">> => <<"Paris">>},
                   #{id => <<"call-1">>, thought_signature => <<"sig-1">>}),
    {ok, Response} = adk_content:function_response(
                       <<"lookup_weather">>,
                       #{<<"temperature_c">> => 18},
                       #{<<"id">> => <<"call-1">>}),
    {ok, Content} = adk_content:new([Call, Response]),
    ?assert(is_binary(jsx:encode(Content))),
    ?assertEqual(
       [<<"function_call">>, <<"function_response">>],
       [maps:get(<<"type">>, Part) || Part <- adk_content:parts(Content)]).

gemini_mapping_round_trip_test() ->
    {ok, Text} = adk_content:text(<<"Look">>),
    {ok, Image} = adk_content:inline_data(<<"image/png">>, <<"PNG">>),
    {ok, File} = adk_content:file_data(
                   <<"application/pdf">>, <<"https://example.test/a.pdf">>),
    {ok, Content} = adk_content:new([Text, Image, File]),
    {ok, GeminiParts} = adk_llm_gemini_content:encode(Content, #{}),
    ?assertMatch([#{<<"text">> := <<"Look">>},
                  #{<<"inlineData">> := _},
                  #{<<"fileData">> := _}], GeminiParts),
    ?assertEqual({ok, Content},
                 adk_llm_gemini_content:decode(GeminiParts, #{})).

gemini_metadata_and_no_arg_call_are_preserved_test() ->
    GeminiParts = [
        #{<<"text">> => <<"thought summary">>,
          <<"thought">> => true,
          <<"thoughtSignature">> => <<"sig-text">>},
        #{<<"functionCall">> => #{<<"name">> => <<"now">>},
          <<"thoughtSignature">> => <<"sig-call">>}
    ],
    {ok, Content} = adk_llm_gemini_content:decode(GeminiParts, #{}),
    [Text, Call] = adk_content:parts(Content),
    ?assertEqual(true, maps:get(<<"thought">>, Text)),
    ?assertEqual(<<"sig-text">>,
                 maps:get(<<"thought_signature">>, Text)),
    ?assertEqual(#{}, maps:get(<<"args">>, Call)),
    ?assertEqual([{<<"now">>, #{}, <<"sig-call">>}],
                 adk_llm_gemini_content:tool_calls(Content)),
    [EncodedText, EncodedCall] = begin
        {ok, Encoded} = adk_llm_gemini_content:encode(Content, #{}),
        Encoded
    end,
    ?assertEqual(hd(GeminiParts), EncodedText),
    ?assertEqual(
       #{<<"name">> => <<"now">>, <<"args">> => #{}},
       maps:get(<<"functionCall">>, EncodedCall)).

invalid_mime_is_rejected_test() ->
    ?assertMatch(
       {error, {invalid_content_part, [<<"parts">>, 0, <<"mime_type">>],
                invalid_mime_type}},
       adk_content:inline_data(<<"image/png; charset=x">>, <<1>>)).

invalid_and_noncanonical_base64_are_rejected_test() ->
    Invalid = content(#{<<"type">> => <<"inline_data">>,
                        <<"mime_type">> => <<"image/png">>,
                        <<"data">> => <<"not base64">>}),
    ?assertMatch({error, {invalid_content_part, _, invalid_base64}},
                 adk_content:validate(Invalid)),
    MissingPadding = content(#{<<"type">> => <<"inline_data">>,
                               <<"mime_type">> => <<"image/png">>,
                               <<"data">> => <<"YQ">>}),
    ?assertMatch({error, {invalid_content_part, _, invalid_base64}},
                 adk_content:validate(MissingPadding)).

inline_size_limits_are_enforced_before_encoding_test() ->
    ?assertEqual(
       {error, {content_size_limit_exceeded,
                max_inline_data_bytes, 4, 3}},
       adk_content:inline_data(<<"application/octet-stream">>, <<0, 1, 2, 3>>,
                               #{max_inline_data_bytes => 3,
                                 max_total_inline_data_bytes => 3})).

total_inline_size_limit_is_enforced_test() ->
    {ok, First} = adk_content:inline_data(
                    <<"image/png">>, <<1, 2, 3>>,
                    #{max_inline_data_bytes => 4,
                      max_total_inline_data_bytes => 4}),
    {ok, Second} = adk_content:inline_data(
                     <<"image/png">>, <<4, 5, 6>>,
                     #{max_inline_data_bytes => 4,
                       max_total_inline_data_bytes => 4}),
    ?assertEqual(
       {error, {content_size_limit_exceeded,
                max_total_inline_data_bytes, 6, 4}},
       adk_content:new([First, Second],
                       #{max_inline_data_bytes => 4,
                         max_total_inline_data_bytes => 4})).

file_uri_policy_test() ->
    ?assertMatch({ok, _}, adk_content:file_data(
                           <<"image/jpeg">>, <<"https://example.test/a.jpg">>)),
    ?assertMatch({ok, _}, adk_content:file_data(
                           <<"image/jpeg">>, <<"gs://bucket/a.jpg">>)),
    ?assertMatch(
       {error, {invalid_content_part, _,
                {unsupported_uri_scheme, <<"file">>}}},
       adk_content:file_data(<<"image/jpeg">>, <<"file:///etc/passwd">>)),
    ?assertMatch(
       {error, {invalid_content_part, _,
                uri_userinfo_not_allowed}},
       adk_content:file_data(
         <<"image/jpeg">>, <<"https://user:pass@example.test/a.jpg">>)),
    ?assertMatch(
       {error, {invalid_content_part, _,
                uri_fragment_not_allowed}},
       adk_content:file_data(
         <<"image/jpeg">>, <<"https://example.test/a.jpg#fragment">>)).

unknown_versions_fields_and_part_types_are_rejected_test() ->
    ?assertEqual({error, {unsupported_content_version, 2}},
                 adk_content:validate(
                   #{<<"schema_version">> => 2,
                     <<"parts">> => [text_part(<<"x">>)]})),
    ?assertMatch({error, {invalid_content_part, [], {unknown_keys, _}}},
                 adk_content:validate(
                   (content(text_part(<<"x">>)))#{<<"unsafe">> => true})),
    ?assertEqual(
       {error, {unsupported_content_part, [<<"parts">>, 0], <<"video">>}},
       adk_content:validate(content(#{<<"type">> => <<"video">>}))).

non_json_function_payload_is_rejected_test() ->
    ?assertMatch(
       {error, {invalid_content_part, _, _}},
       adk_content:function_call(<<"unsafe">>, #{<<"pid">> => self()})),
    ?assertMatch(
       {error, {invalid_content_part, _, not_canonical_json}},
       adk_content:function_response(<<"unsafe">>, #{atom_key => <<"x">>})).

limits_contract_is_strict_test() ->
    ?assertMatch({error, {invalid_content_limits, {unknown_keys, [unknown]}}},
                 adk_content:normalize_limits(#{unknown => 1})),
    ?assertMatch({error, {invalid_content_limits,
                          {max_parts, 0, {allowed_range, 1, 256}}}},
                 adk_content:normalize_limits(#{max_parts => 0})),
    ?assertEqual({error, {invalid_content_limits,
                          max_inline_exceeds_total}},
                 adk_content:normalize_limits(
                   #{max_inline_data_bytes => 5,
                     max_total_inline_data_bytes => 4})).

content(Part) ->
    #{<<"schema_version">> => 1, <<"parts">> => [Part]}.

text_part(Text) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text}.
