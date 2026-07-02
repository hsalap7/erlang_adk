-module(adk_graph_node_test).
-include_lib("eunit/include/eunit.hrl").

graph_node_test_() ->
    [
     fun test_function_node/0,
     fun test_tool_node/0
    ].

test_function_node() ->
    NodeFn = adk_graph_node:function_node(fun(State) -> #{<<"b">> => maps:get(<<"a">>, State) + 1} end),
    Result = NodeFn(#{<<"a">> => 1}),
    ?assertEqual(2, maps:get(<<"b">>, Result)).

test_tool_node() ->
    NodeFn = adk_graph_node:tool_node([]),
    Result1 = NodeFn(#{}),
    ?assertEqual(#{}, Result1),
    
    Result2 = NodeFn(#{<<"pending_tools">> => [{<<"unknown_tool">>, #{}}]}),
    Events = maps:get(<<"events">>, Result2),
    ?assertEqual(1, length(Events)),
    ?assertEqual([], maps:get(<<"pending_tools">>, Result2)).
