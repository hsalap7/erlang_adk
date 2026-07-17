-module(adk_openapi_gun_transport_security_test).

-include_lib("eunit/include/eunit.hrl").

openapi_gun_transport_security_test_() ->
    [fun connection_options_bound_header_and_trailer_blocks/0,
     fun resolver_obeys_absolute_deadline/0,
     fun resolver_dies_with_request_owner/0,
     fun resolver_heap_is_bounded/0,
     fun resolver_accepts_address_component_boundaries/0,
     fun resolver_accepts_exact_address_count_limit/0,
     fun resolver_result_count_is_bounded/0,
     fun resolver_rejects_malformed_results_fail_closed/0,
     fun private_override_preserves_explicit_loopback/0,
     fun embedded_and_transition_addresses_are_rejected/0,
     fun non_global_ipv4_ranges_are_rejected/0,
     fun non_global_ipv6_ranges_are_rejected/0,
     fun ordinary_global_addresses_are_accepted/0].

connection_options_bound_header_and_trailer_blocks() ->
    HttpOptions = adk_openapi_gun_transport:test_connection_options(
                    #{scheme => <<"http">>}, 1000),
    HttpsOptions = adk_openapi_gun_transport:test_connection_options(
                     #{scheme => <<"https">>,
                       host => <<"api.example.test">>}, 1000),
    lists:foreach(
      fun(Options) ->
          ?assertEqual(
             #{max_header_block_size => 65536,
               max_trailer_block_size => 65536},
             maps:get(http_opts, Options)),
          ?assertEqual([http], maps:get(protocols, Options)),
          ?assertEqual(0, maps:get(retry, Options)),
          ?assert(maps:get(connect_timeout, Options) > 0)
      end, [HttpOptions, HttpsOptions]),
    ?assertEqual(tcp, maps:get(transport, HttpOptions)),
    ?assertNot(maps:is_key(tls_opts, HttpOptions)),
    ?assertEqual(tls, maps:get(transport, HttpsOptions)),
    ?assert(maps:get(tls_handshake_timeout, HttpsOptions) > 0),
    TlsOptions = maps:get(tls_opts, HttpsOptions),
    ?assertEqual(verify_peer, proplists:get_value(verify, TlsOptions)),
    ?assertEqual("api.example.test",
                 proplists:get_value(server_name_indication, TlsOptions)),
    ?assert(proplists:is_defined(customize_hostname_check, TlsOptions)),
    ?assert(proplists:is_defined(cacerts, TlsOptions)).

resolver_obeys_absolute_deadline() ->
    Parent = self(),
    Resolver = fun(_Host) ->
        Parent ! {resolver_started, self()},
        timer:sleep(10000),
        [{8, 8, 8, 8}]
    end,
    Started = erlang:monotonic_time(millisecond),
    ?assertEqual(
       {error, timeout},
       adk_openapi_gun_transport:test_resolve_target(
         <<"slow.example">>, false, 20, Resolver)),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    ?assert(Elapsed < 500),
    Worker = receive
        {resolver_started, Pid} -> Pid
    after 100 ->
        error(resolver_worker_not_started)
    end,
    wait_until_dead(Worker, 50).

resolver_dies_with_request_owner() ->
    TestProcess = self(),
    RequestOwner = spawn(fun() ->
        Resolver = fun(_Host) ->
            TestProcess ! {owned_resolver_started, self()},
            receive
                release -> [{8, 8, 8, 8}]
            end
        end,
        Result = adk_openapi_gun_transport:test_resolve_target(
                   <<"owner.example">>, false, 10000, Resolver),
        TestProcess ! {unexpected_owner_result, Result}
    end),
    OwnerMonitor = erlang:monitor(process, RequestOwner),
    ResolverWorker = receive
        {owned_resolver_started, Pid} -> Pid
    after 500 ->
        error(owned_resolver_worker_not_started)
    end,
    WorkerMonitor = erlang:monitor(process, ResolverWorker),
    exit(RequestOwner, kill),
    receive
        {'DOWN', OwnerMonitor, process, RequestOwner, killed} -> ok
    after 500 ->
        error(request_owner_not_killed)
    end,
    receive
        {'DOWN', WorkerMonitor, process, ResolverWorker, killed} -> ok
    after 500 ->
        error(orphaned_resolver_worker)
    end,
    receive
        {unexpected_owner_result, Result} ->
            error({unexpected_owner_result, Result})
    after 0 ->
        ok
    end.

resolver_heap_is_bounded() ->
    Resolver = fun(_Host) -> consume_heap([]) end,
    ?assertEqual(
       {error, dns_resolution_failed},
       adk_openapi_gun_transport:test_resolve_target(
         <<"heap.example">>, false, 1000, Resolver)).

resolver_accepts_address_component_boundaries() ->
    Addresses =
        [{0, 0, 0, 0},
         {255, 255, 255, 255},
         {0, 0, 0, 0, 0, 0, 0, 0},
         {16#ffff, 16#ffff, 16#ffff, 16#ffff,
          16#ffff, 16#ffff, 16#ffff, 16#ffff}],
    lists:foreach(
      fun(Address) ->
          ?assertEqual(
             {ok, Address},
             resolve(true, fun(_Host) -> [Address] end))
      end, Addresses).

resolver_accepts_exact_address_count_limit() ->
    Addresses = [{8, 8, 8, Part} || Part <- lists:seq(1, 64)],
    ?assertEqual(
       {ok, {8, 8, 8, 1}},
       resolve(false, fun(_Host) -> Addresses end)),
    ?assertEqual(
       {ok, {8, 8, 8, 8}},
       resolve(false,
               fun(_Host) -> lists:duplicate(64, {8, 8, 8, 8}) end)).

resolver_result_count_is_bounded() ->
    Addresses = lists:duplicate(65, {8, 8, 8, 8}),
    ?assertEqual(
       {error, dns_resolution_failed},
       resolve(false, fun(_Host) -> Addresses end)).

resolver_rejects_malformed_results_fail_closed() ->
    InvalidResults =
        [not_a_list,
         <<"not a list">>,
         #{address => {8, 8, 8, 8}},
         [{8, 8, 8, 8} | invalid_tail],
         [invalid_address],
         [{8, 8, 8}],
         [{8, 8, 8, 8, 8}],
         [{-1, 8, 8, 8}],
         [{256, 8, 8, 8}],
         [{8.0, 8, 8, 8}],
         [{8, 8, 8, invalid_part}],
         [{-1, 0, 0, 0, 0, 0, 0, 1}],
         [{16#10000, 0, 0, 0, 0, 0, 0, 1}],
         [{16#2001, 0.0, 0, 0, 0, 0, 0, 1}],
         [{16#2001, invalid_part, 0, 0, 0, 0, 0, 1}]],
    lists:foreach(
      fun(Result) ->
          ?assertEqual(
             {error, dns_resolution_failed},
             resolve(true, fun(_Host) -> Result end))
      end, InvalidResults),
    ?assertEqual(
       {error, dns_resolution_failed},
       resolve(true, fun(_Host) -> [] end)).

private_override_preserves_explicit_loopback() ->
    Loopback = fun(_Host) -> [{127, 0, 0, 1}] end,
    ?assertEqual({error, private_address_rejected}, resolve(false, Loopback)),
    ?assertEqual({ok, {127, 0, 0, 1}}, resolve(true, Loopback)).

embedded_and_transition_addresses_are_rejected() ->
    Addresses =
        [{0, 0, 0, 0, 0, 0, 16#7f00, 1},
         {0, 0, 0, 0, 0, 16#ffff, 16#0808, 16#0808},
         {16#0064, 16#ff9b, 0, 0, 0, 0, 16#0808, 16#0808},
         {16#0064, 16#ff9b, 1, 0, 0, 0, 16#0808, 16#0808},
         {16#2002, 16#0808, 16#0808, 0, 0, 0, 0, 1}],
    assert_all_non_public(Addresses),
    lists:foreach(
      fun(Address) ->
          ?assertEqual(
             {error, private_address_rejected},
             resolve(false, fun(_Host) -> [Address] end))
      end, Addresses).

non_global_ipv4_ranges_are_rejected() ->
    Addresses =
        [{0, 0, 0, 1},
         {10, 0, 0, 1},
         {100, 64, 0, 1},
         {127, 0, 0, 1},
         {169, 254, 0, 1},
         {172, 16, 0, 1},
         {192, 0, 0, 1},
         {192, 0, 2, 1},
         {192, 31, 196, 1},
         {192, 52, 193, 1},
         {192, 88, 99, 1},
         {192, 168, 0, 1},
         {198, 18, 0, 1},
         {198, 51, 100, 1},
         {203, 0, 113, 1},
         {224, 0, 0, 1},
         {240, 0, 0, 1},
         {255, 255, 255, 255}],
    assert_all_non_public(Addresses).

non_global_ipv6_ranges_are_rejected() ->
    Addresses =
        [{0, 0, 0, 0, 0, 0, 0, 0},
         {0, 0, 0, 0, 0, 0, 0, 1},
         {16#0100, 0, 0, 0, 0, 0, 0, 1},
         {16#2001, 0, 0, 0, 0, 0, 0, 1},
         {16#2001, 2, 0, 0, 0, 0, 0, 1},
         {16#2001, 16#0db8, 0, 0, 0, 0, 0, 1},
         {16#2001, 16#0020, 0, 0, 0, 0, 0, 1},
         {16#3ffe, 0, 0, 0, 0, 0, 0, 1},
         {16#3fff, 0, 0, 0, 0, 0, 0, 1},
         {16#fc00, 0, 0, 0, 0, 0, 0, 1},
         {16#fe80, 0, 0, 0, 0, 0, 0, 1},
         {16#fec0, 0, 0, 0, 0, 0, 0, 1},
         {16#ff02, 0, 0, 0, 0, 0, 0, 1},
         {16#4000, 0, 0, 0, 0, 0, 0, 1}],
    assert_all_non_public(Addresses).

ordinary_global_addresses_are_accepted() ->
    Ipv4 = {8, 8, 8, 8},
    Ipv6 = {16#2606, 16#4700, 16#4700, 0, 0, 0, 0, 16#1111},
    ?assert(adk_openapi_gun_transport:test_is_public_address(Ipv4)),
    ?assert(adk_openapi_gun_transport:test_is_public_address(Ipv6)),
    ?assertEqual({ok, Ipv4}, resolve(false, fun(_Host) -> [Ipv4] end)),
    ?assertEqual({ok, Ipv6}, resolve(false, fun(_Host) -> [Ipv6] end)).

assert_all_non_public(Addresses) ->
    lists:foreach(
      fun(Address) ->
          ?assertNot(
             adk_openapi_gun_transport:test_is_public_address(Address))
      end, Addresses).

resolve(AllowPrivate, Resolver) ->
    adk_openapi_gun_transport:test_resolve_target(
      <<"fixture.example">>, AllowPrivate, 500, Resolver).

consume_heap(Acc) ->
    consume_heap([make_ref() | Acc]).

wait_until_dead(Pid, 0) ->
    ?assertNot(is_process_alive(Pid));
wait_until_dead(Pid, Attempts) ->
    case is_process_alive(Pid) of
        false -> ok;
        true ->
            timer:sleep(2),
            wait_until_dead(Pid, Attempts - 1)
    end.
