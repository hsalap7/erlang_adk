-module(adk_auth_rotation_test).

-include_lib("eunit/include/eunit.hrl").

refresh_token_rotation_test_() ->
    [fun credential_store_compare_and_swap_is_scoped/0,
     fun concurrent_compare_and_swap_has_one_winner/0,
     fun token_manager_persists_rotation_without_exposure/0,
     fun concurrent_refresh_rotation_conflict_fails_closed/0,
     fun rotation_store_failure_is_redacted/0,
     fun injected_rotator_is_redacted_from_provider_errors/0].

credential_store_compare_and_swap_is_scoped() ->
    with_private_store(
      fun(Store) ->
          Principal = <<"alice">>,
          Provider = <<"oidc-service">>,
          Expected = refresh_credential(<<"old-refresh-secret">>),
          Replacement = refresh_credential(<<"new-refresh-secret">>),
          {ok, Ref} = adk_credential_store_ets:put(
                        Store, Principal, Provider, Expected),
          ok = adk_credential_store_ets:compare_and_swap(
                 Store, Principal, Provider, Ref, Expected, Replacement),
          ?assertEqual({ok, Replacement},
                       adk_credential_store_ets:fetch(
                         Store, Principal, Provider, Ref)),
          ?assertEqual({error, conflict},
                       adk_credential_store_ets:compare_and_swap(
                         Store, Principal, Provider, Ref,
                         Expected,
                         refresh_credential(<<"stale-overwrite">>))),
          ?assertEqual({error, not_found},
                       adk_credential_store_ets:compare_and_swap(
                         Store, <<"bob">>, Provider, Ref,
                         Replacement,
                         refresh_credential(<<"cross-user">>))),
          assert_absent(<<"new-refresh-secret">>, sys:get_state(Store)),
          assert_absent(<<"new-refresh-secret">>, sys:get_status(Store))
      end).

concurrent_compare_and_swap_has_one_winner() ->
    with_private_store(
      fun(Store) ->
          Principal = <<"alice">>,
          Provider = <<"oidc-service">>,
          Expected = refresh_credential(<<"race-old-secret">>),
          {ok, Ref} = adk_credential_store_ets:put(
                        Store, Principal, Provider, Expected),
          Parent = self(),
          Candidates = [
              refresh_credential(
                <<"race-new-", (integer_to_binary(Index))/binary>>)
              || Index <- lists:seq(1, 24)],
          Callers = [spawn(fun() ->
              receive go ->
                  Result = adk_credential_store_ets:compare_and_swap(
                             Store, Principal, Provider, Ref,
                             Expected, Candidate),
                  Parent ! {cas_result, Result, Candidate}
              end
          end) || Candidate <- Candidates],
          lists:foreach(fun(Pid) -> Pid ! go end, Callers),
          Results = collect_cas_results(length(Callers), []),
          Winners = [Candidate || {ok, Candidate} <- Results],
          Conflicts = [conflict || {{error, conflict}, _} <- Results],
          ?assertEqual(1, length(Winners)),
          ?assertEqual(length(Callers) - 1, length(Conflicts)),
          [Winner] = Winners,
          ?assertEqual({ok, Winner},
                       adk_credential_store_ets:fetch(
                         Store, Principal, Provider, Ref))
      end).

token_manager_persists_rotation_without_exposure() ->
    with_private_store(
      fun(Store) ->
          OldRefresh = <<"manager-old-refresh-secret">>,
          NewRefresh = <<"rotated:agent.run">>,
          Credential = refresh_credential(OldRefresh),
          {ok, Ref} = adk_credential_store_ets:put(
                        Store, <<"alice">>, <<"oidc-service">>, Credential),
          with_token_runtime(
            adk_credential_store_ets, Store,
            fun(Manager, _RefreshSup) ->
                Request = refresh_request(Ref, [<<"agent.run">>]),
                {ok, Token} = Result = adk_token_manager:get_token(
                                         Manager, Request, 1000),
                ?assertEqual(<<"refresh:rotation-client:rotation-subject">>,
                             maps:get(access_token, Token)),
                ?assertEqual(false, maps:is_key(refresh_token, Token)),
                {ok, RotatedCredential} = adk_credential_store_ets:fetch(
                                            Store, <<"alice">>,
                                            <<"oidc-service">>, Ref),
                ?assertEqual(NewRefresh,
                             maps:get(refresh_token, RotatedCredential)),
                assert_absent(OldRefresh, Result),
                assert_absent(NewRefresh, Result),
                assert_absent(OldRefresh, sys:get_state(Manager)),
                assert_absent(NewRefresh, sys:get_state(Manager)),
                assert_absent(OldRefresh, sys:get_status(Manager)),
                assert_absent(NewRefresh, sys:get_status(Manager)),
                assert_absent(NewRefresh, sys:get_status(Store))
            end)
      end).

concurrent_refresh_rotation_conflict_fails_closed() ->
    with_private_store(
      fun(Store) ->
          OldRefresh = <<"rotation-race-old-secret">>,
          Credential = refresh_credential(OldRefresh),
          {ok, Ref} = adk_credential_store_ets:put(
                        Store, <<"alice">>, <<"oidc-service">>, Credential),
          with_token_runtime(
            adk_credential_store_ets, Store,
            fun(Manager, _RefreshSup) ->
                Parent = self(),
                Requests = [refresh_request(Ref, [<<"rotation-race-a">>]),
                            refresh_request(Ref, [<<"rotation-race-b">>])],
                Callers = [spawn(fun() ->
                    receive go ->
                        Parent ! {rotation_result,
                                  adk_token_manager:get_token(
                                    Manager, Request, 2000)}
                    end
                end) || Request <- Requests],
                lists:foreach(fun(Pid) -> Pid ! go end, Callers),
                Results = collect_rotation_results(2, []),
                Successes = [Token || {ok, Token} <- Results],
                Conflicts = [conflict ||
                                {error, credential_rotation_conflict}
                                    <- Results],
                ?assertEqual(1, length(Successes)),
                ?assertEqual(1, length(Conflicts)),
                {ok, Current} = adk_credential_store_ets:fetch(
                                  Store, <<"alice">>, <<"oidc-service">>,
                                  Ref),
                StoredRefresh = maps:get(refresh_token, Current),
                ?assert(lists:member(
                          StoredRefresh,
                          [<<"rotated:rotation-race-a">>,
                           <<"rotated:rotation-race-b">>])),
                lists:foreach(
                  fun(Secret) -> assert_absent(Secret, Results) end,
                  [OldRefresh, <<"rotated:rotation-race-a">>,
                   <<"rotated:rotation-race-b">>])
            end)
      end).

rotation_store_failure_is_redacted() ->
    {ok, Store} = adk_auth_rotation_test_store:start_link(unavailable),
    unlink(Store),
    OldRefresh = <<"failure-old-refresh-secret">>,
    NewRefresh = <<"rotated:agent.run">>,
    Credential = refresh_credential(OldRefresh),
    {ok, Ref} = adk_auth_rotation_test_store:put(
                  Store, <<"alice">>, <<"oidc-service">>, Credential),
    try
        with_token_runtime(
          adk_auth_rotation_test_store, Store,
          fun(Manager, _RefreshSup) ->
              Result = adk_token_manager:get_token(
                         Manager, refresh_request(Ref, [<<"agent.run">>]),
                         1000),
              ?assertEqual({error, credential_rotation_failed}, Result),
              ?assertEqual({ok, Credential},
                           adk_auth_rotation_test_store:fetch(
                             Store, <<"alice">>, <<"oidc-service">>, Ref)),
              assert_absent(OldRefresh, Result),
              assert_absent(NewRefresh, Result),
              assert_absent(OldRefresh, sys:get_status(Manager)),
              assert_absent(NewRefresh, sys:get_status(Manager)),
              assert_absent(OldRefresh, sys:get_status(Store)),
              assert_absent(NewRefresh, sys:get_status(Store))
          end)
    after
        stop_process(Store)
    end.

injected_rotator_is_redacted_from_provider_errors() ->
    with_private_store(
      fun(Store) ->
          Secret = <<"echo-provider-refresh-secret">>,
          Credential = refresh_credential(Secret),
          {ok, Ref} = adk_credential_store_ets:put(
                        Store, <<"alice">>, <<"oidc-service">>, Credential),
          with_token_runtime(
            adk_credential_store_ets, Store,
            fun(Manager, _RefreshSup) ->
                Request = (refresh_request(Ref, [<<"agent.run">>]))#{
                            provider_module => adk_auth_context_echo_provider},
                {error, {provider_error, Reason}} = Result =
                    adk_token_manager:get_token(Manager, Request, 1000),
                ?assertEqual(adk_secret_redactor:marker(),
                             maps:get(credential_rotator, Reason)),
                assert_absent(Secret, Result),
                assert_absent(Secret, sys:get_status(Manager))
            end)
      end).

refresh_credential(RefreshToken) ->
    #{kind => oauth_refresh_token,
      client_id => <<"rotation-client">>,
      client_secret => <<"rotation-client-secret">>,
      refresh_token => RefreshToken,
      expected_subject => <<"rotation-subject">>}.

refresh_request(Ref, Scopes) ->
    #{principal => <<"alice">>,
      provider => <<"oidc-service">>,
      provider_module => adk_auth_provider_oidcc,
      credential_ref => Ref,
      scopes => Scopes,
      context => #{provider_worker => oidc_fixture_provider,
                   oauth_adapter => adk_oidc_fake_oauth_adapter}}.

with_private_store(Fun) ->
    {ok, Store} = adk_credential_store_ets:start_link(#{name => undefined}),
    unlink(Store),
    try Fun(Store)
    after stop_process(Store)
    end.

with_token_runtime(StoreModule, StoreHandle, Fun) ->
    {ok, RefreshSup} = adk_token_refresh_sup:start_link(#{name => undefined}),
    unlink(RefreshSup),
    {ok, Manager} = adk_token_manager:start_link(
                      #{name => undefined,
                        store_module => StoreModule,
                        store_handle => StoreHandle,
                        refresh_sup => RefreshSup,
                        expiry_skew_ms => 0,
                        refresh_timeout_ms => 1000}),
    unlink(Manager),
    try Fun(Manager, RefreshSup)
    after
        stop_process(Manager),
        stop_process(RefreshSup)
    end.

collect_cas_results(0, Acc) -> Acc;
collect_cas_results(Remaining, Acc) ->
    receive
        {cas_result, Result, Candidate} ->
            collect_cas_results(Remaining - 1,
                                [{Result, Candidate} | Acc])
    after 2000 ->
        error({missing_cas_results, Remaining})
    end.

collect_rotation_results(0, Acc) -> Acc;
collect_rotation_results(Remaining, Acc) ->
    receive
        {rotation_result, Result} ->
            collect_rotation_results(Remaining - 1, [Result | Acc])
    after 3000 ->
        error({missing_rotation_results, Remaining})
    end.

stop_process(Process) when is_pid(Process) ->
    case erlang:is_process_alive(Process) of
        false -> ok;
        true ->
            Monitor = erlang:monitor(process, Process),
            exit(Process, shutdown),
            receive
                {'DOWN', Monitor, process, Process, _Reason} -> ok
            after 1000 ->
                error({process_did_not_stop, Process})
            end
    end.

assert_absent(Secret, Term) ->
    ?assertEqual(nomatch, binary:match(term_to_binary(Term), Secret)).
