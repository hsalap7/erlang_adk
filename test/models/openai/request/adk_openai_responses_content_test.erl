-module(adk_openai_responses_content_test).

-include_lib("eunit/include/eunit.hrl").

history_text_multimodal_and_tools_test() ->
    {ok, UserText} = adk_content:text(<<"look">>),
    {ok, Inline} = adk_content:inline_data(<<"image/png">>, <<1, 2, 3>>),
    {ok, Remote} = adk_content:file_data(
                     <<"image/jpeg">>, <<"https://example.test/cat.jpg">>),
    {ok, UserContent} = adk_content:new([UserText, Inline, Remote]),
    {ok, AgentText} = adk_content:text(<<"checking">>),
    {ok, AgentCall} = adk_content:function_call(
                        <<"weather">>, #{<<"city">> => <<"Paris">>},
                        #{id => <<"call_1">>}),
    {ok, AgentContent} = adk_content:new([AgentText, AgentCall]),
    {ok, ToolPart} = adk_content:function_response(
                       <<"weather">>, #{<<"c">> => 18},
                       #{id => <<"call_1">>}),
    {ok, ToolContent} = adk_content:new([ToolPart]),
    History = [#{role => system, content => <<"Be exact.">>},
               #{role => system, content => <<"No guessing.">>},
               #{role => user, content => UserContent},
               #{role => agent, content => AgentContent},
               #{role => tool, content => ToolContent}],

    {ok, <<"Be exact.\nNo guessing.">>, Items} =
        adk_openai_responses_content:encode_history(History, #{}),
    [User, Assistant, FunctionCall, FunctionOutput] = Items,
    ?assertEqual(<<"user">>, maps:get(<<"role">>, User)),
    [#{<<"type">> := <<"input_text">>, <<"text">> := <<"look">>},
     #{<<"type">> := <<"input_image">>, <<"image_url">> := DataUrl},
     #{<<"type">> := <<"input_image">>,
       <<"image_url">> := <<"https://example.test/cat.jpg">>}] =
        maps:get(<<"content">>, User),
    ?assertEqual(<<"data:image/png;base64,AQID">>, DataUrl),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Assistant)),
    ?assertEqual(<<"function_call">>, maps:get(<<"type">>, FunctionCall)),
    ?assertEqual(<<"call_1">>, maps:get(<<"call_id">>, FunctionCall)),
    ?assertEqual(#{<<"city">> => <<"Paris">>},
                 jsx:decode(maps:get(<<"arguments">>, FunctionCall),
                            [return_maps])),
    ?assertEqual(<<"function_call_output">>,
                 maps:get(<<"type">>, FunctionOutput)),
    ?assertEqual(#{<<"c">> => 18},
                 jsx:decode(maps:get(<<"output">>, FunctionOutput),
                            [return_maps])).

legacy_call_and_response_require_call_id_test() ->
    ?assertEqual(
       {error, openai_tool_call_id_required},
       adk_openai_responses_content:encode_history(
         [#{role => agent,
            content => {tool_calls, [{<<"weather">>, #{}, undefined}]}}],
         #{})),
    ?assertEqual(
       {error, openai_tool_call_id_required},
       adk_openai_responses_content:encode_history(
         [#{role => tool,
            content => {tool_response, <<"weather">>, #{}, undefined}}],
         #{})),
    {ok, <<>>, [Call, Output]} =
        adk_openai_responses_content:encode_history(
          [#{role => agent,
             content => {tool_calls,
                         [{<<"weather">>, #{}, undefined, <<"call_2">>}]}},
           #{role => tool,
             content => {tool_response, <<"weather">>,
                         #{<<"ok">> => true}, undefined, <<"call_2">>}}],
          #{}),
    ?assertEqual(<<"call_2">>, maps:get(<<"call_id">>, Call)),
    ?assertEqual(<<"call_2">>, maps:get(<<"call_id">>, Output)).

unsupported_multimodal_input_is_rejected_test() ->
    {ok, Audio} = adk_content:inline_data(<<"audio/wav">>, <<1, 2>>),
    {ok, AudioContent} = adk_content:new([Audio]),
    ?assertEqual(
       {error, unsupported_openai_inline_media},
       adk_openai_responses_content:encode_history(
         [#{role => user, content => AudioContent}], #{})),
    {ok, Svg} = adk_content:inline_data(
                  <<"image/svg+xml">>, <<"<svg/>">>),
    {ok, SvgContent} = adk_content:new([Svg]),
    ?assertEqual(
       {error, unsupported_openai_inline_media},
       adk_openai_responses_content:encode_history(
         [#{role => user, content => SvgContent}], #{})),
    {ok, GsImage} = adk_content:file_data(
                      <<"image/png">>, <<"gs://bucket/image.png">>),
    {ok, GsContent} = adk_content:new([GsImage]),
    ?assertEqual(
       {error, unsupported_openai_file_media},
       adk_openai_responses_content:encode_history(
         [#{role => user, content => GsContent}], #{})).

tool_schema_projection_and_validation_test() ->
    Schema = #{<<"name">> => <<"get_weather">>,
               <<"description">> => <<"Current weather">>,
               <<"parameters">> =>
                   #{<<"type">> => <<"object">>,
                     <<"properties">> =>
                         #{<<"city">> => #{<<"type">> => <<"string">>}},
                     <<"required">> => [<<"city">>],
                     <<"additionalProperties">> => false},
               <<"strict">> => true,
               <<"internal_extension">> => <<"must not leak">>},
    {ok, [Encoded]} =
        adk_openai_responses_content:encode_tools([Schema]),
    ?assertEqual(<<"function">>, maps:get(<<"type">>, Encoded)),
    ?assertEqual(true, maps:get(<<"strict">>, Encoded)),
    ?assertEqual(false, maps:is_key(<<"internal_extension">>, Encoded)),
    ?assertEqual(
       {error, duplicate_openai_tool_name},
       adk_openai_responses_content:encode_tools([Schema, Schema])),
    ?assertEqual(
       {error, invalid_openai_tool_name},
       adk_openai_responses_content:encode_tools(
         [Schema#{<<"name">> => <<"bad name">>}])),
    {ok, [Normalized]} = adk_openai_responses_content:encode_tools(
                           [#{name => <<"atom_tool">>,
                              parameters => #{type => object}}]),
    ?assertEqual(<<"atom_tool">>, maps:get(<<"name">>, Normalized)),
    ?assertEqual(false, maps:is_key(name, Normalized)).

decode_text_reasoning_and_function_call_test() ->
    Output = [#{<<"type">> => <<"reasoning">>, <<"summary">> => []},
              #{<<"type">> => <<"message">>,
                <<"role">> => <<"assistant">>,
                <<"content">> =>
                    [#{<<"type">> => <<"output_text">>,
                       <<"text">> => <<"I will check.">>,
                       <<"annotations">> => []}]},
              #{<<"type">> => <<"function_call">>,
                <<"id">> => <<"fc_1">>,
                <<"call_id">> => <<"call_1">>,
                <<"name">> => <<"get_weather">>,
                <<"arguments">> => <<"{\"city\":\"Paris\"}">>}],
    {ok, Content, Calls} =
        adk_openai_responses_content:decode_output(Output, #{}),
    ?assertEqual([<<"text">>, <<"function_call">>],
                 adk_content:part_types(Content)),
    ?assertEqual([<<"I will check.">>],
                 adk_openai_responses_content:text_parts(Content)),
    ?assertEqual(
       [{<<"get_weather">>, #{<<"city">> => <<"Paris">>},
         undefined, <<"call_1">>}], Calls),
    ?assertEqual(Calls,
                 adk_openai_responses_content:tool_calls(Content)).

decode_rejects_refusal_bad_arguments_and_bounds_test() ->
    Refusal = [#{<<"type">> => <<"message">>,
                 <<"role">> => <<"assistant">>,
                 <<"content">> =>
                     [#{<<"type">> => <<"refusal">>,
                        <<"refusal">> => <<"provider detail">>}]}],
    ?assertEqual({error, openai_model_refusal},
                 adk_openai_responses_content:decode_output(Refusal, #{})),
    BadCall = [#{<<"type">> => <<"function_call">>,
                 <<"call_id">> => <<"call_1">>,
                 <<"name">> => <<"tool">>,
                 <<"arguments">> => <<"[]">>}],
    ?assertEqual(
       {error, invalid_openai_function_arguments},
       adk_openai_responses_content:decode_output(BadCall, #{})),
    TooLong = [#{<<"type">> => <<"message">>,
                 <<"role">> => <<"assistant">>,
                 <<"content">> =>
                     [#{<<"type">> => <<"output_text">>,
                        <<"text">> => <<"four">>}]}],
    ?assertMatch(
       {error, _},
       adk_openai_responses_content:decode_output(
         TooLong, #{max_text_bytes => 3})).

history_and_tool_count_bounds_test() ->
    History = [#{role => user, content => <<"x">>}
               || _ <- lists:seq(1, 2049)],
    ?assertEqual(
       {error, {openai_history_limit_exceeded, 2048}},
       adk_openai_responses_content:encode_history(History, #{})),
    Tool = #{<<"name">> => <<"t">>,
             <<"parameters">> => #{<<"type">> => <<"object">>}},
    Tools = [Tool#{<<"name">> => <<"t", (integer_to_binary(N))/binary>>}
             || N <- lists:seq(1, 129)],
    ?assertEqual(
       {error, {openai_tool_limit_exceeded, 128}},
       adk_openai_responses_content:encode_tools(Tools)).
