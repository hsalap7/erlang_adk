-module(adk_llm_anthropic_request_test).
-include_lib("eunit/include/eunit.hrl").

builds_bounded_messages_payload_test() ->
    Config = #{model => <<"claude-test">>,
               max_tokens => 256,
               temperature => 0.25,
               top_p => 0.9,
               top_k => 20,
               stop_sequences => [<<"STOP">>],
               api_key => <<"must-not-enter-body">>},
    History = [#{role => system, content => <<"Be precise.">>},
               #{role => system, content => <<"Use tools safely.">>},
               #{role => user, content => <<"Hello">>}],
    {ok, Payload} = adk_llm_anthropic_request:build(
                      Config, History, [], false),
    ?assertEqual(<<"claude-test">>, maps:get(<<"model">>, Payload)),
    ?assertEqual(256, maps:get(<<"max_tokens">>, Payload)),
    ?assertEqual(false, maps:get(<<"stream">>, Payload)),
    ?assertEqual(<<"Be precise.\nUse tools safely.">>,
                 maps:get(<<"system">>, Payload)),
    ?assertEqual(
       [#{<<"role">> => <<"user">>,
          <<"content">> =>
              [#{<<"type">> => <<"text">>, <<"text">> => <<"Hello">>}]}],
       maps:get(<<"messages">>, Payload)),
    ?assertEqual(0.25, maps:get(<<"temperature">>, Payload)),
    ?assertEqual(0.9, maps:get(<<"top_p">>, Payload)),
    ?assertEqual(20, maps:get(<<"top_k">>, Payload)),
    ?assertEqual([<<"STOP">>], maps:get(<<"stop_sequences">>, Payload)),
    ?assertEqual(false, maps:is_key(<<"api_key">>, Payload)),
    ?assertEqual(false, maps:is_key(api_key, Payload)).

max_tokens_must_be_positive_and_defaults_to_1024_test() ->
    History = [#{role => user, content => <<"Hello">>}],
    ?assertEqual(
       {error, invalid_anthropic_max_tokens},
       adk_llm_anthropic_request:build(
         #{model => <<"claude-test">>, max_tokens => 0}, History, [])),
    {ok, MinimumPayload} = adk_llm_anthropic_request:build(
                             #{model => <<"claude-test">>,
                               max_tokens => 1},
                             History, []),
    ?assertEqual(1, maps:get(<<"max_tokens">>, MinimumPayload)),
    {ok, DefaultPayload} = adk_llm_anthropic_request:build(
                             #{model => <<"claude-test">>}, History, []),
    ?assertEqual(1024, maps:get(<<"max_tokens">>, DefaultPayload)).

ga_structured_output_uses_output_config_format_test() ->
    Schema = #{<<"type">> => <<"object">>,
               <<"properties">> =>
                   #{<<"answer">> => #{<<"type">> => <<"string">>}},
               <<"required">> => [<<"answer">>],
               <<"additionalProperties">> => false},
    {ok, Payload} = adk_llm_anthropic_request:build(
                      #{model => <<"claude-test">>,
                        output_schema => Schema},
                      [#{role => user, content => <<"Return JSON">>}], []),
    ?assertEqual(
       #{<<"format">> =>
             #{<<"type">> => <<"json_schema">>,
               <<"schema">> => Schema}},
       maps:get(<<"output_config">>, Payload)),
    ?assertEqual(
       {error, invalid_anthropic_output_schema},
       adk_llm_anthropic_request:build(
         #{model => <<"claude-test">>,
           output_schema => #{atom_key => <<"not canonical">>}},
         [#{role => user, content => <<"Return JSON">>}], [])).

encodes_base64_and_https_images_test() ->
    {ok, Text} = adk_content:text(<<"What is shown?">>),
    {ok, Inline} = adk_content:inline_data(
                     <<"image/png">>, <<1, 2, 3, 4>>),
    {ok, Url} = adk_content:file_data(
                  <<"image/webp">>, <<"https://example.test/image.webp">>),
    {ok, Content} = adk_content:new([Text, Inline, Url]),
    {ok, Blocks} = adk_llm_anthropic_content:encode(user, Content, #{}),
    [_, InlineBlock, UrlBlock] = Blocks,
    ?assertEqual(
       #{<<"type">> => <<"base64">>,
         <<"media_type">> => <<"image/png">>,
         <<"data">> => base64:encode(<<1, 2, 3, 4>>)},
       maps:get(<<"source">>, InlineBlock)),
    ?assertEqual(
       #{<<"type">> => <<"url">>,
         <<"url">> => <<"https://example.test/image.webp">>},
       maps:get(<<"source">>, UrlBlock)).

rejects_unsupported_image_inputs_test() ->
    {ok, Pdf} = adk_content:inline_data(
                  <<"application/pdf">>, <<"pdf">>),
    {ok, PdfContent} = adk_content:new([Pdf]),
    ?assertMatch(
       {error, {invalid_anthropic_content_part, 0,
                {unsupported_anthropic_image_mime, <<"application/pdf">>}}},
       adk_llm_anthropic_content:encode(user, PdfContent, #{})),
    {ok, Gs} = adk_content:file_data(
                 <<"image/png">>, <<"gs://bucket/image.png">>),
    {ok, GsContent} = adk_content:new([Gs]),
    ?assertMatch(
       {error, {invalid_anthropic_content_part, 0,
                unsupported_anthropic_image_url}},
       adk_llm_anthropic_content:encode(user, GsContent, #{})).

enforces_direct_api_base64_image_limit_test() ->
    %% 7,864,321 raw bytes encode to 10,485,764 base64 bytes: four bytes
    %% above Anthropic's documented 10 MiB direct-API image ceiling.
    Raw = binary:copy(<<0>>, 7864321),
    {ok, Inline} = adk_content:inline_data(<<"image/png">>, Raw),
    {ok, Content} = adk_content:new([Inline]),
    ?assertMatch(
       {error, {invalid_anthropic_content_part, 0,
                {anthropic_base64_image_too_large,
                 10485764, 10485760}}},
       adk_llm_anthropic_content:encode(user, Content, #{})).

encodes_tool_definitions_and_choice_test() ->
    Inline = #{<<"name">> => <<"calculator">>,
               <<"description">> => <<"Calculate">>,
               <<"parameters">> =>
                   #{<<"type">> => <<"object">>,
                     <<"additionalProperties">> => false},
               <<"strict">> => true},
    {ok, [Weather, Calculator]} =
        adk_llm_anthropic_request:encode_tools(
          [adk_anthropic_fixture_tool, Inline]),
    ?assertEqual(<<"weather">>, maps:get(<<"name">>, Weather)),
    ?assertEqual(false, maps:is_key(<<"parameters">>, Weather)),
    ?assert(is_map(maps:get(<<"input_schema">>, Weather))),
    ?assertEqual(true, maps:get(<<"strict">>, Calculator)),
    Config = #{model => <<"claude-test">>,
               tool_choice => {tool, <<"weather">>}},
    {ok, Payload} = adk_llm_anthropic_request:build(
                      Config,
                      [#{role => user, content => <<"Weather?">>}],
                      [adk_anthropic_fixture_tool, Inline], true),
    ?assertEqual(true, maps:get(<<"stream">>, Payload)),
    ?assertEqual(#{<<"type">> => <<"tool">>,
                   <<"name">> => <<"weather">>},
                 maps:get(<<"tool_choice">>, Payload)),
    ?assertEqual([Weather, Calculator], maps:get(<<"tools">>, Payload)).

accepts_current_128_byte_tool_name_limit_test() ->
    Name = binary:copy(<<"a">>, 128),
    {ok, [Tool]} = adk_llm_anthropic_request:encode_tools(
                     [#{<<"name">> => Name,
                        <<"parameters">> => #{}}]),
    ?assertEqual(Name, maps:get(<<"name">>, Tool)),
    ?assertMatch(
       {error, {invalid_anthropic_tool, 0, invalid_tool_name}},
       adk_llm_anthropic_request:encode_tools(
         [#{<<"name">> => <<Name/binary, "a">>,
            <<"parameters">> => #{}}])).

encodes_tool_call_and_result_replay_test() ->
    History = [
        #{role => user, content => <<"Weather in Pune?">>},
        #{role => agent,
          content => {tool_calls,
                      [{<<"weather">>, #{<<"city">> => <<"Pune">>},
                        undefined, <<"toolu_1">>}]}},
        #{role => tool,
          content => {tool_response, <<"weather">>,
                      #{<<"celsius">> => 27}, undefined, <<"toolu_1">>}}
    ],
    {ok, Payload} = adk_llm_anthropic_request:build(
                      #{model => <<"claude-test">>}, History,
                      [adk_anthropic_fixture_tool]),
    [_User, Assistant, ToolUser] = maps:get(<<"messages">>, Payload),
    [ToolUse] = maps:get(<<"content">>, Assistant),
    ?assertEqual(<<"tool_use">>, maps:get(<<"type">>, ToolUse)),
    ?assertEqual(<<"toolu_1">>, maps:get(<<"id">>, ToolUse)),
    [ToolResult] = maps:get(<<"content">>, ToolUser),
    ?assertEqual(<<"tool_result">>, maps:get(<<"type">>, ToolResult)),
    ?assertEqual(<<"toolu_1">>, maps:get(<<"tool_use_id">>, ToolResult)),
    ?assertEqual(#{<<"celsius">> => 27},
                 jsx:decode(maps:get(<<"content">>, ToolResult),
                            [return_maps])).

rejects_uncorrelated_or_provider_specific_tool_replay_test() ->
    Base = [#{role => user, content => <<"Use it">>}],
    MissingId = Base ++
        [#{role => agent,
           content => {tool_calls, [{<<"weather">>, #{}}]}}],
    ?assertMatch(
       {error, {missing_anthropic_tool_use_id, 0, <<"weather">>}},
       adk_llm_anthropic_request:build(
         #{model => <<"claude-test">>}, MissingId, [])),
    Signed = Base ++
        [#{role => agent,
           content => {tool_calls,
                       [{<<"weather">>, #{}, <<"gemini-signature">>,
                         <<"toolu_1">>}]}}],
    ?assertMatch(
       {error, {unsupported_anthropic_thought_signature, 0}},
       adk_llm_anthropic_request:build(
         #{model => <<"claude-test">>}, Signed, [])).

rejects_invalid_tools_and_duplicate_names_test() ->
    Duplicate = #{<<"name">> => <<"weather">>,
                  <<"parameters">> => #{}},
    ?assertEqual(
       {error, {duplicate_anthropic_tool_name, <<"weather">>}},
       adk_llm_anthropic_request:encode_tools(
         [adk_anthropic_fixture_tool, Duplicate])),
    Coercing = #{<<"name">> => <<"bad">>,
                 <<"parameters">> => #{atom_key => <<"value">>}},
    ?assertMatch(
       {error, {invalid_anthropic_tool, 0,
                tool_schema_must_be_canonical_json}},
       adk_llm_anthropic_request:encode_tools([Coercing])),
    ?assertMatch(
       {error, {invalid_anthropic_tool, 0, invalid_tool_name}},
       adk_llm_anthropic_request:encode_tools(
         [#{<<"name">> => <<"invalid name">>,
            <<"parameters">> => #{}}])).

rejects_invalid_config_history_and_local_limits_test() ->
    ?assertEqual(
       {error, invalid_anthropic_model},
       adk_llm_anthropic_request:build(
         #{}, [#{role => user, content => <<"Hi">>}], [])),
    ?assertEqual(
       {error, anthropic_messages_required},
       adk_llm_anthropic_request:build(
         #{model => <<"claude-test">>},
         [#{role => system, content => <<"Only system">>}], [])),
    ?assertMatch(
       {error, invalid_or_oversized_anthropic_text},
       adk_llm_anthropic_request:build(
         #{model => <<"claude-test">>,
           content_limits => #{max_text_bytes => 3}},
         [#{role => user, content => <<"four">>}], [])),
    TooMany = lists:duplicate(
                1025, #{role => user, content => <<"x">>}),
    ?assertEqual(
       {error, {anthropic_history_limit_exceeded, 1024}},
       adk_llm_anthropic_request:build(
         #{model => <<"claude-test">>}, TooMany, [])).

enforces_conservative_cross_model_image_count_test() ->
    {ok, Url} = adk_content:file_data(
                  <<"image/png">>, <<"https://example.test/image.png">>),
    {ok, ImageContent} = adk_content:new([Url]),
    History = lists:duplicate(
                101, #{role => user, content => ImageContent}),
    ?assertEqual(
       {error, {anthropic_image_limit_exceeded, 100}},
       adk_llm_anthropic_request:build(
         #{model => <<"claude-test">>}, History, [])).

strict_generation_options_test() ->
    Memory = [#{role => user, content => <<"Hi">>}],
    ?assertEqual(
       {error, {invalid_anthropic_option, temperature}},
       adk_llm_anthropic_request:build(
         #{model => <<"claude-test">>, temperature => 2}, Memory, [])),
    ?assertEqual(
       {error, invalid_anthropic_stop_sequences},
       adk_llm_anthropic_request:build(
         #{model => <<"claude-test">>, stop_sequences => []}, Memory, [])),
    ?assertEqual(
       {error, anthropic_tool_choice_requires_tools},
       adk_llm_anthropic_request:build(
         #{model => <<"claude-test">>, tool_choice => any}, Memory, [])).
