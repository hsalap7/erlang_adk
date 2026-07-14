-module(adk_auth_bounds_test).

-include_lib("eunit/include/eunit.hrl").

authentication_resource_bounds_test_() ->
    [fun credential_store_bounds/0,
     fun oidcc_input_bounds/0,
     fun token_manager_config_and_request_bounds/0,
     fun token_manager_provider_result_and_heap_bounds/0,
     fun refresh_workers_follow_manager_and_deadline/0,
     fun openapi_broker_bounds/0].

credential_store_bounds() ->
    {ok, Store} = adk_credential_store_ets:start_link(
                    #{name => undefined, max_entries => 1,
                      max_credential_bytes => 128}),
    unlink(Store),
    try
        {ok, Ref} = adk_credential_store_ets:put(
                      Store, <<"alice">>, <<"provider">>,
                      #{value => <<"small">>}),
        ?assertEqual({error, capacity_reached},
                     adk_credential_store_ets:put(
                       Store, <<"alice">>, <<"provider">>,
                       #{value => <<"second">>})),
        ?assertEqual({error, invalid_credential},
                     adk_credential_store_ets:put(
                       Store, <<"alice">>, <<"provider">>,
                       #{value => binary:copy(<<"x">>, 256)})),
        ?assertEqual({error, invalid_scope},
                     adk_credential_store_ets:fetch(
                       Store, binary:copy(<<"i">>, 4097),
                       <<"provider">>, Ref)),
        ?assertEqual({error, not_found},
                     adk_credential_store_ets:fetch(
                       Store, <<"alice">>, <<"provider">>, <<"bad-ref">>))
    after
        stop_process(Store)
    end,
    ?assertMatch(
       {error, _},
       adk_credential_store_ets:start_link(
         #{name => undefined, max_entries => 1048577})),
    ?assertMatch(
       {error, _},
       adk_credential_store_ets:start_link(
         #{name => undefined, max_credential_bytes => 8388609})),
    ?assertEqual(
       {error, invalid_credential_store_options},
       adk_credential_store_ets:start_link(
         #{name => undefined, ignored_padding => <<"not accepted">>})).

oidcc_input_bounds() ->
    BaseCredential = #{kind => oauth_client_credentials,
                       client_id => <<"client">>,
                       client_secret => <<"secret">>},
    BaseContext = #{provider_worker => bounds_provider,
                    oauth_adapter => adk_oidc_fake_oauth_adapter,
                    scopes => [<<"scope">>]},
    ?assertEqual(
       {error, invalid_credential},
       adk_auth_provider_oidcc:refresh(
         BaseCredential#{client_id => binary:copy(<<"i">>, 4097)},
         BaseContext)),
    ?assertEqual(
       {error, invalid_credential},
       adk_auth_provider_oidcc:refresh(
         BaseCredential#{client_secret => binary:copy(<<"s">>, 16385)},
         BaseContext)),
    ?assertEqual(
       {error, invalid_context},
       adk_auth_provider_oidcc:refresh(
         BaseCredential,
         BaseContext#{scopes => [integer_to_binary(I)
                                || I <- lists:seq(1, 65)]})),
    ?assertEqual(
       {error, invalid_context},
       adk_auth_provider_oidcc:refresh(
         BaseCredential,
         BaseContext#{scopes => [binary:copy(<<"s">>, 513)]})),
    ?assertEqual(
       {error, invalid_context},
       adk_auth_provider_oidcc:refresh(
         BaseCredential,
         BaseContext#{resource => binary:copy(<<"r">>, 8193)})).

token_manager_config_and_request_bounds() ->
    ?assertMatch(
       {error, _},
       adk_token_manager:start_link(
         #{name => undefined, refresh_timeout_ms => 60001})),
    ?assertMatch(
       {error, _},
       adk_token_manager:start_link(
         #{name => undefined, max_cache_entries => 65537})),
    ?assertMatch(
       {error, _},
       adk_token_manager:start_link(
         #{name => undefined,
           provider_profiles =>
               #{<<"provider">> =>
                     #{provider_module => adk_auth_bounds_provider,
                       context => #{padding => binary:copy(<<"p">>, 65537)}}}})),
    with_token_runtime(
      fun(Store, Manager) ->
          {ok, Ref} = adk_credential_store_ets:put(
                        Store, <<"alice">>, <<"bounds">>, #{mode => valid}),
          Request = token_request(Ref),
          ?assertMatch({ok, _},
                       adk_token_manager:get_token(Manager, Request, 1000)),
          ?assertEqual({error, invalid_request},
                       adk_token_manager:get_token(
                         Manager,
                         Request#{principal => binary:copy(<<"p">>, 4097)},
                         1000)),
          ?assertEqual({error, invalid_request},
                       adk_token_manager:get_token(
                         Manager,
                         Request#{scopes => [integer_to_binary(I)
                                             || I <- lists:seq(1, 65)]},
                         1000)),
          ?assertEqual({error, invalid_request},
                       adk_token_manager:get_token(
                         Manager,
                         Request#{audience => binary:copy(<<"a">>, 8193)},
                         1000)),
          ?assertEqual({error, invalid_request},
                       adk_token_manager:get_token(
                         Manager, Request#{unexpected => true}, 1000)),
          ?assertEqual({error, invalid_request},
                       adk_token_manager:get_token(Manager, Request, 60001)),
          ?assertEqual(
             {error, invalid_request},
             adk_token_manager:invalidate(
               Manager,
               #{principal => binary:copy(<<"p">>, 20000),
                 provider => <<"bounds">>, credential_ref => Ref}))
      end).

token_manager_provider_result_and_heap_bounds() ->
    with_token_runtime(
      fun(Store, Manager) ->
          lists:foreach(
            fun(Mode) ->
                {ok, Ref} = adk_credential_store_ets:put(
                              Store, <<"alice">>, <<"bounds">>,
                              #{mode => Mode}),
                ?assertEqual(
                   {error, invalid_provider_response},
                   adk_token_manager:get_token(
                     Manager, token_request(Ref), 3000))
            end,
            [oversized_access, oversized_error, invalid_token_type,
             oversized_expiry]),
          {ok, HeapRef} = adk_credential_store_ets:put(
                            Store, <<"alice">>, <<"bounds">>,
                            #{mode => heap_bomb}),
          ?assertEqual(
             {error, provider_process_failed},
             adk_token_manager:get_token(
               Manager, token_request(HeapRef), 3000))
      end).

refresh_workers_follow_manager_and_deadline() ->
    Parent = self(),
    Manager = spawn(fun() -> refresh_manager_init(Parent) end),
    ManagerAlias = receive
        {refresh_manager_ready, Manager, Alias} ->
            Alias
    after 1000 ->
        error(refresh_manager_did_not_start)
    end,
    {ok, Store} = adk_credential_store_ets:start_link(#{name => undefined}),
    unlink(Store),
    Credential = #{kind => oauth_refresh_token,
                   refresh_token => <<"old-refresh">>},
    {ok, Ref} = adk_credential_store_ets:put(
                  Store, <<"alice">>, <<"deadline">>, Credential),
    Generation = make_ref(),
    {ok, Worker} = adk_token_refresh_worker:start_link(Manager, Generation),
    unlink(Worker),
    try
        receive
            {refresh_manager_message, Manager,
             {auth_refresh_ready, Generation, Worker}} -> ok
        after 1000 ->
            error(refresh_worker_did_not_start)
        end,
        Deadline = erlang:monotonic_time(millisecond) + 50,
        Work = #{store_module => adk_credential_store_ets,
                 store_handle => Store,
                 principal => <<"alice">>, provider => <<"deadline">>,
                 credential_ref => Ref,
                 provider_module => adk_auth_deadline_provider,
                 context => #{test_pid => Parent},
                 deadline_ms => Deadline,
                 manager_alias => ManagerAlias},
        ok = adk_token_refresh_worker:perform(Worker, Work),
        Provider = receive
            {deadline_provider_started, ProviderPid, Rotator}
              when is_pid(ProviderPid), is_function(Rotator, 2) ->
                wait_until_after(Deadline),
                ?assertEqual(
                   {error, deadline_exceeded},
                   Rotator(Credential, <<"late-refresh">>)),
                ProviderPid
        after 1000 ->
            error(deadline_provider_did_not_start)
        end,
        ?assertMatch(
           {max_heap_size, #{include_shared_binaries := true}},
           process_info(Worker, max_heap_size)),
        ?assertMatch(
           {max_heap_size, #{include_shared_binaries := true}},
           process_info(Provider, max_heap_size)),
        ?assertEqual(
           {ok, Credential},
           adk_credential_store_ets:fetch(
             Store, <<"alice">>, <<"deadline">>, Ref)),
        WorkerMonitor = erlang:monitor(process, Worker),
        ProviderMonitor = erlang:monitor(process, Provider),
        Manager ! stop,
        await_process_down(WorkerMonitor, Worker),
        await_process_down(ProviderMonitor, Provider)
    after
        stop_process(Worker),
        stop_process(Manager),
        stop_process(Store)
    end.

openapi_broker_bounds() ->
    {ok, Store} = adk_credential_store_ets:start_link(#{name => undefined}),
    unlink(Store),
    Principal = <<"alice">>,
    Provider = <<"api">>,
    {ok, Ref} = adk_credential_store_ets:put(
                  Store, Principal, Provider,
                  #{kind => api_key,
                    api_key => binary:copy(<<"k">>, 16385)}),
    Binding = #{kind => api_key, store_module => adk_credential_store_ets,
                store_handle => Store, principal => Principal,
                provider => Provider, credential_ref => Ref},
    {ok, Broker} = adk_openapi_auth_broker:start_link(
                     #{bindings => #{<<"Key">> => Binding}}),
    unlink(Broker),
    Request = #{operation_id => <<"op">>, scheme_name => <<"Key">>,
                scheme_type => api_key, scopes => [], location => header,
                parameter_name => <<"x-api-key">>},
    try
        ?assertEqual({error, credential_unavailable},
                     adk_openapi_auth_broker:resolve(Broker, Request)),
        ?assertEqual({error, invalid_auth_request},
                     adk_openapi_auth_broker:resolve(
                       Broker,
                       Request#{operation_id => binary:copy(<<"o">>, 257)})),
        ?assertEqual({error, invalid_auth_request},
                     adk_openapi_auth_broker:resolve(
                       Broker,
                       Request#{scopes => [integer_to_binary(I)
                                           || I <- lists:seq(1, 65)]})),
        ?assertEqual({error, invalid_auth_request},
                     adk_openapi_auth_broker:resolve(
                       Broker, Request#{unexpected => true}))
    after
        stop_process(Broker),
        stop_process(Store)
    end,
    ?assertMatch(
       {error, _},
       adk_openapi_auth_broker:start_link(
         #{bindings => #{<<"Key">> => Binding}, timeout_ms => 60001})),
    ?assertMatch(
       {error, _},
       adk_openapi_auth_broker:start_link(
         #{bindings => #{<<"Key">> => Binding}, max_inflight => 1025})),
    ?assertMatch(
       {error, _},
       adk_openapi_auth_broker:start_link(
         #{bindings => #{binary:copy(<<"n">>, 257) => Binding}})).

with_token_runtime(Fun) ->
    {ok, Store} = adk_credential_store_ets:start_link(#{name => undefined}),
    unlink(Store),
    {ok, RefreshSup} = adk_token_refresh_sup:start_link(#{name => undefined}),
    unlink(RefreshSup),
    Profile = #{provider_module => adk_auth_bounds_provider,
                allowed_scopes => [<<"scope">>],
                allowed_audiences => [<<"audience">>]},
    {ok, Manager} = adk_token_manager:start_link(
                      #{name => undefined,
                        store_module => adk_credential_store_ets,
                        store_handle => Store,
                        refresh_sup => RefreshSup,
                        expiry_skew_ms => 0,
                        refresh_timeout_ms => 5000,
                        provider_profiles => #{<<"bounds">> => Profile}}),
    unlink(Manager),
    try Fun(Store, Manager)
    after
        stop_process(Manager),
        stop_process(RefreshSup),
        stop_process(Store)
    end.

token_request(Ref) ->
    #{principal => <<"alice">>, provider => <<"bounds">>,
      credential_ref => Ref, scopes => [<<"scope">>],
      audience => <<"audience">>}.

refresh_manager_init(Parent) ->
    ManagerAlias = erlang:alias([explicit_unalias]),
    Parent ! {refresh_manager_ready, self(), ManagerAlias},
    refresh_manager_loop(Parent).

refresh_manager_loop(Parent) ->
    receive
        stop -> ok;
        Message ->
            Parent ! {refresh_manager_message, self(), Message},
            refresh_manager_loop(Parent)
    end.

wait_until_after(Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond) + 5,
    case Remaining > 0 of
        true -> timer:sleep(Remaining);
        false -> ok
    end.

await_process_down(Monitor, Process) ->
    receive
        {'DOWN', Monitor, process, Process, _Reason} -> ok
    after 1000 ->
        error({process_did_not_follow_owner, Process})
    end.

stop_process(Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        false -> ok;
        true ->
            Monitor = erlang:monitor(process, Pid),
            exit(Pid, shutdown),
            receive
                {'DOWN', Monitor, process, Pid, _Reason} -> ok
            after 1000 -> error({process_did_not_stop, Pid})
            end
    end.
