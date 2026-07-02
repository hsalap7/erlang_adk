-module(adk_graph_test).
-include_lib("eunit/include/eunit.hrl").

graph_test_() ->
    [
     fun test_simple_graph/0,
     fun test_conditional_graph/0,
     fun test_error_missing_entry/0
    ].

test_simple_graph() ->
    G0 = adk_graph:new(),
    
    Node1 = fun(_State) -> #{<<"n1">> => true} end,
    Node2 = fun(_State) -> #{<<"n2">> => true} end,
    
    G1 = adk_graph:add_node(G0, n1, Node1),
    G2 = adk_graph:add_node(G1, n2, Node2),
    
    G3 = adk_graph:add_edge(G2, n1, n2),
    G4 = adk_graph:add_edge(G3, n2, end_node),
    
    G5 = adk_graph:set_entry_point(G4, n1),
    
    {ok, Compiled} = adk_graph:compile(G5),
    
    {ok, FinalState} = adk_graph:run(Compiled, #{<<"initial">> => true}),
    
    ?assert(maps:get(<<"initial">>, FinalState)),
    ?assert(maps:get(<<"n1">>, FinalState)),
    ?assert(maps:get(<<"n2">>, FinalState)).

test_conditional_graph() ->
    G0 = adk_graph:new(),
    
    Node1 = fun(State) -> #{<<"count">> => maps:get(<<"count">>, State, 0) + 1} end,
    
    G1 = adk_graph:add_node(G0, loop_node, Node1),
    
    CondFn = fun(State) ->
        Count = maps:get(<<"count">>, State),
        if 
            Count < 3 -> loop_node;
            true -> end_node
        end
    end,
    
    G2 = adk_graph:add_conditional_edge(G1, loop_node, CondFn),
    G3 = adk_graph:set_entry_point(G2, loop_node),
    
    {ok, Compiled} = adk_graph:compile(G3),
    
    {ok, FinalState} = adk_graph:run(Compiled, #{<<"count">> => 0}),
    
    ?assertEqual(3, maps:get(<<"count">>, FinalState)).

test_error_missing_entry() ->
    G0 = adk_graph:new(),
    ?assertEqual({error, missing_entry_point}, adk_graph:compile(G0)).
