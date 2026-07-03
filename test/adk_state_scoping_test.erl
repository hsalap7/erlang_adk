-module(adk_state_scoping_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

-define(APP, <<"scope_app">>).
-define(USER, <<"scope_user">>).

state_scoping_test_() ->
    {setup,
     fun() -> erlang_adk_session:init() end,
     fun(_) -> ok end,
     [
      fun test_user_prefix_propagation/0,
      fun test_app_prefix_propagation/0,
      fun test_temp_prefix_stripped/0,
      fun test_plain_keys_not_propagated/0
     ]}.

test_user_prefix_propagation() ->
    %% Create two sessions for the same user
    erlang_adk_session:create_session(?APP, ?USER, #{session_id => <<"s1">>}),
    erlang_adk_session:create_session(?APP, ?USER, #{session_id => <<"s2">>}),
    
    %% Update user-scoped state in s1
    erlang_adk_session:update_state(?APP, ?USER, <<"s1">>, #{<<"user:theme">> => <<"dark">>}),
    
    %% Verify it propagated to s2
    {ok, S2} = erlang_adk_session:get_session(?APP, ?USER, <<"s2">>),
    State2 = maps:get(state, S2),
    ?assertEqual(<<"dark">>, maps:get(<<"user:theme">>, State2)),
    
    %% Cleanup
    erlang_adk_session:delete_session(?APP, ?USER, <<"s1">>),
    erlang_adk_session:delete_session(?APP, ?USER, <<"s2">>).

test_app_prefix_propagation() ->
    %% Create sessions for different users
    erlang_adk_session:create_session(?APP, <<"userA">>, #{session_id => <<"sA">>}),
    erlang_adk_session:create_session(?APP, <<"userB">>, #{session_id => <<"sB">>}),
    
    %% Update app-scoped state in userA's session
    erlang_adk_session:update_state(?APP, <<"userA">>, <<"sA">>, #{<<"app:version">> => <<"2.0">>}),
    
    %% Verify it propagated to userB's session
    {ok, SB} = erlang_adk_session:get_session(?APP, <<"userB">>, <<"sB">>),
    StateB = maps:get(state, SB),
    ?assertEqual(<<"2.0">>, maps:get(<<"app:version">>, StateB)),
    
    %% Cleanup
    erlang_adk_session:delete_session(?APP, <<"userA">>, <<"sA">>),
    erlang_adk_session:delete_session(?APP, <<"userB">>, <<"sB">>).

test_temp_prefix_stripped() ->
    erlang_adk_session:create_session(?APP, ?USER, #{session_id => <<"s_temp">>}),
    
    %% Update with temp key
    erlang_adk_session:update_state(?APP, ?USER, <<"s_temp">>, #{<<"temp:cache">> => <<"data">>, <<"normal">> => <<"kept">>}),
    
    %% Before event, temp key should still be there
    {ok, S1} = erlang_adk_session:get_session(?APP, ?USER, <<"s_temp">>),
    State1 = maps:get(state, S1),
    ?assertEqual(<<"data">>, maps:get(<<"temp:cache">>, State1)),
    
    %% After adding an event, temp keys should be stripped
    Event = adk_event:new(<<"test">>, <<"hello">>, #{}),
    erlang_adk_session:add_event(?APP, ?USER, <<"s_temp">>, Event),
    
    {ok, S2} = erlang_adk_session:get_session(?APP, ?USER, <<"s_temp">>),
    State2 = maps:get(state, S2),
    ?assertEqual(error, maps:find(<<"temp:cache">>, State2)),
    ?assertEqual(<<"kept">>, maps:get(<<"normal">>, State2)),
    
    erlang_adk_session:delete_session(?APP, ?USER, <<"s_temp">>).

test_plain_keys_not_propagated() ->
    erlang_adk_session:create_session(?APP, ?USER, #{session_id => <<"sp1">>}),
    erlang_adk_session:create_session(?APP, ?USER, #{session_id => <<"sp2">>}),
    
    %% Update a plain key in sp1
    erlang_adk_session:update_state(?APP, ?USER, <<"sp1">>, #{<<"local_key">> => <<"value">>}),
    
    %% Verify it did NOT propagate to sp2
    {ok, S2} = erlang_adk_session:get_session(?APP, ?USER, <<"sp2">>),
    State2 = maps:get(state, S2),
    ?assertEqual(error, maps:find(<<"local_key">>, State2)),
    
    erlang_adk_session:delete_session(?APP, ?USER, <<"sp1">>),
    erlang_adk_session:delete_session(?APP, ?USER, <<"sp2">>).
