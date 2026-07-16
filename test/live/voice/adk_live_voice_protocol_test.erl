-module(adk_live_voice_protocol_test).
-include_lib("eunit/include/eunit.hrl").

client_audio_and_control_frames_are_exact_test() ->
    Pcm = <<0, 0, 1, 0>>,
    ?assertEqual(
       {ok, {audio, 1, Pcm}},
       adk_live_voice_protocol:decode_client(
         <<1, 1, 1:64/unsigned-big, 16000:32/unsigned-big, 1, Pcm/binary>>,
         64)),
    ?assertEqual(
       {ok, audio_stream_end},
       adk_live_voice_protocol:decode_client(<<1, 2>>, 64)),
    ?assertEqual(
       {ok, {ack, 99}},
       adk_live_voice_protocol:decode_client(
         <<1, 3, 99:64/unsigned-big>>, 64)),
    ?assertEqual(
       {ok, activity_start},
       adk_live_voice_protocol:decode_client(<<1, 4>>, 64)),
    ?assertEqual(
       {ok, activity_end},
       adk_live_voice_protocol:decode_client(<<1, 5>>, 64)).

malformed_client_frames_are_rejected_test() ->
    Pcm = <<0, 0, 1, 0>>,
    Invalid =
      [<<>>,
       <<2, 2>>,
       <<1, 6>>,
       <<1, 2, 0>>,
       <<1, 3, 0:64/unsigned-big>>,
       <<1, 3, 1:64/unsigned-big, 0>>,
       <<1, 4, 0>>,
       <<1, 5, 0>>],
    lists:foreach(
      fun(Frame) ->
          ?assertMatch(
             {error, _},
             adk_live_voice_protocol:decode_client(Frame, 64))
      end, Invalid),
    InvalidAudio =
      [<<1, 1, 0:64/unsigned-big, 16000:32/unsigned-big, 1, Pcm/binary>>,
       <<1, 1, 1:64/unsigned-big, 24000:32/unsigned-big, 1, Pcm/binary>>,
       <<1, 1, 1:64/unsigned-big, 16000:32/unsigned-big, 2, Pcm/binary>>,
       <<1, 1, 1:64/unsigned-big, 16000:32/unsigned-big, 1>>,
       <<1, 1, 1:64/unsigned-big, 16000:32/unsigned-big, 1, 0>>],
    lists:foreach(
      fun(Frame) ->
          ?assertEqual(
             {error, invalid_live_voice_audio},
             adk_live_voice_protocol:decode_client(Frame, 64))
      end, InvalidAudio),
    ?assertEqual(
       {error, invalid_live_voice_frame},
       adk_live_voice_protocol:decode_client(not_binary, 64)),
    ?assertEqual(
       {error, invalid_live_voice_frame_limit},
       adk_live_voice_protocol:decode_client(<<1, 2>>, 1)).

oversized_audio_is_rejected_before_media_admission_test() ->
    Pcm = binary:copy(<<0>>, 66),
    Frame = <<1, 1, 1:64/unsigned-big, 16000:32/unsigned-big,
              1, Pcm/binary>>,
    ?assertEqual(
       {error, live_voice_audio_frame_too_large},
       adk_live_voice_protocol:decode_client(Frame, 64)).

server_audio_transcription_and_lifecycle_layout_test() ->
    Pcm = <<0, 0, 1, 0>>,
    Audio = event(audio, audio_media(Pcm, 24000, 1), 41),
    ?assertEqual(
       {ok, <<1, 129, 41:64/unsigned-big, 24000:32/unsigned-big,
              1, Pcm/binary>>},
       adk_live_voice_protocol:encode_event(Audio, 1024)),

    Input = event(input_transcription,
                  #{text => <<"heard">>, final => false}, 42),
    ?assertEqual(
       {ok, <<1, 130, 42:64/unsigned-big, 1, 0, "heard">>},
       adk_live_voice_protocol:encode_event(Input, 1024)),
    Output = event(output_transcription,
                   #{text => <<"answer">>, final => true}, 43),
    ?assertEqual(
       {ok, <<1, 130, 43:64/unsigned-big, 2, 1, "answer">>},
       adk_live_voice_protocol:encode_event(Output, 1024)),

    ExpectedCodes =
      [{ready, 1},
       {generation_complete, 2},
       {turn_complete, 3},
       {interrupted, 4},
       {reconnecting, 5},
       {go_away, 7},
       {terminal, 8},
       {error, 9}],
    lists:foreach(
      fun({Kind, Code}) ->
          Event = event(Kind, #{}, 50 + Code),
          ?assertEqual(
             {ok, <<1, 131, (50 + Code):64/unsigned-big, Code:8>>},
             adk_live_voice_protocol:encode_event(Event, 1024))
      end, ExpectedCodes),
    Resumed = event(resumption_status, #{resumed => true}, 56),
    ?assertEqual(
       {ok, <<1, 131, 56:64/unsigned-big, 6>>},
       adk_live_voice_protocol:encode_event(Resumed, 1024)),
    HandleUpdated = event(
                      resumption_status,
                      #{resumable => true, handle_updated => true}, 57),
    ?assertEqual(
       skip,
       adk_live_voice_protocol:encode_event(HandleUpdated, 1024)),
    ?assertEqual({ok, 4},
                 adk_live_voice_protocol:lifecycle_code(interrupted)).

non_public_and_unrepresentable_server_events_are_safe_test() ->
    Content = event(content,
                    #{part => #{text => <<"private">>, thought => false}},
                    1),
    ?assertEqual(skip,
                 adk_live_voice_protocol:encode_event(Content, 1024)),
    Usage = event(usage, #{tokens => 10}, 2),
    ?assertEqual(skip,
                 adk_live_voice_protocol:encode_event(Usage, 1024)),
    TooLarge = event(output_transcription,
                     #{text => binary:copy(<<"a">>, 64), final => true},
                     3),
    ?assertEqual(
       {error, live_voice_output_frame_too_large},
       adk_live_voice_protocol:encode_event(TooLarge, 16)),
    {ok, Unenveloped} = adk_live_event:new(ready, #{}),
    ?assertEqual(
       {error, invalid_live_voice_event},
       adk_live_voice_protocol:encode_event(Unenveloped, 1024)),
    ?assertEqual(
       {error, invalid_live_voice_event},
       adk_live_voice_protocol:encode_event(not_an_event, 1024)),
    ?assertEqual(
       {error, invalid_live_voice_frame_limit},
       adk_live_voice_protocol:encode_event(event(ready, #{}, 1), 10)).

event(Kind, Payload, Sequence) ->
    {ok, Base} = adk_live_event:new(Kind, Payload),
    {ok, Event} = adk_live_event:with_envelope(Base, Sequence, 2, 3),
    Event.

audio_media(Pcm, Rate, Channels) ->
    {ok, Media} = adk_live_media:audio_pcm(Pcm, Rate, Channels),
    Media.
