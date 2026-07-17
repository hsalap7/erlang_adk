-module(adk_runner_durable_memory_test).
-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

-define(APP, <<"runner-durable-memory-app">>).
-define(USER, <<"runner-durable-memory-user">>).
-define(OTHER_USER, <<"runner-durable-memory-other-user">>).
-define(JOBS, adk_runner_durable_memory_test_job).
-define(USAGE, adk_runner_durable_memory_test_usage).

runner_durable_memory_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun durable_admission_precedes_success_and_reaches_v2_memory/0,
      fun capacity_failure_is_fail_closed/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    erlang_adk_session:init(),
    assert_runtime_names_free(),
    delete_test_tables(),
    cleanup_sessions(),
    ok.

cleanup(_) ->
    cleanup_sessions(),
    delete_test_tables(),
    ok.

durable_admission_precedes_success_and_reaches_v2_memory() ->
    with_runtime(
      runtime_options(#{}, 5),
      fun(_Outbox) ->
          {ok, Memory} = adk_memory_ets:start_link(#{}),
          Agent = spawn(fun durable_agent_loop/0),
          HandlerId = {?MODULE, admitted, make_ref()},
          TestPid = self(),
          Handler = fun(_Name, _Measurements, Metadata, _Config) ->
              JobId = maps:get(job_id, Metadata),
              TestPid ! {durable_memory_admitted, self(), JobId},
              receive
                  {continue_durable_memory_admission, JobId} -> ok
              after 5000 ->
                  erlang:error(durable_memory_admission_barrier_timeout)
              end
          end,
          ok = telemetry:attach(
                 HandlerId, [erlang_adk, memory, outbox, admitted],
                 Handler, #{}),
          SessionId = <<"successful-ingestion">>,
          AdapterId = <<"runner-memory-ets-v2">>,
          Runner = durable_runner(Agent, Memory, AdapterId),
          try
              {ok, Stream} = adk_runner:run_async(
                               Runner, ?USER, SessionId,
                               <<"remember the durable banana">>),
              {AdmissionWorker, JobId} = receive
                  {durable_memory_admitted, Worker, AdmittedJobId} ->
                      {Worker, AdmittedJobId}
              after 3000 ->
                  erlang:error(durable_memory_admission_not_observed)
              end,

              %% The telemetry handler executes inline between the durable
              %% Mnesia transaction and adk_done. Holding it here proves the
              %% admitted job is queryable before Runner can report success.
              {ok, Admitted} = adk_memory_outbox_sup:status(JobId),
              ?assertEqual({user, ?APP, ?USER}, maps:get(scope, Admitted)),
              ?assertEqual(SessionId, maps:get(session_id, Admitted)),
              ?assertEqual({adk_memory_ets, AdapterId},
                           maps:get(adapter, Admitted)),
              ?assertEqual(2, maps:get(event_count, Admitted)),
              ?assert(lists:member(maps:get(phase, Admitted),
                                   [pending, running, completed])),

              AdmissionWorker !
                  {continue_durable_memory_admission, JobId},
              Events = collect_success(Stream, []),
              ?assertEqual([<<"user">>, <<"DurableMemoryAgent">>],
                           [Event#adk_event.author || Event <- Events]),

              Completed = wait_for_phase(JobId, completed, 3000),
              ?assertEqual(2, maps:get(added,
                                      maps:get(result, Completed))),
              Hits = wait_for_hits(
                       Memory, {user, ?APP, ?USER}, <<"banana">>, 2, 3000),
              ?assertEqual(
                 [<<"DurableMemoryAgent">>, <<"user">>],
                 lists:sort(
                   [maps:get(author, maps:get(provenance, Hit))
                    || Hit <- Hits])),
              {ok, []} = adk_memory_ets:search(
                           Memory, {user, ?APP, ?OTHER_USER}, <<"banana">>,
                           #{filter => #{}, limit => 10})
          after
              _ = telemetry:detach(HandlerId),
              Agent ! stop,
              _ = adk_memory_ets:stop(Memory)
          end
      end).

capacity_failure_is_fail_closed() ->
    OutboxOptions = #{max_active_global => 1,
                      max_active_per_scope => 1},
    with_runtime(
      runtime_options(OutboxOptions, 60000),
      fun(Outbox) ->
          Blocker = #{scope => {user, <<"blocker-app">>, <<"blocker-user">>},
                      session_id => <<"blocker-session">>,
                      adapter => {adk_memory_ets, <<"unresolved-blocker">>},
                      events => [adk_event:new(
                                   <<"user">>, <<"hold outbox capacity">>)],
                      max_attempts => 5},
          {ok, _} = adk_memory_outbox:enqueue(Outbox, Blocker),
          {ok, #{active_jobs := 1}} = adk_memory_outbox:stats(Outbox),

          {ok, Memory} = adk_memory_ets:start_link(#{}),
          Agent = spawn(fun durable_agent_loop/0),
          SessionId = <<"rejected-ingestion">>,
          Runner = durable_runner(
                     Agent, Memory, <<"capacity-rejected-adapter">>),
          try
              Result = adk_runner:run(
                         Runner, ?USER, SessionId,
                         <<"this must not report durable success">>),
              ?assertMatch(
                 {error,
                  {durable_memory_ingestion_not_admitted,
                   {adk_failure,
                    #{component := runner,
                      operation := durable_memory_ingestion}}}},
                 Result),
              {ok, []} = adk_memory_ets:search(
                           Memory, {user, ?APP, ?USER}, <<"durable">>,
                           #{filter => #{}, limit => 10}),
              {ok, Session} = erlang_adk_session:get_session(
                                ?APP, ?USER, SessionId),
              ?assertEqual(2, length(maps:get(events, Session))),
              receive
                  {adk_done, _Stream} ->
                      erlang:error(durable_ingestion_reported_success)
              after 0 -> ok
              end
          after
              Agent ! stop,
              _ = adk_memory_ets:stop(Memory)
          end
      end).

durable_runner(Agent, Memory, AdapterId) ->
    adk_runner:new(
      Agent, ?APP, erlang_adk_session,
      #{memory_svc => {adk_memory_ets, Memory},
        memory_ingestion => #{mode => durable,
                              adapter_id => AdapterId,
                              max_attempts => 5},
        service_timeout => 1000,
        run_timeout => 5000}).

runtime_options(OutboxOverrides, PollInterval) ->
    Outbox = maps:merge(
               #{jobs_table => ?JOBS, usage_table => ?USAGE},
               OutboxOverrides),
    #{outbox => Outbox,
      processor => #{poll_interval_ms => PollInterval,
                     lease_ms => 750,
                     call_timeout_ms => 200,
                     max_concurrency => 2}}.

with_runtime(Options, Fun) ->
    assert_runtime_names_free(),
    {ok, Supervisor} = adk_memory_outbox_sup:start_link(Options),
    unlink(Supervisor),
    try
        {ok, Outbox} = adk_memory_outbox:init(maps:get(outbox, Options)),
        Fun(Outbox)
    after
        stop_runtime(Supervisor)
    end.

stop_runtime(Supervisor) ->
    Monitor = erlang:monitor(process, Supervisor),
    exit(Supervisor, shutdown),
    receive
        {'DOWN', Monitor, process, Supervisor, _Reason} -> ok
    after 3000 ->
        erlang:demonitor(Monitor, [flush]),
        erlang:error(memory_outbox_supervisor_did_not_stop)
    end,
    wait_for_runtime_names(1000).

assert_runtime_names_free() ->
    Occupied = [{Name, Pid}
                || Name <- runtime_names(),
                   Pid <- [whereis(Name)],
                   is_pid(Pid)],
    case Occupied of
        [] -> ok;
        _ -> erlang:error({memory_outbox_test_runtime_already_running,
                           Occupied})
    end.

wait_for_runtime_names(Remaining) when Remaining =< 0 ->
    assert_runtime_names_free();
wait_for_runtime_names(Remaining) ->
    case lists:any(fun(Name) -> is_pid(whereis(Name)) end, runtime_names()) of
        false -> ok;
        true ->
            receive after 10 -> ok end,
            wait_for_runtime_names(Remaining - 10)
    end.

runtime_names() ->
    [adk_memory_outbox_sup,
     adk_memory_outbox_registry,
     adk_memory_outbox_processor].

collect_success(Stream, Acc) ->
    receive
        {adk_event, Stream, Event} ->
            collect_success(Stream, [Event | Acc]);
        {adk_done, Stream} ->
            lists:reverse(Acc);
        {adk_error, Stream, Reason} ->
            erlang:error({unexpected_durable_memory_run_error, Reason})
    after 3000 ->
        erlang:error(durable_memory_run_did_not_finish)
    end.

wait_for_phase(JobId, Phase, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_phase_until(JobId, Phase, Deadline).

wait_for_phase_until(JobId, Phase, Deadline) ->
    case adk_memory_outbox_sup:status(JobId) of
        {ok, #{phase := Phase} = Status} -> Status;
        {ok, #{phase := failed} = Status} ->
            erlang:error({durable_memory_job_failed, Status});
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> erlang:error(durable_memory_job_completion_timeout);
                false ->
                    receive after 10 -> ok end,
                    wait_for_phase_until(JobId, Phase, Deadline)
            end
    end.

wait_for_hits(Memory, Scope, Query, Count, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_hits_until(Memory, Scope, Query, Count, Deadline).

wait_for_hits_until(Memory, Scope, Query, Count, Deadline) ->
    case adk_memory_ets:search(
           Memory, Scope, Query, #{filter => #{}, limit => 10}) of
        {ok, Hits} when length(Hits) =:= Count -> Hits;
        Other ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> erlang:error({durable_memory_hits_timeout, Other});
                false ->
                    receive after 10 -> ok end,
                    wait_for_hits_until(
                      Memory, Scope, Query, Count, Deadline)
            end
    end.

durable_agent_loop() ->
    receive
        {'$gen_call', From, {run_with_events, _HistoryEvents, InvocationId}} ->
            Event = adk_event:new(
                      <<"DurableMemoryAgent">>,
                      <<"the durable banana was persisted">>,
                      #{invocation_id => InvocationId, is_final => true}),
            gen_server:reply(From, {ok, Event}),
            durable_agent_loop();
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"DurableMemoryAgent">>, #{}, [], #{}}),
            durable_agent_loop();
        stop -> ok;
        _Other -> durable_agent_loop()
    end.

cleanup_sessions() ->
    [erlang_adk_session:delete_session(?APP, ?USER, SessionId)
     || SessionId <- [<<"successful-ingestion">>,
                      <<"rejected-ingestion">>]],
    ok.

delete_test_tables() ->
    lists:foreach(fun delete_table/1, [?JOBS, ?USAGE]),
    ok.

delete_table(Table) ->
    case mnesia:delete_table(Table) of
        {atomic, ok} -> ok;
        {aborted, {no_exists, Table}} -> ok;
        {aborted, {no_exists, Table, _}} -> ok;
        {aborted, {not_active, _}} -> ok;
        {aborted, {node_not_running, _}} -> ok;
        _Other -> ok
    end.
