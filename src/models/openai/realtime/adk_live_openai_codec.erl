%% @doc Strict codec for the OpenAI Realtime WebSocket event protocol.
-module(adk_live_openai_codec).

-export([setup_frame/1, encode_client/2, decode_server/2]).

-define(MAX_CLIENT_TEXT_BYTES, 65536).
-define(MAX_SERVER_FRAME_BYTES, 8388608).
-define(MAX_TRANSCRIPT_BYTES, 1048576).
-define(MAX_ARGUMENT_BYTES, 1048576).
-define(MAX_ID_BYTES, 256).
-define(MAX_RATE_LIMITS, 64).

-spec setup_frame(map()) -> {ok, binary()} | {error, term()}.
setup_frame(Config0) ->
    case adk_live_openai:validate_config(Config0) of
        {ok, Config} ->
            encode_json(#{<<"type">> => <<"session.update">>,
                          <<"session">> => build_session(Config)});
        {error, _} = Error -> Error
    end.

-spec encode_client(adk_live_provider:client_action(), map()) ->
    {ok, binary() | [binary(), ...]} | ignored | {error, term()}.
encode_client(Action, Config0) ->
    case adk_live_openai:validate_config(Config0) of
        {ok, Config} -> encode_checked_client(Action, Config);
        {error, _} = Error -> Error
    end.

-spec decode_server(binary(), map()) ->
    {ok, [adk_live_provider:event_spec()]} | {error, term()}.
decode_server(Frame, Config0)
  when is_binary(Frame), byte_size(Frame) > 0,
       byte_size(Frame) =< ?MAX_SERVER_FRAME_BYTES ->
    case adk_live_openai:validate_config(Config0) of
        {ok, Config} ->
            case decode_json(Frame) of
                {ok, Map} when is_map(Map) -> decode_server_map(Map, Config);
                {ok, _} -> protocol_error([], expected_object);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
decode_server(Frame, _Config) when is_binary(Frame) ->
    protocol_error([], invalid_frame_size);
decode_server(_Frame, _Config) ->
    protocol_error([], expected_binary_frame).

build_session(Config) ->
    Modalities = [atom_to_binary(Value, utf8)
                  || Value <- maps:get(response_modalities, Config)],
    Input0 = #{<<"format">> =>
                   #{<<"type">> => <<"audio/pcm">>, <<"rate">> => 24000}},
    Input1 = maybe_input_transcription(Input0, Config),
    Input = maybe_turn_detection(Input1, Config),
    Audio0 = #{<<"input">> => Input},
    Audio = case maps:get(response_modalities, Config) of
        [audio] ->
            Audio0#{<<"output">> =>
                        #{<<"format">> => #{<<"type">> => <<"audio/pcm">>},
                          <<"voice">> => maps:get(voice_name, Config)}};
        [text] -> Audio0
    end,
    Session0 = #{<<"type">> => <<"realtime">>,
                 <<"model">> => maps:get(model, Config),
                 <<"output_modalities">> => Modalities,
                 <<"audio">> => Audio},
    Session1 = maybe_put(<<"instructions">>, system_instruction,
                         Config, Session0),
    case maps:get(tools, Config, []) of
        [] -> Session1;
        Tools -> Session1#{<<"tools">> => [encode_tool(T) || T <- Tools],
                           <<"tool_choice">> => <<"auto">>}
    end.

maybe_input_transcription(Input, Config) ->
    case maps:get(input_audio_transcription, Config, false) of
        false -> Input;
        Model -> Input#{<<"transcription">> => #{<<"model">> => Model}}
    end.

maybe_turn_detection(Input, Config) ->
    case maps:get(turn_detection, Config) of
        disabled -> Input#{<<"turn_detection">> => null};
        semantic_vad ->
            Input#{<<"turn_detection">> => #{<<"type">> => <<"semantic_vad">>}};
        server_vad ->
            Input#{<<"turn_detection">> => #{<<"type">> => <<"server_vad">>}}
    end.

encode_tool(Tool) ->
    Base = #{<<"type">> => <<"function">>,
             <<"name">> => maps:get(name, Tool),
             <<"parameters">> => json_value(maps:get(parameters, Tool))},
    case maps:get(description, Tool, <<>>) of
        <<>> -> Base;
        Description -> Base#{<<"description">> => Description}
    end.

encode_checked_client({text, Text}, _Config)
  when is_binary(Text), byte_size(Text) > 0,
       byte_size(Text) =< ?MAX_CLIENT_TEXT_BYTES ->
    case valid_utf8(Text) of
        true -> encode_frames([
            #{<<"type">> => <<"conversation.item.create">>,
              <<"item">> =>
                  #{<<"type">> => <<"message">>, <<"role">> => <<"user">>,
                    <<"content">> =>
                        [#{<<"type">> => <<"input_text">>,
                           <<"text">> => Text}]}},
            #{<<"type">> => <<"response.create">>}
        ]);
        false -> protocol_error([conversation, text], invalid_text)
    end;
encode_checked_client({text, _Text}, _Config) ->
    protocol_error([conversation, text], invalid_text);
encode_checked_client({audio, Media}, _Config) ->
    encode_audio(Media);
encode_checked_client({video_frame, Media}, _Config) ->
    encode_image(Media);
encode_checked_client(activity_start, #{turn_detection := disabled}) ->
    encode_json(#{<<"type">> => <<"input_audio_buffer.clear">>});
%% The browser emits this lifecycle marker whenever capture stops. Realtime
%% server VAD owns commits in automatic mode, while activity_end performs the
%% explicit commit in manual mode. Treating audio_stream_end as a second
%% commit would create an empty duplicate response.
encode_checked_client(audio_stream_end, _Config) ->
    ignored;
encode_checked_client(activity_end, #{turn_detection := disabled}) ->
    encode_frames([#{<<"type">> => <<"input_audio_buffer.commit">>},
                   #{<<"type">> => <<"response.create">>}]);
encode_checked_client(Action, _Config)
  when Action =:= activity_start; Action =:= activity_end ->
    protocol_error([input_audio_buffer, Action],
                   automatic_vad_owns_audio_commit);
encode_checked_client({tool_response, Id, Name, Response}, _Config)
  when is_binary(Id), is_binary(Name), is_map(Response) ->
    case valid_identifier(Id) andalso valid_identifier(Name) of
        false -> protocol_error([tool_response], invalid_identifier);
        true ->
            case adk_json:normalize(Response) of
                {ok, Normalized} when is_map(Normalized) ->
                    try jsx:encode(Normalized) of
                        Output when byte_size(Output) =< ?MAX_ARGUMENT_BYTES ->
                            encode_frames([
                              #{<<"type">> => <<"conversation.item.create">>,
                                <<"item">> =>
                                    #{<<"type">> => <<"function_call_output">>,
                                      <<"call_id">> => Id,
                                      <<"output">> => Output}},
                              #{<<"type">> => <<"response.create">>}
                            ]);
                        _ -> protocol_error([tool_response, response],
                                            response_too_large)
                    catch
                        _:_ -> protocol_error([tool_response, response],
                                              invalid_json)
                    end;
                _ -> protocol_error([tool_response, response], invalid_json)
            end
    end;
encode_checked_client({tool_response, _Id, _Name, _Response}, _Config) ->
    protocol_error([tool_response], invalid_response);
encode_checked_client(_Action, _Config) ->
    protocol_error([], unsupported_client_action).

encode_audio(Media) ->
    case adk_live_media:validate(Media) of
        ok ->
            case Media of
                #{kind := audio, format := pcm_s16le,
                  sample_rate := 24000, channels := 1, data := Data} ->
                    encode_json(#{<<"type">> => <<"input_audio_buffer.append">>,
                                  <<"audio">> => base64:encode(Data)});
                #{kind := audio} ->
                    protocol_error([input_audio_buffer, audio],
                                   input_audio_must_be_24khz_mono);
                _ -> protocol_error([input_audio_buffer, audio],
                                    wrong_media_kind)
            end;
        {error, Reason} -> protocol_error([input_audio_buffer, audio], Reason)
    end.

encode_image(Media) ->
    case adk_live_media:validate(Media) of
        ok ->
            case Media of
                #{kind := video, format := Format, data := Data} ->
                    Mime = case Format of
                        jpeg -> <<"image/jpeg">>;
                        png -> <<"image/png">>
                    end,
                    Url = <<"data:", Mime/binary, ";base64,",
                            (base64:encode(Data))/binary>>,
                    encode_frames([
                      #{<<"type">> => <<"conversation.item.create">>,
                        <<"item">> =>
                            #{<<"type">> => <<"message">>,
                              <<"role">> => <<"user">>,
                              <<"content">> =>
                                  [#{<<"type">> => <<"input_image">>,
                                     <<"image_url">> => Url}]}},
                      #{<<"type">> => <<"response.create">>}
                    ]);
                _ -> protocol_error([conversation, image], wrong_media_kind)
            end;
        {error, Reason} -> protocol_error([conversation, image], Reason)
    end.

decode_server_map(#{<<"type">> := Type} = Map, Config)
  when is_binary(Type), byte_size(Type) =< 128 ->
    decode_event(Type, Map, Config);
decode_server_map(#{<<"type">> := _}, _Config) ->
    protocol_error([type], invalid_event_type);
decode_server_map(_Map, _Config) ->
    protocol_error([type], missing_event_type).

decode_event(<<"session.created">>, _Map, _Config) -> {ok, []};
decode_event(<<"session.updated">>, _Map, _Config) ->
    {ok, [#{kind => setup_complete, payload => #{}}]};
decode_event(<<"response.output_audio.delta">>, Map, _Config) ->
    decode_audio_delta(Map);
decode_event(<<"response.output_audio_transcript.delta">>, Map, Config) ->
    decode_transcription(output_transcription, Map, <<"delta">>, false,
                         maps:get(output_audio_transcription, Config));
decode_event(<<"response.output_audio_transcript.done">>, Map, Config) ->
    decode_transcription(output_transcription, Map, <<"transcript">>, true,
                         maps:get(output_audio_transcription, Config));
decode_event(<<"conversation.item.input_audio_transcription.delta">>,
             Map, Config) ->
    decode_transcription(input_transcription, Map, <<"delta">>, false,
                         maps:get(input_audio_transcription, Config) =/= false);
decode_event(<<"conversation.item.input_audio_transcription.completed">>,
             Map, Config) ->
    decode_transcription(input_transcription, Map, <<"transcript">>, true,
                         maps:get(input_audio_transcription, Config) =/= false);
decode_event(<<"response.output_text.delta">>, Map, _Config) ->
    case bounded_text(maps:get(<<"delta">>, Map, undefined),
                      ?MAX_TRANSCRIPT_BYTES) of
        {ok, Text} ->
            {ok, [#{kind => content,
                    payload => #{part => #{text => Text,
                                           thought => false}}}]};
        error -> protocol_error([delta], invalid_text_delta)
    end;
decode_event(<<"response.function_call_arguments.done">>, Map, _Config) ->
    decode_tool_call(Map);
decode_event(<<"input_audio_buffer.speech_started">>, _Map, _Config) ->
    {ok, [#{kind => interrupted,
            payload => #{reason => <<"input_speech_started">>}}]};
decode_event(<<"response.done">>, Map, _Config) ->
    decode_response_done(Map);
decode_event(<<"rate_limits.updated">>, Map, _Config) ->
    decode_rate_limits(Map);
decode_event(<<"error">>, Map, _Config) ->
    {ok, [#{kind => error, payload => safe_provider_error(Map)}]};
%% These events are either lifecycle detail already represented by a later
%% terminal event, or forward-compatible metadata that the neutral API does
%% not expose.
decode_event(_KnownOrFuture, _Map, _Config) -> {ok, []}.

decode_audio_delta(Map) ->
    case maps:get(<<"delta">>, Map, undefined) of
        Encoded when is_binary(Encoded), byte_size(Encoded) > 0 ->
            case canonical_base64(Encoded) of
                {ok, Data} ->
                    case adk_live_media:audio_pcm(Data, 24000, 1) of
                        {ok, Media} ->
                            {ok, [#{kind => audio, payload => Media}]};
                        {error, Reason} ->
                            protocol_error([delta], Reason)
                    end;
                error -> protocol_error([delta], invalid_base64)
            end;
        _ -> protocol_error([delta], invalid_audio_delta)
    end.

decode_transcription(_Kind, _Map, _Key, _Final, false) -> {ok, []};
decode_transcription(Kind, Map, Key, Final, true) ->
    case bounded_text(maps:get(Key, Map, undefined), ?MAX_TRANSCRIPT_BYTES) of
        {ok, Text} ->
            {ok, [#{kind => Kind,
                    payload => #{text => Text, final => Final}}]};
        error -> protocol_error([Key], invalid_transcription)
    end.

decode_tool_call(Map) ->
    Id = maps:get(<<"call_id">>, Map, undefined),
    Name = maps:get(<<"name">>, Map, undefined),
    Arguments = maps:get(<<"arguments">>, Map, undefined),
    case valid_identifier(Id) andalso valid_identifier(Name)
         andalso is_binary(Arguments)
         andalso byte_size(Arguments) =< ?MAX_ARGUMENT_BYTES of
        false -> protocol_error([function_call], invalid_function_call);
        true ->
            case decode_json(Arguments) of
                {ok, Args} when is_map(Args) ->
                    {ok, [#{kind => tool_call,
                            payload => #{id => Id, name => Name,
                                         args => Args}}]};
                _ -> protocol_error([arguments], invalid_function_arguments)
            end
    end.

decode_response_done(Map) ->
    Response = maps:get(<<"response">>, Map, #{}),
    case Response of
        #{<<"status">> := <<"completed">>} ->
            UsageEvents = response_usage(Response),
            {ok, [#{kind => generation_complete, payload => #{}},
                  #{kind => turn_complete,
                    payload => #{status => <<"completed">>}}]
                 ++ UsageEvents};
        #{<<"status">> := Status}
          when Status =:= <<"cancelled">>; Status =:= <<"incomplete">> ->
            {ok, [#{kind => interrupted, payload => #{reason => Status}}]};
        #{<<"status">> := <<"failed">>} ->
            {ok, [#{kind => error,
                    payload => safe_response_error(Response)}]};
        _ -> protocol_error([response, status], invalid_response_status)
    end.

response_usage(Response) ->
    case maps:get(<<"usage">>, Response, undefined) of
        Usage when is_map(Usage) ->
            case normalize_usage(Usage) of
                {ok, Normalized} -> [#{kind => usage, payload => Normalized}];
                error -> []
            end;
        _ -> []
    end.

normalize_usage(Usage) ->
    Allowed = [{<<"input_tokens">>, input_tokens},
               {<<"output_tokens">>, output_tokens},
               {<<"total_tokens">>, total_tokens}],
    Pairs = [{Atom, Value} || {Wire, Atom} <- Allowed,
                              (Value = maps:get(Wire, Usage, undefined)) =/= undefined,
                              is_integer(Value), Value >= 0],
    case Pairs of
        [] -> error;
        _ -> {ok, maps:from_list(Pairs)}
    end.

decode_rate_limits(Map) ->
    Limits = maps:get(<<"rate_limits">>, Map, undefined),
    case is_list(Limits) andalso length(Limits) =< ?MAX_RATE_LIMITS of
        true ->
            case normalize_rate_limits(Limits, []) of
                {ok, Normalized} ->
                    {ok, [#{kind => usage,
                            payload => #{rate_limits => Normalized}}]};
                error -> protocol_error([rate_limits], invalid_rate_limits)
            end;
        false -> protocol_error([rate_limits], invalid_rate_limits)
    end.

normalize_rate_limits([], Acc) -> {ok, lists:reverse(Acc)};
normalize_rate_limits([Limit | Rest], Acc) when is_map(Limit) ->
    Name = maps:get(<<"name">>, Limit, undefined),
    Maximum = maps:get(<<"limit">>, Limit, undefined),
    Remaining = maps:get(<<"remaining">>, Limit, undefined),
    Reset = maps:get(<<"reset_seconds">>, Limit, undefined),
    case valid_identifier(Name) andalso number_nonnegative(Maximum)
         andalso number_nonnegative(Remaining)
         andalso number_nonnegative(Reset) of
        true ->
            normalize_rate_limits(
              Rest, [#{name => Name, limit => Maximum,
                       remaining => Remaining, reset_seconds => Reset} | Acc]);
        false -> error
    end;
normalize_rate_limits(_Limits, _Acc) -> error.

safe_provider_error(Map) ->
    Error = maps:get(<<"error">>, Map, #{}),
    safe_error_payload(Error, <<"provider_error">>).

safe_response_error(Response) ->
    Error = maps:get(<<"status_details">>, Response, #{}),
    safe_error_payload(Error, <<"response_failed">>).

safe_error_payload(Error, Reason) when is_map(Error) ->
    Base = #{reason => Reason},
    Base1 = safe_optional_error_field(<<"type">>, type, Error, Base),
    safe_optional_error_field(<<"code">>, code, Error, Base1);
safe_error_payload(_Error, Reason) -> #{reason => Reason}.

safe_optional_error_field(Wire, Key, Source, Acc) ->
    case maps:get(Wire, Source, undefined) of
        Value when is_binary(Value), byte_size(Value) > 0,
                   byte_size(Value) =< 128 -> Acc#{Key => Value};
        _ -> Acc
    end.

encode_frames(Maps) ->
    case encode_frames(Maps, []) of
        {ok, Frames} -> {ok, lists:reverse(Frames)};
        {error, _} = Error -> Error
    end.

encode_frames([], Acc) -> {ok, Acc};
encode_frames([Map | Rest], Acc) ->
    case encode_json(Map) of
        {ok, Frame} -> encode_frames(Rest, [Frame | Acc]);
        {error, _} = Error -> Error
    end.

encode_json(Map) ->
    try jsx:encode(Map) of
        Binary when is_binary(Binary) -> {ok, Binary}
    catch
        _:_ -> protocol_error([], json_encoding_failed)
    end.

decode_json(Binary) ->
    try jsx:decode(Binary, [return_maps]) of
        Value -> {ok, Value}
    catch
        _:_ -> protocol_error([], invalid_json)
    end.

json_value(Value) ->
    case adk_json:normalize(Value) of
        {ok, Normalized} -> Normalized
    end.

maybe_put(WireKey, ConfigKey, Config, Target) ->
    case maps:find(ConfigKey, Config) of
        {ok, Value} -> Target#{WireKey => Value};
        error -> Target
    end.

canonical_base64(Encoded) ->
    try base64:decode(Encoded) of
        Data ->
            case base64:encode(Data) =:= Encoded of
                true -> {ok, Data};
                false -> error
            end
    catch
        _:_ -> error
    end.

bounded_text(Value, Maximum)
  when is_binary(Value), byte_size(Value) > 0,
       byte_size(Value) =< Maximum ->
    case valid_utf8(Value) of
        true -> {ok, Value};
        false -> error
    end;
bounded_text(_Value, _Maximum) -> error.

valid_identifier(Value) when is_binary(Value), byte_size(Value) > 0,
                             byte_size(Value) =< ?MAX_ID_BYTES ->
    valid_utf8(Value) andalso
    not lists:any(fun(Char) -> Char < 32 orelse Char =:= 127 end,
                  unicode:characters_to_list(Value));
valid_identifier(_Value) -> false.

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch
        _:_ -> false
    end.

number_nonnegative(Value) when is_integer(Value), Value >= 0 -> true;
number_nonnegative(Value) when is_float(Value), Value >= 0 -> true;
number_nonnegative(_Value) -> false.

protocol_error(Path, Detail) ->
    {error, {live_protocol_error, Path, Detail}}.
