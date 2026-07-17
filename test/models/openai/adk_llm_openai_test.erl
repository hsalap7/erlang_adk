-module(adk_llm_openai_test).

-include_lib("eunit/include/eunit.hrl").

generate_uses_responses_api_and_returns_canonical_result_test() ->
    Response = completed_response([text_item(<<"Hello from OpenAI">>)]),
    Config = config({response, 200, Response}),
    Result = adk_llm_openai:generate(
               Config, [#{role => user, content => <<"hello">>}], []),
    {ok, {ok, <<"Hello from OpenAI">>}, _Metadata} =
        adk_provider_result:decode(Result),
    receive
        {model_http_request, Request} ->
            ?assertEqual(<<"https://api.test/v1/responses">>,
                         maps:get(url, Request)),
            Headers = maps:from_list(maps:get(headers, Request)),
            ?assertEqual(<<"Bearer test-openai-key">>,
                         maps:get(<<"authorization">>, Headers)),
            Payload = jsx:decode(maps:get(body, Request), [return_maps]),
            ?assertEqual(<<"gpt-test">>, maps:get(<<"model">>, Payload)),
            ?assertEqual(false, maps:get(<<"stream">>, Payload))
    after 1000 -> ?assert(false)
    end.

stream_delivers_fragmented_sse_text_and_metadata_test() ->
    Events = [text_delta(1, <<"Hel">>),
              text_delta(2, <<"lo">>),
              text_done(3, <<"Hello">>),
              #{<<"type">> => <<"response.completed">>,
                <<"sequence_number">> => 4,
                <<"response">> =>
                    completed_response([text_item(<<"Hello">>)])}],
    Wire = iolist_to_binary(
             [[<<"data: ">>, jsx:encode(Event), <<"\n\n">>]
              || Event <- Events]),
    <<First:17/binary, Second:29/binary, Rest/binary>> = Wire,
    Config = config({stream, 200, [First, Second, Rest], <<>>}),
    Parent = self(),
    Result = adk_llm_openai:stream(
               Config, [#{role => user, content => <<"hello">>}], [],
               fun(Delta) -> Parent ! {openai_delta, Delta}, ok end),
    ?assertEqual([<<"Hel">>, <<"lo">>], drain(openai_delta, [])),
    {ok, {ok, <<"Hello">>}, _} = adk_provider_result:decode(Result),
    receive
        {model_http_stream_request, Request} ->
            Payload = jsx:decode(maps:get(body, Request), [return_maps]),
            ?assertEqual(true, maps:get(<<"stream">>, Payload))
    after 1000 -> ?assert(false)
    end.

tool_response_preserves_parallel_call_ids_test() ->
    Calls = [#{<<"type">> => <<"function_call">>,
               <<"id">> => <<"fc_1">>, <<"call_id">> => <<"call_1">>,
               <<"name">> => <<"weather">>,
               <<"arguments">> => <<"{\"city\":\"Pune\"}">>},
             #{<<"type">> => <<"function_call">>,
               <<"id">> => <<"fc_2">>, <<"call_id">> => <<"call_2">>,
               <<"name">> => <<"time">>,
               <<"arguments">> => <<"{\"zone\":\"UTC\"}">>}],
    Result = adk_llm_openai:generate(
               config({response, 200, completed_response(Calls)}),
               [#{role => user, content => <<"tools">>}], []),
    {ok, {tool_calls, Decoded}, _} = adk_provider_result:decode(Result),
    ?assertEqual(
       [{<<"weather">>, #{<<"city">> => <<"Pune">>}, undefined,
         <<"call_1">>},
        {<<"time">>, #{<<"zone">> => <<"UTC">>}, undefined,
         <<"call_2">>}], Decoded),
    receive {model_http_request, _} -> ok after 1000 -> ?assert(false) end.

errors_and_config_are_sanitized_test() ->
    Secret = <<"prompt and secret must not escape">>,
    ErrorBody = #{<<"error">> =>
                      #{<<"code">> => <<"rate_limit_exceeded">>,
                        <<"message">> => Secret}},
    Error = adk_llm_openai:generate(
              config({response, 429, ErrorBody}),
              [#{role => user, content => <<"hello">>}], []),
    ?assertEqual(
       {error, {http_status, 429,
                {openai_api_error, <<"rate_limit_exceeded">>}}}, Error),
    ?assertEqual(nomatch, binary:match(term_to_binary(Error), Secret)),
    receive {model_http_request, _} -> ok after 1000 -> ?assert(false) end,
    ?assertEqual(
       {error, {unknown_openai_options, [temperatur]}},
       adk_llm_openai:validate_config(
         (base_config())#{temperatur => 0.2})),
    ?assertEqual(
       {error, {invalid_openai_option, api_key, redacted}},
       adk_llm_openai:validate_config(
         (base_config())#{api_key => {Secret}})).

credential_origin_is_https_and_environment_bound_test() ->
    Previous = os:getenv("OPENAI_API_KEY"),
    true = os:putenv("OPENAI_API_KEY", "ambient-openai-key"),
    try
        ?assertEqual(
           {error, invalid_model_https_base_url},
           adk_llm_openai:validate_config(
             #{model => <<"gpt-test">>,
               base_url => <<"http://api.openai.com/v1">>})),
        Custom = #{model => <<"gpt-test">>,
                   base_url => <<"https://attacker.invalid/v1">>,
                   http_transport =>
                       {adk_model_fixture_transport,
                        {self(), {response, 200,
                                  completed_response(
                                    [text_item(<<"never">>)])}}}},
        ?assertEqual(
           {error, custom_endpoint_requires_explicit_api_key},
           adk_llm_openai:validate_config(Custom)),
        ?assertEqual(
           {error, custom_endpoint_requires_explicit_api_key},
           adk_llm_openai:generate(
             Custom, [#{role => user, content => <<"hello">>}], [])),
        receive
            {model_http_request, _} -> ?assert(false)
        after 0 -> ok
        end
    after
        restore_env("OPENAI_API_KEY", Previous)
    end.

config(Fixture) ->
    (base_config())#{api_key => <<"test-openai-key">>,
                     http_transport =>
                         {adk_model_fixture_transport, {self(), Fixture}}}.

base_config() ->
    #{model => <<"gpt-test">>, base_url => <<"https://api.test/v1">>}.

completed_response(Output) ->
    #{<<"id">> => <<"resp_1">>, <<"object">> => <<"response">>,
      <<"status">> => <<"completed">>, <<"error">> => null,
      <<"model">> => <<"gpt-test-2026-01-01">>, <<"output">> => Output,
      <<"usage">> => #{<<"input_tokens">> => 2,
                         <<"output_tokens">> => 1,
                         <<"total_tokens">> => 3}}.

text_item(Text) ->
    #{<<"type">> => <<"message">>, <<"id">> => <<"msg_1">>,
      <<"role">> => <<"assistant">>, <<"status">> => <<"completed">>,
      <<"content">> =>
          [#{<<"type">> => <<"output_text">>, <<"text">> => Text,
             <<"annotations">> => []}]}.

text_delta(Sequence, Delta) ->
    #{<<"type">> => <<"response.output_text.delta">>,
      <<"sequence_number">> => Sequence, <<"item_id">> => <<"msg_1">>,
      <<"output_index">> => 0, <<"content_index">> => 0,
      <<"delta">> => Delta}.

text_done(Sequence, Text) ->
    #{<<"type">> => <<"response.output_text.done">>,
      <<"sequence_number">> => Sequence, <<"item_id">> => <<"msg_1">>,
      <<"output_index">> => 0, <<"content_index">> => 0,
      <<"text">> => Text}.

drain(Tag, Acc) ->
    receive
        {Tag, Value} -> drain(Tag, [Value | Acc])
    after 0 -> lists:reverse(Acc)
    end.

restore_env(Name, false) -> os:unsetenv(Name);
restore_env(Name, Value) -> os:putenv(Name, Value).
