-module(adk_llm_gemini_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

-export([init/2]).

setup() ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(gun),

    RequestTable = ets:new(gemini_requests, [set, public]),
    Dispatch = cowboy_router:compile([
        {'_', [{"/v1beta/models/:model", ?MODULE, #{request_table => RequestTable}}]}
    ]),

    {ok, _} = cowboy:start_clear(mock_gemini,
        [{port, 0}],
        #{env => #{dispatch => Dispatch}}
    ),

    Port = ranch:get_port(mock_gemini),
    BaseUrl = list_to_binary("http://127.0.0.1:" ++ integer_to_list(Port)),

    #{
        request_table => RequestTable,
        config => #{
            api_key => <<"test_key">>,
            base_url => BaseUrl,
            model => <<"gemini-test-model">>
        }
    }.

teardown(#{request_table := RequestTable}) ->
    cowboy:stop_listener(mock_gemini),
    ets:delete(RequestTable).

gemini_test_() ->
    {setup,
        fun setup/0,
        fun teardown/1,
        fun(State) ->
            [
                {"Generate text", ?_test(test_generate_text(State))},
                {"Generate tool call", ?_test(test_generate_tool_call(State))},
                {"Preserve parallel tool signatures", ?_test(test_generate_tool_signatures(State))},
                {"Missing API Key error", ?_test(test_missing_api_key())},
                {"Canonical request payload", ?_test(test_request_payload(State))},
                {"Use JSON Schema function declarations", ?_test(test_json_schema_tool_payload(State))},
                {"Thinking configuration payload", ?_test(test_thinking_payload(State))},
                {"Safety settings payload", ?_test(test_safety_payload(State))},
                {"Strict provider configuration", ?_test(test_strict_config(State))},
                {"Google Search request and grounded response", ?_test(test_google_search_grounding(State))},
                {"Grounded tool-call event metadata", ?_test(test_grounded_tool_call_event(State))},
                {"Reject malformed and oversized grounding", ?_test(test_invalid_grounding_metadata(State))},
                {"Keep thought summaries structured", ?_test(test_thought_summary_response(State))},
                {"Default model is consistent", ?_test(test_default_model(State))},
                {"Reject non-success HTTP statuses", ?_test(test_http_statuses(State))},
                {"Honor configured request timeouts", ?_test(test_request_timeout(State))},
                {"Stream incremental text deltas", ?_test(test_stream_text(State))},
                {"Preserve streamed tool signatures", ?_test(test_stream_tool_call(State))},
                {"Encode multimodal requests", ?_test(test_multimodal_request(State))},
                {"Decode multimodal responses", ?_test(test_multimodal_response(State))},
                {"Stream canonical content deltas", ?_test(test_stream_content(State))},
                {"Separate streamed thought summaries", ?_test(test_stream_thought_summary(State))},
                {"Ignore metadata-only stream frames", ?_test(test_stream_metadata_frame(State))},
                {"Accumulate streamed grounding metadata", ?_test(test_stream_grounding(State))},
                {"Finalize streamed grounding metadata", ?_test(test_stream_grounding_agent_event(State))},
                {"Persist grounded final event metadata", ?_test(test_grounding_event_persistence(State))},
                {"Reject non-text parts in text stream", ?_test(test_text_stream_rejects_multimodal(State))},
                {"Reject unsafe content before HTTP", ?_test(test_invalid_content_is_local_error(State))},
                {"Reject unknown provider parts", ?_test(test_unknown_response_part(State))}
            ]
        end
    }.

test_generate_text(#{config := Config}) ->
    History = [#{role => user, content => <<"Hello">>}],
    {ok, Res} = adk_llm_gemini:generate(Config, History, []),
    ?assertEqual(<<"Hello from mock Gemini">>, Res).

test_generate_tool_call(#{config := Config}) ->
    History = [#{role => user, content => <<"Trigger tool">>}],
    {tool_calls, Calls} = adk_llm_gemini:generate(Config, History, []),
    ?assertEqual([{<<"test_tool">>, #{<<"arg">> => <<"val">>}, undefined,
                   <<"call-test">>}], Calls).

test_generate_tool_signatures(#{config := Config}) ->
    History = [#{role => user, content => <<"Trigger signed tools">>}],
    {tool_calls, Calls} = adk_llm_gemini:generate(Config, History, []),
    ?assertEqual(
        [
            {<<"first_tool">>, #{<<"n">> => 1}, <<"sig-123">>, <<"call-1">>},
            {<<"second_tool">>, #{<<"n">> => 2}, undefined, <<"call-2">>}
        ],
        Calls
    ).

test_missing_api_key() ->
    %% Temporarily remove env var if it exists
    OldKey = os:getenv("GEMINI_API_KEY"),
    os:unsetenv("GEMINI_API_KEY"),
    try
        ?assertEqual({error, missing_api_key}, adk_llm_gemini:generate(#{}, [], [])),
        ?assertEqual(
            {error, missing_api_key},
            adk_llm_gemini:stream(#{}, [], [], fun(_) -> ok end)
        )
    after
        if OldKey =/= false -> os:putenv("GEMINI_API_KEY", OldKey); true -> ok end
    end.

test_request_payload(#{config := Config, request_table := RequestTable}) ->
    ets:delete_all_objects(RequestTable),
    InlineSchema = #{
        <<"name">> => <<"inline_tool">>,
        <<"description">> => <<"An inline schema">>,
        <<"parameters">> => #{<<"type">> => <<"object">>}
    },
    History = [
        #{role => system, content => <<"Be precise.">>},
        #{role => user, content => <<"Use the tool">>},
        #{
            role => agent,
            content => {tool_calls, [{<<"dummy_tool">>, #{<<"arg">> => <<"x">>},
                                      <<"sig-a">>, <<"call-a">>}]}
        },
        #{
            role => tool,
            content => {tool_response, <<"dummy_tool">>,
                        #{<<"result">> => <<"done">>}, <<"sig-a">>, <<"call-a">>}
        }
    ],
    ResponseSchema = #{<<"type">> => <<"object">>,
                       <<"properties">> =>
                           #{<<"answer">> => #{<<"type">> => <<"string">>}}},
    RequestConfig = Config#{temperature => 0.2,
                            max_tokens => 64,
                            seed => 7,
                            stop_sequences => [<<"STOP">>],
                            response_mime_type => <<"application/json">>,
                            response_schema => ResponseSchema},
    {ok, _} = adk_llm_gemini:generate(RequestConfig, History, [dummy_tool, InlineSchema]),

    #{body := Payload, headers := RequestHeaders} = last_request(RequestTable),
    ?assertEqual(<<"test_key">>,
                 maps:get(<<"x-goog-api-key">>, RequestHeaders)),
    #{<<"parts">> := SystemParts} = maps:get(<<"system_instruction">>, Payload),
    ?assertEqual([#{<<"text">> => <<"Be precise.">>}], SystemParts),

    Contents = maps:get(<<"contents">>, Payload),
    ?assert(lists:all(fun(#{<<"parts">> := Parts}) -> is_list(Parts) end, Contents)),
    [ModelContent] = [C || C = #{<<"role">> := <<"model">>} <- Contents],
    [ModelToolPart] = maps:get(<<"parts">>, ModelContent),
    ?assertEqual(<<"sig-a">>, maps:get(<<"thoughtSignature">>, ModelToolPart)),
    ?assertEqual(<<"call-a">>,
                 maps:get(<<"id">>, maps:get(<<"functionCall">>, ModelToolPart))),
    [ToolResponseContent] = [
        C
        || C = #{<<"parts">> := [#{<<"functionResponse">> := _}]} <- Contents
    ],
    [ToolResponsePart] = maps:get(<<"parts">>, ToolResponseContent),
    ?assertEqual(<<"sig-a">>, maps:get(<<"thoughtSignature">>, ToolResponsePart)),
    ?assertEqual(<<"call-a">>,
                 maps:get(<<"id">>, maps:get(<<"functionResponse">>, ToolResponsePart))),

    [#{<<"functionDeclarations">> := Declarations}] = maps:get(<<"tools">>, Payload),
    ?assert(lists:member(dummy_tool:schema(), Declarations)),
    ?assert(lists:member(InlineSchema, Declarations)),
    ?assertEqual(
        #{<<"temperature">> => 0.2,
          <<"maxOutputTokens">> => 64,
          <<"seed">> => 7,
          <<"stopSequences">> => [<<"STOP">>],
          <<"responseMimeType">> => <<"application/json">>,
          <<"responseSchema">> => ResponseSchema},
        maps:get(<<"generationConfig">>, Payload)
    ).

test_json_schema_tool_payload(
  #{config := Config, request_table := RequestTable}) ->
    ets:delete_all_objects(RequestTable),
    Schema =
        #{<<"name">> => <<"strict_tool">>,
          <<"description">> => <<"A strict JSON Schema tool">>,
          <<"parameters">> =>
              #{<<"type">> => <<"object">>,
                <<"properties">> =>
                    #{<<"selector">> =>
                          #{<<"oneOf">> =>
                                [#{<<"type">> => <<"integer">>},
                                 #{<<"type">> => <<"string">>}]}},
                <<"additionalProperties">> => false}},
    UnionSchema =
        #{<<"name">> => <<"nullable_union_tool">>,
          <<"parameters">> =>
              #{<<"type">> => <<"object">>,
                <<"properties">> =>
                    #{<<"value">> =>
                          #{<<"type">> => [<<"string">>, <<"null">>]}}}},
    BooleanSubschema =
        #{<<"name">> => <<"boolean_subschema_tool">>,
          <<"parameters">> =>
              #{<<"type">> => <<"object">>,
                <<"properties">> => #{<<"anything">> => true}}},
    BooleanTrue = #{<<"name">> => <<"accept_anything_tool">>,
                    <<"parameters">> => true},
    BooleanFalse = #{<<"name">> => <<"accept_nothing_tool">>,
                     <<"parameters">> => false},
    {ok, _} = adk_llm_gemini:generate(
                Config, [#{role => user, content => <<"Use the tool">>}],
                [Schema, UnionSchema, BooleanSubschema,
                 BooleanTrue, BooleanFalse]),
    #{body := Payload} = last_request(RequestTable),
    [#{<<"functionDeclarations">> := Declarations}] =
        maps:get(<<"tools">>, Payload),
    ?assertEqual(5, length(Declarations)),
    lists:foreach(
      fun({InputSchema, Declaration}) ->
          ?assertEqual(false,
                       maps:is_key(<<"parameters">>, Declaration)),
          ?assertEqual(maps:get(<<"parameters">>, InputSchema),
                       maps:get(<<"parametersJsonSchema">>, Declaration))
      end,
      lists:zip([Schema, UnionSchema, BooleanSubschema,
                 BooleanTrue, BooleanFalse], Declarations)).

test_thinking_payload(#{config := Config, request_table := RequestTable}) ->
    ets:delete_all_objects(RequestTable),
    Thinking = #{thinking_level => high, include_thoughts => true},
    {ok, _} = adk_llm_gemini:generate(
                Config#{thinking_config => Thinking},
                [#{role => user, content => <<"Think carefully">>}], []),
    #{body := Payload} = last_request(RequestTable),
    GenConfig = maps:get(<<"generationConfig">>, Payload),
    ?assertEqual(#{<<"thinkingLevel">> => <<"high">>,
                   <<"includeThoughts">> => true},
                 maps:get(<<"thinkingConfig">>, GenConfig)),
    ?assertEqual(
       {error, {invalid_gemini_option, thinking_config,
                #{thinking_level => low, thinking_budget => 256}}},
       adk_llm_gemini:validate_config(
         Config#{thinking_config =>
                     #{thinking_level => low, thinking_budget => 256}})).

test_safety_payload(#{config := Config, request_table := RequestTable}) ->
    ets:delete_all_objects(RequestTable),
    Settings = [#{category => hate_speech,
                  threshold => block_low_and_above},
                #{category => harassment,
                  threshold => block_only_high}],
    {ok, _} = adk_llm_gemini:generate(
                Config#{safety_settings => Settings},
                [#{role => user, content => <<"Apply safety policy">>}], []),
    #{body := Payload} = last_request(RequestTable),
    ?assertEqual(
       [#{<<"category">> => <<"HARM_CATEGORY_HATE_SPEECH">>,
          <<"threshold">> => <<"BLOCK_LOW_AND_ABOVE">>},
        #{<<"category">> => <<"HARM_CATEGORY_HARASSMENT">>,
          <<"threshold">> => <<"BLOCK_ONLY_HIGH">>}],
       maps:get(<<"safetySettings">>, Payload)),
    ?assertEqual(false, maps:is_key(<<"safetySettings">>,
                                    maps:get(<<"generationConfig">>,
                                             Payload, #{}))),
    ?assertEqual(
       {error, {invalid_gemini_option, safety_settings,
                {duplicate_category, harassment}}},
       adk_llm_gemini:validate_config(
         Config#{safety_settings =>
                     [#{category => harassment, threshold => off},
                      #{category => harassment,
                        threshold => block_none}]})),
    ?assertMatch(
       {error, {invalid_gemini_option, safety_settings,
                {invalid_setting, 0, invalid_category}}},
       adk_llm_gemini:validate_config(
         Config#{safety_settings =>
                     [#{category => civic_integrity,
                        threshold => block_only_high}]})).

test_strict_config(#{config := Config}) ->
    ?assertEqual(
       {error, {unknown_gemini_options, [temperatur]}},
       adk_llm_gemini:validate_config(Config#{temperatur => 0.2})),
    ?assertEqual(
       {error, {unknown_gemini_generation_options, [unsafe_passthrough]}},
       adk_llm_gemini:validate_config(
         Config#{generation_config => #{unsafe_passthrough => true}})),
    %% These are documented agent/runtime fields, not Gemini REST fields, but
    %% they legitimately share the immutable agent config passed to adapters.
    ?assertEqual(
       ok,
       adk_llm_gemini:validate_config(
         Config#{instructions => <<"local">>,
                 global_instruction => <<"global">>,
                 callbacks => [],
                 callback_config => #{application_value => 1},
                 callback_pid => self(),
                 sub_agents => #{},
                 max_tool_rounds => 4,
                 max_concurrent_invocations => 2})),
    ?assertEqual(
       {error, {conflicting_gemini_options,
                [max_output_tokens, max_tokens]}},
       adk_llm_gemini:validate_config(
         Config#{max_tokens => 10, max_output_tokens => 10})).

test_google_search_grounding(
  #{config := Config, request_table := RequestTable}) ->
    GroundedConfig = Config#{model => <<"grounded-response">>,
                             builtin_tools => [google_search]},
    ?assertEqual(ok, adk_llm_gemini:validate_config(GroundedConfig)),
    ?assertEqual(
       {error, {invalid_gemini_option, builtin_tools,
                [google_search, google_search]}},
       adk_llm_gemini:validate_config(
         Config#{builtin_tools => [google_search, google_search]})),
    ?assertEqual(
       {error, {invalid_gemini_option, builtin_tools,
                [<<"google_search">>]}},
       adk_llm_gemini:validate_config(
         Config#{builtin_tools => [<<"google_search">>]})),
    ?assertEqual(
       {error, {invalid_gemini_option, builtin_tools, [url_context]}},
       adk_llm_gemini:validate_config(
         Config#{builtin_tools => [url_context]})),

    ets:delete_all_objects(RequestTable),
    {provider_result, _} = Result = adk_llm_gemini:generate(
                                      GroundedConfig,
                                      [#{role => user,
                                         content => <<"Ground this answer">>}],
                                      [dummy_tool]),
    #{body := Payload} = last_request(RequestTable),
    ?assertEqual(
       [#{<<"googleSearch">> => #{}},
        #{<<"functionDeclarations">> => [dummy_tool:schema()]}],
       maps:get(<<"tools">>, Payload)),

    {ok, {ok, <<"Grounded answer">>}, ProviderMetadata} =
        adk_provider_result:decode(Result),
    ?assertEqual(<<"gemini">>,
                 maps:get(<<"provider">>, ProviderMetadata)),
    ?assertEqual(<<"google_search_grounding">>,
                 maps:get(<<"type">>, ProviderMetadata)),
    Grounding = maps:get(<<"metadata">>, ProviderMetadata),
    ?assertEqual([<<"erlang otp">>],
                 maps:get(<<"webSearchQueries">>, Grounding)),
    #{<<"renderedContent">> := RenderedContent} =
        maps:get(<<"searchEntryPoint">>, Grounding),
    %% HTML is retained as data for clients which implement Google's required
    %% search-suggestion display. The bundled console renders event JSON with
    %% textContent and therefore cannot execute this markup.
    ?assertEqual(<<"<div class=\"search\">Sources</div>">>,
                 RenderedContent),
    {ok, Capabilities} = adk_llm:capabilities(adk_llm_gemini),
    ?assertEqual(true, maps:get(google_search_grounding, Capabilities)),
    ?assertEqual([google_search], maps:get(builtin_tools, Capabilities)),
    {DevHtml, _Csp} = adk_dev_ui:render(),
    ?assertEqual(nomatch, binary:match(DevHtml, <<"innerHTML">>)),
    ?assertNotEqual(
       nomatch,
       binary:match(DevHtml, <<"textContent=JSON.stringify">>)).

test_grounded_tool_call_event(#{config := Config}) ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    AgentConfig = Config#{provider => adk_llm_gemini,
                          model => <<"grounded-tool-response">>,
                          builtin_tools => [google_search]},
    {ok, Agent} = erlang_adk:spawn_agent(
                    "GroundedToolCallAgent", AgentConfig, [dummy_tool]),
    try
        InputEvent = adk_event:new(
                       <<"user">>, <<"Search, then call the tool">>,
                       #{invocation_id => <<"grounded-tool-invocation">>}),
        {tool_calls, ToolEvent, Calls} = adk_agent:run_with_events(
                                           Agent, [InputEvent],
                                           <<"grounded-tool-invocation">>),
        ?assertEqual(
           [{<<"test_tool">>, #{<<"arg">> => <<"grounded">>},
             undefined, <<"grounded-call">>}], Calls),
        ProviderMetadata = maps:get(
                             <<"provider_metadata">>,
                             ToolEvent#adk_event.actions),
        ?assertEqual(<<"google_search_grounding">>,
                     maps:get(<<"type">>, ProviderMetadata)),
        ?assertMatch(
           #{<<"groundingChunks">> := [_]},
           maps:get(<<"metadata">>, ProviderMetadata))
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

test_invalid_grounding_metadata(#{config := Config}) ->
    ?assertEqual(
       {error, {invalid_grounding_metadata, metadata_must_be_map}},
       adk_llm_gemini:generate(
         Config#{model => <<"grounded-malformed">>,
                 builtin_tools => [google_search]},
         [#{role => user, content => <<"Malformed grounding">>}], [])),
    ?assertMatch(
       {error,
        {invalid_grounding_metadata,
         {metadata_too_large, _, 262144}}},
       adk_llm_gemini:generate(
         Config#{model => <<"grounded-oversize">>,
                 builtin_tools => [google_search]},
         [#{role => user, content => <<"Oversized grounding">>}], [])).

test_thought_summary_response(#{config := Config}) ->
    {ok, Content} = adk_llm_gemini:generate(
                      Config#{thinking_config =>
                                  #{thinking_level => high,
                                    include_thoughts => true}},
                      [#{role => user,
                         content => <<"Return a thought summary">>}], []),
    [Thought, Answer] = adk_content:parts(Content),
    ?assertEqual(true, maps:get(<<"thought">>, Thought)),
    ?assertEqual(<<"summary, not raw reasoning">>,
                 maps:get(<<"text">>, Thought)),
    ?assertEqual(false, maps:get(<<"thought">>, Answer, false)),
    ?assertEqual(<<"visible answer">>, maps:get(<<"text">>, Answer)).

test_default_model(#{config := Config, request_table := RequestTable}) ->
    DefaultConfig = maps:remove(model, Config),
    ets:delete_all_objects(RequestTable),
    {ok, _} = adk_llm_gemini:generate(
        DefaultConfig,
        [#{role => user, content => <<"Default generate">>}],
        []
    ),
    #{path := GeneratePath} = last_request(RequestTable),
    ?assertEqual(
        <<"/v1beta/models/gemini-3.1-flash-lite:generateContent">>,
        GeneratePath
    ),

    ets:delete_all_objects(RequestTable),
    ok = adk_llm_gemini:stream(
        DefaultConfig,
        [#{role => user, content => <<"Default stream">>}],
        [],
        fun(_) -> ok end
    ),
    #{path := StreamPath} = last_request(RequestTable),
    ?assertEqual(
        <<"/v1beta/models/gemini-3.1-flash-lite:streamGenerateContent">>,
        StreamPath
    ).

test_http_statuses(#{config := Config}) ->
    ErrorConfig = Config#{model => <<"http-error">>},
    ?assertEqual(
        {error, {http_status, 429, <<"rate limited">>}},
        adk_llm_gemini:generate(ErrorConfig, [], [])
    ),
    ?assertEqual(
        {error, {http_status, 429, <<"rate limited">>}},
        adk_llm_gemini:stream(ErrorConfig, [], [], fun(_) -> ok end)
    ).

test_request_timeout(#{config := Config}) ->
    SlowHistory = [#{role => user, content => <<"Delay response">>}],
    TimeoutConfig = Config#{request_timeout => 30},
    ?assertEqual(
        {error, timeout},
        adk_llm_gemini:generate(TimeoutConfig, SlowHistory, [])
    ),
    ?assertEqual(
        {error, timeout},
        adk_llm_gemini:stream(
          TimeoutConfig, SlowHistory, [], fun(_) -> ok end)
    ),
    ?assertEqual(
        {error, {invalid_request_timeout, -1}},
        adk_llm_gemini:generate(Config#{request_timeout => -1}, [], [])
    ),
    ?assertEqual(
        {error, {invalid_request_timeout, invalid}},
        adk_llm_gemini:stream(
          Config#{request_timeout => invalid}, [], [], fun(_) -> ok end)
    ).

test_stream_text(#{config := Config}) ->
    History = [#{role => user, content => <<"Stream me">>}],
    Ref = make_ref(),
    Caller = self(),
    Callback = fun(Delta) -> Caller ! {Ref, delta, Delta} end,

    spawn(fun() ->
        Result = adk_llm_gemini:stream(Config, History, [], Callback),
        Caller ! {Ref, done, Result}
    end),

    receive
        {Ref, delta, FirstDelta} ->
            ?assertEqual(<<"First delta">>, FirstDelta);
        {Ref, done, EarlyResult} ->
            ?assertEqual(first_delta_should_arrive_before_stream_finishes, EarlyResult)
    after 2000 ->
        ?assert(false)
    end,
    receive
        {Ref, delta, SecondDelta} ->
            ?assertEqual(<<"Second delta">>, SecondDelta)
    after 2000 ->
        ?assert(false)
    end,
    receive
        {Ref, done, Result} ->
            ?assertEqual(ok, Result)
    after 2000 ->
        ?assert(false)
    end.

test_stream_tool_call(#{config := Config}) ->
    ToolConfig = Config#{model => <<"stream-tool-model">>},
    ?assertEqual(
        {tool_calls, [
            {<<"first_tool">>, #{<<"n">> => 1}, <<"sig-123">>, <<"call-1">>},
            {<<"second_tool">>, #{<<"n">> => 2}, undefined, <<"call-2">>}
        ]},
        adk_llm_gemini:stream(ToolConfig, [], [], fun(_) -> ok end)
    ).

test_multimodal_request(#{config := Config, request_table := RequestTable}) ->
    ets:delete_all_objects(RequestTable),
    {ok, Prompt} = adk_content:text(<<"Describe these inputs.">>),
    {ok, Image} = adk_content:inline_data(<<"image/png">>, <<0, 1, 2, 3>>),
    {ok, Pdf} = adk_content:file_data(
                  <<"application/pdf">>, <<"gs://adk-fixtures/doc.pdf">>),
    {ok, Content} = adk_content:new([Prompt, Image, Pdf]),
    {ok, <<"Hello from mock Gemini">>} = adk_llm_gemini:generate(
                                           Config,
                                           [#{role => user,
                                              content => Content}], []),
    #{body := #{<<"contents">> :=
                    [#{<<"role">> := <<"user">>,
                       <<"parts">> := Parts}]}} = last_request(RequestTable),
    ?assertEqual(
       [#{<<"text">> => <<"Describe these inputs.">>},
        #{<<"inlineData">> =>
              #{<<"mimeType">> => <<"image/png">>,
                <<"data">> => base64:encode(<<0, 1, 2, 3>>)}},
        #{<<"fileData">> =>
              #{<<"mimeType">> => <<"application/pdf">>,
                <<"fileUri">> => <<"gs://adk-fixtures/doc.pdf">>}}],
       Parts).

test_multimodal_response(#{config := Config}) ->
    ResponseConfig = Config#{model => <<"multimodal-response">>},
    {ok, Content} = adk_llm_gemini:generate(
                      ResponseConfig,
                      [#{role => user, content => <<"Return media">>}], []),
    ?assertEqual(
       [<<"text">>, <<"inline_data">>, <<"file_data">>],
       adk_llm_gemini_content:part_types(Content)),
    [_, Inline, File] = adk_content:parts(Content),
    ?assertEqual(<<"UE5H">>, maps:get(<<"data">>, Inline)),
    ?assertEqual(<<"gs://adk-fixtures/result.png">>,
                 maps:get(<<"uri">>, File)),
    ?assertMatch({ok, _}, adk_content:validate(Content)).

test_stream_content(#{config := Config}) ->
    StreamConfig = Config#{model => <<"stream-multimodal-model">>},
    Ref = make_ref(),
    Caller = self(),
    Result = adk_llm_gemini:stream_content(
               StreamConfig,
               [#{role => user, content => <<"Stream media">>}], [],
               fun(Content) -> Caller ! {Ref, Content} end),
    ?assertEqual(ok, Result),
    receive
        {Ref, Content} ->
            ?assertEqual([<<"text">>, <<"inline_data">>],
                         adk_llm_gemini_content:part_types(Content)),
            ?assertMatch({ok, _}, adk_content:validate(Content))
    after 2000 ->
        ?assert(false)
    end,
    receive {Ref, _Duplicate} -> ?assert(false) after 0 -> ok end.

test_stream_thought_summary(#{config := Config}) ->
    StreamConfig = Config#{model => <<"stream-thought-model">>,
                           thinking_config =>
                               #{thinking_level => high,
                                 include_thoughts => true}},
    TextRef = make_ref(),
    Caller = self(),
    ?assertEqual(
       ok,
       adk_llm_gemini:stream(
         StreamConfig, [#{role => user, content => <<"Reason">>}], [],
         fun(Text) -> Caller ! {TextRef, Text} end)),
    receive {TextRef, <<"visible delta">>} -> ok
    after 2000 -> ?assert(false)
    end,
    receive {TextRef, _ThoughtLeak} -> ?assert(false) after 0 -> ok end,

    ContentRef = make_ref(),
    ?assertEqual(
       ok,
       adk_llm_gemini:stream_content(
         StreamConfig, [#{role => user, content => <<"Reason">>}], [],
         fun(Content) -> Caller ! {ContentRef, Content} end)),
    receive
        {ContentRef, Content} ->
            [Thought, Answer] = adk_content:parts(Content),
            ?assertEqual(true, maps:get(<<"thought">>, Thought)),
            ?assertEqual(<<"visible delta">>, maps:get(<<"text">>, Answer))
    after 2000 -> ?assert(false)
    end.

test_stream_metadata_frame(#{config := Config}) ->
    StreamConfig = Config#{model => <<"stream-metadata-model">>},
    Ref = make_ref(),
    Caller = self(),
    {provider_result, _} = Result = adk_llm_gemini:stream(
                                      StreamConfig,
                                      [#{role => user,
                                         content => <<"Count frames">>}], [],
                                      fun(Delta) ->
                                          Caller ! {Ref, Delta}
                                      end),
    receive {Ref, <<"only content">>} -> ok after 2000 -> ?assert(false) end,
    receive {Ref, _Phantom} -> ?assert(false) after 0 -> ok end,
    {ok, streamed, ProviderMetadata} = adk_provider_result:decode(Result),
    ?assertEqual(<<"generation_metadata">>,
                 maps:get(<<"type">>, ProviderMetadata)),
    Metadata = maps:get(<<"metadata">>, ProviderMetadata),
    ?assertEqual(1,
                 maps:get(<<"promptTokenCount">>,
                          maps:get(<<"usage_metadata">>, Metadata))).

test_stream_grounding(#{config := Config}) ->
    StreamConfig = Config#{model => <<"stream-grounding-model">>,
                           builtin_tools => [google_search]},
    Ref = make_ref(),
    Caller = self(),
    {provider_result, _} = Result = adk_llm_gemini:stream(
                                      StreamConfig,
                                      [#{role => user,
                                         content => <<"Ground the stream">>}],
                                      [],
                                      fun(Delta) ->
                                          Caller ! {Ref, Delta}
                                      end),
    receive {Ref, <<"Grounded ">>} -> ok after 2000 -> ?assert(false) end,
    receive {Ref, <<"stream">>} -> ok after 2000 -> ?assert(false) end,
    {ok, streamed, ProviderMetadata} = adk_provider_result:decode(Result),
    Grounding = maps:get(<<"metadata">>, ProviderMetadata),
    ?assertEqual([<<"query one">>, <<"query two">>],
                 maps:get(<<"webSearchQueries">>, Grounding)),
    ?assertEqual(2, length(maps:get(<<"groundingChunks">>, Grounding))),
    ?assertEqual(1, length(maps:get(<<"groundingSupports">>, Grounding))).

test_stream_grounding_agent_event(#{config := Config}) ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    AgentConfig = Config#{provider => adk_llm_gemini,
                          model => <<"stream-grounding-model">>,
                          builtin_tools => [google_search],
                          output_schema => #{<<"type">> => <<"string">>}},
    {ok, Agent} = erlang_adk:spawn_agent(
                    "StreamGroundingAgent", AgentConfig, []),
    try
        InvocationId = <<"stream-grounding-invocation">>,
        InputEvent = adk_event:new(
                       <<"user">>, <<"Stream a grounded answer">>,
                       #{invocation_id => InvocationId}),
        {ok, FinalEvent} = adk_agent:stream_with_events(
                             Agent, [InputEvent], InvocationId, #{}, text,
                             fun(_PartialEvent) -> ok end),
        ?assertEqual(<<"Grounded stream">>,
                     FinalEvent#adk_event.content),
        ProviderMetadata = maps:get(
                             <<"provider_metadata">>,
                             FinalEvent#adk_event.actions),
        Grounding = maps:get(<<"metadata">>, ProviderMetadata),
        ?assertEqual(2,
                     length(maps:get(<<"groundingChunks">>, Grounding)))
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

test_grounding_event_persistence(#{config := Config}) ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    App = <<"grounding_test_app">>,
    User = <<"grounding_test_user">>,
    SessionId = <<"grounding-event-persistence">>,
    _ = erlang_adk_session:delete_session(App, User, SessionId),
    {ok, _Session} = erlang_adk_session:create_session(
                       App, User, #{session_id => SessionId}),
    AgentName = "GroundingPersistenceAgent",
    AgentConfig = Config#{provider => adk_llm_gemini,
                          model => <<"grounded-response">>,
                          builtin_tools => [google_search],
                          output_schema => #{<<"type">> => <<"string">>}},
    {ok, Agent} = erlang_adk:spawn_agent(AgentName, AgentConfig, []),
    try
        Runner = adk_runner:new(Agent, App, erlang_adk_session),
        %% The output schema applies to the model output, not to the internal
        %% provider envelope.
        ?assertEqual(
           {ok, <<"Grounded answer">>},
           adk_runner:run(
             Runner, User, SessionId, <<"Persist grounded answer">>)),
        {ok, StoredSession} = erlang_adk_session:get_session(
                                App, User, SessionId),
        FinalEvents = [Event || Event <- maps:get(events, StoredSession),
                                Event#adk_event.is_final =:= true],
        [FinalEvent] = FinalEvents,
        ?assertEqual(<<"Grounded answer">>,
                     FinalEvent#adk_event.content),
        ProviderMetadata = maps:get(
                             <<"provider_metadata">>,
                             FinalEvent#adk_event.actions),
        ?assertEqual(<<"gemini">>,
                     maps:get(<<"provider">>, ProviderMetadata)),
        ?assertEqual(<<"google_search_grounding">>,
                     maps:get(<<"type">>, ProviderMetadata)),
        ?assertMatch(
           #{<<"groundingChunks">> := [_ | _]},
           maps:get(<<"metadata">>, ProviderMetadata)),
        {ok, EncodedEvent} = adk_event:encode(FinalEvent),
        EncodedActions = maps:get(<<"actions">>, EncodedEvent),
        ?assertEqual(ProviderMetadata,
                     maps:get(<<"provider_metadata">>, EncodedActions))
    after
        _ = catch erlang_adk:stop_agent(Agent),
        _ = erlang_adk_session:delete_session(App, User, SessionId)
    end.

test_text_stream_rejects_multimodal(#{config := Config}) ->
    StreamConfig = Config#{model => <<"stream-multimodal-model">>},
    ?assertEqual(
       {error, {unsupported_text_stream_part, <<"inline_data">>}},
       adk_llm_gemini:stream(
         StreamConfig,
         [#{role => user, content => <<"Stream media">>}], [],
         fun(_) -> erlang:error(text_must_not_be_partially_emitted) end)).

test_invalid_content_is_local_error(
  #{config := Config, request_table := RequestTable}) ->
    ets:delete_all_objects(RequestTable),
    Unsafe = #{<<"schema_version">> => 1,
               <<"parts">> =>
                 [#{<<"type">> => <<"file_data">>,
                    <<"mime_type">> => <<"image/png">>,
                    <<"uri">> => <<"file:///etc/passwd">>}]},
    ?assertMatch(
       {error, {invalid_content_part, _,
                {unsupported_uri_scheme, <<"file">>}}},
       adk_llm_gemini:generate(
         Config, [#{role => user, content => Unsafe}], [])),
    ?assertEqual([], ets:lookup(RequestTable, last)).

test_unknown_response_part(#{config := Config}) ->
    UnknownConfig = Config#{model => <<"unsupported-part-response">>},
    ?assertEqual(
       {error, {unsupported_gemini_part, 0, [<<"executableCode">>]}},
       adk_llm_gemini:generate(
         UnknownConfig, [#{role => user, content => <<"Run code">>}], [])).

last_request(RequestTable) ->
    [{last, Request}] = ets:lookup(RequestTable, last),
    Request.

%% Cowboy Handler Callbacks
init(Req, State) ->
    {ok, Body, Req1} = read_body(Req, <<>>),
    Path = cowboy_req:path(Req1),
    RequestTable = maps:get(request_table, State),
    ets:insert(RequestTable, {last, #{
        path => Path,
        query => cowboy_req:qs(Req1),
        headers => cowboy_req:headers(Req1),
        body => jsx:decode(Body, [return_maps])
    }}),
    IsStream = binary:match(Path, <<"streamGenerateContent">>) =/= nomatch,
    IsError = binary:match(Path, <<"http-error">>) =/= nomatch,
    IsStreamTool = binary:match(Path, <<"stream-tool-model">>) =/= nomatch,
    IsStreamMultimodal = binary:match(
                           Path, <<"stream-multimodal-model">>) =/= nomatch,
    IsStreamMetadata = binary:match(
                         Path, <<"stream-metadata-model">>) =/= nomatch,
    IsStreamThought = binary:match(
                        Path, <<"stream-thought-model">>) =/= nomatch,
    IsStreamGrounding = binary:match(
                          Path, <<"stream-grounding-model">>) =/= nomatch,
    case {IsError, IsStream, IsStreamTool,
          IsStreamMultimodal, IsStreamMetadata, IsStreamThought,
          IsStreamGrounding} of
        {true, _, _, _, _, _, _} ->
            Req2 = cowboy_req:reply(
                429,
                #{<<"content-type">> => <<"text/plain">>},
                <<"rate limited">>,
                Req1
            ),
            {ok, Req2, State};
        {false, false, _, _, _, _, _} ->
            reply_generate(Path, Body, Req1, State);
        {false, true, true, _, _, _, _} ->
            reply_stream_tool(Req1, State);
        {false, true, false, true, _, _, _} ->
            reply_stream_multimodal(Req1, State);
        {false, true, false, false, true, _, _} ->
            reply_stream_metadata(Req1, State);
        {false, true, false, false, false, true, _} ->
            reply_stream_thought(Req1, State);
        {false, true, false, false, false, false, true} ->
            reply_stream_grounding(Req1, State);
        {false, true, false, false, false, false, false} ->
            reply_stream_text(Body, Req1, State)
    end.

read_body(Req, Acc) ->
    case cowboy_req:read_body(Req) of
        {ok, Data, Req1} -> {ok, <<Acc/binary, Data/binary>>, Req1};
        {more, Data, Req1} -> read_body(Req1, <<Acc/binary, Data/binary>>)
    end.

reply_generate(Path, Body, Req, State) ->
    maybe_delay_response(Body),
    IsSignedTools = binary:match(Body, <<"Trigger signed tools">>) =/= nomatch,
    IsTool = binary:match(Body, <<"Trigger tool">>) =/= nomatch,
    IsMultimodal = binary:match(Path, <<"multimodal-response">>) =/= nomatch,
    IsUnsupported = binary:match(
                      Path, <<"unsupported-part-response">>) =/= nomatch,
    IsThoughtSummary = binary:match(
                         Body, <<"Return a thought summary">>) =/= nomatch,
    IsGrounded = binary:match(Path, <<"grounded-response">>) =/= nomatch,
    IsMalformedGrounding = binary:match(
                             Path, <<"grounded-malformed">>) =/= nomatch,
    IsOversizeGrounding = binary:match(
                            Path, <<"grounded-oversize">>) =/= nomatch,
    IsGroundedTool = binary:match(
                       Path, <<"grounded-tool-response">>) =/= nomatch,
    RespBody = case IsGroundedTool of
        true -> grounded_tool_response_body();
        false -> case {IsMalformedGrounding, IsOversizeGrounding,
                       IsGrounded, IsUnsupported, IsMultimodal,
                       IsSignedTools, IsTool, IsThoughtSummary} of
        {true, _, _, _, _, _, _, _} ->
            <<"{\"candidates\":[{\"content\":{\"parts\":["
              "{\"text\":\"Malformed grounding\"}]},"
              "\"groundingMetadata\":[]}]} ">>;
        {false, true, _, _, _, _, _, _} ->
            jsx:encode(
              #{<<"candidates">> =>
                    [#{<<"content">> =>
                           #{<<"parts">> =>
                                 [#{<<"text">> =>
                                        <<"Oversized grounding">>}]},
                       <<"groundingMetadata">> =>
                           #{<<"searchEntryPoint">> =>
                                 #{<<"renderedContent">> =>
                                       binary:copy(<<"x">>, 262145)}}}]});
        {false, false, true, _, _, _, _, _} ->
            grounded_response_body();
        {false, false, false, true, _, _, _, _} ->
            <<"{\"candidates\":[{\"content\":{\"parts\":["
              "{\"executableCode\":{\"language\":\"PYTHON\",\"code\":\"1+1\"}}"
              "]}}]}">>;
        {false, false, false, false, true, _, _, _} ->
            <<"{\"candidates\":[{\"content\":{\"parts\":["
              "{\"text\":\"A generated result\"},"
              "{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"UE5H\"}},"
              "{\"fileData\":{\"mimeType\":\"image/png\","
              "\"fileUri\":\"gs://adk-fixtures/result.png\"}}"
              "]}}]}">>;
        {false, false, false, false, false, true, _, _} ->
            <<"{\"candidates\":[{\"content\":{\"parts\":["
              "{\"functionCall\":{\"id\":\"call-1\",\"name\":\"first_tool\",\"args\":{\"n\":1}},"
              "\"thoughtSignature\":\"sig-123\"},"
              "{\"functionCall\":{\"id\":\"call-2\",\"name\":\"second_tool\",\"args\":{\"n\":2}}}"
              "]}}]}">>;
        {false, false, false, false, false, false, true, _} ->
              <<"{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":"
              "{\"id\":\"call-test\",\"name\":\"test_tool\",\"args\":{\"arg\":\"val\"}}}]}}]}">>;
        {false, false, false, false, false, false, false, true} ->
            <<"{\"candidates\":[{\"content\":{\"parts\":["
              "{\"text\":\"summary, not raw reasoning\",\"thought\":true},"
              "{\"text\":\"visible answer\"}]}}]}">>;
        {false, false, false, false, false, false, false, false} ->
            <<"{\"candidates\":[{\"content\":{\"parts\":["
              "{\"text\":\"Hello from mock Gemini\"}]}}]}">>
        end
    end,
    Req2 = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        RespBody,
        Req
    ),
    {ok, Req2, State}.

grounded_response_body() ->
    jsx:encode(
      #{<<"candidates">> =>
            [#{<<"content">> =>
                   #{<<"parts">> =>
                         [#{<<"text">> => <<"Grounded answer">>}]},
               <<"groundingMetadata">> =>
                   #{<<"webSearchQueries">> => [<<"erlang otp">>],
                     <<"searchEntryPoint">> =>
                         #{<<"renderedContent">> =>
                               <<"<div class=\"search\">Sources</div>">>},
                     <<"groundingChunks">> =>
                         [#{<<"web">> =>
                                #{<<"uri">> => <<"https://example.test/otp">>,
                                  <<"title">> => <<"OTP source">>}}],
                     <<"groundingSupports">> =>
                         [#{<<"segment">> =>
                                #{<<"startIndex">> => 0,
                                  <<"endIndex">> => 8,
                                  <<"text">> => <<"Grounded">>},
                            <<"groundingChunkIndices">> => [0],
                            <<"confidenceScores">> => [0.99]}]}}]}).

grounded_tool_response_body() ->
    jsx:encode(
      #{<<"candidates">> =>
            [#{<<"content">> =>
                   #{<<"parts">> =>
                         [#{<<"functionCall">> =>
                                #{<<"id">> => <<"grounded-call">>,
                                  <<"name">> => <<"test_tool">>,
                                  <<"args">> =>
                                      #{<<"arg">> => <<"grounded">>}}}]},
               <<"groundingMetadata">> =>
                   #{<<"webSearchQueries">> => [<<"tool query">>],
                     <<"groundingChunks">> =>
                         [#{<<"web">> =>
                                #{<<"uri">> =>
                                      <<"https://example.test/tool">>,
                                  <<"title">> => <<"Tool source">>}}]}}]}).

reply_stream_text(Body, Req, State) ->
    maybe_delay_response(Body),
    Req2 = cowboy_req:stream_reply(
        200,
        #{<<"content-type">> => <<"text/event-stream">>},
        Req
    ),
    cowboy_req:stream_body(
        <<"data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"First">>,
        nofin,
        Req2
    ),
    timer:sleep(10),
    cowboy_req:stream_body(<<" delta\"}]}}]}\n\n">>, nofin, Req2),
    timer:sleep(100),
    cowboy_req:stream_body(
        <<"data: {\"candidates\":[{\"content\":{\"parts\":["
          "{\"text\":\"Second delta\"}]}}]}\r\n\r\n">>,
        nofin,
        Req2
    ),
    cowboy_req:stream_body(<<>>, fin, Req2),
    {ok, Req2, State}.

maybe_delay_response(Body) ->
    case binary:match(Body, <<"Delay response">>) of
        nomatch -> ok;
        _ -> timer:sleep(150)
    end.

reply_stream_tool(Req, State) ->
    Req2 = cowboy_req:stream_reply(
        200,
        #{<<"content-type">> => <<"text/event-stream">>},
        Req
    ),
    cowboy_req:stream_body(
        <<"data: {\"candidates\":[{\"content\":{\"parts\":["
          "{\"functionCall\":{\"id\":\"call-1\",\"name\":\"first_tool\",\"args\":{\"n\":1}},"
          "\"thoughtSignature\":\"sig-123\"},"
          "{\"functionCall\":{\"id\":\"call-2\",\"name\":\"second_tool\",\"args\":{\"n\":2}}}"
          "]}}]}\n\n">>,
        nofin,
        Req2
    ),
    cowboy_req:stream_body(<<>>, fin, Req2),
    {ok, Req2, State}.

reply_stream_multimodal(Req, State) ->
    Req2 = cowboy_req:stream_reply(
        200,
        #{<<"content-type">> => <<"text/event-stream">>},
        Req
    ),
    cowboy_req:stream_body(
        <<"data: {\"candidates\":[{\"content\":{\"parts\":["
          "{\"text\":\"visual delta\"},"
          "{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"UE5H\"}}"
          "]}}]}\n\n">>,
        nofin,
        Req2
    ),
    cowboy_req:stream_body(<<>>, fin, Req2),
    {ok, Req2, State}.

reply_stream_metadata(Req, State) ->
    Req2 = cowboy_req:stream_reply(
        200,
        #{<<"content-type">> => <<"text/event-stream">>},
        Req
    ),
    cowboy_req:stream_body(
        <<"data: {\"usageMetadata\":{\"promptTokenCount\":1}}\n\n">>,
        nofin, Req2),
    cowboy_req:stream_body(
        <<"data: {\"candidates\":[{\"content\":{\"parts\":["
          "{\"text\":\"only content\"}]}}]}\n\n">>,
        nofin, Req2),
    cowboy_req:stream_body(<<>>, fin, Req2),
    {ok, Req2, State}.

reply_stream_grounding(Req, State) ->
    Req2 = cowboy_req:stream_reply(
        200,
        #{<<"content-type">> => <<"text/event-stream">>},
        Req
    ),
    Frame1 = jsx:encode(
               #{<<"candidates">> =>
                     [#{<<"content">> =>
                            #{<<"parts">> =>
                                  [#{<<"text">> => <<"Grounded ">>}]},
                        <<"groundingMetadata">> =>
                            #{<<"webSearchQueries">> => [<<"query one">>],
                              <<"searchEntryPoint">> =>
                                  #{<<"renderedContent">> =>
                                        <<"<div>Search</div>">>},
                              <<"groundingChunks">> =>
                                  [#{<<"web">> =>
                                         #{<<"uri">> =>
                                               <<"https://example.test/one">>,
                                           <<"title">> => <<"One">>}}]}}]}),
    Frame2 = jsx:encode(
               #{<<"candidates">> =>
                     [#{<<"content">> =>
                            #{<<"parts">> =>
                                  [#{<<"text">> => <<"stream">>}]},
                        <<"groundingMetadata">> =>
                            #{<<"webSearchQueries">> => [<<"query two">>],
                              <<"groundingChunks">> =>
                                  [#{<<"web">> =>
                                         #{<<"uri">> =>
                                               <<"https://example.test/two">>,
                                           <<"title">> => <<"Two">>}}],
                              <<"groundingSupports">> =>
                                  [#{<<"segment">> =>
                                         #{<<"startIndex">> => 0,
                                           <<"endIndex">> => 15,
                                           <<"text">> =>
                                               <<"Grounded stream">>},
                                     <<"groundingChunkIndices">> => [0, 1]}]}}]}),
    cowboy_req:stream_body(
      <<"data: ", Frame1/binary, "\n\n">>, nofin, Req2),
    cowboy_req:stream_body(
      <<"data: ", Frame2/binary, "\n\n">>, nofin, Req2),
    cowboy_req:stream_body(<<>>, fin, Req2),
    {ok, Req2, State}.

reply_stream_thought(Req, State) ->
    Req2 = cowboy_req:stream_reply(
        200,
        #{<<"content-type">> => <<"text/event-stream">>},
        Req
    ),
    cowboy_req:stream_body(
        <<"data: {\"candidates\":[{\"content\":{\"parts\":["
          "{\"text\":\"summary delta\",\"thought\":true},"
          "{\"text\":\"visible delta\"}]}}]}\n\n">>,
        nofin, Req2),
    cowboy_req:stream_body(<<>>, fin, Req2),
    {ok, Req2, State}.
