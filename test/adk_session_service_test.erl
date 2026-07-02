-module(adk_session_service_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

-define(APP, <<"test_app">>).
-define(USER, <<"user1">>).

setup() ->
    erlang_adk_session:init(),
    ok.

cleanup(_) ->
    %% It's an ETS table, we can just delete it
    ets:delete(adk_sessions),
    ok.

session_service_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
      fun test_create_get_delete/0,
      fun test_scoped_state/0,
      fun test_add_event/0
     ]}.

test_create_get_delete() ->
    {ok, Sess1} = erlang_adk_session:create_session(?APP, ?USER, #{}),
    Id = maps:get(id, Sess1),
    
    {ok, Sess2} = erlang_adk_session:get_session(?APP, ?USER, Id),
    ?assertEqual(Id, maps:get(id, Sess2)),
    
    {ok, List} = erlang_adk_session:list_sessions(?APP, ?USER),
    ?assert(length(List) > 0),
    
    ok = erlang_adk_session:delete_session(?APP, ?USER, Id),
    ?assertEqual({error, not_found}, erlang_adk_session:get_session(?APP, ?USER, Id)).

test_scoped_state() ->
    {ok, Sess1} = erlang_adk_session:create_session(?APP, ?USER, #{}),
    Id = maps:get(id, Sess1),
    
    Delta = #{<<"key">> => <<"val">>, <<"user:theme">> => <<"dark">>},
    ok = erlang_adk_session:update_state(?APP, ?USER, Id, Delta),
    
    {ok, Sess2} = erlang_adk_session:get_session(?APP, ?USER, Id),
    State = maps:get(state, Sess2),
    ?assertEqual(<<"val">>, maps:get(<<"key">>, State)),
    ?assertEqual(<<"dark">>, maps:get(<<"user:theme">>, State)).

test_add_event() ->
    {ok, Sess1} = erlang_adk_session:create_session(?APP, ?USER, #{}),
    Id = maps:get(id, Sess1),
    
    Event = adk_event:new(<<"user">>, <<"Hello">>),
    ok = erlang_adk_session:add_event(?APP, ?USER, Id, Event),
    
    {ok, Sess2} = erlang_adk_session:get_session(?APP, ?USER, Id),
    Events = maps:get(events, Sess2),
    ?assertEqual(1, length(Events)),
    [E1] = Events,
    ?assertEqual(<<"Hello">>, E1#adk_event.content).
