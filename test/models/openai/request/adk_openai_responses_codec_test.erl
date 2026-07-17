-module(adk_openai_responses_codec_test).

-include_lib("eunit/include/eunit.hrl").

encode_request_with_tools_and_structured_output_test() ->
    Schema = #{<<"type">> => <<"object">>,
               <<"properties">> =>
                   #{<<"answer">> => #{<<"type">> => <<"string">>}},
               <<"required">> => [<<"answer">>],
               <<"additionalProperties">> => false},
    Tool = #{<<"name">> => <<"lookup">>,
             <<"description">> => <<"Look something up">>,
             <<"parameters">> =>
                 #{<<"type">> => <<"object">>,
                   <<"properties">> =>
                       #{<<"q">> => #{<<"type">> => <<"string">>}}}},
    Config = #{model => <<"gpt-test">>,
               max_tokens => 128,
               temperature => 0.2,
               top_p => 0.9,
               parallel_tool_calls => true,
               response_schema => Schema,
               response_schema_name => <<"answer_shape">>,
               response_mime_type => <<"application/json">>},
    {ok, Payload} = adk_openai_responses_codec:encode_request(
                      Config,
                      [#{role => system, content => <<"Be concise">>},
                       #{role => user, content => <<"Question">>}],
                      [Tool], true),
    ?assertEqual(<<"gpt-test">>, maps:get(<<"model">>, Payload)),
    ?assertEqual(<<"Be concise">>, maps:get(<<"instructions">>, Payload)),
    ?assertEqual(true, maps:get(<<"stream">>, Payload)),
    ?assertEqual(false, maps:get(<<"store">>, Payload)),
    ?assertEqual(128, maps:get(<<"max_output_tokens">>, Payload)),
    ?assertEqual(0.2, maps:get(<<"temperature">>, Payload)),
    ?assertEqual(0.9, maps:get(<<"top_p">>, Payload)),
    ?assertEqual(true, maps:get(<<"parallel_tool_calls">>, Payload)),
    [EncodedTool] = maps:get(<<"tools">>, Payload),
    ?assertEqual(<<"function">>, maps:get(<<"type">>, EncodedTool)),
    #{<<"format">> := Format} = maps:get(<<"text">>, Payload),
    ?assertEqual(<<"json_schema">>, maps:get(<<"type">>, Format)),
    ?assertEqual(<<"answer_shape">>, maps:get(<<"name">>, Format)),
    ?assertEqual(true, maps:get(<<"strict">>, Format)),
    ?assertEqual(Schema, maps:get(<<"schema">>, Format)).

encode_json_object_and_plain_text_formats_test() ->
    Base = #{model => <<"gpt-test">>},
    History = [#{role => user, content => <<"hello">>}],
    {ok, JsonPayload} = adk_openai_responses_codec:encode_request(
                          Base#{response_mime_type =>
                                    <<"application/json">>},
                          History, [], false),
    ?assertEqual(
       #{<<"format">> => #{<<"type">> => <<"json_object">>}},
       maps:get(<<"text">>, JsonPayload)),
    {ok, TextPayload} = adk_openai_responses_codec:encode_request(
                          Base#{response_mime_type => <<"text/plain">>},
                          History, [], false),
    ?assertEqual(false, maps:is_key(<<"text">>, TextPayload)).

structured_schema_is_normalized_to_binary_json_keys_test() ->
    {ok, Payload} = adk_openai_responses_codec:encode_request(
                      #{model => <<"gpt-test">>,
                        response_schema =>
                            #{type => object,
                              properties => #{answer => #{type => string}}}},
                      [#{role => user, content => <<"hello">>}], [], false),
    #{<<"format">> := #{<<"schema">> := Schema}} =
        maps:get(<<"text">>, Payload),
    ?assertEqual(<<"object">>, maps:get(<<"type">>, Schema)),
    ?assertEqual(false, maps:is_key(type, Schema)).

encode_request_rejects_invalid_options_test() ->
    History = [#{role => user, content => <<"hello">>}],
    ?assertEqual(
       {error, invalid_openai_model},
       adk_openai_responses_codec:encode_request(#{}, History, [], false)),
    ?assertEqual(
       {error, conflicting_openai_max_tokens},
       adk_openai_responses_codec:encode_request(
         #{model => <<"gpt-test">>, max_tokens => 1,
           max_output_tokens => 2}, History, [], false)),
    ?assertEqual(
       {error, {invalid_openai_option, temperature}},
       adk_openai_responses_codec:encode_request(
         #{model => <<"gpt-test">>, temperature => 3},
         History, [], false)),
    ?assertEqual(
       {error, unsupported_openai_response_mime_type},
       adk_openai_responses_codec:encode_request(
         #{model => <<"gpt-test">>,
           response_mime_type => <<"image/png">>},
         History, [], false)),
    ?assertEqual(
       {error, openai_input_required},
       adk_openai_responses_codec:encode_request(
         #{model => <<"gpt-test">>},
         [#{role => system, content => <<"only instructions">>}],
         [], false)).

decode_text_response_and_usage_test() ->
    Response = completed_response(
                 [text_item(<<"Hello ">>), text_item(<<"world">>)],
                 #{<<"input_tokens">> => 12,
                   <<"input_tokens_details">> =>
                       #{<<"cached_tokens">> => 3},
                   <<"output_tokens">> => 4,
                   <<"output_tokens_details">> =>
                       #{<<"reasoning_tokens">> => 2},
                   <<"total_tokens">> => 16}),
    {ok, ProviderResult} =
        adk_openai_responses_codec:decode_response(Response, #{}),
    {ok, {ok, <<"Hello world">>}, Action} =
        adk_provider_result:decode(ProviderResult),
    Metadata = maps:get(<<"metadata">>, Action),
    ?assertEqual(<<"resp_1">>, maps:get(<<"response_id">>, Metadata)),
    ?assertEqual(<<"gpt-test-2026-01-01">>,
                 maps:get(<<"response_model">>, Metadata)),
    ?assertEqual(
       #{<<"input_tokens">> => 12,
         <<"cached_input_tokens">> => 3,
         <<"output_tokens">> => 4,
         <<"reasoning_tokens">> => 2,
         <<"total_tokens">> => 16},
       maps:get(<<"usage">>, Metadata)).

decode_function_calls_response_test() ->
    Calls = [#{<<"type">> => <<"function_call">>,
               <<"id">> => <<"fc_1">>,
               <<"call_id">> => <<"call_1">>,
               <<"name">> => <<"first">>,
               <<"arguments">> => <<"{\"n\":1}">>},
             #{<<"type">> => <<"function_call">>,
               <<"id">> => <<"fc_2">>,
               <<"call_id">> => <<"call_2">>,
               <<"name">> => <<"second">>,
               <<"arguments">> => <<"{\"n\":2}">>}],
    {ok, ProviderResult} = adk_openai_responses_codec:decode_response(
                             completed_response(Calls, undefined), #{}),
    {ok, {tool_calls, Decoded}, _Metadata} =
        adk_provider_result:decode(ProviderResult),
    ?assertEqual(
       [{<<"first">>, #{<<"n">> => 1}, undefined, <<"call_1">>},
        {<<"second">>, #{<<"n">> => 2}, undefined, <<"call_2">>}],
       Decoded).

response_failures_are_sanitized_test() ->
    Secret = <<"sk-secret and prompt text">>,
    Failed = #{<<"status">> => <<"failed">>,
               <<"error">> => #{<<"code">> => <<"server_error">>,
                                  <<"message">> => Secret}},
    ?assertEqual(
       {error, {openai_api_error, <<"server_error">>}},
       adk_openai_responses_codec:decode_response(Failed, #{})),
    ?assertEqual(
       {error, {openai_api_error, <<"unknown">>}},
       adk_openai_responses_codec:decode_api_error(
         #{<<"error">> => #{<<"code">> => Secret,
                              <<"message">> => Secret}})),
    Incomplete = #{<<"status">> => <<"incomplete">>,
                   <<"incomplete_details">> =>
                       #{<<"reason">> => <<"max_output_tokens">>}},
    ?assertEqual(
       {error, {openai_response_incomplete, <<"max_output_tokens">>}},
       adk_openai_responses_codec:decode_response(Incomplete, #{})),
    ?assertEqual(
       {error, invalid_openai_response_status},
       adk_openai_responses_codec:decode_response(
         #{<<"status">> => <<"mystery">>}, #{})).

invalid_usage_and_response_bounds_test() ->
    BadUsage = completed_response(
                 [text_item(<<"ok">>)],
                 #{<<"input_tokens">> => -1}),
    ?assertEqual({error, invalid_openai_usage},
                 adk_openai_responses_codec:decode_response(BadUsage, #{})),
    LongText = completed_response(
                 [text_item(<<"four">>)], undefined),
    ?assertMatch(
       {error, _},
       adk_openai_responses_codec:decode_response(
         LongText, #{max_text_bytes => 3})).

completed_response(Output, Usage) ->
    Base = #{<<"id">> => <<"resp_1">>,
             <<"object">> => <<"response">>,
             <<"status">> => <<"completed">>,
             <<"error">> => null,
             <<"model">> => <<"gpt-test-2026-01-01">>,
             <<"output">> => Output},
    case Usage of
        undefined -> Base;
        _ -> Base#{<<"usage">> => Usage}
    end.

text_item(Text) ->
    #{<<"type">> => <<"message">>,
      <<"role">> => <<"assistant">>,
      <<"status">> => <<"completed">>,
      <<"content">> =>
          [#{<<"type">> => <<"output_text">>,
             <<"text">> => Text,
             <<"annotations">> => []}]}.
