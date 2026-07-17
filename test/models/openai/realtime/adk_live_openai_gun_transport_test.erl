-module(adk_live_openai_gun_transport_test).

-include_lib("eunit/include/eunit.hrl").

fixed_origin_encoded_model_and_strict_options_test() ->
    ApiKey = <<"sk-test-fixed-origin">>,
    Model = <<"gpt-realtime:test/snapshot">>,
    ?assertMatch(
       {ok, _},
       adk_live_openai_gun_transport:validate_options(
         #{api_key => ApiKey, model => Model})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_openai_gun_transport:validate_options(
         #{api_key => ApiKey, model => Model,
           base_url => <<"wss://attacker.invalid">>})),
    Path = adk_live_openai_gun_transport:endpoint_path(Model),
    [FixedPath, Query] = binary:split(Path, <<"?">>),
    ?assertEqual(<<"/v1/realtime">>, FixedPath),
    ?assertEqual([{<<"model">>, Model}], uri_string:dissect_query(Query)),
    ?assertNotEqual(nomatch, binary:match(Path, <<"%3A">>)),
    ?assertNotEqual(nomatch, binary:match(Path, <<"%2F">>)),
    ?assertEqual(nomatch, binary:match(Path, ApiKey)).

handoff_and_policy_share_rejection_test() ->
    Options = #{api_key => <<"sk-test">>,
                model => <<"gpt-realtime">>,
                base_url => <<"wss://attacker.invalid">>},
    Expected = adk_live_openai_gun_transport:validate_options(Options),
    ?assertEqual({error, invalid_transport_options}, Expected),
    HandoffRef = make_ref(),
    {ok, Awaiting} = adk_live_openai_gun_transport:init(HandoffRef),
    ?assertMatch(
       {reply, Expected, Awaiting},
       adk_live_openai_gun_transport:handle_call(
         {handoff, HandoffRef, self(), Options},
         {self(), make_ref()}, Awaiting)),
    ok = adk_live_openai_gun_transport:terminate(normal, Awaiting).

invalid_credentials_models_and_query_injection_test() ->
    Model = <<"gpt-realtime">>,
    ?assertEqual(
       {error, invalid_transport_options},
       validate(#{model => Model})),
    ?assertEqual(
       {error, invalid_transport_options},
       validate(#{api_key => <<"sk-test">>})),
    ?assertEqual(
       {error, invalid_transport_options},
       validate(#{api_key => <<>>, model => Model})),
    ?assertEqual(
       {error, invalid_transport_options},
       validate(#{api_key => <<"sk-test\r\nX-Evil: yes">>,
                  model => Model})),
    ?assertEqual(
       {error, invalid_transport_options},
       validate(#{api_key => <<"sk-test:invalid-bearer">>,
                  model => Model})),
    ?assertEqual(
       {error, invalid_transport_options},
       validate(#{api_key => "not-a-binary", model => Model})),
    ?assertEqual(
       {error, invalid_transport_options},
       validate(#{api_key => <<"sk-test">>, credential_ref => make_ref(),
                  model => Model})),
    InvalidModels =
        [<<>>, <<"gpt-realtime&second=value">>,
         <<"gpt-realtime?override=yes">>, <<"gpt-realtime#fragment">>,
         <<"gpt-realtime\n">>, binary:copy(<<"m">>, 257),
         "gpt-realtime"],
    lists:foreach(
      fun(InvalidModel) ->
          ?assertEqual(
             {error, invalid_transport_options},
             validate(#{api_key => <<"sk-test">>, model => InvalidModel}))
      end, InvalidModels).

optional_headers_are_bounded_and_injection_safe_test() ->
    Base = #{api_key => <<"sk-test">>, model => <<"gpt-realtime">>},
    ?assertMatch(
       {ok, _},
       validate(Base#{safety_identifier => binary:copy(<<"s">>, 512),
                      organization => binary:copy(<<"o">>, 256),
                      project => binary:copy(<<"p">>, 256)})),
    InvalidOptions =
        [Base#{safety_identifier => <<>>},
         Base#{safety_identifier => binary:copy(<<"s">>, 513)},
         Base#{safety_identifier => <<"hash\r\nX-Evil: yes">>},
         Base#{organization => <<"org with space">>},
         Base#{organization => binary:copy(<<"o">>, 257)},
         Base#{project => <<"project\nX-Evil: yes">>},
         Base#{project => not_a_binary}],
    lists:foreach(
      fun(Options) ->
          ?assertEqual({error, invalid_transport_options},
                       validate(Options))
      end, InvalidOptions).

timeouts_frame_bounds_and_ca_file_validation_test() ->
    Base = #{api_key => <<"sk-test">>, model => <<"gpt-realtime">>},
    ?assertMatch(
       {ok, _},
       validate(Base#{connect_timeout_ms => 100,
                      tls_handshake_timeout_ms => 120000,
                      upgrade_timeout_ms => 100,
                      send_timeout_ms => 120000,
                      ws_flow => 64,
                      max_client_frame_bytes => 1024,
                      max_server_frame_bytes => 16777216,
                      cacertfile => <<"/tmp/test-ca.pem">>})),
    InvalidOptions =
        [Base#{connect_timeout_ms => 99},
         Base#{tls_handshake_timeout_ms => 120001},
         Base#{upgrade_timeout_ms => infinity},
         Base#{send_timeout_ms => 0},
         Base#{ws_flow => 0},
         Base#{ws_flow => 65},
         Base#{max_client_frame_bytes => 1023},
         Base#{max_server_frame_bytes => 16777217},
         Base#{cacertfile => <<>>},
         Base#{cacertfile => <<"bad", 0, "path">>},
         Base#{cacertfile => [0]},
         Base#{cacertfile => [$/ | invalid_tail]},
         Base#{cacertfile => invalid}],
    lists:foreach(
      fun(Options) ->
          ?assertEqual({error, invalid_transport_options},
                       validate(Options))
      end, InvalidOptions).

tls_retry_deadline_and_flow_options_test() ->
    Options = gun_options(
                #{api_key => <<"sk-test">>,
                  model => <<"gpt-realtime">>,
                  connect_timeout_ms => 1200,
                  tls_handshake_timeout_ms => 1300,
                  send_timeout_ms => 1400,
                  ws_flow => 2,
                  cacertfile => <<"/tmp/test-ca.pem">>}),
    ?assertEqual(tls, maps:get(transport, Options)),
    ?assertEqual([http], maps:get(protocols, Options)),
    ?assertEqual(0, maps:get(retry, Options)),
    ?assertMatch({adk_live_gun_event_h, #{owner := _}},
                 maps:get(event_handler, Options)),
    ?assertEqual(1200, maps:get(connect_timeout, Options)),
    ?assertEqual(1300, maps:get(tls_handshake_timeout, Options)),
    ?assert(lists:member({send_timeout, 1400},
                         maps:get(tcp_opts, Options))),
    ?assert(lists:member({send_timeout_close, true},
                         maps:get(tcp_opts, Options))),
    Tls = maps:get(tls_opts, Options),
    ?assert(lists:member({verify, verify_peer}, Tls)),
    ?assert(lists:member({cacertfile, "/tmp/test-ca.pem"}, Tls)),
    ?assert(lists:member({server_name_indication, "api.openai.com"}, Tls)),
    ?assert(lists:keymember(customize_hostname_check, 1, Tls)),
    ?assertNot(lists:member({verify, verify_none}, Tls)).

handoff_keeps_raw_credential_out_of_state_and_revokes_it_test() ->
    HandoffRef = make_ref(),
    {ok, Awaiting} = adk_live_openai_gun_transport:init(HandoffRef),
    Secret = <<"sk-owned-handoff-secret">>,
    {reply, ok, Connecting} =
        adk_live_openai_gun_transport:handle_call(
          {handoff, HandoffRef, self(),
           #{api_key => Secret,
             model => <<"gpt-realtime">>,
             connect_timeout_ms => 100,
             upgrade_timeout_ms => 100}},
          {self(), make_ref()}, Awaiting),
    ?assertEqual(connecting, maps:get(phase, Connecting)),
    ?assertEqual(true, maps:get(credential_owned, Connecting)),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Connecting), Secret)),
    CredentialRef = maps:get(credential_ref, Connecting),
    ?assertEqual({ok, Secret},
                 adk_live_credential_broker:resolve(CredentialRef)),
    receive
        connect -> ok
    after 0 ->
        erlang:error(connect_message_missing)
    end,
    OwnerMonitor = maps:get(owner_monitor, Connecting),
    ?assertEqual(ok,
                 adk_live_openai_gun_transport:terminate(
                   normal, Connecting)),
    erlang:demonitor(OwnerMonitor, [flush]),
    ?assertEqual({error, credential_unavailable},
                 adk_live_credential_broker:resolve(CredentialRef)).

referenced_credential_is_not_revoked_by_transport_test() ->
    {ok, CredentialRef} =
        adk_live_credential_broker:start(self(), <<"sk-referenced">>),
    HandoffRef = make_ref(),
    {ok, Awaiting} = adk_live_openai_gun_transport:init(HandoffRef),
    {reply, ok, Connecting} =
        adk_live_openai_gun_transport:handle_call(
          {handoff, HandoffRef, self(),
           #{credential_ref => CredentialRef,
             model => <<"gpt-realtime">>,
             connect_timeout_ms => 100}},
          {self(), make_ref()}, Awaiting),
    ?assertEqual(false, maps:get(credential_owned, Connecting)),
    receive
        connect -> ok
    after 0 ->
        erlang:error(connect_message_missing)
    end,
    OwnerMonitor = maps:get(owner_monitor, Connecting),
    ?assertEqual(ok,
                 adk_live_openai_gun_transport:terminate(
                   normal, Connecting)),
    erlang:demonitor(OwnerMonitor, [flush]),
    ?assertEqual({ok, <<"sk-referenced">>},
                 adk_live_credential_broker:resolve(CredentialRef)),
    ok = adk_live_credential_broker:revoke(CredentialRef).

gun_up_uses_bearer_auth_and_only_documented_headers_test() ->
    Secret = <<"sk-upgrade-secret">>,
    Model = <<"gpt-realtime:test/snapshot">>,
    {ok, CredentialRef} =
        adk_live_credential_broker:start(self(), Secret),
    TestPid = self(),
    FakeGun = spawn(fun() -> fake_gun_loop(TestPid) end),
    Connecting =
        (transport_state(connecting))#{
          connection => FakeGun,
          stream_ref => undefined,
          credential_ref => CredentialRef,
          model => Model,
          safety_identifier => <<"hashed-user-id">>,
          organization => <<"org_test">>,
          project => <<"proj_test">>,
          upgrade_timeout_ms => 100,
          ws_flow => 3},
    {noreply, Upgrading} =
        adk_live_openai_gun_transport:handle_info(
          {gun_up, FakeGun, http}, Connecting),
    ?assertEqual(upgrading, maps:get(phase, Upgrading)),
    UpgradeRef = maps:get(stream_ref, Upgrading),
    receive
        {'$gen_cast',
         {ws_upgrade, ReplyTo, UpgradeRef, Path, Headers, WsOptions}} ->
            ?assertEqual(self(), ReplyTo),
            [<<"/v1/realtime">>, Query] = binary:split(Path, <<"?">>),
            ?assertEqual([{<<"model">>, Model}],
                         uri_string:dissect_query(Query)),
            ?assertEqual(nomatch, binary:match(Path, Secret)),
            ?assertEqual(<<"Bearer ", Secret/binary>>,
                         proplists:get_value(<<"authorization">>, Headers)),
            ?assertEqual(<<"hashed-user-id">>,
                         proplists:get_value(
                           <<"openai-safety-identifier">>, Headers)),
            ?assertEqual(<<"org_test">>,
                         proplists:get_value(
                           <<"openai-organization">>, Headers)),
            ?assertEqual(<<"proj_test">>,
                         proplists:get_value(<<"openai-project">>, Headers)),
            ?assertEqual(<<"erlang-adk/0.8">>,
                         proplists:get_value(<<"user-agent">>, Headers)),
            ?assertEqual(5, length(Headers)),
            ?assertEqual(3, maps:get(flow, WsOptions)),
            ?assertEqual(false, maps:get(compress, WsOptions)),
            ?assertEqual(true, maps:get(silence_pings, WsOptions))
    after 1000 ->
        erlang:error(fake_gun_upgrade_missing)
    end,
    ?assertEqual(ok,
                 adk_live_openai_gun_transport:terminate(normal, Upgrading)),
    stop_fake_gun(FakeGun),
    ok = adk_live_credential_broker:revoke(CredentialRef).

resolved_credential_is_revalidated_before_header_use_test() ->
    {ok, CredentialRef} =
        adk_live_credential_broker:start(
          self(), <<"sk-bad\r\nX-Evil: yes">>),
    FakeGun = spawn(fun() -> receive stop -> ok end end),
    Connecting =
        (transport_state(connecting))#{connection => FakeGun,
                                       stream_ref => undefined,
                                       credential_ref => CredentialRef},
    {stop, normal, Closed} =
        adk_live_openai_gun_transport:handle_info(
          {gun_up, FakeGun, http}, Connecting),
    ?assertEqual(true, maps:get(notified_closed, Closed)),
    assert_transport_message({closed, credential_unavailable}),
    FakeGun ! stop,
    ok = adk_live_credential_broker:revoke(CredentialRef).

outbound_frames_are_bounded_and_acknowledged_after_send_completion_test() ->
    TestPid = self(),
    FakeGun = spawn(fun() -> fake_gun_loop(TestPid) end),
    Active = (transport_state(active))#{connection => FakeGun,
                                        max_client_frame_bytes => 4,
                                        send_timeout_ms => 1000},
    StreamRef = maps:get(stream_ref, Active),
    ?assertEqual(
       {reply, {error, client_frame_too_large}, Active},
       adk_live_openai_gun_transport:handle_call(
         {send, <<"12345">>}, {self(), make_ref()}, Active)),
    {reply, {ok, SendRef}, Pending} =
        adk_live_openai_gun_transport:handle_call(
          {send, <<"1234">>}, {self(), make_ref()}, Active),
    ?assert(is_reference(SendRef)),
    ?assert(is_reference(maps:get(send_timer, Pending))),
    receive
        {'$gen_cast', {ws_send, ReplyTo, StreamRef, {text, <<"1234">>}}} ->
            ?assertEqual(self(), ReplyTo)
    after 1000 ->
        erlang:error(fake_gun_send_missing)
    end,
    ?assertEqual(
       {reply, {error, busy}, Pending},
       adk_live_openai_gun_transport:handle_call(
         {send, <<"1">>}, {self(), make_ref()}, Pending)),
    {noreply, Writable} =
        adk_live_openai_gun_transport:handle_info(
          {adk_live_gun_event, FakeGun,
           {ws_send_frame_end, StreamRef}}, Pending),
    assert_transport_message({sent, SendRef}),
    assert_transport_message(writable),
    ?assertEqual(undefined, maps:get(outbound_pending, Writable)),
    ?assertEqual(undefined, maps:get(send_timer, Writable)),
    ?assertEqual(
       {noreply, Writable},
       adk_live_openai_gun_transport:handle_info(
         {send_timeout, SendRef}, Writable)),
    stop_fake_gun(FakeGun).

missing_outbound_completion_has_bounded_stable_failure_test() ->
    TestPid = self(),
    FakeGun = spawn(fun() -> fake_gun_loop(TestPid) end),
    Active = (transport_state(active))#{connection => FakeGun},
    StreamRef = maps:get(stream_ref, Active),
    SendRef = make_ref(),
    Pending = Active#{outbound_pending => SendRef,
                      send_timer => make_ref()},
    {stop, normal, Closed} =
        adk_live_openai_gun_transport:handle_info(
          {send_timeout, SendRef}, Pending),
    ?assertEqual(true, maps:get(notified_closed, Closed)),
    assert_transport_message({closed, send_timeout}),
    receive
        {'$gen_cast', {ws_send, _ReplyTo, StreamRef, close}} -> ok
    after 1000 ->
        erlang:error(fake_gun_close_missing)
    end,
    stop_fake_gun(FakeGun).

inbound_flow_is_explicit_and_server_frames_are_bounded_test() ->
    State = transport_state(active),
    Connection = maps:get(connection, State),
    StreamRef = maps:get(stream_ref, State),
    {noreply, State} = adk_live_openai_gun_transport:handle_info(
                         {gun_ws, Connection, StreamRef,
                          {text, <<"text">>}}, State),
    assert_transport_message({frame, <<"text">>}),
    Bounded = State#{max_server_frame_bytes => 3},
    {stop, normal, Closed} =
        adk_live_openai_gun_transport:handle_info(
          {gun_ws, Connection, StreamRef, {binary, <<0, 1, 2, 3>>}},
          Bounded),
    ?assertEqual(true, maps:get(notified_closed, Closed)),
    assert_transport_message({closed, server_frame_too_large}),
    {noreply, State} =
        adk_live_openai_gun_transport:handle_cast({consumed, 1}, State),
    {noreply, State} =
        adk_live_openai_gun_transport:handle_info(
          {gun_ws, Connection, StreamRef, ping}, State).

redirects_protocol_changes_and_low_level_errors_are_not_exposed_test() ->
    Connecting = transport_state(connecting),
    ConnectingConnection = maps:get(connection, Connecting),
    assert_closed({gun_up, ConnectingConnection, http2},
                  Connecting, protocol_not_allowed),
    assert_closed({phase_timeout, connecting},
                  Connecting, connect_timeout),
    Upgrading = transport_state(upgrading),
    Connection = maps:get(connection, Upgrading),
    StreamRef = maps:get(stream_ref, Upgrading),
    assert_closed({gun_response, Connection, StreamRef, fin, 302,
                   [{<<"location">>,
                     <<"wss://attacker.invalid/steal?secret=value">>}]},
                  Upgrading, upgrade_failed),
    assert_closed({gun_response, Connection, StreamRef, fin, 401,
                   [{<<"x-debug">>, <<"sk-secret">>}]},
                  Upgrading, upgrade_failed),
    Active = transport_state(active),
    ActiveConnection = maps:get(connection, Active),
    assert_closed({gun_error, ActiveConnection,
                   {tls_alert, <<"secret diagnostics">>}},
                  Active, transport_error),
    assert_closed({gun_down, ActiveConnection, http,
                   <<"secret diagnostics">>, []},
                  Active, transport_closed).

upgrade_success_and_terminal_events_have_stable_reasons_test() ->
    Upgrading = transport_state(upgrading),
    Connection = maps:get(connection, Upgrading),
    StreamRef = maps:get(stream_ref, Upgrading),
    {noreply, Active} =
        adk_live_openai_gun_transport:handle_info(
          {gun_upgrade, Connection, StreamRef, [<<"websocket">>], []},
          Upgrading),
    ?assertEqual(active, maps:get(phase, Active)),
    ?assertEqual(undefined, maps:get(timer, Active)),
    assert_transport_message(connected),
    assert_closed({gun_ws, Connection, StreamRef, close},
                  Active, remote_closed),
    assert_closed({gun_ws, Connection, StreamRef,
                   {close, 1000, <<"provider detail">>}},
                  Active, remote_closed),
    assert_closed({phase_timeout, upgrading},
                  Upgrading, upgrade_timeout).

format_status_redacts_credentials_identifiers_paths_and_errors_test() ->
    Secret = <<"sk-status-secret">>,
    Status =
        #{state => #{phase => active,
                     ws_flow => 2,
                     max_client_frame_bytes => 2048,
                     max_server_frame_bytes => 4096,
                     credential_ref => Secret,
                     model => Secret,
                     safety_identifier => Secret,
                     organization => Secret,
                     project => Secret,
                     endpoint_path => Secret},
          message => {send, Secret},
          log => [Secret],
          reason => {failed, Secret},
          extra => Secret},
    Safe = adk_live_openai_gun_transport:format_status(Status),
    ?assertEqual(
       #{phase => active, connected => true, flow => 2,
         max_client_frame_bytes => 2048,
         max_server_frame_bytes => 4096},
       maps:get(state, Safe)),
    ?assertEqual([], maps:get(log, Safe)),
    Marker = adk_secret_redactor:marker(),
    ?assertEqual(Marker, maps:get(message, Safe)),
    ?assertEqual(Marker, maps:get(reason, Safe)),
    ?assertEqual(Marker, maps:get(extra, Safe)),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Safe), Secret)).

public_api_rejects_invalid_and_dead_handles_test() ->
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_openai_gun_transport:open(not_a_pid, #{})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_openai_gun_transport:open(self(), not_a_map)),
    ?assertEqual(
       {error, invalid_frame},
       adk_live_openai_gun_transport:send(not_a_pid, <<"frame">>)),
    ?assertEqual(
       {error, invalid_frame},
       adk_live_openai_gun_transport:send(self(), not_a_binary)),
    {Dead, Monitor} = spawn_monitor(fun() -> ok end),
    receive
        {'DOWN', Monitor, process, Dead, normal} -> ok
    after 1000 ->
        erlang:error(dead_transport_fixture_did_not_exit)
    end,
    ?assertEqual(
       {error, transport_unavailable},
       adk_live_openai_gun_transport:send(Dead, <<"frame">>)),
    ?assertEqual(ok,
                 adk_live_openai_gun_transport:close(Dead, shutdown)),
    ?assertEqual(ok,
                 adk_live_openai_gun_transport:close(not_a_pid, shutdown)),
    ?assertEqual(ok,
                 adk_live_openai_gun_transport:consumed(Dead, 1)),
    ?assertEqual(ok,
                 adk_live_openai_gun_transport:consumed(Dead, 0)).

validate(Options) ->
    adk_live_openai_gun_transport:validate_options(Options).

gun_options(Options) ->
    {ok, Checked} = adk_live_openai_gun_transport:validate_options(Options),
    {ok, GunOptions} =
        adk_live_openai_gun_transport:gun_options(Checked),
    GunOptions.

transport_state(Phase) ->
    #{phase => Phase,
      owner => self(),
      owner_monitor => make_ref(),
      connection => make_ref(),
      stream_ref => make_ref(),
      credential_ref => undefined,
      credential_owned => false,
      outbound_pending => undefined,
      notified_closed => false,
      timer => undefined,
      send_timer => undefined,
      model => <<"gpt-realtime">>,
      safety_identifier => undefined,
      organization => undefined,
      project => undefined,
      connect_timeout_ms => 100,
      tls_handshake_timeout_ms => 100,
      upgrade_timeout_ms => 100,
      send_timeout_ms => 100,
      ws_flow => 1,
      max_client_frame_bytes => 4096,
      max_server_frame_bytes => 4096,
      cacertfile => undefined}.

assert_closed(Event, State, ExpectedReason) ->
    {stop, normal, Closed} =
        adk_live_openai_gun_transport:handle_info(Event, State),
    ?assertEqual(true, maps:get(notified_closed, Closed)),
    assert_transport_message({closed, ExpectedReason}).

assert_transport_message(Expected) ->
    receive
        {adk_live_transport, Sender, Expected} ->
            ?assertEqual(self(), Sender)
    after 0 ->
        erlang:error({transport_message_missing, Expected})
    end.

fake_gun_loop(TestPid) ->
    receive
        stop -> ok;
        Message ->
            TestPid ! Message,
            fake_gun_loop(TestPid)
    end.

stop_fake_gun(FakeGun) ->
    Monitor = erlang:monitor(process, FakeGun),
    FakeGun ! stop,
    receive
        {'DOWN', Monitor, process, FakeGun, normal} -> ok
    after 1000 ->
        erlang:error(fake_gun_stop_timeout)
    end.
