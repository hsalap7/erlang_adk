-module(adk_runner_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

-define(APP, <<"test_app">>).
-define(USER, <<"user1">>).

setup() ->
    erlang_adk_session:init(),
    ok.

cleanup(_) ->
    ets:delete(adk_sessions),
    ok.

runner_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
      fun test_sync_run/0,
      fun test_async_run/0
     ]}.

dummy_agent_loop() ->
    receive
        {'$gen_call', From, {run_with_events, _HistoryEvents, InvId}} ->
            FinalEvent = adk_event:new(<<"agent">>, <<"Response text">>, #{invocation_id => InvId, is_final => true}),
            gen_server:reply(From, {ok, FinalEvent}),
            dummy_agent_loop();
        _ ->
            dummy_agent_loop()
    end.

test_sync_run() ->
    %% Start dummy agent
    AgentPid = spawn(fun dummy_agent_loop/0),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session),
    SessionId = <<"sess1">>,
    
    Result = adk_runner:run(Runner, ?USER, SessionId, <<"Hello">>),
    ?assertEqual({ok, <<"Response text">>}, Result),
    
    %% Verify events were recorded
    {ok, Session} = erlang_adk_session:get_session(?APP, ?USER, SessionId),
    Events = maps:get(events, Session),
    ?assertEqual(2, length(Events)),
    [E1, E2] = Events,
    ?assertEqual(<<"user">>, E1#adk_event.author),
    ?assertEqual(<<"Hello">>, E1#adk_event.content),
    ?assertEqual(<<"agent">>, E2#adk_event.author),
    ?assertEqual(<<"Response text">>, E2#adk_event.content).

test_async_run() ->
    AgentPid = spawn(fun dummy_agent_loop/0),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session),
    SessionId = <<"sess2">>,
    
    {ok, StreamPid} = adk_runner:run_async(Runner, ?USER, SessionId, <<"Hello Async">>),
    
    %% We expect three messages: {adk_event, StreamPid, UserEvent}, {adk_event, StreamPid, AgentEvent}, {adk_done, StreamPid}
    receive {adk_event, StreamPid, E1} -> 
        ?assertEqual(<<"user">>, E1#adk_event.author),
        ?assertEqual(<<"Hello Async">>, E1#adk_event.content)
    after 1000 -> ?assert(false) end,
    
    receive {adk_event, StreamPid, E2} -> 
        ?assertEqual(<<"agent">>, E2#adk_event.author),
        ?assertEqual(<<"Response text">>, E2#adk_event.content)
    after 1000 -> ?assert(false) end,
    
    receive {adk_done, StreamPid} -> 
        ok
    after 1000 -> ?assert(false) end.
