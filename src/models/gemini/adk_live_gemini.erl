%% @doc Gemini 3.1 Flash Live provider adapter.
%%
%% This adapter is intentionally model-specific.  It rejects REST-only and
%% older-Live options instead of silently degrading them.  Gemini 3.1 Live has
%% native AUDIO output and synchronous function calling.
-module(adk_live_gemini).
-behaviour(adk_live_provider).

-export([model/0, capabilities/0, validate_config/1,
         setup_frame/1, resume_setup_frame/2,
         encode_client/2, decode_server/2]).

-define(MODEL, <<"gemini-3.1-flash-live-preview">>).
-define(MAX_SYSTEM_INSTRUCTION_BYTES, 65536).
-define(MAX_TOOLS, 128).
-define(MAX_TOOL_SCHEMA_BYTES, 262144).

-spec model() -> binary().
model() -> ?MODEL.

-spec capabilities() -> map().
capabilities() ->
    #{live => true,
      model => ?MODEL,
      input_modalities => [text, audio, image],
      response_modalities => [audio],
      function_calling => synchronous,
      google_search => true,
      automatic_activity_detection => true,
      manual_activity_detection => true,
      input_transcription => true,
      output_transcription => true,
      session_resumption => true,
      context_window_compression => true,
      proactive_audio => false,
      affective_dialog => false,
      structured_output => false,
      context_cache => false}.

-spec validate_config(map()) -> {ok, map()} | {error, term()}.
validate_config(Config) when is_map(Config) ->
    Allowed = [model, response_modalities, system_instruction, voice_name,
               input_audio_transcription, output_audio_transcription,
               automatic_activity_detection, tools, thinking_config,
               session_resumption, context_window_compression,
               media_resolution],
    case lists:sort(maps:keys(Config) -- Allowed) of
        [] -> validate_fields(Config);
        [Key | _] -> config_error([Key], unsupported_option)
    end;
validate_config(_Config) ->
    config_error([], expected_map).

-spec setup_frame(map()) -> {ok, binary()} | {error, term()}.
setup_frame(Config) ->
    adk_live_gemini_codec:setup_frame(Config).

-spec resume_setup_frame(map(), binary()) ->
    {ok, binary()} | {error, term()}.
resume_setup_frame(Config, Handle) ->
    adk_live_gemini_codec:resume_setup_frame(Config, Handle).

-spec encode_client(adk_live_provider:client_action(), map()) ->
    {ok, binary()} | {error, term()}.
encode_client(Action, Config) ->
    adk_live_gemini_codec:encode_client(Action, Config).

-spec decode_server(binary(), map()) ->
    {ok, [adk_live_provider:event_spec()]} | {error, term()}.
decode_server(Frame, Config) ->
    adk_live_gemini_codec:decode_server(Frame, Config).

validate_fields(Config) ->
    Validators = [
        fun() -> validate_model(Config) end,
        fun() -> validate_response_modalities(Config) end,
        fun() -> validate_optional_text(system_instruction, Config,
                                        ?MAX_SYSTEM_INSTRUCTION_BYTES) end,
        fun() -> validate_optional_text(voice_name, Config, 128) end,
        fun() -> validate_optional_boolean(input_audio_transcription,
                                           Config) end,
        fun() -> validate_optional_boolean(output_audio_transcription,
                                           Config) end,
        fun() -> validate_optional_boolean(automatic_activity_detection,
                                           Config) end,
        fun() -> validate_optional_boolean(session_resumption, Config) end,
        fun() -> validate_optional_boolean(context_window_compression,
                                           Config) end,
        fun() -> validate_thinking(Config) end,
        fun() -> validate_media_resolution(Config) end,
        fun() -> validate_tools(maps:get(tools, Config, [])) end
    ],
    case first_error(Validators) of
        ok ->
            {ok, Config#{model => ?MODEL,
                         response_modalities => [audio],
                         input_audio_transcription =>
                             maps:get(input_audio_transcription,
                                      Config, false),
                         output_audio_transcription =>
                             maps:get(output_audio_transcription,
                                      Config, false),
                         automatic_activity_detection =>
                             maps:get(automatic_activity_detection,
                                      Config, true),
                         tools => maps:get(tools, Config, []),
                         session_resumption =>
                             maps:get(session_resumption, Config, false),
                         context_window_compression =>
                             maps:get(context_window_compression,
                                      Config, false)}};
        {error, _} = Error -> Error
    end.

validate_model(Config) ->
    case maps:get(model, Config, ?MODEL) of
        ?MODEL -> ok;
        _ -> config_error([model], unsupported_model)
    end.

validate_response_modalities(Config) ->
    case maps:get(response_modalities, Config, [audio]) of
        [audio] -> ok;
        [<<"AUDIO">>] -> ok;
        _ -> config_error([response_modalities], audio_only)
    end.

validate_optional_text(Key, Config, Maximum) ->
    case maps:find(Key, Config) of
        error -> ok;
        {ok, Value} when is_binary(Value), byte_size(Value) > 0,
                         byte_size(Value) =< Maximum ->
            case valid_utf8(Value) of
                true -> ok;
                false -> config_error([Key], invalid_utf8)
            end;
        {ok, _} -> config_error([Key], invalid_text)
    end.

validate_optional_boolean(Key, Config) ->
    case maps:find(Key, Config) of
        error -> ok;
        {ok, Value} when is_boolean(Value) -> ok;
        {ok, _} -> config_error([Key], expected_boolean)
    end.

validate_thinking(Config) ->
    case maps:find(thinking_config, Config) of
        error -> ok;
        {ok, Thinking} when is_map(Thinking) ->
            case maps:keys(Thinking) -- [thinking_level, include_thoughts] of
                [] -> validate_thinking_fields(Thinking);
                [Key | _] -> config_error([thinking_config, Key],
                                          unsupported_option)
            end;
        {ok, _} -> config_error([thinking_config], expected_map)
    end.

validate_thinking_fields(Thinking) ->
    Level = maps:get(thinking_level, Thinking, undefined),
    Include = maps:get(include_thoughts, Thinking, undefined),
    case (Level =:= undefined orelse
          lists:member(Level, [minimal, low, medium, high]))
         andalso (Include =:= undefined orelse is_boolean(Include)) of
        true -> ok;
        false -> config_error([thinking_config], invalid_value)
    end.

validate_media_resolution(Config) ->
    case maps:get(media_resolution, Config, undefined) of
        undefined -> ok;
        Value when Value =:= low; Value =:= medium; Value =:= high -> ok;
        _ -> config_error([media_resolution], invalid_value)
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

validate_tool(#{type := google_search} = Tool) ->
    case maps:keys(Tool) of
        [type] -> ok;
        _ -> {error, invalid_google_search_tool}
    end;
validate_tool(#{type := function, name := Name,
                parameters := Parameters} = Tool) ->
    Allowed = [type, name, description, parameters],
    Description = maps:get(description, Tool, <<>>),
    case maps:keys(Tool) -- Allowed of
        [] ->
            case valid_identifier(Name) andalso is_binary(Description)
                 andalso byte_size(Description) =< 4096
                 andalso is_map(Parameters) of
                false -> {error, invalid_function_tool};
                true -> validate_tool_schema(Parameters)
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
    byte_size(Value) > 0 andalso byte_size(Value) =< 128
    andalso valid_utf8(Value);
valid_identifier(_Value) -> false.

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch
        _:_ -> false
    end.

config_error(Path, Reason) ->
    {error, {invalid_live_config, Path, Reason}}.
