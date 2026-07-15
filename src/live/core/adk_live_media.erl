%% @doc Strict, provider-neutral realtime media values.
%%
%% Live media deliberately does not use `adk_content'.  PCM MIME parameters
%% and short-lived audio/video chunks have different lifetime and pressure
%% semantics from durable model content.  Raw bytes remain Erlang binaries
%% until a provider codec crosses its JSON boundary.
-module(adk_live_media).

-export([audio_pcm/3, video_frame/2, validate/1, bytes/1,
         to_gemini_blob/1, from_gemini_blob/2]).

-define(SCHEMA_VERSION, 1).
-define(MAX_AUDIO_CHUNK_BYTES, 1048576).
-define(MAX_VIDEO_FRAME_BYTES, 4194304).

-type media() :: #{
    schema_version := 1,
    kind := audio | video,
    format := pcm_s16le | jpeg | png,
    data := binary(),
    sample_rate => pos_integer(),
    channels => pos_integer()
}.
-type error_reason() ::
    invalid_media | invalid_audio_data | invalid_sample_rate |
    invalid_channels | audio_chunk_too_large | invalid_video_frame |
    video_frame_too_large | unsupported_media_type | invalid_base64.

-export_type([media/0, error_reason/0]).

-spec audio_pcm(binary(), pos_integer(), pos_integer()) ->
    {ok, media()} | {error, error_reason()}.
audio_pcm(Data, SampleRate, Channels)
  when is_binary(Data), is_integer(SampleRate), is_integer(Channels) ->
    Media = #{schema_version => ?SCHEMA_VERSION,
              kind => audio,
              format => pcm_s16le,
              data => Data,
              sample_rate => SampleRate,
              channels => Channels},
    case validate(Media) of
        ok -> {ok, Media};
        {error, _} = Error -> Error
    end;
audio_pcm(_Data, _SampleRate, _Channels) ->
    {error, invalid_media}.

-spec video_frame(jpeg | png, binary()) ->
    {ok, media()} | {error, error_reason()}.
video_frame(Format, Data)
  when (Format =:= jpeg orelse Format =:= png), is_binary(Data) ->
    Media = #{schema_version => ?SCHEMA_VERSION,
              kind => video,
              format => Format,
              data => Data},
    case validate(Media) of
        ok -> {ok, Media};
        {error, _} = Error -> Error
    end;
video_frame(_Format, _Data) ->
    {error, invalid_media}.

-spec validate(term()) -> ok | {error, error_reason()}.
validate(#{schema_version := ?SCHEMA_VERSION,
           kind := audio,
           format := pcm_s16le,
           data := Data,
           sample_rate := SampleRate,
           channels := Channels} = Media) ->
    case exact_keys(Media, [schema_version, kind, format, data,
                            sample_rate, channels]) of
        false -> {error, invalid_media};
        true -> validate_audio(Data, SampleRate, Channels)
    end;
validate(#{schema_version := ?SCHEMA_VERSION,
           kind := video,
           format := Format,
           data := Data} = Media)
  when Format =:= jpeg; Format =:= png ->
    case exact_keys(Media, [schema_version, kind, format, data]) of
        false -> {error, invalid_media};
        true -> validate_video(Data)
    end;
validate(_Media) ->
    {error, invalid_media}.

-spec bytes(media()) -> non_neg_integer().
bytes(#{data := Data}) when is_binary(Data) ->
    byte_size(Data).

%% @doc Convert a checked media value to the Gemini Live Blob JSON shape.
-spec to_gemini_blob(media()) -> {ok, map()} | {error, error_reason()}.
to_gemini_blob(Media) ->
    case validate(Media) of
        ok ->
            {ok, #{<<"mimeType">> => mime_type(Media),
                   <<"data">> => base64:encode(maps:get(data, Media))}};
        {error, _} = Error -> Error
    end.

%% @doc Decode a Gemini Live Blob without retaining its base64 representation.
-spec from_gemini_blob(binary(), binary()) ->
    {ok, media()} | {error, error_reason()}.
from_gemini_blob(MimeType, Encoded)
  when is_binary(MimeType), is_binary(Encoded) ->
    case decode_base64(Encoded) of
        {ok, Data} -> media_from_mime(MimeType, Data);
        error -> {error, invalid_base64}
    end;
from_gemini_blob(_MimeType, _Encoded) ->
    {error, invalid_media}.

validate_audio(Data, _SampleRate, _Channels) when not is_binary(Data) ->
    {error, invalid_audio_data};
validate_audio(<<>>, _SampleRate, _Channels) ->
    {error, invalid_audio_data};
validate_audio(Data, _SampleRate, _Channels)
  when byte_size(Data) > ?MAX_AUDIO_CHUNK_BYTES ->
    {error, audio_chunk_too_large};
validate_audio(_Data, SampleRate, _Channels)
  when not is_integer(SampleRate); SampleRate < 8000; SampleRate > 48000 ->
    {error, invalid_sample_rate};
validate_audio(_Data, _SampleRate, Channels)
  when not is_integer(Channels); Channels < 1; Channels > 2 ->
    {error, invalid_channels};
validate_audio(Data, _SampleRate, Channels) ->
    case byte_size(Data) rem (2 * Channels) of
        0 -> ok;
        _ -> {error, invalid_audio_data}
    end.

validate_video(Data) when not is_binary(Data); Data =:= <<>> ->
    {error, invalid_video_frame};
validate_video(Data) when byte_size(Data) > ?MAX_VIDEO_FRAME_BYTES ->
    {error, video_frame_too_large};
validate_video(_Data) ->
    ok.

mime_type(#{kind := audio, sample_rate := Rate}) ->
    <<"audio/pcm;rate=", (integer_to_binary(Rate))/binary>>;
mime_type(#{kind := video, format := jpeg}) ->
    <<"image/jpeg">>;
mime_type(#{kind := video, format := png}) ->
    <<"image/png">>.

media_from_mime(<<"image/jpeg">>, Data) ->
    video_frame(jpeg, Data);
media_from_mime(<<"image/png">>, Data) ->
    video_frame(png, Data);
media_from_mime(MimeType, Data) ->
    case MimeType of
        <<"audio/pcm;rate=", RateBinary/binary>> ->
            case positive_integer(RateBinary) of
                {ok, Rate} -> audio_pcm(Data, Rate, 1);
                error -> {error, unsupported_media_type}
            end;
        _ ->
            {error, unsupported_media_type}
    end.

positive_integer(<<>>) -> error;
positive_integer(Binary) ->
    try binary_to_integer(Binary) of
        Value when Value > 0 -> {ok, Value};
        _ -> error
    catch
        _:_ -> error
    end.

decode_base64(Encoded) ->
    %% Reject non-canonical encodings.  This both bounds ambiguity and catches
    %% whitespace-tolerant decoders at the untrusted provider boundary.
    try base64:decode(Encoded) of
        Data ->
            case base64:encode(Data) =:= Encoded of
                true -> {ok, Data};
                false -> error
            end
    catch
        _:_ -> error
    end.

exact_keys(Map, Keys) ->
    lists:sort(maps:keys(Map)) =:= lists:sort(Keys).
