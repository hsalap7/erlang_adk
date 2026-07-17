-module(adk_live_voice_bridge_test).
-include_lib("eunit/include/eunit.hrl").

-define(PRINCIPAL, <<"live-voice-bridge-principal">>).

exact_pending_ack_controls_subscriber_credit_test() ->
    Fixture = start_fixture(#{},
                            #{credit => #{messages => 1, bytes => 4096}}),
    try
        #{bridge := Bridge, handle := Handle} = Fixture,
        inject_output_transcription(Handle, <<"first answer">>, true),
        {FirstSequence,
         <<1, 130, FirstSequence:64/unsigned-big,
           2, 1, "first answer">>} = receive_voice_frame(Bridge),
        inject_output_transcription(Handle, <<"bounded answer">>, true),
        assert_no_voice_frame(Bridge),

        ok = erlang_adk:live_voice_frame(
               Bridge, <<1, 3, FirstSequence:64/unsigned-big>>),
        {TranscriptSequence,
         <<1, 130, TranscriptSequence:64/unsigned-big,
           2, 1, "bounded answer">>} = receive_voice_frame(Bridge),
        ?assertEqual(
           {error, unknown_live_voice_event_sequence},
           erlang_adk:live_voice_frame(
             Bridge, <<1, 3, FirstSequence:64/unsigned-big>>)),
        ok = erlang_adk:live_voice_frame(
               Bridge, <<1, 3, TranscriptSequence:64/unsigned-big>>)
    after
        cleanup(Fixture)
    end.

multi_chunk_audio_is_forwarded_byte_exact_in_order_under_credit_test() ->
    Fixture = start_fixture(#{},
                            #{credit => #{messages => 2, bytes => 4096}}),
    try
        #{bridge := Bridge, handle := Handle} = Fixture,
        Pcm1 = <<0, 0, 1, 0, 255, 127, 0, 128>>,
        Pcm2 = <<16#34, 16#12, 16#cc, 16#ed>>,
        Pcm3 = <<2, 0, 3, 0, 4, 0>>,
        adk_live_fake_transport:inject(
          Handle,
          #{<<"serverContent">> =>
                #{<<"modelTurn">> =>
                      #{<<"parts">> =>
                            [gemini_audio_part(Pcm1),
                             gemini_audio_part(Pcm2),
                             gemini_audio_part(Pcm3)]}}}),

        {FirstSequence,
         <<1, 129, FirstSequence:64/unsigned-big,
           24000:32/unsigned-big, 1, FirstPcm/binary>>} =
            receive_voice_frame(Bridge),
        {SecondSequence,
         <<1, 129, SecondSequence:64/unsigned-big,
           24000:32/unsigned-big, 1, SecondPcm/binary>>} =
            receive_voice_frame(Bridge),
        ?assertEqual(Pcm1, FirstPcm),
        ?assertEqual(Pcm2, SecondPcm),
        ?assertEqual(FirstSequence + 1, SecondSequence),
        assert_no_voice_frame(Bridge),

        ok = ack(Bridge, FirstSequence),
        {ThirdSequence,
         <<1, 129, ThirdSequence:64/unsigned-big,
           24000:32/unsigned-big, 1, ThirdPcm/binary>>} =
            receive_voice_frame(Bridge),
        ?assertEqual(Pcm3, ThirdPcm),
        ?assertEqual(SecondSequence + 1, ThirdSequence),
        ?assertEqual(<<Pcm1/binary, Pcm2/binary, Pcm3/binary>>,
                     <<FirstPcm/binary, SecondPcm/binary, ThirdPcm/binary>>),
        ok = ack(Bridge, SecondSequence),
        ok = ack(Bridge, ThirdSequence)
    after
        cleanup(Fixture)
    end.

non_public_events_are_acked_without_reaching_owner_test() ->
    Fixture = start_fixture(#{},
                            #{credit => #{messages => 1, bytes => 4096}}),
    try
        #{bridge := Bridge, handle := Handle} = Fixture,
        adk_live_fake_transport:inject(
          Handle,
          #{<<"serverContent">> => #{},
            <<"usageMetadata">> => #{<<"totalTokenCount">> => 1}}),
        Pcm = <<0, 0, 1, 0>>,
        inject_audio(Handle, Pcm),
        {AudioSequence,
         <<1, 129, AudioSequence:64/unsigned-big,
           24000:32/unsigned-big, 1, Pcm/binary>>} =
            receive_voice_frame(Bridge),
        ok = ack(Bridge, AudioSequence),
        assert_no_voice_frame(Bridge)
    after
        cleanup(Fixture)
    end.

audio_input_is_strictly_sequenced_and_bounded_test() ->
    Fixture = start_fixture(#{}, #{max_audio_frame_bytes => 8}),
    try
        #{bridge := Bridge, handle := Handle} = Fixture,
        Pcm = <<0, 0, 1, 0>>,
        ?assertEqual(
           {error, {unexpected_live_voice_input_sample_rate, 16000}},
           erlang_adk:live_voice_frame(
             Bridge, audio_frame(1, 24000, Pcm))),
        {ok, 1} = erlang_adk:live_voice_frame(
                    Bridge, audio_frame(1, Pcm)),
        #{<<"realtimeInput">> := #{<<"audio">> := Blob1}} =
            decode_sent(Handle),
        ?assertEqual(<<"audio/pcm;rate=16000">>,
                     maps:get(<<"mimeType">>, Blob1)),

        ?assertEqual(
           {error, {out_of_order_live_voice_audio, 2}},
           erlang_adk:live_voice_frame(Bridge, audio_frame(1, Pcm))),
        ?assertEqual(
           {error, {out_of_order_live_voice_audio, 2}},
           erlang_adk:live_voice_frame(Bridge, audio_frame(3, Pcm))),
        {ok, 2} = erlang_adk:live_voice_frame(
                    Bridge, audio_frame(2, Pcm)),
        #{<<"realtimeInput">> := #{<<"audio">> := _Blob2}} =
            decode_sent(Handle),

        Oversized = binary:copy(<<0>>, 10),
        ?assertEqual(
           {error, live_voice_audio_frame_too_large},
           erlang_adk:live_voice_frame(
             Bridge, audio_frame(3, Oversized))),
        ?assertEqual(
           {error, invalid_live_voice_frame},
           erlang_adk:live_voice_frame(Bridge, <<1, 2, 0>>)),

        {ok, 3} = erlang_adk:live_voice_frame(Bridge, <<1, 2>>),
        #{<<"realtimeInput">> := #{<<"audioStreamEnd">> := true}} =
            decode_sent(Handle)
    after
        cleanup(Fixture)
    end.

trusted_24khz_input_format_is_derived_signalled_and_enforced_test() ->
    Fixture = start_openai_fixture(),
    try
        #{bridge := Bridge, handle := Handle} = Fixture,
        Pcm = <<0, 0, 1, 0, 255, 127, 0, 128>>,
        ?assertEqual(
           {error, {unexpected_live_voice_input_sample_rate, 24000}},
           erlang_adk:live_voice_frame(
             Bridge, audio_frame(1, 16000, Pcm))),
        {ok, 1} = erlang_adk:live_voice_frame(
                    Bridge, audio_frame(1, 24000, Pcm)),
        #{<<"type">> := <<"input_audio_buffer.append">>,
          <<"audio">> := Encoded} = decode_sent(Handle),
        ?assertEqual(Pcm, base64:decode(Encoded))
    after
        cleanup(Fixture)
    end.

manual_activity_controls_use_existing_live_legality_test() ->
    Fixture = start_fixture(#{automatic_activity_detection => false}, #{}),
    try
        #{bridge := Bridge, handle := Handle} = Fixture,
        {ok, 1} = erlang_adk:live_voice_frame(Bridge, <<1, 4>>),
        #{<<"realtimeInput">> := #{<<"activityStart">> := #{}}} =
            decode_sent(Handle),
        {ok, 2} = erlang_adk:live_voice_frame(Bridge, <<1, 5>>),
        #{<<"realtimeInput">> := #{<<"activityEnd">> := #{}}} =
            decode_sent(Handle),
        ?assertMatch(
           {error, {live_protocol_error, _, manual_vad_enabled}},
           erlang_adk:live_voice_frame(Bridge, <<1, 2>>))
    after
        cleanup(Fixture)
    end.

interruption_is_forwarded_with_stable_code_four_test() ->
    Fixture = start_fixture(#{}, #{}),
    try
        #{bridge := Bridge, handle := Handle} = Fixture,
        adk_live_fake_transport:inject(
          Handle,
          #{<<"serverContent">> => #{<<"interrupted">> => true}}),
        {InterruptedSequence,
         <<1, 131, InterruptedSequence:64/unsigned-big, 4>>} =
            receive_voice_frame(Bridge),
        ok = ack(Bridge, InterruptedSequence)
    after
        cleanup(Fixture)
    end.

bridge_calls_are_owner_only_test() ->
    Fixture = start_fixture(#{}, #{}),
    try
        #{bridge := Bridge} = Fixture,
        Parent = self(),
        Attacker = spawn(
                     fun() ->
                         Parent ! {attacker_frame,
                                   erlang_adk:live_voice_frame(
                                     Bridge, <<1, 2>>)},
                         Parent ! {attacker_stop,
                                   erlang_adk:stop_live_voice_bridge(Bridge)}
                     end),
        Ref = erlang:monitor(process, Attacker),
        receive
            {attacker_frame, FrameResult} ->
                ?assertEqual({error, not_live_voice_owner}, FrameResult)
        after 1000 -> erlang:error(attacker_frame_timeout)
        end,
        receive
            {attacker_stop, StopResult} ->
                ?assertEqual({error, not_live_voice_owner}, StopResult)
        after 1000 -> erlang:error(attacker_stop_timeout)
        end,
        receive {'DOWN', Ref, process, Attacker, normal} -> ok
        after 1000 -> erlang:error(attacker_down_timeout)
        end,
        ?assert(is_process_alive(Bridge)),
        ok = erlang_adk:stop_live_voice_bridge(Bridge),
        ?assertEqual({error, not_found},
                     erlang_adk:stop_live_voice_bridge(Bridge))
    after
        cleanup(Fixture)
    end.

owner_death_stops_and_unsubscribes_bridge_test() ->
    {SessionId, Session, Handle} = start_session(#{}),
    Owner = spawn(fun owner_wait/0),
    {ok, Bridge} = erlang_adk:start_live_voice_bridge(
                     Session, ?PRINCIPAL, Owner, #{}),
    Ref = erlang:monitor(process, Bridge),
    try
        {ok, Before} = erlang_adk:live_status(Session, ?PRINCIPAL),
        ?assertEqual(1, maps:get(subscriber_count, Before)),
        exit(Owner, kill),
        receive
            {'DOWN', Ref, process, Bridge, normal} -> ok
        after 1000 -> erlang:error(bridge_owner_down_timeout)
        end,
        wait_for_subscriber_count(Session, 0, 50),
        {ok, After} = erlang_adk:live_status(Session, ?PRINCIPAL),
        ?assertEqual(0, maps:get(subscriber_count, After)),
        {ok, Replacement} = erlang_adk:start_live_voice_bridge(
                              Session, ?PRINCIPAL, self(), #{}),
        ok = erlang_adk:stop_live_voice_bridge(Replacement)
    after
        catch exit(Owner, kill),
        _ = erlang_adk:close_live_session(
              Session, ?PRINCIPAL, owner_death_test_complete),
        flush_transport(Handle, SessionId)
    end.

exclusive_bridge_claim_is_race_safe_and_reusable_test() ->
    {SessionId, Session, Handle} = start_session(#{}),
    Parent = self(),
    Gate = make_ref(),
    Starters =
      [spawn(
         fun() ->
             receive {start, Gate} -> ok end,
             Result = erlang_adk:start_live_voice_bridge(
                        Session, ?PRINCIPAL, Parent, #{}),
             Parent ! {voice_start_result, self(), Result}
         end) || _ <- lists:seq(1, 8)],
    lists:foreach(fun(Pid) -> Pid ! {start, Gate} end, Starters),
    Results = collect_voice_start_results(length(Starters), []),
    Winners = [Bridge || {_Starter, {ok, Bridge}} <- Results],
    Rejected = [Reason || {_Starter, {error, Reason}} <- Results],
    try
        ?assertEqual(1, length(Winners)),
        ?assertEqual(
           lists:duplicate(7, live_voice_bridge_already_attached),
           lists:sort(Rejected)),
        {ok, Status} = erlang_adk:live_status(Session, ?PRINCIPAL),
        ?assertEqual(1, maps:get(subscriber_count, Status)),
        [Winner] = Winners,
        ok = erlang_adk:stop_live_voice_bridge(Winner),
        {ok, Replacement} = erlang_adk:start_live_voice_bridge(
                              Session, ?PRINCIPAL, self(), #{}),
        ok = erlang_adk:stop_live_voice_bridge(Replacement)
    after
        lists:foreach(
          fun(Bridge) -> _ = erlang_adk:stop_live_voice_bridge(Bridge) end,
          Winners),
        _ = erlang_adk:close_live_session(
              Session, ?PRINCIPAL, exclusive_claim_test_complete),
        flush_transport(Handle, SessionId)
    end.

exclusive_claim_is_scoped_to_each_live_session_test() ->
    {SessionIdA, SessionA, HandleA} = start_session(#{}),
    {SessionIdB, SessionB, HandleB} = start_session(#{}),
    Parent = self(),
    Gate = make_ref(),
    Starter =
      fun(Label, Session) ->
          spawn(
            fun() ->
                receive {start, Gate} -> ok end,
                Parent !
                    {parallel_voice_start, Label,
                     erlang_adk:start_live_voice_bridge(
                       Session, ?PRINCIPAL, Parent, #{})}
            end)
      end,
    StartA = Starter(a, SessionA),
    StartB = Starter(b, SessionB),
    StartA ! {start, Gate},
    StartB ! {start, Gate},
    Results = collect_parallel_voice_starts(2, #{}),
    try
        {ok, BridgeA} = maps:get(a, Results),
        {ok, BridgeB} = maps:get(b, Results),
        ?assert(BridgeA =/= BridgeB),
        ok = erlang_adk:stop_live_voice_bridge(BridgeA),
        ok = erlang_adk:stop_live_voice_bridge(BridgeB)
    after
        stop_parallel_result(a, Results),
        stop_parallel_result(b, Results),
        _ = erlang_adk:close_live_session(
              SessionA, ?PRINCIPAL, parallel_claim_test_complete),
        _ = erlang_adk:close_live_session(
              SessionB, ?PRINCIPAL, parallel_claim_test_complete),
        flush_transport(HandleA, SessionIdA),
        flush_transport(HandleB, SessionIdB)
    end.

killed_bridge_lease_is_cleaned_by_registry_monitor_test() ->
    Fixture = start_fixture(#{}, #{}),
    #{bridge := Bridge, session := Session} = Fixture,
    Ref = erlang:monitor(process, Bridge),
    try
        exit(Bridge, kill),
        receive
            {'DOWN', Ref, process, Bridge, killed} -> ok
        after 1000 -> erlang:error(killed_voice_bridge_timeout)
        end,
        wait_for_subscriber_count(Session, 0, 50),
        {ok, Replacement} = erlang_adk:start_live_voice_bridge(
                              Session, ?PRINCIPAL, self(), #{}),
        ok = erlang_adk:stop_live_voice_bridge(Replacement)
    after
        erlang:demonitor(Ref, [flush]),
        cleanup(Fixture)
    end.

registry_lease_cannot_be_claimed_or_released_for_another_bridge_test() ->
    Fixture = start_fixture(#{}, #{}),
    try
        #{bridge := Bridge, session := Session} = Fixture,
        ?assertEqual(
           {error, not_live_voice_lease_owner},
           adk_live_voice_registry:claim(Session, Bridge)),
        ?assertEqual(
           {error, not_live_voice_lease_owner},
           adk_live_voice_registry:release(Session, Bridge)),
        ?assertEqual(
           {error, not_live_voice_lease_owner},
           gen_server:call(
             adk_live_voice_registry, {release, Session, Bridge})),
        ?assert(is_process_alive(Bridge)),
        ?assertEqual(
           {error, live_voice_bridge_already_attached},
           erlang_adk:start_live_voice_bridge(
             Session, ?PRINCIPAL, self(), #{}))
    after
        cleanup(Fixture)
    end.

remote_pids_are_rejected_without_crashing_voice_services_test() ->
    Fixture = start_fixture(#{}, #{}),
    Registry = whereis(adk_live_voice_registry),
    Remote = external_pid(),
    try
        #{session := Session} = Fixture,
        ?assert(node(Remote) =/= node()),
        ?assertEqual(
           {error, invalid_live_voice_bridge},
           erlang_adk:start_live_voice_bridge(
             Remote, ?PRINCIPAL, self(), #{})),
        ?assertEqual(
           {error, invalid_live_voice_bridge},
           erlang_adk:start_live_voice_bridge(
             Session, ?PRINCIPAL, Remote, #{})),
        ?assertEqual(
           {error, invalid_live_voice_lease},
           adk_live_voice_registry:claim(Remote, self())),
        ?assertEqual(
           {error, invalid_live_voice_lease},
           gen_server:call(
             adk_live_voice_registry, {claim, Remote, self()})),
        ?assertEqual(
           {error, invalid_live_voice_lease},
           gen_server:call(
             adk_live_voice_registry, {release, Remote, self()})),
        ?assertEqual(
           {error, invalid_live_voice_bridge},
           erlang_adk:live_voice_frame(Remote, <<1, 2>>)),
        ?assertEqual(
           {error, invalid_live_voice_bridge},
           erlang_adk:stop_live_voice_bridge(Remote)),
        ?assertEqual(Registry, whereis(adk_live_voice_registry)),
        ?assert(is_process_alive(Registry))
    after
        cleanup(Fixture)
    end.

activity_detection_mode_is_exposed_in_live_status_test() ->
    {SessionIdA, Automatic, HandleA} = start_session(#{}),
    {SessionIdB, Manual, HandleB} =
        start_session(#{automatic_activity_detection => false}),
    try
        {ok, AutomaticStatus} =
            erlang_adk:live_status(Automatic, ?PRINCIPAL),
        {ok, ManualStatus} = erlang_adk:live_status(Manual, ?PRINCIPAL),
        ?assertEqual(
           true, maps:get(automatic_activity_detection, AutomaticStatus)),
        ?assertEqual(
           false, maps:get(automatic_activity_detection, ManualStatus))
    after
        _ = erlang_adk:close_live_session(
              Automatic, ?PRINCIPAL, status_test_complete),
        _ = erlang_adk:close_live_session(
              Manual, ?PRINCIPAL, status_test_complete),
        flush_transport(HandleA, SessionIdA),
        flush_transport(HandleB, SessionIdB)
    end.

reconnect_is_explicit_and_terminates_capture_bridge_test() ->
    Fixture = start_fixture(
                #{session_resumption => true},
                #{credit => #{messages => 1, bytes => 4096}}),
    #{bridge := Bridge, handle := Handle, session := Session} = Fixture,
    Ref = erlang:monitor(process, Bridge),
    try
        adk_live_fake_transport:inject(
          Handle,
          #{<<"sessionResumptionUpdate">> =>
                #{<<"newHandle">> => <<"voice-resume-handle">>,
                  <<"resumable">> => true}}),
        %% The initial resumable handle is continuity metadata.  It must not
        %% be projected to the browser as if a reconnect had completed.
        assert_no_voice_frame(Bridge),

        Pcm = <<0, 0, 1, 0>>,
        inject_audio(Handle, Pcm),
        {AudioSequence,
         <<1, 129, AudioSequence:64/unsigned-big,
           24000:32/unsigned-big, 1, Pcm/binary>>} =
            receive_voice_frame(Bridge),

        ok = adk_live_fake_transport:disconnect(Handle, network_lost),
        wait_for_live_state(Session, reconnecting, 50),
        receive
            {'DOWN', Ref, process, Bridge,
             {shutdown, live_voice_reconnect_required}} -> ok
        after 1000 -> erlang:error(voice_reconnect_shutdown_timeout)
        end,
        ?assertEqual(
           {error, not_found},
           erlang_adk:live_voice_frame(Bridge, audio_frame(1, <<0, 0>>))),
        ?assertEqual(
           {error, live_voice_reconnect_required},
           erlang_adk:start_live_voice_bridge(
             Session, ?PRINCIPAL, self(), #{}))
    after
        erlang:demonitor(Ref, [flush]),
        cleanup(Fixture)
    end.

fast_resume_with_exhausted_credit_rejects_stale_bridge_test() ->
    Fixture = start_fixture(
                #{session_resumption => true},
                #{credit => #{messages => 1, bytes => 4096}}),
    #{bridge := Bridge, handle := Handle, session := Session} = Fixture,
    Ref = erlang:monitor(process, Bridge),
    try
        adk_live_fake_transport:inject(
          Handle,
          #{<<"sessionResumptionUpdate">> =>
                #{<<"newHandle">> => <<"fast-voice-resume-handle">>,
                  <<"resumable">> => true}}),
        %% A handle update is continuity metadata, not a completed resume.
        %% The bridge consumes and ACKs it internally, preserving the single
        %% public-event credit for the audio below.
        assert_no_voice_frame(Bridge),

        Pcm = <<0, 0, 1, 0>>,
        inject_audio(Handle, Pcm),
        {AudioSequence,
         <<1, 129, AudioSequence:64/unsigned-big,
           24000:32/unsigned-big, 1, Pcm/binary>>} =
            receive_voice_frame(Bridge),

        ok = adk_live_fake_transport:disconnect(Handle, network_lost),
        wait_for_live_state(Session, reconnecting, 50),
        receive
            {'DOWN', Ref, process, Bridge,
             {shutdown, live_voice_reconnect_required}} -> ok
        after 1000 -> erlang:error(idle_voice_invalidation_timeout)
        end,
        wait_for_subscriber_count(Session, 0, 100),
        ?assertEqual(
           {error, not_found},
           erlang_adk:live_voice_frame(
             Bridge, audio_frame(1, <<0, 0>>))),

        NewHandle = receive_reconnected_handle(Handle),
        #{<<"setup">> := _} = decode_sent(NewHandle),
        activate_session(Session, NewHandle),
        assert_no_sent_frame(NewHandle),

        {ok, Replacement} = erlang_adk:start_live_voice_bridge(
                              Session, ?PRINCIPAL, self(), #{}),
        ok = erlang_adk:stop_live_voice_bridge(Replacement)
    after
        erlang:demonitor(Ref, [flush]),
        cleanup(Fixture)
    end.

stale_voice_continuity_token_is_rejected_after_resume_test() ->
    {SessionId, Session, Handle} =
        start_session(#{session_resumption => true}),
    try
        {ok, #{continuity_token := ContinuityToken}} =
            adk_live_session:subscribe_voice(
              Session, ?PRINCIPAL, self(),
              #{messages => 8, bytes => 4096}),
        adk_live_fake_transport:inject(
          Handle,
          #{<<"sessionResumptionUpdate">> =>
                #{<<"newHandle">> => <<"token-resume-handle">>,
                  <<"resumable">> => true}}),
        receive
            {adk_live_event, SessionId, Sequence, Event} ->
                ?assertEqual(resumption_status,
                             adk_live_event:kind(Event)),
                ok = adk_live_session:ack(
                       Session, ?PRINCIPAL, self(), Sequence)
        after 1000 -> erlang:error(voice_resumption_status_timeout)
        end,

        ok = adk_live_fake_transport:disconnect(Handle, network_lost),
        receive
            {adk_live_voice_continuity_invalidated,
             Session, SessionId, ContinuityToken} -> ok
        after 1000 -> erlang:error(voice_continuity_invalidation_timeout)
        end,
        NewHandle = receive_reconnected_handle(Handle),
        #{<<"setup">> := _} = decode_sent(NewHandle),
        activate_session(Session, NewHandle),

        {ok, Media} = adk_live_media:audio_pcm(<<0, 0>>, 16000, 1),
        ?assertEqual(
           {error, live_voice_reconnect_required},
           adk_live_session:send_voice_audio(
             Session, ?PRINCIPAL, ContinuityToken, Media)),
        assert_no_sent_frame(NewHandle)
    after
        _ = adk_live_session:unsubscribe(Session, ?PRINCIPAL, self()),
        _ = erlang_adk:close_live_session(
              Session, ?PRINCIPAL, stale_continuity_test_complete),
        flush_transport(Handle, SessionId)
    end.

initialization_timeout_does_not_orphan_bridge_test_() ->
    {timeout, 15, fun initialization_timeout_does_not_orphan_bridge/0}.

initialization_timeout_does_not_orphan_bridge() ->
    {SessionId, Session, Handle} = start_session(#{}),
    Registry = whereis(adk_live_voice_registry),
    Parent = self(),
    try
        ok = sys:suspend(Registry),
        Starter = spawn(
                    fun() ->
                        Parent !
                            {timed_out_voice_start,
                             erlang_adk:start_live_voice_bridge(
                               Session, ?PRINCIPAL, Parent, #{})}
                    end),
        put(initialization_timeout_starter, Starter),
        Bridge = wait_for_pending_registry_claim(Registry, Session, 100),
        put(initialization_timeout_bridge, Bridge),

        ok = sys:suspend(Session),
        ok = sys:resume(Registry),
        wait_for_pending_voice_subscription(Session, Bridge, 100),
        true = erlang:suspend_process(Bridge),
        ok = sys:resume(Session),
        wait_for_subscriber_count(Session, 1, 100),
        ?assertEqual(
           {error, live_voice_bridge_already_attached},
           erlang_adk:start_live_voice_bridge(
             Session, ?PRINCIPAL, self(), #{})),

        receive
            {timed_out_voice_start, StartResult} ->
                ?assertEqual({error, timeout}, StartResult)
        after 6000 -> erlang:error(timed_out_voice_start_timeout)
        end,
        wait_for_subscriber_count(Session, 0, 100),
        {ok, Replacement} = erlang_adk:start_live_voice_bridge(
                              Session, ?PRINCIPAL, self(), #{}),
        ok = erlang_adk:stop_live_voice_bridge(Replacement)
    after
        resume_if_suspended(Session),
        resume_if_suspended(Registry),
        cleanup_initialization_timeout_processes(),
        _ = erlang_adk:close_live_session(
              Session, ?PRINCIPAL, initialization_timeout_test_complete),
        flush_transport(Handle, SessionId)
    end.

nested_session_timeout_is_bridge_terminal_test_() ->
    {timeout, 12, fun nested_session_timeout_is_bridge_terminal/0}.

nested_session_timeout_is_bridge_terminal() ->
    Fixture = start_fixture(#{}, #{}),
    #{bridge := Bridge, session := Session} = Fixture,
    Ref = erlang:monitor(process, Bridge),
    try
        ok = sys:suspend(Session),
        ?assertEqual(
           {error, live_voice_outcome_unknown},
           erlang_adk:live_voice_frame(
             Bridge, audio_frame(1, <<0, 0>>))),
        ok = sys:resume(Session),
        receive
            {'DOWN', Ref, process, Bridge, DownReason} ->
                ?assertEqual(
                   {shutdown, live_voice_outcome_unknown}, DownReason)
        after 2000 -> erlang:error(voice_outcome_unknown_shutdown_timeout)
        end,
        wait_for_subscriber_count(Session, 0, 100),
        ?assertEqual(
           {error, not_found},
           erlang_adk:live_voice_frame(
             Bridge, audio_frame(1, <<0, 0>>)))
    after
        resume_if_suspended(Session),
        erlang:demonitor(Ref, [flush]),
        cleanup(Fixture)
    end.

outer_frame_timeout_is_bridge_terminal_test_() ->
    {timeout, 10, fun outer_frame_timeout_is_bridge_terminal/0}.

outer_frame_timeout_is_bridge_terminal() ->
    Fixture = start_fixture(#{}, #{}),
    #{bridge := Bridge, session := Session} = Fixture,
    Ref = erlang:monitor(process, Bridge),
    try
        ok = sys:suspend(Bridge),
        ?assertEqual(
           {error, live_voice_outcome_unknown},
           erlang_adk:live_voice_frame(
             Bridge, audio_frame(1, <<0, 0>>))),
        receive
            {'DOWN', Ref, process, Bridge, killed} -> ok
        after 1000 -> erlang:error(outer_voice_timeout_shutdown_timeout)
        end,
        wait_for_subscriber_count(Session, 0, 100),
        ?assertEqual(
           {error, not_found},
           erlang_adk:live_voice_frame(
             Bridge, audio_frame(1, <<0, 0>>)))
    after
        resume_if_suspended(Bridge),
        erlang:demonitor(Ref, [flush]),
        cleanup(Fixture)
    end.

voice_registry_is_supervised_before_live_sessions_test() ->
    {ok, {#{strategy := rest_for_one}, Children}} = erlang_adk_sup:init([]),
    Ids = [maps:get(id, Child) || Child <- Children],
    RegistryIndex = index_of(adk_live_voice_registry, Ids, 1),
    SessionSupIndex = index_of(adk_live_session_sup, Ids, 1),
    ?assert(RegistryIndex < SessionSupIndex).

startup_validation_fails_closed_test() ->
    Fixture = start_fixture(#{}, #{}),
    try
        #{session := Session} = Fixture,
        ?assertEqual(
           {error, invalid_live_voice_bridge},
           erlang_adk:start_live_voice_bridge(
             Session, ?PRINCIPAL, self(), #{unknown => true})),
        ?assertEqual(
           {error, invalid_live_voice_bridge_options},
           erlang_adk:start_live_voice_bridge(
             Session, ?PRINCIPAL, self(),
             #{credit => #{messages => 0, bytes => 4096}})),
        ?assertEqual(
           {error, invalid_live_voice_bridge},
           erlang_adk:start_live_voice_bridge(
             Session, ?PRINCIPAL, self(),
             #{input_sample_rate => 16000})),
        ?assertEqual(
           {error, invalid_live_voice_bridge},
           erlang_adk:start_live_voice_bridge(
             Session, ?PRINCIPAL, self(),
             #{input_sample_rate => 24000})),
        ?assertEqual(
           {error, not_found},
           erlang_adk:start_live_voice_bridge(
             Session, <<"wrong-principal">>, self(), #{})),
        ?assertEqual(
           {error, invalid_live_voice_bridge},
           erlang_adk:start_live_voice_bridge(
             not_a_pid, ?PRINCIPAL, self(), #{}))
    after
        cleanup(Fixture)
    end.

startup_requires_active_live_session_test() ->
    {SessionId, Session, Handle} = start_connecting_session(#{}),
    try
        ?assertEqual(
           {error, {not_ready, setup_pending}},
           erlang_adk:start_live_voice_bridge(
             Session, ?PRINCIPAL, self(), #{})),
        activate_session(Session, Handle),
        {ok, Bridge} = erlang_adk:start_live_voice_bridge(
                         Session, ?PRINCIPAL, self(), #{}),
        ok = erlang_adk:stop_live_voice_bridge(Bridge)
    after
        _ = erlang_adk:close_live_session(
              Session, ?PRINCIPAL, active_start_test_complete),
        flush_transport(Handle, SessionId)
    end.

start_fixture(ProviderConfig, BridgeOpts) ->
    {SessionId, Session, Handle} = start_session(ProviderConfig),
    {ok, Bridge} = erlang_adk:start_live_voice_bridge(
                     Session, ?PRINCIPAL, self(), BridgeOpts),
    assert_input_config(Bridge, 16000),
    #{session_id => SessionId,
      session => Session,
      handle => Handle,
      bridge => Bridge}.

start_openai_fixture() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    SessionId = <<"voice-openai-",
                  (integer_to_binary(
                     erlang:unique_integer([positive, monotonic])))/binary>>,
    Config = #{provider => adk_live_openai,
               provider_config =>
                   #{model => <<"gpt-realtime-test">>,
                     response_modalities => [audio]},
               transport => adk_live_fake_transport,
               transport_opts => #{test_pid => self()}},
    {ok, Session} = erlang_adk:start_live_session(
                      SessionId, ?PRINCIPAL, Config),
    Handle = receive
        {adk_live_fake_transport, opened, Opened} -> Opened
    after 1000 -> erlang:error(live_transport_open_timeout)
    end,
    receive
        {adk_live_fake_transport, sent, Handle, SetupFrame} ->
            #{<<"type">> := <<"session.update">>} =
                jsx:decode(SetupFrame, [return_maps])
    after 1000 -> erlang:error(live_setup_timeout)
    end,
    adk_live_fake_transport:inject(
      Handle, #{<<"type">> => <<"session.updated">>}),
    wait_for_live_state(Session, active, 50),
    {ok, Bridge} = erlang_adk:start_live_voice_bridge(
                     Session, ?PRINCIPAL, self(), #{}),
    assert_input_config(Bridge, 24000),
    #{session_id => SessionId, session => Session,
      handle => Handle, bridge => Bridge}.

start_session(ProviderConfig) ->
    {SessionId, Session, Handle} =
        start_connecting_session(ProviderConfig),
    activate_session(Session, Handle),
    {SessionId, Session, Handle}.

start_connecting_session(ProviderConfig) ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    SessionId = <<"voice-bridge-",
                  (integer_to_binary(
                     erlang:unique_integer([positive, monotonic])))/binary>>,
    Config = #{provider => adk_live_gemini,
               provider_config => ProviderConfig,
               transport => adk_live_fake_transport,
               transport_opts => #{test_pid => self()}},
    {ok, Session} = erlang_adk:start_live_session(
                      SessionId, ?PRINCIPAL, Config),
    Handle = receive
        {adk_live_fake_transport, opened, Opened} -> Opened
    after 1000 -> erlang:error(live_transport_open_timeout)
    end,
    receive
        {adk_live_fake_transport, sent, Handle, SetupFrame} ->
            #{<<"setup">> := _} = jsx:decode(SetupFrame, [return_maps])
    after 1000 -> erlang:error(live_setup_timeout)
    end,
    {SessionId, Session, Handle}.

activate_session(Session, Handle) ->
    adk_live_fake_transport:inject(
      Handle, #{<<"setupComplete">> => #{}}),
    wait_for_live_state(Session, active, 50).

inject_output_transcription(Handle, Text, Final) ->
    adk_live_fake_transport:inject(
      Handle,
      #{<<"serverContent">> =>
            #{<<"outputTranscription">> =>
                  #{<<"text">> => Text, <<"finished">> => Final}}}).

inject_audio(Handle, Pcm) ->
    adk_live_fake_transport:inject(
      Handle,
      #{<<"serverContent">> =>
            #{<<"modelTurn">> =>
                  #{<<"parts">> =>
                        [#{<<"inlineData">> =>
                               #{<<"mimeType">> =>
                                 <<"audio/pcm;rate=24000">>,
                                 <<"data">> => base64:encode(Pcm)}}]}}}).

gemini_audio_part(Pcm) ->
    #{<<"inlineData">> =>
          #{<<"mimeType">> => <<"audio/pcm;rate=24000">>,
            <<"data">> => base64:encode(Pcm)}}.

audio_frame(Sequence, Pcm) ->
    audio_frame(Sequence, 16000, Pcm).

audio_frame(Sequence, Rate, Pcm) ->
    <<1, 1, Sequence:64/unsigned-big, Rate:32/unsigned-big,
      1, Pcm/binary>>.

assert_input_config(Bridge, Rate) ->
    receive
        {adk_live_voice_frame, Bridge,
         <<1, 128, Rate:32/unsigned-big, 1, 1>>} -> ok
    after 1000 -> erlang:error(live_voice_input_config_timeout)
    end.

ack(Bridge, Sequence) ->
    erlang_adk:live_voice_frame(
      Bridge, <<1, 3, Sequence:64/unsigned-big>>).

receive_voice_frame(Bridge) ->
    receive
        {adk_live_voice_frame, Bridge, Binary} ->
            case Binary of
                <<1, _Type, Sequence:64/unsigned-big, _/binary>> ->
                    {Sequence, Binary}
            end
    after 1000 -> erlang:error(live_voice_frame_timeout)
    end.

assert_no_voice_frame(Bridge) ->
    receive
        {adk_live_voice_frame, Bridge, Unexpected} ->
            erlang:error({unexpected_live_voice_frame, Unexpected})
    after 100 -> ok
    end.

decode_sent(Handle) ->
    receive
        {adk_live_fake_transport, sent, Handle, Frame} ->
            jsx:decode(Frame, [return_maps])
    after 1000 -> erlang:error(live_voice_input_timeout)
    end.

assert_no_sent_frame(Handle) ->
    receive
        {adk_live_fake_transport, sent, Handle, Unexpected} ->
            erlang:error({unexpected_live_voice_input, Unexpected})
    after 100 -> ok
    end.

receive_reconnected_handle(OldHandle) ->
    receive
        {adk_live_fake_transport, opened, NewHandle}
          when NewHandle =/= OldHandle ->
            NewHandle
    after 2000 -> erlang:error(live_voice_reconnect_open_timeout)
    end.

cleanup(#{bridge := Bridge, session := Session,
          session_id := SessionId, handle := Handle}) ->
    _ = erlang_adk:stop_live_voice_bridge(Bridge),
    _ = erlang_adk:close_live_session(
          Session, ?PRINCIPAL, live_voice_bridge_test_complete),
    flush_transport(Handle, SessionId).

flush_transport(Handle, _SessionId) ->
    receive
        {adk_live_fake_transport, closed, Handle, _Reason} -> ok
    after 0 -> ok
    end.

owner_wait() ->
    receive stop -> ok end.

external_pid() ->
    binary_to_term(
      <<131, 103, 100, 0, 20, "voice-test@elsewhere", 0:32, 0:32, 0:8>>).

resume_if_suspended(Process) ->
    _ = catch sys:resume(Process),
    ok.

cleanup_initialization_timeout_processes() ->
    case erase(initialization_timeout_bridge) of
        Bridge when is_pid(Bridge) ->
            case is_process_alive(Bridge) of
                true ->
                    _ = catch erlang:resume_process(Bridge),
                    exit(Bridge, kill);
                false -> ok
            end;
        _ -> ok
    end,
    case erase(initialization_timeout_starter) of
        Starter when is_pid(Starter) ->
            case is_process_alive(Starter) of
                true -> exit(Starter, kill);
                false -> ok
            end;
        _ -> ok
    end.

wait_for_pending_registry_claim(_Registry, _Session, 0) ->
    erlang:error(pending_voice_registry_claim_timeout);
wait_for_pending_registry_claim(Registry, Session, Attempts) ->
    {messages, Messages} = process_info(Registry, messages),
    case [Bridge ||
             {'$gen_call', {Bridge, _Tag},
              {claim, PendingSession, Bridge}} <- Messages,
             PendingSession =:= Session] of
        [Bridge | _] -> Bridge;
        [] ->
            receive after 10 -> ok end,
            wait_for_pending_registry_claim(
              Registry, Session, Attempts - 1)
    end.

wait_for_pending_voice_subscription(_Session, _Bridge, 0) ->
    erlang:error(pending_voice_subscription_timeout);
wait_for_pending_voice_subscription(Session, Bridge, Attempts) ->
    {messages, Messages} = process_info(Session, messages),
    Pending = lists:any(
                fun({'$gen_call', {Caller, _Tag},
                     {api, ?PRINCIPAL,
                      {subscribe_voice, Subscriber, _Credit}}}) ->
                        Caller =:= Bridge andalso Subscriber =:= Bridge;
                   (_Other) -> false
                end, Messages),
    case Pending of
        true -> ok;
        false ->
            receive after 10 -> ok end,
            wait_for_pending_voice_subscription(
              Session, Bridge, Attempts - 1)
    end.

wait_for_subscriber_count(_Session, _Expected, 0) ->
    erlang:error(subscriber_count_timeout);
wait_for_subscriber_count(Session, Expected, Attempts) ->
    case erlang_adk:live_status(Session, ?PRINCIPAL) of
        {ok, #{subscriber_count := Expected}} -> ok;
        _ ->
            receive after 10 -> ok end,
            wait_for_subscriber_count(Session, Expected, Attempts - 1)
    end.

wait_for_live_state(_Session, _Expected, 0) ->
    erlang:error(live_state_timeout);
wait_for_live_state(Session, Expected, Attempts) ->
    case erlang_adk:live_status(Session, ?PRINCIPAL) of
        {ok, #{state := Expected}} -> ok;
        _Other ->
            receive after 10 -> ok end,
            wait_for_live_state(Session, Expected, Attempts - 1)
    end.

collect_voice_start_results(0, Acc) ->
    Acc;
collect_voice_start_results(Remaining, Acc) ->
    receive
        {voice_start_result, Starter, Result} ->
            collect_voice_start_results(
              Remaining - 1, [{Starter, Result} | Acc])
    after 2000 -> erlang:error(voice_start_results_timeout)
    end.

collect_parallel_voice_starts(0, Acc) ->
    Acc;
collect_parallel_voice_starts(Remaining, Acc) ->
    receive
        {parallel_voice_start, Label, Result} ->
            collect_parallel_voice_starts(
              Remaining - 1, Acc#{Label => Result})
    after 2000 -> erlang:error(parallel_voice_start_timeout)
    end.

stop_parallel_result(Label, Results) ->
    case maps:get(Label, Results, undefined) of
        {ok, Bridge} -> _ = erlang_adk:stop_live_voice_bridge(Bridge), ok;
        _Other -> ok
    end.

index_of(Expected, [Expected | _Rest], Index) -> Index;
index_of(Expected, [_Other | Rest], Index) ->
    index_of(Expected, Rest, Index + 1);
index_of(Expected, [], _Index) ->
    erlang:error({missing_supervisor_child, Expected}).
