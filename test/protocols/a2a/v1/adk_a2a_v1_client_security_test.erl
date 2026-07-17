-module(adk_a2a_v1_client_security_test).

-include_lib("eunit/include/eunit.hrl").

-define(LISTENER, adk_a2a_v1_client_security_listener).

safe_destination_defaults_and_exact_host_policy_test() ->
    ?assertEqual(
       {error, invalid_a2a_client_options},
       adk_a2a_v1_client:discover(
         <<"https://example.com">>,
         #{tls_opts => [{verify, verify_none}]})),
    with_fixture(
      fun base_card/1, #{},
      fun(#{base := Base, card := Card}) ->
          ?assertEqual(
             {error, insecure_a2a_destination},
             adk_a2a_v1_client:discover(Base, #{timeout => 500})),
          ?assertEqual(
             {error, a2a_destination_not_allowed},
             adk_a2a_v1_client:discover(
               Base, local_options(#{allowed_hosts =>
                                         [<<"other.example">>]}))),
          ?assertMatch(
             {error, a2a_private_destination_rejected},
             adk_a2a_v1_client:get_task(
               card_with_url(<<"https://169.254.169.254/a2a/v1">>),
               <<"task">>, #{timeout => 500})),
          ?assertEqual(
             {error, insecure_a2a_destination},
             adk_a2a_v1_client:get_task(
               card_with_url(<<"http://10.0.0.1/a2a/v1">>),
               <<"task">>, #{timeout => 500,
                              allow_http_loopback => true})),
          {ok, _} = adk_a2a_v1_client:get_task(
                      Card, <<"task">>, local_options(#{})),
          {undefined, undefined} = receive_request(rpc)
      end).

discovery_and_rpc_credentials_are_separated_test() ->
    with_fixture(
      fun base_card/1, #{},
      fun(#{base := Base, card := Card}) ->
          Owner = self(),
          RpcAuth = fun() ->
              Owner ! rpc_auth_called,
              [{<<"authorization">>, <<"Bearer rpc-private">>}]
          end,
          DiscoveryAuth = fun() ->
              Owner ! discovery_auth_called,
              [{<<"authorization">>, <<"Bearer discovery-private">>}]
          end,

          {ok, _} = adk_a2a_v1_client:discover(
                      Base, local_options(#{auth_fun => RpcAuth})),
          {undefined, undefined} = receive_request(card),
          assert_not_received(rpc_auth_called),

          {ok, _} = adk_a2a_v1_client:discover(
                      Base,
                      local_options(#{auth_fun => RpcAuth,
                                      discovery_auth_fun => DiscoveryAuth})),
          receive discovery_auth_called -> ok after 1000 ->
              error(discovery_auth_not_called)
          end,
          {<<"Bearer discovery-private">>, undefined} =
              receive_request(card),
          assert_not_received(rpc_auth_called),

          {ok, _} = adk_a2a_v1_client:get_task(
                      Card, <<"task">>,
                      local_options(#{auth_fun => RpcAuth})),
          {undefined, undefined} = receive_request(rpc),
          assert_not_received(rpc_auth_called),

          {ok, _} = adk_a2a_v1_client:get_task(
                      Card, <<"task">>,
                      local_options(#{auth_fun => RpcAuth,
                                      allow_undeclared_auth => true})),
          receive rpc_auth_called -> ok after 1000 ->
              error(rpc_auth_not_called)
          end,
          {<<"Bearer rpc-private">>, undefined} = receive_request(rpc)
      end).

declared_security_enables_rpc_auth_and_errors_are_secret_free_test() ->
    Private = <<"Bearer declared-private-token">>,
    RpcError = #{<<"code">> => -32001,
                 <<"message">> => Private,
                 <<"data">> => #{<<"access_token">> => Private}},
    with_fixture(
      fun secure_card/1, #{rpc_error => RpcError},
      fun(#{card := Card}) ->
          ?assertEqual(
             {error, a2a_auth_required},
             adk_a2a_v1_client:get_task(
               Card, <<"task">>, local_options(#{}))),
          assert_no_request(rpc),
          Owner = self(),
          Auth = fun() ->
              Owner ! declared_auth_called,
              [{<<"authorization">>, Private}]
          end,
          ?assertEqual(
             {error, a2a_auth_scheme_required},
             adk_a2a_v1_client:get_task(
               Card, <<"task">>, local_options(#{auth_fun => Auth}))),
          assert_not_received(declared_auth_called),
          assert_no_request(rpc),
          ?assertEqual(
             {error, a2a_auth_scheme_not_declared},
             adk_a2a_v1_client:get_task(
               Card, <<"task">>,
               local_options(#{auth_fun => Auth,
                               auth_scheme => <<"attacker-selected">>}))),
          assert_not_received(declared_auth_called),
          assert_no_request(rpc),
          Result = adk_a2a_v1_client:get_task(
                     Card, <<"task">>,
                     local_options(#{auth_fun => Auth,
                                     auth_scheme => <<"bearer">>})),
          receive declared_auth_called -> ok after 1000 ->
              error(declared_auth_not_called)
          end,
          {Private, undefined} = receive_request(rpc),
          ?assertEqual(
             {error, {a2a_error,
                      #{<<"code">> => -32001,
                        <<"message">> => <<"A2A request failed">>}}},
             Result),
          ?assertEqual(nomatch,
                       binary:match(term_to_binary(Result), Private))
      end).

compound_security_requirement_is_rejected_test() ->
    with_fixture(
      fun compound_secure_card/1, #{},
      fun(#{card := Card}) ->
          Auth = fun() ->
              [{<<"authorization">>, <<"Bearer private">>}]
          end,
          ?assertEqual(
             {error, a2a_compound_auth_not_supported},
             adk_a2a_v1_client:get_task(
               Card, <<"task">>,
               local_options(#{auth_fun => Auth,
                               auth_scheme => <<"bearer">>}))),
          assert_no_request(rpc)
      end).

cross_origin_discovery_requires_exact_origin_allowlist_test() ->
    CrossOrigin = <<"http://127.0.0.1:9">>,
    Builder = fun(_RpcUrl) ->
        card_with_url(<<CrossOrigin/binary, "/a2a/v1">>)
    end,
    with_fixture(
      Builder, #{},
      fun(#{base := Base, card := Expected}) ->
          ?assertEqual(
             {error, cross_origin_agent_interface_rejected},
             adk_a2a_v1_client:discover(Base, local_options(#{}))),
          {undefined, undefined} = receive_request(card),
          {ok, Expected} = adk_a2a_v1_client:discover(
                             Base,
                             local_options(
                               #{allowed_interface_origins =>
                                     [CrossOrigin]})),
          {undefined, undefined} = receive_request(card)
      end).

required_extensions_are_bounded_and_sent_test() ->
    Extension = <<"https://example.test/a2a/extensions/audit/v1">>,
    Builder = fun(RpcUrl) -> extension_card(RpcUrl, [Extension]) end,
    with_fixture(
      Builder, #{},
      fun(#{card := Card}) ->
          {ok, _} = adk_a2a_v1_client:get_task(
                      Card, <<"task">>, local_options(#{})),
          {undefined, Extension} = receive_request(rpc),
          ?assertEqual(
             {error, a2a_extension_header_too_large},
             adk_a2a_v1_client:get_task(
               Card, <<"task">>,
               local_options(#{max_extension_header_bytes => 8}))),
          assert_no_request(rpc)
      end),
    TwoBuilder = fun(RpcUrl) ->
        extension_card(
          RpcUrl, [<<"https://example.test/ext/one">>,
                   <<"https://example.test/ext/two">>])
    end,
    with_fixture(
      TwoBuilder, #{},
      fun(#{card := Card2}) ->
          ?assertEqual(
             {error, too_many_required_a2a_extensions},
             adk_a2a_v1_client:get_task(
               Card2, <<"task">>,
               local_options(#{max_extensions => 1}))),
          assert_no_request(rpc)
      end).

operation_uses_one_absolute_deadline_test() ->
    with_fixture(
      fun base_card/1, #{card_delay_ms => 90, rpc_delay_ms => 90},
      fun(#{base := Base}) ->
          Started = erlang:monotonic_time(millisecond),
          ?assertEqual(
             {error, a2a_timeout},
             adk_a2a_v1_client:get_task(
               Base, <<"task">>,
               #{timeout => 140, allow_http_loopback => true})),
          Elapsed = erlang:monotonic_time(millisecond) - Started,
          ?assert(Elapsed < 260)
      end).

body_chunks_do_not_restart_deadline_test() ->
    with_fixture(
      fun(RpcUrl) -> card_with_url(<<RpcUrl/binary, "/slow">>) end,
      #{slow_chunks => true, chunk_delay_ms => 80},
      fun(#{card := Card}) ->
          ?assertEqual(
             {error, a2a_timeout},
             adk_a2a_v1_client:get_task(
               Card, <<"task">>,
               #{timeout => 120, allow_http_loopback => true}))
      end).

authentication_callback_is_bounded_test() ->
    with_fixture(
      fun base_card/1, #{},
      fun(#{card := Card}) ->
          Owner = self(),
          Auth = fun() ->
              Owner ! {slow_a2a_auth, self()},
              timer:sleep(5000),
              [{<<"authorization">>, <<"Bearer too-late">>}]
          end,
          Started = erlang:monotonic_time(millisecond),
          ?assertEqual(
             {error, a2a_auth_provider_timeout},
             adk_a2a_v1_client:get_task(
               Card, <<"task">>,
               local_options(
                 #{auth_fun => Auth, allow_undeclared_auth => true,
                   auth_timeout => 10}))),
          Elapsed = erlang:monotonic_time(millisecond) - Started,
          ?assert(Elapsed < 1000),
          Worker = receive
              {slow_a2a_auth, Pid} -> Pid
          after 1000 -> error(auth_worker_not_started)
          end,
          ?assertNot(is_process_alive(Worker)),
          assert_no_request(rpc)
      end).

authentication_callback_heap_is_bounded_test() ->
    with_fixture(
      fun base_card/1, #{},
      fun(#{card := Card}) ->
          Auth = fun() ->
              _ = lists:seq(1, 1000000),
              [{<<"authorization">>, <<"Bearer too-large">>}]
          end,
          ?assertEqual(
             {error, a2a_auth_provider_failed},
             adk_a2a_v1_client:get_task(
               Card, <<"task">>,
               local_options(
                 #{auth_fun => Auth, allow_undeclared_auth => true,
                   auth_max_heap_words => 1000}))),
          assert_no_request(rpc)
      end).

authentication_callback_dies_with_request_owner_test() ->
    with_fixture(
      fun base_card/1, #{},
      fun(#{card := Card}) ->
          TestProcess = self(),
          RequestOwner = spawn(fun() ->
              Auth = fun() ->
                  TestProcess ! {owned_a2a_auth_started, self()},
                  receive release ->
                      [{<<"authorization">>, <<"Bearer late">>}]
                  end
              end,
              Result = adk_a2a_v1_client:get_task(
                         Card, <<"task">>,
                         local_options(
                           #{auth_fun => Auth,
                             allow_undeclared_auth => true,
                             auth_timeout => 10000,
                             timeout => 10000})),
              TestProcess ! {unexpected_a2a_owner_result, Result}
          end),
          OwnerMonitor = erlang:monitor(process, RequestOwner),
          AuthWorker = receive
              {owned_a2a_auth_started, Pid} -> Pid
          after 1000 -> error(owned_auth_worker_not_started)
          end,
          WorkerMonitor = erlang:monitor(process, AuthWorker),
          exit(RequestOwner, kill),
          receive
              {'DOWN', OwnerMonitor, process, RequestOwner, killed} -> ok
          after 1000 -> error(request_owner_not_killed)
          end,
          receive
              {'DOWN', WorkerMonitor, process, AuthWorker, killed} -> ok
          after 1000 -> error(orphaned_auth_worker)
          end,
          receive
              {unexpected_a2a_owner_result, Result} ->
                  error({unexpected_a2a_owner_result, Result})
          after 0 -> ok
          end,
          assert_no_request(rpc)
      end).

resolver_obeys_absolute_deadline_without_late_reply_test() ->
    TestProcess = self(),
    RequestOwner = spawn(fun() ->
        Resolver = fun(_Host) ->
            TestProcess ! {late_a2a_resolver_started, self()},
            receive release -> [{8, 8, 8, 8}] end
        end,
        Result = adk_a2a_v1_client:test_resolve_addresses(
                   <<"late.example">>, 20, Resolver),
        timer:sleep(30),
        {message_queue_len, QueueLength} =
            erlang:process_info(self(), message_queue_len),
        TestProcess ! {late_a2a_resolver_result, Result, QueueLength}
    end),
    OwnerMonitor = erlang:monitor(process, RequestOwner),
    ResolverWorker = receive
        {late_a2a_resolver_started, Pid} -> Pid
    after 500 -> error(late_resolver_worker_not_started)
    end,
    timer:sleep(30),
    ResolverWorker ! release,
    receive
        {late_a2a_resolver_result, {error, a2a_timeout}, 0} -> ok;
        {late_a2a_resolver_result, Result, QueueLength} ->
            error({unexpected_late_resolver_result, Result, QueueLength})
    after 1000 -> error(late_resolver_owner_stuck)
    end,
    receive
        {'DOWN', OwnerMonitor, process, RequestOwner, normal} -> ok
    after 1000 -> error(late_resolver_owner_not_stopped)
    end,
    ?assertNot(is_process_alive(ResolverWorker)).

resolver_dies_with_request_owner_test() ->
    TestProcess = self(),
    RequestOwner = spawn(fun() ->
        Resolver = fun(_Host) ->
            TestProcess ! {owned_a2a_resolver_started, self()},
            receive release -> [{8, 8, 8, 8}] end
        end,
        Result = adk_a2a_v1_client:test_resolve_addresses(
                   <<"owner.example">>, 10000, Resolver),
        TestProcess ! {unexpected_a2a_resolver_result, Result}
    end),
    OwnerMonitor = erlang:monitor(process, RequestOwner),
    ResolverWorker = receive
        {owned_a2a_resolver_started, Pid} -> Pid
    after 500 -> error(owned_resolver_worker_not_started)
    end,
    WorkerMonitor = erlang:monitor(process, ResolverWorker),
    exit(RequestOwner, kill),
    receive
        {'DOWN', OwnerMonitor, process, RequestOwner, killed} -> ok
    after 500 -> error(resolver_owner_not_killed)
    end,
    receive
        {'DOWN', WorkerMonitor, process, ResolverWorker, killed} -> ok
    after 500 -> error(orphaned_resolver_worker)
    end.

resolver_normalizes_valid_addresses_test() ->
    V4A = {8, 8, 4, 4},
    V4B = {8, 8, 8, 8},
    V6 = {16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8888},
    Addresses = [V6, V4B, V4A, V4B, V6],
    ?assertEqual(
       {ok, lists:usort(Addresses)},
       adk_a2a_v1_client:test_resolve_addresses(
         <<"normalize.example">>, 1000,
         fun(<<"normalize.example">>) -> Addresses end)).

resolver_address_count_boundary_test() ->
    Address = {8, 8, 8, 8},
    AtLimit = lists:duplicate(64, Address),
    AboveLimit = lists:duplicate(65, Address),
    ?assertEqual(
       {ok, [Address]},
       adk_a2a_v1_client:test_resolve_addresses(
         <<"limit.example">>, 1000, fun(_Host) -> AtLimit end)),
    ?assertEqual(
       {error, a2a_dns_resolution_failed},
       adk_a2a_v1_client:test_resolve_addresses(
         <<"limit.example">>, 1000, fun(_Host) -> AboveLimit end)),
    ?assertEqual(
       {error, a2a_dns_resolution_failed},
       adk_a2a_v1_client:test_resolve_addresses(
         <<"empty.example">>, 1000, fun(_Host) -> [] end)).

resolver_rejects_malformed_results_without_crashing_test() ->
    V4 = {8, 8, 8, 8},
    InvalidResults =
        [not_a_list,
         #{address => V4},
         {ok, [V4]},
         [V4 | improper_tail],
         [{-1, 8, 8, 8}],
         [{256, 8, 8, 8}],
         [{8, 8, 8, not_an_integer}],
         [{8, 8, 8}],
         [{-1, 0, 0, 0, 0, 0, 0, 1}],
         [{16#10000, 0, 0, 0, 0, 0, 0, 1}],
         [{16#2001, 0, 0, 0, 0, 0, 0, not_an_integer}]],
    lists:foreach(
      fun(Result) ->
          ?assertEqual(
             {error, a2a_dns_resolution_failed},
             adk_a2a_v1_client:test_resolve_addresses(
               <<"malformed.example">>, 1000,
               fun(_Host) -> Result end))
      end, InvalidResults),
    ?assertEqual(
       {error, a2a_dns_resolution_failed},
       adk_a2a_v1_client:test_resolve_addresses(
         <<"throw.example">>, 1000,
         fun(_Host) -> error(resolver_failed) end)),
    ?assertEqual(
       {error, a2a_dns_resolution_failed},
       adk_a2a_v1_client:test_resolve_addresses(
         <<"exit.example">>, 1000,
         fun(_Host) -> exit(resolver_failed) end)).

resolver_heap_and_result_are_bounded_test() ->
    HeapResolver = fun(_Host) -> consume_heap([]) end,
    ?assertEqual(
       {error, a2a_dns_resolution_failed},
       adk_a2a_v1_client:test_resolve_addresses(
         <<"heap.example">>, 1000, HeapResolver)),
    TooMany = lists:duplicate(65, {8, 8, 8, 8}),
    ?assertEqual(
       {error, a2a_dns_resolution_failed},
       adk_a2a_v1_client:test_resolve_addresses(
         <<"many.example">>, 1000, fun(_Host) -> TooMany end)),
    ?assertEqual(
       {error, a2a_dns_resolution_failed},
       adk_a2a_v1_client:test_resolve_addresses(
         <<"invalid.example">>, 1000,
         fun(_Host) -> [{999, 8, 8, 8} | invalid_tail] end)).

redirects_are_not_followed_test() ->
    with_fixture(
      fun(RpcUrl) -> card_with_url(<<RpcUrl/binary, "/redirect">>) end,
      #{},
      fun(#{card := Card}) ->
          ?assertEqual(
             {error, {a2a_http_status, 302}},
             adk_a2a_v1_client:get_task(
               Card, <<"task">>, local_options(#{}))),
          {undefined, undefined} = receive_request(redirect),
          assert_no_request(rpc)
      end).

with_fixture(CardBuilder, RpcOptions, Fun) ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    _ = catch cowboy:stop_listener(?LISTENER),
    flush_fixture_messages(),
    Port = free_port(),
    Base = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
    RpcBase = <<Base/binary, "/a2a/v1">>,
    Card = CardBuilder(RpcBase),
    Common = RpcOptions#{parent => self()},
    Dispatch = cowboy_router:compile(
                 [{'_', [
                   {"/.well-known/agent-card.json",
                    adk_a2a_v1_client_fixture_handler,
                    Common#{endpoint => card, card => Card}},
                   {"/a2a/v1/slow", adk_a2a_v1_client_fixture_handler,
                    Common#{endpoint => rpc}},
                   {"/a2a/v1/redirect", adk_a2a_v1_client_fixture_handler,
                    Common#{endpoint => redirect, location => RpcBase}},
                   {"/a2a/v1", adk_a2a_v1_client_fixture_handler,
                    Common#{endpoint => rpc}}
                 ]}]),
    {ok, _} = cowboy:start_clear(
                ?LISTENER,
                #{socket_opts => [{ip, {127, 0, 0, 1}}, {port, Port}]},
                #{env => #{dispatch => Dispatch}}),
    try Fun(#{base => Base, rpc_url => RpcBase, card => Card})
    after
        _ = catch cowboy:stop_listener(?LISTENER),
        flush_fixture_messages()
    end.

base_card(RpcUrl) -> card_with_url(RpcUrl).

card_with_url(Url) ->
    {ok, Card} = adk_a2a_v1_card:new(#{url => Url}),
    Card.

secure_card(RpcUrl) ->
    {ok, Card} = adk_a2a_v1_card:new(
                   #{url => RpcUrl,
                     security_schemes =>
                         #{<<"bearer">> =>
                               #{<<"httpAuthSecurityScheme">> =>
                                     #{<<"scheme">> => <<"Bearer">>}}},
                     security_requirements =>
                         [#{<<"schemes">> =>
                                #{<<"bearer">> =>
                                      #{<<"list">> => []}}}]}),
    Card.

compound_secure_card(RpcUrl) ->
    {ok, Card} = adk_a2a_v1_card:new(
                   #{url => RpcUrl,
                     security_schemes =>
                         #{<<"bearer">> =>
                               #{<<"httpAuthSecurityScheme">> =>
                                     #{<<"scheme">> => <<"Bearer">>}},
                           <<"api-key">> =>
                               #{<<"apiKeySecurityScheme">> =>
                                     #{<<"name">> => <<"x-api-key">>,
                                       <<"location">> => <<"header">>}}},
                     security_requirements =>
                         [#{<<"schemes">> =>
                                #{<<"bearer">> => #{<<"list">> => []},
                                  <<"api-key">> => #{<<"list">> => []}}}]}),
    Card.

extension_card(RpcUrl, Extensions) ->
    {ok, Card} = adk_a2a_v1_card:new(
                   #{url => RpcUrl,
                     extensions => [#{<<"uri">> => Uri,
                                       <<"required">> => true}
                                    || Uri <- Extensions]}),
    Card.

local_options(Extra) ->
    maps:merge(#{timeout => 1000, allow_http_loopback => true}, Extra).

receive_request(Endpoint) ->
    receive
        {a2a_client_fixture_request, Endpoint, Authorization, Extensions} ->
            {Authorization, Extensions}
    after 1000 ->
        error({missing_fixture_request, Endpoint})
    end.

assert_no_request(Endpoint) ->
    receive
        {a2a_client_fixture_request, Endpoint, _, _} ->
            error({unexpected_fixture_request, Endpoint})
    after 50 -> ok
    end.

assert_not_received(Message) ->
    receive Message -> error({unexpected_message, Message})
    after 50 -> ok
    end.

flush_fixture_messages() ->
    receive
        {a2a_client_fixture_request, _, _, _} -> flush_fixture_messages();
        rpc_auth_called -> flush_fixture_messages();
        discovery_auth_called -> flush_fixture_messages();
        declared_auth_called -> flush_fixture_messages()
    after 0 -> ok
    end.

free_port() ->
    {ok, Socket} = gen_tcp:listen(
                     0, [binary, {active, false},
                         {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.

consume_heap(Acc) ->
    consume_heap([make_ref() | Acc]).
