-module(adk_context_cache_test).

-include_lib("eunit/include/eunit.hrl").

cache_test_() ->
    [fun strict_configuration_and_scope/0,
     fun concurrent_single_flight_and_private_metadata/0,
     fun scope_isolation_and_capacity_bound/0,
     fun scoped_lifecycle_is_exact_and_content_free/0,
     fun expiry_and_invalidation/0,
     fun provider_failure_falls_back/0,
     fun caller_deadline_cancels_orphan_create/0,
     fun queued_provider_result_cannot_beat_caller_deadline/0,
     fun explicit_stop_deletes_active_resources_in_parallel/0,
     fun registry_is_owner_bound/0].

strict_configuration_and_scope() ->
    ?assertMatch(
       {error, {invalid_context_cache_options,
                {unknown_keys, [unknown]}}},
       adk_context_cache:compile(#{unknown => true})),
    ?assertMatch(
       {error, {invalid_context_cache_options,
                default_ttl_exceeds_max_ttl}},
       adk_context_cache:compile(
         #{default_ttl_ms => 100, max_ttl_ms => 10})),
    adk_context_cache_fake_provider:reset(success),
    {ok, Cache} = adk_context_cache:start_link(#{}),
    try
        ?assertEqual(
           {error, invalid_context_cache_scope_keys},
           adk_context_cache:acquire(
             Cache, adk_context_cache_fake_provider,
             #{app => <<"app">>, user => <<"u">>, model => <<"m">>},
             prefix(<<"x">>), #{})),
        ?assertEqual(
           {error, sensitive_context_cache_scope},
           adk_context_cache:acquire(
             Cache, adk_context_cache_fake_provider,
             (scope(<<"u">>))#{policy => #{api_key => <<"secret">>}},
             prefix(<<"x">>), #{})),
        ?assertMatch(
           {error, {invalid_context_cache_provider, unavailable}},
           adk_context_cache:acquire(
             Cache, adk_missing_cache_provider, scope(<<"u">>),
             prefix(<<"x">>), #{}))
    after adk_context_cache:stop(Cache)
    end,
    {ok, MinimumCache} = adk_context_cache:start_link(
                           #{min_prefix_tokens => 100000}),
    try
        ?assertMatch(
           {bypass, #{<<"status">> := <<"below_minimum">>}},
           adk_context_cache:acquire(
             MinimumCache, adk_context_cache_fake_provider,
             scope(<<"u">>), prefix(<<"small">>), #{})),
        ?assertEqual(0, maps:get(creates,
                                 adk_context_cache_fake_provider:stats()))
    after adk_context_cache:stop(MinimumCache)
    end.

concurrent_single_flight_and_private_metadata() ->
    adk_context_cache_fake_provider:reset({delay, 100}),
    {ok, Cache} = adk_context_cache:start_link(
                    #{create_timeout_ms => 1000,
                      max_waiters_per_key => 64}),
    try
        Parent = self(),
        Prefix = (prefix(<<"shared">>))#{
                   <<"nested">> => #{<<"api_key">> => <<"secret">>}},
        [spawn(fun() ->
             Parent ! {cache_result,
                       adk_context_cache:acquire(
                         Cache, adk_context_cache_fake_provider,
                         scope(<<"user">>), Prefix, #{})}
         end) || _ <- lists:seq(1, 24)],
        Results = collect_results(24, []),
        ?assertEqual(1, maps:get(creates,
                                 adk_context_cache_fake_provider:stats())),
        Leases = [Lease || {ok, Lease, _Meta} <- Results],
        ?assertEqual(24, length(Leases)),
        ?assertEqual(1, length(lists:usort(Leases))),
        Lease = hd(Leases),
        {ok, Resource} = adk_context_cache:resolve(Cache, Lease),
        ?assertMatch(<<"provider-cache-resource-", _/binary>>, Resource),
        {ok, Lease, HitMeta} = adk_context_cache:acquire(
                                 Cache, adk_context_cache_fake_provider,
                                 scope(<<"user">>), Prefix, #{}),
        ?assertEqual(<<"hit">>, maps:get(<<"status">>, HitMeta)),
        EncodedMetadata = jsx:encode(HitMeta),
        ?assertEqual(nomatch, binary:match(EncodedMetadata, Resource)),
        ?assertEqual(nomatch,
                     binary:match(EncodedMetadata, <<"must-not-escape">>)),
        SafePrefix = adk_context_cache_fake_provider:last_prefix(),
        ?assertEqual(false, contains_sensitive_key(SafePrefix)),
        ?assert(is_binary(jsx:encode(HitMeta)))
    after adk_context_cache:stop(Cache)
    end.

scope_isolation_and_capacity_bound() ->
    adk_context_cache_fake_provider:reset(success),
    {ok, Cache} = adk_context_cache:start_link(#{max_entries => 2}),
    try
        {ok, LeaseA, _} = adk_context_cache:acquire(
                            Cache, adk_context_cache_fake_provider,
                            scope(<<"a">>), prefix(<<"same">>), #{}),
        {ok, LeaseB, _} = adk_context_cache:acquire(
                            Cache, adk_context_cache_fake_provider,
                            scope(<<"b">>), prefix(<<"same">>), #{}),
        ?assertNotEqual(LeaseA, LeaseB),
        ?assertEqual(2, maps:get(creates,
                                 adk_context_cache_fake_provider:stats())),
        ?assertMatch(
           {bypass, #{<<"reason">> := <<"registry_full">>}},
           adk_context_cache:acquire(
             Cache, adk_context_cache_fake_provider,
             scope(<<"c">>), prefix(<<"other">>), #{}))
    after adk_context_cache:stop(Cache)
    end.

scoped_lifecycle_is_exact_and_content_free() ->
    adk_context_cache_fake_provider:reset(success),
    {ok, Cache} = adk_context_cache:start_link(#{}),
    ScopeA = scope(<<"lifecycle-a">>),
    ScopeB = scope(<<"lifecycle-b">>),
    try
        {ok, LeaseA, _} = adk_context_cache:acquire(
                            Cache, adk_context_cache_fake_provider,
                            ScopeA, prefix(<<"private-prefix-a">>), #{}),
        {ok, LeaseB, _} = adk_context_cache:acquire(
                            Cache, adk_context_cache_fake_provider,
                            ScopeB, prefix(<<"private-prefix-b">>), #{}),
        Deadline = erlang:monotonic_time(millisecond) + 1000,
        {ok, StatusA} = adk_context_cache:scope_status(
                          Cache, adk_context_cache_fake_provider, ScopeA,
                          #{deadline_ms => Deadline}),
        ?assertEqual(1, maps:get(<<"entries">>, StatusA)),
        ?assertEqual(<<"active">>, maps:get(<<"status">>, StatusA)),
        Encoded = jsx:encode(StatusA),
        ?assertEqual(nomatch, binary:match(Encoded, <<"private-prefix-a">>)),
        ?assertEqual(nomatch,
                     binary:match(Encoded,
                                  <<"provider-cache-resource-">>)),
        ?assertEqual(nomatch, binary:match(Encoded, <<"#Pid">>)),
        ?assertEqual(
           {error, context_cache_deadline_exceeded},
           adk_context_cache:scope_status(
             Cache, adk_context_cache_fake_provider, ScopeA,
             #{deadline_ms => erlang:monotonic_time(millisecond) - 1})),
        {ok, Invalidated} = adk_context_cache:invalidate_scope(
                              Cache, adk_context_cache_fake_provider,
                              ScopeA, #{deadline_ms => Deadline}),
        ?assertEqual(1, maps:get(<<"entries">>, Invalidated)),
        ?assertEqual({error, context_cache_lease_expired},
                     adk_context_cache:resolve(Cache, LeaseA)),
        ?assertMatch({ok, _}, adk_context_cache:resolve(Cache, LeaseB)),
        {ok, EmptyA} = adk_context_cache:scope_status(
                         Cache, adk_context_cache_fake_provider, ScopeA,
                         #{deadline_ms => Deadline}),
        ?assertEqual(<<"empty">>, maps:get(<<"status">>, EmptyA)),
        ?assertEqual(0, maps:get(<<"entries">>, EmptyA))
    after adk_context_cache:stop(Cache)
    end.

expiry_and_invalidation() ->
    adk_context_cache_fake_provider:reset(success),
    {ok, Cache} = adk_context_cache:start_link(
                    #{default_ttl_ms => 30, max_ttl_ms => 1000}),
    try
        {ok, Lease1, _} = adk_context_cache:acquire(
                            Cache, adk_context_cache_fake_provider,
                            scope(<<"u">>), prefix(<<"expiring">>), #{}),
        timer:sleep(60),
        ?assertEqual({error, context_cache_lease_expired},
                     adk_context_cache:resolve(Cache, Lease1)),
        {ok, Lease2, _} = adk_context_cache:acquire(
                            Cache, adk_context_cache_fake_provider,
                            scope(<<"u">>), prefix(<<"expiring">>), #{}),
        ?assertNotEqual(Lease1, Lease2),
        {ok, Invalidated} = adk_context_cache:invalidate(
                              Cache, adk_context_cache_fake_provider,
                              scope(<<"u">>), prefix(<<"expiring">>)),
        ?assertEqual(1, maps:get(<<"entries">>, Invalidated)),
        ?assertEqual({error, context_cache_lease_expired},
                     adk_context_cache:resolve(Cache, Lease2)),
        wait_for_deletes(2, 100),
        {ok, Status} = adk_context_cache:status(Cache),
        ?assertEqual(0, maps:get(<<"entries">>, Status))
    after adk_context_cache:stop(Cache)
    end.

provider_failure_falls_back() ->
    adk_context_cache_fake_provider:reset(fail),
    {ok, Cache} = adk_context_cache:start_link(#{}),
    try
        {bypass, Meta} = adk_context_cache:acquire(
                           Cache, adk_context_cache_fake_provider,
                           scope(<<"u">>), prefix(<<"fail">>), #{}),
        ?assertEqual(<<"fixture_provider_failure">>,
                     maps:get(<<"reason">>, Meta)),
        {ok, Status} = adk_context_cache:status(Cache),
        ?assertEqual(0, maps:get(<<"entries">>, Status)),
        ?assertEqual(0, maps:get(<<"in_flight">>, Status))
    after adk_context_cache:stop(Cache)
    end,
    {ok, Strict} = adk_context_cache:start_link(#{failure_mode => error}),
    try
        ?assertEqual(
           {error, {context_cache_unavailable, fixture_provider_failure}},
           adk_context_cache:acquire(
             Strict, adk_context_cache_fake_provider,
             scope(<<"u">>), prefix(<<"fail">>), #{}))
    after adk_context_cache:stop(Strict)
    end.

caller_deadline_cancels_orphan_create() ->
    adk_context_cache_fake_provider:reset(hang),
    {ok, Cache} = adk_context_cache:start_link(
                    #{create_timeout_ms => 5000}),
    try
        Parent = self(),
        Deadline = erlang:monotonic_time(millisecond) + 50,
        spawn(fun() ->
            Parent ! {deadline_result,
                      adk_context_cache:acquire(
                        Cache, adk_context_cache_fake_provider,
                        scope(<<"u">>), prefix(<<"hang">>),
                        #{deadline_ms => Deadline})}
        end),
        Worker = wait_cache_worker(100),
        receive
            {deadline_result, Result} ->
                ?assertMatch(
                   {bypass, #{<<"reason">> := <<"deadline_exceeded">>}},
                   Result)
        after 1000 -> error(cache_deadline_not_enforced)
        end,
        assert_down(Worker),
        {ok, Status} = adk_context_cache:status(Cache),
        ?assertEqual(0, maps:get(<<"in_flight">>, Status)),
        ?assertEqual(0, maps:get(<<"waiters">>, Status))
    after adk_context_cache:stop(Cache)
    end.

queued_provider_result_cannot_beat_caller_deadline() ->
    adk_context_cache_fake_provider:reset({controlled, self()}),
    {ok, Cache} = adk_context_cache:start_link(
                    #{create_timeout_ms => 5000}),
    Parent = self(),
    try
        Deadline = erlang:monotonic_time(millisecond) + 100,
        Caller = spawn(fun() ->
            Parent ! {boundary_deadline_result,
                      adk_context_cache:acquire(
                        Cache, adk_context_cache_fake_provider,
                        scope(<<"deadline-boundary">>),
                        prefix(<<"queued-before-deadline">>),
                        #{deadline_ms => Deadline})}
        end),
        Worker = receive
            {cache_provider_waiting, ProviderWorker} -> ProviderWorker
        after 1000 -> error(cache_provider_not_waiting)
        end,
        ok = sys:suspend(Cache),
        Worker ! cache_provider_release,
        timer:sleep(150),
        ok = sys:resume(Cache),
        receive
            {boundary_deadline_result, Result} ->
                ?assertMatch(
                   {bypass, #{<<"reason">> := <<"deadline_exceeded">>}},
                   Result)
        after 1000 -> error(cache_boundary_deadline_not_enforced)
        end,
        assert_down(Caller),
        wait_for_deletes(1, 100),
        {ok, Status} = adk_context_cache:status(Cache),
        ?assertEqual(0, maps:get(<<"entries">>, Status)),
        ?assertEqual(0, maps:get(<<"in_flight">>, Status)),
        ?assertEqual(0, maps:get(<<"waiters">>, Status))
    after
        _ = catch sys:resume(Cache),
        adk_context_cache:stop(Cache)
    end.

explicit_stop_deletes_active_resources_in_parallel() ->
    adk_context_cache_fake_provider:reset(success),
    {ok, Cache} = adk_context_cache:start_link(
                    #{delete_timeout_ms => 1000}),
    {ok, _, _} = adk_context_cache:acquire(
                   Cache, adk_context_cache_fake_provider,
                   scope(<<"shutdown-a">>), prefix(<<"a">>), #{}),
    {ok, _, _} = adk_context_cache:acquire(
                   Cache, adk_context_cache_fake_provider,
                   scope(<<"shutdown-b">>), prefix(<<"b">>), #{}),
    ok = adk_context_cache_fake_provider:reset({delete_delay, 50}),
    ok = adk_context_cache:stop(Cache),
    ?assertEqual(2,
                 maps:get(deletes,
                          adk_context_cache_fake_provider:stats())),
    ?assertEqual(2,
                 maps:get(max_delete_active,
                          adk_context_cache_fake_provider:stats())),
    ?assertEqual(false, is_process_alive(Cache)),
    adk_context_cache_fake_provider:reset(success),
    {ok, BoundedCache} = adk_context_cache:start_link(
                           #{delete_timeout_ms => 30}),
    {ok, _, _} = adk_context_cache:acquire(
                   BoundedCache, adk_context_cache_fake_provider,
                   scope(<<"shutdown-bounded">>), prefix(<<"bounded">>),
                   #{}),
    ok = adk_context_cache_fake_provider:reset({delete_delay, 1000}),
    Started = erlang:monotonic_time(millisecond),
    ok = adk_context_cache:stop(BoundedCache),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    ?assert(Elapsed < 500),
    ?assertEqual(1,
                 maps:get(deletes,
                          adk_context_cache_fake_provider:stats())),
    ?assertEqual(false, is_process_alive(BoundedCache)).

registry_is_owner_bound() ->
    Parent = self(),
    Owner = spawn(fun() ->
        {ok, Cache} = adk_context_cache:start(#{}),
        Parent ! {owned_cache, Cache},
        receive stop_owner -> ok end
    end),
    Cache = receive
        {owned_cache, Pid} -> Pid
    after 1000 -> error(cache_did_not_start)
    end,
    Monitor = erlang:monitor(process, Cache),
    exit(Owner, kill),
    receive
        {'DOWN', Monitor, process, Cache, _} -> ok
    after 1000 -> error(cache_outlived_owner)
    end.

scope(User) ->
    #{app => <<"example-app">>,
      user => User,
      model => <<"gemini-3.1-flash-lite">>,
      policy => #{context_version => 1, cache_policy => <<"default">>}}.

prefix(Value) ->
    #{<<"system_instruction">> => <<"You are concise.">>,
      <<"history_prefix">> => [Value],
      <<"tools">> => []}.

collect_results(0, Acc) -> lists:reverse(Acc);
collect_results(Count, Acc) ->
    receive
        {cache_result, Result} -> collect_results(Count - 1, [Result | Acc])
    after 3000 -> error(cache_results_timeout)
    end.

wait_for_deletes(Expected, 0) ->
    ?assertEqual(Expected,
                 maps:get(deletes, adk_context_cache_fake_provider:stats()));
wait_for_deletes(Expected, Attempts) ->
    case maps:get(deletes, adk_context_cache_fake_provider:stats()) >= Expected of
        true -> ok;
        false -> timer:sleep(10), wait_for_deletes(Expected, Attempts - 1)
    end.

assert_down(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    receive
        {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 -> error(provider_worker_outlived_waiter)
    end.

wait_cache_worker(0) -> error(cache_provider_did_not_start);
wait_cache_worker(Attempts) ->
    case adk_context_cache_fake_provider:last_worker() of
        undefined ->
            timer:sleep(10),
            wait_cache_worker(Attempts - 1);
        Pid -> Pid
    end.

contains_sensitive_key(Map) when is_map(Map) ->
    lists:any(
      fun({Key, Value}) ->
          adk_context_guard:sensitive_key(Key)
          orelse contains_sensitive_key(Value)
      end, maps:to_list(Map));
contains_sensitive_key(List) when is_list(List) ->
    lists:any(fun contains_sensitive_key/1, List);
contains_sensitive_key(_) -> false.
