-module(adk_ambient_test).

-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

-define(APP, <<"adk_ambient_test">>).

adk_ambient_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun application_runtime_options_are_wired_case/0,
      fun trigger_and_event_boundaries_fail_early_case/0,
      fun bounded_concurrency_and_queue_deadline_case/0,
      fun idempotency_returns_one_execution_case/0,
      fun retry_reaches_success_and_releases_admission_case/0,
      fun attempt_timeout_cancels_orphan_run_case/0,
      fun cancellation_cleans_active_and_queued_jobs_case/0,
      fun waiter_limit_and_caller_death_cleanup_case/0,
      fun per_event_sessions_are_isolated_case/0,
      fun explicit_session_policy_is_enforced_case/0,
      fun periodic_schedule_uses_bounded_runtime_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    ok.

cleanup(_Setup) ->
    ok.

application_runtime_options_are_wired_case() ->
    Old = application:get_env(erlang_adk, ambient_runtime),
    Options = #{max_triggers => 7, max_events => 99},
    try
        ok = application:set_env(erlang_adk, ambient_runtime, Options),
        {ok, {_Flags, Children}} = adk_ambient_sup:init([]),
        [AmbientChild] = [Child || Child <- Children,
                                  maps:get(id, Child) =:= adk_ambient],
        ?assertEqual(
           {adk_ambient, start_link, [Options]},
           maps:get(start, AmbientChild))
    after
        case Old of
            {ok, Value} ->
                application:set_env(erlang_adk, ambient_runtime, Value);
            undefined ->
                application:unset_env(erlang_adk, ambient_runtime)
        end
    end.

trigger_and_event_boundaries_fail_early_case() ->
    Name = unique(<<"ambient-boundary">>),
    Agent = start_agent(#{observer => self(), delay => 0}),
    Runner = runner(Agent, 2000),
    ?assertEqual(true, adk_runner:is_runner(Runner)),
    ?assertEqual(false, adk_runner:is_runner(#{runner => fake})),
    ?assertEqual(
       {error, invalid_trigger_options},
       adk_ambient:register_trigger(
         unique(<<"invalid-runner">>), not_a_runner,
         trigger_options(#{}))),
    ok = adk_ambient:register_trigger(
           Name, Runner, trigger_options(#{})),
    try
        ?assertEqual(
           {error, invalid_ambient_event},
           adk_ambient:submit(
             Name,
             #{payload => fun() -> unsafe end,
               idempotency_key => <<"non-json">>})),
        ?assertEqual(
           {error, invalid_ambient_event},
           adk_ambient:submit(
             Name,
             #{payload => #{answer => 42},
               idempotency_key => <<"non-content-map">>})),
        ?assertEqual(
           {error, invalid_ambient_event},
           adk_ambient:submit(
             Name,
             #{payload => #{api_key => <<"never-store-this">>},
               idempotency_key => <<"secret">>})),
        {ok, Ref} = adk_ambient:submit(
                      Name,
                      #{payload => <<"ambient input">>,
                        metadata => #{source => <<"test">>},
                        idempotency_key => <<"canonical">>}),
        {ok, Status} = adk_ambient:status(Ref),
        ?assertEqual(#{<<"source">> => <<"test">>},
                     maps:get(metadata, Status)),
        ?assertMatch({completed, _}, adk_ambient:await(Ref, 1000)),
        receive
            {ambient_agent_started, Agent, _Context} -> ok
        after 1000 -> ?assert(false)
        end
    after
        stop_trigger(Name),
        Agent ! stop
    end.

bounded_concurrency_and_queue_deadline_case() ->
    Name = unique(<<"ambient-concurrency">>),
    Agent = start_agent(#{observer => self(), delay => 120}),
    Runner = runner(Agent, 2000),
    ok = adk_ambient:register_trigger(
           Name, Runner,
           trigger_options(#{max_concurrency => 2,
                             max_queue => 2,
                             event_timeout => 1000})),
    try
        {ok, Ref1} = adk_ambient:submit(Name, event(<<"c-1">>)),
        {ok, Ref2} = adk_ambient:submit(Name, event(<<"c-2">>)),
        {ok, Ref3} = adk_ambient:submit(
                       Name, (event(<<"c-3">>))#{timeout_ms => 40}),
        {ok, Ref4} = adk_ambient:submit(Name, event(<<"c-4">>)),
        ?assertEqual({error, ambient_queue_full},
                     adk_ambient:submit(Name, event(<<"c-5">>))),

        Started = receive_started(2, []),
        ?assertEqual(2, length(Started)),
        receive
            {ambient_agent_started, Agent, _Context} ->
                ?assert(false)
        after 20 -> ok
        end,

        ?assertEqual({timed_out, deadline_exceeded},
                     adk_ambient:await(Ref3, 1000)),
        ?assertMatch({completed, _}, adk_ambient:await(Ref1, 2000)),
        ?assertMatch({completed, _}, adk_ambient:await(Ref2, 2000)),
        ?assertMatch({completed, _}, adk_ambient:await(Ref4, 2000)),
        {ok, RouteStatus} = adk_ambient:trigger_status(Name),
        ?assertEqual(0, maps:get(active, RouteStatus)),
        ?assertEqual(0, maps:get(queued, RouteStatus))
    after
        stop_trigger(Name),
        Agent ! stop
    end.

idempotency_returns_one_execution_case() ->
    Name = unique(<<"ambient-dedupe">>),
    Agent = start_agent(#{observer => self(), delay => 30}),
    ok = adk_ambient:register_trigger(
           Name, runner(Agent, 2000), trigger_options(#{})),
    try
        Event = event(<<"same-delivery">>),
        {ok, Ref} = adk_ambient:submit(Name, Event),
        ?assertEqual({ok, Ref, duplicate}, adk_ambient:submit(Name, Event)),
        ?assertMatch({completed, _}, adk_ambient:await(Ref, 1000)),
        receive
            {ambient_agent_started, Agent, _Context} -> ok
        after 1000 -> ?assert(false)
        end,
        receive
            {ambient_agent_started, Agent, _Context2} -> ?assert(false)
        after 50 -> ok
        end,
        {ok, Status} = adk_ambient:status(Ref),
        ?assertEqual(1, maps:get(attempts, Status))
    after
        stop_trigger(Name),
        Agent ! stop
    end.

retry_reaches_success_and_releases_admission_case() ->
    Name = unique(<<"ambient-retry">>),
    Agent = start_agent(#{observer => self(), delay => 5, failures => 2}),
    Options = trigger_options(
                #{retry => #{max_attempts => 3,
                             initial_delay => 1,
                             max_delay => 1,
                             backoff_factor => 1.0,
                             attempt_timeout => 500,
                             max_heap_words => 100000,
                             jitter => none}}),
    ok = adk_ambient:register_trigger(Name, runner(Agent, 2000), Options),
    try
        {ok, Ref} = adk_ambient:submit(Name, event(<<"retry-key">>)),
        ?assertMatch({completed, _}, adk_ambient:await(Ref, 2000)),
        {ok, Status} = adk_ambient:status(Ref),
        ?assertEqual(3, maps:get(attempts, Status)),
        ?assertEqual(3, count_started(Agent, 0)),
        ok = wait_until(
               fun() ->
                   {ok, Admission} = adk_admission_control:status(),
                   maps:get(active, Admission) =:= 0
               end, 1000)
    after
        stop_trigger(Name),
        Agent ! stop
    end.

attempt_timeout_cancels_orphan_run_case() ->
    Name = unique(<<"ambient-attempt-timeout">>),
    Agent = start_agent(#{observer => self(), delay => 5000}),
    Options = trigger_options(
                #{event_timeout => 1000,
                  retry => #{max_attempts => 2,
                             initial_delay => 1,
                             max_delay => 1,
                             backoff_factor => 1.0,
                             attempt_timeout => 30,
                             max_heap_words => 100000,
                             jitter => none}}),
    ok = adk_ambient:register_trigger(Name, runner(Agent, 10000), Options),
    try
        {ok, Ref} = adk_ambient:submit(Name, event(<<"timeout-key">>)),
        ?assertEqual({failed, attempt_timeout},
                     adk_ambient:await(Ref, 2000)),
        {ok, #{attempts := 2, run_id := LastRunId}} =
            adk_ambient:status(Ref),
        ?assertMatch({cancelled, _}, adk_run:await(LastRunId, 1000)),
        {ok, Admission} = adk_admission_control:status(),
        ?assertEqual(0, maps:get(active, Admission))
    after
        stop_trigger(Name),
        Agent ! stop
    end.

cancellation_cleans_active_and_queued_jobs_case() ->
    Name = unique(<<"ambient-cancel">>),
    Agent = start_agent(#{observer => self(), delay => 5000}),
    Options = trigger_options(#{max_concurrency => 1, max_queue => 1}),
    ok = adk_ambient:register_trigger(Name, runner(Agent, 10000), Options),
    try
        {ok, ActiveRef} = adk_ambient:submit(Name, event(<<"active">>)),
        receive
            {ambient_agent_started, Agent, _Context} -> ok
        after 1000 -> ?assert(false)
        end,
        {ok, QueuedRef} = adk_ambient:submit(Name, event(<<"queued">>)),
        ok = adk_ambient:cancel(QueuedRef, test_queue_cancel),
        ?assertEqual({cancelled, test_queue_cancel},
                     adk_ambient:await(QueuedRef, 1000)),
        ok = adk_ambient:cancel(ActiveRef, test_active_cancel),
        ?assertEqual({cancelled, test_active_cancel},
                     adk_ambient:await(ActiveRef, 2000)),
        {ok, #{run_id := CancelledRunId}} = adk_ambient:status(ActiveRef),
        ?assertMatch(
           {cancelled,
            {adk_failure,
             #{component := invocation, operation := cancel,
               reason := test_active_cancel}}},
           adk_run:await(CancelledRunId, 1000)),
        ok = wait_until(
               fun() ->
                   {ok, Status} = adk_ambient:trigger_status(Name),
                   maps:get(active, Status) =:= 0 andalso
                       maps:get(queued, Status) =:= 0
               end, 1000),
        {ok, Admission} = adk_admission_control:status(),
        ?assertEqual(0, maps:get(active, Admission))
    after
        stop_trigger(Name),
        Agent ! stop
    end.

waiter_limit_and_caller_death_cleanup_case() ->
    Name = unique(<<"ambient-waiters">>),
    Agent = start_agent(#{observer => self(), delay => 5000}),
    Options = trigger_options(#{max_waiters => 1}),
    ok = adk_ambient:register_trigger(Name, runner(Agent, 10000), Options),
    try
        {ok, Ref} = adk_ambient:submit(Name, event(<<"waiter-key">>)),
        receive
            {ambient_agent_started, Agent, _Context} -> ok
        after 1000 -> ?assert(false)
        end,
        Parent = self(),
        Waiter = spawn(fun() ->
            Parent ! {waiter_started, self()},
            _ = adk_ambient:await(Ref, infinity)
        end),
        receive {waiter_started, Waiter} -> ok after 1000 -> ?assert(false) end,
        ok = wait_until(
               fun() ->
                   case adk_ambient:status(Ref) of
                       {ok, #{waiter_count := 1}} -> true;
                       _ -> false
                   end
               end, 1000),
        ?assertEqual({error, waiter_limit_reached},
                     adk_ambient:await(Ref, 0)),
        exit(Waiter, kill),
        ok = wait_until(
               fun() ->
                   case adk_ambient:status(Ref) of
                       {ok, #{waiter_count := 0}} -> true;
                       _ -> false
                   end
               end, 1000),
        ok = adk_ambient:cancel(Ref, waiter_test_done),
        ?assertEqual({cancelled, waiter_test_done},
                     adk_ambient:await(Ref, 2000))
    after
        stop_trigger(Name),
        Agent ! stop
    end.

per_event_sessions_are_isolated_case() ->
    Name = unique(<<"ambient-sessions">>),
    User = unique(<<"ambient-user">>),
    Agent = start_agent(#{observer => self(), delay => 0}),
    Options = trigger_options(
                #{session_policy => #{mode => per_event,
                                      user_id => User,
                                      prefix => <<"isolated-">>}}),
    ok = adk_ambient:register_trigger(Name, runner(Agent, 2000), Options),
    try
        {ok, Ref1} = adk_ambient:submit(Name, event(<<"session-a">>)),
        {ok, Ref2} = adk_ambient:submit(Name, event(<<"session-b">>)),
        ?assertMatch({completed, _}, adk_ambient:await(Ref1, 1000)),
        ?assertMatch({completed, _}, adk_ambient:await(Ref2, 1000)),
        {ok, Status1} = adk_ambient:status(Ref1),
        {ok, Status2} = adk_ambient:status(Ref2),
        Session1 = maps:get(session_id, Status1),
        Session2 = maps:get(session_id, Status2),
        ?assertNotEqual(Session1, Session2),
        ?assertMatch({ok, _}, erlang_adk_session:get_session(
                                ?APP, User, Session1)),
        ?assertMatch({ok, _}, erlang_adk_session:get_session(
                                ?APP, User, Session2)),
        ok = erlang_adk_session:delete_session(?APP, User, Session1),
        ok = erlang_adk_session:delete_session(?APP, User, Session2)
    after
        stop_trigger(Name),
        Agent ! stop
    end.

explicit_session_policy_is_enforced_case() ->
    Name = unique(<<"ambient-explicit">>),
    Agent = start_agent(#{observer => self(), delay => 0}),
    Options = trigger_options(
                #{session_policy => #{mode => explicit}}),
    ok = adk_ambient:register_trigger(Name, runner(Agent, 2000), Options),
    User = unique(<<"explicit-user">>),
    Session = unique(<<"explicit-session">>),
    try
        ?assertEqual({error, invalid_ambient_event},
                     adk_ambient:submit(Name, event(<<"missing-session">>))),
        Event = (event(<<"explicit-key">>))#{
                  session => #{user_id => User, session_id => Session}},
        {ok, Ref} = adk_ambient:submit(Name, Event),
        ?assertMatch({completed, _}, adk_ambient:await(Ref, 1000)),
        {ok, Status} = adk_ambient:status(Ref),
        ?assertEqual(User, maps:get(user_id, Status)),
        ?assertEqual(Session, maps:get(session_id, Status)),
        ok = erlang_adk_session:delete_session(?APP, User, Session)
    after
        stop_trigger(Name),
        Agent ! stop
    end.

periodic_schedule_uses_bounded_runtime_case() ->
    Name = unique(<<"ambient-schedule">>),
    ScheduleId = unique(<<"periodic">>),
    Agent = start_agent(#{observer => self(), delay => 0}),
    ok = adk_ambient:register_trigger(
           Name, runner(Agent, 2000),
           trigger_options(#{max_concurrency => 1, max_queue => 2})),
    Template = #{payload => <<"scheduled message">>},
    try
        {ok, Source} = adk_trigger_schedule:start(
                         Name, ScheduleId, 30, Template,
                         #{initial_delay_ms => 0}),
        try
            ok = wait_until(
                   fun() ->
                       case adk_trigger_schedule:status(Source) of
                           {ok, #{submitted := Count}} when Count >= 2 -> true;
                           _ -> false
                       end
                   end, 1000),
            {ok, SourceStatus} = adk_trigger_schedule:status(Source),
            ?assert(maps:get(submitted, SourceStatus) >= 2),
            ?assert(maps:get(rejected, SourceStatus) =< 1),
            ?assert(length(adk_trigger_sup:sources()) >= 1)
        after
            ok = adk_trigger_schedule:stop(Source)
        end,
        ok = wait_until(
               fun() ->
                   {ok, Status} = adk_ambient:trigger_status(Name),
                   maps:get(active, Status) =:= 0 andalso
                       maps:get(queued, Status) =:= 0
               end, 1000)
    after
        stop_trigger(Name),
        Agent ! stop
    end.

trigger_options(Overrides) ->
    Defaults = #{max_concurrency => 2,
                 max_queue => 4,
                 event_timeout => 2000,
                 retention_ms => 5000,
                 max_retained => 32,
                 max_waiters => 8,
                 session_policy => #{mode => per_event,
                                     user_id => <<"ambient-test-user">>,
                                     prefix => <<"test-">>},
                 retry => #{max_attempts => 1,
                            initial_delay => 0,
                            max_delay => 0,
                            backoff_factor => 1.0,
                            attempt_timeout => 2000,
                            max_heap_words => 100000,
                            jitter => none}},
    maps:merge(Defaults, Overrides).

event(Key) ->
    #{payload => <<"background work">>, idempotency_key => Key}.

runner(Agent, Timeout) ->
    adk_runner:new(Agent, ?APP, erlang_adk_session,
                   #{run_timeout => Timeout}).

start_agent(Options) ->
    spawn(fun() -> agent_loop(Options#{failures =>
                                          maps:get(failures, Options, 0)}) end).

agent_loop(State) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From, {ok, <<"ambient-test-agent">>,
                                    #{}, [], #{}}),
            agent_loop(State);
        {'$gen_call', From,
         {run_with_events, _History, InvocationId}} ->
            Observer = maps:get(observer, State),
            Context = #{},
            Observer ! {ambient_agent_started, self(), Context},
            Delay = maps:get(delay, State, 0),
            case maps:get(failures, State) of
                Failures when Failures > 0 ->
                    erlang:send_after(Delay, self(),
                                      {reply_failure, From}),
                    agent_loop(State#{failures => Failures - 1});
                0 ->
                    erlang:send_after(Delay, self(),
                                      {reply_success, From, InvocationId,
                                       Context}),
                    agent_loop(State)
            end;
        {reply_failure, From} ->
            gen_server:reply(From, {error, transient_test_failure}),
            agent_loop(State);
        {reply_success, From, InvocationId, Context} ->
            Output = maps:get(session_id, Context, <<"ambient-result">>),
            Final = adk_event:new(
                      <<"ambient-test-agent">>, Output,
                      #{invocation_id => InvocationId, is_final => true}),
            gen_server:reply(From, {ok, Final}),
            agent_loop(State);
        stop ->
            ok;
        _Other ->
            agent_loop(State)
    end.

receive_started(0, Acc) -> Acc;
receive_started(Count, Acc) ->
    receive
        {ambient_agent_started, Agent, Context} ->
            receive_started(Count - 1, [{Agent, Context} | Acc])
    after 1000 ->
        erlang:error({started_timeout, Count})
    end.

count_started(Agent, Count) ->
    receive
        {ambient_agent_started, Agent, _Context} ->
            count_started(Agent, Count + 1)
    after 20 -> Count
    end.

stop_trigger(Name) ->
    _ = wait_until(
          fun() ->
              case adk_ambient:trigger_status(Name) of
                  {ok, #{active := 0, queued := 0}} -> true;
                  _ -> false
              end
          end, 2000),
    case adk_ambient:unregister_trigger(Name) of
        ok -> ok;
        {error, not_found} -> ok;
        {error, trigger_busy} ->
            erlang:error({trigger_still_busy, Name})
    end.

wait_until(Fun, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_until_loop(Fun, Deadline).

wait_until_loop(Fun, Deadline) ->
    case Fun() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> {error, timeout};
                false ->
                    receive after 5 -> ok end,
                    wait_until_loop(Fun, Deadline)
            end
    end.

unique(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "-", Suffix/binary>>.
