-module(adk_memory_outbox_supervision_test).

-include_lib("eunit/include/eunit.hrl").

-define(JOBS, adk_memory_outbox_supervision_test_job).
-define(USAGE, adk_memory_outbox_supervision_test_usage).
-define(SCHEDULE, adk_memory_outbox_supervision_test_schedule).

memory_outbox_supervision_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun initial_registry_rehydration_gates_claims/0,
      fun registry_child_restart_gates_claims/0,
      fun partial_registry_rehydration_gates_each_identity/0,
      fun safe_call_failures_do_not_echo_private_inputs/0,
      fun majority_mode_requires_multi_node_readiness/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    delete_test_tables(),
    ok.

cleanup(_) ->
    delete_test_tables(),
    ok.

initial_registry_rehydration_gates_claims() ->
    {ok, Store} = adk_memory_outbox:init(store_config()),
    {ok, Supervisor} = adk_memory_outbox_sup:start_link(
                         supervisor_options()),
    unlink(Supervisor),
    try
        ?assertEqual(
           {error, memory_outbox_registry_not_rehydrated},
           adk_memory_outbox_sup:health(Supervisor)),
        {ok, Queued} = adk_memory_outbox:enqueue(
                         Store, request(<<"initial-race">>)),
        JobId = maps:get(job_id, Queued),
        wait_without_claim(JobId, Store, 150),
        {ok, Adapter} = adk_memory_outbox_test_adapter:start_link(
                          #{test_pid => self()}),
        try
            ok = adk_memory_outbox_sup:register_adapter(
                   Supervisor, identity(),
                   {adk_memory_outbox_test_adapter, Adapter}),
            {ok, #{registry := Registry}} =
                adk_memory_outbox_sup:runtime(Supervisor),
            ?assertEqual(false, contains_exact(
                                  Adapter, sys:get_status(Registry))),
            Completed = wait_for_phase(
                          Supervisor, JobId, completed, 3000),
            ?assertEqual(1, maps:get(attempt, Completed)),
            ?assertEqual(
               #{calls => 1, unique_events => 1},
               adk_memory_outbox_test_adapter:stats(Adapter))
        after
            stop_adapter(Adapter)
        end
    after
        stop_supervisor(Supervisor)
    end.

registry_child_restart_gates_claims() ->
    {ok, Store} = adk_memory_outbox:init(store_config()),
    {ok, Supervisor} = adk_memory_outbox_sup:start_link(
                         supervisor_options()),
    unlink(Supervisor),
    {ok, Adapter} = adk_memory_outbox_test_adapter:start_link(
                      #{test_pid => self()}),
    try
        ok = adk_memory_outbox_sup:register_adapter(
               Supervisor, identity(),
               {adk_memory_outbox_test_adapter, Adapter}),
        {ok, #{registry := Registry0, processor := Processor0}} =
            adk_memory_outbox_sup:runtime(Supervisor),
        exit(Registry0, kill),
        {Registry1, Processor1} = await_restarted_children(
                                   Supervisor, Registry0, Processor0, 3000),
        ?assert(Registry1 =/= Registry0),
        ?assert(Processor1 =/= Processor0),
        ?assertEqual(
           {error, memory_outbox_registry_not_rehydrated},
           adk_memory_outbox_sup:health(Supervisor)),

        {ok, Queued} = adk_memory_outbox:enqueue(
                         Store, request(<<"registry-restart">>)),
        JobId = maps:get(job_id, Queued),
        wait_without_claim(JobId, Store, 150),
        ok = adk_memory_outbox_sup:register_adapter(
               Supervisor, identity(),
               {adk_memory_outbox_test_adapter, Adapter}),
        Completed = wait_for_phase(
                      Supervisor, JobId, completed, 3000),
        ?assertEqual(1, maps:get(attempt, Completed)),
        ?assertEqual(
           #{calls => 1, unique_events => 1},
           adk_memory_outbox_test_adapter:stats(Adapter))
    after
        stop_adapter(Adapter),
        stop_supervisor(Supervisor)
    end.

partial_registry_rehydration_gates_each_identity() ->
    {ok, Store} = adk_memory_outbox:init(store_config()),
    {ok, Supervisor} = adk_memory_outbox_sup:start_link(
                         supervisor_options()),
    unlink(Supervisor),
    {ok, Adapter} = adk_memory_outbox_test_adapter:start_link(
                      #{test_pid => self()}),
    IdentityA = identity(<<"adapter-a-v2">>),
    IdentityB = identity(<<"adapter-b-v2">>),
    try
        ok = adk_memory_outbox_sup:register_adapter(
               Supervisor, IdentityA,
               {adk_memory_outbox_test_adapter, Adapter}),
        ok = adk_memory_outbox_sup:register_adapter(
               Supervisor, IdentityB,
               {adk_memory_outbox_test_adapter, Adapter}),
        {ok, #{registry := Registry0, processor := Processor0}} =
            adk_memory_outbox_sup:runtime(Supervisor),
        exit(Registry0, kill),
        {_Registry1, _Processor1} = await_restarted_children(
                                      Supervisor, Registry0,
                                      Processor0, 3000),

        JobsB = [begin
                     Suffix = integer_to_binary(Index),
                     {ok, QueuedB} = adk_memory_outbox:enqueue(
                                       Store,
                                       request(
                                         <<"partial-b-", Suffix/binary>>,
                                         IdentityB)),
                     %% Make every unavailable identity deterministically sort
                     %% before A in the ordered due index.
                     receive after 2 -> ok end,
                     maps:get(job_id, QueuedB)
                 end || Index <- lists:seq(1, 8)],
        {ok, QueuedA} = adk_memory_outbox:enqueue(
                          Store, request(<<"partial-a">>, IdentityA)),
        JobA = maps:get(job_id, QueuedA),
        wait_without_claim(hd(JobsB), Store, 100),
        assert_pending_without_attempt(JobsB, Store),
        wait_without_claim(JobA, Store, 100),

        ok = adk_memory_outbox_sup:register_adapter(
               Supervisor, IdentityA,
               {adk_memory_outbox_test_adapter, Adapter}),
        CompletedA = wait_for_phase(Supervisor, JobA, completed, 3000),
        ?assertEqual(1, maps:get(attempt, CompletedA)),
        wait_without_claim(hd(JobsB), Store, 100),
        assert_pending_without_attempt(JobsB, Store),
        ?assertEqual(
           #{calls => 1, unique_events => 1},
           adk_memory_outbox_test_adapter:stats(Adapter)),

        ok = adk_memory_outbox_sup:register_adapter(
               Supervisor, IdentityB,
               {adk_memory_outbox_test_adapter, Adapter}),
        CompletedB = [wait_for_phase(Supervisor, JobB, completed, 3000)
                      || JobB <- JobsB],
        ?assert(lists:all(
                  fun(Status) -> maps:get(attempt, Status) =:= 1 end,
                  CompletedB)),
        ?assertEqual(
           #{calls => 9, unique_events => 9},
           adk_memory_outbox_test_adapter:stats(Adapter))
    after
        stop_adapter(Adapter),
        stop_supervisor(Supervisor)
    end.

safe_call_failures_do_not_echo_private_inputs() ->
    Secret = <<"private-event-content-never-echo">>,
    Request = #{events => [#{content => Secret}]},
    CrashingProcessor = spawn(fun crashing_call_server/0),
    ProcessorReply = adk_memory_outbox_processor:submit(
                       CrashingProcessor, Request),
    ?assertEqual(
       {error, memory_outbox_processor_unavailable}, ProcessorReply),
    ?assertEqual(false, contains_exact(Secret, ProcessorReply)),

    OpaqueHandle = make_ref(),
    CrashingRegistry = spawn(fun crashing_call_server/0),
    RegistryReply = adk_memory_outbox_registry:register(
                      CrashingRegistry, identity(),
                      {adk_memory_outbox_test_adapter, OpaqueHandle}),
    ?assertEqual(
       {error, memory_outbox_resolver_unavailable}, RegistryReply),
    ?assertEqual(false, contains_exact(OpaqueHandle, RegistryReply)).

majority_mode_requires_multi_node_readiness() ->
    Options0 = supervisor_options(),
    StoreConfig = (maps:get(outbox, Options0))#{
                    cluster_mode => mnesia_majority},
    {ok, Supervisor} = adk_memory_outbox_sup:start_link(
                         Options0#{outbox => StoreConfig}),
    unlink(Supervisor),
    {ok, Adapter} = adk_memory_outbox_test_adapter:start_link(
                      #{test_pid => self()}),
    try
        ok = adk_memory_outbox_sup:register_adapter(
               Supervisor, identity(),
               {adk_memory_outbox_test_adapter, Adapter}),
        ?assertMatch(
           {error,
            {memory_outbox_store_unhealthy,
             {memory_outbox_cluster_not_ready,
              #{mode := mnesia_majority,
                shared_nodes := [_],
                required_shared_nodes := 2}}}},
           adk_memory_outbox_sup:health(Supervisor)),
        ?assertMatch(
           {error,
            {memory_outbox_cluster_not_ready,
             #{mode := mnesia_majority,
               required_shared_nodes := 2}}},
           adk_memory_outbox:validate_cluster_readiness(
             mnesia_majority, [node()])),
        ?assertMatch(
           {ok, #{mode := mnesia_majority,
                  multi_node_ready := true,
                  shared_nodes := [_, _]}},
           adk_memory_outbox:validate_cluster_readiness(
             mnesia_majority, [node(), 'outbox-peer@localhost'])),
        ?assertMatch(
           {ok, #{mode := single_node,
                  multi_node_ready := false}},
           adk_memory_outbox:validate_cluster_readiness(
             single_node, [node()]))
    after
        stop_adapter(Adapter),
        stop_supervisor(Supervisor)
    end.

supervisor_options() ->
    #{name => undefined,
      outbox => store_config(),
      processor => #{poll_interval_ms => 5,
                     lease_ms => 500,
                     call_timeout_ms => 100,
                     max_concurrency => 1}}.

store_config() ->
    #{jobs_table => ?JOBS,
      usage_table => ?USAGE,
      schedule_table => ?SCHEDULE,
      max_claim_scan => 8}.

identity() ->
    {adk_memory_outbox_test_adapter, <<"rehydrated-v2">>}.

identity(AdapterId) ->
    {adk_memory_outbox_test_adapter, AdapterId}.

request(SessionId) ->
    request(SessionId, identity()).

request(SessionId, AdapterIdentity) ->
    #{scope => {user, <<"outbox-rehydration-app">>,
                       <<"outbox-rehydration-user">>},
      session_id => SessionId,
      adapter => AdapterIdentity,
      events => [adk_event:new(
                   <<"user">>, <<"registry rehydration event">>)],
      max_attempts => 3}.

wait_without_claim(JobId, Store, Milliseconds) ->
    Deadline = erlang:monotonic_time(millisecond) + Milliseconds,
    wait_without_claim_until(JobId, Store, Deadline).

wait_without_claim_until(JobId, Store, Deadline) ->
    {ok, Status} = adk_memory_outbox:status(Store, JobId),
    ?assertEqual(pending, maps:get(phase, Status)),
    ?assertEqual(0, maps:get(attempt, Status)),
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> ok;
        false ->
            receive after 10 -> ok end,
            wait_without_claim_until(JobId, Store, Deadline)
    end.

assert_pending_without_attempt(JobIds, Store) ->
    lists:foreach(
      fun(JobId) ->
              {ok, Status} = adk_memory_outbox:status(Store, JobId),
              ?assertEqual(pending, maps:get(phase, Status)),
              ?assertEqual(0, maps:get(attempt, Status))
      end, JobIds).

crashing_call_server() ->
    receive
        {'$gen_call', _From, Request} ->
            exit({intentional_test_crash, Request})
    end.

await_restarted_children(Supervisor, Registry0, Processor0, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_restarted_children_until(
      Supervisor, Registry0, Processor0, Deadline).

await_restarted_children_until(Supervisor, Registry0, Processor0, Deadline) ->
    case adk_memory_outbox_sup:runtime(Supervisor) of
        {ok, #{registry := Registry, processor := Processor}}
          when Registry =/= Registry0, Processor =/= Processor0 ->
            {Registry, Processor};
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> erlang:error(memory_outbox_children_not_restarted);
                false ->
                    receive after 10 -> ok end,
                    await_restarted_children_until(
                      Supervisor, Registry0, Processor0, Deadline)
            end
    end.

wait_for_phase(Supervisor, JobId, Phase, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_phase_until(Supervisor, JobId, Phase, Deadline).

wait_for_phase_until(Supervisor, JobId, Phase, Deadline) ->
    case adk_memory_outbox_sup:status(Supervisor, JobId) of
        {ok, #{phase := Phase} = Status} -> Status;
        {ok, #{phase := failed} = Status} ->
            erlang:error({memory_outbox_job_failed, Status});
        Other ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> erlang:error({memory_outbox_phase_timeout, Other});
                false ->
                    receive after 10 -> ok end,
                    wait_for_phase_until(
                      Supervisor, JobId, Phase, Deadline)
            end
    end.

stop_adapter(Adapter) ->
    case is_process_alive(Adapter) of
        true -> adk_memory_outbox_test_adapter:stop(Adapter);
        false -> ok
    end.

stop_supervisor(Supervisor) ->
    case is_process_alive(Supervisor) of
        true -> adk_memory_outbox_sup:stop(Supervisor);
        false -> ok
    end.

delete_test_tables() ->
    lists:foreach(
      fun(Table) -> _ = catch mnesia:delete_table(Table) end,
      [?JOBS, ?USAGE, ?SCHEDULE]),
    ok.

contains_exact(Expected, Expected) -> true;
contains_exact(Expected, Map) when is_map(Map) ->
    lists:any(
      fun({Key, Value}) ->
          contains_exact(Expected, Key) orelse
              contains_exact(Expected, Value)
      end, maps:to_list(Map));
contains_exact(Expected, Tuple) when is_tuple(Tuple) ->
    lists:any(
      fun(Value) -> contains_exact(Expected, Value) end,
      tuple_to_list(Tuple));
contains_exact(Expected, List) when is_list(List) ->
    lists:any(
      fun(Value) -> contains_exact(Expected, Value) end, List);
contains_exact(_Expected, _Value) -> false.
