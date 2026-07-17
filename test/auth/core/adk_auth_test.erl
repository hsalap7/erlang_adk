-module(adk_auth_test).

-include_lib("eunit/include/eunit.hrl").

-define(STORE, adk_auth_test_store).
-define(REFRESH_SUP, adk_auth_test_refresh_sup).
-define(MANAGER, adk_auth_test_token_manager).
-define(EXCHANGE_SUP, adk_auth_test_authorization_exchange_sup).
-define(FLOW, adk_auth_test_authorization_flow).

auth_foundation_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun(Env) -> fun() -> concurrent_refresh_is_single_flight(Env) end end,
      fun(Env) -> fun() -> expiry_skew_is_deterministic(Env) end end,
      fun(Env) -> fun() -> credentials_are_isolated_by_principal(Env) end end,
      fun(Env) -> fun() -> provider_failure_is_redacted(Env) end end,
      fun(Env) -> fun() -> provider_exception_is_redacted(Env) end end,
      fun(Env) -> fun() -> invalid_provider_token_is_not_exposed(Env) end end,
      fun(Env) -> fun() -> provider_timeout_is_bounded(Env) end end,
      fun(Env) -> fun() -> queued_late_result_is_not_installed(Env) end end,
      fun(Env) -> fun() -> caller_timeout_cancels_orphan_refresh(Env) end end,
      fun(Env) -> fun() -> secrets_and_tokens_are_not_in_server_state(Env) end end,
      fun(Env) -> fun() -> malformed_scope_list_fails_closed(Env) end end,
      fun(Env) -> fun() -> recursive_seeded_redaction(Env) end end]}.

provider_profile_security_test_() ->
    [fun empty_profiles_fail_closed/0,
     fun provider_profile_is_authoritative/0,
     fun cache_inflight_waiter_bounds_and_invalidation/0,
     fun request_context_is_rejected_for_production_provider/0].

setup() ->
    Clock = ets:new(adk_auth_test_clock, [set, public]),
    Counter = ets:new(adk_auth_test_counter, [set, public]),
    true = ets:insert(Clock, {now, 0}),
    true = ets:insert(Counter, {refreshes, 0}),
    NowFun = fun() -> ets:lookup_element(Clock, now, 2) end,
    Opts = #{name => undefined,
             credential_store_name => ?STORE,
             refresh_sup_name => ?REFRESH_SUP,
             token_manager_name => ?MANAGER,
             authorization_exchange_sup_name => ?EXCHANGE_SUP,
             authorization_flow_name => ?FLOW,
             token_manager_opts => #{expiry_skew_ms => 100,
                                     refresh_timeout_ms => 80,
                                     provider_profiles =>
                                         #{<<"gemini">> =>
                                               #{provider_module =>
                                                     adk_auth_fake_provider,
                                                 allowed_scopes =>
                                                     [<<"models.generate">>],
                                                 allowed_audiences =>
                                                     [<<"gemini-api">>],
                                                 allow_request_context =>
                                                     true}},
                                     now_fun => NowFun}},
    {ok, Supervisor} = adk_auth_sup:start_link(Opts),
    unlink(Supervisor),
    #{supervisor => Supervisor, clock => Clock, counter => Counter}.

cleanup(#{supervisor := Supervisor, clock := Clock, counter := Counter}) ->
    Monitor = erlang:monitor(process, Supervisor),
    exit(Supervisor, shutdown),
    receive
        {'DOWN', Monitor, process, Supervisor, _Reason} -> ok
    after 1000 ->
        error(auth_supervisor_did_not_stop)
    end,
    true = ets:delete(Clock),
    true = ets:delete(Counter).

concurrent_refresh_is_single_flight(Env) ->
    Ref = put_credential(<<"alice-token">>, <<"single-flight-secret">>),
    Request = request(<<"alice">>, Ref, Env,
                      #{delay_ms => 40, ttl_ms => 1000}),
    Parent = self(),
    Callers = [spawn(fun() ->
        receive go ->
            Parent ! {token_result,
                      adk_token_manager:get_token(?MANAGER, Request, 1000)}
        end
    end) || _ <- lists:seq(1, 32)],
    lists:foreach(fun(Pid) -> Pid ! go end, Callers),
    Results = collect_results(length(Callers), []),
    ?assertEqual(1, length(lists:usort(Results))),
    ?assertMatch([{ok, #{access_token := <<"alice-token-1">>}} | _],
                 Results),
    ?assertEqual(1, refresh_count(Env)).

expiry_skew_is_deterministic(Env = #{clock := Clock}) ->
    Ref = put_credential(<<"expiry-token">>, <<"expiry-secret">>),
    Request = request(<<"alice">>, Ref, Env, #{ttl_ms => 1000}),
    {ok, #{access_token := <<"expiry-token-1">>}} =
        adk_token_manager:get_token(?MANAGER, Request, 1000),
    true = ets:insert(Clock, {now, 899}),
    {ok, #{access_token := <<"expiry-token-1">>}} =
        adk_token_manager:get_token(?MANAGER, Request, 1000),
    ?assertEqual(1, refresh_count(Env)),
    true = ets:insert(Clock, {now, 900}),
    {ok, #{access_token := <<"expiry-token-2">>}} =
        adk_token_manager:get_token(?MANAGER, Request, 1000),
    ?assertEqual(2, refresh_count(Env)).

credentials_are_isolated_by_principal(Env) ->
    {ok, AliceRef} = adk_credential_store_ets:put(
                       ?STORE, <<"alice">>, <<"gemini">>,
                       #{token_prefix => <<"alice">>,
                         client_secret => <<"alice-secret">>}),
    {ok, BobRef} = adk_credential_store_ets:put(
                     ?STORE, <<"bob">>, <<"gemini">>,
                     #{token_prefix => <<"bob">>,
                       client_secret => <<"bob-secret">>}),
    {ok, #{access_token := <<"alice-1">>}} =
        adk_token_manager:get_token(
          ?MANAGER, request(<<"alice">>, AliceRef, Env, #{}), 1000),
    {ok, #{access_token := <<"bob-2">>}} =
        adk_token_manager:get_token(
          ?MANAGER, request(<<"bob">>, BobRef, Env, #{}), 1000),
    ?assertEqual(
       {error, credential_not_found},
       adk_token_manager:get_token(
         ?MANAGER, request(<<"bob">>, AliceRef, Env, #{}), 1000)),
    ?assertEqual(2, refresh_count(Env)).

provider_failure_is_redacted(Env) ->
    Secret = <<"seeded-provider-secret-71f2">>,
    Ref = put_credential(<<"failure-token">>, Secret),
    Request = request(<<"alice">>, Ref, Env, #{mode => failure}),
    {error, {provider_error, Redacted}} =
        adk_token_manager:get_token(?MANAGER, Request, 1000),
    assert_absent(Secret, Redacted),
    ?assertNotEqual(nomatch,
                    binary:match(term_to_binary(Redacted),
                                 adk_secret_redactor:marker())).

provider_exception_is_redacted(Env) ->
    Secret = <<"seeded-exception-secret-82a3">>,
    Ref = put_credential(<<"exception-token">>, Secret),
    Request = request(<<"alice">>, Ref, Env, #{mode => exception}),
    {error, {provider_exception, error, Redacted}} =
        adk_token_manager:get_token(?MANAGER, Request, 1000),
    assert_absent(Secret, Redacted).

invalid_provider_token_is_not_exposed(Env) ->
    Secret = <<"invalid-response-secret-93b4">>,
    Ref = put_credential(<<"invalid-token">>, Secret),
    Request = request(<<"alice">>, Ref, Env, #{mode => invalid}),
    ?assertEqual({error, invalid_provider_response},
                 adk_token_manager:get_token(?MANAGER, Request, 1000)),
    assert_absent(Secret, sys:get_state(?MANAGER)),
    assert_absent(Secret, sys:get_status(?MANAGER)).

provider_timeout_is_bounded(Env) ->
    Ref = put_credential(<<"timeout-token">>, <<"timeout-secret">>),
    Request = request(<<"alice">>, Ref, Env, #{delay_ms => 500}),
    StartedAt = erlang:monotonic_time(millisecond),
    ?assertEqual({error, refresh_timeout},
                 adk_token_manager:get_token(?MANAGER, Request, 1000)),
    Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
    ?assert(Elapsed < 400),
    ok = wait_for_no_refresh_children(500),
    ?assertEqual(1, refresh_count(Env)).

queued_late_result_is_not_installed(Env) ->
    Ref = put_credential(<<"queued-late-token">>, <<"queued-late-secret">>),
    Request = request(<<"alice">>, Ref, Env,
                      #{delay_ms => 40, ttl_ms => 1000, notify => self()}),
    Parent = self(),
    _Caller = spawn(fun() ->
        Parent ! {queued_late_result,
                  adk_token_manager:get_token(?MANAGER, Request, 1000)}
    end),
    receive
        {fake_provider_started, _ProviderPid, 1} -> ok
    after 1000 ->
        error(queued_late_provider_did_not_start)
    end,
    [{Generation, Worker, worker, [adk_token_refresh_worker]}] =
        supervisor:which_children(?REFRESH_SUP),
    {state, _Manager, Generation, _ManagerMonitor, _Provider,
     _ProviderAlias, ResultAlias, Deadline} = sys:get_state(Worker),
    _ = erlang:send(
          ResultAlias,
          {ResultAlias, auth_refresh_result, Generation, Worker,
           Deadline + 1,
           {ok, #{access_token => <<"must-not-be-cached">>,
                  token_type => <<"Bearer">>, expires_in_ms => 60000}}},
          [noconnect, nosuspend]),
    receive
        {queued_late_result, Result} ->
            ?assertEqual({error, refresh_timeout}, Result)
    after 1000 ->
        error(missing_queued_late_result)
    end,
    ok = wait_for_no_refresh_children(500),
    ?assertEqual(1, refresh_count(Env)),
    Immediate = request(<<"alice">>, Ref, Env,
                        #{delay_ms => 0, ttl_ms => 1000}),
    ?assertEqual(
       {ok, #{access_token => <<"queued-late-token-2">>,
              token_type => <<"Bearer">>}},
       adk_token_manager:get_token(?MANAGER, Immediate, 1000)),
    ?assertEqual(2, refresh_count(Env)).

caller_timeout_cancels_orphan_refresh(Env) ->
    Ref = put_credential(<<"orphan-token">>, <<"orphan-secret">>),
    Request = request(<<"alice">>, Ref, Env, #{delay_ms => 500}),
    ?assertEqual({error, caller_timeout},
                 adk_token_manager:get_token(?MANAGER, Request, 10)),
    ok = wait_for_no_refresh_children(500),
    ?assertEqual(1, refresh_count(Env)).

secrets_and_tokens_are_not_in_server_state(Env) ->
    Secret = <<"private-credential-secret-fb4c">>,
    Ref = put_credential(<<"private-access-token">>, Secret),
    Request = request(<<"alice">>, Ref, Env, #{}),
    {ok, #{access_token := AccessToken}} =
        adk_token_manager:get_token(?MANAGER, Request, 1000),
    StoreState = sys:get_state(?STORE),
    ManagerState = sys:get_state(?MANAGER),
    assert_absent(Secret, StoreState),
    assert_absent(Secret, ManagerState),
    assert_absent(AccessToken, ManagerState),
    assert_absent(Secret, sys:get_status(?STORE)),
    assert_absent(Secret, sys:get_status(?MANAGER)),
    assert_absent(AccessToken, sys:get_status(?MANAGER)),
    StoreTable = element(2, StoreState),
    ?assertEqual(private, ets:info(StoreTable, protection)),
    ?assertError(badarg, ets:tab2list(StoreTable)),
    ManagerTables = [Value || Value <- tuple_to_list(ManagerState),
                              is_reference(Value),
                              ets:info(Value, protection) =:= private],
    ?assertEqual(2, length(ManagerTables)),
    lists:foreach(fun(Table) ->
        ?assertError(badarg, ets:tab2list(Table))
    end, ManagerTables).

malformed_scope_list_fails_closed(Env) ->
    Ref = put_credential(<<"malformed-token">>, <<"malformed-secret">>),
    Request = (request(<<"alice">>, Ref, Env, #{}))#{
                scopes => [<<"models.generate">> | improper_tail]},
    ?assertEqual({error, invalid_request},
                 adk_token_manager:get_token(?MANAGER, Request, 1000)),
    ?assert(erlang:is_process_alive(whereis(?MANAGER))),
    ?assertEqual(0, refresh_count(Env)).

recursive_seeded_redaction(_Env) ->
    Secret = <<"recursive-secret-26de">>,
    Input = #{client_secret => Secret,
              nested => [
                {<<"Authorization">>, <<"Bearer ", Secret/binary>>},
                {url, <<"https://user:", Secret/binary,
                        "@auth.invalid/path?api-key=", Secret/binary>>},
                {tuple, {ok, <<"failure: ", Secret/binary>>}},
                #{<<"Set-Cookie">> => <<"sid=", Secret/binary>>}]},
    Redacted = adk_secret_redactor:redact(Input, [Secret]),
    assert_absent(Secret, Redacted),
    ?assertNotEqual(nomatch,
                    binary:match(term_to_binary(Redacted),
                                 adk_secret_redactor:marker())).

empty_profiles_fail_closed() ->
    with_profile_runtime(
      #{}, #{},
      fun(Store, Manager, _RefreshSup) ->
          {ok, Ref} = adk_credential_store_ets:put(
                        Store, <<"alice">>, <<"unconfigured">>,
                        #{token_prefix => <<"unused">>,
                          client_secret => <<"unused-secret">>}),
          Request = #{principal => <<"alice">>,
                      provider => <<"unconfigured">>,
                      credential_ref => Ref,
                      scopes => [],
                      audience => undefined},
          ?assertEqual({error, unknown_provider},
                       adk_token_manager:get_token(Manager, Request, 1000))
      end).

provider_profile_is_authoritative() ->
    Counter = ets:new(adk_auth_profile_counter, [set, public]),
    true = ets:insert(Counter, {refreshes, 0}),
    Profile = #{provider_module => adk_auth_fake_provider,
                context => #{counter => Counter, mode => success,
                             ttl_ms => 60000},
                allowed_scopes => [<<"models.generate">>],
                allowed_audiences => [<<"gemini-api">>]},
    try
        with_profile_runtime(
          #{<<"gemini">> => Profile}, #{},
          fun(Store, Manager, _RefreshSup) ->
              {ok, Ref} = adk_credential_store_ets:put(
                            Store, <<"alice">>, <<"gemini">>,
                            #{token_prefix => <<"profile-token">>,
                              client_secret => <<"profile-secret">>}),
              Request = #{principal => <<"alice">>,
                          provider => <<"gemini">>,
                          credential_ref => Ref,
                          scopes => [<<"models.generate">>],
                          audience => <<"gemini-api">>,
                          %% Legacy caller choices are deliberately hostile;
                          %% neither is used by the manager.
                          provider_module =>
                              adk_auth_context_echo_provider,
                          context => #{mode => exception,
                                       resource =>
                                           <<"https://attacker.example">>}},
              ?assertEqual(
                 {ok, #{access_token => <<"profile-token-1">>,
                        token_type => <<"Bearer">>}},
                 adk_token_manager:get_token(Manager, Request, 1000)),
              ?assertEqual(
                 {error, scope_not_allowed},
                 adk_token_manager:get_token(
                   Manager, Request#{scopes => [<<"admin">>]}, 1000)),
              ?assertEqual(
                 {error, audience_not_allowed},
                 adk_token_manager:get_token(
                   Manager, Request#{audience => <<"attacker-api">>},
                   1000)),
              ?assertEqual(
                 {error, unknown_provider},
                 adk_token_manager:get_token(
                   Manager, Request#{provider => <<"unknown">>}, 1000)),
              ?assertEqual(1, ets:lookup_element(Counter, refreshes, 2))
          end)
    after
        true = ets:delete(Counter)
    end.

cache_inflight_waiter_bounds_and_invalidation() ->
    Counter = ets:new(adk_auth_bounds_counter, [set, public]),
    true = ets:insert(Counter, {refreshes, 0}),
    Parent = self(),
    Profile = #{provider_module => adk_auth_fake_provider,
                context => #{counter => Counter, mode => success,
                             ttl_ms => 60000, delay_ms => 100,
                             notify => Parent},
                allowed_scopes => [<<"models.generate">>],
                allowed_audiences => [<<"gemini-api">>]},
    try
        with_profile_runtime(
          #{<<"gemini">> => Profile},
          #{max_cache_entries => 1,
            max_inflight_refreshes => 1,
            max_waiters_per_refresh => 1},
          fun(Store, Manager, RefreshSup) ->
              {ok, RefA} = adk_credential_store_ets:put(
                             Store, <<"alice">>, <<"gemini">>,
                             #{token_prefix => <<"bounded-a">>,
                               client_secret => <<"bounded-secret-a">>}),
              {ok, RefB} = adk_credential_store_ets:put(
                             Store, <<"alice">>, <<"gemini">>,
                             #{token_prefix => <<"bounded-b">>,
                               client_secret => <<"bounded-secret-b">>}),
              RequestA = profile_request(RefA),
              RequestB = profile_request(RefB),
              _Caller = spawn(fun() ->
                  Parent ! {bounded_result,
                            adk_token_manager:get_token(
                              Manager, RequestA, 2000)}
              end),
              receive
                  {fake_provider_started, _ProviderPid, 1} -> ok
              after 1000 -> error(bounded_refresh_did_not_start)
              end,
              ?assertEqual(
                 {error, waiter_capacity_reached},
                 adk_token_manager:get_token(Manager, RequestA, 1000)),
              ?assertEqual(
                 {error, refresh_capacity_reached},
                 adk_token_manager:get_token(Manager, RequestB, 1000)),
              receive
                  {bounded_result, FirstResult} ->
                      ?assertEqual(
                         {ok, #{access_token => <<"bounded-a-1">>,
                                token_type => <<"Bearer">>}},
                         FirstResult)
              after 2000 -> error(missing_bounded_refresh_result)
              end,
              ?assertEqual(
                 {ok, #{access_token => <<"bounded-b-2">>,
                        token_type => <<"Bearer">>}},
                 adk_token_manager:get_token(Manager, RequestB, 2000)),
              %% Two successful grants with a one-entry cache leave exactly
              %% one matching entry to invalidate.
              ?assertEqual(
                 {ok, 1},
                 adk_token_manager:invalidate(
                   Manager, #{principal => <<"alice">>,
                              provider => <<"gemini">>,
                              credential_ref => RefB})),
              ?assertEqual(
                 {ok, #{access_token => <<"bounded-b-3">>,
                        token_type => <<"Bearer">>}},
                 adk_token_manager:get_token(Manager, RequestB, 2000)),
              ?assertEqual(
                 {ok, 1},
                 adk_token_manager:invalidate(
                   Manager, #{principal => <<"alice">>,
                              provider => <<"gemini">>,
                              credential_ref => RefB})),
              _CancelCaller = spawn(fun() ->
                  Parent ! {cancelled_bounded_result,
                            adk_token_manager:get_token(
                              Manager, RequestB, 2000)}
              end),
              receive
                  {fake_provider_started, _CancelProviderPid, 4} -> ok
              after 1000 -> error(cancellable_refresh_did_not_start)
              end,
              ?assertEqual(
                 {ok, 1},
                 adk_token_manager:invalidate(
                   Manager, #{principal => <<"alice">>,
                              provider => <<"gemini">>,
                              credential_ref => RefB})),
              receive
                  {cancelled_bounded_result, CancelledResult} ->
                      ?assertEqual({error, token_invalidated},
                                   CancelledResult)
              after 1000 -> error(missing_cancelled_refresh_result)
              end,
              ?assertEqual([], supervisor:which_children(RefreshSup)),
              ?assertEqual(
                 {error, invalid_request},
                 adk_token_manager:invalidate(
                   Manager, #{principal => <<"alice">>,
                              provider => <<"gemini">>, extra => true}))
          end)
    after
        true = ets:delete(Counter)
    end.

request_context_is_rejected_for_production_provider() ->
    {ok, Store} = adk_credential_store_ets:start_link(#{name => undefined}),
    unlink(Store),
    {ok, RefreshSup} = adk_token_refresh_sup:start_link(#{name => undefined}),
    unlink(RefreshSup),
    PreviousTrapExit = process_flag(trap_exit, true),
    try
        Result = adk_token_manager:start_link(
                   #{name => undefined,
                     store_module => adk_credential_store_ets,
                     store_handle => Store,
                     refresh_sup => RefreshSup,
                     provider_profiles =>
                         #{<<"oidc">> =>
                               #{provider_module => adk_auth_provider_oidcc,
                                 allowed_scopes => [],
                                 allowed_audiences => [],
                                 allow_request_context => true}}}),
        ?assertMatch({error, _}, Result)
    after
        receive
            {'EXIT', _FailedManager, _Reason} -> ok
        after 0 -> ok
        end,
        _ = process_flag(trap_exit, PreviousTrapExit),
        stop_process(Store),
        stop_process(RefreshSup)
    end.

profile_request(Ref) ->
    #{principal => <<"alice">>,
      provider => <<"gemini">>,
      credential_ref => Ref,
      scopes => [<<"models.generate">>],
      audience => <<"gemini-api">>}.

with_profile_runtime(Profiles, ExtraManagerOpts, Fun) ->
    {ok, Store} = adk_credential_store_ets:start_link(#{name => undefined}),
    unlink(Store),
    {ok, RefreshSup} = adk_token_refresh_sup:start_link(#{name => undefined}),
    unlink(RefreshSup),
    ManagerOpts = maps:merge(
                    #{name => undefined,
                      store_module => adk_credential_store_ets,
                      store_handle => Store,
                      refresh_sup => RefreshSup,
                      expiry_skew_ms => 0,
                      refresh_timeout_ms => 1000,
                      provider_profiles => Profiles},
                    ExtraManagerOpts),
    {ok, Manager} = adk_token_manager:start_link(ManagerOpts),
    unlink(Manager),
    try Fun(Store, Manager, RefreshSup)
    after
        stop_process(Manager),
        stop_process(RefreshSup),
        stop_process(Store)
    end.

stop_process(Process) when is_pid(Process) ->
    case erlang:is_process_alive(Process) of
        false -> ok;
        true ->
            Monitor = erlang:monitor(process, Process),
            exit(Process, shutdown),
            receive
                {'DOWN', Monitor, process, Process, _Reason} -> ok
            after 1000 -> error({process_did_not_stop, Process})
            end
    end.

put_credential(TokenPrefix, Secret) ->
    {ok, Ref} = adk_credential_store_ets:put(
                  ?STORE, <<"alice">>, <<"gemini">>,
                  #{token_prefix => TokenPrefix, client_secret => Secret}),
    Ref.

request(Principal, Ref, #{counter := Counter}, Overrides) ->
    BaseContext = #{counter => Counter, mode => success, ttl_ms => 1000},
    Context = maps:merge(BaseContext, Overrides),
    #{principal => Principal,
      provider => <<"gemini">>,
      credential_ref => Ref,
      scopes => [<<"models.generate">>],
      audience => <<"gemini-api">>,
      context => Context}.

refresh_count(#{counter := Counter}) ->
    ets:lookup_element(Counter, refreshes, 2).

collect_results(0, Acc) -> Acc;
collect_results(Remaining, Acc) ->
    receive
        {token_result, Result} ->
            collect_results(Remaining - 1, [Result | Acc])
    after 2000 ->
        error({missing_token_results, Remaining})
    end.

wait_for_no_refresh_children(Remaining) when Remaining =< 0 ->
    case supervisor:which_children(?REFRESH_SUP) of
        [] -> ok;
        Children -> error({refresh_children_still_running, Children})
    end;
wait_for_no_refresh_children(Remaining) ->
    case supervisor:which_children(?REFRESH_SUP) of
        [] -> ok;
        _ ->
            timer:sleep(10),
            wait_for_no_refresh_children(Remaining - 10)
    end.

assert_absent(Secret, Term) ->
    ?assertEqual(nomatch, binary:match(term_to_binary(Term), Secret)).
