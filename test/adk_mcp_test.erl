-module(adk_mcp_test).
-include_lib("eunit/include/eunit.hrl").

mcp_client_test() ->
    {ok, Client} = adk_mcp_client:connect(<<"stdio">>, <<"dummy">>),
    {links, Links} = process_info(self(), links),
    ?assertNot(lists:member(Client, Links)),
    
    {ok, Tools} = adk_mcp_client:list_tools(Client),
    ?assertEqual([], Tools),
    
    ?assertEqual({error, {unknown_tool, <<"foo">>}}, adk_mcp_client:execute_tool(Client, <<"foo">>, #{})),
    ok = adk_mcp_client:close(Client).

mcp_stdio_handshake_test() ->
    Fixture = filename:absname("test/mcp_stdio_fixture.sh"),
    {ok, Client} = adk_mcp_client:connect(<<"stdio">>,
                                          unicode:characters_to_binary(Fixture)),
    {ok, [Tool]} = adk_mcp_client:list_tools(Client),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, Tool)),
    {ok, Result} = adk_mcp_client:execute_tool(
                     Client, <<"search">>, #{<<"query">> => <<"erlang">>}),
    ?assertEqual(false, maps:get(<<"isError">>, Result)),
    ok = wait_for_port_closed(Client, 50),
    ?assert(is_process_alive(Client)),
    ?assertEqual({error, port_closed}, adk_mcp_client:list_tools(Client)),
    ok = adk_mcp_client:close(Client).

mcp_unsupported_sse_test() ->
    ?assertEqual({error, {unsupported_transport, sse}},
                 adk_mcp_client:connect(<<"sse">>, <<"http://localhost">>)).

mcp_server_test() ->
    ?assertEqual(
       {error, {not_implemented, mcp_server_sse}},
       adk_mcp_server:start(<<"sse">>, [])).

wait_for_port_closed(_Client, 0) ->
    {error, fixture_did_not_exit};
wait_for_port_closed(Client, Attempts) ->
    case maps:get(port_closed, sys:get_state(Client), false) of
        true -> ok;
        false ->
            timer:sleep(10),
            wait_for_port_closed(Client, Attempts - 1)
    end.
