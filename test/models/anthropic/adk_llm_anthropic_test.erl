-module(adk_llm_anthropic_test).

-include_lib("eunit/include/eunit.hrl").

generate_messages_flow_and_headers_test() ->
    Config = config({response, 200, response(
                                        [#{<<"type">> => <<"text">>,
                                           <<"text">> => <<"Hello">>}])}),
    Result = adk_llm_anthropic:generate(
               Config, [#{role => user, content => <<"hello">>}], []),
    {ok, {ok, <<"Hello">>}, _} = adk_provider_result:decode(Result),
    receive
        {model_http_request, Request} ->
            ?assertEqual(<<"https://anthropic.test/v1/messages">>,
                         maps:get(url, Request)),
            Headers = maps:from_list(maps:get(headers, Request)),
            ?assertEqual(<<"test-anthropic-key">>,
                         maps:get(<<"x-api-key">>, Headers)),
            ?assertEqual(<<"2023-06-01">>,
                         maps:get(<<"anthropic-version">>, Headers)),
            Payload = jsx:decode(maps:get(body, Request), [return_maps]),
            ?assertEqual(false, maps:get(<<"stream">>, Payload)),
            ?assertEqual(1024, maps:get(<<"max_tokens">>, Payload))
    after 1000 -> ?assert(false)
    end.

capabilities_report_ga_structured_output_test() ->
    ?assertEqual(true,
                 maps:get(structured_output,
                          adk_llm_anthropic:capabilities())).

stream_delivers_fragmented_named_events_test() ->
    Events = [{<<"message_start">>, message_start()},
              {<<"content_block_start">>,
               #{<<"index">> => 0,
                 <<"content_block">> =>
                     #{<<"type">> => <<"text">>, <<"text">> => <<>>}}},
              {<<"content_block_delta">>,
               #{<<"index">> => 0,
                 <<"delta">> =>
                     #{<<"type">> => <<"text_delta">>,
                       <<"text">> => <<"Hi">>}}},
              {<<"content_block_stop">>, #{<<"index">> => 0}},
              {<<"message_delta">>,
               #{<<"delta">> => #{<<"stop_reason">> => <<"end_turn">>},
                 <<"usage">> => #{<<"output_tokens">> => 2}}},
              {<<"message_stop">>, #{}}],
    Wire = iolist_to_binary([sse(Name, Fields) || {Name, Fields} <- Events]),
    <<A:11/binary, B:23/binary, C/binary>> = Wire,
    Parent = self(),
    Result = adk_llm_anthropic:stream(
               config({stream, 200, [A, B, C], <<>>}),
               [#{role => user, content => <<"hello">>}], [],
               fun(Delta) -> Parent ! {anthropic_delta, Delta}, ok end),
    ?assertEqual([<<"Hi">>], drain(anthropic_delta, [])),
    {ok, streamed, _} = adk_provider_result:decode(Result),
    receive {model_http_stream_request, _} -> ok
    after 1000 -> ?assert(false)
    end.

tool_use_round_trip_keeps_provider_call_id_test() ->
    Result = adk_llm_anthropic:generate(
               config({response, 200,
                       response([#{<<"type">> => <<"tool_use">>,
                                   <<"id">> => <<"toolu_1">>,
                                   <<"name">> => <<"weather">>,
                                   <<"input">> =>
                                       #{<<"city">> => <<"Pune">>}}])}),
               [#{role => user, content => <<"weather">>}], []),
    {ok, {tool_calls, Calls}, _} = adk_provider_result:decode(Result),
    ?assertEqual([{<<"weather">>, #{<<"city">> => <<"Pune">>},
                   undefined, <<"toolu_1">>}], Calls),
    receive {model_http_request, _} -> ok after 1000 -> ?assert(false) end.

configuration_is_strict_and_secret_safe_test() ->
    Secret = <<"anthropic-secret-must-not-leak">>,
    ?assertEqual(
       {error, {unknown_anthropic_options, [temperatur]}},
       adk_llm_anthropic:validate_config(
         (base_config())#{temperatur => 0.2})),
    Error = adk_llm_anthropic:generate(
              config({response, 429,
                      #{<<"type">> => <<"error">>,
                        <<"error">> =>
                            #{<<"type">> => <<"rate_limit_error">>,
                              <<"message">> => Secret},
                        <<"request_id">> => <<"req_1">>}}),
              [#{role => user, content => <<"hello">>}], []),
    ?assertEqual(
       {error, {anthropic_api_error, 429,
                <<"rate_limit_error">>, <<"req_1">>}}, Error),
    ?assertEqual(nomatch, binary:match(term_to_binary(Error), Secret)),
    receive {model_http_request, _} -> ok after 1000 -> ?assert(false) end.

credential_origin_is_https_and_environment_bound_test() ->
    Previous = os:getenv("ANTHROPIC_API_KEY"),
    true = os:putenv("ANTHROPIC_API_KEY", "ambient-anthropic-key"),
    try
        ?assertEqual(
           {error, invalid_model_https_base_url},
           adk_llm_anthropic:validate_config(
             #{model => <<"claude-test">>,
               base_url => <<"http://api.anthropic.com/v1">>})),
        Custom = #{model => <<"claude-test">>,
                   base_url => <<"https://attacker.invalid/v1">>,
                   http_transport =>
                       {adk_model_fixture_transport,
                        {self(), {response, 200,
                                  response([#{<<"type">> => <<"text">>,
                                              <<"text">> => <<"never">>}])}}}},
        ?assertEqual(
           {error, custom_endpoint_requires_explicit_api_key},
           adk_llm_anthropic:validate_config(Custom)),
        ?assertEqual(
           {error, custom_endpoint_requires_explicit_api_key},
           adk_llm_anthropic:generate(
             Custom, [#{role => user, content => <<"hello">>}], [])),
        receive
            {model_http_request, _} -> ?assert(false)
        after 0 -> ok
        end
    after
        restore_env("ANTHROPIC_API_KEY", Previous)
    end.

config(Fixture) ->
    (base_config())#{api_key => <<"test-anthropic-key">>,
                     http_transport =>
                         {adk_model_fixture_transport, {self(), Fixture}}}.

base_config() ->
    #{model => <<"claude-test">>,
      base_url => <<"https://anthropic.test/v1">>}.

response(Blocks) ->
    #{<<"id">> => <<"msg_1">>, <<"type">> => <<"message">>,
      <<"role">> => <<"assistant">>, <<"model">> => <<"claude-test">>,
      <<"content">> => Blocks, <<"stop_reason">> => <<"end_turn">>,
      <<"stop_sequence">> => null,
      <<"usage">> => #{<<"input_tokens">> => 4,
                         <<"output_tokens">> => 2}}.

message_start() ->
    #{<<"message">> =>
          #{<<"id">> => <<"msg_stream_1">>, <<"type">> => <<"message">>,
            <<"role">> => <<"assistant">>, <<"model">> => <<"claude-test">>,
            <<"content">> => [], <<"stop_reason">> => null,
            <<"stop_sequence">> => null,
            <<"usage">> => #{<<"input_tokens">> => 4,
                               <<"output_tokens">> => 1}}}.

sse(Name, Fields) ->
    [<<"event: ">>, Name, <<"\n">>,
     <<"data: ">>, jsx:encode(Fields#{<<"type">> => Name}), <<"\n\n">>].

drain(Tag, Acc) ->
    receive
        {Tag, Value} -> drain(Tag, [Value | Acc])
    after 0 -> lists:reverse(Acc)
    end.

restore_env(Name, false) -> os:unsetenv(Name);
restore_env(Name, Value) -> os:putenv(Name, Value).
