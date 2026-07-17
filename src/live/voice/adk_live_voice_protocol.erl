%% @doc Strict provider-neutral binary framing for realtime browser voice.
%%
%% One binary is exactly one frame.  Version 1 intentionally has no generic
%% length-prefixed or JSON envelope: every type has one exact shape, making it
%% possible for an HTTP/WebSocket adapter to reject malformed input before it
%% reaches a Live session.  Multi-byte header integers are big-endian; PCM
%% samples inside the payload are signed 16-bit little-endian.
-module(adk_live_voice_protocol).

-export([decode_client/2, encode_input_config/1,
         encode_event/2, lifecycle_code/1]).

-define(VERSION, 1).
-define(MAX_AUDIO_BYTES, 1048576).
-define(MAX_FRAME_BYTES, 67108864).
-define(MAX_U64, 16#ffffffffffffffff).
-define(INPUT_FORMAT_PCM_S16LE, 1).

-type client_action() ::
    {audio, pos_integer(), 16000 | 24000, binary()} |
    audio_stream_end |
    {ack, pos_integer()} |
    activity_start |
    activity_end.
-type decode_error() ::
    invalid_live_voice_frame |
    invalid_live_voice_audio |
    live_voice_audio_frame_too_large |
    invalid_live_voice_frame_limit.
-type encode_error() ::
    invalid_live_voice_config |
    invalid_live_voice_event |
    invalid_live_voice_frame_limit |
    live_voice_output_frame_too_large.

-export_type([client_action/0, decode_error/0, encode_error/0]).

%% Client -> server v1 frames:
%%   audio       <<1, 1, ClientAudioSeq:64/big, Rate:32/big, 1, PCM/binary>>
%%   stream end  <<1, 2>>
%%   event ack   <<1, 3, LiveEventSeq:64/big>>
%%   VAD start   <<1, 4>>
%%   VAD end     <<1, 5>>
-spec decode_client(binary(), pos_integer()) ->
    {ok, client_action()} | {error, decode_error()}.
decode_client(Frame, MaxAudioBytes)
  when is_binary(Frame), is_integer(MaxAudioBytes),
       MaxAudioBytes >= 2, MaxAudioBytes =< ?MAX_AUDIO_BYTES ->
    decode_client_frame(Frame, MaxAudioBytes);
decode_client(Frame, MaxAudioBytes)
  when not is_binary(Frame), is_integer(MaxAudioBytes),
       MaxAudioBytes >= 2, MaxAudioBytes =< ?MAX_AUDIO_BYTES ->
    {error, invalid_live_voice_frame};
decode_client(_Frame, _MaxAudioBytes) ->
    {error, invalid_live_voice_frame_limit}.

decode_client_frame(
  <<?VERSION, 1, Sequence:64/unsigned-big, Rate:32/unsigned-big,
    Channels:8, Pcm/binary>>, MaxAudioBytes) ->
    case byte_size(Pcm) > MaxAudioBytes of
        true ->
            {error, live_voice_audio_frame_too_large};
        false when Sequence > 0,
                   (Rate =:= 16000 orelse Rate =:= 24000),
                   Channels =:= 1,
                   byte_size(Pcm) > 0, byte_size(Pcm) rem 2 =:= 0 ->
            {ok, {audio, Sequence, Rate, Pcm}};
        false ->
            {error, invalid_live_voice_audio}
    end;
decode_client_frame(<<?VERSION, 2>>, _MaxAudioBytes) ->
    {ok, audio_stream_end};
decode_client_frame(<<?VERSION, 3, Sequence:64/unsigned-big>>,
                    _MaxAudioBytes)
  when Sequence > 0 ->
    {ok, {ack, Sequence}};
decode_client_frame(<<?VERSION, 4>>, _MaxAudioBytes) ->
    {ok, activity_start};
decode_client_frame(<<?VERSION, 5>>, _MaxAudioBytes) ->
    {ok, activity_end};
decode_client_frame(_Frame, _MaxAudioBytes) ->
    {error, invalid_live_voice_frame}.

%% Server -> client input-format negotiation frame:
%%   <<1, 128, Rate:32/big, Channels:8, Format:8>>
%%
%% The frame is connection configuration rather than a Live event.  It has no
%% event sequence and consumes no subscriber credit, so clients must not ACK
%% it.  Format code 1 is signed 16-bit little-endian PCM.
-spec encode_input_config(map()) ->
    {ok, binary()} | {error, invalid_live_voice_config}.
encode_input_config(#{sample_rate := Rate, channels := 1,
                      format := pcm_s16le} = Config)
  when map_size(Config) =:= 3,
       (Rate =:= 16000 orelse Rate =:= 24000) ->
    {ok, <<?VERSION, 128, Rate:32/unsigned-big, 1,
           ?INPUT_FORMAT_PCM_S16LE>>};
encode_input_config(_Config) ->
    {error, invalid_live_voice_config}.

%% Server -> client v1 frames:
%%   audio         <<1, 129, EventSeq:64/big, Rate:32/big, Channels:8, PCM>>
%%   transcription <<1, 130, EventSeq:64/big, Direction:8, Final:8, UTF8>>
%%   lifecycle     <<1, 131, EventSeq:64/big, StateCode:8>>
%%
%% Direction is 1 for input and 2 for output.  Final is exactly 0 or 1.
%% Non-public Live events return `skip' so the bridge can acknowledge them
%% internally without exposing provider payloads.
-spec encode_event(adk_live_event:event(), pos_integer()) ->
    {ok, binary()} | skip | {error, encode_error()}.
encode_event(Event, MaxFrameBytes)
  when is_map(Event), is_integer(MaxFrameBytes),
       MaxFrameBytes >= 11, MaxFrameBytes =< ?MAX_FRAME_BYTES ->
    case safe_validate_event(Event) of
        ok -> encode_checked_event(Event, MaxFrameBytes);
        {error, _} -> {error, invalid_live_voice_event}
    end;
encode_event(Event, MaxFrameBytes)
  when not is_map(Event), is_integer(MaxFrameBytes),
       MaxFrameBytes >= 11, MaxFrameBytes =< ?MAX_FRAME_BYTES ->
    {error, invalid_live_voice_event};
encode_event(_Event, _MaxFrameBytes) ->
    {error, invalid_live_voice_frame_limit}.

encode_checked_event(#{kind := audio, sequence := Sequence,
                       payload := #{data := Pcm, sample_rate := Rate,
                                    channels := Channels}}, MaxFrameBytes)
  when is_binary(Pcm), is_integer(Rate), Rate > 0, Rate =< 16#ffffffff,
       is_integer(Channels), Channels > 0, Channels =< 255 ->
    case valid_event_sequence(Sequence) of
        true ->
            bounded_frame(
              <<?VERSION, 129, Sequence:64/unsigned-big,
                Rate:32/unsigned-big, Channels:8, Pcm/binary>>,
              MaxFrameBytes);
        false ->
            {error, invalid_live_voice_event}
    end;
encode_checked_event(#{kind := Kind, sequence := Sequence,
                       payload := #{text := Text, final := Final}},
                     MaxFrameBytes)
  when (Kind =:= input_transcription orelse
        Kind =:= output_transcription),
       is_binary(Text), is_boolean(Final) ->
    case valid_event_sequence(Sequence) of
        true ->
            Direction = case Kind of
                input_transcription -> 1;
                output_transcription -> 2
            end,
            FinalCode = case Final of true -> 1; false -> 0 end,
            bounded_frame(
              <<?VERSION, 130, Sequence:64/unsigned-big,
                Direction:8, FinalCode:8, Text/binary>>,
              MaxFrameBytes);
        false ->
            {error, invalid_live_voice_event}
    end;
%% A provider handle update means future resumption is possible; it does not
%% mean a reconnect has completed.  Only the session's explicit post-setup
%% resumed event is public lifecycle code 6.  Handle-only status is ACKed
%% internally by the bridge and never mislabels the browser state.
encode_checked_event(#{kind := resumption_status, sequence := Sequence,
                       payload := #{resumed := true}}, MaxFrameBytes) ->
    case valid_event_sequence(Sequence) of
        true ->
            bounded_frame(
              <<?VERSION, 131, Sequence:64/unsigned-big, 6:8>>,
              MaxFrameBytes);
        false ->
            {error, invalid_live_voice_event}
    end;
encode_checked_event(#{kind := resumption_status}, _MaxFrameBytes) ->
    skip;
encode_checked_event(#{kind := Kind, sequence := Sequence}, MaxFrameBytes) ->
    case lifecycle_code(Kind) of
        {ok, Code} ->
            case valid_event_sequence(Sequence) of
                true ->
                    bounded_frame(
                      <<?VERSION, 131, Sequence:64/unsigned-big, Code:8>>,
                      MaxFrameBytes);
                false ->
                    {error, invalid_live_voice_event}
            end;
        error ->
            skip
    end.

%% Code 4 is a stable wire contract: a browser must purge queued playback
%% immediately when it receives that lifecycle frame.
-spec lifecycle_code(atom()) -> {ok, 1..9} | error.
lifecycle_code(ready) -> {ok, 1};
lifecycle_code(generation_complete) -> {ok, 2};
lifecycle_code(turn_complete) -> {ok, 3};
lifecycle_code(interrupted) -> {ok, 4};
lifecycle_code(reconnecting) -> {ok, 5};
lifecycle_code(resumption_status) -> {ok, 6};
lifecycle_code(go_away) -> {ok, 7};
lifecycle_code(terminal) -> {ok, 8};
lifecycle_code(error) -> {ok, 9};
lifecycle_code(_Kind) -> error.

bounded_frame(Frame, MaxFrameBytes) ->
    case byte_size(Frame) =< MaxFrameBytes of
        true -> {ok, Frame};
        false -> {error, live_voice_output_frame_too_large}
    end.

valid_event_sequence(Sequence) ->
    is_integer(Sequence) andalso Sequence > 0 andalso
    Sequence =< ?MAX_U64.

safe_validate_event(Event) ->
    try adk_live_event:validate(Event)
    catch _:_ -> {error, invalid_live_event}
    end.
