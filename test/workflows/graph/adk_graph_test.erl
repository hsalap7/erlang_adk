-module(adk_graph_test).
-include_lib("eunit/include/eunit.hrl").

graph_test_() ->
    [
     fun test_simple_graph/0,
     fun test_conditional_graph/0,
     fun test_error_missing_entry/0,
     fun test_unknown_entry/0,
     fun test_unknown_edge_source/0,
     fun test_unknown_edge_target/0,
     fun test_max_steps/0,
     fun test_invalid_max_steps/0
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

test_unknown_entry() ->
    G0 = adk_graph:set_entry_point(adk_graph:new(), absent),
    ?assertEqual({error, {unknown_entry_point, absent}},
                 adk_graph:compile(G0)).

test_unknown_edge_source() ->
    G0 = adk_graph:add_node(adk_graph:new(), present,
                            fun(_State) -> #{} end),
    G1 = adk_graph:add_edge(G0, absent, present),
    G2 = adk_graph:set_entry_point(G1, present),
    ?assertEqual({error, {unknown_edge_source, absent}},
                 adk_graph:compile(G2)).

test_unknown_edge_target() ->
    G0 = adk_graph:add_node(adk_graph:new(), present,
                            fun(_State) -> #{} end),
    G1 = adk_graph:add_edge(G0, present, absent),
    G2 = adk_graph:set_entry_point(G1, present),
    ?assertEqual({error, {unknown_edge_target, absent}},
                 adk_graph:compile(G2)).

test_max_steps() ->
    G0 = adk_graph:add_node(adk_graph:new(), cycle,
                            fun(State) -> State end),
    G1 = adk_graph:add_edge(G0, cycle, cycle),
    G2 = adk_graph:set_entry_point(G1, cycle),
    {ok, Compiled} = adk_graph:compile(G2),
    ?assertEqual({error, {max_steps_exceeded, 3}},
                 adk_graph:run(Compiled, #{}, #{max_steps => 3})).

test_invalid_max_steps() ->
    G0 = adk_graph:add_node(adk_graph:new(), entry,
                            fun(State) -> State end),
    G1 = adk_graph:set_entry_point(G0, entry),
    {ok, Compiled} = adk_graph:compile(G1),
    ?assertEqual({error, {invalid_max_steps, 0}},
                 adk_graph:run(Compiled, #{}, #{max_steps => 0})),
    ?assertEqual({error, {invalid_max_steps, -1}},
                 adk_graph:run(Compiled, #{}, #{max_steps => -1})),
    ?assertEqual({error, {invalid_max_steps, <<"many">>}},
                 adk_graph:run(Compiled, #{}, #{max_steps => <<"many">>})).
