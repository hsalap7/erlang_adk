%% @doc Bounded Messages API request construction for the Anthropic adapter.
%%
%% This module deliberately receives the complete runtime config but copies
%% only documented generation fields. In particular, API keys and runtime
%% handles can never enter the JSON payload through an accidental map merge.
-module(adk_llm_anthropic_request).

-export([build/3, build/4, encode_tools/1, max_request_bytes/0]).

-define(MAX_REQUEST_BYTES, 33554432).
-define(MAX_TOOLS, 128).
-define(MAX_TOOL_SCHEMA_BYTES, 1048576).
-define(MAX_OUTPUT_SCHEMA_BYTES, 1048576).
-define(MAX_ALL_TOOL_BYTES, 4194304).
-define(MAX_DESCRIPTION_BYTES, 8192).
-define(MAX_MODEL_BYTES, 512).
-define(MAX_TOOL_NAME_BYTES, 128).
-define(MAX_IMAGES, 100).
-define(MAX_TOKENS, 1000000).
-define(MAX_STOP_SEQUENCES, 64).
-define(MAX_STOP_BYTES, 4096).
-define(MAX_ALL_STOP_BYTES, 65536).

-spec max_request_bytes() -> pos_integer().
max_request_bytes() -> ?MAX_REQUEST_BYTES.

-spec build(map(), term(), term()) -> {ok, map()} | {error, term()}.
build(Config, Memory, Tools) ->
    build(Config, Memory, Tools, false).

-spec build(map(), term(), term(), boolean()) ->
    {ok, map()} | {error, term()}.
build(Config, Memory, Tools, Stream)
  when is_map(Config), is_boolean(Stream) ->
    case validate_request_config(Config) of
        {ok, Model, MaxTokens, Limits, Generation} ->
            case {adk_llm_anthropic_content:encode_history(Memory, Limits),
                  encode_tools(Tools)} of
                {{ok, System, Messages}, {ok, EncodedTools}} ->
                    build_payload(Model, MaxTokens, Stream, System,
                                  Messages, EncodedTools,
                                  Generation, Config);
                {{error, _} = Error, _} -> Error;
                {_, {error, _} = Error} -> Error
            end;
        {error, _} = Error -> Error
    end;
build(_Config, _Memory, _Tools, Stream) when not is_boolean(Stream) ->
    {error, invalid_anthropic_stream_option};
build(_Config, _Memory, _Tools, _Stream) ->
    {error, invalid_anthropic_request_config}.

%% @doc Translate the existing ADK function declaration contract (`name',
%% optional `description', and `parameters') into Anthropic client tools.
-spec encode_tools(term()) -> {ok, [map()]} | {error, term()}.
encode_tools(Tools) ->
    case bounded_list_length(Tools, ?MAX_TOOLS) of
        {ok, _} -> encode_tools(Tools, 0, [], #{}, 0);
        too_many -> {error, {anthropic_tool_limit_exceeded, ?MAX_TOOLS}};
        improper -> {error, invalid_anthropic_tools}
    end.

build_payload(_Model, _MaxTokens, _Stream, _System, [],
              _Tools, _Generation, _Config) ->
    {error, anthropic_messages_required};
build_payload(Model, MaxTokens, Stream, System, Messages,
              Tools, Generation, Config) ->
    Base = #{<<"model">> => Model,
             <<"max_tokens">> => MaxTokens,
             <<"messages">> => Messages,
             <<"stream">> => Stream},
    WithSystem = case System of
        undefined -> Base;
        _ -> Base#{<<"system">> => System}
    end,
    WithTools = case Tools of
        [] -> WithSystem;
        _ -> WithSystem#{<<"tools">> => Tools}
    end,
    WithGeneration = maps:merge(WithTools, Generation),
    case add_tool_choice(WithGeneration, Config, Tools) of
        {ok, WithChoice} ->
            case add_output_config(WithChoice, Config) of
                {ok, Payload} -> check_request_constraints(Payload);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_request_config(Config) ->
    Model = maps:get(model, Config, undefined),
    MaxTokens = maps:get(max_tokens, Config, 1024),
    LimitsValue = maps:get(content_limits, Config, #{}),
    case {bounded_utf8(Model, ?MAX_MODEL_BYTES),
          valid_integer(MaxTokens, 1, ?MAX_TOKENS),
          adk_content:normalize_limits(LimitsValue),
          generation_options(Config)} of
        {true, true, {ok, Limits}, {ok, Generation}} ->
            {ok, Model, MaxTokens, Limits, Generation};
        {false, _, _, _} -> {error, invalid_anthropic_model};
        {_, false, _, _} -> {error, invalid_anthropic_max_tokens};
        {_, _, {error, Reason}, _} ->
            {error, {invalid_anthropic_content_limits, Reason}};
        {_, _, _, {error, _} = Error} -> Error
    end.

generation_options(Config) ->
    case {optional_probability(temperature, Config),
          optional_probability(top_p, Config),
          optional_integer(top_k, Config, 0, ?MAX_TOKENS),
          stop_sequences(Config)} of
        {{ok, Temperature}, {ok, TopP}, {ok, TopK}, {ok, Stops}} ->
            Options0 = put_optional(<<"temperature">>, Temperature, #{}),
            Options1 = put_optional(<<"top_p">>, TopP, Options0),
            Options2 = put_optional(<<"top_k">>, TopK, Options1),
            {ok, put_optional(<<"stop_sequences">>, Stops, Options2)};
        {{error, _} = Error, _, _, _} -> Error;
        {_, {error, _} = Error, _, _} -> Error;
        {_, _, {error, _} = Error, _} -> Error;
        {_, _, _, {error, _} = Error} -> Error
    end.

optional_probability(Key, Config) ->
    case maps:find(Key, Config) of
        error -> {ok, undefined};
        {ok, Value} when (is_integer(Value) orelse is_float(Value)),
                         Value >= 0, Value =< 1 -> {ok, Value};
        {ok, _} -> {error, {invalid_anthropic_option, Key}}
    end.

optional_integer(Key, Config, Min, Max) ->
    case maps:find(Key, Config) of
        error -> {ok, undefined};
        {ok, Value} when is_integer(Value), Value >= Min, Value =< Max ->
            {ok, Value};
        {ok, _} -> {error, {invalid_anthropic_option, Key}}
    end.

stop_sequences(Config) ->
    case maps:find(stop_sequences, Config) of
        error -> {ok, undefined};
        {ok, Stops} -> validate_stop_sequences(Stops)
    end.

validate_stop_sequences(Stops) ->
    case bounded_list_length(Stops, ?MAX_STOP_SEQUENCES) of
        {ok, Count} when Count > 0 ->
            validate_stop_sequences(Stops, 0);
        {ok, 0} -> {error, invalid_anthropic_stop_sequences};
        too_many ->
            {error, {anthropic_stop_sequence_limit_exceeded,
                     ?MAX_STOP_SEQUENCES}};
        improper -> {error, invalid_anthropic_stop_sequences}
    end.

validate_stop_sequences([], _Total) -> {ok, []};
validate_stop_sequences(Stops, _Total) ->
    validate_stop_sequences(Stops, 0, []).

validate_stop_sequences([], Total, Acc) when Total =< ?MAX_ALL_STOP_BYTES ->
    {ok, lists:reverse(Acc)};
validate_stop_sequences([], _Total, _Acc) ->
    {error, {anthropic_stop_sequences_too_large,
             ?MAX_ALL_STOP_BYTES}};
validate_stop_sequences([Stop | Rest], Total, Acc) ->
    case bounded_utf8(Stop, ?MAX_STOP_BYTES) of
        true ->
            NewTotal = Total + byte_size(Stop),
            case NewTotal =< ?MAX_ALL_STOP_BYTES of
                true -> validate_stop_sequences(
                          Rest, NewTotal, [Stop | Acc]);
                false ->
                    {error, {anthropic_stop_sequences_too_large,
                             ?MAX_ALL_STOP_BYTES}}
            end;
        false -> {error, invalid_anthropic_stop_sequence}
    end.

add_tool_choice(Payload, Config, Tools) ->
    case maps:find(tool_choice, Config) of
        error -> {ok, Payload};
        {ok, _} when Tools =:= [] ->
            {error, anthropic_tool_choice_requires_tools};
        {ok, Choice} ->
            case normalize_tool_choice(Choice, Tools) of
                {ok, Encoded} ->
                    {ok, Payload#{<<"tool_choice">> => Encoded}};
                {error, _} = Error -> Error
            end
    end.

normalize_tool_choice(auto, _Tools) ->
    {ok, #{<<"type">> => <<"auto">>}};
normalize_tool_choice(any, _Tools) ->
    {ok, #{<<"type">> => <<"any">>}};
normalize_tool_choice(none, _Tools) ->
    {ok, #{<<"type">> => <<"none">>}};
normalize_tool_choice(<<"auto">>, Tools) ->
    normalize_tool_choice(auto, Tools);
normalize_tool_choice(<<"any">>, Tools) ->
    normalize_tool_choice(any, Tools);
normalize_tool_choice(<<"none">>, Tools) ->
    normalize_tool_choice(none, Tools);
normalize_tool_choice({tool, Name}, Tools) ->
    normalize_named_tool_choice(Name, Tools);
normalize_tool_choice(#{type := tool, name := Name}, Tools) ->
    normalize_named_tool_choice(Name, Tools);
normalize_tool_choice(#{<<"type">> := <<"tool">>,
                        <<"name">> := Name}, Tools) ->
    normalize_named_tool_choice(Name, Tools);
normalize_tool_choice(_Choice, _Tools) ->
    {error, invalid_anthropic_tool_choice}.

normalize_named_tool_choice(Name, Tools) ->
    case valid_tool_name(Name) andalso
         lists:any(fun(Tool) -> maps:get(<<"name">>, Tool) =:= Name end,
                   Tools) of
        true -> {ok, #{<<"type">> => <<"tool">>, <<"name">> => Name}};
        false -> {error, invalid_anthropic_tool_choice}
    end.

%% Anthropic's GA structured-output shape is intentionally derived only from
%% the existing ADK `output_schema' field. Caller maps are required to be
%% canonical binary-keyed JSON so schema coercion cannot alter semantics.
add_output_config(Payload, Config) ->
    case maps:find(output_schema, Config) of
        error -> {ok, Payload};
        {ok, Schema} when is_map(Schema) ->
            case strict_json_map(Schema, ?MAX_OUTPUT_SCHEMA_BYTES) of
                {ok, _Size} ->
                    {ok, Payload#{
                           <<"output_config">> =>
                               #{<<"format">> =>
                                     #{<<"type">> => <<"json_schema">>,
                                       <<"schema">> => Schema}}}};
                {error, _} -> {error, invalid_anthropic_output_schema}
            end;
        {ok, _} -> {error, invalid_anthropic_output_schema}
    end.

encode_tools([], _Index, Acc, _Names, _Total) ->
    {ok, lists:reverse(Acc)};
encode_tools([Tool | Rest], Index, Acc, Names, Total) ->
    case tool_schema(Tool) of
        {ok, Schema} ->
            case encode_tool_schema(Schema) of
                {ok, Encoded, Size} ->
                    Name = maps:get(<<"name">>, Encoded),
                    NewTotal = Total + Size,
                    case {maps:is_key(Name, Names),
                          NewTotal =< ?MAX_ALL_TOOL_BYTES} of
                        {true, _} ->
                            {error, {duplicate_anthropic_tool_name, Name}};
                        {false, false} ->
                            {error, {anthropic_tool_schemas_too_large,
                                     ?MAX_ALL_TOOL_BYTES}};
                        {false, true} ->
                            encode_tools(Rest, Index + 1,
                                         [Encoded | Acc],
                                         Names#{Name => true}, NewTotal)
                    end;
                {error, Reason} ->
                    {error, {invalid_anthropic_tool, Index, Reason}}
            end;
        {error, Reason} ->
            {error, {invalid_anthropic_tool, Index, Reason}}
    end.

tool_schema(Schema) when is_map(Schema) -> {ok, Schema};
tool_schema(Module) when is_atom(Module) ->
    try Module:schema() of
        Schema when is_map(Schema) -> {ok, Schema};
        _ -> {error, tool_schema_must_be_map}
    catch
        _:_ -> {error, tool_schema_callback_failed}
    end;
tool_schema(_) -> {error, invalid_tool_descriptor}.

encode_tool_schema(Schema) ->
    Allowed = [<<"name">>, <<"description">>, <<"parameters">>,
               <<"input_schema">>, <<"strict">>],
    Unknown = maps:keys(maps:without(Allowed, Schema)),
    case {Unknown, maps:find(<<"name">>, Schema),
          input_schema(Schema), description(Schema), strict(Schema)} of
        {[], {ok, Name}, {ok, InputSchema},
         {ok, Description}, {ok, Strict}} ->
            case {valid_tool_name(Name),
                  strict_json_map(InputSchema, ?MAX_TOOL_SCHEMA_BYTES)} of
                {true, {ok, Size}} ->
                    Base = #{<<"name">> => Name,
                             <<"input_schema">> => InputSchema},
                    WithDescription = put_optional(
                                        <<"description">>, Description, Base),
                    Encoded = put_optional(<<"strict">>, Strict,
                                           WithDescription),
                    {ok, Encoded, Size + byte_size(Name) +
                         optional_size(Description)};
                {false, _} -> {error, invalid_tool_name};
                {_, {error, _} = Error} -> Error
            end;
        {[_ | _], _, _, _, _} ->
            {error, {unknown_tool_schema_keys, lists:sort(Unknown)}};
        {_, error, _, _, _} -> {error, missing_tool_name};
        {_, _, {error, _} = Error, _, _} -> Error;
        {_, _, _, {error, _} = Error, _} -> Error;
        {_, _, _, _, {error, _} = Error} -> Error
    end.

input_schema(Schema) ->
    case {maps:find(<<"parameters">>, Schema),
          maps:find(<<"input_schema">>, Schema)} of
        {{ok, _}, {ok, _}} -> {error, conflicting_tool_input_schemas};
        {{ok, Value}, error} when is_map(Value) -> {ok, Value};
        {error, {ok, Value}} when is_map(Value) -> {ok, Value};
        {error, error} -> {error, missing_tool_input_schema};
        _ -> {error, tool_input_schema_must_be_map}
    end.

description(Schema) ->
    case maps:find(<<"description">>, Schema) of
        error -> {ok, undefined};
        {ok, Value} ->
            case bounded_utf8(Value, ?MAX_DESCRIPTION_BYTES) of
                true -> {ok, Value};
                false -> {error, invalid_tool_description}
            end
    end.

strict(Schema) ->
    case maps:find(<<"strict">>, Schema) of
        error -> {ok, undefined};
        {ok, Value} when is_boolean(Value) -> {ok, Value};
        {ok, _} -> {error, invalid_tool_strict_option}
    end.

strict_json_map(Value, Max) when is_map(Value) ->
    case adk_json:normalize(Value) of
        {ok, Value} ->
            try jsx:encode(Value) of
                Encoded when byte_size(Encoded) =< Max ->
                    {ok, byte_size(Encoded)};
                _ -> {error, {tool_schema_too_large, Max}}
            catch
                _:_ -> {error, invalid_tool_schema_json}
            end;
        {ok, _Coerced} -> {error, tool_schema_must_be_canonical_json};
        {error, Reason} -> {error, {invalid_tool_schema_json, Reason}}
    end.

check_request_constraints(Payload) ->
    case image_count(Payload) =< ?MAX_IMAGES of
        true -> check_request_size(Payload);
        false -> {error, {anthropic_image_limit_exceeded, ?MAX_IMAGES}}
    end.

check_request_size(Payload) ->
    try jsx:encode(Payload) of
        Encoded when byte_size(Encoded) =< ?MAX_REQUEST_BYTES ->
            {ok, Payload};
        Encoded ->
            {error, {anthropic_request_too_large,
                     byte_size(Encoded), ?MAX_REQUEST_BYTES}}
    catch
        _:_ -> {error, invalid_anthropic_request_json}
    end.

put_optional(_Key, undefined, Map) -> Map;
put_optional(Key, Value, Map) -> Map#{Key => Value}.

optional_size(undefined) -> 0;
optional_size(Value) -> byte_size(Value).

valid_integer(Value, Min, Max) ->
    is_integer(Value) andalso Value >= Min andalso Value =< Max.

valid_tool_name(Name) when is_binary(Name),
                           byte_size(Name) > 0,
                           byte_size(Name) =< ?MAX_TOOL_NAME_BYTES ->
    valid_utf8(Name) andalso
        re:run(Name, <<"^[A-Za-z0-9_-]{1,128}$">>,
               [{capture, none}]) =:= match;
valid_tool_name(_) -> false.

image_count(#{<<"messages">> := Messages}) ->
    lists:sum([
        length([image || #{<<"type">> := <<"image">>} <- Content])
        || #{<<"content">> := Content} <- Messages
    ]).

bounded_utf8(Value, Max) when is_binary(Value), byte_size(Value) > 0,
                              byte_size(Value) =< Max ->
    valid_utf8(Value);
bounded_utf8(_, _) -> false.

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.

bounded_list_length(Value, Max) ->
    bounded_list_length(Value, Max, 0).

bounded_list_length([], _Max, Count) -> {ok, Count};
bounded_list_length([_ | _], Max, Count) when Count >= Max -> too_many;
bounded_list_length([_ | Rest], Max, Count) ->
    bounded_list_length(Rest, Max, Count + 1);
bounded_list_length(_, _Max, _Count) -> improper.
