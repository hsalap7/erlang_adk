-module(adk_live_session_test).

-include_lib("eunit/include/eunit.hrl").

-define(PRINCIPAL, <<"principal-live-test">>).

live_session_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun setup_gating_authorization_and_input_case/0,
      fun current_gemini_server_content_advances_one_turn_case/0,
      fun bounded_ingress_backpressure_case/0,
      fun bounded_subscriber_admission_and_recovery_case/0,
      fun outbound_credit_waits_for_transport_consumption_case/0,
      fun interruption_preserves_accepted_input_and_has_priority_case/0,
      fun synchronous_tool_ids_and_cancellation_case/0,
      fun duplicate_tool_call_closes_synchronous_stream_case/0,
      fun excess_tool_call_closes_synchronous_stream_case/0,
      fun raw_api_key_is_replaced_by_opaque_credential_case/0,
      fun resumption_handle_is_not_exposed_case/0,
      fun reconnect_uses_latest_handle_without_replaying_input_case/0,
      fun go_away_proactively_resumes_case/0,
      fun starter_death_does_not_own_live_session_case/0]}.

setup() ->
    case whereis(adk_live_session_sup) of
        undefined ->
            {ok, Pid} = adk_live_session_sup:start_link(),
            unlink(Pid),
            {started, Pid};
        Pid -> {existing, Pid}
    end.

cleanup({started, Pid}) ->
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 ->
        erlang:demonitor(Ref, [flush]),
        ok
    end;
cleanup({existing, _Pid}) -> ok.

setup_gating_authorization_and_input_case() ->
    {SessionId, Session, Handle, SetupFrame} = start_session(#{}),
    #{<<"setup">> := _} = jsx:decode(SetupFrame, [return_maps]),
    ?assertMatch({error, {not_ready, setup_pending}},
                 adk_live_session:send_text(
                   Session, ?PRINCIPAL, <<"too early">>)),
    {ok, _} = adk_live_session:subscribe(
                Session, ?PRINCIPAL,
                #{messages => 4, bytes => 1048576}),
    adk_live_fake_transport:inject(
      Handle, #{<<"setupComplete">> => #{}}),
    {ReadySequence, Ready} = receive_event(SessionId),
    ?assertEqual(ready, adk_live_event:kind(Ready)),
    ok = adk_live_session:ack(Session, ?PRINCIPAL, ReadySequence),
    {ok, 1} = adk_live_session:send_text(
                Session, ?PRINCIPAL, <<"hello live">>),
    TextFrame = receive_sent(Handle),
    #{<<"realtimeInput">> := #{<<"text">> := <<"hello live">>}} =
        jsx:decode(TextFrame, [return_maps]),
    ?assertEqual({error, not_found},
                 adk_live_session:status(Session, <<"other-principal">>)),
    {ok, Status} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(active, maps:get(state, Status)),
    ?assertEqual(0, maps:get(input_queue_messages, Status)),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

current_gemini_server_content_advances_one_turn_case() ->
    {SessionId, Session, Handle, _SetupFrame} = start_session(#{}),
    make_ready_without_subscriber(Session, Handle),
    {ok, #{latest_sequence := BeforeSequence,
           turn_epoch := 0}} =
        adk_live_session:subscribe(
          Session, ?PRINCIPAL, #{messages => 2, bytes => 4096}),

    adk_live_fake_transport:inject(
      Handle,
      #{<<"serverContent">> =>
            #{<<"interimInputTranscription">> =>
                  #{<<"text">> => <<"hel">>,
                    <<"languageCode">> => <<"en-US">>},
              <<"turnComplete">> => true,
              <<"turnCompleteReason">> => <<"NEED_MORE_INPUT">>,
              <<"waitingForInput">> => true}}),

    {InterimSequence, Interim} = receive_event(SessionId),
    ?assertEqual(BeforeSequence + 1, InterimSequence),
    ?assertEqual(input_transcription, adk_live_event:kind(Interim)),
    ?assertEqual(#{text => <<"hel">>, final => false},
                 maps:get(payload, Interim)),
    ?assertEqual(0, maps:get(turn_epoch, Interim)),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Interim), <<"en-US">>)),

    {TurnSequence, TurnComplete} = receive_event(SessionId),
    ?assertEqual(InterimSequence + 1, TurnSequence),
    ?assertEqual(turn_complete, adk_live_event:kind(TurnComplete)),
    ?assertEqual(#{reason => <<"NEED_MORE_INPUT">>,
                   waiting_for_input => true},
                 maps:get(payload, TurnComplete)),
    ?assertEqual(0, maps:get(turn_epoch, TurnComplete)),

    {ok, Status} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(active, maps:get(state, Status)),
    ?assertEqual(1, maps:get(turn_epoch, Status)),
    ?assertEqual(0, maps:get(generation_epoch, Status)),
    ?assertEqual(TurnSequence, maps:get(latest_sequence, Status)),
    ?assert(is_process_alive(Session)),
    {ok, 1} = adk_live_session:send_text(
                Session, ?PRINCIPAL, <<"still active">>),
    #{<<"realtimeInput">> := #{<<"text">> := <<"still active">>}} =
        jsx:decode(receive_sent(Handle), [return_maps]),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

bounded_ingress_backpressure_case() ->
    Overrides = #{max_ingress_messages => 2,
                  max_ingress_bytes => 4096},
    {_SessionId, Session, Handle, _SetupFrame} = start_session(Overrides),
    make_ready_without_subscriber(Session, Handle),
    ok = adk_live_fake_transport:set_busy(Handle, true),
    {ok, Media} = adk_live_media:audio_pcm(
                    binary:copy(<<0>>, 256), 16000, 1),
    ?assertMatch({ok, 1},
                 adk_live_session:send_audio(Session, ?PRINCIPAL, Media)),
    ?assertMatch({ok, 2},
                 adk_live_session:send_audio(Session, ?PRINCIPAL, Media)),
    ?assertEqual({error, ingress_backpressure},
                 adk_live_session:send_audio(
                   Session, ?PRINCIPAL, Media)),
    {ok, FullStatus} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(2, maps:get(input_queue_messages, FullStatus)),
    ok = adk_live_fake_transport:writable(Handle),
    _ = receive_sent(Handle),
    _ = receive_sent(Handle),
    wait_for_empty_ingress(Session, 50),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

bounded_subscriber_admission_and_recovery_case() ->
    {_SessionId, Session, Handle, _SetupFrame} =
        start_session(#{max_subscribers => 2}),
    make_ready_without_subscriber(Session, Handle),
    Parent = self(),
    Credit = #{messages => 2, bytes => 4096},
    Subscribers = [spawn(fun() ->
                              receive subscribe_now -> ok end,
                              Result = adk_live_session:subscribe(
                                         Session, ?PRINCIPAL, Credit),
                              Parent ! {subscriber_result, self(), Result},
                              receive stop -> ok end
                         end) || _ <- lists:seq(1, 3)],
    lists:foreach(fun(Pid) -> Pid ! subscribe_now end, Subscribers),
    Results = collect_subscriber_results(3, []),
    Accepted = [Pid || {Pid, {ok, _}} <- Results],
    Rejected = [Pid || {Pid, {error, subscriber_limit}} <- Results],
    ?assertEqual(2, length(Accepted)),
    ?assertEqual(1, length(Rejected)),
    wait_for_subscriber_count(Session, 2, 50),
    {ok, FullStatus} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(2, maps:get(max_subscribers, FullStatus)),

    [Detached, Dying] = Accepted,
    [Retrying] = Rejected,
    ok = adk_live_session:unsubscribe(Session, ?PRINCIPAL, Detached),
    wait_for_subscriber_count(Session, 1, 50),
    {ok, _} = adk_live_session:subscribe(
                Session, ?PRINCIPAL, Retrying, Credit),
    wait_for_subscriber_count(Session, 2, 50),

    exit(Dying, kill),
    wait_for_subscriber_count(Session, 1, 50),
    Replacement = spawn(fun() -> receive stop -> ok end end),
    {ok, _} = adk_live_session:subscribe(
                Session, ?PRINCIPAL, Replacement, Credit),
    wait_for_subscriber_count(Session, 2, 50),
    lists:foreach(fun(Pid) -> Pid ! stop end,
                  [Detached, Retrying, Replacement]),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

outbound_credit_waits_for_transport_consumption_case() ->
    Overrides = #{max_ingress_messages => 2,
                  max_ingress_bytes => 4096},
    {_SessionId, Session, Handle, _SetupFrame} = start_session(Overrides),
    make_ready_without_subscriber(Session, Handle),
    ok = adk_live_fake_transport:set_auto_ack(Handle, false),
    {ok, Media} = adk_live_media:audio_pcm(
                    binary:copy(<<0>>, 256), 16000, 1),
    {ok, 1} = adk_live_session:send_audio(Session, ?PRINCIPAL, Media),
    _FirstFrame = receive_sent(Handle),
    {ok, FirstPending} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(1, maps:get(input_queue_messages, FirstPending)),
    {ok, 2} = adk_live_session:send_audio(Session, ?PRINCIPAL, Media),
    ?assertEqual(
       {error, ingress_backpressure},
       adk_live_session:send_audio(Session, ?PRINCIPAL, Media)),
    ok = adk_live_fake_transport:ack_sent(Handle),
    _SecondFrame = receive_sent(Handle),
    {ok, SecondPending} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(1, maps:get(input_queue_messages, SecondPending)),
    ok = adk_live_fake_transport:ack_sent(Handle),
    wait_for_empty_ingress(Session, 50),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

interruption_preserves_accepted_input_and_has_priority_case() ->
    {SessionId, Session, Handle, _SetupFrame} = start_session(#{}),
    {ok, _} = adk_live_session:subscribe(
                Session, ?PRINCIPAL,
                #{messages => 1, bytes => 1048576}),
    adk_live_fake_transport:inject(
      Handle, #{<<"setupComplete">> => #{}}),
    {ReadySequence, Ready} = receive_event(SessionId),
    ?assertEqual(ready, adk_live_event:kind(Ready)),

    %% Keep one input audio frame queued at a busy transport.
    ok = adk_live_fake_transport:set_busy(Handle, true),
    {ok, InputAudio} = adk_live_media:audio_pcm(
                         <<0, 0, 1, 0>>, 16000, 1),
    {ok, _} = adk_live_session:send_audio(
                Session, ?PRINCIPAL, InputAudio),

    %% Output audio cannot consume subscriber credit while Ready is in flight.
    ProviderAudio =
      #{<<"serverContent">> =>
            #{<<"modelTurn">> =>
                  #{<<"parts">> =>
                        [#{<<"inlineData">> =>
                               #{<<"mimeType">> =>
                                     <<"audio/pcm;rate=24000">>,
                                 <<"data">> =>
                                     base64:encode(<<0, 0, 1, 0>>)}}]}}},
    adk_live_fake_transport:inject(Handle, ProviderAudio),
    adk_live_fake_transport:inject(
      Handle,
      #{<<"serverContent">> => #{<<"interrupted">> => true}}),

    %% Calls and transport notifications have different senders. Wait until
    %% the session has committed the priority interruption before returning
    %% subscriber credit.
    wait_for_generation(Session, 1, 50),
    ok = adk_live_session:ack(Session, ?PRINCIPAL, ReadySequence),
    {InterruptedSequence, Interrupted} = receive_event(SessionId),
    ?assertEqual(interrupted, adk_live_event:kind(Interrupted)),
    ?assertEqual(0, maps:get(generation_epoch, Interrupted)),
    assert_no_audio_event(SessionId),
    ok = adk_live_session:ack(
           Session, ?PRINCIPAL, InterruptedSequence),
    {ok, Status} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(1, maps:get(input_queue_messages, Status)),
    ?assertEqual(1, maps:get(generation_epoch, Status)),
    ok = adk_live_fake_transport:writable(Handle),
    InputFrame = receive_sent(Handle),
    #{<<"realtimeInput">> := #{<<"audio">> := _}} =
        jsx:decode(InputFrame, [return_maps]),
    wait_for_empty_ingress(Session, 50),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

synchronous_tool_ids_and_cancellation_case() ->
    {_SessionId, Session, Handle, _SetupFrame} = start_session(#{}),
    make_ready_without_subscriber(Session, Handle),
    inject_tool_call(Handle, <<"call-1">>, <<"weather">>),
    wait_for_pending_tools(Session, 1, 50),
    {ok, 1} = adk_live_session:send_tool_response(
                Session, ?PRINCIPAL, <<"call-1">>, <<"weather">>,
                #{<<"temperature">> => 29}),
    ResponseFrame = receive_sent(Handle),
    #{<<"toolResponse">> := #{<<"functionResponses">> := [Response]}} =
        jsx:decode(ResponseFrame, [return_maps]),
    ?assertEqual(<<"call-1">>, maps:get(<<"id">>, Response)),
    ?assertEqual(
       {error, unknown_or_cancelled_tool_call},
       adk_live_session:send_tool_response(
         Session, ?PRINCIPAL, <<"call-1">>, <<"weather">>, #{})),

    inject_tool_call(Handle, <<"call-2">>, <<"clock">>),
    wait_for_pending_tools(Session, 1, 50),
    ok = adk_live_fake_transport:set_busy(Handle, true),
    {ok, 2} = adk_live_session:send_tool_response(
                Session, ?PRINCIPAL, <<"call-2">>, <<"clock">>,
                #{<<"time">> => <<"12:00">>}),
    adk_live_fake_transport:inject(
      Handle,
      #{<<"toolCallCancellation">> => #{<<"ids">> => [<<"call-2">>]}}),
    wait_for_empty_ingress(Session, 50),
    ok = adk_live_fake_transport:writable(Handle),
    assert_no_sent_frame(Handle),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

duplicate_tool_call_closes_synchronous_stream_case() ->
    {_SessionId, Session, Handle, _SetupFrame} = start_session(#{}),
    make_ready_without_subscriber(Session, Handle),
    inject_tool_call(Handle, <<"duplicate-call">>, <<"weather">>),
    wait_for_pending_tools(Session, 1, 50),
    inject_tool_call(Handle, <<"duplicate-call">>, <<"weather">>),
    wait_for_state(Session, closed, 50),
    receive
        {adk_live_fake_transport, closed, Handle,
         invalid_tool_call_sequence} -> ok
    after 1000 ->
        ?assert(false)
    end.

excess_tool_call_closes_synchronous_stream_case() ->
    {_SessionId, Session, Handle, _SetupFrame} = start_session(#{}),
    make_ready_without_subscriber(Session, Handle),
    Calls = [#{<<"id">> => <<"call-", (integer_to_binary(I))/binary>>,
               <<"name">> => <<"weather">>, <<"args">> => #{}}
             || I <- lists:seq(1, 128)],
    adk_live_fake_transport:inject(
      Handle, #{<<"toolCall">> => #{<<"functionCalls">> => Calls}}),
    wait_for_pending_tools(Session, 128, 50),
    inject_tool_call(Handle, <<"call-129">>, <<"weather">>),
    wait_for_state(Session, closed, 50),
    receive
        {adk_live_fake_transport, closed, Handle,
         invalid_tool_call_sequence} -> ok
    after 1000 ->
        ?assert(false)
    end.

raw_api_key_is_replaced_by_opaque_credential_case() ->
    Secret = <<"never-retain-this-live-key">>,
    TransportOptions = #{test_pid => self(), api_key => Secret},
    {_SessionId, Session, Handle, _SetupFrame} =
        start_session(#{transport_opts => TransportOptions}),
    make_ready_without_subscriber(Session, Handle),
    {active, SessionData} = sys:get_state(Session),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(SessionData), Secret)),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(sys:get_state(Handle)),
                              Secret)),
    CredentialRef = maps:get(credential_ref, SessionData),
    {ok, Secret} = adk_live_credential_broker:resolve(CredentialRef),
    {adk_live_credential, Broker, _Token} = CredentialRef,
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(sys:get_state(Broker)),
                              Secret)),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done),
    ?assertEqual({error, credential_unavailable},
                 adk_live_credential_broker:resolve(CredentialRef)).

resumption_handle_is_not_exposed_case() ->
    {SessionId, Session, Handle, _SetupFrame} = start_session(#{}),
    {ok, _} = adk_live_session:subscribe(
                Session, ?PRINCIPAL,
                #{messages => 4, bytes => 1048576}),
    adk_live_fake_transport:inject(
      Handle, #{<<"setupComplete">> => #{}}),
    {ReadySequence, _Ready} = receive_event(SessionId),
    ok = adk_live_session:ack(Session, ?PRINCIPAL, ReadySequence),
    PrivateHandle = <<"very-private-resumption-handle">>,
    adk_live_fake_transport:inject(
      Handle,
      #{<<"sessionResumptionUpdate">> =>
            #{<<"newHandle">> => PrivateHandle,
              <<"resumable">> => true}}),
    {_Sequence, Event} = receive_event(SessionId),
    ?assertEqual(resumption_status, adk_live_event:kind(Event)),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Event), PrivateHandle)),
    {ok, Status} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(true, maps:get(resumable, Status)),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Status), PrivateHandle)),
    Diagnostic = sys:get_status(Session),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Diagnostic), PrivateHandle)),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

reconnect_uses_latest_handle_without_replaying_input_case() ->
    Overrides = #{provider_config => #{session_resumption => true},
                  max_reconnect_attempts => 2,
                  reconnect_backoff_ms => 10},
    {_SessionId, Session, Handle, _SetupFrame} = start_session(Overrides),
    make_ready_without_subscriber(Session, Handle),
    ResumeHandle = <<"latest-provider-handle">>,
    adk_live_fake_transport:inject(
      Handle,
      #{<<"sessionResumptionUpdate">> =>
            #{<<"newHandle">> => ResumeHandle,
              <<"resumable">> => true}}),
    wait_for_resumable(Session, 50),

    %% This input is admitted locally but cannot be handed to the busy old
    %% transport. It must be discarded explicitly at the continuity gap.
    ok = adk_live_fake_transport:set_busy(Handle, true),
    {ok, 1} = adk_live_session:send_text(
                Session, ?PRINCIPAL, <<"do not replay me">>),
    ok = adk_live_fake_transport:disconnect(Handle, network_lost),
    wait_for_state(Session, reconnecting, 50),
    NewHandle = receive
        {adk_live_fake_transport, opened, Reopened}
          when Reopened =/= Handle -> Reopened
    after 1000 ->
        ?assert(false)
    end,
    ResumeSetupFrame = receive_sent(NewHandle),
    #{<<"setup">> := ResumeSetup} =
        jsx:decode(ResumeSetupFrame, [return_maps]),
    ?assertEqual(
       ResumeHandle,
       maps:get(<<"handle">>,
                maps:get(<<"sessionResumption">>, ResumeSetup))),
    assert_no_sent_frame(NewHandle),
    {ok, ReconnectingStatus} =
        adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(0, maps:get(input_queue_messages, ReconnectingStatus)),
    ?assertEqual(false, maps:get(replayed_inputs, ReconnectingStatus)),

    adk_live_fake_transport:inject(
      NewHandle, #{<<"setupComplete">> => #{}}),
    wait_for_state(Session, active, 50),
    {ok, ActiveStatus} = adk_live_session:status(Session, ?PRINCIPAL),
    %% The consumed handle is never reused. A new provider update is required
    %% before another resumption can be attempted.
    ?assertEqual(false, maps:get(resumable, ActiveStatus)),
    {ok, 2} = adk_live_session:send_text(
                Session, ?PRINCIPAL, <<"new input">>),
    NewInput = receive_sent(NewHandle),
    #{<<"realtimeInput">> := #{<<"text">> := <<"new input">>}} =
        jsx:decode(NewInput, [return_maps]),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

go_away_proactively_resumes_case() ->
    Overrides = #{provider_config => #{session_resumption => true},
                  max_reconnect_attempts => 1,
                  reconnect_backoff_ms => 10},
    {_SessionId, Session, Handle, _SetupFrame} = start_session(Overrides),
    make_ready_without_subscriber(Session, Handle),
    ResumeHandle = <<"go-away-resumption-handle">>,
    adk_live_fake_transport:inject(
      Handle,
      #{<<"sessionResumptionUpdate">> =>
            #{<<"newHandle">> => ResumeHandle,
              <<"resumable">> => true}}),
    wait_for_resumable(Session, 50),
    adk_live_fake_transport:inject(
      Handle, #{<<"goAway">> => #{<<"timeLeft">> => <<"5s">>}}),
    wait_for_state(Session, reconnecting, 50),
    NewHandle = receive
        {adk_live_fake_transport, opened, Reopened}
          when Reopened =/= Handle -> Reopened
    after 1000 ->
        ?assert(false)
    end,
    ResumeFrame = receive_sent(NewHandle),
    #{<<"setup">> := Setup} = jsx:decode(ResumeFrame, [return_maps]),
    ?assertEqual(
       ResumeHandle,
       maps:get(<<"handle">>,
                maps:get(<<"sessionResumption">>, Setup))),
    adk_live_fake_transport:inject(
      NewHandle, #{<<"setupComplete">> => #{}}),
    wait_for_state(Session, active, 50),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

starter_death_does_not_own_live_session_case() ->
    SessionId = <<"detached-live-", (integer_to_binary(
                                      erlang:unique_integer([positive])))/binary>>,
    Parent = self(),
    Config = #{provider => adk_live_gemini,
               provider_config => #{},
               transport => adk_live_fake_transport,
               transport_opts => #{test_pid => Parent}},
    {Starter, StarterRef} = spawn_monitor(
      fun() ->
          Parent ! {detached_start,
                    adk_live_session_sup:start_session(
                      SessionId, ?PRINCIPAL, Config)}
      end),
    Session = receive
        {detached_start, {ok, Pid}} -> Pid
    after 1000 ->
        ?assert(false)
    end,
    receive
        {'DOWN', StarterRef, process, Starter, normal} -> ok
    after 1000 ->
        ?assert(false)
    end,
    Handle = receive
        {adk_live_fake_transport, opened, OpenedHandle} -> OpenedHandle
    after 1000 ->
        ?assert(false)
    end,
    _ = receive_sent(Handle),
    ?assert(is_process_alive(Session)),
    adk_live_fake_transport:inject(
      Handle, #{<<"setupComplete">> => #{}}),
    wait_for_state(Session, active, 50),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

start_session(Overrides) ->
    SessionId = <<"live-", (integer_to_binary(
                              erlang:unique_integer([positive])))/binary>>,
    Base = #{provider => adk_live_gemini,
             provider_config => #{},
             transport => adk_live_fake_transport,
             transport_opts => #{test_pid => self()}},
    Config = maps:merge(Base, Overrides),
    {ok, Session} = adk_live_session_sup:start_session(
                      SessionId, ?PRINCIPAL, Config),
    Handle = receive
        {adk_live_fake_transport, opened, OpenedHandle} -> OpenedHandle
    after 1000 ->
        ?assert(false)
    end,
    SetupFrame = receive_sent(Handle),
    {SessionId, Session, Handle, SetupFrame}.

inject_tool_call(Handle, Id, Name) ->
    adk_live_fake_transport:inject(
      Handle,
      #{<<"toolCall">> =>
            #{<<"functionCalls">> =>
                  [#{<<"id">> => Id,
                     <<"name">> => Name,
                     <<"args">> => #{}}]}}).

make_ready_without_subscriber(Session, Handle) ->
    adk_live_fake_transport:inject(
      Handle, #{<<"setupComplete">> => #{}}),
    wait_for_state(Session, active, 50).

receive_sent(Handle) ->
    receive
        {adk_live_fake_transport, sent, Handle, Frame} -> Frame
    after 1000 ->
        ?assert(false)
    end.

receive_event(SessionId) ->
    receive
        {adk_live_event, SessionId, Sequence, Event} -> {Sequence, Event}
    after 1000 ->
        ?assert(false)
    end.

assert_no_audio_event(SessionId) ->
    receive
        {adk_live_event, SessionId, _Sequence,
         #{kind := audio}} -> ?assert(false)
    after 50 ->
        ok
    end.

assert_no_sent_frame(Handle) ->
    receive
        {adk_live_fake_transport, sent, Handle, _Frame} -> ?assert(false)
    after 50 ->
        ok
    end.

wait_for_state(_Session, _Expected, 0) ->
    ?assert(false);
wait_for_state(Session, Expected, Remaining) ->
    case adk_live_session:status(Session, ?PRINCIPAL) of
        {ok, #{state := Expected}} -> ok;
        _ ->
            receive after 10 -> ok end,
            wait_for_state(Session, Expected, Remaining - 1)
    end.

wait_for_empty_ingress(_Session, 0) ->
    ?assert(false);
wait_for_empty_ingress(Session, Remaining) ->
    case adk_live_session:status(Session, ?PRINCIPAL) of
        {ok, #{input_queue_messages := 0}} -> ok;
        _ ->
            receive after 10 -> ok end,
            wait_for_empty_ingress(Session, Remaining - 1)
    end.

wait_for_generation(_Session, _Expected, 0) ->
    ?assert(false);
wait_for_generation(Session, Expected, Remaining) ->
    case adk_live_session:status(Session, ?PRINCIPAL) of
        {ok, #{generation_epoch := Expected}} -> ok;
        _ ->
            receive after 10 -> ok end,
            wait_for_generation(Session, Expected, Remaining - 1)
    end.

wait_for_resumable(_Session, 0) ->
    ?assert(false);
wait_for_resumable(Session, Remaining) ->
    case adk_live_session:status(Session, ?PRINCIPAL) of
        {ok, #{resumable := true}} -> ok;
        _ ->
            receive after 10 -> ok end,
            wait_for_resumable(Session, Remaining - 1)
    end.

wait_for_pending_tools(_Session, _Expected, 0) ->
    ?assert(false);
wait_for_pending_tools(Session, Expected, Remaining) ->
    case adk_live_session:status(Session, ?PRINCIPAL) of
        {ok, #{pending_tool_calls := Expected}} -> ok;
        _ ->
            receive after 10 -> ok end,
            wait_for_pending_tools(Session, Expected, Remaining - 1)
    end.

collect_subscriber_results(0, Acc) -> Acc;
collect_subscriber_results(Remaining, Acc) ->
    receive
        {subscriber_result, Pid, Result} ->
            collect_subscriber_results(Remaining - 1,
                                       [{Pid, Result} | Acc])
    after 1000 ->
        ?assert(false)
    end.

wait_for_subscriber_count(_Session, _Expected, 0) ->
    ?assert(false);
wait_for_subscriber_count(Session, Expected, Remaining) ->
    case adk_live_session:status(Session, ?PRINCIPAL) of
        {ok, #{subscriber_count := Expected}} -> ok;
        _ ->
            receive after 10 -> ok end,
            wait_for_subscriber_count(Session, Expected, Remaining - 1)
    end.
