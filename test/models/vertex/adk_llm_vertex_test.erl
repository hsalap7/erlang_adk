-module(adk_llm_vertex_test).

-include_lib("eunit/include/eunit.hrl").

-define(RESOURCE,
        <<"projects/adk-demo/locations/us-central1/",
          "publishers/google/models/gemini-test">>).

regional_generate_uses_fixed_vertex_authority_and_gemini_codec_test() ->
    Secret = <<"vertex-oauth-secret">>,
    Response = generation_response(<<"hello">>),
    Config = (fixture_config({response, 200, Response}, Secret))#
      {temperature => 0.25,
       max_tokens => 64,
       safety_settings =>
           [#{category => harassment, threshold => block_only_high}]},
    Memory = [#{role => system, content => <<"Be concise.">>},
              #{role => user, content => <<"Hello">>}],
    Result = adk_llm_vertex:generate(Config, Memory, []),
    {ok, {ok, <<"hello">>}, ProviderMetadata} =
        adk_provider_result:decode(Result),
    ?assertEqual(<<"vertex_ai">>,
                 maps:get(<<"provider">>, ProviderMetadata)),
    ?assertEqual(<<"generation_metadata">>,
                 maps:get(<<"type">>, ProviderMetadata)),
    receive
        {model_http_request, Request} ->
            ?assertEqual(
               <<"https://us-central1-aiplatform.googleapis.com/v1/",
                 ?RESOURCE/binary, ":generateContent">>,
               maps:get(url, Request)),
            ?assertEqual([<<"us-central1-aiplatform.googleapis.com">>],
                         maps:get(allowed_hosts, Request)),
            ?assertEqual(false, maps:get(follow_redirects, Request)),
            ?assertEqual(false, maps:get(allow_private_hosts, Request)),
            Headers = maps:get(headers, Request),
            ?assertEqual(<<"Bearer ", Secret/binary>>,
                         proplists:get_value(<<"authorization">>, Headers)),
            ?assertEqual(undefined,
                         proplists:get_value(<<"x-goog-user-project">>,
                                             Headers)),
            Payload = jsx:decode(maps:get(body, Request), [return_maps]),
            ?assertEqual(
               #{<<"parts">> => [#{<<"text">> => <<"Be concise.">>}]},
               maps:get(<<"system_instruction">>, Payload)),
            Generation = maps:get(<<"generationConfig">>, Payload),
            ?assertEqual(0.25, maps:get(<<"temperature">>, Generation)),
            ?assertEqual(64, maps:get(<<"maxOutputTokens">>, Generation)),
            ?assertEqual(
               [#{<<"category">> => <<"HARM_CATEGORY_HARASSMENT">>,
                  <<"threshold">> => <<"BLOCK_ONLY_HIGH">>}],
               maps:get(<<"safetySettings">>, Payload))
    after 1000 -> ?assert(false)
    end.

global_resource_uses_global_vertex_origin_test() ->
    Resource = <<"projects/123456/locations/global/",
                 "publishers/google/models/gemini-test">>,
    Config = (fixture_config(
                {response, 200, generation_response(<<"ok">>)},
                <<"token">>))#{model => Resource},
    _ = adk_llm_vertex:generate(
          Config, [#{role => user, content => <<"hello">>}], []),
    receive
        {model_http_request, Request} ->
            ?assertEqual(
               <<"https://aiplatform.googleapis.com/v1/", Resource/binary,
                 ":generateContent">>, maps:get(url, Request)),
            ?assertEqual([<<"aiplatform.googleapis.com">>],
                         maps:get(allowed_hosts, Request))
    after 1000 -> ?assert(false)
    end.

fragmented_sse_stream_ignores_usage_tail_and_owns_query_test() ->
    First = stream_response([#{<<"text">> => <<"hel">>}]),
    Second = stream_response([#{<<"text">> => <<"lo">>}]),
    Usage = #{<<"usageMetadata">> => #{<<"totalTokenCount">> => 3}},
    Wire = iolist_to_binary(
             [[<<"data: ">>, jsx:encode(Event), <<"\r\n\r\n">>]
              || Event <- [First, Second, Usage]] ++
             [<<"data: [DONE]\r\n\r\n">>]),
    Chunks = split_three(Wire),
    Config = fixture_config(
               {stream, 200, Chunks, <<>>}, <<"stream-token">>),
    Callback = fun(Text) -> self() ! {vertex_delta, Text}, ok end,
    ?assertEqual(
       ok,
       adk_llm_vertex:stream(
         Config, [#{role => user, content => <<"stream">>}], [], Callback)),
    ?assertEqual([<<"hel">>, <<"lo">>], drain(vertex_delta, [])),
    receive
        {model_http_stream_request, Request} ->
            ?assertEqual(
               <<"https://us-central1-aiplatform.googleapis.com/v1/",
                 ?RESOURCE/binary,
                 ":streamGenerateContent?alt=sse">>,
               maps:get(url, Request)),
            ?assertEqual(<<"text/event-stream">>,
                         proplists:get_value(
                           <<"accept">>, maps:get(headers, Request)))
    after 1000 -> ?assert(false)
    end.

stream_preserves_function_call_order_signature_and_id_test() ->
    Call1 = function_call_part(<<"first">>, #{<<"a">> => 1},
                               <<"sig-1">>, <<"call-1">>),
    Call2 = function_call_part(<<"second">>, #{<<"b">> => 2},
                               <<"sig-2">>, <<"call-2">>),
    Wire = iolist_to_binary(
             [[<<"data: ">>, jsx:encode(stream_response([Call])),
               <<"\n\n">>] || Call <- [Call1, Call2]]),
    Config = fixture_config({stream, 200, [Wire], <<>>}, <<"token">>),
    ?assertEqual(
       {tool_calls,
        [{<<"first">>, #{<<"a">> => 1}, <<"sig-1">>, <<"call-1">>},
         {<<"second">>, #{<<"b">> => 2}, <<"sig-2">>, <<"call-2">>}]},
       adk_llm_vertex:stream(
         Config, [#{role => user, content => <<"tools">>}], [],
         fun(_Text) -> ok end)),
    drain_transport_messages().

content_stream_emits_canonical_content_test() ->
    Wire = iolist_to_binary(
             [<<"data: ">>,
              jsx:encode(stream_response([#{<<"text">> => <<"chunk">>}])),
              <<"\n\n">>]),
    Config = fixture_config({stream, 200, [Wire], <<>>}, <<"token">>),
    Callback = fun(Content) -> self() ! {vertex_content, Content}, ok end,
    ?assertEqual(
       ok,
       adk_llm_vertex:stream_content(
         Config, [#{role => user, content => <<"stream">>}], [], Callback)),
    receive
        {vertex_content, Content} ->
            ?assertEqual([<<"text">>], adk_content:part_types(Content))
    after 1000 -> ?assert(false)
    end,
    drain_transport_messages().

api_errors_are_status_only_and_never_include_remote_message_test() ->
    Secret = <<"remote-secret-message">>,
    Body = #{<<"error">> =>
                 #{<<"status">> => <<"PERMISSION_DENIED">>,
                   <<"message">> => Secret}},
    Error = adk_llm_vertex:generate(
              fixture_config({response, 403, Body}, <<"token">>),
              [#{role => user, content => <<"hello">>}], []),
    ?assertEqual(
       {error, {http_status, 403,
                {vertex_api_error, <<"PERMISSION_DENIED">>}}}, Error),
    ?assertEqual(nomatch, binary:match(term_to_binary(Error), Secret)),
    MaliciousStatus = #{<<"error">> =>
                            #{<<"status">> => Secret,
                              <<"message">> => <<"ignored">>}},
    Sanitized = adk_llm_vertex:generate(
                  fixture_config(
                    {response, 403, MaliciousStatus}, <<"token">>),
                  [#{role => user, content => <<"hello">>}], []),
    ?assertEqual(
       {error, {http_status, 403, {vertex_api_error, unknown}}},
       Sanitized),
    ?assertEqual(nomatch, binary:match(term_to_binary(Sanitized), Secret)),
    drain_transport_messages().

malformed_success_responses_are_data_free_test() ->
    Secret = <<"REMOTE_SECRET_RESPONSE_KEY">>,
    Body = #{<<"candidates">> =>
                 [#{<<"content">> =>
                        #{<<"parts">> => [#{Secret => <<"ignored">>}]}}]},
    GenerateError = adk_llm_vertex:generate(
                      fixture_config({response, 200, Body}, <<"token">>),
                      [#{role => user, content => <<"hello">>}], []),
    ?assertEqual({error, invalid_vertex_response}, GenerateError),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(GenerateError), Secret)),
    Wire = iolist_to_binary(
             [<<"data: ">>, jsx:encode(Body), <<"\n\n">>]),
    StreamError = adk_llm_vertex:stream(
                    fixture_config(
                      {stream, 200, [Wire], <<>>}, <<"token">>),
                    [#{role => user, content => <<"hello">>}], [],
                    fun(_Text) -> ok end),
    ?assertEqual({error, invalid_vertex_stream_response}, StreamError),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(StreamError), Secret)),
    InvalidUsage = iolist_to_binary(
                     [<<"data: ">>,
                      jsx:encode(#{<<"usageMetadata">> => Secret}),
                      <<"\n\n">>]),
    ?assertEqual(
       {error, invalid_vertex_stream_response},
       adk_llm_vertex:stream(
         fixture_config({stream, 200, [InvalidUsage], <<>>}, <<"token">>),
         [#{role => user, content => <<"hello">>}], [],
         fun(_Text) -> ok end)),
    drain_transport_messages().

invalid_content_does_not_acquire_adc_test() ->
    Config = #{model => ?RESOURCE,
               credential_source => google_adc,
               adc_token_provider =>
                   {adk_google_adc_fixture,
                    {self(), {ok, <<"must-not-be-requested">>}}}},
    ?assertMatch(
       {error, _},
       adk_llm_vertex:generate(Config, [invalid_message], [])),
    receive
        google_adc_requested -> ?assert(false)
    after 0 -> ok
    end.

config_contract_rejects_authority_and_unsupported_features_test() ->
    Base = base_config(<<"token">>),
    InvalidResources = [
        <<"projects/p/locations/us-central1/publishers/acme/models/m">>,
        <<"projects/p/locations/US-CENTRAL1/publishers/google/models/m">>,
        <<"projects/p/locations/", (binary:copy(<<"a">>, 53))/binary,
          "/publishers/google/models/m">>,
        <<"projects/../locations/global/publishers/google/models/m">>,
        <<"projects/p/locations/-us-central1/publishers/google/models/m">>,
        <<"/projects/p/locations/global/publishers/google/models/m">>,
        <<"projects/p/locations/global/publishers/google/models/m/extra">>,
        <<"projects/p/locations/global/publishers/google/models/m%2Fother">>,
        <<"projects/p/locations/global/endpoints/123">>
    ],
    lists:foreach(
      fun(Resource) ->
          ?assertEqual(
             {error, invalid_vertex_model_resource},
             adk_llm_vertex:validate_config(Base#{model => Resource}))
      end, InvalidResources),
    ?assertEqual(
       {error, {unknown_vertex_options, [base_url]}},
       adk_llm_vertex:validate_config(
         Base#{base_url => <<"https://attacker.invalid">>})),
    lists:foreach(
      fun({Key, Value}) ->
          ?assertMatch(
             {error, {unknown_vertex_options, [_]}},
             adk_llm_vertex:validate_config(Base#{Key => Value}))
      end,
      [{candidate_count, 2}, {thinking_config, #{thinking_level => high}},
       {builtin_tools, [google_search]}, {context_cache, #{}}]),
    ?assertEqual(
       {error, {unknown_vertex_generation_options, [candidate_count]}},
       adk_llm_vertex:validate_config(
         Base#{generation_config => #{candidate_count => 2}})),
    ?assertEqual(
       {error, conflicting_vertex_oauth_credentials},
       adk_llm_vertex:validate_config(
         Base#{credential_source => google_adc})),
    ?assertEqual(
       {error, vertex_oauth_credential_required},
       adk_llm_vertex:validate_config(maps:remove(api_key, Base))).

callback_failures_and_stream_limits_are_deterministic_test() ->
    Wire = iolist_to_binary(
             [<<"data: ">>,
              jsx:encode(stream_response([#{<<"text">> => <<"x">>}])),
              <<"\n\n">>]),
    Config = fixture_config({stream, 200, [Wire], <<>>}, <<"token">>),
    ?assertEqual(
       {error, invalid_stream_callback_result},
       adk_llm_vertex:stream(
         Config, [#{role => user, content => <<"x">>}], [],
         fun(_Text) -> ignored end)),
    ?assertEqual(
       {error, {stream_callback_failed, error}},
       adk_llm_vertex:stream(
         Config, [#{role => user, content => <<"x">>}], [],
         fun(_Text) -> erlang:error(callback_secret) end)),
    TwoEvents = <<Wire/binary, Wire/binary>>,
    Limited = (fixture_config(
                {stream, 200, [TwoEvents], <<>>}, <<"token">>))#
      {max_stream_events => 1},
    ?assertEqual(
       {error, sse_event_count_limit_exceeded},
       adk_llm_vertex:stream(
         Limited, [#{role => user, content => <<"x">>}], [],
         fun(_Text) -> ok end)),
    drain_transport_messages().

public_config_and_capability_ceiling_are_conservative_test() ->
    Secret = <<"public-config-secret">>,
    Config = fixture_config({response, 200, generation_response(<<"ok">>)},
                            Secret),
    Public = adk_llm_vertex:public_config(Config),
    ?assertEqual(false, maps:is_key(http_transport, Public)),
    ?assertEqual(false, maps:is_key(adc_token_provider, Public)),
    ?assertEqual(nomatch, binary:match(term_to_binary(Public), Secret)),
    Capabilities = adk_llm_vertex:capabilities(),
    lists:foreach(
      fun(Key) -> ?assertEqual(true, maps:get(Key, Capabilities)) end,
      [generate, streaming, content_streaming, function_calling,
       parallel_function_calling, generation_config, safety_settings,
       structured_output, multimodal]),
    ?assertEqual(false, maps:get(live, Capabilities)),
    ?assertEqual(false, maps:get(context_caching, Capabilities)),
    ?assertEqual([], maps:get(builtin_tools, Capabilities)),
    ?assertEqual(false, maps:is_key(google_search_grounding, Capabilities)),
    ?assertEqual(false, maps:is_key(candidate_count, Capabilities)).

fixture_config(Fixture, Token) ->
    (base_config(Token))#{http_transport =>
                              {adk_model_fixture_transport,
                               {self(), Fixture}}}.

base_config(Token) ->
    #{model => ?RESOURCE, api_key => Token}.

generation_response(Text) ->
    #{<<"candidates">> =>
          [#{<<"content">> => #{<<"parts">> => [#{<<"text">> => Text}]},
             <<"finishReason">> => <<"STOP">>}],
      <<"modelVersion">> => <<"gemini-test-001">>,
      <<"usageMetadata">> =>
          #{<<"promptTokenCount">> => 2,
            <<"candidatesTokenCount">> => 1,
            <<"totalTokenCount">> => 3}}.

stream_response(Parts) ->
    #{<<"candidates">> =>
          [#{<<"content">> => #{<<"parts">> => Parts}}]}.

function_call_part(Name, Args, Signature, Id) ->
    #{<<"functionCall">> =>
          #{<<"name">> => Name, <<"args">> => Args, <<"id">> => Id},
      <<"thoughtSignature">> => Signature}.

split_three(Binary) ->
    FirstSize = erlang:min(17, byte_size(Binary)),
    <<First:FirstSize/binary, Rest/binary>> = Binary,
    SecondSize = erlang:min(31, byte_size(Rest)),
    <<Second:SecondSize/binary, Third/binary>> = Rest,
    [First, Second, Third].

drain(Tag, Acc) ->
    receive
        {Tag, Value} -> drain(Tag, [Value | Acc])
    after 0 -> lists:reverse(Acc)
    end.

drain_transport_messages() ->
    receive
        {model_http_request, _} -> drain_transport_messages();
        {model_http_stream_request, _} -> drain_transport_messages()
    after 0 -> ok
    end.
