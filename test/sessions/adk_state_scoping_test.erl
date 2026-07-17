-module(adk_state_scoping_test).
-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

-define(APP, <<"scope_app">>).
-define(USER, <<"scope_user">>).

state_scoping_test_() ->
    {setup,
     fun() -> erlang_adk_session:init() end,
     fun(_) -> ok end,
     [
      fun test_user_prefix_propagation/0,
      fun test_app_prefix_propagation/0,
      fun test_temp_prefix_lifecycle/0,
      fun test_plain_keys_not_propagated/0,
      fun test_missing_session_update_does_not_leak_scoped_state/0,
      fun test_concurrent_updates_are_not_lost/0,
      fun test_concurrent_create_is_idempotent/0,
      fun test_take_state_is_atomic/0,
      fun test_independent_sessions_do_not_share_a_lock/0
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
    erlang_adk_session:delete_session(?APP, ?USER, <<"s2">>),

    %% User state is independent of session records and is visible to future sessions.
    {ok, S3} = erlang_adk_session:create_session(
                 ?APP, ?USER, #{session_id => <<"s3">>}),
    ?assertEqual(<<"dark">>, maps:get(<<"user:theme">>, maps:get(state, S3))),
    erlang_adk_session:delete_session(?APP, ?USER, <<"s3">>).

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
    erlang_adk_session:delete_session(?APP, <<"userB">>, <<"sB">>),

    %% App state remains available after all current sessions have been deleted.
    {ok, SC} = erlang_adk_session:create_session(
                 ?APP, <<"userC">>, #{session_id => <<"sC">>}),
    ?assertEqual(<<"2.0">>, maps:get(<<"app:version">>, maps:get(state, SC))),
    erlang_adk_session:delete_session(?APP, <<"userC">>, <<"sC">>).

test_temp_prefix_lifecycle() ->
    erlang_adk_session:create_session(?APP, ?USER, #{session_id => <<"s_temp">>}),
    
    %% Update with temp key
    erlang_adk_session:update_state(?APP, ?USER, <<"s_temp">>, #{<<"temp:cache">> => <<"data">>, <<"normal">> => <<"kept">>}),
    
    %% Before event, temp key should still be there
    {ok, S1} = erlang_adk_session:get_session(?APP, ?USER, <<"s_temp">>),
    State1 = maps:get(state, S1),
    ?assertEqual(<<"data">>, maps:get(<<"temp:cache">>, State1)),
    
    %% Intermediate events are part of the same invocation and retain temp state.
    Event = adk_event:new(<<"test">>, <<"hello">>, #{}),
    ok = erlang_adk_session:add_event(?APP, ?USER, <<"s_temp">>, Event),
    
    {ok, S2} = erlang_adk_session:get_session(?APP, ?USER, <<"s_temp">>),
    State2 = maps:get(state, S2),
    ?assertEqual(<<"data">>, maps:get(<<"temp:cache">>, State2)),
    ?assertEqual(<<"kept">>, maps:get(<<"normal">>, State2)),

    %% The runner can explicitly clear temp state at the invocation boundary.
    ok = erlang_adk_session:clear_temp_state(?APP, ?USER, <<"s_temp">>),
    {ok, S3} = erlang_adk_session:get_session(?APP, ?USER, <<"s_temp">>),
    State3 = maps:get(state, S3),
    ?assertEqual(error, maps:find(<<"temp:cache">>, State3)),
    ?assertEqual(<<"kept">>, maps:get(<<"normal">>, State3)),
    
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

test_missing_session_update_does_not_leak_scoped_state() ->
    App = <<"missing_scope_app">>,
    User = <<"missing_scope_user">>,
    Delta = #{<<"local">> => true,
              <<"user:missing">> => true,
              <<"app:missing">> => true},
    ?assertEqual(
       {error, not_found},
       erlang_adk_session:update_state(App, User, <<"missing">>, Delta)),
    ?assertEqual(
       {error, not_found},
       erlang_adk_session:clear_temp_state(App, User, <<"missing">>)),

    {ok, Session} = erlang_adk_session:create_session(
                      App, User, #{session_id => <<"future">>}),
    State = maps:get(state, Session),
    ?assertEqual(error, maps:find(<<"local">>, State)),
    ?assertEqual(error, maps:find(<<"user:missing">>, State)),
    ?assertEqual(error, maps:find(<<"app:missing">>, State)),
    erlang_adk_session:delete_session(App, User, <<"future">>).

test_concurrent_updates_are_not_lost() ->
    App = <<"concurrent_scope_app">>,
    User = <<"concurrent_scope_user">>,
    SessionId = <<"concurrent_session">>,
    {ok, _} = erlang_adk_session:create_session(
                App, User, #{session_id => SessionId}),
    Parent = self(),
    Count = 32,
    lists:foreach(
      fun(Index) ->
          spawn(fun() ->
              Suffix = integer_to_binary(Index),
              Delta = #{
                  <<"local_", Suffix/binary>> => Index,
                  <<"user:key_", Suffix/binary>> => Index,
                  <<"app:key_", Suffix/binary>> => Index
              },
              Parent ! {state_update_done, Index,
                        erlang_adk_session:update_state(
                          App, User, SessionId, Delta)}
          end)
      end,
      lists:seq(1, Count)),
    wait_for_updates(Count),

    {ok, Session} = erlang_adk_session:get_session(App, User, SessionId),
    State = maps:get(state, Session),
    lists:foreach(
      fun(Index) ->
          Suffix = integer_to_binary(Index),
          ?assertEqual(Index, maps:get(<<"local_", Suffix/binary>>, State)),
          ?assertEqual(Index, maps:get(<<"user:key_", Suffix/binary>>, State)),
          ?assertEqual(Index, maps:get(<<"app:key_", Suffix/binary>>, State))
      end,
      lists:seq(1, Count)),
    erlang_adk_session:delete_session(App, User, SessionId).

wait_for_updates(0) ->
    ok;
wait_for_updates(Remaining) ->
    receive
        {state_update_done, _Index, ok} ->
            wait_for_updates(Remaining - 1);
        {state_update_done, _Index, Error} ->
            ?assertEqual(ok, Error)
    after 5000 ->
        ?assert(false)
    end.

test_concurrent_create_is_idempotent() ->
    App = <<"idempotent_create_app">>,
    User = <<"idempotent_create_user">>,
    SessionId = <<"idempotent_create_session">>,
    Parent = self(),
    Count = 20,
    lists:foreach(fun(Index) ->
        spawn(fun() ->
            Result = erlang_adk_session:create_session(
                       App, User,
                       #{session_id => SessionId,
                         state => #{<<"winner">> => Index}}),
            Parent ! {create_result, Result}
        end)
    end, lists:seq(1, Count)),
    Winners = collect_create_winners(Count, []),
    ?assertEqual(1, length(lists:usort(Winners))),
    {ok, Session} = erlang_adk_session:get_session(App, User, SessionId),
    [Winner] = lists:usort(Winners),
    ?assertEqual(Winner, maps:get(<<"winner">>, maps:get(state, Session))),
    ok = erlang_adk_session:delete_session(App, User, SessionId).

test_take_state_is_atomic() ->
    App = <<"atomic_take_app">>,
    User = <<"atomic_take_user">>,
    SessionId = <<"atomic_take_session">>,
    Key = <<"temp:claim">>,
    {ok, _} = erlang_adk_session:create_session(
                App, User,
                #{session_id => SessionId, state => #{Key => claimed}}),
    Parent = self(),
    Count = 20,
    lists:foreach(fun(_) ->
        spawn(fun() ->
            Parent ! {take_result,
                      erlang_adk_session:take_state(
                        App, User, SessionId, Key)}
        end)
    end, lists:seq(1, Count)),
    Results = collect_take_results(Count, []),
    ?assertEqual(1, length([ok || {ok, claimed} <- Results])),
    ?assertEqual(Count - 1,
                 length([error || {error, not_found} <- Results])),
    {ok, Session} = erlang_adk_session:get_session(App, User, SessionId),
    ?assertEqual(error, maps:find(Key, maps:get(state, Session))),
    ok = erlang_adk_session:delete_session(App, User, SessionId).

collect_create_winners(0, Acc) -> Acc;
collect_create_winners(Remaining, Acc) ->
    receive
        {create_result, {ok, Session}} ->
            Winner = maps:get(<<"winner">>, maps:get(state, Session)),
            collect_create_winners(Remaining - 1, [Winner | Acc]);
        {create_result, Error} ->
            erlang:error({unexpected_create_result, Error})
    after 5000 ->
        erlang:error(create_timeout)
    end.

collect_take_results(0, Acc) -> Acc;
collect_take_results(Remaining, Acc) ->
    receive
        {take_result, Result} ->
            collect_take_results(Remaining - 1, [Result | Acc])
    after 5000 ->
        erlang:error(take_timeout)
    end.

test_independent_sessions_do_not_share_a_lock() ->
    App = <<"lock_granularity_app">>,
    User = <<"lock_granularity_user">>,
    BlockedSession = <<"blocked">>,
    FreeSession = <<"free">>,
    {ok, _} = erlang_adk_session:create_session(
                App, User, #{session_id => BlockedSession}),
    {ok, _} = erlang_adk_session:create_session(
                App, User, #{session_id => FreeSession}),
    Parent = self(),
    Blocker = spawn(fun() ->
        Resource = {erlang_adk_session, session, App, User, BlockedSession},
        global:trans(
          {Resource, self()},
          fun() ->
              Parent ! session_lock_held,
              receive release_session_lock -> ok end
          end,
          [node()], infinity)
    end),
    receive session_lock_held -> ok after 1000 -> ?assert(false) end,

    %% A former app-wide lock made this read wait behind BlockedSession.
    Reader = spawn(fun() ->
        Parent ! {free_session_read,
                  erlang_adk_session:get_session(App, User, FreeSession)}
    end),
    receive
        {free_session_read, {ok, Session}} ->
            ?assertEqual(FreeSession, maps:get(id, Session))
    after 1000 ->
        exit(Reader, kill),
        ?assert(false)
    end,
    Blocker ! release_session_lock,
    ok = erlang_adk_session:delete_session(App, User, BlockedSession),
    ok = erlang_adk_session:delete_session(App, User, FreeSession).
