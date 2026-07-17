-module(adk_runner_test).
-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

-define(APP, <<"test_app">>).
-define(USER, <<"user1">>).

setup() ->
    erlang_adk_session:init(),
    ok.

cleanup(_) ->
    %% The table belongs to the supervised session owner, not this test process.
    ets:delete_all_objects(adk_sessions),
    ok.

runner_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
      fun test_sync_run/0,
      fun test_async_run/0,
      fun test_non_text_callback_result_is_not_dropped/0,
      fun test_invalid_run_timeout_is_rejected_before_spawn/0,
      fun test_invalid_execution_limits_are_rejected_before_spawn/0,
      fun test_sync_run_timeout_is_bounded/0,
      fun test_async_run_timeout_kills_invocation_worker/0,
      fun test_async_run_can_be_cancelled/0,
      fun test_max_llm_calls_bounds_tool_loop/0,
      fun test_max_tool_rounds_bounds_tool_execution/0,
      fun test_error_clears_temp_state/0
     ]}.

dummy_agent_loop() ->
    receive
        {'$gen_call', From, {run_with_events, _HistoryEvents, InvId}} ->
            FinalEvent = adk_event:new(<<"agent">>, <<"Response text">>, #{invocation_id => InvId, is_final => true}),
            gen_server:reply(From, {ok, FinalEvent}),
            dummy_agent_loop();
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From, {ok, <<"agent">>, #{}, [], #{}}),
            dummy_agent_loop();
        stop ->
            ok;
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
    ?assertEqual(<<"Response text">>, E2#adk_event.content),
    %% run/4 consumes the terminal adk_done and its monitor notification.
    receive
        {adk_done, _} -> ?assert(false);
        {'DOWN', _, process, _, _} -> ?assert(false)
    after 0 ->
        ok
    end,
    AgentPid ! stop.

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
    after 1000 -> ?assert(false) end,
    AgentPid ! stop.

test_invalid_run_timeout_is_rejected_before_spawn() ->
    AgentPid = spawn(fun dummy_agent_loop/0),
    try
        ?assertError(
           {invalid_run_timeout, -1},
           adk_runner:new(
             AgentPid, ?APP, erlang_adk_session, #{run_timeout => -1})),
        ?assertError(
           {invalid_run_timeout, invalid},
           adk_runner:new(
             AgentPid, ?APP, erlang_adk_session, #{run_timeout => invalid}))
    after
        AgentPid ! stop
    end.

test_invalid_execution_limits_are_rejected_before_spawn() ->
    AgentPid = spawn(fun dummy_agent_loop/0),
    try
        ?assertError(
           {invalid_runner_limit, max_llm_calls, 0},
           adk_runner:new(
             AgentPid, ?APP, erlang_adk_session,
             #{max_llm_calls => 0})),
        ?assertError(
           {invalid_runner_limit, max_tool_rounds, invalid},
           adk_runner:new(
             AgentPid, ?APP, erlang_adk_session,
             #{max_tool_rounds => invalid}))
    after
        AgentPid ! stop
    end.

test_non_text_callback_result_is_not_dropped() ->
    SessionId = <<"callback_map_sess">>,
    AgentPid = spawn(fun callback_runtime_agent_loop/0),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session),
    try
        ?assertEqual(
           {ok, <<"#{status => ok}">>},
           adk_runner:run(
             Runner, ?USER, SessionId, <<"map response">>)),
        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        FinalEvents = [Event || Event <- maps:get(events, Session),
                                Event#adk_event.is_final =:= true],
        ?assertMatch([#adk_event{content = <<"#{status => ok}">>}],
                     FinalEvents)
    after
        AgentPid ! stop,
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

callback_runtime_agent_loop() ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From,
              {ok, <<"RunnerMapCallbackAgent">>,
               #{callbacks => [adk_agent_history_callback]}, [], #{}}),
            callback_runtime_agent_loop();
        stop ->
            ok;
        _ ->
            callback_runtime_agent_loop()
    end.

test_sync_run_timeout_is_bounded() ->
    AgentPid = spawn(fun blocking_agent_loop/0),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session,
                            #{run_timeout => 25}),
    Start = erlang:monotonic_time(millisecond),
    ?assertEqual({error, timeout},
                 adk_runner:run(Runner, ?USER, <<"timeout_sess">>, <<"Block">>)),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    ?assert(Elapsed < 1000),
    receive
        {'DOWN', _, process, _, _} -> ?assert(false)
    after 0 ->
        ok
    end,
    AgentPid ! stop.

blocking_agent_loop() ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From, {ok, <<"blocking-agent">>, #{}, [], #{}}),
            blocking_agent_loop();
        {'$gen_call', _From, {run_with_events, _HistoryEvents, _InvId}} ->
            %% Intentionally never reply; the runner deadline must remain bounded.
            blocking_agent_loop();
        stop ->
            ok;
        _ ->
            blocking_agent_loop()
    end.

test_async_run_timeout_kills_invocation_worker() ->
    TestPid = self(),
    AgentPid = spawn(fun() -> reporting_blocking_agent_loop(TestPid) end),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session,
                            #{run_timeout => 30}),
    {ok, StreamPid} = adk_runner:run_async(
                        Runner, ?USER, <<"async_timeout_sess">>, <<"Block">>),
    WorkerPid = receive
        {blocked_runner_worker, SeenWorkerPid} -> SeenWorkerPid
    after 1000 ->
        ?assert(false)
    end,
    receive
        {adk_event, StreamPid, #adk_event{author = <<"user">>}} -> ok
    after 1000 ->
        ?assert(false)
    end,
    receive
        {adk_error, StreamPid, timeout} -> ok
    after 1000 ->
        ?assert(false)
    end,
    ?assertEqual(ok, await_process_exit(StreamPid, 100)),
    ?assertEqual(ok, await_process_exit(WorkerPid, 100)),
    assert_no_second_terminal(StreamPid),
    AgentPid ! stop.

test_async_run_can_be_cancelled() ->
    TestPid = self(),
    AgentPid = spawn(fun() -> reporting_blocking_agent_loop(TestPid) end),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    {ok, StreamPid} = adk_runner:run_async(
                        Runner, ?USER, <<"cancel_sess">>, <<"Block">>),
    WorkerPid = receive
        {blocked_runner_worker, SeenWorkerPid} -> SeenWorkerPid
    after 1000 ->
        ?assert(false)
    end,
    ok = adk_runner:cancel(StreamPid, test_cancel),
    receive
        {adk_error, StreamPid, {cancelled, test_cancel}} -> ok
    after 1000 ->
        ?assert(false)
    end,
    ?assertEqual(ok, await_process_exit(StreamPid, 100)),
    ?assertEqual(ok, await_process_exit(WorkerPid, 100)),
    assert_no_second_terminal(StreamPid),
    AgentPid ! stop.

reporting_blocking_agent_loop(TestPid) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"blocking-agent">>, #{}, [], #{}}),
            reporting_blocking_agent_loop(TestPid);
        {'$gen_call', From, {run_with_events, _HistoryEvents, _InvId}} ->
            TestPid ! {blocked_runner_worker, element(1, From)},
            %% Intentionally never reply. The coordinator must terminate the
            %% process blocked in gen_server:call when its deadline/cancel wins.
            reporting_blocking_agent_loop(TestPid);
        stop ->
            ok;
        _ ->
            reporting_blocking_agent_loop(TestPid)
    end.

test_max_llm_calls_bounds_tool_loop() ->
    AgentPid = spawn(fun() -> endless_tool_agent_loop(0) end),
    SessionId = <<"max_llm_calls_sess">>,
    Runner = adk_runner:new(
               AgentPid, ?APP, erlang_adk_session,
               #{run_timeout => 1000,
                 max_llm_calls => 2,
                 max_tool_rounds => 10}),
    try
        ?assertEqual(
           {error, {max_llm_calls_exceeded, 2}},
           adk_runner:run(Runner, ?USER, SessionId, <<"Loop">>)),
        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        Events = maps:get(events, Session),
        ?assertEqual(2, count_author(<<"loop-agent">>, Events)),
        ?assertEqual(2, count_author(<<"tool">>, Events))
    after
        AgentPid ! stop,
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

test_max_tool_rounds_bounds_tool_execution() ->
    AgentPid = spawn(fun() -> endless_tool_agent_loop(0) end),
    SessionId = <<"max_tool_rounds_sess">>,
    Runner = adk_runner:new(
               AgentPid, ?APP, erlang_adk_session,
               #{run_timeout => 1000,
                 max_llm_calls => 10,
                 max_tool_rounds => 1}),
    try
        ?assertEqual(
           {error, {max_tool_rounds_exceeded, 1}},
           adk_runner:run(Runner, ?USER, SessionId, <<"Loop">>)),
        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        Events = maps:get(events, Session),
        ?assertEqual(2, count_author(<<"loop-agent">>, Events)),
        ?assertEqual(1, count_author(<<"tool">>, Events))
    after
        AgentPid ! stop,
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

endless_tool_agent_loop(CallNumber) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"loop-agent">>, #{}, [dummy_tool], #{}}),
            endless_tool_agent_loop(CallNumber);
        {'$gen_call', From, {run_with_events, _HistoryEvents, InvId}} ->
            CallId = integer_to_binary(CallNumber),
            Calls = [{<<"dummy_tool">>, #{<<"arg">> => CallId},
                      undefined, CallId}],
            Event = adk_event:new(
                      <<"loop-agent">>, {tool_calls, Calls},
                      #{invocation_id => InvId}),
            gen_server:reply(From, {tool_calls, Event, Calls}),
            endless_tool_agent_loop(CallNumber + 1);
        stop ->
            ok;
        _ ->
            endless_tool_agent_loop(CallNumber)
    end.

count_author(Author, Events) ->
    length([ok || #adk_event{author = SeenAuthor} <- Events,
                  SeenAuthor =:= Author]).

await_process_exit(Pid, 0) ->
    case is_process_alive(Pid) of
        false -> ok;
        true -> timeout
    end;
await_process_exit(Pid, Attempts) ->
    case is_process_alive(Pid) of
        false -> ok;
        true ->
            receive after 1 -> ok end,
            await_process_exit(Pid, Attempts - 1)
    end.

assert_no_second_terminal(StreamPid) ->
    receive
        {adk_done, StreamPid} -> ?assert(false);
        {adk_paused, StreamPid, _} -> ?assert(false);
        {adk_error, StreamPid, _} -> ?assert(false)
    after 20 ->
        ok
    end.

test_error_clears_temp_state() ->
    SessionId = <<"error_sess">>,
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER,
                #{session_id => SessionId,
                  state => #{<<"temp:request_data">> => <<"discard on error">>}}),
    AgentPid = spawn(fun error_agent_loop/0),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session,
                            #{run_timeout => 1000}),
    ?assertEqual({error, model_failed},
                 adk_runner:run(Runner, ?USER, SessionId, <<"Fail">>)),
    {ok, Session} = erlang_adk_session:get_session(?APP, ?USER, SessionId),
    ?assertEqual(error,
                 maps:find(<<"temp:request_data">>, maps:get(state, Session))),
    AgentPid ! stop.

error_agent_loop() ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From, {ok, <<"error-agent">>, #{}, [], #{}}),
            error_agent_loop();
        {'$gen_call', From, {run_with_events, _HistoryEvents, _InvId}} ->
            gen_server:reply(From, {error, model_failed}),
            error_agent_loop();
        stop ->
            ok;
        _ ->
            error_agent_loop()
    end.
