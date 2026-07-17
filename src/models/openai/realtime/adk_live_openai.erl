%% @doc OpenAI Realtime provider adapter.
%%
%% The adapter keeps OpenAI wire details out of the provider-neutral Live
%% session. It deliberately supports the GA Realtime WebSocket event model;
%% browser WebRTC negotiation remains a UI/server concern.
-module(adk_live_openai).
-behaviour(adk_live_provider).

-export([model/0, capabilities/0, validate_config/1, transport/0,
         setup_frame/1, encode_client/2, decode_server/2]).

-define(DEFAULT_MODEL, <<"gpt-realtime-2.1">>).
-define(DEFAULT_TRANSCRIPTION_MODEL, <<"gpt-4o-mini-transcribe">>).
-define(MAX_TEXT_BYTES, 65536).
-define(MAX_MODEL_BYTES, 512).
-define(MAX_TOOLS, 128).
-define(MAX_TOOL_SCHEMA_BYTES, 262144).

-spec model() -> binary().
model() -> ?DEFAULT_MODEL.

-spec transport() -> module().
transport() -> adk_live_openai_gun_transport.

-spec capabilities() -> map().
capabilities() ->
    #{live => true,
      model => ?DEFAULT_MODEL,
      input_modalities => [text, audio, image],
      input_audio_sample_rate => 24000,
      response_modalities => [text, audio],
      function_calling => synchronous,
      automatic_activity_detection => true,
      manual_activity_detection => true,
      input_transcription => true,
      output_transcription => true,
      session_resumption => false,
      structured_output => false,
      context_cache => false}.

-spec validate_config(map()) -> {ok, map()} | {error, term()}.
validate_config(Config) when is_map(Config) ->
    Allowed = [model, response_modalities, system_instruction, voice_name,
               input_audio_transcription, output_audio_transcription,
               automatic_activity_detection, turn_detection, tools],
    case lists:sort(maps:keys(Config) -- Allowed) of
        [] -> validate_fields(Config);
        [Key | _] -> config_error([Key], unsupported_option)
    end;
validate_config(_Config) ->
    config_error([], expected_map).

-spec setup_frame(map()) -> {ok, binary()} | {error, term()}.
setup_frame(Config) ->
    adk_live_openai_codec:setup_frame(Config).

-spec encode_client(adk_live_provider:client_action(), map()) ->
    {ok, binary() | [binary(), ...]} | ignored | {error, term()}.
encode_client(Action, Config) ->
    adk_live_openai_codec:encode_client(Action, Config).

-spec decode_server(binary(), map()) ->
    {ok, [adk_live_provider:event_spec()]} | {error, term()}.
decode_server(Frame, Config) ->
    adk_live_openai_codec:decode_server(Frame, Config).

validate_fields(Config) ->
    Validators = [
        fun() -> validate_text(model, maps:get(model, Config, ?DEFAULT_MODEL),
                               ?MAX_MODEL_BYTES) end,
        fun() -> validate_modalities(Config) end,
        fun() -> validate_optional_text(system_instruction, Config,
                                        ?MAX_TEXT_BYTES) end,
        fun() -> validate_optional_text(voice_name, Config, 128) end,
        fun() -> validate_transcription(Config) end,
        fun() -> validate_optional_boolean(output_audio_transcription,
                                           Config) end,
        fun() -> validate_optional_boolean(automatic_activity_detection,
                                           Config) end,
        fun() -> validate_turn_detection(Config) end,
        fun() -> validate_tools(maps:get(tools, Config, [])) end
    ],
    case first_error(Validators) of
        ok ->
            TurnDetection = normalized_turn_detection(Config),
            {ok, Config#{model => maps:get(model, Config, ?DEFAULT_MODEL),
                         response_modalities =>
                             normalized_modalities(Config),
                         voice_name => maps:get(voice_name, Config,
                                                <<"marin">>),
                         input_audio_transcription =>
                             normalized_transcription(Config),
                         output_audio_transcription =>
                             maps:get(output_audio_transcription,
                                      Config, true),
                         automatic_activity_detection =>
                             TurnDetection =/= disabled,
                         turn_detection => TurnDetection,
                         tools => maps:get(tools, Config, [])}};
        {error, _} = Error -> Error
    end.

validate_modalities(Config) ->
    case normalized_modalities(Config) of
        [audio] -> ok;
        [text] -> ok;
        invalid -> config_error([response_modalities], invalid_value)
    end.

normalized_modalities(Config) ->
    case maps:get(response_modalities, Config, [audio]) of
        [audio] -> [audio];
        [text] -> [text];
        [<<"audio">>] -> [audio];
        [<<"text">>] -> [text];
        _ -> invalid
    end.

validate_transcription(Config) ->
    case maps:get(input_audio_transcription, Config, false) of
        false -> ok;
        true -> ok;
        Model when is_binary(Model) ->
            validate_text(input_audio_transcription, Model,
                          ?MAX_MODEL_BYTES);
        _ -> config_error([input_audio_transcription], invalid_value)
    end.

normalized_transcription(Config) ->
    case maps:get(input_audio_transcription, Config, false) of
        true -> ?DEFAULT_TRANSCRIPTION_MODEL;
        Value -> Value
    end.

validate_turn_detection(Config) ->
    Explicit = maps:get(turn_detection, Config, undefined),
    Automatic = maps:get(automatic_activity_detection, Config, undefined),
    case {Explicit, Automatic} of
        {undefined, undefined} -> ok;
        {undefined, Value} when is_boolean(Value) -> ok;
        {Value, undefined} when Value =:= semantic_vad;
                                Value =:= server_vad;
                                Value =:= disabled -> ok;
        {disabled, false} -> ok;
        {Value, true} when Value =:= semantic_vad;
                           Value =:= server_vad -> ok;
        {undefined, _} -> config_error(
                           [automatic_activity_detection],
                           expected_boolean);
        _ -> config_error([turn_detection], conflicting_or_invalid_value)
    end.

normalized_turn_detection(Config) ->
    case maps:find(turn_detection, Config) of
        {ok, Value} -> Value;
        error ->
            case maps:get(automatic_activity_detection, Config, true) of
                true -> semantic_vad;
                false -> disabled
            end
    end.

validate_optional_text(Key, Config, Maximum) ->
    case maps:find(Key, Config) of
        error -> ok;
        {ok, Value} -> validate_text(Key, Value, Maximum)
    end.

validate_text(Key, Value, Maximum)
  when is_binary(Value), byte_size(Value) > 0,
       byte_size(Value) =< Maximum ->
    case valid_utf8(Value) andalso not contains_control(Value) of
        true -> ok;
        false -> config_error([Key], invalid_text)
    end;
validate_text(Key, _Value, _Maximum) ->
    config_error([Key], invalid_text).

validate_optional_boolean(Key, Config) ->
    case maps:find(Key, Config) of
        error -> ok;
        {ok, Value} when is_boolean(Value) -> ok;
        {ok, _} -> config_error([Key], expected_boolean)
    end.

validate_tools(Tools) when is_list(Tools), length(Tools) =< ?MAX_TOOLS ->
    validate_tools(Tools, 0);
validate_tools(_Tools) ->
    config_error([tools], invalid_tools).

validate_tools([], _Index) -> ok;
validate_tools([Tool | Rest], Index) ->
    case validate_tool(Tool) of
        ok -> validate_tools(Rest, Index + 1);
        {error, Reason} -> config_error([tools, Index], Reason)
    end.

validate_tool(#{type := function, name := Name,
                parameters := Parameters} = Tool) ->
    Allowed = [type, name, description, parameters],
    Description = maps:get(description, Tool, <<>>),
    case maps:keys(Tool) -- Allowed of
        [] ->
            case valid_identifier(Name) andalso is_binary(Description)
                 andalso byte_size(Description) =< 4096
                 andalso valid_utf8(Description)
                 andalso is_map(Parameters) of
                true -> validate_tool_schema(Parameters);
                false -> {error, invalid_function_tool}
            end;
        _ -> {error, invalid_function_tool}
    end;
validate_tool(_Tool) ->
    {error, invalid_tool}.

validate_tool_schema(Schema) ->
    case adk_json:normalize(Schema) of
        {ok, Normalized} when is_map(Normalized) ->
            try byte_size(jsx:encode(Normalized)) of
                Size when Size =< ?MAX_TOOL_SCHEMA_BYTES -> ok;
                _ -> {error, tool_schema_too_large}
            catch
                _:_ -> {error, invalid_tool_schema}
            end;
        _ -> {error, invalid_tool_schema}
    end.

first_error([]) -> ok;
first_error([Validator | Rest]) ->
    case Validator() of
        ok -> first_error(Rest);
        {error, _} = Error -> Error
    end.

valid_identifier(Value) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< 256
    andalso valid_utf8(Value) andalso not contains_control(Value);
valid_identifier(_Value) -> false.

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch
        _:_ -> false
    end.

contains_control(Value) ->
    lists:any(fun(Char) -> Char < 32 orelse Char =:= 127 end,
              unicode:characters_to_list(Value)).

config_error(Path, Reason) ->
    {error, {invalid_live_config, Path, Reason}}.
