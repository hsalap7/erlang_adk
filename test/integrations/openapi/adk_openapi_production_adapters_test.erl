-module(adk_openapi_production_adapters_test).

-include_lib("eunit/include/eunit.hrl").

openapi_production_adapters_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_Started) -> ok end,
     [fun static_credentials_are_private_and_scoped/0,
      fun oauth_uses_token_manager_and_enforces_scopes/0,
      fun broker_admission_and_deadline_are_bounded/0,
      fun broker_rejects_queued_post_deadline_result/0,
      fun broker_worker_dies_with_broker_owner/0,
      fun broker_rejects_oversized_shared_secret/0,
      fun gun_transport_enforces_dns_policy_and_response_limit/0]}.

static_credentials_are_private_and_scoped() ->
    Principal = unique(<<"openapi-static-user">>),
    Provider = unique(<<"openapi-static-provider">>),
    Secret = unique(<<"openapi-api-secret">>),
    {ok, Ref} = adk_credential_store_ets:put(
                  adk_credential_store_ets, Principal, Provider,
                  #{kind => api_key, api_key => Secret}),
    Binding = #{kind => api_key,
                store_module => adk_credential_store_ets,
                store_handle => adk_credential_store_ets,
                principal => Principal,
                provider => Provider,
                credential_ref => Ref},
    {ok, Broker} = adk_openapi_auth_broker:start_link(
                     #{bindings => #{<<"ApiKeyAuth">> => Binding}}),
    try
        Request = #{operation_id => <<"getPet">>,
                    scheme_name => <<"ApiKeyAuth">>,
                    scheme_type => api_key,
                    location => header,
                    parameter_name => <<"x-api-key">>,
                    scopes => []},
        ?assertEqual({ok, {api_key, Secret}},
                     adk_openapi_auth_broker:resolve(Broker, Request)),
        ?assertEqual(
           {error, scheme_type_mismatch},
           adk_openapi_auth_broker:resolve(
             Broker, Request#{scheme_type => bearer})),
        StatusBinary = term_to_binary(sys:get_status(Broker)),
        ?assertEqual(nomatch, binary:match(StatusBinary, Secret)),
        ?assertEqual(nomatch, binary:match(StatusBinary, Ref)),

        WrongBinding = Binding#{principal => unique(<<"other-user">>)},
        {ok, WrongBroker} = adk_openapi_auth_broker:start_link(
                              #{bindings =>
                                    #{<<"ApiKeyAuth">> => WrongBinding}}),
        try
            ?assertEqual(
               {error, credential_unavailable},
               adk_openapi_auth_broker:resolve(WrongBroker, Request))
        after
            gen_server:stop(WrongBroker)
        end
    after
        gen_server:stop(Broker),
        ok = adk_credential_store_ets:delete(
               adk_credential_store_ets, Principal, Provider, Ref)
    end.

oauth_uses_token_manager_and_enforces_scopes() ->
    Principal = unique(<<"openapi-oauth-user">>),
    Provider = unique(<<"openapi-oauth-provider">>),
    Counter = ets:new(openapi_oauth_counter, [set, public]),
    true = ets:insert(Counter, {refreshes, 0}),
    {ok, Ref} = adk_credential_store_ets:put(
                  adk_credential_store_ets, Principal, Provider,
                  #{token_prefix => <<"openapi-oauth-token">>,
                    client_secret => <<"not-returned">>}),
    {ok, TokenManager} = adk_token_manager:start_link(
                           #{name => undefined,
                             store_module => adk_credential_store_ets,
                             store_handle => adk_credential_store_ets,
                             refresh_sup => adk_token_refresh_sup,
                             expiry_skew_ms => 0,
                             provider_profiles =>
                                 #{Provider =>
                                       #{provider_module =>
                                             adk_auth_fake_provider,
                                         context => #{counter => Counter,
                                                      ttl_ms => 60000},
                                         allowed_scopes =>
                                             [<<"pets:read">>],
                                         allowed_audiences =>
                                             [<<"pet-api">>]}}}),
    Binding = #{kind => oauth2,
                token_manager => TokenManager,
                principal => Principal,
                provider => Provider,
                credential_ref => Ref,
                allowed_scopes => [<<"pets:read">>],
                audience => <<"pet-api">>},
    {ok, Broker} = adk_openapi_auth_broker:start_link(
                     #{bindings => #{<<"OAuth">> => Binding},
                       timeout_ms => 2000}),
    Request = #{operation_id => <<"getPet">>,
                scheme_name => <<"OAuth">>,
                scheme_type => oauth2,
                scopes => [<<"pets:read">>]},
    try
        ?assertEqual(
           {ok, {bearer, <<"openapi-oauth-token-1">>}},
           adk_openapi_auth_broker:resolve(Broker, Request)),
        ?assertEqual(
           {error, scope_not_allowed},
           adk_openapi_auth_broker:resolve(
             Broker, Request#{scopes => [<<"pets:write">>]})),
        ?assertEqual(1, ets:lookup_element(Counter, refreshes, 2))
    after
        gen_server:stop(Broker),
        gen_server:stop(TokenManager),
        ok = adk_credential_store_ets:delete(
               adk_credential_store_ets, Principal, Provider, Ref),
        true = ets:delete(Counter)
    end.

broker_admission_and_deadline_are_bounded() ->
    Principal = unique(<<"openapi-bounded-user">>),
    Provider = unique(<<"openapi-bounded-provider">>),
    Secret = unique(<<"openapi-bounded-secret">>),
    {ok, Store} = adk_auth_rotation_test_store:start_link(ok),
    {ok, Ref} = adk_auth_rotation_test_store:put(
                  Store, Principal, Provider,
                  #{kind => api_key, api_key => Secret}),
    Binding = #{kind => api_key,
                store_module => adk_auth_rotation_test_store,
                store_handle => Store,
                principal => Principal,
                provider => Provider,
                credential_ref => Ref},
    {ok, Broker} = adk_openapi_auth_broker:start_link(
                     #{bindings => #{<<"ApiKeyAuth">> => Binding},
                       timeout_ms => 75,
                       max_inflight => 1}),
    Request = #{operation_id => <<"bounded">>,
                scheme_name => <<"ApiKeyAuth">>,
                scheme_type => api_key,
                location => header,
                parameter_name => <<"x-api-key">>,
                scopes => []},
    try
        ok = sys:suspend(Store),
        Parent = self(),
        First = spawn(fun() ->
            Parent ! {bounded_result, self(),
                      adk_openapi_auth_broker:resolve(Broker, Request)}
        end),
        wait_for_broker_inflight(Broker, 50),
        ?assertEqual({error, auth_capacity_exceeded},
                     adk_openapi_auth_broker:resolve(Broker, Request)),
        receive
            {bounded_result, First, FirstResult} ->
                ?assertEqual({error, auth_timeout}, FirstResult)
        after 1000 ->
            error(openapi_auth_timeout_missing)
        end,
        Status = sys:get_status(Broker),
        ?assertEqual(nomatch,
                     binary:match(term_to_binary(Status), Secret)),
        ?assertEqual(nomatch,
                     binary:match(term_to_binary(Status), Ref))
    after
        _ = catch sys:resume(Store),
        _ = catch gen_server:stop(Broker),
        _ = catch gen_server:stop(Store)
    end.

broker_rejects_queued_post_deadline_result() ->
    {Store, Broker, Request} = start_blocked_auth_broker(5000),
    try
        Parent = self(),
        Caller = spawn(fun() ->
            Parent ! {queued_late_broker_result, self(),
                      adk_openapi_auth_broker:resolve(Broker, Request)}
        end),
        wait_for_broker_inflight(Broker, 50),
        {JobRef, Entry} = broker_single_inflight(Broker),
        Worker = maps:get(worker, Entry),
        Deadline = maps:get(deadline, Entry),
        %% Simulate a result that was queued while the broker was descheduled.
        %% The completion timestamp, not mailbox position, decides acceptance.
        Broker ! {openapi_auth_result, JobRef, Worker, Deadline + 1,
                  {ok, {api_key, <<"must-not-be-accepted">>}}},
        receive
            {queued_late_broker_result, Caller, Result} ->
                ?assertEqual({error, auth_timeout}, Result)
        after 1000 ->
            error(queued_late_broker_result_missing)
        end,
        ?assertEqual(ok, wait_process_dead(Worker, 100)),
        ?assert(is_process_alive(Broker)),
        ?assertEqual(0, map_size(element(5, sys:get_state(Broker))))
    after
        stop_blocked_auth_broker(Store, Broker)
    end.

broker_worker_dies_with_broker_owner() ->
    {Store, Broker, Request} = start_blocked_auth_broker(5000),
    unlink(Broker),
    Parent = self(),
    Caller = spawn(fun() ->
        Parent ! {dead_broker_result, self(),
                  adk_openapi_auth_broker:resolve(Broker, Request)}
    end),
    wait_for_broker_inflight(Broker, 50),
    {_JobRef, Entry} = broker_single_inflight(Broker),
    Worker = maps:get(worker, Entry),
    Monitor = erlang:monitor(process, Broker),
    exit(Broker, kill),
    receive
        {'DOWN', Monitor, process, Broker, _Reason} -> ok
    after 1000 ->
        error(openapi_auth_broker_did_not_die)
    end,
    ?assertEqual(ok, wait_process_dead(Worker, 100)),
    receive
        {dead_broker_result, Caller, Result} ->
            ?assertEqual({error, auth_unavailable}, Result)
    after 1000 ->
        error(dead_broker_result_missing)
    end,
    _ = catch sys:resume(Store),
    _ = catch gen_server:stop(Store),
    ok.

broker_rejects_oversized_shared_secret() ->
    Principal = unique(<<"openapi-shared-user">>),
    Provider = unique(<<"openapi-shared-provider">>),
    Oversized = binary:copy(<<"s">>, 20000),
    {ok, Store} = adk_auth_rotation_test_store:start_link(ok),
    {ok, Ref} = adk_auth_rotation_test_store:put(
                  Store, Principal, Provider,
                  #{kind => api_key, api_key => Oversized}),
    Binding = #{kind => api_key,
                store_module => adk_auth_rotation_test_store,
                store_handle => Store,
                principal => Principal,
                provider => Provider,
                credential_ref => Ref},
    {ok, Broker} = adk_openapi_auth_broker:start_link(
                     #{bindings => #{<<"ApiKeyAuth">> => Binding}}),
    try
        ?assertEqual(
           {error, credential_unavailable},
           adk_openapi_auth_broker:resolve(Broker, auth_broker_request())),
        ?assert(is_process_alive(Broker)),
        Status = term_to_binary(sys:get_status(Broker)),
        ?assertEqual(nomatch, binary:match(Status, Oversized))
    after
        _ = catch gen_server:stop(Broker),
        _ = catch gen_server:stop(Store)
    end.

start_blocked_auth_broker(Timeout) ->
    Principal = unique(<<"openapi-lifecycle-user">>),
    Provider = unique(<<"openapi-lifecycle-provider">>),
    {ok, Store} = adk_auth_rotation_test_store:start_link(ok),
    {ok, Ref} = adk_auth_rotation_test_store:put(
                  Store, Principal, Provider,
                  #{kind => api_key, api_key => <<"bounded-secret">>}),
    Binding = #{kind => api_key,
                store_module => adk_auth_rotation_test_store,
                store_handle => Store,
                principal => Principal,
                provider => Provider,
                credential_ref => Ref},
    {ok, Broker} = adk_openapi_auth_broker:start_link(
                     #{bindings => #{<<"ApiKeyAuth">> => Binding},
                       timeout_ms => Timeout, max_inflight => 1}),
    ok = sys:suspend(Store),
    {Store, Broker, auth_broker_request()}.

stop_blocked_auth_broker(Store, Broker) ->
    _ = catch sys:resume(Store),
    _ = catch gen_server:stop(Broker),
    _ = catch gen_server:stop(Store),
    ok.

broker_single_inflight(Broker) ->
    Inflight = element(5, sys:get_state(Broker)),
    [{JobRef, Entry}] = maps:to_list(Inflight),
    {JobRef, Entry}.

auth_broker_request() ->
    #{operation_id => <<"lifecycle">>,
      scheme_name => <<"ApiKeyAuth">>,
      scheme_type => api_key,
      location => header,
      parameter_name => <<"x-api-key">>,
      scopes => []}.

wait_process_dead(_Pid, 0) -> {error, process_survived};
wait_process_dead(Pid, Attempts) ->
    case is_process_alive(Pid) of
        false -> ok;
        true -> timer:sleep(5), wait_process_dead(Pid, Attempts - 1)
    end.

wait_for_broker_inflight(_Broker, 0) ->
    error(openapi_auth_worker_not_started);
wait_for_broker_inflight(Broker, Attempts) ->
    Status = sys:get_status(Broker),
    case contains_status_value(Status, inflight_count, 1) of
        true -> ok;
        false -> timer:sleep(2),
                 wait_for_broker_inflight(Broker, Attempts - 1)
    end.

contains_status_value(#{inflight_count := Value}, inflight_count, Value) ->
    true;
contains_status_value(Term, Key, Value) when is_map(Term) ->
    lists:any(fun({K, V}) ->
                      contains_status_value(K, Key, Value) orelse
                      contains_status_value(V, Key, Value)
              end, maps:to_list(Term));
contains_status_value(Term, Key, Value) when is_tuple(Term) ->
    contains_status_value(tuple_to_list(Term), Key, Value);
contains_status_value(Term, Key, Value) when is_list(Term) ->
    lists:any(fun(Item) -> contains_status_value(Item, Key, Value) end,
              Term);
contains_status_value(_Term, _Key, _Value) -> false.

gun_transport_enforces_dns_policy_and_response_limit() ->
    {Port, Server} = start_http_server(<<"{\"ok\":true}">>),
    Url = <<"http://localhost:", (integer_to_binary(Port))/binary,
            "/pets?limit=1">>,
    Request = transport_request(Url, 1024, true),
    try
        ?assertMatch(
           {ok, #{status := 200, body := <<"{\"ok\":true}">>}},
           adk_openapi_gun_transport:request(default, Request)),
        receive
            {http_request_seen, Server, Captured} ->
                ?assertNotEqual(
                   nomatch, binary:match(Captured, <<"GET /pets?limit=1">>)),
                ?assertNotEqual(
                   nomatch, binary:match(
                              string:lowercase(Captured),
                              <<"host: localhost:">>))
        after 2000 ->
            ?assert(false)
        end
    after
        stop_http_server(Server)
    end,

    ?assertEqual(
       {error, private_address_rejected},
       adk_openapi_gun_transport:request(
         default, Request#{allow_private_hosts => false})),
    ?assertEqual(
       {error, target_not_allowed},
       adk_openapi_gun_transport:request(
         default, Request#{allowed_hosts => [<<"api.example.com">>]})),

    {LargePort, LargeServer} = start_http_server(binary:copy(<<"x">>, 100)),
    LargeUrl = <<"http://localhost:",
                 (integer_to_binary(LargePort))/binary, "/large">>,
    try
        ?assertEqual(
           {error, response_too_large},
           adk_openapi_gun_transport:request(
             default, transport_request(LargeUrl, 10, true)))
    after
        stop_http_server(LargeServer)
    end.

transport_request(Url, MaxBytes, AllowPrivate) ->
    #{method => <<"GET">>,
      url => Url,
      headers => [{<<"accept">>, <<"application/json">>}],
      body => <<>>,
      timeout_ms => 2000,
      max_response_bytes => MaxBytes,
      follow_redirects => false,
      allowed_schemes => [<<"http">>],
      allowed_hosts => [<<"localhost">>],
      allow_private_hosts => AllowPrivate}.

start_http_server(Body) ->
    {ok, Listener} = gen_tcp:listen(
                       0, [binary, {active, false}, {reuseaddr, true},
                           {ip, {127, 0, 0, 1}}]),
    {ok, {{127, 0, 0, 1}, Port}} = inet:sockname(Listener),
    Parent = self(),
    Server = spawn(fun() ->
        {ok, Socket} = gen_tcp:accept(Listener, 2000),
        {ok, Request} = gen_tcp:recv(Socket, 0, 2000),
        Parent ! {http_request_seen, self(), Request},
        Length = integer_to_binary(byte_size(Body)),
        ok = gen_tcp:send(
               Socket,
               <<"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n",
                 "content-length: ", Length/binary,
                 "\r\nconnection: close\r\n\r\n", Body/binary>>),
        gen_tcp:close(Socket),
        gen_tcp:close(Listener)
    end),
    {Port, Server}.

stop_http_server(Server) ->
    case is_process_alive(Server) of
        true -> exit(Server, kill);
        false -> ok
    end.

unique(Prefix) ->
    <<Prefix/binary, "-",
      (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>.
