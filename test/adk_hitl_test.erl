-module(adk_hitl_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

-define(APP, <<"hitl_app">>).
-define(USER, <<"hitl_user">>).
-define(SIG, <<"approval-call-signature">>).
-define(CALL_ID, <<"approval-call-id">>).

hitl_pause_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
      fun test_pause_and_resume_same_invocation/0,
      fun test_concurrent_resume_is_single_use/0,
      fun test_sync_run_returns_paused/0,
      fun test_resume_rejects_missing_pause/0
     ]}.

setup() ->
    erlang_adk_session:init(),
    cleanup_sessions(),
    ok.

cleanup(_) ->
    cleanup_sessions().

cleanup_sessions() ->
    lists:foreach(
      fun(SessionId) ->
          erlang_adk_session:delete_session(?APP, ?USER, SessionId)
      end,
      [<<"hitl_resume_sess">>, <<"hitl_concurrent_sess">>,
       <<"hitl_sync_sess">>, <<"hitl_missing_sess">>]),
    ok.

%% The first model turn requests approval. The resumed turn reports the exact
%% invocation and history it received before returning a final response.
hitl_agent_loop(TestPid, Stage) ->
    receive
        {'$gen_call', From, {run_with_events, _History, InvId}} when Stage =:= initial ->
            TestPid ! {initial_invocation, InvId},
            Calls = [{<<"request_human_approval">>,
                      #{<<"action_summary">> => <<"Format Drive">>},
                      ?SIG, ?CALL_ID}],
            AgentEvent = adk_event:new(<<"agent">>, {tool_calls, Calls},
                                       #{invocation_id => InvId}),
            gen_server:reply(From, {tool_calls, AgentEvent, Calls}),
            hitl_agent_loop(TestPid, waiting_for_resume);
        {'$gen_call', From, {run_with_events, History, InvId}}
          when Stage =:= waiting_for_resume ->
            TestPid ! {resumed_invocation, InvId, History},
            FinalEvent = adk_event:new(<<"agent">>, <<"Approved and completed">>,
                                       #{invocation_id => InvId, is_final => true}),
            gen_server:reply(From, {ok, FinalEvent}),
            hitl_agent_loop(TestPid, complete);
        {'$gen_call', From, get_tools} ->
            gen_server:reply(From, {ok, [adk_long_running_tool], #{}}),
            hitl_agent_loop(TestPid, Stage);
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From,
              {ok, <<"agent">>, #{}, [adk_long_running_tool], #{}}),
            hitl_agent_loop(TestPid, Stage);
        stop ->
            ok;
        _ ->
            hitl_agent_loop(TestPid, Stage)
    end.

test_pause_and_resume_same_invocation() ->
    SessionId = <<"hitl_resume_sess">>,
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER,
                #{session_id => SessionId,
                  state => #{<<"temp:approval_context">> => <<"keep while paused">>}}),
    TestPid = self(),
    AgentPid1 = spawn(fun() -> hitl_agent_loop(TestPid, initial) end),
    Runner = adk_runner:new(AgentPid1, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),

    {ok, StreamPid} = adk_runner:run_async(
                        Runner, ?USER, SessionId, <<"Do dangerous thing">>),
    {PauseEvent, PauseEvents} = await_pause(StreamPid, []),
    receive
        {initial_invocation, OriginalInvId} ->
            ?assertEqual(OriginalInvId, PauseEvent#adk_event.invocation_id),
            assert_pause_event(PauseEvent),
            ?assert(lists:member(PauseEvent, PauseEvents)),

            %% Invocation temp state is deliberately retained at the pause boundary.
            {ok, PausedSession} = erlang_adk_session:get_session(
                                    ?APP, ?USER, SessionId),
            PausedState = maps:get(state, PausedSession),
            ?assertEqual(<<"keep while paused">>,
                         maps:get(<<"temp:approval_context">>, PausedState)),

            {ok, ResumePid} = adk_runner:resume(
                                Runner, ?USER, SessionId, <<"Approved">>),
            ResumeEvents = await_done(ResumePid, []),
            assert_correlated_tool_response(ResumeEvents, OriginalInvId),

            receive
                {resumed_invocation, ResumedInvId, History} ->
                    ?assertEqual(OriginalInvId, ResumedInvId),
                    assert_history_has_correlated_response(History, OriginalInvId)
            after 1000 ->
                ?assert(false)
            end,

            %% A continuation is single-use and terminal completion clears temp state.
            ?assertEqual({error, no_paused_invocation},
                         adk_runner:resume(Runner, ?USER, SessionId, <<"Again">>)),
            {ok, FinalSession} = erlang_adk_session:get_session(?APP, ?USER, SessionId),
            FinalState = maps:get(state, FinalSession),
            ?assertEqual(error, maps:find(<<"temp:approval_context">>, FinalState))
    after 1000 ->
        ?assert(false)
    end,
    AgentPid1 ! stop.

test_concurrent_resume_is_single_use() ->
    SessionId = <<"hitl_concurrent_sess">>,
    TestPid = self(),
    AgentPid = spawn(fun() -> hitl_agent_loop(TestPid, initial) end),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    {ok, StreamPid} = adk_runner:run_async(
                        Runner, ?USER, SessionId, <<"Needs one approval">>),
    {_PauseEvent, _Events} = await_pause(StreamPid, []),

    Parent = self(),
    Resume = fun() ->
        receive
            go ->
                Parent ! {resume_result,
                          adk_runner:resume(
                            Runner, ?USER, SessionId, <<"Approved">>)}
        end
    end,
    Caller1 = spawn(Resume),
    Caller2 = spawn(Resume),
    Caller1 ! go,
    Caller2 ! go,
    Results = [receive {resume_result, Result} -> Result after 1000 -> timeout end
               || _ <- [1, 2]],
    Winners = [Pid || {ok, Pid} <- Results],
    ?assertMatch([_], Winners),
    ?assertEqual(1, length([ok || {error, no_paused_invocation} <- Results])),
    [Winner] = Winners,
    Ref = erlang:monitor(process, Winner),
    receive
        %% If the short-lived continuation finished before monitor/2, the
        %% synthetic DOWN reason is noproc rather than its original normal.
        {'DOWN', Ref, process, Winner, Reason}
          when Reason =:= normal; Reason =:= noproc -> ok
    after 1000 ->
        ?assert(false)
    end,
    {ok, CompletedSession} = erlang_adk_session:get_session(
                               ?APP, ?USER, SessionId),
    CompletedEvents = maps:get(events, CompletedSession),
    ?assertEqual(
       1,
       length([Event || Event <- CompletedEvents,
                        is_correlated_tool_response(Event)])),
    ?assertEqual(
       1,
       length([Event || Event <- CompletedEvents,
                        Event#adk_event.is_final =:= true])),
    ?assertEqual({error, no_paused_invocation},
                 adk_runner:resume(Runner, ?USER, SessionId, <<"Again">>)),
    AgentPid ! stop.

test_sync_run_returns_paused() ->
    SessionId = <<"hitl_sync_sess">>,
    TestPid = self(),
    AgentPid = spawn(fun() -> hitl_agent_loop(TestPid, initial) end),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    {paused, PauseEvent} = adk_runner:run(
                             Runner, ?USER, SessionId, <<"Needs approval">>),
    assert_pause_event(PauseEvent),
    %% The synchronous collector consumed its terminal pause message.
    receive
        {adk_paused, _, _} -> ?assert(false)
    after 0 ->
        ok
    end,
    AgentPid ! stop.

test_resume_rejects_missing_pause() ->
    SessionId = <<"hitl_missing_sess">>,
    TestPid = self(),
    AgentPid = spawn(fun() -> hitl_agent_loop(TestPid, initial) end),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session),
    ?assertEqual({error, no_paused_invocation},
                 adk_runner:resume(Runner, ?USER, SessionId, <<"Approved">>)),
    %% A failed resume is read-only; it does not create an empty session.
    ?assertEqual({error, not_found},
                 erlang_adk_session:get_session(?APP, ?USER, SessionId)),
    AgentPid ! stop.

await_pause(StreamPid, Acc) ->
    receive
        {adk_event, StreamPid, Event} ->
            await_pause(StreamPid, [Event | Acc]);
        {adk_paused, StreamPid, PauseEvent} ->
            {PauseEvent, lists:reverse(Acc)};
        {adk_error, StreamPid, Reason} ->
            ?assertEqual(no_error_expected, Reason)
    after 1000 ->
        ?assert(false)
    end.

await_done(StreamPid, Acc) ->
    receive
        {adk_event, StreamPid, Event} ->
            await_done(StreamPid, [Event | Acc]);
        {adk_done, StreamPid} ->
            lists:reverse(Acc);
        {adk_error, StreamPid, Reason} ->
            ?assertEqual(no_error_expected, Reason)
    after 1000 ->
        ?assert(false)
    end.

assert_pause_event(PauseEvent) ->
    ?assertEqual(<<"runner">>, PauseEvent#adk_event.author),
    ?assertEqual(<<"Format Drive">>, PauseEvent#adk_event.content),
    Pause = maps:get(<<"pause">>, PauseEvent#adk_event.actions),
    ?assertEqual(<<"request_human_approval">>, maps:get(<<"tool_name">>, Pause)),
    ?assertEqual(?SIG, maps:get(<<"thought_signature">>, Pause)),
    ?assertEqual(?CALL_ID, maps:get(<<"call_id">>, Pause)),
    ?assertEqual(<<"human_in_the_loop">>, maps:get(<<"reason">>, Pause)).

assert_correlated_tool_response(Events, InvId) ->
    ToolEvents = [Event || Event <- Events,
                           Event#adk_event.author =:= <<"tool">>],
    ?assertMatch([_], ToolEvents),
    [ToolEvent] = ToolEvents,
    ?assertEqual(InvId, ToolEvent#adk_event.invocation_id),
    {tool_response, <<"request_human_approval">>, Result, ?SIG, ?CALL_ID} =
        ToolEvent#adk_event.content,
    ?assertEqual(true, maps:get(<<"success">>, Result)),
    ?assertEqual(#{<<"result">> => <<"Approved">>},
                 maps:get(<<"result">>, Result)).

assert_history_has_correlated_response(History, InvId) ->
    Matches = [Event || Event <- History,
                        Event#adk_event.author =:= <<"tool">>,
                        Event#adk_event.invocation_id =:= InvId,
                        element(1, Event#adk_event.content) =:= tool_response],
    ?assertMatch([_], Matches),
    [ToolEvent] = Matches,
    ?assertMatch({tool_response, <<"request_human_approval">>, _, ?SIG, ?CALL_ID},
                 ToolEvent#adk_event.content).

is_correlated_tool_response(
  #adk_event{author = <<"tool">>,
             content = {tool_response, <<"request_human_approval">>,
                        _, ?SIG, ?CALL_ID}}) ->
    true;
is_correlated_tool_response(_) ->
    false.
