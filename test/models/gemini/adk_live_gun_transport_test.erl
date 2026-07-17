-module(adk_live_gun_transport_test).

-include_lib("eunit/include/eunit.hrl").

fixed_origin_and_strict_options_test() ->
    ApiKey = <<"key with ? and & delimiters">>,
    ?assertMatch({ok, _},
                 adk_live_gun_transport:validate_options(
                   #{api_key => ApiKey})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:validate_options(
         #{api_key => ApiKey,
           base_url => <<"wss://attacker.invalid">>})),
    Path = adk_live_gun_transport:endpoint_path(ApiKey),
    [FixedPath, Query] = binary:split(Path, <<"?">>),
    ?assertEqual(
       <<"/ws/google.ai.generativelanguage.v1beta."
         "GenerativeService.BidiGenerateContent">>, FixedPath),
    ?assertEqual([{<<"key">>, ApiKey}], uri_string:dissect_query(Query)).

handoff_and_policy_share_rejection_test() ->
    Options = #{api_key => <<"test-key">>,
                base_url => <<"wss://attacker.invalid">>},
    Expected = adk_live_gun_transport:validate_options(Options),
    ?assertEqual({error, invalid_transport_options}, Expected),
    HandoffRef = make_ref(),
    {ok, Awaiting} = adk_live_gun_transport:init(HandoffRef),
    ?assertMatch(
       {reply, Expected, Awaiting},
       adk_live_gun_transport:handle_call(
         {handoff, HandoffRef, self(), Options},
         {self(), make_ref()}, Awaiting)),
    ok = adk_live_gun_transport:terminate(normal, Awaiting).

tls_retry_deadline_and_flow_options_test() ->
    Options = gun_options(
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
       adk_live_gun_transport:validate_options(#{})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:validate_options(#{api_key => <<>>})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:validate_options(
         #{api_key => "not-a-binary"})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:validate_options(
         #{api_key => <<"key">>, credential_ref => make_ref()})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:validate_options(
         #{api_key => <<"key">>, ws_flow => 0})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:validate_options(
         #{api_key => <<"key">>,
           max_server_frame_bytes => 100000000})),
    ?assertMatch(
       {ok, _},
       adk_live_gun_transport:validate_options(
         #{api_key => <<"key">>, cacertfile => <<"/tmp/ca.pem">>})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:validate_options(
         #{api_key => <<"key">>, cacertfile => <<>>})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:validate_options(
         #{api_key => <<"key">>, cacertfile => [0]})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:validate_options(
         #{api_key => <<"key">>, cacertfile => invalid})),
    BinaryCa = gun_options(
                 #{api_key => <<"key">>,
                   cacertfile => <<"/tmp/test-ca.pem">>}),
    ?assert(lists:member(
              {cacertfile, "/tmp/test-ca.pem"},
              maps:get(tls_opts, BinaryCa))),
    ListCa = gun_options(
               #{api_key => <<"key">>,
                 cacertfile => "/tmp/test-ca.pem"}),
    ?assert(lists:member(
              {cacertfile, "/tmp/test-ca.pem"},
              maps:get(tls_opts, ListCa))).

handoff_installs_and_revokes_owned_credential_test() ->
    HandoffRef = make_ref(),
    {ok, Awaiting} = adk_live_gun_transport:init(HandoffRef),
    Secret = <<"owned-handoff-secret">>,
    {reply, ok, Connecting} =
        adk_live_gun_transport:handle_call(
          {handoff, HandoffRef, self(),
           #{api_key => Secret,
             connect_timeout_ms => 100,
             upgrade_timeout_ms => 100}},
          {self(), make_ref()}, Awaiting),
    ?assertEqual(connecting, maps:get(phase, Connecting)),
    ?assertEqual(true, maps:get(credential_owned, Connecting)),
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
                 adk_live_gun_transport:terminate(normal, Connecting)),
    erlang:demonitor(OwnerMonitor, [flush]),
    ?assertEqual({error, credential_unavailable},
                 adk_live_credential_broker:resolve(CredentialRef)).

handoff_preserves_referenced_credential_and_rejects_bad_options_test() ->
    {ok, CredentialRef} =
        adk_live_credential_broker:start(self(), <<"referenced-secret">>),
    HandoffRef = make_ref(),
    {ok, Awaiting} = adk_live_gun_transport:init(HandoffRef),
    {reply, {error, invalid_transport_options}, Awaiting} =
        adk_live_gun_transport:handle_call(
          {handoff, HandoffRef, self(), #{}},
          {self(), make_ref()}, Awaiting),
    {reply, ok, Connecting} =
        adk_live_gun_transport:handle_call(
          {handoff, HandoffRef, self(),
           #{credential_ref => CredentialRef,
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
                 adk_live_gun_transport:terminate(normal, Connecting)),
    erlang:demonitor(OwnerMonitor, [flush]),
    ?assertEqual({ok, <<"referenced-secret">>},
                 adk_live_credential_broker:resolve(CredentialRef)),
    ok = adk_live_credential_broker:revoke(CredentialRef).

gun_up_resolves_credential_and_starts_strict_upgrade_test() ->
    Secret = <<"upgrade key with ? and &">>,
    {ok, CredentialRef} =
        adk_live_credential_broker:start(self(), Secret),
    TestPid = self(),
    FakeGun = spawn(fun() -> fake_gun_loop(TestPid) end),
    Connecting = (transport_state(connecting))#{
                   connection => FakeGun,
                   stream_ref => undefined,
                   credential_ref => CredentialRef,
                   upgrade_timeout_ms => 100,
                   ws_flow => 3},
    {noreply, Upgrading} = adk_live_gun_transport:handle_info(
                             {gun_up, FakeGun, http}, Connecting),
    ?assertEqual(upgrading, maps:get(phase, Upgrading)),
    UpgradeRef = maps:get(stream_ref, Upgrading),
    receive
        {'$gen_cast',
         {ws_upgrade, ReplyTo, UpgradeRef, Path, Headers, WsOptions}} ->
            ?assertEqual(self(), ReplyTo),
            [_FixedPath, Query] = binary:split(Path, <<"?">>),
            ?assertEqual([{<<"key">>, Secret}],
                         uri_string:dissect_query(Query)),
            ?assert(lists:member(
                      {<<"user-agent">>, <<"erlang-adk/0.8">>},
                      Headers)),
            ?assertEqual(3, maps:get(flow, WsOptions)),
            ?assertEqual(false, maps:get(compress, WsOptions)),
            ?assertEqual(true, maps:get(silence_pings, WsOptions))
    after 1000 ->
        erlang:error(fake_gun_upgrade_missing)
    end,
    ?assertEqual(ok, adk_live_gun_transport:terminate(normal, Upgrading)),
    stop_fake_gun(FakeGun),
    ok = adk_live_credential_broker:revoke(CredentialRef).

gun_up_rejects_revoked_credential_test() ->
    {ok, CredentialRef} =
        adk_live_credential_broker:start(self(), <<"revoked-secret">>),
    ok = adk_live_credential_broker:revoke(CredentialRef),
    TestPid = self(),
    FakeGun = spawn(fun() -> fake_gun_loop(TestPid) end),
    Connecting = (transport_state(connecting))#{
                   connection => FakeGun,
                   stream_ref => undefined,
                   credential_ref => CredentialRef},
    {stop, normal, Closed} = adk_live_gun_transport:handle_info(
                               {gun_up, FakeGun, http}, Connecting),
    ?assertEqual(true, maps:get(notified_closed, Closed)),
    assert_transport_message({closed, credential_unavailable}),
    stop_fake_gun(FakeGun).

active_send_close_and_gun_exit_paths_test() ->
    TestPid = self(),
    FakeGun = spawn(fun() -> fake_gun_loop(TestPid) end),
    Active = (transport_state(active))#{connection => FakeGun},
    StreamRef = maps:get(stream_ref, Active),
    {reply, {ok, SendRef}, Pending} =
        adk_live_gun_transport:handle_call(
          {send, <<"outbound">>}, {self(), make_ref()}, Active),
    ?assert(is_reference(SendRef)),
    ?assertEqual(SendRef, maps:get(outbound_pending, Pending)),
    receive
        {'$gen_cast', {ws_send, ReplyTo, StreamRef,
                       {text, <<"outbound">>}}} ->
            ?assertEqual(self(), ReplyTo)
    after 1000 ->
        erlang:error(fake_gun_send_missing)
    end,

    Failed = Active#{connection => make_ref()},
    ?assertEqual(
       {reply, {error, transport_send_failed}, Failed},
       adk_live_gun_transport:handle_call(
         {send, <<"outbound">>}, {self(), make_ref()}, Failed)),

    ?assertEqual(
       {stop, normal, ok, Active},
       adk_live_gun_transport:handle_call(
         close, {self(), make_ref()}, Active)),
    receive
        {'$gen_cast', {ws_send, _ReplyTo, StreamRef, close}} -> ok
    after 1000 ->
        erlang:error(fake_gun_close_missing)
    end,

    {stop, normal, ExitClosed} = adk_live_gun_transport:handle_info(
                                   {'EXIT', FakeGun, shutdown}, Active),
    ?assertEqual(true, maps:get(notified_closed, ExitClosed)),
    assert_transport_message({closed, transport_closed}),

    ConnectionOnly = Active#{stream_ref => undefined},
    ?assertEqual(ok,
                 adk_live_gun_transport:terminate(
                   normal, ConnectionOnly)),
    stop_fake_gun(FakeGun).

ownerless_terminal_event_does_not_attempt_notification_test() ->
    State = (transport_state(active))#{owner => undefined},
    Connection = maps:get(connection, State),
    {stop, normal, State} = adk_live_gun_transport:handle_info(
                              {gun_error, Connection, opaque}, State),
    assert_no_transport_message().

opaque_credential_and_frame_end_event_test() ->
    Secret = <<"gun-secret-must-not-enter-state">>,
    {ok, CredentialRef} =
        adk_live_credential_broker:start(self(), Secret),
    ?assertMatch(
       {ok, _},
       adk_live_gun_transport:validate_options(
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

public_api_rejects_invalid_and_dead_handles_test() ->
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:open(not_a_pid, #{})),
    ?assertEqual(
       {error, invalid_transport_options},
       adk_live_gun_transport:open(self(), not_a_map)),
    ?assertEqual(
       {error, invalid_frame},
       adk_live_gun_transport:send(not_a_pid, <<"frame">>)),
    ?assertEqual(
       {error, invalid_frame},
       adk_live_gun_transport:send(self(), not_a_binary)),
    {Dead, Monitor} = spawn_monitor(fun() -> ok end),
    receive
        {'DOWN', Monitor, process, Dead, normal} -> ok
    after 1000 -> erlang:error(dead_transport_fixture_did_not_exit)
    end,
    ?assertEqual(
       {error, transport_unavailable},
       adk_live_gun_transport:send(Dead, <<"frame">>)),
    ?assertEqual(ok, adk_live_gun_transport:close(Dead, shutdown)),
    ?assertEqual(ok,
                 adk_live_gun_transport:close(not_a_pid, shutdown)),
    ?assertEqual(ok, adk_live_gun_transport:consumed(Dead, 1)),
    ?assertEqual(ok, adk_live_gun_transport:consumed(not_a_pid, 1)),
    ?assertEqual(ok, adk_live_gun_transport:consumed(Dead, 0)).

public_api_forwards_send_flow_and_close_to_handle_test() ->
    TestPid = self(),
    Handle = spawn(fun() -> fake_transport_handle_loop(TestPid) end),
    Monitor = erlang:monitor(process, Handle),
    {ok, SendRef} = adk_live_gun_transport:send(
                      Handle, <<"public-frame">>),
    ?assert(is_reference(SendRef)),
    receive
        {fake_transport_call, {send, <<"public-frame">>}} -> ok
    after 1000 ->
        erlang:error(fake_transport_send_missing)
    end,
    ?assertEqual(ok, adk_live_gun_transport:consumed(Handle, 2)),
    receive
        {fake_transport_cast, {consumed, 2}} -> ok
    after 1000 ->
        erlang:error(fake_transport_flow_missing)
    end,
    ?assertEqual(ok,
                 adk_live_gun_transport:close(Handle, normal)),
    receive
        {fake_transport_call, close} -> ok
    after 1000 ->
        erlang:error(fake_transport_close_missing)
    end,
    receive
        {'DOWN', Monitor, process, Handle, normal} -> ok
    after 1000 ->
        erlang:error(fake_transport_handle_stop_timeout)
    end.

inbound_frames_are_delivered_and_bounded_test() ->
    State = transport_state(active),
    Connection = maps:get(connection, State),
    StreamRef = maps:get(stream_ref, State),
    {noreply, State} = adk_live_gun_transport:handle_info(
                         {gun_ws, Connection, StreamRef,
                          {text, <<"text">>}}, State),
    assert_transport_message({frame, <<"text">>}),
    {noreply, State} = adk_live_gun_transport:handle_info(
                         {gun_ws, Connection, StreamRef,
                          {binary, <<0, 1, 2>>}}, State),
    assert_transport_message({frame, <<0, 1, 2>>}),

    Bounded = State#{max_server_frame_bytes => 3},
    {stop, normal, Closed} = adk_live_gun_transport:handle_info(
                               {gun_ws, Connection, StreamRef,
                                {binary, <<0, 1, 2, 3>>}}, Bounded),
    assert_transport_message({closed, server_frame_too_large}),
    ?assertEqual(true, maps:get(notified_closed, Closed)),
    %% A second terminal signal must not produce a duplicate close event.
    {stop, normal, Closed} = adk_live_gun_transport:handle_info(
                               {gun_error, Connection, duplicate}, Closed),
    assert_no_transport_message().

terminal_transport_events_have_stable_reasons_test() ->
    Active = transport_state(active),
    Connection = maps:get(connection, Active),
    StreamRef = maps:get(stream_ref, Active),
    assert_closed({gun_ws, Connection, StreamRef, close},
                  Active, remote_closed),
    assert_closed({gun_ws, Connection, StreamRef,
                   {close, 1000, <<"normal">>}},
                  Active, remote_closed),
    assert_closed({gun_error, Connection, opaque},
                  Active, transport_error),
    assert_closed({gun_error, Connection, StreamRef, opaque},
                  Active, transport_error),
    assert_closed({gun_down, Connection, http, opaque, []},
                  Active, transport_closed),

    Connecting = transport_state(connecting),
    ConnectingConnection = maps:get(connection, Connecting),
    assert_closed({gun_up, ConnectingConnection, http2},
                  Connecting, protocol_not_allowed),
    assert_closed({phase_timeout, connecting},
                  Connecting, connect_timeout),
    {noreply, Connecting} = adk_live_gun_transport:handle_info(
                              {phase_timeout, upgrading}, Connecting),
    assert_no_transport_message(),

    Upgrading = transport_state(upgrading),
    UpgradeConnection = maps:get(connection, Upgrading),
    UpgradeStreamRef = maps:get(stream_ref, Upgrading),
    assert_closed({gun_upgrade, UpgradeConnection, UpgradeStreamRef,
                   [<<"not-websocket">>], []},
                  Upgrading, upgrade_failed),
    assert_closed({gun_response, UpgradeConnection, UpgradeStreamRef,
                   fin, 403, []},
                  Upgrading, upgrade_failed),
    assert_closed({phase_timeout, upgrading},
                  Upgrading, upgrade_timeout).

upgrade_flow_and_send_acknowledgement_test() ->
    Upgrading = transport_state(upgrading),
    Connection = maps:get(connection, Upgrading),
    StreamRef = maps:get(stream_ref, Upgrading),
    {noreply, Active} = adk_live_gun_transport:handle_info(
                          {gun_upgrade, Connection, StreamRef,
                           [<<"websocket">>], []}, Upgrading),
    ?assertEqual(active, maps:get(phase, Active)),
    ?assertEqual(undefined, maps:get(timer, Active)),
    assert_transport_message(connected),

    SendRef = make_ref(),
    Pending = Active#{outbound_pending => SendRef},
    {noreply, Writable} = adk_live_gun_transport:handle_info(
                            {adk_live_gun_event, Connection,
                             {ws_send_frame_end, StreamRef}}, Pending),
    assert_transport_message({sent, SendRef}),
    assert_transport_message(writable),
    ?assertEqual(undefined, maps:get(outbound_pending, Writable)),

    %% Stale acknowledgements and control frames are metadata-free no-ops.
    {noreply, Writable} = adk_live_gun_transport:handle_info(
                            {adk_live_gun_event, Connection,
                             {ws_send_frame_end, StreamRef}}, Writable),
    {noreply, Writable} = adk_live_gun_transport:handle_info(
                            {gun_ws, Connection, StreamRef, ping}, Writable),
    {noreply, Writable} = adk_live_gun_transport:handle_cast(
                            {consumed, 1}, Writable),
    {noreply, Writable} = adk_live_gun_transport:handle_cast(
                            ignored, Writable),
    assert_no_transport_message().

callback_defaults_and_lifecycle_messages_test() ->
    Active = transport_state(active),
    Pending = Active#{outbound_pending => make_ref()},
    ?assertEqual(
       {reply, {error, busy}, Pending},
       adk_live_gun_transport:handle_call(
         {send, <<"frame">>}, {self(), make_ref()}, Pending)),
    ?assertEqual(
       {reply, {error, bad_request}, Active},
       adk_live_gun_transport:handle_call(
         unsupported, {self(), make_ref()}, Active)),
    Closeable = Active#{connection => undefined,
                        stream_ref => undefined},
    ?assertEqual(
       {stop, normal, ok, Closeable},
       adk_live_gun_transport:handle_call(
         close, {self(), make_ref()}, Closeable)),

    HandoffRef = make_ref(),
    Awaiting = #{phase => awaiting_handoff,
                 handoff_ref => HandoffRef},
    ?assertEqual(
       {reply, {error, invalid_transport_handoff}, Awaiting},
       adk_live_gun_transport:handle_call(
         {handoff, make_ref(), self(), #{}},
         {self(), make_ref()}, Awaiting)),
    ?assertEqual(
       {reply, {error, transport_handoff_already_completed}, Active},
       adk_live_gun_transport:handle_call(
         {handoff, HandoffRef, self(), #{}},
         {self(), make_ref()}, Active)),
    ?assertEqual(
       {stop, normal, Awaiting},
       adk_live_gun_transport:handle_info(handoff_timeout, Awaiting)),

    OwnerMonitor = make_ref(),
    Owned = Active#{owner_monitor => OwnerMonitor},
    ?assertEqual(
       {stop, normal, Owned},
       adk_live_gun_transport:handle_info(
         {'DOWN', OwnerMonitor, process, self(), shutdown}, Owned)),
    ?assertEqual(
       {noreply, Active},
       adk_live_gun_transport:handle_info(ignored, Active)),
    ?assertEqual({ok, Active},
                 adk_live_gun_transport:code_change(old, Active, extra)),
    ?assertEqual(ok,
                 adk_live_gun_transport:terminate(normal, Closeable)).

format_status_redacts_credentials_and_messages_test() ->
    Secret = <<"credential-and-endpoint-must-not-leak">>,
    Status = #{state => #{phase => active,
                          ws_flow => 2,
                          max_server_frame_bytes => 4096,
                          credential_ref => Secret,
                          endpoint_path => Secret},
               message => {send, Secret},
               log => [Secret],
               reason => {failed, Secret},
               extra => Secret},
    Safe = adk_live_gun_transport:format_status(Status),
    ?assertEqual(#{phase => active, connected => true, flow => 2,
                   max_server_frame_bytes => 4096},
                 maps:get(state, Safe)),
    ?assertEqual([], maps:get(log, Safe)),
    Marker = adk_secret_redactor:marker(),
    ?assertEqual(Marker, maps:get(message, Safe)),
    ?assertEqual(Marker, maps:get(reason, Safe)),
    ?assertEqual(Marker, maps:get(extra, Safe)),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Safe), Secret)).

gun_event_handler_no_op_surface_test() ->
    State = #{owner => self(), marker => make_ref()},
    Event = #{stream_ref => make_ref(), private => <<"not retained">>},
    NoOpCallbacks =
        [init,
         domain_lookup_start, domain_lookup_end,
         connect_start, connect_end,
         tls_handshake_start, tls_handshake_end,
         request_start, request_headers, request_end,
         push_promise_start, push_promise_end,
         response_start, response_inform, response_headers,
         response_trailers, response_end,
         ws_upgrade,
         ws_recv_frame_start, ws_recv_frame_header, ws_recv_frame_end,
         ws_send_frame_start,
         protocol_changed, origin_changed, cancel, disconnect, terminate],
    lists:foreach(
      fun(Callback) ->
          ?assertEqual(
             State,
             apply(adk_live_gun_event_h, Callback, [Event, State]))
      end, NoOpCallbacks),
    assert_no_gun_event().

gun_event_handler_send_end_fallbacks_test() ->
    StreamRef = make_ref(),
    MissingStream = #{owner => self(), marker => make_ref()},
    ?assertEqual(
       MissingStream,
       adk_live_gun_event_h:ws_send_frame_end(
         #{different_event => true}, MissingStream)),
    NonPidOwner = #{owner => not_a_pid, marker => make_ref()},
    ?assertEqual(
       NonPidOwner,
       adk_live_gun_event_h:ws_send_frame_end(
         #{stream_ref => StreamRef}, NonPidOwner)),
    assert_no_gun_event().

gun_options(Options) ->
    {ok, Checked} = adk_live_gun_transport:validate_options(Options),
    {ok, GunOptions} = adk_live_gun_transport:gun_options(Checked),
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
      ws_flow => 1,
      max_server_frame_bytes => 4096}.

assert_closed(Event, State, ExpectedReason) ->
    {stop, normal, Closed} =
        adk_live_gun_transport:handle_info(Event, State),
    ?assertEqual(true, maps:get(notified_closed, Closed)),
    assert_transport_message({closed, ExpectedReason}).

assert_transport_message(Expected) ->
    receive
        {adk_live_transport, Sender, Expected} ->
            ?assertEqual(self(), Sender)
    after 0 ->
        erlang:error({transport_message_missing, Expected})
    end.

assert_no_transport_message() ->
    receive
        {adk_live_transport, _, _} = Unexpected ->
            erlang:error({unexpected_transport_message, Unexpected})
    after 0 -> ok
    end.

assert_no_gun_event() ->
    receive
        {adk_live_gun_event, _, _} = Unexpected ->
            erlang:error({unexpected_gun_event, Unexpected})
    after 0 -> ok
    end.

fake_gun_loop(TestPid) ->
    receive
        stop ->
            ok;
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

fake_transport_handle_loop(TestPid) ->
    receive
        {'$gen_call', From, {send, _Frame} = Request} ->
            TestPid ! {fake_transport_call, Request},
            gen_server:reply(From, {ok, make_ref()}),
            fake_transport_handle_loop(TestPid);
        {'$gen_call', From, close} ->
            TestPid ! {fake_transport_call, close},
            gen_server:reply(From, ok);
        {'$gen_cast', Request} ->
            TestPid ! {fake_transport_cast, Request},
            fake_transport_handle_loop(TestPid)
    end.
