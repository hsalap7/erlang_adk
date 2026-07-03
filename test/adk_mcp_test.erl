-module(adk_mcp_test).
-include_lib("eunit/include/eunit.hrl").

mcp_client_test() ->
    {ok, Client} = adk_mcp_client:connect(<<"stdio">>, <<"dummy">>),
    
    {ok, Tools} = adk_mcp_client:list_tools(Client),
    ?assertEqual([], Tools),
    
    ?assertEqual({error, {unknown_tool, <<"foo">>}}, adk_mcp_client:execute_tool(Client, <<"foo">>, #{})),
    ok = adk_mcp_client:close(Client).

mcp_server_test() ->
    {ok, Server} = adk_mcp_server:start(<<"sse">>, []),
    ?assertEqual(<<"sse">>, maps:get(transport, Server)),
    ok = adk_mcp_server:stop(Server).
