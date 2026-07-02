-module(adk_llm_gemini_test).
-include_lib("eunit/include/eunit.hrl").

-export([init/2]).

setup() ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(gun),
    
    Dispatch = cowboy_router:compile([
        {'_', [{"/v1beta/models/:model", ?MODULE, []}]}
    ]),
    
    {ok, _} = cowboy:start_clear(mock_gemini,
        [{port, 0}],
        #{env => #{dispatch => Dispatch}}
    ),
    
    Port = ranch:get_port(mock_gemini),
    BaseUrl = list_to_binary("http://127.0.0.1:" ++ integer_to_list(Port)),
    
    #{
        config => #{
            api_key => <<"test_key">>,
            base_url => BaseUrl,
            model => <<"gemini-test-model">>
        }
    }.

teardown(_) ->
    cowboy:stop_listener(mock_gemini).

gemini_test_() ->
    {setup,
        fun setup/0,
        fun teardown/1,
        fun(State) ->
            [
                {"Generate text", ?_test(test_generate_text(State))},
                {"Generate tool call", ?_test(test_generate_tool_call(State))},
                {"Missing API Key error", ?_test(test_missing_api_key())},
                {"Stream text", ?_test(test_stream_text(State))}
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
    ?assertEqual([{<<"test_tool">>, #{<<"arg">> => <<"val">>}, undefined}], Calls).

test_missing_api_key() ->
    %% Temporarily remove env var if it exists
    OldKey = os:getenv("GEMINI_API_KEY"),
    os:unsetenv("GEMINI_API_KEY"),
    try
        ?assertThrow({error, missing_api_key}, adk_llm_gemini:generate(#{}, [], []))
    after
        if OldKey =/= false -> os:putenv("GEMINI_API_KEY", OldKey); true -> ok end
    end.

test_stream_text(#{config := Config}) ->
    History = [#{role => user, content => <<"Stream me">>}],
    Ref = make_ref(),
    Caller = self(),
    Callback = fun(Chunk) -> Caller ! {Ref, Chunk} end,
    
    adk_llm_gemini:stream(Config, History, [], Callback),
    
    %% Wait for the single message sent by our mock SSE server
    receive
        {Ref, Chunk} -> 
            ?assertEqual(<<"data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Stream chunk\"}]}}]}\n\n">>, Chunk)
    after 2000 ->
        ?assert(false)
    end.

%% Cowboy Handler Callbacks
init(Req, State) ->
    Path = cowboy_req:path(Req),
    case binary:match(Path, <<"streamGenerateContent">>) of
        nomatch ->
            %% Standard response
            {ok, Body, _} = cowboy_req:read_body(Req),
            IsTool = binary:match(Body, <<"Trigger tool">>) =/= nomatch,
            RespBody = if
                IsTool -> <<"{\"candidates\": [{\"content\": {\"parts\": [{\"functionCall\": {\"name\": \"test_tool\", \"args\": {\"arg\": \"val\"}}}]}}]}">>;
                true -> <<"{\"candidates\": [{\"content\": {\"parts\": [{\"text\": \"Hello from mock Gemini\"}]}}]}">>
            end,
            Req2 = cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, RespBody, Req),
            {ok, Req2, State};
        _ ->
            %% Stream response
            Req2 = cowboy_req:stream_reply(200, #{<<"content-type">> => <<"text/event-stream">>}, Req),
            cowboy_req:stream_body(<<"data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Stream chunk\"}]}}]}\n\n">>, nofin, Req2),
            cowboy_req:stream_body(<<>>, fin, Req2),
            {ok, Req2, State}
    end.
