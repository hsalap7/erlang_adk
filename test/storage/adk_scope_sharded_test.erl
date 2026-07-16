-module(adk_scope_sharded_test).
-include_lib("eunit/include/eunit.hrl").

-define(A_SCOPE_A, {session, <<"shard-app">>, <<"alice">>, <<"one">>}).
-define(A_SCOPE_B, {session, <<"shard-app">>, <<"bob">>, <<"two">>}).
-define(M_SCOPE_A, {user, <<"shard-app">>, <<"alice">>}).
-define(M_SCOPE_B, {user, <<"shard-app">>, <<"bob">>}).

artifact_ets_conformance_test() ->
    {ok, Handle} = adk_artifact_sharded:start_link(#{}),
    try
        artifact_conformance(Handle),
        {ok, Capabilities} = adk_artifact_sharded:capabilities(Handle),
        ?assertEqual(1, maps:get(api_version, Capabilities)),
        ?assertEqual(false, maps:get(global_quota, maps:get(quotas,
                                                            Capabilities))),
        ?assertEqual(exact_scope,
                     maps:get(strategy, maps:get(sharding, Capabilities)))
    after
        ok = adk_artifact_sharded:stop(Handle)
    end.

artifact_filesystem_conformance_and_restart_test() ->
    Root = temp_root("artifact-sharded"),
    Config = #{adapter => adk_artifact_fs,
               adapter_config => #{root => Root}},
    try
        {ok, First} = adk_artifact_sharded:start_link(Config),
        artifact_conformance(First),
        {ok, #{persistence := filesystem}} =
            adk_artifact_sharded:capabilities(First),
        ok = adk_artifact_sharded:stop(First),
        {ok, Second} = adk_artifact_sharded:start_link(Config),
        try
            {ok, #{data := <<"three">>, version := 3}} =
                adk_artifact_sharded:get(
                  Second, ?A_SCOPE_A, <<"report.txt">>, latest),
            {ok, #{data := <<"isolated">>}} =
                adk_artifact_sharded:get(
                  Second, ?A_SCOPE_B, <<"report.txt">>, latest)
        after
            ok = adk_artifact_sharded:stop(Second)
        end
    after
        _ = file:del_dir_r(Root)
    end.

memory_ets_conformance_test() ->
    {ok, Handle} = adk_memory_sharded:start_link(#{}),
    try
        memory_conformance(Handle),
        Capabilities = adk_memory_sharded:capabilities(Handle),
        ?assertEqual(2, maps:get(contract_version, Capabilities)),
        ?assertEqual(false, maps:get(global_quota, Capabilities)),
        ?assertEqual(exact_scope_shard,
                     maps:get(quota_scope, Capabilities))
    after
        ok = adk_memory_sharded:stop(Handle)
    end.

memory_mnesia_conformance_and_restart_test() ->
    Config = #{adapter => adk_memory_mnesia},
    {ok, First} = adk_memory_sharded:start_link(Config),
    clear_memory_tables(),
    try
        memory_conformance(First),
        ?assertEqual(true,
                     maps:get(durable,
                              adk_memory_sharded:capabilities(First)))
    after
        ok = adk_memory_sharded:stop(First)
    end,
    {ok, Second} = adk_memory_sharded:start_link(Config),
    try
        {ok, [Hit]} = adk_memory_sharded:search(
                        Second, ?M_SCOPE_A, <<"persistent restart">>,
                        #{limit => 5}),
        ?assertEqual(<<"persistent restart lightweight process">>,
                     maps:get(content, Hit)),
        {ok, []} = adk_memory_sharded:search(
                     Second, ?M_SCOPE_B, <<"persistent restart">>,
                     #{limit => 5})
    after
        ok = adk_memory_sharded:stop(Second),
        clear_memory_tables()
    end.

same_scope_reuses_one_worker_test() ->
    Config = probe_artifact_config(false, 10, 32),
    {ok, Handle = {adk_scope_shard, Router, _RoutingTable,
                   _RouteAdmission, _MaxQueue}} =
        adk_artifact_sharded:start_link(Config),
    flush_probe_messages(),
    try
        {ok, _} = adk_artifact_sharded:put(
                    Handle, ?A_SCOPE_A, <<"one">>, <<>>, #{}),
        {probe_started, Worker, artifact} = receive_probe_started(),
        receive_probe_enter(Worker, put, ?A_SCOPE_A),
        %% A resolved scope uses the protected read-through table. Suspending
        %% the router proves the second call reaches the adapter directly.
        ok = sys:suspend(Router),
        {ok, _} = adk_artifact_sharded:put(
                    Handle, ?A_SCOPE_A, <<"two">>, <<>>, #{}),
        receive_probe_enter(Worker, put, ?A_SCOPE_A),
        ok = sys:resume(Router),
        receive
            {probe_started, _Other, artifact} ->
                ?assert(false)
        after 50 -> ok
        end,
        {ok, #{active_scopes := 1}} =
            adk_artifact_sharded:status(Handle)
    after
        _ = catch sys:resume(Router),
        ok = adk_artifact_sharded:stop(Handle)
    end.

unrelated_scopes_overlap_test() ->
    Config = probe_artifact_config(true, 10, 32),
    {ok, Handle} = adk_artifact_sharded:start_link(Config),
    flush_probe_messages(),
    Parent = self(),
    CallerA = spawn(fun() ->
        Parent ! {call_a, adk_artifact_sharded:put(
                            Handle, ?A_SCOPE_A, <<"a">>, <<>>, #{},
                            #{timeout_ms => 1000})}
    end),
    CallerB = spawn(fun() ->
        Parent ! {call_b, adk_artifact_sharded:put(
                            Handle, ?A_SCOPE_B, <<"b">>, <<>>, #{},
                            #{timeout_ms => 1000})}
    end),
    try
        {WorkerA, OptionsA} = receive_probe_scope(?A_SCOPE_A),
        {WorkerB, OptionsB} = receive_probe_scope(?A_SCOPE_B),
        ?assertNotEqual(WorkerA, WorkerB),
        assert_forwarded_deadline(OptionsA, 1000),
        assert_forwarded_deadline(OptionsB, 1000),
        WorkerA ! {probe_release, ?A_SCOPE_A},
        WorkerB ! {probe_release, ?A_SCOPE_B},
        receive {call_a, {ok, _}} -> ok after 1500 -> ?assert(false) end,
        receive {call_b, {ok, _}} -> ok after 1500 -> ?assert(false) end,
        {ok, #{active_scopes := 2}} =
            adk_artifact_sharded:status(Handle)
    after
        exit(CallerA, kill),
        exit(CallerB, kill),
        _ = adk_artifact_sharded:stop(Handle)
    end.

max_active_scopes_rejected_test() ->
    {ok, Artifact} = adk_artifact_sharded:start_link(
                       #{max_active_scopes => 1}),
    try
        {ok, _} = adk_artifact_sharded:put(
                    Artifact, ?A_SCOPE_A, <<"a">>, <<"one">>, #{}),
        ?assertEqual(
           {error, max_active_scopes_reached},
           adk_artifact_sharded:put(
             Artifact, ?A_SCOPE_B, <<"b">>, <<"two">>, #{}))
    after
        ok = adk_artifact_sharded:stop(Artifact)
    end,
    {ok, Memory} = adk_memory_sharded:start_link(#{max_active_scopes => 1}),
    try
        {ok, _} = add_memory_entry(Memory, ?M_SCOPE_A, <<"one">>, <<"one">>),
        ?assertEqual(
           {error, max_active_scopes_reached},
           add_memory_entry(Memory, ?M_SCOPE_B, <<"two">>, <<"two">>))
    after
        ok = adk_memory_sharded:stop(Memory)
    end.

router_queue_rejects_overload_test() ->
    {ok, Handle = {adk_scope_shard, Router, _RoutingTable,
                   _RouteAdmission, 1}} =
        adk_artifact_sharded:start_link(#{max_router_queue => 1}),
    ok = sys:suspend(Router),
    Parent = self(),
    Blocked = spawn(fun() ->
        Parent ! {blocked_result,
                  adk_artifact_sharded:put(
                    Handle, ?A_SCOPE_A, <<"a">>, <<"one">>, #{},
                    #{timeout_ms => 1000})}
    end),
    try
        ok = await_router_queue(Router, 1, 100),
        ?assertEqual(
           {error, scope_router_overloaded},
           adk_artifact_sharded:put(
             Handle, ?A_SCOPE_B, <<"b">>, <<"two">>, #{})),
        ok = sys:resume(Router),
        receive {blocked_result, {ok, _}} -> ok
        after 1500 -> ?assert(false)
        end
    after
        _ = catch sys:resume(Router),
        exit(Blocked, kill),
        _ = adk_artifact_sharded:stop(Handle)
    end.

killed_cold_route_caller_releases_admission_test() ->
    {ok, Handle = {adk_scope_shard, Router, _RoutingTable,
                   RouteAdmission, 1}} =
        adk_artifact_sharded:start_link(#{max_router_queue => 1}),
    ok = sys:suspend(Router),
    Caller = spawn(fun() ->
        _ = adk_artifact_sharded:put(
              Handle, ?A_SCOPE_A, <<"abandoned">>, <<"one">>, #{},
              #{timeout_ms => 1000}),
        ok
    end),
    try
        ok = await_atomic_value(RouteAdmission, 1, 100),
        exit(Caller, kill),
        ok = await_atomic_value(RouteAdmission, 0, 100),
        ok = sys:resume(Router),
        {ok, _} = adk_artifact_sharded:put(
                    Handle, ?A_SCOPE_B, <<"survivor">>, <<"two">>, #{}),
        {ok, Status} = adk_artifact_sharded:status(Handle),
        ?assertEqual(0, maps:get(cold_routes_in_flight, Status))
    after
        _ = catch sys:resume(Router),
        _ = adk_artifact_sharded:stop(Handle)
    end.

simultaneous_cold_routes_strictly_bounded_test() ->
    MaxColdRoutes = 2,
    CallerCount = 12,
    {ok, Handle = {adk_scope_shard, Router, _RoutingTable,
                   RouteAdmission, MaxColdRoutes}} =
        adk_artifact_sharded:start_link(
          #{max_active_scopes => CallerCount,
            max_router_queue => MaxColdRoutes}),
    ok = sys:suspend(Router),
    Parent = self(),
    Callers = [spawn(fun() ->
        Parent ! {cold_route_ready, self()},
        receive cold_route_go -> ok end,
        Suffix = integer_to_binary(Index),
        Scope = {session, <<"simultaneous">>, Suffix, Suffix},
        Result = adk_artifact_sharded:put(
                   Handle, Scope, <<"entry">>, Suffix, #{},
                   #{timeout_ms => 5000}),
        Parent ! {cold_route_result, self(), Result}
    end) || Index <- lists:seq(1, CallerCount)],
    try
        await_ready_callers(CallerCount),
        lists:foreach(fun(Pid) -> Pid ! cold_route_go end, Callers),
        ok = await_atomic_value(RouteAdmission, MaxColdRoutes, 200),
        Rejected = collect_cold_route_results(
                     CallerCount - MaxColdRoutes, []),
        ?assertEqual(
           CallerCount - MaxColdRoutes,
           length([ok || {error, scope_router_overloaded} <- Rejected])),
        ?assertEqual(MaxColdRoutes, atomics:get(RouteAdmission, 1)),
        ok = sys:resume(Router),
        Admitted = collect_cold_route_results(MaxColdRoutes, []),
        ?assertEqual(MaxColdRoutes,
                     length([ok || {ok, _} <- Admitted])),
        {ok, #{cold_routes_in_flight := 0,
               max_router_queue := MaxColdRoutes,
               cold_route_admission := strict_atomic}} =
            adk_artifact_sharded:status(Handle)
    after
        _ = catch sys:resume(Router),
        lists:foreach(fun(Pid) -> exit(Pid, kill) end, Callers),
        _ = adk_artifact_sharded:stop(Handle)
    end.

owner_and_explicit_stop_clean_children_test() ->
    Parent = self(),
    Owner = spawn(fun() ->
        {ok, OwnedHandle} = adk_artifact_sharded:start_link(
                              probe_artifact_config(false, 10, 32)),
        flush_probe_messages(),
        {ok, _} = adk_artifact_sharded:put(
                    OwnedHandle, ?A_SCOPE_A, <<"owner">>, <<>>, #{}),
        Parent ! {owned_handle, OwnedHandle},
        receive stop_owner -> ok end
    end),
    {owned_handle,
     OwnedHandle = {adk_scope_shard, OwnedRouter, _RoutingTable,
                    _RouteAdmission, _}} =
        receive Message = {owned_handle, _} -> Message
        after 1000 -> ?assert(false)
        end,
    OwnedMonitor = erlang:monitor(process, OwnedRouter),
    Owner ! stop_owner,
    receive {'DOWN', OwnedMonitor, process, OwnedRouter, _} -> ok
    after 1000 -> ?assert(false)
    end,
    ?assertEqual(ok, adk_artifact_sharded:stop(OwnedHandle)),

    {ok, Explicit =
             {adk_scope_shard, ExplicitRouter, _ExplicitTable,
              _ExplicitAdmission, _}} =
        adk_artifact_sharded:start_link(probe_artifact_config(false, 10, 32)),
    flush_probe_messages(),
    {ok, _} = adk_artifact_sharded:put(
                Explicit, ?A_SCOPE_A, <<"explicit">>, <<>>, #{}),
    {probe_started, Worker, artifact} = receive_probe_started(),
    receive_probe_enter(Worker, put, ?A_SCOPE_A),
    RouterMonitor = erlang:monitor(process, ExplicitRouter),
    WorkerMonitor = erlang:monitor(process, Worker),
    ok = adk_artifact_sharded:stop(Explicit),
    receive {'DOWN', RouterMonitor, process, ExplicitRouter, _} -> ok
    after 1000 -> ?assert(false)
    end,
    receive {'DOWN', WorkerMonitor, process, Worker, _} -> ok
    after 1000 -> ?assert(false)
    end.

invalid_scopes_and_adapter_sets_rejected_test() ->
    {ok, Artifact} = adk_artifact_sharded:start_link(#{}),
    try
        ?assertEqual({error, invalid_scope},
                     adk_artifact_sharded:list(
                       Artifact, {user, <<"missing-user">>}))
    after
        ok = adk_artifact_sharded:stop(Artifact)
    end,
    ?assertMatch(
       {error, {invalid_scope_shard_adapter, adk_json,
                {missing_callbacks, [_ | _]}}},
       adk_artifact_sharded:start_link(#{adapter => adk_json})),
    {ok, Memory} = adk_memory_sharded:start_link(#{}),
    try
        ?assertMatch(
           {error, {invalid_memory_scope, _}},
           adk_memory_sharded:search(
             Memory, {session, <<"a">>, <<"u">>, <<"s">>},
             <<"query">>, #{}))
    after
        ok = adk_memory_sharded:stop(Memory)
    end.

artifact_conformance(Handle) ->
    Name = <<"report.txt">>,
    {ok, #{version := 1}} = adk_artifact_sharded:put(
                               Handle, ?A_SCOPE_A, Name, <<"one">>,
                               #{mime_type => <<"text/plain">>}),
    {ok, #{version := 2}} = adk_artifact_sharded:put(
                               Handle, ?A_SCOPE_A, Name, <<"two">>, #{}),
    {ok, #{data := <<"one">>}} =
        adk_artifact_sharded:get(Handle, ?A_SCOPE_A, Name, 1),
    {ok, #{scope := ?A_SCOPE_A, items := [Name]}} =
        adk_artifact_sharded:list_names(Handle, ?A_SCOPE_A, #{limit => 10}),
    {ok, #{items := [_, _]}} = adk_artifact_sharded:list_versions(
                                  Handle, ?A_SCOPE_A, Name, #{limit => 10}),
    ok = adk_artifact_sharded:delete(Handle, ?A_SCOPE_A, Name, latest),
    {ok, #{data := <<"one">>}} =
        adk_artifact_sharded:get(Handle, ?A_SCOPE_A, Name, latest),
    ok = adk_artifact_sharded:delete(Handle, ?A_SCOPE_A, Name, all),
    {ok, #{version := 3}} = adk_artifact_sharded:put(
                               Handle, ?A_SCOPE_A, Name, <<"three">>, #{}),
    {ok, #{version := 1}} = adk_artifact_sharded:put(
                               Handle, ?A_SCOPE_B, Name, <<"isolated">>, #{}),
    {ok, #{data := <<"three">>}} =
        adk_artifact_sharded:get(Handle, ?A_SCOPE_A, Name, latest),
    {ok, #{data := <<"isolated">>}} =
        adk_artifact_sharded:get(Handle, ?A_SCOPE_B, Name, latest).

memory_conformance(Handle) ->
    {ok, First} = add_memory_entry(
                    Handle, ?M_SCOPE_A, <<"durable-entry">>,
                    <<"persistent restart lightweight process">>),
    {ok, Duplicate} = add_memory_entry(
                        Handle, ?M_SCOPE_A, <<"durable-entry">>,
                        <<"persistent restart lightweight process">>),
    ?assertEqual(maps:get(id, First), maps:get(id, Duplicate)),
    {ok, [_]} = adk_memory_sharded:search(
                  Handle, ?M_SCOPE_A, <<"lightweight process">>,
                  #{limit => 5}),
    {ok, []} = adk_memory_sharded:search(
                 Handle, ?M_SCOPE_B, <<"lightweight process">>,
                 #{limit => 5}),
    {ok, _} = add_memory_entry(
                Handle, ?M_SCOPE_B, <<"other-entry">>,
                <<"other user private marker">>),
    {ok, []} = adk_memory_sharded:search(
                 Handle, ?M_SCOPE_A, <<"private marker">>, #{limit => 5}).

add_memory_entry(Handle, Scope, Idempotency, Content) ->
    adk_memory_sharded:add_entry(
      Handle, Scope,
      #{content => Content, metadata => #{},
        provenance => #{session_id => <<"session">>,
                        event_ids => [Idempotency],
                        author => <<"user">>, timestamp => 1}},
      #{idempotency_key => Idempotency}).

probe_artifact_config(Barrier, MaxScopes, MaxQueue) ->
    #{adapter => adk_scope_shard_delay_probe,
      adapter_config => #{test_owner => self(), mode => artifact,
                          barrier => Barrier},
      max_active_scopes => MaxScopes,
      max_router_queue => MaxQueue}.

receive_probe_started() ->
    receive
        Message = {probe_started, _Pid, _Mode} -> Message
    after 1000 -> ?assert(false)
    end.

receive_probe_enter(Worker, Operation, Scope) ->
    receive
        {probe_enter, Worker, Operation, Scope, _CallOptions} -> ok
    after 1000 -> ?assert(false)
    end.

receive_probe_scope(Scope) ->
    receive
        {probe_enter, Worker, put, Scope, CallOptions} ->
            {Worker, CallOptions}
    after 1000 -> ?assert(false)
    end.

assert_forwarded_deadline(#{timeout_ms := Timeout}, Original) ->
    ?assert(Timeout > 0),
    ?assert(Timeout =< Original).

flush_probe_messages() ->
    receive
        {probe_started, _Pid, _Mode} -> flush_probe_messages();
        {probe_stopped, _Pid, _Mode} -> flush_probe_messages();
        {probe_enter, _Pid, _Operation, _Scope, _Options} ->
            flush_probe_messages()
    after 0 -> ok
    end.

await_router_queue(_Router, _Minimum, 0) ->
    {error, timeout};
await_router_queue(Router, Minimum, Attempts) ->
    case process_info(Router, message_queue_len) of
        {message_queue_len, Length} when Length >= Minimum -> ok;
        _ ->
            receive after 5 -> ok end,
            await_router_queue(Router, Minimum, Attempts - 1)
    end.

await_atomic_value(_Admission, _Expected, 0) ->
    {error, timeout};
await_atomic_value(Admission, Expected, Attempts) ->
    case atomics:get(Admission, 1) of
        Expected -> ok;
        _ ->
            receive after 5 -> ok end,
            await_atomic_value(Admission, Expected, Attempts - 1)
    end.

await_ready_callers(0) -> ok;
await_ready_callers(Remaining) ->
    receive
        {cold_route_ready, _Pid} -> await_ready_callers(Remaining - 1)
    after 1000 -> ?assert(false)
    end.

collect_cold_route_results(0, Acc) -> lists:reverse(Acc);
collect_cold_route_results(Remaining, Acc) ->
    receive
        {cold_route_result, _Pid, Result} ->
            collect_cold_route_results(Remaining - 1, [Result | Acc])
    after 1000 ->
        ?assert(false)
    end.

clear_memory_tables() ->
    lists:foreach(
      fun(Table) ->
          case mnesia:clear_table(Table) of
              {atomic, ok} -> ok;
              {aborted, {no_exists, Table}} -> ok
          end
      end, adk_memory_mnesia:table_names()).

temp_root(Prefix) ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    filename:join(Base, Prefix ++ "-" ++
                        integer_to_list(erlang:unique_integer([positive]))).
