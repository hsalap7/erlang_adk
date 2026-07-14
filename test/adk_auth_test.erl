-module(adk_auth_test).

-include_lib("eunit/include/eunit.hrl").

-define(STORE, adk_auth_test_store).
-define(REFRESH_SUP, adk_auth_test_refresh_sup).
-define(MANAGER, adk_auth_test_token_manager).

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
      fun(Env) -> fun() -> caller_timeout_cancels_orphan_refresh(Env) end end,
      fun(Env) -> fun() -> secrets_and_tokens_are_not_in_server_state(Env) end end,
      fun(Env) -> fun() -> malformed_scope_list_fails_closed(Env) end end,
      fun(Env) -> fun() -> recursive_seeded_redaction(Env) end end]}.

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
             token_manager_opts => #{expiry_skew_ms => 100,
                                     refresh_timeout_ms => 80,
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
      provider_module => adk_auth_fake_provider,
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
