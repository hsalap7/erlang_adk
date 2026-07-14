-module(erlang_adk_session_mnesia_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

setup() ->
    %% Stop mnesia if running, wipe it, start fresh
    application:stop(mnesia),
    mnesia:delete_schema([node()]),
    mnesia:create_schema([node()]),
    application:start(mnesia),
    erlang_adk_session_mnesia:init(),
    ok.

teardown(_) ->
    %% Keep the application dependency running for later EUnit modules, but
    %% leave no session data behind. delete_schema/1 cannot run while Mnesia is
    %% active and the previous teardown silently leaked its data.
    lists:foreach(
      fun(Table) -> {atomic, ok} = mnesia:clear_table(Table) end,
      [adk_sessions_mnesia, adk_session_v2, adk_session_scope]),
    ok.

session_mnesia_test_() ->
    {setup,
        fun setup/0,
        fun teardown/1,
        fun(_State) ->
            [
                {"Create and Get Session", ?_test(test_create_get())},
                {"Update State", ?_test(test_update_state())},
                {"List and Delete Sessions", ?_test(test_list_delete())},
                {"Scoped State Survives Sessions", ?_test(test_scoped_state_survives_sessions())},
                {"Temp State Lifecycle", ?_test(test_temp_state_lifecycle())},
                {"Missing Session State Update", ?_test(test_missing_session_update())},
                {"Concurrent Updates", ?_test(test_concurrent_updates())},
                {"Concurrent Create Is Idempotent", ?_test(test_concurrent_create())},
                {"Atomic State Take", ?_test(test_atomic_take_state())},
                {"Atomic Compare And Append",
                 ?_test(test_compare_and_append_event())},
                {"Runner Integration", ?_test(test_runner_integration())}
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

test_scoped_state_survives_sessions() ->
    App = <<"ScopeApp">>,
    User = <<"ScopeUser">>,
    {ok, _} = erlang_adk_session_mnesia:create_session(
                App, User, #{session_id => <<"scope-1">>}),
    ok = erlang_adk_session_mnesia:update_state(
           App, User, <<"scope-1">>,
           #{<<"local">> => <<"only-here">>,
             <<"user:theme">> => <<"dark">>,
             <<"app:version">> => <<"2.0">>}),
    ok = erlang_adk_session_mnesia:delete_session(App, User, <<"scope-1">>),

    {ok, SameUserSession} = erlang_adk_session_mnesia:create_session(
                              App, User, #{session_id => <<"scope-2">>}),
    SameUserState = maps:get(state, SameUserSession),
    ?assertEqual(<<"dark">>, maps:get(<<"user:theme">>, SameUserState)),
    ?assertEqual(<<"2.0">>, maps:get(<<"app:version">>, SameUserState)),
    ?assertEqual(error, maps:find(<<"local">>, SameUserState)),

    {ok, OtherUserSession} = erlang_adk_session_mnesia:create_session(
                               App, <<"OtherUser">>,
                               #{session_id => <<"scope-3">>}),
    OtherUserState = maps:get(state, OtherUserSession),
    ?assertEqual(<<"2.0">>, maps:get(<<"app:version">>, OtherUserState)),
    ?assertEqual(error, maps:find(<<"user:theme">>, OtherUserState)).

test_temp_state_lifecycle() ->
    App = <<"TempApp">>,
    User = <<"TempUser">>,
    SessionId = <<"temp-session">>,
    {ok, _} = erlang_adk_session_mnesia:create_session(
                App, User, #{session_id => SessionId}),
    ok = erlang_adk_session_mnesia:update_state(
           App, User, SessionId,
           #{<<"temp:working">> => true, <<"durable">> => true}),
    Event = adk_event:new(<<"agent">>, <<"intermediate">>),
    ok = erlang_adk_session_mnesia:add_event(
           App, User, SessionId, Event),

    {ok, DuringInvocation} = erlang_adk_session_mnesia:get_session(
                               App, User, SessionId),
    DuringState = maps:get(state, DuringInvocation),
    ?assertEqual(true, maps:get(<<"temp:working">>, DuringState)),
    ok = erlang_adk_session_mnesia:clear_temp_state(App, User, SessionId),

    {ok, AfterInvocation} = erlang_adk_session_mnesia:get_session(
                              App, User, SessionId),
    AfterState = maps:get(state, AfterInvocation),
    ?assertEqual(error, maps:find(<<"temp:working">>, AfterState)),
    ?assertEqual(true, maps:get(<<"durable">>, AfterState)).

test_missing_session_update() ->
    App = <<"MissingApp">>,
    User = <<"MissingUser">>,
    Delta = #{<<"user:should_not_exist">> => true,
              <<"app:should_not_exist">> => true},
    ?assertEqual(
       {error, not_found},
       erlang_adk_session_mnesia:update_state(
         App, User, <<"missing">>, Delta)),
    ?assertEqual(
       {error, not_found},
       erlang_adk_session_mnesia:clear_temp_state(
         App, User, <<"missing">>)),
    MissingEvent = adk_event:new(<<"agent">>, <<"missing">>),
    ?assertEqual(
       {error, not_found},
       erlang_adk_session_mnesia:add_event(
         App, User, <<"missing">>, MissingEvent)),

    {ok, FutureSession} = erlang_adk_session_mnesia:create_session(
                            App, User, #{session_id => <<"future">>}),
    FutureState = maps:get(state, FutureSession),
    ?assertEqual(error, maps:find(<<"user:should_not_exist">>, FutureState)),
    ?assertEqual(error, maps:find(<<"app:should_not_exist">>, FutureState)).

test_concurrent_updates() ->
    App = <<"ConcurrentMnesiaApp">>,
    User = <<"ConcurrentMnesiaUser">>,
    SessionId = <<"concurrent-mnesia-session">>,
    {ok, _} = erlang_adk_session_mnesia:create_session(
                App, User, #{session_id => SessionId}),
    Parent = self(),
    Count = 24,
    lists:foreach(
      fun(Index) ->
          spawn(fun() ->
              Suffix = integer_to_binary(Index),
              Delta = #{
                  <<"local_", Suffix/binary>> => Index,
                  <<"user:key_", Suffix/binary>> => Index,
                  <<"app:key_", Suffix/binary>> => Index
              },
              Parent ! {mnesia_state_update_done, Index,
                        erlang_adk_session_mnesia:update_state(
                          App, User, SessionId, Delta)}
          end)
      end,
      lists:seq(1, Count)),
    wait_for_mnesia_updates(Count),

    {ok, Session} = erlang_adk_session_mnesia:get_session(
                      App, User, SessionId),
    State = maps:get(state, Session),
    lists:foreach(
      fun(Index) ->
          Suffix = integer_to_binary(Index),
          ?assertEqual(Index, maps:get(<<"local_", Suffix/binary>>, State)),
          ?assertEqual(Index, maps:get(<<"user:key_", Suffix/binary>>, State)),
          ?assertEqual(Index, maps:get(<<"app:key_", Suffix/binary>>, State))
      end,
      lists:seq(1, Count)).

wait_for_mnesia_updates(0) ->
    ok;
wait_for_mnesia_updates(Remaining) ->
    receive
        {mnesia_state_update_done, _Index, ok} ->
            wait_for_mnesia_updates(Remaining - 1);
        {mnesia_state_update_done, _Index, Error} ->
            ?assertEqual(ok, Error)
    after 5000 ->
        ?assert(false)
    end.

test_concurrent_create() ->
    App = <<"ConcurrentCreateMnesiaApp">>,
    User = <<"ConcurrentCreateMnesiaUser">>,
    SessionId = <<"concurrent-create-mnesia-session">>,
    Parent = self(),
    Count = 16,
    lists:foreach(fun(Index) ->
        spawn(fun() ->
            Result = erlang_adk_session_mnesia:create_session(
                       App, User,
                       #{session_id => SessionId,
                         state => #{<<"winner">> => Index}}),
            Parent ! {mnesia_create_result, Result}
        end)
    end, lists:seq(1, Count)),
    Winners = collect_mnesia_create_winners(Count, []),
    ?assertEqual(1, length(lists:usort(Winners))),
    {ok, Session} = erlang_adk_session_mnesia:get_session(
                      App, User, SessionId),
    [Winner] = lists:usort(Winners),
    ?assertEqual(Winner, maps:get(<<"winner">>, maps:get(state, Session))).

test_atomic_take_state() ->
    App = <<"AtomicTakeMnesiaApp">>,
    User = <<"AtomicTakeMnesiaUser">>,
    SessionId = <<"atomic-take-mnesia-session">>,
    Key = <<"temp:claim">>,
    {ok, _} = erlang_adk_session_mnesia:create_session(
                App, User,
                #{session_id => SessionId, state => #{Key => claimed}}),
    Parent = self(),
    Count = 16,
    lists:foreach(fun(_) ->
        spawn(fun() ->
            Parent ! {mnesia_take_result,
                      erlang_adk_session_mnesia:take_state(
                        App, User, SessionId, Key)}
        end)
    end, lists:seq(1, Count)),
    Results = collect_mnesia_take_results(Count, []),
    ?assertEqual(1, length([ok || {ok, claimed} <- Results])),
    ?assertEqual(Count - 1,
                 length([error || {error, not_found} <- Results])),
    {ok, Session} = erlang_adk_session_mnesia:get_session(
                      App, User, SessionId),
    ?assertEqual(error, maps:find(Key, maps:get(state, Session))).

test_compare_and_append_event() ->
    App = <<"CompareAppendMnesiaApp">>,
    User = <<"CompareAppendMnesiaUser">>,
    SessionId = <<"compare-append-mnesia-session">>,
    Key = <<"continuation">>,
    Expected = #{<<"revision">> => 1},
    {ok, _} = erlang_adk_session_mnesia:create_session(
                App, User,
                #{session_id => SessionId,
                  state => #{Key => Expected}}),
    Event = adk_event:new(
              <<"tool">>, <<"progress">>,
              #{actions =>
                    #{<<"state_delta">> => #{<<"progress">> => 50}}}),
    ok = erlang_adk_session_mnesia:add_event_if_state(
           App, User, SessionId, Key, Expected, Event),
    ?assertEqual(
       {error, conflict},
       erlang_adk_session_mnesia:add_event_if_state(
         App, User, SessionId, Key,
         #{<<"revision">> => 2}, Event)),
    {ok, Session} = erlang_adk_session_mnesia:get_session(
                      App, User, SessionId),
    ?assertEqual(Expected, maps:get(Key, maps:get(state, Session))),
    ?assertEqual(50, maps:get(<<"progress">>, maps:get(state, Session))),
    ?assertEqual([Event], maps:get(events, Session)).

test_runner_integration() ->
    App = <<"MnesiaRunnerApp">>,
    User = <<"MnesiaRunnerUser">>,
    SessionId = <<"mnesia-runner-session">>,
    AgentPid = spawn(fun mnesia_runner_agent/0),
    Runner = adk_runner:new(
               AgentPid, App, erlang_adk_session_mnesia,
               #{run_timeout => 2000}),
    try
        ?assertEqual(
           {ok, <<"persistent response">>},
           adk_runner:run(Runner, User, SessionId, <<"Hello">>)),
        {ok, Session} = erlang_adk_session_mnesia:get_session(
                          App, User, SessionId),
        Events = maps:get(events, Session),
        ?assertEqual([<<"user">>, <<"persistent-agent">>],
                     [Event#adk_event.author || Event <- Events])
    after
        AgentPid ! stop
    end.

mnesia_runner_agent() ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"persistent-agent">>, #{}, [], #{}}),
            mnesia_runner_agent();
        {'$gen_call', From, {run_with_events, _History, InvocationId}} ->
            Event = adk_event:new(
                      <<"persistent-agent">>, <<"persistent response">>,
                      #{invocation_id => InvocationId, is_final => true}),
            gen_server:reply(From, {ok, Event}),
            mnesia_runner_agent();
        stop ->
            ok;
        _ ->
            mnesia_runner_agent()
    end.

collect_mnesia_create_winners(0, Acc) -> Acc;
collect_mnesia_create_winners(Remaining, Acc) ->
    receive
        {mnesia_create_result, {ok, Session}} ->
            Winner = maps:get(<<"winner">>, maps:get(state, Session)),
            collect_mnesia_create_winners(Remaining - 1, [Winner | Acc]);
        {mnesia_create_result, Error} ->
            erlang:error({unexpected_mnesia_create_result, Error})
    after 5000 ->
        erlang:error(mnesia_create_timeout)
    end.

collect_mnesia_take_results(0, Acc) -> Acc;
collect_mnesia_take_results(Remaining, Acc) ->
    receive
        {mnesia_take_result, Result} ->
            collect_mnesia_take_results(Remaining - 1, [Result | Acc])
    after 5000 ->
        erlang:error(mnesia_take_timeout)
    end.
