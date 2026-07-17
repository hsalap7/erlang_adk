%% Paid, opt-in integration tests for the actual Gemini Live WebSocket API.
%%
%% This suite is intentionally separate from readme_live_gemini_SUITE, which
%% exercises the REST GenerateContent API.  Credentials remain in the owning
%% transport process and are never copied into Common Test configuration or
%% diagnostics.
-module(gemini_live_SUITE).

-export([all/0, suite/0, init_per_suite/1, end_per_suite/1]).
-export([text_audio_transcription/1, audio_input/1, image_input/1,
         synchronous_tool_round_trip/1, browser_voice_bridge/1]).

-define(MODEL, <<"gemini-3.1-flash-live-preview">>).
-define(PRINCIPAL, <<"gemini-live-common-test">>).
-define(TURN_TIMEOUT_MS, 120000).
-define(CREDIT, #{messages => 256, bytes => 8388608}).

suite() ->
    [{timetrap, {minutes, 10}}].

all() ->
    [text_audio_transcription,
     audio_input,
     image_input,
     synchronous_tool_round_trip,
     browser_voice_bridge].

init_per_suite(Config) ->
    case {os:getenv("ERLANG_ADK_GEMINI_LIVE"),
          os:getenv("GEMINI_API_KEY")} of
        {"1", Key} when is_list(Key), Key =/= [] ->
            {ok, _} = application:ensure_all_started(erlang_adk),
            Config;
        {"1", _} ->
            {skip, "GEMINI_API_KEY is not available to the test process"};
        _ ->
            {skip,
             "set ERLANG_ADK_GEMINI_LIVE=1 to run paid Gemini Live tests"}
    end.

end_per_suite(_Config) ->
    _ = application:stop(erlang_adk),
    ok.

text_audio_transcription(_Config) ->
    with_session(
      #{output_audio_transcription => true},
      fun(Session, SessionId) ->
          {ok, _} = erlang_adk:live_send_text(
                      Session, ?PRINCIPAL,
                      <<"Reply with one short sentence about Erlang OTP.">>),
          Summary = collect_turn(Session, SessionId),
          assert_audio_and_transcription(Summary)
      end).

audio_input(_Config) ->
    with_session(
      #{output_audio_transcription => true},
      fun(Session, SessionId) ->
          %% 250 ms, 16 kHz, mono, signed little-endian square wave.  The test
          %% checks the real audio ingress path without retaining a fixture.
          Pcm = binary:copy(<<16#40, 16#1f, 16#c0, 16#e0>>, 2000),
          {ok, Media} = adk_live_media:audio_pcm(Pcm, 16000, 1),
          {ok, _} = erlang_adk:live_send_audio(
                      Session, ?PRINCIPAL, Media),
          {ok, _} = erlang_adk:live_send_text(
                      Session, ?PRINCIPAL,
                      <<"A short test tone was sent. Reply briefly.">>),
          {ok, _} = erlang_adk:live_audio_stream_end(
                      Session, ?PRINCIPAL),
          Summary = collect_turn(Session, SessionId),
          assert_audio_and_transcription(Summary)
      end).

image_input(_Config) ->
    with_session(
      #{output_audio_transcription => true},
      fun(Session, SessionId) ->
          TinyPng = base64:decode(
              <<"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0l"
                "EQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=">>),
          {ok, Frame} = adk_live_media:video_frame(png, TinyPng),
          {ok, _} = erlang_adk:live_send_video_frame(
                      Session, ?PRINCIPAL, Frame),
          {ok, _} = erlang_adk:live_send_text(
                      Session, ?PRINCIPAL,
                      <<"Describe the image in one short sentence.">>),
          Summary = collect_turn(Session, SessionId),
          assert_audio_and_transcription(Summary)
      end).

synchronous_tool_round_trip(_Config) ->
    Weather = #{type => function,
                name => <<"get_weather">>,
                description => <<"Return weather for one city">>,
                parameters =>
                    #{<<"type">> => <<"object">>,
                      <<"properties">> =>
                          #{<<"city">> =>
                                #{<<"type">> => <<"string">>}},
                      <<"required">> => [<<"city">>]}},
    with_session(
      #{output_audio_transcription => true, tools => [Weather]},
      fun(Session, SessionId) ->
          {ok, _} = erlang_adk:live_send_text(
                      Session, ?PRINCIPAL,
                      <<"You must call get_weather for Kolkata before "
                        "answering. Then report the returned temperature.">>),
          {CallId, CallName} = await_tool_call(
                                 Session, SessionId,
                                 deadline(?TURN_TIMEOUT_MS)),
          <<"get_weather">> = CallName,
          {ok, _} = erlang_adk:live_send_tool_response(
                      Session, ?PRINCIPAL, CallId, CallName,
                      #{<<"temperature_c">> => 30,
                        <<"condition">> => <<"clear">>}),
          Summary = collect_turn(Session, SessionId),
          assert_audio_and_transcription(Summary)
      end).

browser_voice_bridge(_Config) ->
    with_voice_bridge(
      fun(Session, Bridge) ->
          %% Exercise browser framing against the real provider. The short tone
          %% proves binary PCM ingress; text makes the response deterministic
          %% without checking in a large spoken-audio fixture.
          Pcm = binary:copy(<<16#40, 16#1f, 16#c0, 16#e0>>, 2000),
          {ok, _} = erlang_adk:live_voice_frame(
                      Bridge,
                      <<1, 1, 1:64/unsigned-big,
                        16000:32/unsigned-big, 1, Pcm/binary>>),
          {ok, _} = erlang_adk:live_send_text(
                      Session, ?PRINCIPAL,
                      <<"A browser voice bridge sent a short test tone. "
                        "Reply with one brief sentence.">>),
          {ok, _} = erlang_adk:live_voice_frame(Bridge, <<1, 2>>),
          Summary = collect_voice_turn(
                      Bridge, deadline(?TURN_TIMEOUT_MS),
                      #{audio_bytes => 0, transcription => <<>>}),
          assert_audio_and_transcription(Summary)
      end).

with_voice_bridge(Fun) ->
    SessionId = <<"ct-live-voice-bridge-",
                  (integer_to_binary(
                     erlang:unique_integer([positive, monotonic])))/binary>>,
    ApiKey = unicode:characters_to_binary(os:getenv("GEMINI_API_KEY")),
    SessionConfig =
      #{provider => adk_live_gemini,
        provider_config =>
          #{model => ?MODEL,
            response_modalities => [audio],
            output_audio_transcription => true,
            automatic_activity_detection => true,
            session_resumption => true},
        transport => adk_live_gun_transport,
        transport_opts =>
          #{api_key => ApiKey,
            connect_timeout_ms => 30000,
            tls_handshake_timeout_ms => 30000,
            upgrade_timeout_ms => 30000},
        connect_timeout_ms => 35000,
        setup_timeout_ms => 30000,
        max_reconnect_attempts => 1},
    {ok, Session} = erlang_adk:start_live_session(
                      SessionId, ?PRINCIPAL, SessionConfig),
    try
        %% A new bridge is future-only and deliberately requires the Live
        %% session to be active. Use a short-lived setup subscription to
        %% observe and acknowledge ready before acquiring the exclusive
        %% bidirectional voice lease.
        {ok, _} = erlang_adk:live_subscribe(
                    Session, ?PRINCIPAL, ?CREDIT),
        _Ready = await_kind(Session, SessionId, ready,
                            deadline(?TURN_TIMEOUT_MS)),
        ok = erlang_adk:live_unsubscribe(Session, ?PRINCIPAL),
        {ok, Bridge} = erlang_adk:start_live_voice_bridge(
                         Session, ?PRINCIPAL, self(),
                         #{credit => ?CREDIT,
                           max_audio_frame_bytes => 64000}),
        receive
            {adk_live_voice_frame, Bridge,
             <<1, 128, 16000:32/unsigned-big, 1, 1>>} -> ok
        after 1000 -> ct:fail(gemini_live_voice_input_config_timeout)
        end,
        try Fun(Session, Bridge)
        after
            _ = erlang_adk:stop_live_voice_bridge(Bridge)
        end
    after
        _ = erlang_adk:close_live_session(
              Session, ?PRINCIPAL, common_test_complete)
    end.

collect_voice_turn(Bridge, Deadline, Summary0) ->
    {Sequence, Frame} = receive_voice_frame(Bridge, Deadline),
    ok = voice_ack(Bridge, Sequence),
    case Frame of
        <<1, 129, Sequence:64/unsigned-big,
          _Rate:32/unsigned-big, _Channels:8, Pcm/binary>> ->
            Summary = Summary0#{
                        audio_bytes := maps:get(audio_bytes, Summary0)
                                       + byte_size(Pcm)},
            collect_voice_turn(Bridge, Deadline, Summary);
        <<1, 130, Sequence:64/unsigned-big, 2, _Final:8, Text/binary>> ->
            Existing = maps:get(transcription, Summary0),
            Summary = Summary0#{transcription :=
                                  <<Existing/binary, Text/binary>>},
            collect_voice_turn(Bridge, Deadline, Summary);
        <<1, 130, Sequence:64/unsigned-big, 1, _Final:8, _Text/binary>> ->
            collect_voice_turn(Bridge, Deadline, Summary0);
        <<1, 131, Sequence:64/unsigned-big, 3>> ->
            Summary0;
        <<1, 131, Sequence:64/unsigned-big, Code>>
          when Code =:= 8; Code =:= 9 ->
            ct:fail({gemini_live_voice_terminal, Code});
        <<1, 131, Sequence:64/unsigned-big, _Code>> ->
            collect_voice_turn(Bridge, Deadline, Summary0)
    end.

receive_voice_frame(Bridge, Deadline) ->
    Timeout = remaining(Deadline),
    receive
        {adk_live_voice_frame, Bridge,
         <<1, _Type, Sequence:64/unsigned-big, _/binary>> = Frame} ->
            {Sequence, Frame}
    after Timeout ->
        ct:fail(gemini_live_voice_frame_timeout)
    end.

voice_ack(Bridge, Sequence) ->
    erlang_adk:live_voice_frame(
      Bridge, <<1, 3, Sequence:64/unsigned-big>>).

with_session(ProviderOverrides, Fun) ->
    SessionId = <<"ct-live-",
                  (integer_to_binary(
                     erlang:unique_integer([positive, monotonic])))/binary>>,
    ApiKey = unicode:characters_to_binary(os:getenv("GEMINI_API_KEY")),
    ProviderConfig = maps:merge(
                       #{model => ?MODEL,
                         response_modalities => [audio],
                         session_resumption => true},
                       ProviderOverrides),
    SessionConfig = #{provider => adk_live_gemini,
                      provider_config => ProviderConfig,
                      transport => adk_live_gun_transport,
                      transport_opts => #{api_key => ApiKey,
                                          connect_timeout_ms => 30000,
                                          tls_handshake_timeout_ms => 30000,
                                          upgrade_timeout_ms => 30000},
                      connect_timeout_ms => 35000,
                      setup_timeout_ms => 30000,
                      max_reconnect_attempts => 1},
    {ok, Session} = erlang_adk:start_live_session(
                      SessionId, ?PRINCIPAL, SessionConfig),
    try
        {ok, _} = erlang_adk:live_subscribe(
                    Session, ?PRINCIPAL, ?CREDIT),
        _Ready = await_kind(Session, SessionId, ready,
                            deadline(?TURN_TIMEOUT_MS)),
        Fun(Session, SessionId)
    after
        _ = erlang_adk:close_live_session(
              Session, ?PRINCIPAL, common_test_complete)
    end.

collect_turn(Session, SessionId) ->
    collect_turn(Session, SessionId, deadline(?TURN_TIMEOUT_MS),
                 #{audio_bytes => 0, transcription => <<>>}).

collect_turn(Session, SessionId, Deadline, Summary0) ->
    {Sequence, Event} = receive_event(SessionId, Deadline),
    ok = erlang_adk:live_ack(Session, ?PRINCIPAL, Sequence),
    Kind = adk_live_event:kind(Event),
    Summary = summarize_event(Kind, Event, Summary0),
    case Kind of
        turn_complete -> Summary;
        error -> ct:fail({gemini_live_error, maps:get(payload, Event)});
        terminal -> ct:fail({gemini_live_terminal, maps:get(payload, Event)});
        _ -> collect_turn(Session, SessionId, Deadline, Summary)
    end.

await_tool_call(Session, SessionId, Deadline) ->
    {Sequence, Event} = receive_event(SessionId, Deadline),
    ok = erlang_adk:live_ack(Session, ?PRINCIPAL, Sequence),
    case adk_live_event:kind(Event) of
        tool_call ->
            Payload = maps:get(payload, Event),
            {maps:get(id, Payload), maps:get(name, Payload)};
        error ->
            ct:fail({gemini_live_error, maps:get(payload, Event)});
        terminal ->
            ct:fail({gemini_live_terminal, maps:get(payload, Event)});
        _ ->
            await_tool_call(Session, SessionId, Deadline)
    end.

await_kind(Session, SessionId, Expected, Deadline) ->
    {Sequence, Event} = receive_event(SessionId, Deadline),
    ok = erlang_adk:live_ack(Session, ?PRINCIPAL, Sequence),
    case adk_live_event:kind(Event) of
        Expected -> Event;
        error -> ct:fail({gemini_live_error, maps:get(payload, Event)});
        terminal -> ct:fail({gemini_live_terminal, maps:get(payload, Event)});
        _ -> await_kind(Session, SessionId, Expected, Deadline)
    end.

receive_event(SessionId, Deadline) ->
    Timeout = remaining(Deadline),
    receive
        {adk_live_event, SessionId, Sequence, Event} ->
            {Sequence, Event};
        {adk_live_subscriber_dropped, SessionId, Reason} ->
            ct:fail({live_subscriber_dropped, Reason})
    after Timeout ->
        ct:fail(gemini_live_event_timeout)
    end.

summarize_event(audio, Event, Summary) ->
    Media = maps:get(payload, Event),
    Summary#{audio_bytes := maps:get(audio_bytes, Summary)
                             + adk_live_media:bytes(Media)};
summarize_event(output_transcription, Event, Summary) ->
    #{text := Text} = maps:get(payload, Event),
    Existing = maps:get(transcription, Summary),
    Summary#{transcription := <<Existing/binary, Text/binary>>};
summarize_event(_Kind, _Event, Summary) ->
    Summary.

assert_audio_and_transcription(#{audio_bytes := AudioBytes,
                                 transcription := Transcript}) ->
    true = AudioBytes > 0,
    true = byte_size(string:trim(Transcript)) > 0,
    ok.

deadline(Timeout) ->
    erlang:monotonic_time(millisecond) + Timeout.

remaining(Deadline) ->
    erlang:max(1, Deadline - erlang:monotonic_time(millisecond)).
