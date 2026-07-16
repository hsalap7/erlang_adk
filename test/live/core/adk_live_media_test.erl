-module(adk_live_media_test).

-include_lib("eunit/include/eunit.hrl").

pcm_round_trip_test() ->
    Raw = <<0, 1, 2, 3, 4, 5, 6, 7>>,
    {ok, Media} = adk_live_media:audio_pcm(Raw, 16000, 1),
    ?assertEqual(ok, adk_live_media:validate(Media)),
    ?assertEqual(byte_size(Raw), adk_live_media:bytes(Media)),
    {ok, Blob} = adk_live_media:to_gemini_blob(Media),
    ?assertEqual(<<"audio/pcm;rate=16000">>,
                 maps:get(<<"mimeType">>, Blob)),
    ?assertEqual({ok, Media},
                 adk_live_media:from_gemini_blob(
                   maps:get(<<"mimeType">>, Blob),
                   maps:get(<<"data">>, Blob))).

strict_pcm_validation_test() ->
    ?assertEqual({error, invalid_audio_data},
                 adk_live_media:audio_pcm(<<1>>, 16000, 1)),
    ?assertEqual({error, invalid_sample_rate},
                 adk_live_media:audio_pcm(<<0, 0>>, 1000, 1)),
    ?assertEqual({error, invalid_channels},
                 adk_live_media:audio_pcm(<<0, 0>>, 16000, 3)),
    TooLarge = binary:copy(<<0>>, 1048578),
    ?assertEqual({error, audio_chunk_too_large},
                 adk_live_media:audio_pcm(TooLarge, 16000, 1)).

video_and_mime_bounds_test() ->
    {ok, Frame} = adk_live_media:video_frame(jpeg, <<16#ff, 16#d8, 0, 1>>),
    {ok, Blob} = adk_live_media:to_gemini_blob(Frame),
    ?assertEqual(<<"image/jpeg">>, maps:get(<<"mimeType">>, Blob)),
    ?assertEqual({ok, Frame},
                 adk_live_media:from_gemini_blob(
                   <<"image/jpeg">>, maps:get(<<"data">>, Blob))),
    ?assertEqual({error, unsupported_media_type},
                 adk_live_media:from_gemini_blob(
                   <<"audio/mpeg">>, base64:encode(<<0, 0>>))),
    ?assertEqual({error, invalid_base64},
                 adk_live_media:from_gemini_blob(
                   <<"audio/pcm;rate=16000">>, <<"not-base64">>)).

event_audio_is_ephemeral_and_byte_charged_test() ->
    {ok, Media} = adk_live_media:audio_pcm(<<0, 0, 1, 0>>, 24000, 1),
    {ok, Event0} = adk_live_event:new(audio, Media),
    {ok, Event} = adk_live_event:with_envelope(Event0, 1, 0, 2),
    ?assertEqual(ephemeral, adk_live_event:durability(Event)),
    ?assertEqual(audio, adk_live_event:kind(Event)),
    ?assertEqual(1, adk_live_event:sequence(Event)),
    ?assert(adk_live_event:bytes(Event) >= 132),
    ?assertEqual(ok, adk_live_event:validate(Event)).
