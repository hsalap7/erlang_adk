-module(adk_admission_control_test).
-include_lib("eunit/include/eunit.hrl").

limits_and_reject_policy_test() ->
    with_server(
      #{global_limit => 2, default_agent_limit => 1,
        overflow => reject},
      fun(Server) ->
          {ok, PermitA} = adk_admission_control:acquire(
                            Server, <<"agent-a">>, #{}),
          ?assertEqual(
             {error, concurrency_limit_reached},
             adk_admission_control:acquire(Server, <<"agent-a">>, #{})),
          {ok, PermitB} = adk_admission_control:acquire(
                            Server, <<"agent-b">>, #{}),
          ?assertEqual(
             {error, concurrency_limit_reached},
             adk_admission_control:acquire(Server, <<"agent-c">>, #{})),
          ok = adk_admission_control:release(Server, PermitA),
          {ok, PermitC} = adk_admission_control:acquire(
                            Server, <<"agent-c">>, #{}),
          ok = adk_admission_control:release(Server, PermitB),
          ok = adk_admission_control:release(Server, PermitC),
          assert_empty(Server)
      end).

bounded_queue_and_fifo_release_test() ->
    with_server(
      #{global_limit => 1, default_agent_limit => 1,
        overflow => queue, max_queue => 2,
        default_queue_timeout => 2000},
      fun(Server) ->
          {ok, Seed} = adk_admission_control:acquire(
                         Server, <<"agent">>, #{}),
          {ok, Request1, {queued, _}} =
              adk_admission_control:submit(Server, <<"agent">>, #{}),
          {ok, Request2, {queued, _}} =
              adk_admission_control:submit(Server, <<"agent">>, #{}),
          ?assertEqual(
             {error, admission_queue_full},
             adk_admission_control:submit(Server, <<"agent">>, #{})),
          ok = adk_admission_control:release(Server, Seed),
          {ok, Permit1} = adk_admission_control:await(Request1, 1000),
          ?assertEqual({error, await_timeout},
                       adk_admission_control:await(Request2, 0)),
          ok = adk_admission_control:release(Server, Permit1),
          {ok, Permit2} = adk_admission_control:await(Request2, 1000),
          ok = adk_admission_control:release(Server, Permit2),
          assert_empty(Server)
      end).

oldest_eligible_avoids_cross_agent_head_blocking_test() ->
    with_server(
      #{global_limit => 2, default_agent_limit => 1,
        overflow => queue, max_queue => 4,
        default_queue_timeout => 2000},
      fun(Server) ->
          {ok, ActiveA} = adk_admission_control:acquire(
                            Server, <<"agent-a">>, #{}),
          {ok, ActiveC} = adk_admission_control:acquire(
                            Server, <<"agent-c">>, #{}),
          {ok, QueuedA, {queued, _}} =
              adk_admission_control:submit(Server, <<"agent-a">>, #{}),
          {ok, QueuedB, {queued, _}} =
              adk_admission_control:submit(Server, <<"agent-b">>, #{}),
          ok = adk_admission_control:release(Server, ActiveC),
          {ok, PermitB} = adk_admission_control:await(QueuedB, 1000),
          ?assertEqual({error, await_timeout},
                       adk_admission_control:await(QueuedA, 0)),
          ok = adk_admission_control:release(Server, ActiveA),
          {ok, PermitA} = adk_admission_control:await(QueuedA, 1000),
          ok = adk_admission_control:release(Server, PermitB),
          ok = adk_admission_control:release(Server, PermitA),
          assert_empty(Server)
      end).

active_owner_death_releases_exactly_once_test() ->
    with_server(
      #{global_limit => 1, default_agent_limit => 1,
        overflow => reject},
      fun(Server) ->
          Owner = spawn(fun owner_loop/0),
          {ok, Permit} = adk_admission_control:acquire(
                           Server, <<"agent">>, #{owner => Owner}),
          exit(Owner, kill),
          ok = wait_until(
                 fun() ->
                     {ok, Status} = adk_admission_control:status(Server),
                     maps:get(active, Status) =:= 0
                 end, 1000),
          ?assertEqual({error, not_found},
                       adk_admission_control:release(Server, Permit)),
          {ok, Replacement} = adk_admission_control:acquire(
                                Server, <<"agent">>, #{}),
          ok = adk_admission_control:release(Server, Replacement),
          assert_empty(Server)
      end).

queued_requester_death_removes_request_test() ->
    with_server(
      #{global_limit => 1, default_agent_limit => 1,
        overflow => queue, max_queue => 2,
        default_queue_timeout => 5000},
      fun(Server) ->
          {ok, Active} = adk_admission_control:acquire(
                           Server, <<"agent">>, #{}),
          Parent = self(),
          Requester = spawn(
                        fun() ->
                            Result = adk_admission_control:submit(
                                       Server, <<"agent">>, #{}),
                            Parent ! {submitted, self(), Result},
                            owner_loop()
                        end),
          receive
              {submitted, Requester, {ok, _RequestRef, {queued, _}}} -> ok
          after 1000 -> erlang:error(submit_timeout)
          end,
          exit(Requester, kill),
          ok = wait_until(
                 fun() ->
                     {ok, Status} = adk_admission_control:status(Server),
                     maps:get(queue_length, Status) =:= 0
                 end, 1000),
          ok = adk_admission_control:release(Server, Active),
          assert_empty(Server)
      end).

queued_owner_death_notifies_requester_test() ->
    with_server(
      #{global_limit => 1, default_agent_limit => 1,
        overflow => queue, max_queue => 2,
        default_queue_timeout => 5000},
      fun(Server) ->
          {ok, Active} = adk_admission_control:acquire(
                           Server, <<"agent">>, #{}),
          Owner = spawn(fun owner_loop/0),
          {ok, RequestRef, {queued, _}} =
              adk_admission_control:submit(
                Server, <<"agent">>, #{owner => Owner}),
          exit(Owner, kill),
          ?assertEqual({error, owner_down},
                       adk_admission_control:await(RequestRef, 1000)),
          ?assertEqual({error, not_found},
                       adk_admission_control:cancel(Server, RequestRef)),
          ok = adk_admission_control:release(Server, Active),
          assert_empty(Server)
      end).

absolute_deadline_expires_queue_entry_test() ->
    with_server(
      #{global_limit => 1, default_agent_limit => 1,
        overflow => queue, max_queue => 2},
      fun(Server) ->
          {ok, Active} = adk_admission_control:acquire(
                           Server, <<"agent">>, #{}),
          Deadline = erlang:monotonic_time(millisecond) + 30,
          {ok, RequestRef, {queued, Deadline}} =
              adk_admission_control:submit(
                Server, <<"agent">>, #{deadline => Deadline}),
          ?assertEqual({error, queue_deadline_exceeded},
                       adk_admission_control:await(RequestRef, 1000)),
          ?assertEqual({error, not_found},
                       adk_admission_control:cancel(Server, RequestRef)),
          {ok, Status} = adk_admission_control:status(Server),
          ?assertEqual(0, maps:get(queue_length, Status)),
          ok = adk_admission_control:release(Server, Active),
          assert_empty(Server)
      end).

cancellation_handles_queued_and_active_requests_test() ->
    with_server(
      #{global_limit => 1, default_agent_limit => 1,
        overflow => queue, max_queue => 2,
        default_queue_timeout => 5000},
      fun(Server) ->
          {ok, ActiveRequest, {granted, ActivePermit}} =
              adk_admission_control:submit(Server, <<"agent">>, #{}),
          {ok, QueuedRequest, {queued, _}} =
              adk_admission_control:submit(Server, <<"agent">>, #{}),
          ok = adk_admission_control:cancel(Server, QueuedRequest),
          ?assertEqual({error, cancelled},
                       adk_admission_control:await(QueuedRequest, 1000)),
          ok = adk_admission_control:cancel(Server, ActiveRequest),
          ?assertEqual({error, not_found},
                       adk_admission_control:release(Server, ActivePermit)),
          ?assertEqual({error, not_found},
                       adk_admission_control:cancel(Server, ActiveRequest)),
          assert_empty(Server)
      end).

malformed_options_do_not_crash_controller_test() ->
    with_server(
      #{global_limit => 1, default_agent_limit => 1},
      fun(Server) ->
          ?assertEqual(
             {error, invalid_admission_options},
             adk_admission_control:submit(
               Server, <<"agent">>, #{queue_timeout => broken})),
          ?assert(is_process_alive(Server)),
          {ok, Permit} = adk_admission_control:acquire(
                           Server, <<"agent">>, #{}),
          ok = adk_admission_control:release(Server, Permit)
      end).

bounded_concurrency_drains_without_leaks_test() ->
    with_server(
      #{global_limit => 3, default_agent_limit => 2,
        overflow => queue, max_queue => 20,
        default_queue_timeout => 5000},
      fun(Server) ->
          Parent = self(),
          Workers = [spawn_monitor(
                       fun() -> admission_worker(Server, Parent, Index) end)
                     || Index <- lists:seq(1, 10)],
          Active0 = receive_acquired(3, []),
          ok = wait_until(
                 fun() ->
                     {ok, Current} = adk_admission_control:status(Server),
                     maps:get(active, Current) =:= 3 andalso
                     maps:get(queue_length, Current) =:= 7
                 end, 2000),
          {ok, Full} = adk_admission_control:status(Server),
          ?assertEqual(3, maps:get(active, Full)),
          ?assertEqual(7, maps:get(queue_length, Full)),
          Active1 = drain_queued(Server, 7, Active0),
          lists:foreach(fun(Pid) -> Pid ! release end, Active1),
          await_worker_downs(Workers),
          assert_empty(Server)
      end).

status_and_telemetry_are_process_safe_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = {?MODULE, make_ref()},
    TestPid = self(),
    ok = telemetry:attach(
           HandlerId, [erlang_adk, admission, decision],
           fun(Name, Measurements, Metadata, Pid) ->
               Pid ! {admission_telemetry, Name, Measurements, Metadata}
           end, TestPid),
    try
        with_server(
          #{global_limit => 1, default_agent_limit => 1},
          fun(Server) ->
              {ok, Permit} = adk_admission_control:acquire(
                               Server, <<"safe-agent">>, #{}),
              {ok, Status} = adk_admission_control:status(Server),
              ?assertNot(contains_runtime_handle(Status)),
              receive
                  {admission_telemetry,
                   [erlang_adk, admission, decision],
                   Measurements, Metadata} ->
                      ?assertNot(contains_runtime_handle(Measurements)),
                      ?assertNot(contains_runtime_handle(Metadata))
              after 1000 -> erlang:error(telemetry_timeout)
              end,
              ok = adk_admission_control:release(Server, Permit),
              flush_admission_telemetry()
          end)
    after
        telemetry:detach(HandlerId)
    end.

with_server(Options, Fun) ->
    {ok, Server} = adk_admission_control:start_link(
                     Options#{name => undefined}),
    try Fun(Server)
    after
        case is_process_alive(Server) of
            true -> gen_server:stop(Server);
            false -> ok
        end
    end.

owner_loop() -> receive stop -> ok end.

assert_empty(Server) ->
    {ok, Status} = adk_admission_control:status(Server),
    ?assertEqual(0, maps:get(active, Status)),
    ?assertEqual(0, maps:get(queue_length, Status)).

wait_until(Predicate, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_until_deadline(Predicate, Deadline).

wait_until_deadline(Predicate, Deadline) ->
    case Predicate() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> erlang:error(wait_timeout);
                false -> receive after 5 -> ok end,
                         wait_until_deadline(Predicate, Deadline)
            end
    end.

admission_worker(Server, Parent, Index) ->
    Agent = case Index rem 2 of
        0 -> <<"agent-a">>;
        1 -> <<"agent-b">>
    end,
    {ok, Permit} = adk_admission_control:acquire(
                     Server, Agent, #{queue_timeout => 5000}),
    Parent ! {worker_acquired, self()},
    receive release -> ok end,
    ok = adk_admission_control:release(Server, Permit).

receive_acquired(0, Pids) -> Pids;
receive_acquired(Count, Pids) ->
    receive
        {worker_acquired, Pid} -> receive_acquired(Count - 1, [Pid | Pids])
    after 2000 -> erlang:error(acquire_timeout)
    end.

drain_queued(_Server, 0, Active) -> Active;
drain_queued(Server, Remaining, [Released | StillActive]) ->
    Released ! release,
    receive
        {worker_acquired, Replacement} ->
            {ok, Status} = adk_admission_control:status(Server),
            ?assert(maps:get(active, Status) =< 3),
            drain_queued(Server, Remaining - 1,
                         [Replacement | StillActive])
    after 2000 -> erlang:error(queue_drain_timeout)
    end.

await_worker_downs([]) -> ok;
await_worker_downs([{Pid, Monitor} | Rest]) ->
    receive
        {'DOWN', Monitor, process, Pid, normal} -> await_worker_downs(Rest);
        {'DOWN', Monitor, process, Pid, Reason} ->
            erlang:error({worker_failed, Reason})
    after 2000 -> erlang:error(worker_shutdown_timeout)
    end.

contains_runtime_handle(Value) when is_pid(Value); is_reference(Value);
                                    is_port(Value); is_function(Value) -> true;
contains_runtime_handle(Value) when is_map(Value) ->
    contains_runtime_handle(maps:keys(Value)) orelse
    contains_runtime_handle(maps:values(Value));
contains_runtime_handle(Value) when is_list(Value) ->
    lists:any(fun contains_runtime_handle/1, Value);
contains_runtime_handle(Value) when is_tuple(Value) ->
    contains_runtime_handle(tuple_to_list(Value));
contains_runtime_handle(_Value) -> false.

flush_admission_telemetry() ->
    receive
        {admission_telemetry, [erlang_adk, admission, decision],
         _Measurements, _Metadata} ->
            flush_admission_telemetry()
    after 0 -> ok
    end.
