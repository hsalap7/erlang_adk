-module(adk_llm_gemini_test).
-include_lib("eunit/include/eunit.hrl").

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
                {"Default model is consistent", ?_test(test_default_model(State))},
                {"Reject non-success HTTP statuses", ?_test(test_http_statuses(State))},
                {"Honor configured request timeouts", ?_test(test_request_timeout(State))},
                {"Stream incremental text deltas", ?_test(test_stream_text(State))},
                {"Preserve streamed tool signatures", ?_test(test_stream_tool_call(State))}
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
    RequestConfig = Config#{temperature => 0.2, max_tokens => 64},
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
        #{<<"temperature">> => 0.2, <<"maxOutputTokens">> => 64},
        maps:get(<<"generationConfig">>, Payload)
    ).

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
    case {IsError, IsStream, IsStreamTool} of
        {true, _, _} ->
            Req2 = cowboy_req:reply(
                429,
                #{<<"content-type">> => <<"text/plain">>},
                <<"rate limited">>,
                Req1
            ),
            {ok, Req2, State};
        {false, false, _} ->
            reply_generate(Body, Req1, State);
        {false, true, true} ->
            reply_stream_tool(Req1, State);
        {false, true, false} ->
            reply_stream_text(Body, Req1, State)
    end.

read_body(Req, Acc) ->
    case cowboy_req:read_body(Req) of
        {ok, Data, Req1} -> {ok, <<Acc/binary, Data/binary>>, Req1};
        {more, Data, Req1} -> read_body(Req1, <<Acc/binary, Data/binary>>)
    end.

reply_generate(Body, Req, State) ->
    maybe_delay_response(Body),
    IsSignedTools = binary:match(Body, <<"Trigger signed tools">>) =/= nomatch,
    IsTool = binary:match(Body, <<"Trigger tool">>) =/= nomatch,
    RespBody = case {IsSignedTools, IsTool} of
        {true, _} ->
            <<"{\"candidates\":[{\"content\":{\"parts\":["
              "{\"functionCall\":{\"id\":\"call-1\",\"name\":\"first_tool\",\"args\":{\"n\":1}},"
              "\"thoughtSignature\":\"sig-123\"},"
              "{\"functionCall\":{\"id\":\"call-2\",\"name\":\"second_tool\",\"args\":{\"n\":2}}}"
              "]}}]}">>;
        {false, true} ->
              <<"{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":"
              "{\"id\":\"call-test\",\"name\":\"test_tool\",\"args\":{\"arg\":\"val\"}}}]}}]}">>;
        _ ->
            <<"{\"candidates\":[{\"content\":{\"parts\":["
              "{\"text\":\"Hello from mock Gemini\"}]}}]}">>
    end,
    Req2 = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        RespBody,
        Req
    ),
    {ok, Req2, State}.

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
