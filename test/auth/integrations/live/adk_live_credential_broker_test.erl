-module(adk_live_credential_broker_test).

-include_lib("eunit/include/eunit.hrl").

credential_lifecycle_and_capability_validation_test() ->
    Secret = <<"live-provider-secret">>,
    {ok, CredentialRef = {adk_live_credential, Broker, _Token}} =
        adk_live_credential_broker:start(self(), Secret),
    BrokerMonitor = monitor(process, Broker),

    ?assert(adk_live_credential_broker:valid_ref(CredentialRef)),
    ?assertEqual({ok, Secret},
                 adk_live_credential_broker:resolve(CredentialRef)),

    WrongRef = {adk_live_credential, Broker, make_ref()},
    ?assertEqual({error, credential_unavailable},
                 adk_live_credential_broker:resolve(WrongRef)),
    ?assertEqual(ok, adk_live_credential_broker:revoke(WrongRef)),
    ?assertEqual({ok, Secret},
                 adk_live_credential_broker:resolve(CredentialRef)),

    ?assertEqual({error, bad_request}, gen_server:call(Broker, unexpected)),
    gen_server:cast(Broker, ignored),
    Broker ! ignored,
    ?assert(is_process_alive(Broker)),

    ?assertEqual(ok, adk_live_credential_broker:revoke(CredentialRef)),
    receive
        {'DOWN', BrokerMonitor, process, Broker, normal} -> ok
    after 1000 ->
        ?assert(false)
    end,
    ?assertEqual({error, credential_unavailable},
                 adk_live_credential_broker:resolve(CredentialRef)),
    ?assertEqual(ok, adk_live_credential_broker:revoke(CredentialRef)).

owner_exit_revokes_credential_test() ->
    Owner = spawn(fun owner_loop/0),
    {ok, CredentialRef = {adk_live_credential, Broker, _Token}} =
        adk_live_credential_broker:start(Owner, <<"ephemeral-secret">>),
    BrokerMonitor = monitor(process, Broker),

    exit(Owner, kill),
    receive
        {'DOWN', BrokerMonitor, process, Broker, normal} -> ok
    after 1000 ->
        ?assert(false)
    end,
    ?assertEqual({error, credential_unavailable},
                 adk_live_credential_broker:resolve(CredentialRef)).

invalid_inputs_and_status_redaction_test() ->
    ?assertEqual({error, invalid_credential},
                 adk_live_credential_broker:start(not_a_pid, <<"secret">>)),
    ?assertEqual({error, invalid_credential},
                 adk_live_credential_broker:start(self(), <<>>)),
    ?assertEqual({error, invalid_credential},
                 adk_live_credential_broker:start(self(),
                                                  binary:copy(<<0>>, 4097))),
    ?assertNot(adk_live_credential_broker:valid_ref(invalid)),
    ?assertNot(adk_live_credential_broker:valid_ref(
                 {adk_live_credential, self(), not_a_reference})),
    ?assertEqual({error, credential_unavailable},
                 adk_live_credential_broker:resolve(invalid)),
    ?assertEqual(ok, adk_live_credential_broker:revoke(invalid)),

    Marker = adk_secret_redactor:marker(),
    Status = adk_live_credential_broker:format_status(
               #{state => #{table => secret_table, token => make_ref()},
                 message => <<"secret-message">>,
                 log => [<<"secret-log">>],
                 reason => <<"secret-reason">>,
                 extra => <<"secret-extra">>}),
    ?assertEqual(#{configured => true}, maps:get(state, Status)),
    ?assertEqual(Marker, maps:get(message, Status)),
    ?assertEqual([], maps:get(log, Status)),
    ?assertEqual(Marker, maps:get(reason, Status)),
    ?assertEqual(Marker, maps:get(extra, Status)),

    State = #{unchanged => true},
    ?assertEqual({ok, State},
                 adk_live_credential_broker:code_change(old, State, extra)).

owner_loop() ->
    receive
        stop -> ok
    end.
