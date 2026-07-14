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
          ?_test(test_add_session(Pid)),
          ?_test(test_add_session_skips_non_serializable_event(Pid)),
          ?_test(test_correlated_replies(Pid))
         ]
     end}.

setup() ->
    {ok, Pid} = adk_memory_ets:init(#{}),
    Pid.

cleanup(Pid) ->
    adk_memory_ets:stop(Pid).

test_add_search(Pid) ->
    {ok, Id1} = adk_memory_ets:add(Pid, <<"Erlang is awesome">>, #{<<"lang">> => <<"erlang">>}),
    {ok, _Id2} = adk_memory_ets:add(Pid, <<"Python is okay">>, #{<<"lang">> => <<"python">>}),
    
    {ok, Results} = adk_memory_ets:search(Pid, <<"awesome">>, #{}, 10),
    ?assertEqual(1, length(Results)),
    [R1] = Results,
    ?assertEqual(Id1, maps:get(id, R1)),
    ?assertEqual(<<"Erlang is awesome">>, maps:get(content, R1)),

    {ok, Filtered} = adk_memory_ets:search(
                       Pid, <<"is">>, #{<<"lang">> => <<"erlang">>}, 10),
    ?assertEqual([Id1], [maps:get(id, Result) || Result <- Filtered]),
    
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

test_add_session_skips_non_serializable_event(Pid) ->
    InternalEvent = adk_event:new(
                      <<"runner">>, <<"internal continuation">>,
                      #{actions => #{<<"private">> => {not_json, self()}}}),
    SearchableEvent = adk_event:new(<<"user">>, <<"still searchable">>),
    ok = adk_memory_ets:add_session_to_memory(
           Pid, <<"sess_with_internal_event">>,
           [InternalEvent, SearchableEvent]),
    {ok, [_ | _]} = adk_memory_ets:search(
                      Pid, <<"still searchable">>, #{}, 10),
    ?assert(is_process_alive(Pid)).

test_correlated_replies(Pid) ->
    OldRef = make_ref(),
    Pid ! {add, self(), OldRef, <<"older request">>, #{}},
    {ok, NewId} = adk_memory_ets:add(Pid, <<"current request">>, #{}),
    receive
        {memory_reply, OldRef, {ok, OldId}} ->
            ?assertNotEqual(OldId, NewId)
    after 1000 ->
        ?assert(false)
    end.
