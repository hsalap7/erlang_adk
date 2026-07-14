-module(adk_live_gun_transport_test).

-include_lib("eunit/include/eunit.hrl").

fixed_origin_and_strict_options_test() ->
    ApiKey = <<"key with ? and & delimiters">>,
    ?assertMatch({ok, _},
                 adk_live_gun_transport:test_validate_options(
                   #{api_key => ApiKey})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:test_validate_options(
         #{api_key => ApiKey,
           base_url => <<"wss://attacker.invalid">>})),
    Path = adk_live_gun_transport:test_endpoint_path(ApiKey),
    [FixedPath, Query] = binary:split(Path, <<"?">>),
    ?assertEqual(
       <<"/ws/google.ai.generativelanguage.v1beta."
         "GenerativeService.BidiGenerateContent">>, FixedPath),
    ?assertEqual([{<<"key">>, ApiKey}], uri_string:dissect_query(Query)).

tls_retry_deadline_and_flow_options_test() ->
    Options = adk_live_gun_transport:test_gun_options(
                #{api_key => <<"test-key">>,
                  connect_timeout_ms => 1200,
                  tls_handshake_timeout_ms => 1300,
                  send_timeout_ms => 1400,
                  ws_flow => 2}),
    ?assertEqual(tls, maps:get(transport, Options)),
    ?assertEqual([http], maps:get(protocols, Options)),
    ?assertEqual(0, maps:get(retry, Options)),
    ?assertMatch({adk_live_gun_event_h, #{owner := _}},
                 maps:get(event_handler, Options)),
    ?assertEqual(1200, maps:get(connect_timeout, Options)),
    ?assertEqual(1300, maps:get(tls_handshake_timeout, Options)),
    ?assert(lists:member({send_timeout, 1400},
                         maps:get(tcp_opts, Options))),
    Tls = maps:get(tls_opts, Options),
    ?assert(lists:member({verify, verify_peer}, Tls)),
    ?assert(lists:member(
              {server_name_indication,
               "generativelanguage.googleapis.com"}, Tls)),
    ?assert(lists:keymember(customize_hostname_check, 1, Tls)).

invalid_credentials_and_bounds_test() ->
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:test_validate_options(#{})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:test_validate_options(#{api_key => <<>>})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:test_validate_options(
         #{api_key => "not-a-binary"})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:test_validate_options(
         #{api_key => <<"key">>, credential_ref => make_ref()})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:test_validate_options(
         #{api_key => <<"key">>, ws_flow => 0})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:test_validate_options(
         #{api_key => <<"key">>,
           max_server_frame_bytes => 100000000})),
    ?assertMatch(
       {ok, _},
       adk_live_gun_transport:test_validate_options(
         #{api_key => <<"key">>, cacertfile => <<"/tmp/ca.pem">>})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:test_validate_options(
         #{api_key => <<"key">>, cacertfile => <<>>})).

opaque_credential_and_frame_end_event_test() ->
    Secret = <<"gun-secret-must-not-enter-state">>,
    {ok, CredentialRef} =
        adk_live_credential_broker:start(self(), Secret),
    ?assertMatch(
       {ok, _},
       adk_live_gun_transport:test_validate_options(
         #{credential_ref => CredentialRef})),
    {adk_live_credential, Broker, _Token} = CredentialRef,
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(sys:get_state(Broker)),
                              Secret)),
    StreamRef = make_ref(),
    EventState = #{owner => self()},
    EventState = adk_live_gun_event_h:ws_send_frame_start(
                   #{stream_ref => StreamRef}, EventState),
    receive
        {adk_live_gun_event, _, _} -> ?assert(false)
    after 10 -> ok
    end,
    EventState = adk_live_gun_event_h:ws_send_frame_end(
                   #{stream_ref => StreamRef}, EventState),
    receive
        {adk_live_gun_event, EventProcess,
         {ws_send_frame_end, StreamRef}} ->
            ?assertEqual(self(), EventProcess)
    after 1000 ->
        ?assert(false)
    end,
    ok = adk_live_credential_broker:revoke(CredentialRef),
    ?assertEqual({error, credential_unavailable},
                 adk_live_credential_broker:resolve(CredentialRef)).
