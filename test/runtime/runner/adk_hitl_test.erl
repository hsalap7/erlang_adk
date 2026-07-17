-module(adk_hitl_test).
-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

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
      fun test_pause_event_is_json_roundtrippable/0,
      fun test_two_paused_invocations_are_independently_resumable/0,
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
       <<"hitl_two_pauses_sess">>, <<"hitl_sync_sess">>,
       <<"hitl_missing_sess">>, <<"hitl_json_pause_sess">>]),
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

%% This agent leaves a second, correlated Gemini-style call in the durable
%% continuation.  Its first call deliberately has no signature or call ID.
json_pause_agent_loop(initial) ->
    receive
        {'$gen_call', From, {run_with_events, _History, InvId}} ->
            Calls = [
                {<<"request_human_approval">>,
                 #{<<"action_summary">> => <<"Publish Release">>},
                 undefined},
                {<<"missing_after_approval">>,
                 #{<<"release">> => <<"0.3.0">>},
                 undefined, <<"remaining-call-id">>}
            ],
            AgentEvent = adk_event:new(
                           <<"agent">>, {tool_calls, Calls},
                           #{invocation_id => InvId}),
            gen_server:reply(From, {tool_calls, AgentEvent, Calls}),
            json_pause_agent_loop(waiting_for_resume);
        {'$gen_call', From, get_tools} ->
            gen_server:reply(From, {ok, [adk_long_running_tool], #{}}),
            json_pause_agent_loop(initial);
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"json-agent">>, #{},
                     [adk_long_running_tool], #{}}),
            json_pause_agent_loop(initial);
        stop -> ok
    end;
json_pause_agent_loop(waiting_for_resume) ->
    receive
        {'$gen_call', From, {run_with_events, _History, InvId}} ->
            FinalEvent = adk_event:new(
                           <<"json-agent">>, <<"Release handled">>,
                           #{invocation_id => InvId, is_final => true}),
            gen_server:reply(From, {ok, FinalEvent}),
            json_pause_agent_loop(done);
        {'$gen_call', From, get_tools} ->
            gen_server:reply(From, {ok, [adk_long_running_tool], #{}}),
            json_pause_agent_loop(waiting_for_resume);
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"json-agent">>, #{},
                     [adk_long_running_tool], #{}}),
            json_pause_agent_loop(waiting_for_resume);
        stop -> ok
    end;
json_pause_agent_loop(done) ->
    receive
        {'$gen_call', From, get_tools} ->
            gen_server:reply(From, {ok, [adk_long_running_tool], #{}}),
            json_pause_agent_loop(done);
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"json-agent">>, #{},
                     [adk_long_running_tool], #{}}),
            json_pause_agent_loop(done);
        stop -> ok
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
            ?assertEqual(
               {error, no_paused_invocation},
               adk_runner:resume(
                 Runner, ?USER, SessionId, OriginalInvId, <<"Again">>)),
            {ok, FinalSession} = erlang_adk_session:get_session(?APP, ?USER, SessionId),
            FinalState = maps:get(state, FinalSession),
            ?assertEqual(error, maps:find(<<"temp:approval_context">>, FinalState))
    after 1000 ->
        ?assert(false)
    end,
    AgentPid1 ! stop.

test_pause_event_is_json_roundtrippable() ->
    SessionId = <<"hitl_json_pause_sess">>,
    AgentPid = spawn(fun() -> json_pause_agent_loop(initial) end),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    try
        {ok, StreamPid} = adk_runner:run_async(
                            Runner, ?USER, SessionId,
                            <<"Publish the release">>),
        {PauseEvent, _Events} = await_pause(StreamPid, []),

        {ok, Encoded} = adk_event:encode(PauseEvent),
        ?assertEqual(Encoded, adk_event:to_map(PauseEvent)),
        JsonMap = jsx:decode(jsx:encode(Encoded), [return_maps]),
        ?assertEqual({ok, PauseEvent}, adk_event:decode(JsonMap)),

        Pause = maps:get(<<"pause">>, PauseEvent#adk_event.actions),
        ?assertEqual(null, maps:get(<<"thought_signature">>, Pause)),
        ?assertEqual(null, maps:get(<<"call_id">>, Pause)),
        StateDelta = maps:get(
                       <<"state_delta">>, PauseEvent#adk_event.actions),
        [_ContinuationKey] = maps:keys(StateDelta),
        [PauseState] = maps:values(StateDelta),
        ?assertEqual(<<"human_in_the_loop">>,
                     maps:get(<<"reason">>, PauseState)),
        [RemainingCall] = maps:get(<<"remaining_calls">>, PauseState),
        ?assert(is_map(RemainingCall)),
        ?assertEqual(<<"remaining-call-id">>,
                     maps:get(<<"call_id">>, RemainingCall)),

        InvocationId = PauseEvent#adk_event.invocation_id,
        {ok, ResumePid} = adk_runner:resume(
                            Runner, ?USER, SessionId, InvocationId,
                            <<"Approved">>),
        ResumeEvents = await_done(ResumePid, []),
        ?assert(lists:any(
                  fun(Event) -> Event#adk_event.is_final =:= true end,
                  ResumeEvents))
    after
        AgentPid ! stop
    end.

test_two_paused_invocations_are_independently_resumable() ->
    SessionId = <<"hitl_two_pauses_sess">>,
    TestPid = self(),
    AgentPid1 = spawn(fun() -> hitl_agent_loop(TestPid, initial) end),
    AgentPid2 = spawn(fun() -> hitl_agent_loop(TestPid, initial) end),
    Runner1 = adk_runner:new(AgentPid1, ?APP, erlang_adk_session,
                             #{run_timeout => 2000}),
    Runner2 = adk_runner:new(AgentPid2, ?APP, erlang_adk_session,
                             #{run_timeout => 2000}),
    try
        {ok, StreamPid1} = adk_runner:run_async(
                             Runner1, ?USER, SessionId, <<"Approval one">>),
        {PauseEvent1, _} = await_pause(StreamPid1, []),
        InvId1 = PauseEvent1#adk_event.invocation_id,
        receive {initial_invocation, InvId1} -> ok
        after 1000 -> ?assert(false)
        end,

        {ok, StreamPid2} = adk_runner:run_async(
                             Runner2, ?USER, SessionId, <<"Approval two">>),
        {PauseEvent2, _} = await_pause(StreamPid2, []),
        InvId2 = PauseEvent2#adk_event.invocation_id,
        receive {initial_invocation, InvId2} -> ok
        after 1000 -> ?assert(false)
        end,
        ?assertNotEqual(InvId1, InvId2),

        %% The compatibility API refuses to guess. The pause event's
        %% invocation_id is the explicit continuation reference for resume/5.
        {error, {ambiguous_paused_invocation, AmbiguousIds}} =
            adk_runner:resume(Runner1, ?USER, SessionId, <<"Approved">>),
        ?assertEqual(lists:sort([InvId1, InvId2]), AmbiguousIds),

        {ok, ResumePid1} = adk_runner:resume(
                             Runner1, ?USER, SessionId, InvId1,
                             <<"Approved one">>),
        _ = await_done(ResumePid1, []),
        receive {resumed_invocation, InvId1, _History1} -> ok
        after 1000 -> ?assert(false)
        end,
        ?assertEqual(
           {error, no_paused_invocation},
           adk_runner:resume(
             Runner1, ?USER, SessionId, InvId1, <<"Replay">>)),

        %% Completing the first invocation must not clear the second
        %% invocation's continuation. With only one left resume/4 is safe.
        {ok, ResumePid2} = adk_runner:resume(
                             Runner2, ?USER, SessionId,
                             <<"Approved two">>),
        _ = await_done(ResumePid2, []),
        receive {resumed_invocation, InvId2, _History2} -> ok
        after 1000 -> ?assert(false)
        end,
        ?assertEqual(
           {error, no_paused_invocation},
           adk_runner:resume(
             Runner2, ?USER, SessionId, InvId2, <<"Replay">>))
    after
        AgentPid1 ! stop,
        AgentPid2 ! stop,
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

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
    ?assertEqual(PauseEvent#adk_event.invocation_id,
                 maps:get(<<"continuation_id">>, Pause)),
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
