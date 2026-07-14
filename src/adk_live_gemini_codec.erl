%% @doc Strict JSON codec for the Gemini 3.1 Flash Live WebSocket protocol.
-module(adk_live_gemini_codec).

-export([setup_frame/1, resume_setup_frame/2,
         encode_client/2, decode_server/2]).

-define(MAX_CLIENT_TEXT_BYTES, 65536).
-define(MAX_SERVER_FRAME_BYTES, 8388608).
-define(MAX_SERVER_PARTS, 128).
-define(MAX_TOOL_CALLS, 128).
-define(MAX_RESUMPTION_HANDLE_BYTES, 65536).

-spec setup_frame(map()) -> {ok, binary()} | {error, term()}.
setup_frame(Config0) ->
    case adk_live_gemini:validate_config(Config0) of
        {ok, Config} ->
            Setup = build_setup(Config),
            encode_json(#{<<"setup">> => Setup});
        {error, _} = Error -> Error
    end.

-spec resume_setup_frame(map(), binary()) ->
    {ok, binary()} | {error, term()}.
resume_setup_frame(Config0, Handle)
  when is_binary(Handle), byte_size(Handle) > 0,
       byte_size(Handle) =< ?MAX_RESUMPTION_HANDLE_BYTES ->
    case adk_live_gemini:validate_config(Config0) of
        {ok, #{session_resumption := true} = Config} ->
            Setup0 = build_setup(Config),
            Setup = Setup0#{<<"sessionResumption">> =>
                                #{<<"handle">> => Handle}},
            encode_json(#{<<"setup">> => Setup});
        {ok, _} ->
            protocol_error([setup, session_resumption], not_enabled);
        {error, _} = Error -> Error
    end;
resume_setup_frame(_Config, _Handle) ->
    protocol_error([setup, session_resumption], invalid_handle).

-spec encode_client(adk_live_provider:client_action(), map()) ->
    {ok, binary()} | {error, term()}.
encode_client(Action, Config0) ->
    case adk_live_gemini:validate_config(Config0) of
        {ok, Config} -> encode_checked_client(Action, Config);
        {error, _} = Error -> Error
    end.

-spec decode_server(binary(), map()) ->
    {ok, [adk_live_provider:event_spec()]} | {error, term()}.
decode_server(Frame, _Config)
  when is_binary(Frame), byte_size(Frame) > 0,
       byte_size(Frame) =< ?MAX_SERVER_FRAME_BYTES ->
    case decode_json(Frame) of
        {ok, Map} when is_map(Map) -> decode_server_map(Map);
        {ok, _} -> protocol_error([], expected_object);
        {error, _} = Error -> Error
    end;
decode_server(Frame, _Config) when is_binary(Frame) ->
    protocol_error([], invalid_frame_size);
decode_server(_Frame, _Config) ->
    protocol_error([], expected_binary_frame).

build_setup(Config) ->
    Model = maps:get(model, Config),
    Generation0 = #{<<"responseModalities">> => [<<"AUDIO">>]},
    Generation1 = maybe_voice(Generation0, Config),
    Generation2 = maybe_thinking(Generation1, Config),
    Generation = maybe_media_resolution(Generation2, Config),
    Setup0 = #{<<"model">> => <<"models/", Model/binary>>,
               <<"generationConfig">> => Generation},
    Setup1 = maybe_system_instruction(Setup0, Config),
    Setup2 = maybe_transcription(<<"inputAudioTranscription">>,
                                 input_audio_transcription,
                                 Setup1, Config),
    Setup3 = maybe_transcription(<<"outputAudioTranscription">>,
                                 output_audio_transcription,
                                 Setup2, Config),
    Setup4 = maybe_manual_vad(Setup3, Config),
    Setup5 = maybe_tools(Setup4, Config),
    Setup6 = case maps:get(session_resumption, Config, false) of
        true -> Setup5#{<<"sessionResumption">> => #{}};
        false -> Setup5
    end,
    case maps:get(context_window_compression, Config, false) of
        true -> Setup6#{<<"contextWindowCompression">> =>
                            #{<<"slidingWindow">> => #{}}};
        false -> Setup6
    end.

maybe_voice(Generation, Config) ->
    case maps:find(voice_name, Config) of
        {ok, Voice} ->
            Generation#{
              <<"speechConfig">> =>
                  #{<<"voiceConfig">> =>
                        #{<<"prebuiltVoiceConfig">> =>
                              #{<<"voiceName">> => Voice}}}};
        error -> Generation
    end.

maybe_thinking(Generation, Config) ->
    case maps:find(thinking_config, Config) of
        {ok, Thinking} ->
            Encoded0 = #{},
            Encoded1 = case maps:find(thinking_level, Thinking) of
                {ok, Level} ->
                    Encoded0#{<<"thinkingLevel">> => enum(Level)};
                error -> Encoded0
            end,
            Encoded = case maps:find(include_thoughts, Thinking) of
                {ok, Include} ->
                    Encoded1#{<<"includeThoughts">> => Include};
                error -> Encoded1
            end,
            Generation#{<<"thinkingConfig">> => Encoded};
        error -> Generation
    end.

maybe_media_resolution(Generation, Config) ->
    case maps:find(media_resolution, Config) of
        {ok, Resolution} ->
            Generation#{<<"mediaResolution">> =>
                            <<"MEDIA_RESOLUTION_", (enum(Resolution))/binary>>};
        error -> Generation
    end.

maybe_system_instruction(Setup, Config) ->
    case maps:find(system_instruction, Config) of
        {ok, Text} ->
            Setup#{<<"systemInstruction">> =>
                       #{<<"parts">> => [#{<<"text">> => Text}]}};
        error -> Setup
    end.

maybe_transcription(WireKey, ConfigKey, Setup, Config) ->
    case maps:get(ConfigKey, Config, false) of
        true -> Setup#{WireKey => #{}};
        false -> Setup
    end.

maybe_manual_vad(Setup, Config) ->
    case maps:get(automatic_activity_detection, Config, true) of
        true -> Setup;
        false ->
            Setup#{<<"realtimeInputConfig">> =>
                       #{<<"automaticActivityDetection">> =>
                             #{<<"disabled">> => true}}}
    end.

maybe_tools(Setup, Config) ->
    Tools = maps:get(tools, Config, []),
    case encode_tools(Tools) of
        [] -> Setup;
        Encoded -> Setup#{<<"tools">> => Encoded}
    end.

encode_tools(Tools) ->
    Search = [#{<<"googleSearch">> => #{}}
              || #{type := google_search} <- Tools],
    Functions = [encode_function_declaration(Tool)
                 || #{type := function} = Tool <- Tools],
    case Functions of
        [] -> Search;
        _ -> Search ++ [#{<<"functionDeclarations">> => Functions}]
    end.

encode_function_declaration(Tool) ->
    Base = #{<<"name">> => maps:get(name, Tool),
             <<"parameters">> => json_value(maps:get(parameters, Tool))},
    case maps:get(description, Tool, <<>>) of
        <<>> -> Base;
        Description -> Base#{<<"description">> => Description}
    end.

encode_checked_client({text, Text}, _Config)
  when is_binary(Text), byte_size(Text) > 0,
       byte_size(Text) =< ?MAX_CLIENT_TEXT_BYTES ->
    encode_json(#{<<"realtimeInput">> => #{<<"text">> => Text}});
encode_checked_client({text, _Text}, _Config) ->
    protocol_error([realtime_input, text], invalid_text);
encode_checked_client({audio, Media}, _Config) ->
    encode_media(audio, Media);
encode_checked_client({video_frame, Media}, _Config) ->
    encode_media(video, Media);
encode_checked_client(activity_start, Config) ->
    case maps:get(automatic_activity_detection, Config) of
        false -> encode_json(#{<<"realtimeInput">> =>
                                   #{<<"activityStart">> => #{}}});
        true -> protocol_error([realtime_input, activity_start],
                               automatic_vad_enabled)
    end;
encode_checked_client(activity_end, Config) ->
    case maps:get(automatic_activity_detection, Config) of
        false -> encode_json(#{<<"realtimeInput">> =>
                                   #{<<"activityEnd">> => #{}}});
        true -> protocol_error([realtime_input, activity_end],
                               automatic_vad_enabled)
    end;
encode_checked_client(audio_stream_end, Config) ->
    case maps:get(automatic_activity_detection, Config) of
        true -> encode_json(#{<<"realtimeInput">> =>
                                  #{<<"audioStreamEnd">> => true}});
        false -> protocol_error([realtime_input, audio_stream_end],
                                manual_vad_enabled)
    end;
encode_checked_client({tool_response, Id, Name, Response}, _Config)
  when is_binary(Id), is_binary(Name), is_map(Response),
       byte_size(Id) > 0, byte_size(Name) > 0 ->
    case adk_json:normalize(Response) of
        {ok, Checked} when is_map(Checked) ->
            encode_json(
              #{<<"toolResponse">> =>
                    #{<<"functionResponses">> =>
                          [#{<<"id">> => Id, <<"name">> => Name,
                             <<"response">> => Checked}]}});
        _ -> protocol_error([tool_response, response], invalid_json)
    end;
encode_checked_client({tool_response, _Id, _Name, _Response}, _Config) ->
    protocol_error([tool_response], invalid_response);
encode_checked_client(_Action, _Config) ->
    protocol_error([], unsupported_client_action).

encode_media(ExpectedKind, Media) ->
    case adk_live_media:validate(Media) of
        ok ->
            case maps:get(kind, Media) of
                ExpectedKind ->
                    case validate_gemini_input_media(ExpectedKind, Media) of
                        ok ->
                            {ok, Blob} = adk_live_media:to_gemini_blob(Media),
                            WireKey = case ExpectedKind of
                                audio -> <<"audio">>;
                                video -> <<"video">>
                            end,
                            encode_json(#{<<"realtimeInput">> =>
                                              #{WireKey => Blob}});
                        {error, _} = Error -> Error
                    end;
                _ ->
                    protocol_error([realtime_input, media], wrong_media_kind)
            end;
        {error, Reason} -> protocol_error([realtime_input, media], Reason)
    end.

validate_gemini_input_media(
  audio, #{sample_rate := 16000, channels := 1}) -> ok;
validate_gemini_input_media(audio, _Media) ->
    protocol_error([realtime_input, audio],
                   input_audio_must_be_16khz_mono);
validate_gemini_input_media(video, _Media) -> ok.

decode_server_map(Map) ->
    case maps:take(<<"usageMetadata">>, Map) of
        {Usage, Message} when map_size(Message) > 0 ->
            case {decode_server_message(Message),
                  decode_json_event(usage, Usage, [usage_metadata])} of
                {{ok, Events}, {ok, UsageEvents}} ->
                    {ok, Events ++ UsageEvents};
                {{error, _} = Error, _} -> Error;
                {_, {error, _} = Error} -> Error
            end;
        {_, _Empty} ->
            protocol_error([], missing_server_message);
        error ->
            decode_server_message(Map)
    end.

decode_server_message(Map) ->
    case maps:to_list(Map) of
        [{<<"setupComplete">>, Value}] when is_map(Value), map_size(Value) =:= 0 ->
            {ok, [#{kind => setup_complete, payload => #{}}]};
        [{<<"serverContent">>, Value}] ->
            decode_server_content(Value);
        [{<<"toolCall">>, Value}] ->
            decode_tool_call(Value);
        [{<<"toolCallCancellation">>, Value}] ->
            decode_tool_cancellation(Value);
        [{<<"goAway">>, Value}] ->
            decode_go_away(Value);
        [{<<"sessionResumptionUpdate">>, Value}] ->
            decode_resumption_update(Value);
        [{Key, _Value}] ->
            protocol_error([Key], unsupported_server_message);
        _ ->
            protocol_error([], expected_single_server_message)
    end.

decode_server_content(Content) when is_map(Content) ->
    Allowed = [<<"modelTurn">>, <<"generationComplete">>,
               <<"turnComplete">>, <<"interrupted">>,
               <<"inputTranscription">>, <<"outputTranscription">>,
               <<"groundingMetadata">>, <<"urlContextMetadata">>],
    case maps:keys(Content) -- Allowed of
        [] -> decode_server_content_fields(Content);
        [Key | _] -> protocol_error([server_content, Key], unsupported_field)
    end;
decode_server_content(_Content) ->
    protocol_error([server_content], expected_object).

decode_server_content_fields(Content) ->
    Decoders = [
        fun() -> decode_optional_model_turn(Content) end,
        fun() -> decode_optional_transcription(
                   <<"inputTranscription">>, input_transcription, Content) end,
        fun() -> decode_optional_transcription(
                   <<"outputTranscription">>, output_transcription, Content) end,
        fun() -> decode_optional_json_event(
                   <<"groundingMetadata">>, grounding, Content) end,
        fun() -> decode_optional_json_event(
                   <<"urlContextMetadata">>, grounding, Content) end,
        fun() -> decode_optional_flag(
                   <<"generationComplete">>, generation_complete, Content) end,
        fun() -> decode_optional_flag(
                   <<"interrupted">>, interrupted, Content) end,
        fun() -> decode_optional_flag(
                   <<"turnComplete">>, turn_complete, Content) end
    ],
    case collect_decoders(Decoders, []) of
        %% Proto3 may serialize a valid server-content heartbeat/no-op as an
        %% empty object (or with all boolean fields false). It carries no
        %% application event but is still a consumed protocol frame.
        {ok, []} -> {ok, []};
        {ok, Events} -> {ok, Events};
        {error, _} = Error -> Error
    end.

decode_optional_model_turn(Content) ->
    case maps:find(<<"modelTurn">>, Content) of
        error -> {ok, []};
        {ok, Turn} -> decode_model_turn(Turn)
    end.

decode_model_turn(#{<<"parts">> := Parts} = Turn)
  when is_list(Parts), length(Parts) =< ?MAX_SERVER_PARTS ->
    case maps:keys(Turn) -- [<<"role">>, <<"parts">>] of
        [] -> decode_parts(Parts, 0, []);
        [Key | _] -> protocol_error([server_content, model_turn, Key],
                                    unsupported_field)
    end;
decode_model_turn(_Turn) ->
    protocol_error([server_content, model_turn], invalid_turn).

decode_parts([], _Index, Acc) -> {ok, lists:reverse(Acc)};
decode_parts([Part | Rest], Index, Acc) ->
    case decode_part(Part, Index) of
        {ok, Event} -> decode_parts(Rest, Index + 1, [Event | Acc]);
        {error, _} = Error -> Error
    end.

decode_part(Part, Index) when is_map(Part) ->
    Primary = [Key || Key <- [<<"text">>, <<"inlineData">>,
                               <<"functionCall">>, <<"functionResponse">>,
                               <<"fileData">>, <<"executableCode">>,
                               <<"codeExecutionResult">>],
                      maps:is_key(Key, Part)],
    decode_primary_part(Primary, Part, Index);
decode_part(_Part, Index) ->
    protocol_error([server_content, model_turn, parts, Index], expected_object).

decode_primary_part([<<"text">>], Part, Index) ->
    Allowed = [<<"text">>, <<"thought">>, <<"thoughtSignature">>],
    Text = maps:get(<<"text">>, Part),
    Thought = maps:get(<<"thought">>, Part, false),
    Signature = maps:get(<<"thoughtSignature">>, Part, undefined),
    case maps:keys(Part) -- Allowed of
        [] when is_binary(Text), is_boolean(Thought),
                (Signature =:= undefined orelse is_binary(Signature)) ->
            Payload0 = #{part => #{text => Text, thought => Thought}},
            Payload = case Signature of
                undefined -> Payload0;
                _ -> Payload0#{part :=
                                   (maps:get(part, Payload0))#{
                                      thought_signature => Signature}}
            end,
            {ok, #{kind => content, payload => Payload}};
        [] -> protocol_error(part_path(Index), invalid_text_part);
        [Key | _] -> protocol_error(part_path(Index) ++ [Key],
                                    unsupported_field)
    end;
decode_primary_part([<<"inlineData">>], Part, Index) ->
    case maps:keys(Part) of
        [<<"inlineData">>] -> decode_inline_data(
                                maps:get(<<"inlineData">>, Part), Index);
        _ -> protocol_error(part_path(Index), invalid_inline_data_part)
    end;
decode_primary_part([<<"functionCall">>], Part, Index) ->
    case maps:keys(Part) of
        [<<"functionCall">>] ->
            decode_function_call(maps:get(<<"functionCall">>, Part),
                                 part_path(Index));
        _ -> protocol_error(part_path(Index), invalid_function_call_part)
    end;
decode_primary_part([<<"functionResponse">>], Part, Index) ->
    case maps:keys(Part) of
        [<<"functionResponse">>] ->
            decode_function_response(
              maps:get(<<"functionResponse">>, Part), part_path(Index));
        _ -> protocol_error(part_path(Index), invalid_function_response_part)
    end;
decode_primary_part([Known], Part, _Index)
  when Known =:= <<"fileData">>; Known =:= <<"executableCode">>;
       Known =:= <<"codeExecutionResult">> ->
    case adk_json:normalize(Part) of
        {ok, Normalized} ->
            {ok, #{kind => content,
                   payload => #{part => Normalized}}};
        _ -> protocol_error([server_content, model_turn, parts], invalid_part)
    end;
decode_primary_part([], _Part, Index) ->
    protocol_error(part_path(Index), unsupported_part);
decode_primary_part(_Multiple, _Part, Index) ->
    protocol_error(part_path(Index), multiple_part_payloads).

decode_inline_data(#{<<"mimeType">> := MimeType,
                     <<"data">> := Data} = Blob, Index) ->
    case maps:keys(Blob) of
        [<<"data">>, <<"mimeType">>] ->
            case adk_live_media:from_gemini_blob(MimeType, Data) of
                {ok, #{kind := audio, sample_rate := 24000,
                       channels := 1} = Media} ->
                    {ok, #{kind => audio, payload => Media}};
                {ok, #{kind := audio}} ->
                    protocol_error(part_path(Index),
                                   output_audio_must_be_24khz_mono);
                {ok, _OtherMedia} ->
                    protocol_error(part_path(Index),
                                   non_audio_response_for_audio_model);
                {error, Reason} ->
                    protocol_error(part_path(Index), Reason)
            end;
        _ -> protocol_error(part_path(Index), invalid_inline_data)
    end;
decode_inline_data(_Blob, Index) ->
    protocol_error(part_path(Index), invalid_inline_data).

decode_tool_call(#{<<"functionCalls">> := Calls} = ToolCall)
  when is_list(Calls), Calls =/= [], length(Calls) =< ?MAX_TOOL_CALLS ->
    case maps:keys(ToolCall) of
        [<<"functionCalls">>] -> decode_function_calls(Calls, 0, []);
        _ -> protocol_error([tool_call], unsupported_field)
    end;
decode_tool_call(_ToolCall) ->
    protocol_error([tool_call], invalid_tool_call).

decode_function_calls([], _Index, Acc) -> {ok, lists:reverse(Acc)};
decode_function_calls([Call | Rest], Index, Acc) ->
    case decode_function_call(Call, [tool_call, function_calls, Index]) of
        {ok, Event} ->
            decode_function_calls(Rest, Index + 1, [Event | Acc]);
        {error, _} = Error -> Error
    end.

decode_function_call(#{<<"id">> := Id, <<"name">> := Name,
                       <<"args">> := Args} = Call, Path)
  when is_binary(Id), is_binary(Name), is_map(Args),
       byte_size(Id) > 0, byte_size(Name) > 0 ->
    case maps:keys(Call) of
        [<<"args">>, <<"id">>, <<"name">>] ->
            case adk_json:normalize(Args) of
                {ok, Checked} when is_map(Checked) ->
                    {ok, #{kind => tool_call,
                           payload => #{id => Id, name => Name,
                                        args => Checked}}};
                _ -> protocol_error(Path ++ [args], invalid_json)
            end;
        _ -> protocol_error(Path, synchronous_calls_only)
    end;
decode_function_call(_Call, Path) ->
    protocol_error(Path, invalid_function_call).

decode_function_response(#{<<"id">> := Id, <<"name">> := Name,
                           <<"response">> := Response} = Value, Path)
  when is_binary(Id), is_binary(Name), is_map(Response) ->
    case maps:keys(Value) of
        [<<"id">>, <<"name">>, <<"response">>] ->
            case adk_json:normalize(Response) of
                {ok, Checked} ->
                    {ok, #{kind => tool_response,
                           payload => #{id => Id, name => Name,
                                        response => Checked}}};
                _ -> protocol_error(Path ++ [response], invalid_json)
            end;
        _ -> protocol_error(Path, invalid_function_response)
    end;
decode_function_response(_Value, Path) ->
    protocol_error(Path, invalid_function_response).

decode_tool_cancellation(#{<<"ids">> := Ids} = Value)
  when is_list(Ids), Ids =/= [], length(Ids) =< ?MAX_TOOL_CALLS ->
    case maps:keys(Value) =:= [<<"ids">>]
         andalso lists:all(fun valid_id/1, Ids)
         andalso length(Ids) =:= length(lists:usort(Ids)) of
        true -> {ok, [#{kind => tool_cancelled,
                        payload => #{ids => Ids}}]};
        false -> protocol_error([tool_call_cancellation], invalid_ids)
    end;
decode_tool_cancellation(_Value) ->
    protocol_error([tool_call_cancellation], invalid_cancellation).

decode_go_away(#{<<"timeLeft">> := TimeLeft} = Value)
  when is_binary(TimeLeft), byte_size(TimeLeft) > 0,
       byte_size(TimeLeft) =< 64 ->
    case maps:keys(Value) of
        [<<"timeLeft">>] ->
            {ok, [#{kind => go_away,
                    payload => #{time_left => TimeLeft}}]};
        _ -> protocol_error([go_away], unsupported_field)
    end;
decode_go_away(_Value) ->
    protocol_error([go_away], invalid_go_away).

decode_resumption_update(#{<<"newHandle">> := Handle,
                           <<"resumable">> := Resumable} = Value)
  when is_binary(Handle),
       byte_size(Handle) =< ?MAX_RESUMPTION_HANDLE_BYTES,
       is_boolean(Resumable) ->
    case maps:keys(Value) of
        [<<"newHandle">>, <<"resumable">>]
          when (Resumable =:= true andalso byte_size(Handle) > 0)
               orelse (Resumable =:= false andalso Handle =:= <<>>) ->
            %% This internal event is intercepted by adk_live_session.  The
            %% opaque handle is never copied into a subscriber event/status.
            {ok, [#{kind => resumption_update,
                    payload => #{handle => Handle,
                                 resumable => Resumable}}]};
        [<<"newHandle">>, <<"resumable">>] ->
            protocol_error([session_resumption_update], invalid_handle);
        _ -> protocol_error([session_resumption_update], unsupported_field)
    end;
decode_resumption_update(_Value) ->
    protocol_error([session_resumption_update], invalid_update).

decode_optional_transcription(WireKey, Kind, Content) ->
    case maps:find(WireKey, Content) of
        error -> {ok, []};
        {ok, #{<<"text">> := Text} = Value} when is_binary(Text) ->
            Allowed = [<<"text">>, <<"finished">>],
            Final = maps:get(<<"finished">>, Value, false),
            case maps:keys(Value) -- Allowed of
                [] when is_boolean(Final) ->
                    {ok, [#{kind => Kind,
                            payload => #{text => Text, final => Final}}]};
                [] -> protocol_error([server_content, WireKey],
                                     invalid_finished);
                [Key | _] -> protocol_error([server_content, WireKey, Key],
                                            unsupported_field)
            end;
        {ok, _} -> protocol_error([server_content, WireKey],
                                  invalid_transcription)
    end.

decode_optional_json_event(WireKey, Kind, Content) ->
    case maps:find(WireKey, Content) of
        error -> {ok, []};
        {ok, Value} -> decode_json_event_list(Kind, Value,
                                              [server_content, WireKey])
    end.

decode_json_event(Kind, Value, Path) ->
    case decode_json_event_list(Kind, Value, Path) of
        {ok, Events} -> {ok, Events};
        {error, _} = Error -> Error
    end.

decode_json_event_list(Kind, Value, Path) when is_map(Value) ->
    case adk_json:normalize(Value) of
        {ok, Checked} when is_map(Checked) ->
            {ok, [#{kind => Kind, payload => Checked}]};
        _ -> protocol_error(Path, invalid_json)
    end;
decode_json_event_list(_Kind, _Value, Path) ->
    protocol_error(Path, expected_object).

decode_optional_flag(WireKey, Kind, Content) ->
    case maps:find(WireKey, Content) of
        error -> {ok, []};
        {ok, true} -> {ok, [#{kind => Kind, payload => #{}}]};
        {ok, false} -> {ok, []};
        {ok, _} -> protocol_error([server_content, WireKey],
                                  expected_boolean)
    end.

collect_decoders([], Acc) -> {ok, lists:append(lists:reverse(Acc))};
collect_decoders([Decoder | Rest], Acc) ->
    case Decoder() of
        {ok, Events} -> collect_decoders(Rest, [Events | Acc]);
        {error, _} = Error -> Error
    end.

encode_json(Map) ->
    try jsx:encode(Map) of
        Binary when is_binary(Binary) -> {ok, Binary}
    catch
        _:_ -> protocol_error([], json_encoding_failed)
    end.

decode_json(Frame) ->
    try jsx:decode(Frame, [return_maps]) of
        Value -> {ok, Value}
    catch
        _:_ -> protocol_error([], invalid_json)
    end.

json_value(Value) ->
    {ok, Normalized} = adk_json:normalize(Value),
    Normalized.

enum(Value) ->
    string:uppercase(atom_to_binary(Value, utf8)).

valid_id(Id) when is_binary(Id) ->
    byte_size(Id) > 0 andalso byte_size(Id) =< 256;
valid_id(_Id) -> false.

part_path(Index) ->
    [server_content, model_turn, parts, Index].

protocol_error(Path, Reason) ->
    {error, {live_protocol_error, Path, Reason}}.
