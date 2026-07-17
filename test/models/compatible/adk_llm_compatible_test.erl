-module(adk_llm_compatible_test).

-include_lib("eunit/include/eunit.hrl").

generate_uses_fixed_chat_completions_path_and_bearer_auth_test() ->
    Config = config({response, 200, text_response(<<"Hello">>)}),
    Result = adk_llm_compatible:generate(
               Config, [#{role => user, content => <<"hello">>}], []),
    {ok, {ok, <<"Hello">>}, _Action} =
        adk_provider_result:decode(Result),
    receive
        {model_http_request, Request} ->
            ?assertEqual(
               <<"https://compatible.test/v1/chat/completions">>,
               maps:get(url, Request)),
            Headers = maps:from_list(maps:get(headers, Request)),
            ?assertEqual(<<"Bearer test-compatible-key">>,
                         maps:get(<<"authorization">>, Headers)),
            ?assertEqual(false, maps:is_key(<<"x-api-key">>, Headers)),
            Payload = jsx:decode(maps:get(body, Request), [return_maps]),
            ?assertEqual(<<"vendor-model">>, maps:get(<<"model">>, Payload)),
            ?assertEqual(false, maps:get(<<"stream">>, Payload))
    after 1000 -> ?assert(false)
    end.

fixed_auth_modes_allow_x_api_key_and_keyless_local_test() ->
    XConfig = (config({response, 200, text_response(<<"x">>)}))#{
                auth_scheme => x_api_key},
    XResult = adk_llm_compatible:generate(
                XConfig, [#{role => user, content => <<"x">>}], []),
    {ok, {ok, <<"x">>}, _} = adk_provider_result:decode(XResult),
    receive
        {model_http_request, XRequest} ->
            XHeaders = maps:from_list(maps:get(headers, XRequest)),
            ?assertEqual(<<"test-compatible-key">>,
                         maps:get(<<"x-api-key">>, XHeaders)),
            ?assertEqual(false,
                         maps:is_key(<<"authorization">>, XHeaders))
    after 1000 -> ?assert(false)
    end,
    NoneConfig = #{model => <<"local-model">>,
                   base_url => <<"https://local.test/v1">>,
                   auth_scheme => none,
                   http_transport =>
                       {adk_model_fixture_transport,
                        {self(), {response, 200,
                                  text_response(<<"local">>)}}}},
    NoneResult = adk_llm_compatible:generate(
                   NoneConfig,
                   [#{role => user, content => <<"local">>}], []),
    {ok, {ok, <<"local">>}, _} =
        adk_provider_result:decode(NoneResult),
    receive
        {model_http_request, NoneRequest} ->
            NoneHeaders = maps:from_list(maps:get(headers, NoneRequest)),
            ?assertEqual(false,
                         maps:is_key(<<"authorization">>, NoneHeaders)),
            ?assertEqual(false,
                         maps:is_key(<<"x-api-key">>, NoneHeaders))
    after 1000 -> ?assert(false)
    end.

stream_preserves_fragmented_and_coalesced_deltas_test() ->
    First = sse(stream_chunk(
                  #{<<"role">> => <<"assistant">>,
                    <<"content">> => <<"Hel">>}, null)),
    Final = <<(sse(stream_chunk(
                    #{<<"content">> => <<"lo">>}, <<"stop">>)))/binary,
              "data: [DONE]\n\n">>,
    <<A:13/binary, B/binary>> = First,
    Parent = self(),
    Config = config({stream, 200, [A, B, Final], <<>>}),
    Result = adk_llm_compatible:stream(
               Config, [#{role => user, content => <<"hello">>}], [],
               fun(Delta) ->
                   Parent ! {compatible_delta, Delta},
                   ok
               end),
    ?assertEqual([<<"Hel">>, <<"lo">>],
                 drain(compatible_delta, [])),
    {ok, streamed, Action} = adk_provider_result:decode(Result),
    ?assertEqual(<<"stop">>,
                 maps:get(<<"finish_reason">>,
                          maps:get(<<"metadata">>, Action))),
    receive
        {model_http_stream_request, Request} ->
            ?assertEqual(
               <<"https://compatible.test/v1/chat/completions">>,
               maps:get(url, Request)),
            Payload = jsx:decode(maps:get(body, Request), [return_maps]),
            ?assertEqual(true, maps:get(<<"stream">>, Payload))
    after 1000 -> ?assert(false)
    end.

content_stream_emits_canonical_text_parts_test() ->
    Wire = <<(sse(stream_chunk(
                   #{<<"content">> => <<"canonical">>},
                   <<"stop">>)))/binary,
             "data: [DONE]\n\n">>,
    Parent = self(),
    Result = adk_llm_compatible:stream_content(
               config({stream, 200, [Wire], <<>>}),
               [#{role => user, content => <<"hello">>}], [],
               fun(Content) ->
                   Parent ! {compatible_content, Content},
                   ok
               end),
    {ok, streamed, _} = adk_provider_result:decode(Result),
    receive
        {compatible_content, Content} ->
            ?assertEqual([<<"canonical">>],
                         adk_llm_compatible_content:text_parts(Content))
    after 1000 -> ?assert(false)
    end,
    receive {model_http_stream_request, _} -> ok
    after 1000 -> ?assert(false)
    end.

parallel_tool_calls_keep_provider_ids_test() ->
    Message = #{<<"role">> => <<"assistant">>,
                <<"content">> => null,
                <<"tool_calls">> =>
                    [wire_call(<<"call-a">>, <<"weather">>,
                               #{<<"city">> => <<"Pune">>}),
                     wire_call(<<"call-b">>, <<"time">>,
                               #{<<"zone">> => <<"UTC">>})]},
    Response = response(Message, <<"tool_calls">>),
    Result = adk_llm_compatible:generate(
               config({response, 200, Response}),
               [#{role => user, content => <<"tools">>}], []),
    {ok, {tool_calls, Calls}, _} = adk_provider_result:decode(Result),
    ?assertEqual(
       [{<<"weather">>, #{<<"city">> => <<"Pune">>},
         undefined, <<"call-a">>},
        {<<"time">>, #{<<"zone">> => <<"UTC">>},
         undefined, <<"call-b">>}], Calls),
    receive {model_http_request, _} -> ok
    after 1000 -> ?assert(false)
    end.

large_valid_sse_event_has_json_envelope_headroom_test() ->
    Text = binary:copy(<<"x">>, 1100000),
    Wire = <<(sse(stream_chunk(
                   #{<<"content">> => Text}, <<"stop">>)))/binary,
             "data: [DONE]\n\n">>,
    Parent = self(),
    Config = (config({stream, 200, [Wire], <<>>}))#{
                content_limits => #{max_text_bytes => 1200000}},
    Result = adk_llm_compatible:stream_content(
               Config, [#{role => user, content => <<"large">>}], [],
               fun(Content) ->
                   [Part] = adk_content:parts(Content),
                   Delta = maps:get(<<"text">>, Part),
                   Parent ! {large_delta, byte_size(Delta)},
                   ok
               end),
    ?assertEqual([1100000], drain(large_delta, [])),
    {ok, streamed, _} = adk_provider_result:decode(Result),
    receive {model_http_stream_request, _} -> ok
    after 1000 -> ?assert(false)
    end.

configuration_and_remote_errors_are_secret_safe_test() ->
    Secret = <<"compatible-secret-must-not-leak">>,
    ?assertEqual(
       {error, compatible_https_base_url_required},
       adk_llm_compatible:validate_config(
         (base_config())#{base_url => <<"http://compatible.test/v1">>})),
    ?assertEqual(
       {error, invalid_compatible_auth_scheme},
       adk_llm_compatible:validate_config(
         (base_config())#{auth_scheme => <<"bearer">>})),
    ?assertEqual(
       {error, {unknown_compatible_options, [headers]}},
       adk_llm_compatible:validate_config(
         (base_config())#{headers => [{<<"authorization">>, Secret}]})),
    ?assertEqual(
       {error, {invalid_compatible_option, api_key, redacted}},
       adk_llm_compatible:validate_config(
         (base_config())#{api_key => {Secret}})),
    ErrorBody = #{<<"error">> =>
                      #{<<"code">> => <<"rate_limit">>,
                        <<"message">> => Secret,
                        <<"param">> => Secret}},
    Error = adk_llm_compatible:generate(
              config({response, 429, ErrorBody}),
              [#{role => user, content => <<"hello">>}], []),
    ?assertEqual(
       {error, {http_status, 429,
                {compatible_api_error, <<"rate_limit">>}}}, Error),
    ?assertEqual(nomatch, binary:match(term_to_binary(Error), Secret)),
    receive {model_http_request, _} -> ok
    after 1000 -> ?assert(false)
    end,
    Public = adk_llm_compatible:public_config(
               (base_config())#{api_key => Secret,
                                http_transport => {secret_transport,
                                                   Secret}}),
    ?assertEqual(adk_secret_redactor:marker(), maps:get(api_key, Public)),
    ?assertEqual(false, maps:is_key(http_transport, Public)),
    ?assertEqual(nomatch, binary:match(term_to_binary(Public), Secret)).

capability_projection_reflects_structured_output_gate_test() ->
    ?assertEqual(true,
                 maps:get(structured_output,
                          adk_llm_compatible:capabilities())),
    ?assertEqual(false,
                 maps:get(structured_output,
                          adk_llm_compatible:capabilities(
                            #{response_format => unsupported}))).

ambient_compatible_key_is_never_sent_to_caller_endpoint_test() ->
    Previous = os:getenv("OPENAI_COMPATIBLE_API_KEY"),
    true = os:putenv("OPENAI_COMPATIBLE_API_KEY",
                     "ambient-compatible-key"),
    try
        Config = (base_config())#{
                   http_transport =>
                       {adk_model_fixture_transport,
                        {self(), {response, 200,
                                  text_response(<<"never">>)}}}},
        ?assertEqual(
           {error, compatible_api_key_required},
           adk_llm_compatible:validate_config(Config)),
        ?assertEqual(
           {error, compatible_api_key_required},
           adk_llm_compatible:generate(
             Config, [#{role => user, content => <<"hello">>}], [])),
        receive
            {model_http_request, _} -> ?assert(false)
        after 0 -> ok
        end
    after
        restore_env("OPENAI_COMPATIBLE_API_KEY", Previous)
    end.

config(Fixture) ->
    (base_config())#{api_key => <<"test-compatible-key">>,
                     http_transport =>
                         {adk_model_fixture_transport, {self(), Fixture}}}.

base_config() ->
    #{model => <<"vendor-model">>,
      base_url => <<"https://compatible.test/v1">>}.

text_response(Text) ->
    response(#{<<"role">> => <<"assistant">>,
               <<"content">> => Text}, <<"stop">>).

response(Message, FinishReason) ->
    #{<<"id">> => <<"chatcmpl-1">>,
      <<"model">> => <<"vendor-model">>,
      <<"choices">> =>
          [#{<<"index">> => 0,
             <<"message">> => Message,
             <<"finish_reason">> => FinishReason}],
      <<"usage">> => #{<<"prompt_tokens">> => 3,
                         <<"completion_tokens">> => 1,
                         <<"total_tokens">> => 4}}.

stream_chunk(Delta, FinishReason) ->
    #{<<"id">> => <<"chatcmpl-stream-1">>,
      <<"model">> => <<"vendor-model">>,
      <<"choices">> =>
          [#{<<"index">> => 0,
             <<"delta">> => Delta,
             <<"finish_reason">> => FinishReason}]}.

wire_call(Id, Name, Args) ->
    #{<<"id">> => Id,
      <<"type">> => <<"function">>,
      <<"function">> =>
          #{<<"name">> => Name,
            <<"arguments">> => jsx:encode(Args)}}.

sse(Map) ->
    <<"data: ", (jsx:encode(Map))/binary, "\n\n">>.

drain(Tag, Acc) ->
    receive
        {Tag, Value} -> drain(Tag, [Value | Acc])
    after 0 -> lists:reverse(Acc)
    end.

restore_env(Name, false) -> os:unsetenv(Name);
restore_env(Name, Value) -> os:putenv(Name, Value).
