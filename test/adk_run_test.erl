-module(adk_run_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

-define(APP, <<"adk_run_test">>).
-define(USER, <<"run-user">>).

adk_run_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun late_subscriber_receives_bounded_replay_case/0,
      fun credit_subscriber_is_bounded_and_detects_gap_case/0,
      fun credit_subscriber_runtime_buffer_overrun_case/0,
      fun starter_death_does_not_stop_run_case/0,
      fun cancel_reaches_runner_worker_case/0,
      fun terminal_is_emitted_exactly_once_case/0,
      fun dead_subscriber_is_removed_case/0,
      fun terminal_retention_expires_case/0,
      fun paused_run_resumes_as_new_supervised_run_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = ensure_started(adk_run_registry,
                        fun adk_run_registry:start_link/0),
    ok = ensure_started(adk_invocation_sup,
                        fun adk_invocation_sup:start_link/0),
    ok = erlang_adk_session:init(),
    ok.

cleanup(_Setup) ->
    %% Each test uses a unique session and every blocking run is cancelled.
    %% Completed invocation processes expire through their own retention timer.
    ok.

late_subscriber_receives_bounded_replay_case() ->
    Agent = spawn(fun() -> completing_agent_loop(0) end),
    Runner = runner(Agent, 2000),
    SessionId = unique_session(<<"late-replay">>),
    try
        {ok, RunId} = adk_run:start(
                        Runner, ?USER, SessionId, <<"hello">>,
                        #{retention_ms => 2000,
                          max_buffered_events => 8}),
        ?assertMatch(<<"run-", _/binary>>, RunId),
        Outcome = adk_run:await(RunId, 1000),
        ?assertEqual({completed, <<"Response text">>}, Outcome),

        %% Subscription happens after completion and must replay both events
        %% followed by the already-committed terminal outcome.
        ok = adk_run:subscribe(RunId),
        {Seqs, ReplayedOutcome} = collect_until_terminal(RunId, []),
        ?assertEqual([1, 2], Seqs),
        ?assertEqual(Outcome, ReplayedOutcome),
        ok = adk_run:unsubscribe(RunId)
    after
        Agent ! stop,
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

credit_subscriber_is_bounded_and_detects_gap_case() ->
    Agent = spawn(fun() -> completing_agent_loop(100) end),
    Runner = runner(Agent, 2000),
    SessionId = unique_session(<<"credit-bounded">>),
    try
        {ok, RunId} = adk_run:start(
                        Runner, ?USER, SessionId, <<"slow consumer">>,
                        #{retention_ms => 2000,
                          max_buffered_events => 1}),
        {ok, _Info} = adk_run:subscribe_credit(RunId, 0),
        FirstSeq = receive
            {adk_run_event, RunId, Seq, #adk_event{}} -> Seq
        after 1000 ->
            ?assert(false)
        end,
        ?assertEqual(1, FirstSeq),

        %% Let the producer finish while credit is withheld. No second run
        %% message may be pushed into this subscriber's mailbox.
        ?assertEqual({completed, <<"Response text">>},
                     adk_run:await(RunId, 1000)),
        assert_no_run_message(RunId),

        %% The one-event replay retained sequence 2, so returning credit for
        %% sequence 1 releases only that event, not the terminal sequence 3.
        ok = adk_run:ack(RunId, FirstSeq),
        SecondSeq = receive
            {adk_run_event, RunId, Seq2, #adk_event{}} -> Seq2
        after 1000 ->
            ?assert(false)
        end,
        ?assertEqual(2, SecondSeq),
        assert_no_run_message(RunId),
        ok = adk_run:ack(RunId, SecondSeq),
        receive
            {adk_run_terminal, RunId, 3,
             {completed, <<"Response text">>}} -> ok
        after 1000 ->
            ?assert(false)
        end,
        ok = adk_run:unsubscribe(RunId),

        %% A fresh cursor before the retained window is rejected explicitly;
        %% it never receives a misleading partial replay.
        {error, {replay_gap, Gap}} =
            adk_run:subscribe_credit(RunId, 0),
        ?assertEqual(0, maps:get(after_sequence, Gap)),
        ?assertEqual(2, maps:get(oldest_available_sequence, Gap)),
        ?assertEqual(3, maps:get(latest_sequence, Gap)),
        ?assertEqual(true, maps:get(terminal, Gap))
    after
        Agent ! stop,
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

credit_subscriber_runtime_buffer_overrun_case() ->
    TestPid = self(),
    Agent = spawn(fun() -> multi_round_agent_loop(TestPid, 0) end),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{run_timeout => 2000, max_tool_rounds => 8}),
    SessionId = unique_session(<<"credit-runtime-gap">>),
    try
        {ok, RunId} = adk_run:start(
                        Runner, ?USER, SessionId,
                        <<"produce several tool rounds">>,
                        #{retention_ms => 2000,
                          max_buffered_events => 2}),
        receive
            {multi_round_waiting, Agent} -> ok
        after 1000 ->
            ?assert(false)
        end,
        {ok, _Info} = adk_run:subscribe_credit(RunId, 0),
        FirstSeq = receive
            {adk_run_event, RunId, Seq, #adk_event{}} -> Seq
        after 1000 ->
            ?assert(false)
        end,
        ?assertEqual(1, FirstSeq),

        %% Hold the only credit while four tool rounds generate enough events
        %% to evict sequence 2 from the two-event replay window.
        Agent ! release_multi_rounds,
        ?assertEqual({completed, <<"Multi-round complete">>},
                     adk_run:await(RunId, 2000)),
        assert_no_run_message(RunId),
        {error, {replay_gap, Gap}} = adk_run:ack(RunId, FirstSeq),
        ?assertEqual(FirstSeq, maps:get(after_sequence, Gap)),
        ?assert(maps:get(oldest_available_sequence, Gap) > FirstSeq + 1),
        ?assert(maps:get(latest_sequence, Gap) >
                maps:get(oldest_available_sequence, Gap)),
        ?assertEqual(true, maps:get(terminal, Gap)),
        assert_no_run_message(RunId),
        {ok, Status} = adk_run:status(RunId),
        ?assertEqual(1, maps:get(subscriber_count, Status)),
        ok = adk_run:unsubscribe(RunId)
    after
        Agent ! stop,
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

starter_death_does_not_stop_run_case() ->
    Agent = spawn(fun() -> completing_agent_loop(50) end),
    Runner = runner(Agent, 2000),
    SessionId = unique_session(<<"detached">>),
    Parent = self(),
    try
        {Starter, StarterRef} =
            spawn_monitor(
              fun() ->
                  Result = adk_run:start(
                             Runner, ?USER, SessionId, <<"detached">>,
                             #{retention_ms => 2000}),
                  Parent ! {starter_result, self(), Result}
              end),
        RunId = receive
            {starter_result, Starter, {ok, Id}} -> Id
        after 1000 ->
            ?assert(false)
        end,
        receive
            {'DOWN', StarterRef, process, Starter, normal} -> ok
        after 1000 ->
            ?assert(false)
        end,
        ?assertEqual(
           {completed, <<"Response text">>},
           adk_run:await(RunId, 1000))
    after
        Agent ! stop,
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

cancel_reaches_runner_worker_case() ->
    TestPid = self(),
    Agent = spawn(fun() -> blocking_agent_loop(TestPid) end),
    Runner = runner(Agent, 5000),
    SessionId = unique_session(<<"cancel">>),
    try
        {ok, RunId} = adk_run:start(
                        Runner, ?USER, SessionId, <<"block">>,
                        #{retention_ms => 2000,
                          cancel_grace_ms => 100}),
        WorkerPid = receive
            {blocked_runner_worker, SeenWorkerPid} -> SeenWorkerPid
        after 1000 ->
            ?assert(false)
        end,
        WorkerRef = erlang:monitor(process, WorkerPid),
        ok = adk_run:subscribe(RunId),
        ok = adk_run:cancel(RunId, test_cancel),
        Cancelled = adk_run:await(RunId, 1000),
        ?assertMatch(
           {cancelled,
            {adk_failure,
             #{component := invocation, operation := cancel,
               reason := test_cancel}}},
           Cancelled),
        receive
            {'DOWN', WorkerRef, process, WorkerPid, _Reason} -> ok
        after 1000 ->
            ?assert(false)
        end,
        {_Seqs, TerminalCancelled} = collect_until_terminal(RunId, []),
        ?assertMatch(
           {cancelled,
            {adk_failure,
             #{component := invocation, operation := cancel,
               reason := test_cancel}}},
           TerminalCancelled),
        ?assertEqual(Cancelled, TerminalCancelled),
        assert_no_second_terminal(RunId)
    after
        Agent ! stop,
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

terminal_is_emitted_exactly_once_case() ->
    Agent = spawn(fun() -> completing_agent_loop(30) end),
    Runner = runner(Agent, 2000),
    SessionId = unique_session(<<"terminal-once">>),
    try
        {ok, RunId} = adk_run:start(
                        Runner, ?USER, SessionId, <<"once">>,
                        #{retention_ms => 2000}),
        ok = adk_run:subscribe(RunId),
        {_Seqs, {completed, <<"Response text">>}} =
            collect_until_terminal(RunId, []),
        assert_no_second_terminal(RunId),
        {ok, Status} = adk_run:status(RunId),
        ?assertEqual(completed, maps:get(state, Status)),
        ?assertEqual({completed, <<"Response text">>},
                     maps:get(outcome, Status)),
        ?assertEqual({error, already_terminal},
                     adk_run:cancel(RunId, too_late))
    after
        Agent ! stop,
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

dead_subscriber_is_removed_case() ->
    TestPid = self(),
    Agent = spawn(fun() -> blocking_agent_loop(TestPid) end),
    Runner = runner(Agent, 5000),
    SessionId = unique_session(<<"subscriber-monitor">>),
    Parent = self(),
    try
        {ok, RunId} = adk_run:start(
                        Runner, ?USER, SessionId, <<"block">>,
                        #{retention_ms => 2000}),
        receive
            {blocked_runner_worker, _WorkerPid} -> ok
        after 1000 ->
            ?assert(false)
        end,
        Subscriber = spawn(
                       fun() ->
                           ok = adk_run:subscribe(RunId),
                           Parent ! {subscribed, self()},
                           receive stop -> ok end
                       end),
        receive {subscribed, Subscriber} -> ok after 1000 -> ?assert(false) end,
        {ok, Before} = adk_run:status(RunId),
        ?assertEqual(1, maps:get(subscriber_count, Before)),
        SubscriberRef = erlang:monitor(process, Subscriber),
        exit(Subscriber, kill),
        receive
            {'DOWN', SubscriberRef, process, Subscriber, killed} -> ok
        after 1000 ->
            ?assert(false)
        end,
        ok = await_subscriber_count(RunId, 0, 100),
        ok = adk_run:cancel(RunId, cleanup),
        ?assertMatch(
           {cancelled,
            {adk_failure,
             #{component := invocation, operation := cancel,
               reason := cleanup}}},
           adk_run:await(RunId, 1000))
    after
        Agent ! stop,
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

terminal_retention_expires_case() ->
    Agent = spawn(fun() -> completing_agent_loop(0) end),
    Runner = runner(Agent, 2000),
    SessionId = unique_session(<<"retention">>),
    try
        {ok, RunId} = adk_run:start(
                        Runner, ?USER, SessionId, <<"short lived">>,
                        #{retention_ms => 20}),
        ?assertEqual({completed, <<"Response text">>},
                     adk_run:await(RunId, 1000)),
        ok = await_not_found(RunId, 100)
    after
        Agent ! stop,
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

paused_run_resumes_as_new_supervised_run_case() ->
    Agent = spawn(fun() -> resumable_agent_loop(initial) end),
    Runner = runner(Agent, 2000),
    SessionId = unique_session(<<"supervised-resume">>),
    try
        {ok, PausedRunId} = adk_run:start(
                              Runner, ?USER, SessionId,
                              <<"publish the release">>,
                              #{retention_ms => 2000}),
        {paused, PauseEvent} = adk_run:await(PausedRunId, 1000),
        ?assertMatch(#adk_event{invocation_id = <<"inv-", _/binary>>},
                     PauseEvent),

        {ok, ResumedRunId} = adk_run:resume(
                               PausedRunId,
                               #{<<"decision">> => <<"approved">>},
                               #{retention_ms => 2000}),
        ?assertNotEqual(PausedRunId, ResumedRunId),
        ?assertEqual({completed, <<"Release published">>},
                     adk_run:await(ResumedRunId, 1000)),

        {ok, PausedStatus} = adk_run:status(PausedRunId),
        {ok, ResumedStatus} = adk_run:status(ResumedRunId),
        ?assertEqual(ResumedRunId, maps:get(resumed_to, PausedStatus)),
        ?assertEqual(PausedRunId,
                     maps:get(parent_run_id, ResumedStatus)),
        ?assertEqual(
           {error, {already_resumed, ResumedRunId}},
           adk_run:resume(PausedRunId, <<"replay">>))
    after
        Agent ! stop,
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

runner(Agent, Timeout) ->
    adk_runner:new(Agent, ?APP, erlang_adk_session,
                   #{run_timeout => Timeout}).

completing_agent_loop(Delay) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"run-agent">>, #{}, [], #{}}),
            completing_agent_loop(Delay);
        {'$gen_call', From, {run_with_events, _History, InvocationId}} ->
            case Delay of
                0 ->
                    reply_final(From, InvocationId);
                _ ->
                    erlang:send_after(
                      Delay, self(), {reply_final, From, InvocationId})
            end,
            completing_agent_loop(Delay);
        {reply_final, From, InvocationId} ->
            reply_final(From, InvocationId),
            completing_agent_loop(Delay);
        stop ->
            ok;
        _Other ->
            completing_agent_loop(Delay)
    end.

reply_final(From, InvocationId) ->
    Event = adk_event:new(
              <<"run-agent">>, <<"Response text">>,
              #{invocation_id => InvocationId, is_final => true}),
    gen_server:reply(From, {ok, Event}).

multi_round_agent_loop(TestPid, Round) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"multi-round-agent">>, #{}, [dummy_tool], #{}}),
            multi_round_agent_loop(TestPid, Round);
        {'$gen_call', From, {run_with_events, _History, InvocationId}}
          when Round =:= 0 ->
            TestPid ! {multi_round_waiting, self()},
            receive release_multi_rounds -> ok end,
            reply_multi_round_tool(From, InvocationId, Round + 1),
            multi_round_agent_loop(TestPid, Round + 1);
        {'$gen_call', From, {run_with_events, _History, InvocationId}}
          when Round < 4 ->
            reply_multi_round_tool(From, InvocationId, Round + 1),
            multi_round_agent_loop(TestPid, Round + 1);
        {'$gen_call', From, {run_with_events, _History, InvocationId}} ->
            Event = adk_event:new(
                      <<"multi-round-agent">>, <<"Multi-round complete">>,
                      #{invocation_id => InvocationId, is_final => true}),
            gen_server:reply(From, {ok, Event}),
            multi_round_agent_loop(TestPid, Round + 1);
        stop ->
            ok;
        _Other ->
            multi_round_agent_loop(TestPid, Round)
    end.

reply_multi_round_tool(From, InvocationId, Round) ->
    CallId = <<"gap-call-", (integer_to_binary(Round))/binary>>,
    Args = #{<<"arg">> => <<"round-", (integer_to_binary(Round))/binary>>},
    Calls = [{<<"dummy_tool">>, Args, undefined, CallId}],
    Event = adk_event:new(
              <<"multi-round-agent">>, {tool_calls, Calls},
              #{invocation_id => InvocationId}),
    gen_server:reply(From, {tool_calls, Event, Calls}).

blocking_agent_loop(TestPid) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"blocking-run-agent">>, #{}, [], #{}}),
            blocking_agent_loop(TestPid);
        {'$gen_call', From, {run_with_events, _History, _InvocationId}} ->
            TestPid ! {blocked_runner_worker, element(1, From)},
            blocking_agent_loop(TestPid);
        stop ->
            ok;
        _Other ->
            blocking_agent_loop(TestPid)
    end.

resumable_agent_loop(initial) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"resumable-run-agent">>, #{},
                     [adk_long_running_tool], #{}}),
            resumable_agent_loop(initial);
        {'$gen_call', From, {run_with_events, _History, InvocationId}} ->
            Calls = [{<<"request_human_approval">>,
                      #{<<"action_summary">> => <<"Publish release">>},
                      undefined, <<"approval-call">>}],
            Event = adk_event:new(
                      <<"resumable-run-agent">>, {tool_calls, Calls},
                      #{invocation_id => InvocationId}),
            gen_server:reply(From, {tool_calls, Event, Calls}),
            resumable_agent_loop(paused);
        stop ->
            ok;
        _Other ->
            resumable_agent_loop(initial)
    end;
resumable_agent_loop(paused) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"resumable-run-agent">>, #{},
                     [adk_long_running_tool], #{}}),
            resumable_agent_loop(paused);
        {'$gen_call', From, {run_with_events, _History, InvocationId}} ->
            Event = adk_event:new(
                      <<"resumable-run-agent">>, <<"Release published">>,
                      #{invocation_id => InvocationId, is_final => true}),
            gen_server:reply(From, {ok, Event}),
            resumable_agent_loop(done);
        stop ->
            ok;
        _Other ->
            resumable_agent_loop(paused)
    end;
resumable_agent_loop(done) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"resumable-run-agent">>, #{},
                     [adk_long_running_tool], #{}}),
            resumable_agent_loop(done);
        stop -> ok;
        _Other -> resumable_agent_loop(done)
    end.

collect_until_terminal(RunId, Seqs0) ->
    receive
        {adk_run_event, RunId, Seq, #adk_event{}} ->
            collect_until_terminal(RunId, [Seq | Seqs0]);
        {adk_run_terminal, RunId, _TerminalSeq, Outcome} ->
            {lists:reverse(Seqs0), Outcome}
    after 1000 ->
        ?assert(false)
    end.

assert_no_second_terminal(RunId) ->
    receive
        {adk_run_terminal, RunId, _Seq, _Outcome} ->
            ?assert(false)
    after 50 ->
        ok
    end.

assert_no_run_message(RunId) ->
    receive
        {adk_run_event, RunId, _Seq, _Event} -> ?assert(false);
        {adk_run_terminal, RunId, _Seq, _Outcome} -> ?assert(false);
        {adk_run_replay_gap, RunId, _Gap} -> ?assert(false)
    after 30 ->
        ok
    end.

await_subscriber_count(_RunId, _Expected, 0) ->
    {error, timeout};
await_subscriber_count(RunId, Expected, Attempts) ->
    case adk_run:status(RunId) of
        {ok, #{subscriber_count := Expected}} -> ok;
        _ ->
            receive after 5 -> ok end,
            await_subscriber_count(RunId, Expected, Attempts - 1)
    end.

await_not_found(_RunId, 0) ->
    {error, timeout};
await_not_found(RunId, Attempts) ->
    case adk_run:status(RunId) of
        {error, not_found} -> ok;
        _ ->
            receive after 5 -> ok end,
            await_not_found(RunId, Attempts - 1)
    end.

ensure_started(Name, StartFun) ->
    case whereis(Name) of
        undefined ->
            case StartFun() of
                {ok, Pid} ->
                    unlink(Pid),
                    ok;
                {error, {already_started, _Pid}} ->
                    ok
            end;
        _Pid ->
            ok
    end.

unique_session(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "-", Suffix/binary>>.
