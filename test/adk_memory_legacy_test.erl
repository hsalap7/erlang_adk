-module(adk_memory_legacy_test).
-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

memory_test_() ->
    [
        {"Legacy add_message and get_history", ?_test(test_legacy_memory())},
        {"to_events and from_events", ?_test(test_conversions())}
    ].

test_legacy_memory() ->
    Mem0 = adk_memory:new(),
    ?assertEqual([], adk_memory:get_history(Mem0)),
    
    Mem1 = adk_memory:add_message(Mem0, user, <<"Hello">>),
    Mem2 = adk_memory:add_message(Mem1, agent, <<"Hi there">>),
    
    History = adk_memory:get_history(Mem2),
    ?assertEqual(2, length(History)),
    [M1, M2] = History,
    ?assertEqual(user, maps:get(role, M1)),
    ?assertEqual(<<"Hello">>, maps:get(content, M1)),
    ?assertEqual(agent, maps:get(role, M2)),
    ?assertEqual(<<"Hi there">>, maps:get(content, M2)).



test_conversions() ->
    Events = [
        adk_event:new(<<"user">>, <<"Hi">>),
        adk_event:new(<<"AgentX">>, <<"Hello">>)
    ],
    
    LegacyMem = adk_memory:from_events(Events),
    History = adk_memory:get_history(LegacyMem),
    ?assertEqual(2, length(History)),
    
    ConvertedEvents = adk_memory:to_events(LegacyMem),
    ?assertEqual(2, length(ConvertedEvents)).
