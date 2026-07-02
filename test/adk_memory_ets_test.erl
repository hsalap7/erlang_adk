-module(adk_memory_ets_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

memory_ets_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Pid) ->
         [
          ?_test(test_add_search(Pid)),
          ?_test(test_add_session(Pid))
         ]
     end}.

setup() ->
    {ok, Pid} = adk_memory_ets:init(#{}),
    Pid.

cleanup(Pid) ->
    exit(Pid, kill).

test_add_search(Pid) ->
    {ok, Id1} = adk_memory_ets:add(Pid, <<"Erlang is awesome">>, #{<<"lang">> => <<"erlang">>}),
    {ok, _Id2} = adk_memory_ets:add(Pid, <<"Python is okay">>, #{<<"lang">> => <<"python">>}),
    
    {ok, Results} = adk_memory_ets:search(Pid, <<"awesome">>, #{}, 10),
    ?assertEqual(1, length(Results)),
    [R1] = Results,
    ?assertEqual(Id1, maps:get(id, R1)),
    ?assertEqual(<<"Erlang is awesome">>, maps:get(content, R1)),
    
    %% Delete
    ok = adk_memory_ets:delete(Pid, Id1),
    {ok, Results2} = adk_memory_ets:search(Pid, <<"awesome">>, #{}, 10),
    ?assertEqual([], Results2).

test_add_session(Pid) ->
    Event1 = adk_event:new(<<"user">>, <<"Query 1">>),
    Event2 = adk_event:new(<<"agent">>, <<"Response 1">>),
    
    ok = adk_memory_ets:add_session_to_memory(Pid, <<"sess_test">>, [Event1, Event2]),
    
    {ok, Results} = adk_memory_ets:search(Pid, <<"Query 1">>, #{}, 10),
    ?assertEqual(1, length(Results)),
    [R] = Results,
    Content = maps:get(content, R),
    ?assert(string:str(binary_to_list(Content), "Query 1") > 0),
    ?assert(string:str(binary_to_list(Content), "Response 1") > 0).
