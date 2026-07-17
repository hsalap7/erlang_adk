-module(adk_live_openai_codec_test).

-include_lib("eunit/include/eunit.hrl").

strict_config_and_capabilities_test() ->
    {ok, Config} = adk_live_openai:validate_config(#{}),
    ?assertEqual(<<"gpt-realtime-2.1">>, maps:get(model, Config)),
    ?assertEqual([audio], maps:get(response_modalities, Config)),
    ?assertEqual(semantic_vad, maps:get(turn_detection, Config)),
    ?assertEqual(adk_live_openai_gun_transport,
                 adk_live_openai:transport()),
    ?assertEqual(true, maps:get(live, adk_live_openai:capabilities())),
    ?assertMatch(
       {error, {invalid_live_config, [response_modalities], invalid_value}},
       adk_live_openai:validate_config(
         #{response_modalities => [text, audio]})),
    ?assertMatch(
       {error, {invalid_live_config, [endpoint], unsupported_option}},
       adk_live_openai:validate_config(#{endpoint => <<"https://evil">>})),
    ?assertMatch(
       {error, {invalid_live_config, [turn_detection],
                conflicting_or_invalid_value}},
       adk_live_openai:validate_config(
         #{turn_detection => disabled,
           automatic_activity_detection => true})).

setup_uses_current_realtime_session_shape_test() ->
    Tool = #{type => function,
             name => <<"weather">>,
             description => <<"Look up weather">>,
             parameters => #{<<"type">> => <<"object">>}},
    {ok, Frame} = adk_live_openai:setup_frame(
                    #{system_instruction => <<"Be concise">>,
                      voice_name => <<"marin">>,
                      input_audio_transcription => true,
                      turn_detection => server_vad,
                      tools => [Tool]}),
    #{<<"type">> := <<"session.update">>,
      <<"session">> := Session} = jsx:decode(Frame, [return_maps]),
    ?assertEqual(<<"realtime">>, maps:get(<<"type">>, Session)),
    ?assertEqual(<<"gpt-realtime-2.1">>,
                 maps:get(<<"model">>, Session)),
    ?assertEqual([<<"audio">>], maps:get(<<"output_modalities">>, Session)),
    Audio = maps:get(<<"audio">>, Session),
    Input = maps:get(<<"input">>, Audio),
    ?assertEqual(#{<<"type">> => <<"audio/pcm">>, <<"rate">> => 24000},
                 maps:get(<<"format">>, Input)),
    ?assertEqual(<<"server_vad">>,
                 maps:get(<<"type">>, maps:get(<<"turn_detection">>, Input))),
    ?assertEqual(<<"gpt-4o-mini-transcribe">>,
                 maps:get(<<"model">>, maps:get(<<"transcription">>, Input))),
    Output = maps:get(<<"output">>, Audio),
    ?assertEqual(<<"marin">>, maps:get(<<"voice">>, Output)),
    [WireTool] = maps:get(<<"tools">>, Session),
    ?assertEqual(<<"weather">>, maps:get(<<"name">>, WireTool)).

text_image_and_tool_actions_are_ordered_batches_test() ->
    {ok, [TextItem, TextResponse]} =
        adk_live_openai:encode_client({text, <<"hello">>}, #{}),
    ?assertEqual(<<"conversation.item.create">>,
                 event_type(TextItem)),
    ?assertEqual(<<"response.create">>, event_type(TextResponse)),

    {ok, Image} = adk_live_media:video_frame(png, <<1, 2, 3>>),
    {ok, [ImageItem, ImageResponse]} =
        adk_live_openai:encode_client({video_frame, Image}, #{}),
    #{<<"item">> := #{<<"content">> := [ImageContent]}} =
        jsx:decode(ImageItem, [return_maps]),
    ?assertMatch(<<"data:image/png;base64," , _/binary>>,
                 maps:get(<<"image_url">>, ImageContent)),
    ?assertEqual(<<"response.create">>, event_type(ImageResponse)),

    {ok, [ToolItem, ToolResponse]} = adk_live_openai:encode_client(
                                      {tool_response, <<"call-1">>,
                                       <<"weather">>,
                                       #{<<"temp">> => 21}}, #{}),
    #{<<"item">> := #{<<"type">> := <<"function_call_output">>,
                       <<"call_id">> := <<"call-1">>,
                       <<"output">> := Output}} =
        jsx:decode(ToolItem, [return_maps]),
    ?assertEqual(#{<<"temp">> => 21}, jsx:decode(Output, [return_maps])),
    ?assertEqual(<<"response.create">>, event_type(ToolResponse)).

audio_and_manual_commit_validation_test() ->
    Raw = <<0, 0, 1, 0>>,
    {ok, Audio} = adk_live_media:audio_pcm(Raw, 24000, 1),
    {ok, Frame} = adk_live_openai:encode_client({audio, Audio}, #{}),
    #{<<"type">> := <<"input_audio_buffer.append">>,
      <<"audio">> := Encoded} = jsx:decode(Frame, [return_maps]),
    ?assertEqual(Raw, base64:decode(Encoded)),
    {ok, WrongRate} = adk_live_media:audio_pcm(Raw, 16000, 1),
    ?assertMatch(
       {error, {live_protocol_error, [input_audio_buffer, audio],
                input_audio_must_be_24khz_mono}},
       adk_live_openai:encode_client({audio, WrongRate}, #{})),
    ?assertEqual(ignored,
                 adk_live_openai:encode_client(audio_stream_end, #{})),
    {ok, [Commit, Response]} = adk_live_openai:encode_client(
                               activity_end,
                               #{automatic_activity_detection => false}),
    ?assertEqual(<<"input_audio_buffer.commit">>, event_type(Commit)),
    ?assertEqual(<<"response.create">>, event_type(Response)),
    ?assertEqual(ignored,
                 adk_live_openai:encode_client(
                   audio_stream_end,
                   #{automatic_activity_detection => false})).

setup_preamble_and_core_output_events_test() ->
    ?assertEqual(
       {ok, []},
       decode(#{<<"type">> => <<"session.created">>})),
    ?assertEqual(
       {ok, [#{kind => setup_complete, payload => #{}}]},
       decode(#{<<"type">> => <<"session.updated">>})),
    Raw = <<0, 0, 2, 0>>,
    {ok, [#{kind := audio, payload := Media}]} =
        decode(#{<<"type">> => <<"response.output_audio.delta">>,
                 <<"delta">> => base64:encode(Raw)}),
    ?assertEqual(Raw, maps:get(data, Media)),
    ?assertEqual(24000, maps:get(sample_rate, Media)),
    ?assertEqual(
       {ok, [#{kind => content,
               payload => #{part => #{text => <<"hi">>,
                                      thought => false}}}]},
       decode(#{<<"type">> => <<"response.output_text.delta">>,
                <<"delta">> => <<"hi">>})).

transcription_tool_turn_usage_and_interruption_test() ->
    Config = #{input_audio_transcription => true,
               output_audio_transcription => true},
    ?assertEqual(
       {ok, [#{kind => input_transcription,
               payload => #{text => <<"hello">>, final => true}}]},
       decode(#{<<"type">> =>
                    <<"conversation.item.input_audio_transcription.completed">>,
                <<"transcript">> => <<"hello">>}, Config)),
    ?assertEqual(
       {ok, [#{kind => output_transcription,
               payload => #{text => <<"hel">>, final => false}}]},
       decode(#{<<"type">> =>
                    <<"response.output_audio_transcript.delta">>,
                <<"delta">> => <<"hel">>}, Config)),
    ?assertEqual(
       {ok, [#{kind => tool_call,
               payload => #{id => <<"call-1">>, name => <<"weather">>,
                            args => #{<<"city">> => <<"Pune">>}}}]},
       decode(#{<<"type">> =>
                    <<"response.function_call_arguments.done">>,
                <<"call_id">> => <<"call-1">>,
                <<"name">> => <<"weather">>,
                <<"arguments">> => <<"{\"city\":\"Pune\"}">>})),
    {ok, Completed} = decode(
                        #{<<"type">> => <<"response.done">>,
                          <<"response">> =>
                              #{<<"status">> => <<"completed">>,
                                <<"usage">> =>
                                    #{<<"input_tokens">> => 4,
                                      <<"output_tokens">> => 2,
                                      <<"total_tokens">> => 6}}}),
    ?assertEqual([generation_complete, turn_complete, usage],
                 [maps:get(kind, Event) || Event <- Completed]),
    ?assertEqual(
       {ok, [#{kind => interrupted,
               payload => #{reason => <<"input_speech_started">>}}]},
       decode(#{<<"type">> => <<"input_audio_buffer.speech_started">>})).

malformed_frames_and_provider_errors_are_safe_test() ->
    ?assertMatch(
       {error, {live_protocol_error, [], invalid_json}},
       adk_live_openai:decode_server(<<"not json">>, #{})),
    ?assertMatch(
       {error, {live_protocol_error, [delta], invalid_base64}},
       decode(#{<<"type">> => <<"response.output_audio.delta">>,
                <<"delta">> => <<"%%%">>})),
    Secret = <<"sk-secret-that-must-not-leak">>,
    {ok, [#{kind := error, payload := Safe}]} =
        decode(#{<<"type">> => <<"error">>,
                 <<"error">> =>
                     #{<<"type">> => <<"invalid_request_error">>,
                       <<"code">> => <<"bad_request">>,
                       <<"message">> => Secret}}),
    ?assertEqual(nomatch, binary:match(term_to_binary(Safe), Secret)),
    ?assertEqual(<<"provider_error">>, maps:get(reason, Safe)),
    ?assertEqual({ok, []},
                 decode(#{<<"type">> => <<"future.event">>,
                          <<"secret">> => Secret})).

event_type(Frame) ->
    maps:get(<<"type">>, jsx:decode(Frame, [return_maps])).

decode(Map) -> decode(Map, #{}).
decode(Map, Config) ->
    adk_live_openai:decode_server(jsx:encode(Map), Config).
