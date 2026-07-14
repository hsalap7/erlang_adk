-module(adk_plugin_stateful_test).
-include_lib("eunit/include/eunit.hrl").

application_supervised_runtime_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Supervisor = whereis(adk_plugin_runtime_sup),
    ?assert(is_pid(Supervisor)),
    {ok, Instance} = adk_plugin_runtime_sup:start_instance(
                       instance_spec(self())),
    {ok, Status} = adk_plugin_instance:status(Instance),
    ?assertEqual(<<"counter">>, maps:get(id, Status)),
    ?assertEqual(pid, maps:get(identity, Status)),
    ?assertEqual(temporary, maps:get(restart_policy, Status)),
    ok = adk_plugin_runtime_sup:stop_instance(Instance),
    receive {stateful_terminated, shutdown} -> ok
    after 1000 -> ?assert(false)
    end.

serialized_concurrent_state_test() ->
    {ok, Supervisor} = adk_plugin_runtime_sup:start_link(),
    {ok, Instance} = adk_plugin_runtime_sup:start_instance(
                       Supervisor, instance_spec(self())),
    {ok, Pipeline} = stateful_pipeline(Instance),
    Parent = self(),
    Workers = [spawn(fun() ->
                  Parent ! {stateful_result, self(),
                            adk_plugin_pipeline:run(
                              Pipeline, before_run, #{}, normal)}
              end) || _ <- lists:seq(1, 20)],
    Results = collect_results(Workers, []),
    Counts = lists:sort(
               [Count || {amend, Count, _Trace} <- Results]),
    ?assertEqual(lists:seq(1, 20), Counts),
    {ok, Status} = adk_plugin_instance:status(Instance),
    ?assertEqual(false, maps:get(busy, Status)),
    ?assertEqual(0, maps:get(queued, Status)),
    ?assertEqual(20, maps:get(generation, Status)),
    ok = adk_plugin_runtime_sup:stop_instance(Supervisor, Instance),
    receive {stateful_terminated, shutdown} -> ok
    after 1000 -> ?assert(false)
    end,
    unlink(Supervisor),
    exit(Supervisor, shutdown).

initialization_is_time_and_heap_isolated_test() ->
    {ok, Supervisor} = adk_plugin_runtime_sup:start_link(),
    unlink(Supervisor),
    TimeoutSpec = (instance_spec(self()))#{
                    config => #{test_pid => self(), init_action => timeout,
                                init_delay_ms => 1000},
                    init_timeout_ms => 20},
    Started = erlang:monotonic_time(millisecond),
    ?assertMatch(
       {error, stateful_plugin_init_timeout},
       adk_plugin_runtime_sup:start_instance(Supervisor, TimeoutSpec)),
    ?assert(erlang:monotonic_time(millisecond) - Started < 500),
    InitWorker = receive
        {stateful_init_started, Pid} -> Pid
    after 1000 -> erlang:error(init_worker_not_observed)
    end,
    ?assertEqual(false, is_process_alive(InitWorker)),
    HeapSpec = (instance_spec(self()))#{
                 config => #{test_pid => self(), init_action => heap},
                 max_heap_words => 1000, init_timeout_ms => 1000},
    ?assertMatch(
       {error, stateful_plugin_init_worker_down},
       adk_plugin_runtime_sup:start_instance(Supervisor, HeapSpec)),
    exit(Supervisor, shutdown).

failed_pid_identity_is_not_silently_restarted_test() ->
    {ok, Supervisor} = adk_plugin_runtime_sup:start_link(),
    unlink(Supervisor),
    {ok, Instance} = adk_plugin_runtime_sup:start_instance(
                       Supervisor, instance_spec(self())),
    Monitor = erlang:monitor(process, Instance),
    exit(Instance, kill),
    receive
        {'DOWN', Monitor, process, Instance, killed} -> ok
    after 1000 -> erlang:error(plugin_instance_not_killed)
    end,
    wait_for_no_children(Supervisor, 100),
    ?assertEqual({error, not_found},
                 adk_plugin_runtime_sup:stop_instance(
                   Supervisor, Instance)),
    {ok, Replacement} = adk_plugin_runtime_sup:start_instance(
                          Supervisor, instance_spec(self())),
    ?assert(Replacement =/= Instance),
    ?assertEqual(
       {ok, {amend, 1}},
       adk_plugin_instance:invoke(
         Replacement, before_run, #{}, normal, 1000)),
    ok = adk_plugin_runtime_sup:stop_instance(Supervisor, Replacement),
    exit(Supervisor, shutdown).

owner_death_discards_late_state_test() ->
    {ok, Supervisor} = adk_plugin_runtime_sup:start_link(),
    {ok, Instance} = adk_plugin_runtime_sup:start_instance(
                       Supervisor, instance_spec(self())),
    Parent = self(),
    Owner = spawn(fun() ->
        Parent ! owner_ready,
        _ = adk_plugin_instance:invoke(
              Instance, before_run, #{}, delay, 5000)
    end),
    receive owner_ready -> ok after 1000 -> ?assert(false) end,
    CallbackWorker = receive
        {stateful_hook_started, Worker, delay} -> Worker
    after 1000 -> erlang:error(stateful_callback_not_started)
    end,
    WorkerMonitor = erlang:monitor(process, CallbackWorker),
    exit(Owner, kill),
    receive
        {'DOWN', WorkerMonitor, process, CallbackWorker, _} -> ok
    after 1000 -> erlang:error(stateful_callback_not_cancelled)
    end,
    ?assertEqual(
       {ok, {amend, 1}},
       adk_plugin_instance:invoke(
         Instance, before_run, #{}, normal, 1000)),
    ok = adk_plugin_runtime_sup:stop_instance(Supervisor, Instance),
    unlink(Supervisor),
    exit(Supervisor, shutdown).

completion_before_owner_down_never_commits_dead_owner_state_test() ->
    {ok, Supervisor} = adk_plugin_runtime_sup:start_link(),
    {ok, Instance} = adk_plugin_runtime_sup:start_instance(
                       Supervisor, instance_spec(self())),
    Parent = self(),
    Owner = spawn(fun() ->
        _ = adk_plugin_instance:invoke(
              Instance, before_run, #{}, commit_race, 5000),
        Parent ! owner_invoke_returned
    end),
    CallbackWorker = receive
        {stateful_hook_started, Worker, commit_race} -> Worker
    after 1000 -> erlang:error(stateful_callback_not_started)
    end,
    ok = sys:suspend(Instance),
    try
        WorkerMonitor = erlang:monitor(process, CallbackWorker),
        CallbackWorker ! complete_stateful_hook,
        receive
            {'DOWN', WorkerMonitor, process, CallbackWorker, normal} -> ok
        after 1000 -> erlang:error(stateful_callback_not_completed)
        end,
        OwnerMonitor = erlang:monitor(process, Owner),
        exit(Owner, kill),
        receive
            {'DOWN', OwnerMonitor, process, Owner, killed} -> ok
        after 1000 -> erlang:error(stateful_owner_not_killed)
        end
    after
        ok = sys:resume(Instance)
    end,
    %% The completion signal was queued before the owner DOWN signal. The
    %% instance must still discard count=1; the next live owner observes the
    %% initial snapshot and commits count=1 itself.
    ?assertEqual(
       {ok, {amend, 1}},
       adk_plugin_instance:invoke(
         Instance, before_run, #{}, normal, 1000)),
    receive owner_invoke_returned -> ?assert(false) after 0 -> ok end,
    ok = adk_plugin_runtime_sup:stop_instance(Supervisor, Instance),
    unlink(Supervisor),
    exit(Supervisor, shutdown).

stateful_instance_bounds_are_hard_test() ->
    {ok, Supervisor} = adk_plugin_runtime_sup:start_link(),
    unlink(Supervisor),
    Base = instance_spec(self()),
    Invalid = [Base#{id => binary:copy(<<"i">>, 257)},
               Base#{max_queue => 4097},
               Base#{max_heap_words => 10000001},
               Base#{max_state_bytes => 67108865},
               Base#{init_timeout_ms => 30001},
               Base#{config =>
                         #{blob => binary:copy(<<0>>, 1048577)}}],
    lists:foreach(
      fun(Spec) ->
          ?assertMatch(
             {error, invalid_plugin_instance_spec},
             adk_plugin_runtime_sup:start_instance(Supervisor, Spec))
      end, Invalid),
    {ok, Instance} = adk_plugin_runtime_sup:start_instance(
                       Supervisor, Base),
    ?assertEqual(
       {error, invalid_plugin_instance_invocation},
       adk_plugin_instance:invoke(
         Instance, before_run, #{}, normal, 120001)),
    ok = adk_plugin_runtime_sup:stop_instance(Supervisor, Instance),
    exit(Supervisor, shutdown).

instance_spec(TestPid) ->
    #{id => <<"counter">>,
      module => adk_stateful_counter_plugin,
      config => #{test_pid => TestPid},
      max_queue => 32,
      max_heap_words => 100000,
      max_state_bytes => 4096}.

stateful_pipeline(Instance) ->
    adk_plugin_pipeline:compile([
        #{id => <<"stateful-counter">>,
          module => adk_plugin_stateful_adapter,
          mode => intervene,
          failure_policy => closed,
          timeout_ms => 1500,
          max_heap_words => 100000,
          config => #{instance => Instance, timeout_ms => 1200}}
    ]).

collect_results([], Acc) -> Acc;
collect_results(Workers, Acc) ->
    receive
        {stateful_result, Worker, Result} ->
            collect_results(lists:delete(Worker, Workers),
                            [Result | Acc])
    after 5000 -> erlang:error(stateful_results_timeout)
    end.

wait_for_no_children(_Supervisor, 0) ->
    erlang:error(temporary_plugin_child_was_restarted);
wait_for_no_children(Supervisor, Attempts) ->
    case supervisor:which_children(Supervisor) of
        [] -> ok;
        _ ->
            timer:sleep(10),
            wait_for_no_children(Supervisor, Attempts - 1)
    end.
