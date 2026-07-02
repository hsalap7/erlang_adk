-module(erlang_adk_session_mnesia_test).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    %% Stop mnesia if running, wipe it, start fresh
    application:stop(mnesia),
    mnesia:delete_schema([node()]),
    mnesia:create_schema([node()]),
    application:start(mnesia),
    erlang_adk_session_mnesia:init(),
    ok.

teardown(_) ->
    application:stop(erlang_adk),
    application:stop(mnesia),
    mnesia:delete_schema([node()]).

session_mnesia_test_() ->
    {setup,
        fun setup/0,
        fun teardown/1,
        fun(_State) ->
            [
                {"Create and Get Session", ?_test(test_create_get())},
                {"Update State", ?_test(test_update_state())},
                {"List and Delete Sessions", ?_test(test_list_delete())}
            ]
        end
    }.

test_create_get() ->
    {ok, Session} = erlang_adk_session_mnesia:create_session(<<"App">>, <<"User1">>, #{session_id => <<"S1">>}),
    ?assertEqual(<<"S1">>, maps:get(id, Session)),
    
    {ok, Fetched} = erlang_adk_session_mnesia:get_session(<<"App">>, <<"User1">>, <<"S1">>),
    ?assertEqual(<<"S1">>, maps:get(id, Fetched)).

test_update_state() ->
    erlang_adk_session_mnesia:create_session(<<"App">>, <<"User1">>, #{session_id => <<"S2">>}),
    ok = erlang_adk_session_mnesia:update_state(<<"App">>, <<"User1">>, <<"S2">>, #{<<"key">> => <<"val">>}),
    
    {ok, Session} = erlang_adk_session_mnesia:get_session(<<"App">>, <<"User1">>, <<"S2">>),
    State = maps:get(state, Session),
    ?assertEqual(<<"val">>, maps:get(<<"key">>, State)).

test_list_delete() ->
    erlang_adk_session_mnesia:create_session(<<"App">>, <<"User2">>, #{session_id => <<"S3">>}),
    erlang_adk_session_mnesia:create_session(<<"App">>, <<"User2">>, #{session_id => <<"S4">>}),
    
    {ok, Sessions} = erlang_adk_session_mnesia:list_sessions(<<"App">>, <<"User2">>),
    ?assert(length(Sessions) >= 2),
    
    ok = erlang_adk_session_mnesia:delete_session(<<"App">>, <<"User2">>, <<"S3">>),
    {error, not_found} = erlang_adk_session_mnesia:get_session(<<"App">>, <<"User2">>, <<"S3">>).
