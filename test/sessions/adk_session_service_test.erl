-module(adk_session_service_test).
-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

-define(APP, <<"test_app">>).
-define(USER, <<"user1">>).

setup() ->
    erlang_adk_session:init(),
    ok.

cleanup(_) ->
    %% Preserve the supervised table; remove only this suite's data.
    ets:delete_all_objects(adk_sessions),
    ok.

session_service_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
      fun test_create_get_delete/0,
      fun test_scoped_state/0,
      fun test_add_event/0,
      fun test_compare_and_append_event/0,
      fun test_atomic_event_compaction/0
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

test_compare_and_append_event() ->
    SessionId = <<"compare-and-append">>,
    Key = <<"continuation">>,
    Expected = #{<<"revision">> => 1},
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER,
                #{session_id => SessionId,
                  state => #{Key => Expected}}),
    Event = adk_event:new(
              <<"tool">>, <<"progress">>,
              #{actions =>
                    #{<<"state_delta">> => #{<<"progress">> => 50}}}),
    ok = erlang_adk_session:add_event_if_state(
           ?APP, ?USER, SessionId, Key, Expected, Event),
    ?assertEqual(
       {error, conflict},
       erlang_adk_session:add_event_if_state(
         ?APP, ?USER, SessionId, Key,
         #{<<"revision">> => 2}, Event)),
    {ok, Session} = erlang_adk_session:get_session(
                      ?APP, ?USER, SessionId),
    ?assertEqual(Expected, maps:get(Key, maps:get(state, Session))),
    ?assertEqual(50, maps:get(<<"progress">>, maps:get(state, Session))),
    ?assertEqual([Event], maps:get(events, Session)).

test_atomic_event_compaction() ->
    SessionId = <<"atomic-compaction">>,
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER, #{session_id => SessionId}),
    Old1 = adk_event:new(<<"user">>, <<"old-1">>),
    Old2 = adk_event:new(<<"agent">>, <<"old-2">>),
    Retained = adk_event:new(<<"user">>, <<"retained">>),
    [ok = erlang_adk_session:add_event(
            ?APP, ?USER, SessionId, Event)
     || Event <- [Old1, Old2, Retained]],
    Summary = adk_event:new(<<"context_compactor">>, <<"summary">>),
    ?assertEqual(
       {error, conflict},
       erlang_adk_session:compact_events(
         ?APP, ?USER, SessionId,
         [Old2#adk_event.id, Old1#adk_event.id], Summary)),
    ok = erlang_adk_session:compact_events(
           ?APP, ?USER, SessionId,
           [Old1#adk_event.id, Old2#adk_event.id], Summary),
    {ok, Session} = erlang_adk_session:get_session(
                      ?APP, ?USER, SessionId),
    ?assertEqual([Summary, Retained], maps:get(events, Session)).
