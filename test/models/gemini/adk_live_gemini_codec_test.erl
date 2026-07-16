-module(adk_live_gemini_codec_test).

-include_lib("eunit/include/eunit.hrl").

strict_model_capability_validation_test() ->
    {ok, Config} = adk_live_gemini:validate_config(#{}),
    ?assertEqual(<<"gemini-3.1-flash-live-preview">>,
                 maps:get(model, Config)),
    ?assertEqual([audio], maps:get(response_modalities, Config)),
    ?assertMatch(
       {error, {invalid_live_config, [model], unsupported_model}},
       adk_live_gemini:validate_config(
         #{model => <<"gemini-3.1-flash-lite">>})),
    ?assertMatch(
       {error, {invalid_live_config,
                [response_modalities], audio_only}},
       adk_live_gemini:validate_config(
         #{response_modalities => [text]})),
    ?assertMatch(
       {error, {invalid_live_config, [output_schema], unsupported_option}},
       adk_live_gemini:validate_config(#{output_schema => #{}})),
    ?assertMatch(
       {error, {invalid_live_config, [tool_scheduling], unsupported_option}},
       adk_live_gemini:validate_config(
         #{tool_scheduling => nonblocking})),
    Caps = adk_live_gemini:capabilities(),
    ?assertEqual(synchronous, maps:get(function_calling, Caps)),
    ?assertEqual(false, maps:get(proactive_audio, Caps)).

setup_is_single_first_message_and_audio_only_test() ->
    Function = #{type => function,
                 name => <<"weather">>,
                 description => <<"Weather lookup">>,
                 parameters => #{<<"type">> => <<"object">>}},
    Config = #{system_instruction => <<"Be concise">>,
               voice_name => <<"Kore">>,
               input_audio_transcription => true,
               output_audio_transcription => true,
               automatic_activity_detection => false,
               session_resumption => true,
               context_window_compression => true,
               thinking_config => #{thinking_level => low,
                                    include_thoughts => true},
               tools => [#{type => google_search}, Function]},
    {ok, Frame} = adk_live_gemini:setup_frame(Config),
    #{<<"setup">> := Setup} = jsx:decode(Frame, [return_maps]),
    ?assertEqual(1, map_size(jsx:decode(Frame, [return_maps]))),
    ?assertEqual(<<"models/gemini-3.1-flash-live-preview">>,
                 maps:get(<<"model">>, Setup)),
    Generation = maps:get(<<"generationConfig">>, Setup),
    ?assertEqual([<<"AUDIO">>],
                 maps:get(<<"responseModalities">>, Generation)),
    ?assert(maps:is_key(<<"inputAudioTranscription">>, Setup)),
    ?assert(maps:is_key(<<"outputAudioTranscription">>, Setup)),
    ?assertEqual(
       true,
       maps:get(
         <<"disabled">>,
         maps:get(
           <<"automaticActivityDetection">>,
           maps:get(<<"realtimeInputConfig">>, Setup)))),
    ?assertEqual(2, length(maps:get(<<"tools">>, Setup))).

realtime_input_and_vad_legality_test() ->
    {ok, TextFrame} = adk_live_gemini:encode_client(
                        {text, <<"hello">>}, #{}),
    #{<<"realtimeInput">> := #{<<"text">> := <<"hello">>}} =
        jsx:decode(TextFrame, [return_maps]),
    {ok, Media} = adk_live_media:audio_pcm(<<0, 0, 1, 0>>, 16000, 1),
    {ok, AudioFrame} = adk_live_gemini:encode_client(
                         {audio, Media}, #{}),
    #{<<"realtimeInput">> := #{<<"audio">> := Blob}} =
        jsx:decode(AudioFrame, [return_maps]),
    ?assertEqual(<<"audio/pcm;rate=16000">>,
                 maps:get(<<"mimeType">>, Blob)),
    ?assertMatch(
       {error, {live_protocol_error, _, automatic_vad_enabled}},
       adk_live_gemini:encode_client(activity_start, #{})),
    {ok, _} = adk_live_gemini:encode_client(
                activity_start,
                #{automatic_activity_detection => false}),
    ?assertMatch(
       {error, {live_protocol_error, _, manual_vad_enabled}},
       adk_live_gemini:encode_client(
         audio_stream_end,
         #{automatic_activity_detection => false})),
    {ok, _} = adk_live_gemini:encode_client(audio_stream_end, #{}).

gemini_audio_rates_are_enforced_at_provider_boundary_test() ->
    {ok, WrongRate} = adk_live_media:audio_pcm(
                        <<0, 0, 1, 0>>, 24000, 1),
    ?assertMatch(
       {error, {live_protocol_error, [realtime_input, audio],
                input_audio_must_be_16khz_mono}},
       adk_live_gemini:encode_client({audio, WrongRate}, #{})),
    {ok, Stereo} = adk_live_media:audio_pcm(
                     <<0, 0, 1, 0>>, 16000, 2),
    ?assertMatch(
       {error, {live_protocol_error, [realtime_input, audio],
                input_audio_must_be_16khz_mono}},
       adk_live_gemini:encode_client({audio, Stereo}, #{})),
    WrongOutput =
      #{<<"serverContent">> =>
            #{<<"modelTurn">> =>
                  #{<<"parts">> =>
                        [#{<<"inlineData">> =>
                               #{<<"mimeType">> =>
                                     <<"audio/pcm;rate=16000">>,
                                 <<"data">> =>
                                     base64:encode(<<0, 0, 1, 0>>)}}]}}},
    ?assertMatch(
       {error, {live_protocol_error, _,
                output_audio_must_be_24khz_mono}},
       adk_live_gemini:decode_server(jsx:encode(WrongOutput), #{})).

all_server_parts_and_control_signals_are_decoded_test() ->
    RawAudio = <<0, 0, 1, 0>>,
    Message =
      #{<<"serverContent">> =>
            #{<<"modelTurn">> =>
                  #{<<"role">> => <<"model">>,
                    <<"parts">> =>
                        [#{<<"text">> => <<"thinking">>,
                           <<"thought">> => true,
                           <<"thoughtSignature">> => <<"signature">>},
                         #{<<"text">> => <<"answer">>},
                         #{<<"inlineData">> =>
                               #{<<"mimeType">> =>
                                     <<"audio/pcm;rate=24000">>,
                                 <<"data">> => base64:encode(RawAudio)}}]},
              <<"inputTranscription">> =>
                  #{<<"text">> => <<"question">>},
              <<"outputTranscription">> =>
                  #{<<"text">> => <<"answer">>,
                    <<"finished">> => true},
              <<"groundingMetadata">> => #{<<"source">> => <<"search">>},
              <<"generationComplete">> => true,
              <<"interrupted">> => true,
              <<"turnComplete">> => true}},
    {ok, Events} = adk_live_gemini:decode_server(jsx:encode(Message), #{}),
    Kinds = [maps:get(kind, Event) || Event <- Events],
    ?assertEqual([content, content, audio,
                  input_transcription, output_transcription, grounding,
                  generation_complete, interrupted, turn_complete], Kinds),
    [Audio] = [maps:get(payload, Event) || Event <- Events,
                                          maps:get(kind, Event) =:= audio],
    ?assertEqual(RawAudio, maps:get(data, Audio)),
    ?assertEqual(24000, maps:get(sample_rate, Audio)).

current_transcription_and_turn_metadata_are_safely_projected_test() ->
    Message =
      #{<<"serverContent">> =>
            #{<<"interimInputTranscription">> =>
                  #{<<"text">> => <<"hel">>,
                    <<"languageCode">> => <<"en-US">>},
              <<"inputTranscription">> =>
                  #{<<"text">> => <<"hello">>,
                    <<"finished">> => true,
                    <<"languageCode">> => <<"en-US">>},
              <<"outputTranscription">> =>
                  #{<<"text">> => <<"Hi!">>,
                    <<"languageCode">> => <<"en">>},
              <<"turnComplete">> => true,
              <<"turnCompleteReason">> => <<"NEED_MORE_INPUT">>,
              <<"waitingForInput">> => true}},
    {ok, Events} = adk_live_gemini:decode_server(
                     jsx:encode(Message), #{}),
    ?assertEqual(
       [#{kind => input_transcription,
          payload => #{text => <<"hel">>, final => false}},
        #{kind => input_transcription,
          payload => #{text => <<"hello">>, final => true}},
        #{kind => output_transcription,
          payload => #{text => <<"Hi!">>, final => false}},
        #{kind => turn_complete,
          payload => #{reason => <<"NEED_MORE_INPUT">>,
                       waiting_for_input => true}}],
       Events).

optional_transcription_metadata_and_wait_state_can_be_noops_test() ->
    Message =
      #{<<"serverContent">> =>
            #{<<"interimInputTranscription">> => #{},
              <<"inputTranscription">> =>
                  #{<<"languageCode">> => <<"en-Latn-US">>},
              <<"outputTranscription">> => #{<<"finished">> => true},
              <<"turnCompleteReason">> => <<"NEED_MORE_INPUT">>,
              <<"waitingForInput">> => true}},
    ?assertEqual(
       {ok, []},
       adk_live_gemini:decode_server(jsx:encode(Message), #{})).

current_turn_complete_reasons_remain_bounded_binaries_test() ->
    Reasons =
      [<<"TURN_COMPLETE_REASON_UNSPECIFIED">>,
       <<"MALFORMED_FUNCTION_CALL">>,
       <<"RESPONSE_REJECTED">>,
       <<"NEED_MORE_INPUT">>,
       <<"PROHIBITED_INPUT_CONTENT">>,
       <<"IMAGE_PROHIBITED_INPUT_CONTENT">>,
       <<"INPUT_TEXT_CONTAIN_PROMINENT_PERSON_PROHIBITED">>,
       <<"INPUT_IMAGE_CELEBRITY">>,
       <<"INPUT_IMAGE_PHOTO_REALISTIC_CHILD_PROHIBITED">>,
       <<"INPUT_TEXT_NCII_PROHIBITED">>,
       <<"INPUT_OTHER">>,
       <<"INPUT_IP_PROHIBITED">>,
       <<"BLOCKLIST">>,
       <<"UNSAFE_PROMPT_FOR_IMAGE_GENERATION">>,
       <<"GENERATED_IMAGE_SAFETY">>,
       <<"GENERATED_CONTENT_SAFETY">>,
       <<"GENERATED_AUDIO_SAFETY">>,
       <<"GENERATED_VIDEO_SAFETY">>,
       <<"GENERATED_CONTENT_PROHIBITED">>,
       <<"GENERATED_CONTENT_BLOCKLIST">>,
       <<"GENERATED_IMAGE_PROHIBITED">>,
       <<"GENERATED_IMAGE_CELEBRITY">>,
       <<"GENERATED_IMAGE_PROMINENT_PEOPLE_DETECTED_BY_REWRITER">>,
       <<"GENERATED_IMAGE_IDENTIFIABLE_PEOPLE">>,
       <<"GENERATED_IMAGE_MINORS">>,
       <<"OUTPUT_IMAGE_IP_PROHIBITED">>,
       <<"GENERATED_OTHER">>,
       <<"MAX_REGENERATION_REACHED">>],
    lists:foreach(
      fun(WireReason) ->
          Message =
            #{<<"serverContent">> =>
                  #{<<"turnComplete">> => true,
                    <<"turnCompleteReason">> => WireReason}},
          ?assertEqual(
             {ok, [#{kind => turn_complete,
                     payload => #{reason => WireReason}}]},
             adk_live_gemini:decode_server(jsx:encode(Message), #{}))
      end,
      Reasons).

future_enum_shaped_turn_complete_reason_is_forward_compatible_test() ->
    FutureReason = <<"FUTURE_POLICY_REASON_2">>,
    Message =
      #{<<"serverContent">> =>
            #{<<"turnComplete">> => true,
              <<"turnCompleteReason">> => FutureReason}},
    ?assertEqual(
       {ok, [#{kind => turn_complete,
               payload => #{reason => FutureReason}}]},
       adk_live_gemini:decode_server(jsx:encode(Message), #{})).

current_optional_server_content_fields_remain_strictly_bounded_test() ->
    BadMessages =
      [#{<<"serverContent">> =>
             #{<<"interimInputTranscription">> =>
                   #{<<"text">> => <<"hello">>,
                     <<"finished">> => <<"false">>}}},
       #{<<"serverContent">> =>
             #{<<"inputTranscription">> =>
                   #{<<"text">> => <<"hello">>,
                     <<"languageCode">> => <<"en_US">>}}},
       #{<<"serverContent">> =>
             #{<<"inputTranscription">> =>
                   #{<<"text">> =>
                         binary:copy(<<"x">>, 65537)}}},
       #{<<"serverContent">> =>
             #{<<"turnCompleteReason">> => <<>>}},
       #{<<"serverContent">> =>
             #{<<"turnCompleteReason">> =>
                   binary:copy(<<"A">>, 129)}},
       #{<<"serverContent">> =>
             #{<<"turnCompleteReason">> => <<"future-reason">>}},
       #{<<"serverContent">> =>
             #{<<"turnCompleteReason">> => 42}},
       #{<<"serverContent">> =>
             #{<<"waitingForInput">> => <<"true">>}}],
    lists:foreach(
      fun(Message) ->
          ?assertMatch(
             {error, {live_protocol_error, _, _}},
             adk_live_gemini:decode_server(jsx:encode(Message), #{}))
      end,
      BadMessages).

current_voice_control_messages_are_validated_and_consumed_test() ->
    VoiceActivityTypes =
      [<<"TYPE_UNSPECIFIED">>, <<"ACTIVITY_START">>, <<"ACTIVITY_END">>],
    lists:foreach(
      fun(ActivityType) ->
          ?assertEqual(
             {ok, []},
             adk_live_gemini:decode_server(
               jsx:encode(
                 #{<<"voiceActivity">> =>
                       #{<<"voiceActivityType">> => ActivityType,
                         <<"audioOffset">> => <<"1.250s">>}}), #{}))
      end,
      VoiceActivityTypes),
    VadSignalTypes =
      [<<"VAD_SIGNAL_TYPE_UNSPECIFIED">>,
       <<"VAD_SIGNAL_TYPE_SOS">>, <<"VAD_SIGNAL_TYPE_EOS">>],
    lists:foreach(
      fun(SignalType) ->
          ?assertEqual(
             {ok, []},
             adk_live_gemini:decode_server(
               jsx:encode(
                 #{<<"voiceActivityDetectionSignal">> =>
                       #{<<"vadSignalType">> => SignalType}}), #{}))
      end,
      VadSignalTypes).

voice_controls_compose_with_server_content_and_usage_test() ->
    Message =
      #{<<"voiceActivity">> =>
            #{<<"voiceActivityType">> => <<"ACTIVITY_END">>},
        <<"voiceActivityDetectionSignal">> =>
            #{<<"vadSignalType">> => <<"VAD_SIGNAL_TYPE_EOS">>},
        <<"serverContent">> => #{<<"turnComplete">> => true},
        <<"usageMetadata">> => #{<<"totalTokenCount">> => 7}},
    {ok, Events} = adk_live_gemini:decode_server(
                     jsx:encode(Message), #{}),
    ?assertEqual([turn_complete, usage],
                 [maps:get(kind, Event) || Event <- Events]).

malformed_or_unknown_voice_controls_are_rejected_test() ->
    BadMessages =
      [#{<<"voiceActivity">> =>
             #{<<"voiceActivityType">> => <<"ACTIVITY_PAUSE">>}},
       #{<<"voiceActivity">> =>
             #{<<"voiceActivityType">> => 1}},
       #{<<"voiceActivity">> =>
             #{<<"voiceActivityType">> => <<"ACTIVITY_START">>,
               <<"audioOffset">> => binary:copy(<<"1">>, 65)}},
       #{<<"voiceActivity">> =>
             #{<<"voiceActivityType">> => <<"ACTIVITY_START">>,
               <<"unexpected">> => true}},
       #{<<"voiceActivityDetectionSignal">> =>
             #{<<"vadSignalType">> => <<"VAD_SIGNAL_TYPE_MAYBE">>}},
       #{<<"voiceActivityDetectionSignal">> =>
             #{<<"vadSignalType">> => false}}],
    lists:foreach(
      fun(Message) ->
          ?assertMatch(
             {error, {live_protocol_error, _, _}},
             adk_live_gemini:decode_server(jsx:encode(Message), #{}))
      end,
      BadMessages).

setup_tool_and_resumption_messages_are_strict_test() ->
    ?assertEqual(
       {ok, [#{kind => setup_complete, payload => #{}}]},
       adk_live_gemini:decode_server(
         jsx:encode(#{<<"setupComplete">> => #{}}), #{})),
    ToolMessage =
      #{<<"toolCall">> =>
            #{<<"functionCalls">> =>
                  [#{<<"id">> => <<"call-1">>,
                     <<"name">> => <<"weather">>,
                     <<"args">> => #{<<"city">> => <<"Pune">>}},
                   #{<<"id">> => <<"call-2">>,
                     <<"name">> => <<"clock">>,
                     <<"args">> => #{}}]}},
    {ok, ToolEvents} = adk_live_gemini:decode_server(
                         jsx:encode(ToolMessage), #{}),
    ?assertEqual([tool_call, tool_call],
                 [maps:get(kind, Event) || Event <- ToolEvents]),
    NonBlocking =
      #{<<"toolCall">> =>
            #{<<"functionCalls">> =>
                  [#{<<"id">> => <<"call-3">>,
                     <<"name">> => <<"unsafe">>,
                     <<"args">> => #{},
                     <<"behavior">> => <<"NON_BLOCKING">>}]}},
    ?assertMatch(
       {error, {live_protocol_error, _, synchronous_calls_only}},
       adk_live_gemini:decode_server(jsx:encode(NonBlocking), #{})),
    Handle = <<"private-resumption-handle">>,
    {ok, [Update]} = adk_live_gemini:decode_server(
                       jsx:encode(
                         #{<<"sessionResumptionUpdate">> =>
                               #{<<"newHandle">> => Handle,
                                 <<"resumable">> => true}}), #{}),
    ?assertEqual(resumption_update, maps:get(kind, Update)),
    ?assertEqual(Handle, maps:get(handle, maps:get(payload, Update))),
    {ok, [Unavailable]} = adk_live_gemini:decode_server(
                            jsx:encode(
                              #{<<"sessionResumptionUpdate">> =>
                                    #{<<"newHandle">> => <<>>,
                                      <<"resumable">> => false}}), #{}),
    ?assertEqual(false,
                 maps:get(resumable, maps:get(payload, Unavailable))),
    ?assertMatch(
       {error, {live_protocol_error, _, unsupported_server_message}},
       adk_live_gemini:decode_server(
         jsx:encode(#{<<"unexpected">> => #{}}), #{})).

server_message_can_carry_usage_metadata_test() ->
    Message = #{<<"serverContent">> => #{<<"turnComplete">> => true},
                <<"usageMetadata">> =>
                    #{<<"promptTokenCount">> => 4,
                      <<"responseTokenCount">> => 2,
                      <<"totalTokenCount">> => 6}},
    {ok, Events} = adk_live_gemini:decode_server(
                     jsx:encode(Message), #{}),
    ?assertEqual([turn_complete, usage],
                 [maps:get(kind, Event) || Event <- Events]),
    ?assertMatch(
       {error, {live_protocol_error, _, missing_server_message}},
       adk_live_gemini:decode_server(
         jsx:encode(#{<<"usageMetadata">> => #{}}), #{})).

empty_server_content_is_a_consumed_noop_test() ->
    ?assertEqual(
       {ok, []},
       adk_live_gemini:decode_server(
         jsx:encode(#{<<"serverContent">> => #{}}), #{})),
    ?assertEqual(
       {ok, []},
       adk_live_gemini:decode_server(
         jsx:encode(
           #{<<"serverContent">> =>
                 #{<<"generationComplete">> => false,
                   <<"turnComplete">> => false,
                   <<"interrupted">> => false}}), #{})).

resume_setup_uses_explicit_handle_test() ->
    Handle = <<"opaque-latest-handle">>,
    {ok, Frame} = adk_live_gemini:resume_setup_frame(
                    #{session_resumption => true}, Handle),
    #{<<"setup">> := Setup} = jsx:decode(Frame, [return_maps]),
    ?assertEqual(
       Handle,
       maps:get(<<"handle">>, maps:get(<<"sessionResumption">>, Setup))),
    ?assertMatch(
       {error, {live_protocol_error, _, not_enabled}},
       adk_live_gemini:resume_setup_frame(#{}, Handle)),
    ?assertMatch(
       {error, {live_protocol_error, _, invalid_handle}},
       adk_live_gemini:resume_setup_frame(
         #{session_resumption => true}, <<>>)).
