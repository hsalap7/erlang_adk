-module(adk_mcp_test).
-include_lib("eunit/include/eunit.hrl").

mcp_client_test() ->
    {ok, Client} = adk_mcp_client:connect(<<"stdio">>, <<"dummy">>),
    {links, Links} = process_info(self(), links),
    ?assertNot(lists:member(Client, Links)),
    {ok, []} = adk_mcp_client:list_tools(Client),
    ok = adk_mcp_client:close(Client).

mcp_stdio_handshake_test() ->
    Fixture = filename:absname("test/mcp_stdio_fixture.sh"),
    {ok, Client} = adk_mcp_client:connect(
                     <<"stdio">>, unicode:characters_to_binary(Fixture)),
    {ok, [Tool]} = adk_mcp_client:list_tools(Client),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, Tool)),
    {ok, Result} = adk_mcp_client:execute_tool(
                     Client, <<"search">>, #{<<"query">> => <<"erlang">>}),
    ?assertEqual(false, maps:get(<<"isError">>, Result)),
    ok = wait_for_port_closed(Client, 50),
    ?assert(is_process_alive(Client)),
    ?assertEqual({error, port_closed}, adk_mcp_client:list_tools(Client)),
    ok = adk_mcp_client:close(Client).

mcp_deprecated_sse_test() ->
    ?assertEqual(
       {error, {unsupported_transport, sse_deprecated_use_streamable_http}},
       adk_mcp_client:connect(<<"sse">>, <<"http://localhost">>)).

mcp_client_rejects_static_secret_and_transport_headers_test() ->
    ?assertEqual(
       {error, invalid_mcp_client_options},
       adk_mcp_client:connect(
         <<"streamable_http">>, <<"http://127.0.0.1:1/mcp">>,
         #{headers => [{<<"authorization">>, <<"Bearer secret">>}]})),
    ?assertEqual(
       {error, invalid_mcp_client_options},
       adk_mcp_client:connect(
         <<"streamable_http">>, <<"http://127.0.0.1:1/mcp">>,
         #{headers => [{<<"mcp-session-id">>, <<"injected">>}]})).

mcp_stdio_request_timeout_test_() ->
    {timeout, 5, fun() ->
        Fixture = filename:absname("test/mcp_stdio_timeout_fixture.sh"),
        Command = unicode:characters_to_binary(["sh ", Fixture]),
        {ok, Client} = adk_mcp_client:connect(
                         <<"stdio">>, Command,
                         #{request_timeout => 50}),
        try
            ?assertEqual({error, timeout}, adk_mcp_client:list_tools(Client)),
            ?assert(is_process_alive(Client))
        after
            ok = adk_mcp_client:close(Client)
        end
    end}.

streamable_http_round_trip_test_() ->
    {timeout, 20, fun streamable_http_round_trip/0}.

streamable_http_does_not_replay_tool_after_session_loss_test_() ->
    {timeout, 20, fun streamable_http_does_not_replay_tool_after_session_loss/0}.

streamable_http_does_not_replay_tool_after_session_loss() ->
    TestPid = self(),
    Tool = #{schema =>
                 #{<<"name">> => <<"side_effect">>,
                   <<"description">> => <<"Count executions">>,
                   <<"inputSchema">> => #{<<"type">> => <<"object">>}},
             execute => fun(_Args, _Context) ->
                 TestPid ! side_effect_executed,
                 {ok, <<"done">>}
             end},
    {ok, Server} = adk_mcp_server:start(
                     <<"streamable_http">>,
                     #{port => 0, tools => [Tool]}),
    try
        {ok, #{url := Url}} = adk_mcp_server:endpoint(Server),
        {ok, Client} = adk_mcp_client:connect(
                         <<"streamable_http">>, Url),
        try
            OldSession = maps:get(session_id, sys:get_state(Client)),
            ok = adk_mcp_server:delete_session(
                   Server, OldSession, <<"2025-11-25">>),
            ?assertEqual(
               {error, {mcp_session_lost, request_not_replayed}},
               adk_mcp_client:execute_tool(
                 Client, <<"side_effect">>, #{})),
            receive side_effect_executed -> ?assert(false)
            after 0 -> ok
            end,
            ?assertNotEqual(
               OldSession, maps:get(session_id, sys:get_state(Client))),
            {ok, _Result} = adk_mcp_client:execute_tool(
                              Client, <<"side_effect">>, #{}),
            receive side_effect_executed -> ok
            after 1000 -> ?assert(false)
            end,
            receive side_effect_executed -> ?assert(false)
            after 0 -> ok
            end
        after
            ok = adk_mcp_client:close(Client)
        end
    after
        ok = adk_mcp_server:stop(Server)
    end.

streamable_http_round_trip() ->
    Token = <<"fixture-token-at-least-16-bytes">>,
    Resource = #{uri => <<"memo://readme">>,
                 name => <<"readme">>,
                 mime_type => <<"text/plain">>,
                 read => fun() -> {ok, <<"OTP-native MCP">>} end},
    Prompt = #{name => <<"review">>,
               description => <<"Review a topic">>,
               arguments => [#{<<"name">> => <<"topic">>,
                               <<"required">> => true}],
               get => fun(#{<<"topic">> := Topic}) ->
                   {ok, #{<<"description">> => <<"Fixture prompt">>,
                          <<"messages">> =>
                              [#{<<"role">> => <<"user">>,
                                 <<"content">> =>
                                     #{<<"type">> => <<"text">>,
                                       <<"text">> => <<"Review ", Topic/binary>>}}]}}
               end},
    {ok, Server} = adk_mcp_server:start(
                     <<"streamable_http">>,
                     #{port => 0, auth_token => Token,
                       tools => [adk_mcp_fixture_tool],
                       resources => [Resource], prompts => [Prompt]}),
    try
        {ok, #{url := Url}} = adk_mcp_server:endpoint(Server),
        Auth = fun() ->
            [{<<"authorization">>, <<"Bearer ", Token/binary>>}]
        end,
        {ok, Client} = adk_mcp_client:connect(
                         <<"streamable_http">>, Url,
                         #{auth_fun => Auth, request_timeout => 5000}),
        try
            assert_status_redacted(Client, Token),
            assert_status_redacted(Server, Token),
            {ok, Info} = adk_mcp_client:server_info(Client),
            ?assertEqual(<<"2025-11-25">>,
                         maps:get(<<"protocolVersion">>, Info)),
            {ok, [Tool]} = adk_mcp_client:list_tools(Client),
            ?assertEqual(<<"echo">>, maps:get(<<"name">>, Tool)),
            ?assert(maps:is_key(<<"inputSchema">>, Tool)),
            [ProviderSchema] = adk_mcp_client:schemas(Client),
            ?assert(maps:is_key(<<"parameters">>, ProviderSchema)),
            {ok, Resolved} = adk_mcp_client:resolved_call(
                               Client, <<"echo">>,
                               #{<<"text">> => <<"resolved">>},
                               #{secret_ref => should_not_cross_transport}),
            {ok, #{<<"structuredContent">> :=
                       #{<<"echo">> := <<"resolved">>}}} =
                (maps:get(execute, Resolved))(),
            ?assertEqual({error, unknown_tool},
                         adk_mcp_client:resolved_call(
                           Client, <<"missing">>, #{}, #{})),
            {ok, ToolResult} = adk_mcp_client:execute_tool(
                                 Client, <<"echo">>,
                                 #{<<"text">> => <<"hello">>}),
            ?assertEqual(#{<<"echo">> => <<"hello">>},
                         maps:get(<<"structuredContent">>, ToolResult)),
            {ok, [ListedResource]} = adk_mcp_client:list_resources(Client),
            ?assertEqual(<<"memo://readme">>,
                         maps:get(<<"uri">>, ListedResource)),
            {ok, #{<<"contents">> := [Content]}} =
                adk_mcp_client:read_resource(Client, <<"memo://readme">>),
            ?assertEqual(<<"OTP-native MCP">>, maps:get(<<"text">>, Content)),
            {ok, [ListedPrompt]} = adk_mcp_client:list_prompts(Client),
            ?assertEqual(<<"review">>, maps:get(<<"name">>, ListedPrompt)),
            {ok, #{<<"messages">> := [_]}} = adk_mcp_client:get_prompt(
                                                    Client, <<"review">>,
                                                    #{<<"topic">> => <<"OTP">>}),
            OldSession = maps:get(session_id, sys:get_state(Client)),
            ok = adk_mcp_server:delete_session(
                   Server, OldSession, <<"2025-11-25">>),
            %% MCP requires a client receiving 404 for a session to create a
            %% new session. The original operation is retried exactly once.
            {ok, [_]} = adk_mcp_client:list_tools(Client),
            ?assertNotEqual(OldSession,
                            maps:get(session_id, sys:get_state(Client)))
        after
            ok = adk_mcp_client:close(Client)
        end
    after
        ok = adk_mcp_server:stop(Server)
    end.

streamable_http_rejects_bad_auth_test_() ->
    {timeout, 10, fun() ->
        Token = <<"fixture-token-at-least-16-bytes">>,
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>,
                         #{port => 0, auth_token => Token,
                           tools => [adk_mcp_fixture_tool]}),
        try
            {ok, #{url := Url}} = adk_mcp_server:endpoint(Server),
            Auth = fun() ->
                [{<<"authorization">>, <<"Bearer definitely-wrong">>}]
            end,
            ?assertEqual({error, {http_status, 401}},
                         adk_mcp_client:connect(<<"streamable_http">>, Url,
                                                #{auth_fun => Auth}))
        after
            ok = adk_mcp_server:stop(Server)
        end
    end}.

streamable_http_auth_hook_test_() ->
    {timeout, 10, fun() ->
        TestPid = self(),
        AuthRef = make_ref(),
        Hook = fun(Meta) ->
            TestPid ! {mcp_auth_meta, AuthRef,
                       maps:without([authorization], Meta)},
            maps:get(authorization, Meta, undefined) =:= <<"Bearer hook-token">>
        end,
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>,
                         #{port => 0, auth_fun => Hook,
                           tools => [adk_mcp_fixture_tool]}),
        try
            {ok, #{url := Url}} = adk_mcp_server:endpoint(Server),
            ClientAuth = fun() ->
                [{<<"authorization">>, <<"Bearer hook-token">>}]
            end,
            {ok, Client} = adk_mcp_client:connect(
                             <<"streamable_http">>, Url,
                             #{auth_fun => ClientAuth}),
            try
                receive
                    {mcp_auth_meta, AuthRef,
                     #{method := <<"POST">>, endpoint := <<"/mcp">>,
                       peer := {_Ip, _Port}}} ->
                        ok
                after 1000 -> ?assert(false)
                end
            after
                ok = adk_mcp_client:close(Client)
            end
        after
            ok = adk_mcp_server:stop(Server),
            flush_mcp_auth_meta(AuthRef)
        end
    end}.

flush_mcp_auth_meta(AuthRef) ->
    receive
        {mcp_auth_meta, AuthRef, _Meta} ->
            flush_mcp_auth_meta(AuthRef)
    after 0 ->
        ok
    end.

streamable_http_client_accepts_sse_post_response_test_() ->
    {timeout, 10, fun() ->
        {ok, _} = application:ensure_all_started(cowboy),
        Listener = {mcp_sse_fixture, make_ref()},
        Dispatch = cowboy_router:compile(
                     [{'_', [{"/mcp", adk_mcp_sse_fixture_handler, #{}}]}]),
        {ok, _} = cowboy:start_clear(
                    Listener, #{socket_opts => [{ip, {127, 0, 0, 1}},
                                                 {port, 0}]},
                    #{env => #{dispatch => Dispatch}}),
        try
            Port = ranch:get_port(Listener),
            Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary,
                    "/mcp">>,
            {ok, Client} = adk_mcp_client:connect(
                             <<"streamable_http">>, Url),
            try
                {ok, [Tool]} = adk_mcp_client:list_tools(Client),
                ?assertEqual(<<"sse_tool">>, maps:get(<<"name">>, Tool))
            after
                ok = adk_mcp_client:close(Client)
            end
        after
            ok = cowboy:stop_listener(Listener)
        end
    end}.

mcp_server_explicit_unsupported_test() ->
    ?assertEqual(
       {error, {unsupported_transport, sse_deprecated_use_streamable_http}},
       adk_mcp_server:start(<<"sse">>, [])).

mcp_server_rejects_unauthenticated_non_loopback_test() ->
    ?assertEqual(
       {error, invalid_mcp_server_config},
       adk_mcp_server:start(<<"streamable_http">>,
                            #{ip => {0, 0, 0, 0}, port => 0})).

mcp_server_requires_explicit_non_loopback_opt_in_test() ->
    ?assertEqual(
       {error, invalid_mcp_server_config},
       adk_mcp_server:start(
         <<"streamable_http">>,
         #{ip => {0, 0, 0, 0}, port => 0,
           auth_token => <<"valid-token-at-least-16-bytes">>})).

wait_for_port_closed(_Client, 0) -> {error, fixture_did_not_exit};
wait_for_port_closed(Client, Attempts) ->
    case maps:get(port_closed, sys:get_state(Client), false) of
        true -> ok;
        false -> timer:sleep(10), wait_for_port_closed(Client, Attempts - 1)
    end.

assert_status_redacted(Pid, Secret) ->
    Rendered = unicode:characters_to_binary(
                 io_lib:format("~p", [sys:get_status(Pid)])),
    ?assertEqual(nomatch, binary:match(Rendered, Secret)).
