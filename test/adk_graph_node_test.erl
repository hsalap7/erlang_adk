-module(adk_graph_node_test).
-include_lib("eunit/include/eunit.hrl").

graph_node_test_() ->
    [
     fun test_function_node/0,
     fun test_tool_node/0,
     fun test_agent_node_instructions_and_callbacks/0
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

test_agent_node_instructions_and_callbacks() ->
    NodeFn = adk_graph_node:agent_node(<<"graph_agent">>, #{
        provider => adk_llm_probe,
        instructions => <<"GRAPH INSTRUCTION">>,
        test_pid => self(),
        callback_pid => self(),
        callbacks => [adk_unloaded_callback]
    }, []),
    Result = NodeFn(#{<<"events">> =>
                          [adk_event:new(<<"user">>, <<"hello">>)]}),
    ?assertEqual(<<"graph_agent">>, maps:get(<<"last_agent">>, Result)),
    receive
        {probe_generate, History, []} ->
            ?assert(lists:any(
                      fun(#{role := system,
                            content := <<"GRAPH INSTRUCTION">>}) -> true;
                         (_) -> false
                      end, History))
    after 1000 -> ?assert(false)
    end,
    receive before_model -> ok after 1000 -> ?assert(false) end,
    receive after_model -> ok after 1000 -> ?assert(false) end.
