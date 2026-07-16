-module(adk_authorization_flow_test).

-export([profiles/0]).

-include_lib("eunit/include/eunit.hrl").

-define(STORE, adk_authorization_flow_test_store).
-define(REFRESH_SUP, adk_authorization_flow_test_refresh_sup).
-define(TOKEN_MANAGER, adk_authorization_flow_test_token_manager).
-define(EXCHANGE_SUP, adk_authorization_flow_test_exchange_sup).
-define(FLOW, adk_authorization_flow_test_manager).
-define(RESOURCE, <<"https://resource.example/agents">>).

authorization_flow_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun(Env) -> fun() -> successful_flow_is_suspension_compatible(Env) end end,
      fun(Env) -> fun() -> callback_claim_is_atomic_and_one_time(Env) end end,
      fun(Env) -> fun() -> provider_mixup_and_missing_subject_fail_closed(Env) end end,
      fun(Env) -> fun() -> expiry_deletes_pending_credential(Env) end end,
      fun(Env) -> fun() -> capacity_cancel_and_request_authority(Env) end end,
      fun(Env) -> fun() -> status_and_failures_are_redacted(Env) end end,
      fun(Env) -> fun() -> inflight_cancel_is_terminal(Env) end end,
      fun(Env) -> fun() -> authorization_uri_callbacks_are_isolated(Env) end end,
      fun(Env) -> fun() -> exchange_callbacks_are_isolated(Env) end end,
      fun(Env) -> fun() -> configuration_and_token_sizes_are_bounded(Env) end end]}.

setup() ->
    Clock = ets:new(adk_authorization_flow_clock, [set, public]),
    true = ets:insert(Clock, {now, 1000}),
    NowFun = fun() -> ets:lookup_element(Clock, now, 2) end,
    Opts = #{name => undefined,
             credential_store_name => ?STORE,
             refresh_sup_name => ?REFRESH_SUP,
             token_manager_name => ?TOKEN_MANAGER,
             authorization_exchange_sup_name => ?EXCHANGE_SUP,
             authorization_flow_name => ?FLOW,
             authorization_profile_loader => {?MODULE, profiles},
             authorization_flow_opts =>
                 #{max_pending_flows => 2,
                   default_lifetime_ms => 100,
                   exchange_timeout_ms => 1000,
                   sweep_interval_ms => 10,
                   now_fun => NowFun}},
    {ok, Supervisor} = adk_auth_sup:start_link(Opts),
    unlink(Supervisor),
    #{supervisor => Supervisor, clock => Clock}.

profiles() ->
    #{<<"provider-a">> => profile(<<"a">>, <<"secret-a-71f2">>, 0),
      <<"provider-b">> => profile(<<"b">>, <<"secret-b-82e3">>, 0),
      <<"provider-slow">> =>
          profile(<<"slow">>, <<"secret-slow-93d4">>, 150)}.

cleanup(#{supervisor := Supervisor, clock := Clock}) ->
    Monitor = erlang:monitor(process, Supervisor),
    exit(Supervisor, shutdown),
    receive
        {'DOWN', Monitor, process, Supervisor, _Reason} -> ok
    after 1000 ->
        error(auth_supervisor_did_not_stop)
    end,
    true = ets:delete(Clock).

profile(Marker, Secret, Delay) ->
    #{adapter_module => adk_authorization_flow_fake_adapter,
      adapter_context => #{marker => Marker,
                           client_id => <<"client-", Marker/binary>>,
                           client_secret => Secret,
                           delay_ms => Delay},
      redirect_uri => <<"https://app.example/oauth/callback">>,
      allowed_scopes => [<<"openid">>, <<"agents.run">>],
      default_scopes => [<<"openid">>, <<"agents.run">>],
      resource => ?RESOURCE,
      lifetime_ms => 100,
      prompt => <<"Sign in to run this agent.">>}.

successful_flow_is_suspension_compatible(_Env) ->
    Principal = <<"oidc_issuer_bound_local_alice">>,
    ProviderSubject = <<"google-sub-alice-4421">>,
    {ok, Request} = begin_flow(Principal, <<"provider-a">>),
    assert_public_request(Request),
    State = maps:get(<<"correlation_id">>, Request),
    Ref = maps:get(<<"credential_flow_ref">>, Request),
    AuthorizationUri = maps:get(<<"authorization_uri">>, Request),
    ?assertEqual(nomatch, binary:match(AuthorizationUri,
                                      <<"secret-a-71f2">>)),
    ?assertEqual(nomatch, binary:match(AuthorizationUri,
                                      <<"code_verifier">>)),
    Details = adk_suspension:pause_details(
                {credential_required, Request}),
    ?assertMatch(#{<<"type">> := <<"credential_request">>}, Details),
    {ok, Response} = adk_authorization_flow:complete(
                       ?FLOW, State,
                       <<"code:a:", ProviderSubject/binary>>),
    ?assertEqual(Ref, maps:get(<<"credential_ref">>, Response)),
    ?assertEqual(
       {ok, Response},
       adk_suspension:validate_resume(
         Details, Response, {adk_credential_store_ets, ?STORE}, Principal)),
    {ok, Credential} = adk_credential_store_ets:fetch(
                         ?STORE, Principal, <<"provider-a">>, Ref),
    ?assertEqual(oauth_refresh_token, maps:get(kind, Credential)),
    ?assertEqual(ProviderSubject, maps:get(expected_subject, Credential)),
    ?assertNotEqual(Principal, maps:get(expected_subject, Credential)),
    ?assertEqual(<<"refresh:a:", ProviderSubject/binary>>,
                 maps:get(refresh_token, Credential)),
    ?assertNot(maps:is_key(code_verifier, Credential)),
    ?assertEqual({error, invalid_or_expired_state},
                 adk_authorization_flow:complete(
                   ?FLOW, State, <<"code:a:", ProviderSubject/binary>>)).

callback_claim_is_atomic_and_one_time(_Env) ->
    Principal = <<"subject-race">>,
    ProviderSubject = <<"provider-subject-race">>,
    {ok, Request} = begin_flow(Principal, <<"provider-slow">>),
    State = maps:get(<<"correlation_id">>, Request),
    Code = <<"code:slow:", ProviderSubject/binary>>,
    Parent = self(),
    Callers = [spawn(fun() ->
                         Parent ! {callback_result,
                                   adk_authorization_flow:complete(
                                     ?FLOW, State, Code, 2000)}
                     end) || _ <- lists:seq(1, 16)],
    ?assertEqual(16, length(Callers)),
    Results = collect_results(16, []),
    Successes = [Result || Result = {ok, _} <- Results],
    Replays = [Result || Result = {error, invalid_or_expired_state}
                           <- Results],
    ?assertEqual(1, length(Successes)),
    ?assertEqual(15, length(Replays)).

provider_mixup_and_missing_subject_fail_closed(_Env) ->
    Principal = <<"subject-mixup">>,
    {ok, RequestA} = begin_flow(Principal, <<"provider-a">>),
    StateA = maps:get(<<"correlation_id">>, RequestA),
    RefA = maps:get(<<"credential_flow_ref">>, RequestA),
    ?assertEqual({error, authorization_failed},
                 adk_authorization_flow:complete(
                   ?FLOW, StateA,
                   <<"code:b:provider-subject">>)),
    ?assertEqual({error, not_found},
                 adk_credential_store_ets:fetch(
                   ?STORE, Principal, <<"provider-a">>, RefA)),
    {ok, RequestB} = begin_flow(Principal, <<"provider-b">>),
    StateB = maps:get(<<"correlation_id">>, RequestB),
    ?assertEqual({error, authorization_failed},
                 adk_authorization_flow:complete(
                   ?FLOW, StateB, <<"code:b:missing-sub">>)),
    {ok, RequestB2} = begin_flow(Principal, <<"provider-b">>),
    StateB2 = maps:get(<<"correlation_id">>, RequestB2),
    ?assertEqual({error, authorization_failed},
                 adk_authorization_flow:complete(
                   ?FLOW, StateB2, <<"code:b:invalid-sub">>)).

expiry_deletes_pending_credential(#{clock := Clock}) ->
    Principal = <<"subject-expired">>,
    {ok, Request} = begin_flow(Principal, <<"provider-a">>),
    State = maps:get(<<"correlation_id">>, Request),
    Ref = maps:get(<<"credential_flow_ref">>, Request),
    true = ets:insert(Clock, {now, 1101}),
    ?assertEqual({error, invalid_or_expired_state},
                 adk_authorization_flow:complete(
                   ?FLOW, State, <<"code:a:", Principal/binary>>)),
    ?assertEqual({error, not_found},
                 adk_credential_store_ets:fetch(
                   ?STORE, Principal, <<"provider-a">>, Ref)).

capacity_cancel_and_request_authority(_Env) ->
    {ok, First} = begin_flow(<<"subject-one">>, <<"provider-a">>),
    {ok, Second} = begin_flow(<<"subject-two">>, <<"provider-b">>),
    ?assertNotEqual(maps:get(<<"correlation_id">>, First),
                    maps:get(<<"correlation_id">>, Second)),
    ?assertNotEqual(maps:get(<<"credential_flow_ref">>, First),
                    maps:get(<<"credential_flow_ref">>, Second)),
    ?assertEqual({error, capacity_exceeded},
                 begin_flow(<<"subject-three">>, <<"provider-a">>)),
    FirstState = maps:get(<<"correlation_id">>, First),
    FirstRef = maps:get(<<"credential_flow_ref">>, First),
    ok = adk_authorization_flow:cancel(?FLOW, FirstState),
    ?assertEqual({error, not_found},
                 adk_credential_store_ets:fetch(
                   ?STORE, <<"subject-one">>, <<"provider-a">>, FirstRef)),
    {ok, _Third} = begin_flow(<<"subject-three">>, <<"provider-a">>),
    ?assertEqual({error, invalid_request},
                 adk_authorization_flow:begin_flow(
                   ?FLOW, #{principal => <<"subject-forged">>,
                            provider => <<"provider-a">>,
                            scopes => [<<"openid">>],
                            adapter_module =>
                                adk_oidcc_authorization_code_adapter,
                            context => #{client_secret => <<"attacker">>}})),
    ?assertEqual({error, scope_not_allowed},
                 adk_authorization_flow:begin_flow(
                   ?FLOW, #{principal => <<"subject-forged">>,
                            provider => <<"provider-a">>,
                            scopes => [<<"admin">>]})),
    ?assertEqual({error, unknown_provider},
                 begin_flow(<<"subject-forged">>, <<"attacker-provider">>)).

status_and_failures_are_redacted(#{supervisor := Supervisor}) ->
    Secret = <<"secret-slow-93d4">>,
    Principal = <<"subject-status">>,
    {ok, Request} = begin_flow(Principal, <<"provider-slow">>),
    State = maps:get(<<"correlation_id">>, Request),
    FlowStatus = sys:get_status(?FLOW),
    assert_absent(Secret, FlowStatus),
    assert_absent(State, FlowStatus),
    assert_absent(Secret, sys:get_state(?FLOW)),
    assert_absent(State, sys:get_state(?FLOW)),
    assert_absent(Secret, sys:get_status(Supervisor)),
    Parent = self(),
    Caller = spawn(fun() ->
        Parent ! {slow_result,
                  adk_authorization_flow:complete(
                    ?FLOW, State,
                    <<"code:slow:provider-subject-status">>, 2000)}
    end),
    ?assert(is_pid(Caller)),
    Worker = wait_for_worker(100),
    WorkerStatus = sys:get_status(Worker),
    assert_absent(Secret, WorkerStatus),
    assert_absent(State, WorkerStatus),
    assert_absent(Secret, sys:get_state(Worker)),
    ChildSpecs = [supervisor:get_childspec(?EXCHANGE_SUP, Id)
                  || {Id, _Pid, _Type, _Modules} <-
                         supervisor:which_children(?EXCHANGE_SUP)],
    assert_absent(Secret, ChildSpecs),
    receive
        {slow_result, {ok, _}} -> ok
    after 2500 ->
        error(slow_exchange_did_not_complete)
    end,
    {ok, LeakRequest} = begin_flow(<<"subject-leak">>, <<"provider-a">>),
    LeakState = maps:get(<<"correlation_id">>, LeakRequest),
    ?assertEqual({error, authorization_failed},
                 adk_authorization_flow:complete(
                   ?FLOW, LeakState, <<"leak">>)),
    assert_absent(<<"secret-a-71f2">>, sys:get_status(?FLOW)).

inflight_cancel_is_terminal(_Env) ->
    Principal = <<"oidc_local_cancelled">>,
    {ok, Request} = begin_flow(Principal, <<"provider-slow">>),
    State = maps:get(<<"correlation_id">>, Request),
    Ref = maps:get(<<"credential_flow_ref">>, Request),
    Parent = self(),
    _Caller = spawn(fun() ->
        Parent ! {cancelled_callback,
                  adk_authorization_flow:complete(
                    ?FLOW, State, <<"code:slow:provider-sub-cancelled">>,
                    2000)}
    end),
    _Worker = wait_for_worker(100),
    ok = adk_authorization_flow:cancel(?FLOW, State),
    receive
        {cancelled_callback, {error, authorization_cancelled}} -> ok
    after 1000 ->
        error(cancelled_callback_did_not_terminate)
    end,
    ?assertEqual([], supervisor:which_children(?EXCHANGE_SUP)),
    ?assertEqual({error, not_found},
                 adk_credential_store_ets:fetch(
                   ?STORE, Principal, <<"provider-slow">>, Ref)),
    ?assertEqual({error, invalid_or_expired_state},
                 adk_authorization_flow:complete(
                   ?FLOW, State, <<"code:slow:provider-sub-cancelled">>)).

authorization_uri_callbacks_are_isolated(_Env) ->
    Observer = self(),
    Base = profile(<<"guard">>, <<"authorization-secret-guard">>, 0),
    Profiles =
        #{<<"slow">> => with_adapter_context(
                           Base, #{authorization_delay_ms => 250,
                                   observer => Observer}),
          <<"crash">> => with_adapter_context(
                            Base, #{authorization_mode => crash}),
          <<"heap">> => with_adapter_context(
                           Base, #{authorization_mode => heap})},
    {ok, Flow} = start_isolated_flow(
                   Profiles, #{authorization_uri_timeout_ms => 25,
                               adapter_max_heap_words => 16384}),
    unlink(Flow),
    try
        ?assertEqual(
           {error, authorization_unavailable},
           begin_flow_on(Flow, <<"uri-slow">>, <<"slow">>)),
        Callback = receive
            {authorization_uri_started, Pid} -> Pid
        after 500 ->
            error(authorization_uri_callback_not_started)
        end,
        ?assert(wait_until_dead(Callback, 50)),
        CrashResult = begin_flow_on(Flow, <<"uri-crash">>, <<"crash">>),
        ?assertEqual({error, authorization_unavailable}, CrashResult),
        assert_absent(<<"authorization-secret-guard">>, CrashResult),
        ?assertEqual(
           {error, authorization_unavailable},
           begin_flow_on(Flow, <<"uri-heap">>, <<"heap">>)),
        ?assert(is_process_alive(Flow))
    after
        stop_flow(Flow)
    end,

    OwnerProfiles =
        #{<<"owner">> => with_adapter_context(
                            Base,
                            #{authorization_delay_ms => 1000,
                              observer => Observer})},
    {ok, OwnerFlow} = start_isolated_flow(
                        OwnerProfiles,
                        #{authorization_uri_timeout_ms => 2000,
                          adapter_max_heap_words => 16384}),
    unlink(OwnerFlow),
    _Caller = spawn(fun() ->
        _ = begin_flow_on(OwnerFlow, <<"uri-owner">>, <<"owner">>)
    end),
    OwnerCallback = receive
        {authorization_uri_started, Pid2} -> Pid2
    after 500 ->
        error(owner_callback_not_started)
    end,
    CallbackMonitor = erlang:monitor(process, OwnerCallback),
    exit(OwnerFlow, kill),
    receive
        {'DOWN', CallbackMonitor, process, OwnerCallback, _} -> ok
    after 500 ->
        error(callback_survived_manager)
    end.

exchange_callbacks_are_isolated(_Env) ->
    Observer = self(),
    Base = profile(<<"exchange">>, <<"exchange-secret-guard">>, 0),
    Slow = with_adapter_context(
             Base, #{delay_ms => 250, observer => Observer}),
    Profiles = #{<<"exchange">> => Base,
                 <<"slow-exchange">> => Slow},
    {ok, Flow} = start_isolated_flow(
                   Profiles, #{exchange_timeout_ms => 25,
                               authorization_uri_timeout_ms => 100,
                               adapter_max_heap_words => 16384}),
    unlink(Flow),
    try
        {ok, CrashRequest} = begin_flow_on(
                               Flow, <<"exchange-crash">>, <<"exchange">>),
        CrashState = maps:get(<<"correlation_id">>, CrashRequest),
        CrashResult = adk_authorization_flow:complete(
                        Flow, CrashState, <<"crash">>, 1000),
        ?assertEqual({error, authorization_failed}, CrashResult),
        assert_absent(<<"exchange-secret-guard">>, CrashResult),

        {ok, HeapRequest} = begin_flow_on(
                              Flow, <<"exchange-heap">>, <<"exchange">>),
        HeapState = maps:get(<<"correlation_id">>, HeapRequest),
        ?assertEqual(
           {error, authorization_failed},
           adk_authorization_flow:complete(
             Flow, HeapState, <<"heap">>, 1000)),

        {ok, SlowRequest} = begin_flow_on(
                              Flow, <<"exchange-slow">>, <<"slow-exchange">>),
        SlowState = maps:get(<<"correlation_id">>, SlowRequest),
        ?assertEqual(
           {error, authorization_timeout},
           adk_authorization_flow:complete(
             Flow, SlowState, <<"code:exchange:subject">>, 1000)),
        ExchangeCallback = receive
            {exchange_started, Pid, <<"code:exchange:subject">>} -> Pid
        after 500 ->
            error(exchange_callback_not_started)
        end,
        ?assert(wait_until_dead(ExchangeCallback, 50)),
        ?assert(is_process_alive(Flow))
    after
        stop_flow(Flow)
    end.

configuration_and_token_sizes_are_bounded(_Env) ->
    ?assertEqual(
       {error, invalid_adapter_context},
       adk_oidcc_authorization_code_adapter:validate_context(
         #{provider_worker => oidc_provider,
           client_id => binary:copy(<<"i">>, 4097),
           client_secret => <<"secret">>})),
    ?assertEqual(
       {error, invalid_adapter_context},
       adk_oidcc_authorization_code_adapter:validate_context(
         #{provider_worker => oidc_provider,
           client_id => <<"client">>,
           client_secret => binary:copy(<<"s">>, 16385)})),
    OversizedProfile =
        (profile(<<"large">>, <<"secret">>, 0))#{
          adapter_context :=
              #{marker => <<"large">>, client_id => <<"client-large">>,
                client_secret => <<"secret">>, delay_ms => 0,
                padding => binary:copy(<<"p">>, 70000)}},
    OldTrapExit = process_flag(trap_exit, true),
    OversizedStart = adk_authorization_flow:start_link(
                       #{name => undefined,
                         store_module => adk_credential_store_ets,
                         store_handle => ?STORE,
                         exchange_sup => ?EXCHANGE_SUP,
                         provider_profiles =>
                             #{<<"large">> => OversizedProfile},
                         default_lifetime_ms => 100,
                         sweep_interval_ms => 10}),
    receive {'EXIT', _FailedPid, _Failure} -> ok after 100 -> ok end,
    _ = process_flag(trap_exit, OldTrapExit),
    ?assertMatch({error, {invalid_authorization_flow_options, _}},
                 OversizedStart),
    Principal = <<"oidc_local_bounded">>,
    {ok, Request} = begin_flow(Principal, <<"provider-a">>),
    State = maps:get(<<"correlation_id">>, Request),
    ?assertEqual({error, authorization_failed},
                 adk_authorization_flow:complete(
                   ?FLOW, State, <<"oversized-token">>)).

start_isolated_flow(Profiles, Overrides) ->
    adk_authorization_flow:start_link(
      maps:merge(
        #{name => undefined,
          store_module => adk_credential_store_ets,
          store_handle => ?STORE,
          exchange_sup => ?EXCHANGE_SUP,
          provider_profiles => Profiles,
          default_lifetime_ms => 100,
          sweep_interval_ms => 10},
        Overrides)).

with_adapter_context(Profile, Extra) ->
    Context = maps:get(adapter_context, Profile),
    Profile#{adapter_context => maps:merge(Context, Extra)}.

begin_flow_on(Flow, Principal, Provider) ->
    adk_authorization_flow:begin_flow(
      Flow, #{principal => Principal,
              provider => Provider,
              scopes => [<<"openid">>, <<"agents.run">>]}).

stop_flow(Flow) ->
    case is_process_alive(Flow) of
        true -> gen_server:stop(Flow);
        false -> ok
    end.

wait_until_dead(Pid, 0) ->
    not is_process_alive(Pid);
wait_until_dead(Pid, Attempts) ->
    case is_process_alive(Pid) of
        false -> true;
        true -> timer:sleep(5), wait_until_dead(Pid, Attempts - 1)
    end.

begin_flow(Principal, Provider) ->
    adk_authorization_flow:begin_flow(
      ?FLOW, #{principal => Principal,
               provider => Provider,
               scopes => [<<"openid">>, <<"agents.run">>]}).

assert_public_request(Request) ->
    ?assertEqual(<<"oidc">>, maps:get(<<"scheme">>, Request)),
    ?assertEqual(<<"S256">>, maps:get(<<"pkce_method">>, Request)),
    Challenge = maps:get(<<"pkce_challenge">>, Request),
    ?assertEqual(43, byte_size(Challenge)),
    ?assert(adk_credential_store:is_ref(
              maps:get(<<"credential_flow_ref">>, Request))),
    Uri = maps:get(<<"authorization_uri">>, Request),
    Parsed = uri_string:parse(Uri),
    Pairs = uri_string:dissect_query(maps:get(query, Parsed)),
    ?assertEqual([maps:get(<<"correlation_id">>, Request)],
                 [Value || {<<"state">>, Value} <- Pairs]),
    ?assertEqual([Challenge],
                 [Value || {<<"code_challenge">>, Value} <- Pairs]),
    ?assertEqual([<<"S256">>],
                 [Value || {<<"code_challenge_method">>, Value} <- Pairs]),
    ?assertEqual([?RESOURCE],
                 [Value || {<<"resource">>, Value} <- Pairs]).

collect_results(0, Acc) -> Acc;
collect_results(Count, Acc) ->
    receive
        {callback_result, Result} -> collect_results(Count - 1,
                                                     [Result | Acc])
    after 2500 ->
        error(callback_results_timed_out)
    end.

wait_for_worker(0) -> error(exchange_worker_not_started);
wait_for_worker(Attempts) ->
    case supervisor:which_children(?EXCHANGE_SUP) of
        [{_Id, Worker, worker, _Modules} | _] when is_pid(Worker) -> Worker;
        _ -> timer:sleep(5), wait_for_worker(Attempts - 1)
    end.

assert_absent(Secret, Term) ->
    ?assertEqual(nomatch, binary:match(term_to_binary(Term), Secret)).
