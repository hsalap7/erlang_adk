-module(adk_openapi_production_adapters_test).

-include_lib("eunit/include/eunit.hrl").

openapi_production_adapters_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_Started) -> ok end,
     [fun static_credentials_are_private_and_scoped/0,
      fun oauth_uses_token_manager_and_enforces_scopes/0,
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
    Binding = #{kind => oauth2,
                token_manager => adk_token_manager,
                principal => Principal,
                provider => Provider,
                provider_module => adk_auth_fake_provider,
                credential_ref => Ref,
                allowed_scopes => [<<"pets:read">>],
                audience => <<"pet-api">>,
                context => #{counter => Counter, ttl_ms => 60000}},
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
        ok = adk_credential_store_ets:delete(
               adk_credential_store_ets, Principal, Provider, Ref),
        true = ets:delete(Counter)
    end.

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
