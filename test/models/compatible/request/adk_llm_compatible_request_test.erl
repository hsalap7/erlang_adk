-module(adk_llm_compatible_request_test).

-include_lib("eunit/include/eunit.hrl").

request_builds_tools_parallel_calls_and_json_schema_test() ->
    Secret = <<"request-api-secret-must-not-enter-json">>,
    Schema = #{<<"type">> => <<"object">>,
               <<"properties">> =>
                   #{<<"answer">> => #{<<"type">> => <<"string">>}},
               <<"required">> => [<<"answer">>]},
    Config = #{model => <<"vendor-model">>,
               api_key => Secret,
               base_url => <<"https://trusted.example/v1">>,
               temperature => 0.2,
               max_tokens => 512,
               parallel_tool_calls => true,
               tool_choice => required,
               response_schema => Schema,
               response_schema_name => <<"answer">>,
               stream_include_usage => true},
    {ok, Payload} = adk_llm_compatible_request:build(
                      Config,
                      [#{role => user, content => <<"Question">>}],
                      [tool_schema()], true),
    ?assertEqual(<<"vendor-model">>, maps:get(<<"model">>, Payload)),
    ?assertEqual(true, maps:get(<<"stream">>, Payload)),
    ?assertEqual(true, maps:get(<<"parallel_tool_calls">>, Payload)),
    ?assertEqual(<<"required">>, maps:get(<<"tool_choice">>, Payload)),
    ?assertEqual(#{<<"include_usage">> => true},
                 maps:get(<<"stream_options">>, Payload)),
    Format = maps:get(<<"response_format">>, Payload),
    ?assertEqual(<<"json_schema">>, maps:get(<<"type">>, Format)),
    JsonSchema = maps:get(<<"json_schema">>, Format),
    ?assertEqual(Schema, maps:get(<<"schema">>, JsonSchema)),
    ?assertEqual(nomatch,
                 binary:match(jsx:encode(Payload), Secret)),
    assert_binary_json_keys(Payload).

structured_output_capability_gate_is_explicit_test() ->
    Base = #{model => <<"vendor-model">>,
             response_mime_type => <<"application/json">>},
    Memory = [#{role => user, content => <<"Question">>}],
    {ok, JsonObject} = adk_llm_compatible_request:build(
                         Base, Memory, []),
    ?assertEqual(#{<<"type">> => <<"json_object">>},
                 maps:get(<<"response_format">>, JsonObject)),
    ?assertEqual(
       {error, compatible_structured_output_unsupported},
       adk_llm_compatible_request:build(
         Base#{response_format => unsupported}, Memory, [])),
    ?assertEqual(
       {error, invalid_compatible_response_format},
       adk_llm_compatible_request:build(
         Base#{response_format => text}, Memory, [])).

one_shot_text_response_decodes_metadata_test() ->
    Response = base_response(
                 #{<<"role">> => <<"assistant">>,
                   <<"content">> => <<"Hello">>}, <<"stop">>),
    {ok, Result} = adk_llm_compatible_request:decode_response(Response, #{}),
    {ok, {ok, <<"Hello">>}, Action} = adk_provider_result:decode(Result),
    Metadata = maps:get(<<"metadata">>, Action),
    ?assertEqual(<<"chatcmpl-1">>, maps:get(<<"response_id">>, Metadata)),
    ?assertEqual(#{<<"input_tokens">> => 4,
                   <<"output_tokens">> => 2,
                   <<"total_tokens">> => 6},
                 maps:get(<<"usage">>, Metadata)).

one_shot_parallel_tool_calls_decode_test() ->
    Message = #{<<"role">> => <<"assistant">>,
                <<"content">> => null,
                <<"tool_calls">> =>
                    [wire_call(<<"a">>, <<"weather">>,
                               #{<<"city">> => <<"Paris">>}),
                     wire_call(<<"b">>, <<"time">>,
                               #{<<"zone">> => <<"UTC">>})]},
    {ok, Result} = adk_llm_compatible_request:decode_response(
                     base_response(Message, <<"tool_calls">>), #{}),
    {ok, {tool_calls, Calls}, _Action} =
        adk_provider_result:decode(Result),
    ?assertEqual(2, length(Calls)).

truncated_filtered_and_inconsistent_finishes_fail_test() ->
    Text = #{<<"role">> => <<"assistant">>, <<"content">> => <<"x">>},
    ?assertEqual(
       {error, compatible_response_incomplete},
       adk_llm_compatible_request:decode_response(
         base_response(Text, <<"length">>), #{})),
    ?assertEqual(
       {error, compatible_response_filtered},
       adk_llm_compatible_request:decode_response(
         base_response(Text, <<"content_filter">>), #{})),
    ?assertEqual(
       {error, invalid_compatible_finish_reason},
       adk_llm_compatible_request:decode_response(
         base_response(Text, <<"tool_calls">>), #{})).

api_error_drops_remote_message_and_parameter_test() ->
    Secret = <<"provider-error-secret-must-not-leak">>,
    Body = #{<<"error">> =>
                 #{<<"message">> => Secret,
                   <<"param">> => Secret,
                   <<"type">> => <<"invalid_request_error">>,
                   <<"code">> => <<"bad_request">>}},
    Error = adk_llm_compatible_request:decode_error(Body),
    ?assertEqual({error, {compatible_api_error, <<"bad_request">>}},
                 Error),
    ?assertEqual(nomatch, binary:match(term_to_binary(Error), Secret)),
    UnsafeCode = <<"unsafe code: ", Secret/binary>>,
    Unsafe = adk_llm_compatible_request:decode_error(
               #{<<"error">> => #{<<"code">> => UnsafeCode}}),
    ?assertEqual({error, {compatible_api_error, <<"unknown">>}}, Unsafe),
    ?assertEqual(nomatch, binary:match(term_to_binary(Unsafe), Secret)).

request_limits_and_option_conflicts_are_values_test() ->
    Memory = [#{role => user, content => <<"Question">>}],
    ?assertEqual(
       {error, conflicting_compatible_max_tokens},
       adk_llm_compatible_request:build(
         #{model => <<"m">>, max_tokens => 1,
           max_completion_tokens => 2}, Memory, [])),
    ?assertEqual(
       {error, compatible_parallel_tool_calls_requires_tools},
       adk_llm_compatible_request:build(
         #{model => <<"m">>, parallel_tool_calls => true}, Memory, [])),
    ?assertEqual(
       {error, invalid_compatible_model},
       adk_llm_compatible_request:build(#{}, Memory, [])).

base_response(Message, FinishReason) ->
    #{<<"id">> => <<"chatcmpl-1">>,
      <<"model">> => <<"vendor-model">>,
      <<"system_fingerprint">> => <<"fp-1">>,
      <<"choices">> =>
          [#{<<"index">> => 0,
             <<"message">> => Message,
             <<"finish_reason">> => FinishReason}],
      <<"usage">> => #{<<"prompt_tokens">> => 4,
                         <<"completion_tokens">> => 2,
                         <<"total_tokens">> => 6}}.

tool_schema() ->
    #{<<"name">> => <<"weather">>,
      <<"description">> => <<"Get weather">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"city">> => #{<<"type">> => <<"string">>}}}}.

wire_call(Id, Name, Args) ->
    #{<<"id">> => Id,
      <<"type">> => <<"function">>,
      <<"function">> =>
          #{<<"name">> => Name,
            <<"arguments">> => jsx:encode(Args)}}.

assert_binary_json_keys(Map) when is_map(Map) ->
    ?assert(lists:all(fun is_binary/1, maps:keys(Map))),
    lists:foreach(fun({_Key, Value}) -> assert_binary_json_keys(Value) end,
                  maps:to_list(Map));
assert_binary_json_keys([Head | Tail]) ->
    assert_binary_json_keys(Head),
    assert_binary_json_keys(Tail);
assert_binary_json_keys([]) -> ok;
assert_binary_json_keys(_Value) -> ok.
