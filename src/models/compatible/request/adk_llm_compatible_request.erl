%% @doc Bounded OpenAI-compatible Chat Completions request/response codec.
%%
%% Transport, endpoint selection, authentication, and retries intentionally
%% live elsewhere. The runtime config is never merged into the wire payload;
%% only explicitly validated generation options are copied.
-module(adk_llm_compatible_request).

-export([build/3, build/4, decode_response/2, decode_error/1,
         max_request_bytes/0]).

-define(MAX_REQUEST_BYTES, 33554432).
-define(MAX_RESPONSE_BYTES, 33554432).
-define(MAX_ERROR_BYTES, 1048576).
-define(MAX_MODEL_BYTES, 512).
-define(MAX_TOKENS, 1000000).
-define(MAX_STOP_SEQUENCES, 16).
-define(MAX_STOP_BYTES, 4096).
-define(MAX_ALL_STOP_BYTES, 32768).
-define(MAX_SCHEMA_NAME_BYTES, 64).
-define(MAX_ID_BYTES, 512).
-define(MAX_MODEL_RESPONSE_BYTES, 512).

-spec max_request_bytes() -> pos_integer().
max_request_bytes() -> ?MAX_REQUEST_BYTES.

-spec build(map(), term(), term()) -> {ok, map()} | {error, term()}.
build(Config, Memory, Tools) ->
    build(Config, Memory, Tools, false).

-spec build(map(), term(), term(), boolean()) ->
    {ok, map()} | {error, term()}.
build(Config, Memory, Tools, Stream)
  when is_map(Config), is_boolean(Stream) ->
    Limits0 = maps:get(content_limits, Config, #{}),
    case {validate_model(maps:get(model, Config, undefined)),
          adk_content:normalize_limits(Limits0)} of
        {{ok, Model}, {ok, Limits}} ->
            case {adk_llm_compatible_content:encode_history(Memory, Limits),
                  adk_llm_compatible_content:encode_tools(Tools)} of
                {{ok, []}, _} -> {error, compatible_messages_required};
                {{ok, Messages}, {ok, EncodedTools}} ->
                    build_payload(Config, Model, Messages,
                                  EncodedTools, Stream);
                {{error, _} = Error, _} -> Error;
                {_, {error, _} = Error} -> Error
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, Reason}} ->
            {error, {invalid_compatible_content_limits, Reason}}
    end;
build(_Config, _Memory, _Tools, Stream) when not is_boolean(Stream) ->
    {error, invalid_compatible_stream_option};
build(_Config, _Memory, _Tools, _Stream) ->
    {error, invalid_compatible_request_config}.

-spec decode_response(binary() | map(), map()) ->
    {ok, adk_provider_result:result()} | {error, term()}.
decode_response(Body, ConfigOrLimits) when is_binary(Body),
                                           is_map(ConfigOrLimits) ->
    case byte_size(Body) =< ?MAX_RESPONSE_BYTES of
        false -> {error, compatible_response_too_large};
        true ->
            try jsx:decode(Body, [return_maps]) of
                Map when is_map(Map) -> decode_response(Map, ConfigOrLimits);
                _ -> {error, invalid_compatible_response_json}
            catch
                _:_ -> {error, invalid_compatible_response_json}
            end
    end;
decode_response(#{<<"error">> := _} = Response, _ConfigOrLimits) ->
    decode_error(Response);
decode_response(Response, ConfigOrLimits)
  when is_map(Response), is_map(ConfigOrLimits) ->
    Limits0 = content_limits(ConfigOrLimits),
    case adk_content:normalize_limits(Limits0) of
        {ok, Limits} -> decode_success_response(Response, Limits);
        {error, Reason} ->
            {error, {invalid_compatible_content_limits, Reason}}
    end;
decode_response(_Response, _ConfigOrLimits) ->
    {error, invalid_compatible_response}.

%% @doc Sanitize a compatible API error. Remote messages and parameter values
%% are deliberately discarded because providers may quote request content.
-spec decode_error(binary() | map()) -> {error, term()}.
decode_error(Body) when is_binary(Body) ->
    case byte_size(Body) =< ?MAX_ERROR_BYTES of
        false -> {error, compatible_error_response_too_large};
        true ->
            try jsx:decode(Body, [return_maps]) of
                Map when is_map(Map) -> decode_error(Map);
                _ -> {error, invalid_compatible_error_response}
            catch
                _:_ -> {error, invalid_compatible_error_response}
            end
    end;
decode_error(#{<<"error">> := Error}) when is_map(Error) ->
    Candidate = case maps:get(<<"code">>, Error, undefined) of
        undefined -> maps:get(<<"type">>, Error, undefined);
        Code -> Code
    end,
    {error, {compatible_api_error, safe_code(Candidate)}};
decode_error(Error) when is_map(Error) ->
    Candidate = case maps:get(<<"code">>, Error, undefined) of
        undefined -> maps:get(<<"type">>, Error, undefined);
        Code -> Code
    end,
    {error, {compatible_api_error, safe_code(Candidate)}};
decode_error(_Body) ->
    {error, invalid_compatible_error_response}.

build_payload(Config, Model, Messages, Tools, Stream) ->
    Base0 = #{<<"model">> => Model,
              <<"messages">> => Messages,
              <<"stream">> => Stream},
    Base1 = case Tools of
        [] -> Base0;
        _ -> Base0#{<<"tools">> => Tools}
    end,
    case add_generation_options(Config, Base1) of
        {ok, Payload1} ->
            case add_tool_options(Config, Tools, Payload1) of
                {ok, Payload2} ->
                    case add_response_format(Config, Payload2) of
                        {ok, Payload3} ->
                            case add_stream_options(Config, Stream,
                                                    Payload3) of
                                {ok, Payload} -> check_request_size(Payload);
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

add_generation_options(Config, Payload0) ->
    case {optional_number(temperature, Config, 0.0, 2.0),
          optional_number(top_p, Config, 0.0, 1.0),
          max_tokens(Config), stop_sequences(Config)} of
        {{ok, Temperature}, {ok, TopP},
         {ok, MaxTokens}, {ok, Stops}} ->
            Payload1 = put_optional(<<"temperature">>, Temperature,
                                    Payload0),
            Payload2 = put_optional(<<"top_p">>, TopP, Payload1),
            Payload3 = put_optional(<<"max_tokens">>, MaxTokens, Payload2),
            {ok, put_optional(<<"stop">>, Stops, Payload3)};
        {{error, _} = Error, _, _, _} -> Error;
        {_, {error, _} = Error, _, _} -> Error;
        {_, _, {error, _} = Error, _} -> Error;
        {_, _, _, {error, _} = Error} -> Error
    end.

optional_number(Key, Config, Min, Max) ->
    case maps:find(Key, Config) of
        error -> {ok, undefined};
        {ok, Value} when (is_integer(Value) orelse is_float(Value)),
                         Value >= Min, Value =< Max -> {ok, Value};
        {ok, _} -> {error, {invalid_compatible_option, Key}}
    end.

max_tokens(Config) ->
    Legacy = maps:get(max_tokens, Config, undefined),
    Completion = maps:get(max_completion_tokens, Config, undefined),
    case {Legacy, Completion} of
        {undefined, undefined} -> {ok, undefined};
        {Value, undefined} -> valid_max_tokens(Value);
        {undefined, Value} -> valid_max_tokens(Value);
        {Value, Value} -> valid_max_tokens(Value);
        _ -> {error, conflicting_compatible_max_tokens}
    end.

valid_max_tokens(Value) when is_integer(Value), Value > 0,
                             Value =< ?MAX_TOKENS -> {ok, Value};
valid_max_tokens(_Value) -> {error, invalid_compatible_max_tokens}.

stop_sequences(Config) ->
    case maps:find(stop_sequences, Config) of
        error -> {ok, undefined};
        {ok, Stops} -> validate_stop_sequences(Stops)
    end.

validate_stop_sequences(Stops) ->
    case bounded_list_length(Stops, ?MAX_STOP_SEQUENCES) of
        {ok, Count} when Count > 0 -> validate_stops(Stops, 0, []);
        {ok, 0} -> {error, invalid_compatible_stop_sequences};
        too_many -> {error, compatible_stop_sequence_limit_exceeded};
        improper -> {error, invalid_compatible_stop_sequences}
    end.

validate_stops([], _Total, Acc) -> {ok, lists:reverse(Acc)};
validate_stops([Stop | Rest], Total, Acc) ->
    case bounded_utf8(Stop, ?MAX_STOP_BYTES) of
        true ->
            NewTotal = Total + byte_size(Stop),
            case NewTotal =< ?MAX_ALL_STOP_BYTES of
                true -> validate_stops(Rest, NewTotal, [Stop | Acc]);
                false -> {error, compatible_stop_sequences_too_large}
            end;
        false -> {error, invalid_compatible_stop_sequence}
    end.

add_tool_options(Config, Tools, Payload0) ->
    case add_parallel_tool_calls(Config, Tools, Payload0) of
        {ok, Payload1} -> add_tool_choice(Config, Tools, Payload1);
        {error, _} = Error -> Error
    end.

add_parallel_tool_calls(Config, Tools, Payload) ->
    case maps:find(parallel_tool_calls, Config) of
        error -> {ok, Payload};
        {ok, _Value} when Tools =:= [] ->
            {error, compatible_parallel_tool_calls_requires_tools};
        {ok, Value} when is_boolean(Value) ->
            {ok, Payload#{<<"parallel_tool_calls">> => Value}};
        {ok, _} -> {error, {invalid_compatible_option,
                             parallel_tool_calls}}
    end.

add_tool_choice(Config, Tools, Payload) ->
    case maps:find(tool_choice, Config) of
        error -> {ok, Payload};
        {ok, _Choice} when Tools =:= [] ->
            {error, compatible_tool_choice_requires_tools};
        {ok, Choice} ->
            case normalize_tool_choice(Choice, Tools) of
                {ok, Encoded} ->
                    {ok, Payload#{<<"tool_choice">> => Encoded}};
                {error, _} = Error -> Error
            end
    end.

normalize_tool_choice(auto, _Tools) -> {ok, <<"auto">>};
normalize_tool_choice(required, _Tools) -> {ok, <<"required">>};
normalize_tool_choice(none, _Tools) -> {ok, <<"none">>};
normalize_tool_choice(<<"auto">>, Tools) ->
    normalize_tool_choice(auto, Tools);
normalize_tool_choice(<<"required">>, Tools) ->
    normalize_tool_choice(required, Tools);
normalize_tool_choice(<<"none">>, Tools) ->
    normalize_tool_choice(none, Tools);
normalize_tool_choice({tool, Name}, Tools) ->
    named_tool_choice(Name, Tools);
normalize_tool_choice(#{type := tool, name := Name}, Tools) ->
    named_tool_choice(Name, Tools);
normalize_tool_choice(_Choice, _Tools) ->
    {error, invalid_compatible_tool_choice}.

named_tool_choice(Name, Tools) ->
    case valid_tool_name(Name) andalso
         lists:any(
           fun(#{<<"function">> := #{<<"name">> := ToolName}}) ->
                   ToolName =:= Name
           end, Tools) of
        true ->
            {ok, #{<<"type">> => <<"function">>,
                   <<"function">> => #{<<"name">> => Name}}};
        false -> {error, invalid_compatible_tool_choice}
    end.

%% `response_format' is a capability gate, not a raw wire-map escape hatch.
%% `auto' uses json_schema when a schema exists and json_object for a JSON MIME
%% request. Profiles for vendors without structured output set `unsupported'.
add_response_format(Config, Payload) ->
    Mode = maps:get(response_format, Config, auto),
    Schema = maps:get(response_schema, Config, undefined),
    Mime = maps:get(response_mime_type, Config, undefined),
    case structured_request(Mode, Schema, Mime, Config) of
        {ok, undefined} -> {ok, Payload};
        {ok, Format} -> {ok, Payload#{<<"response_format">> => Format}};
        {error, _} = Error -> Error
    end.

structured_request(unsupported, undefined, undefined, _Config) ->
    {ok, undefined};
structured_request(unsupported, _Schema, _Mime, _Config) ->
    {error, compatible_structured_output_unsupported};
structured_request(text, undefined, undefined, _Config) -> {ok, undefined};
structured_request(text, undefined, <<"text/plain">>, _Config) ->
    {ok, undefined};
structured_request(json_object, undefined, Mime, _Config)
  when Mime =:= undefined; Mime =:= <<"application/json">> ->
    {ok, #{<<"type">> => <<"json_object">>}};
structured_request(auto, undefined, <<"application/json">>, _Config) ->
    {ok, #{<<"type">> => <<"json_object">>}};
structured_request(auto, undefined, Mime, _Config)
  when Mime =:= undefined; Mime =:= <<"text/plain">> ->
    {ok, undefined};
structured_request(Mode, Schema, Mime, Config)
  when is_map(Schema),
       (Mode =:= auto orelse Mode =:= json_schema),
       (Mime =:= undefined orelse Mime =:= <<"application/json">>) ->
    json_schema_format(Schema, Config);
structured_request(json_schema, undefined, _Mime, _Config) ->
    {error, compatible_response_schema_required};
structured_request(Mode, _Schema, _Mime, _Config)
  when Mode =:= auto; Mode =:= text; Mode =:= json_object;
       Mode =:= json_schema ->
    {error, invalid_compatible_response_format};
structured_request(_Mode, _Schema, _Mime, _Config) ->
    {error, invalid_compatible_response_format}.

json_schema_format(Schema, Config) ->
    Name = maps:get(response_schema_name, Config, <<"adk_response">>),
    case {valid_schema_name(Name), strict_json_map(Schema),
          adk_json_schema:compile(Schema)} of
        {true, ok, {ok, Compiled}} ->
            {ok, #{<<"type">> => <<"json_schema">>,
                   <<"json_schema">> =>
                       #{<<"name">> => Name,
                         <<"schema">> => Compiled,
                         <<"strict">> => true}}};
        _ -> {error, invalid_compatible_response_schema}
    end.

add_stream_options(Config, false, Payload) ->
    case maps:find(stream_include_usage, Config) of
        error -> {ok, Payload};
        {ok, false} -> {ok, Payload};
        {ok, _} -> {error, compatible_stream_options_require_streaming}
    end;
add_stream_options(Config, true, Payload) ->
    case maps:find(stream_include_usage, Config) of
        error -> {ok, Payload};
        {ok, false} -> {ok, Payload};
        {ok, true} ->
            {ok, Payload#{<<"stream_options">> =>
                              #{<<"include_usage">> => true}}};
        {ok, _} ->
            {error, {invalid_compatible_option, stream_include_usage}}
    end.

check_request_size(Payload) ->
    try iolist_size(jsx:encode(Payload)) of
        Size when Size =< ?MAX_REQUEST_BYTES -> {ok, Payload};
        _ -> {error, compatible_request_too_large}
    catch
        _:_ -> {error, invalid_compatible_request_json}
    end.

decode_success_response(Response, Limits) ->
    case {bounded_field(Response, <<"id">>, ?MAX_ID_BYTES),
          bounded_field(Response, <<"model">>, ?MAX_MODEL_RESPONSE_BYTES),
          single_choice(maps:get(<<"choices">>, Response, undefined)),
          normalize_usage(maps:get(<<"usage">>, Response, undefined))} of
        {{ok, Id}, {ok, Model}, {ok, Choice}, {ok, Usage}} ->
            decode_choice(Response, Choice, Id, Model, Usage, Limits);
        {{error, _}, _, _, _} ->
            {error, invalid_compatible_response_id};
        {_, {error, _}, _, _} ->
            {error, invalid_compatible_response_model};
        {_, _, {error, _}, _} ->
            {error, invalid_compatible_response_choices};
        {_, _, _, {error, _}} ->
            {error, invalid_compatible_usage}
    end.

single_choice([#{<<"index">> := 0} = Choice]) -> {ok, Choice};
single_choice(_Choices) -> {error, invalid_choices}.

decode_choice(Response, Choice, Id, Model, Usage, Limits) ->
    FinishReason = maps:get(<<"finish_reason">>, Choice, undefined),
    Message = maps:get(<<"message">>, Choice, undefined),
    case adk_llm_compatible_content:decode_message(Message, Limits) of
        {ok, Content, Calls} ->
            case validate_finish(FinishReason, Calls) of
                ok ->
                    case adk_llm_compatible_content:outcome(Content) of
                        {error, _} = Error -> Error;
                        Outcome ->
                            Metadata0 = #{<<"response_id">> => Id,
                                          <<"response_model">> => Model,
                                          <<"finish_reason">> =>
                                              FinishReason},
                            Metadata1 = maybe_metadata(
                                          <<"usage">>, Usage, #{},
                                          Metadata0),
                            Fingerprint = maps:get(
                                            <<"system_fingerprint">>,
                                            Response, undefined),
                            case optional_bounded_field(
                                   Fingerprint, ?MAX_ID_BYTES) of
                                {ok, SafeFingerprint} ->
                                    Metadata = maybe_metadata(
                                                 <<"system_fingerprint">>,
                                                 SafeFingerprint,
                                                 undefined, Metadata1),
                                    provider_result(Outcome, Metadata);
                                error ->
                                    {error,
                                     invalid_compatible_system_fingerprint}
                            end
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_finish(<<"stop">>, []) -> ok;
validate_finish(<<"tool_calls">>, [_ | _]) -> ok;
validate_finish(<<"function_call">>, [_ | _]) -> ok;
validate_finish(<<"length">>, _Calls) ->
    {error, compatible_response_incomplete};
validate_finish(<<"content_filter">>, _Calls) ->
    {error, compatible_response_filtered};
validate_finish(_Reason, _Calls) ->
    {error, invalid_compatible_finish_reason}.

provider_result(Outcome, Metadata) ->
    case adk_provider_result:new(
           <<"openai_compatible">>, <<"chat_completions">>,
           Outcome, Metadata) of
        {ok, Result} -> {ok, Result};
        {error, _} -> {error, invalid_compatible_metadata}
    end.

normalize_usage(undefined) -> {ok, #{}};
normalize_usage(null) -> {ok, #{}};
normalize_usage(Usage) when is_map(Usage) ->
    Fields = [{<<"prompt_tokens">>, <<"input_tokens">>},
              {<<"completion_tokens">>, <<"output_tokens">>},
              {<<"total_tokens">>, <<"total_tokens">>}],
    copy_usage(Fields, Usage, #{});
normalize_usage(_Usage) -> {error, invalid_usage}.

copy_usage([], _Usage, Acc) -> {ok, Acc};
copy_usage([{Source, Target} | Rest], Usage, Acc) ->
    case maps:find(Source, Usage) of
        error -> copy_usage(Rest, Usage, Acc);
        {ok, Value} when is_integer(Value), Value >= 0 ->
            copy_usage(Rest, Usage, Acc#{Target => Value});
        {ok, _} -> {error, invalid_usage_integer}
    end.

content_limits(#{content_limits := Limits}) when is_map(Limits) -> Limits;
content_limits(Map) when is_map(Map) ->
    Allowed = maps:keys(adk_content:default_limits()),
    case lists:all(fun(Key) -> lists:member(Key, Allowed) end,
                   maps:keys(Map)) of
        true -> Map;
        false -> #{}
    end.

validate_model(Model) when is_binary(Model), byte_size(Model) > 0,
                           byte_size(Model) =< ?MAX_MODEL_BYTES ->
    case valid_utf8(Model) of
        true -> {ok, Model};
        false -> {error, invalid_compatible_model}
    end;
validate_model(_Model) -> {error, invalid_compatible_model}.

bounded_field(Map, Key, Max) ->
    case maps:find(Key, Map) of
        {ok, Value} ->
            case bounded_utf8(Value, Max) of
                true -> {ok, Value};
                false -> {error, invalid_field}
            end;
        error -> {error, missing_field}
    end.

optional_bounded_field(undefined, _Max) -> {ok, undefined};
optional_bounded_field(null, _Max) -> {ok, undefined};
optional_bounded_field(Value, Max) ->
    case bounded_utf8(Value, Max) of
        true -> {ok, Value};
        false -> error
    end.

bounded_utf8(Value, Max) when is_binary(Value), byte_size(Value) > 0,
                              byte_size(Value) =< Max -> valid_utf8(Value);
bounded_utf8(_Value, _Max) -> false.

valid_tool_name(Name) when is_binary(Name), byte_size(Name) > 0,
                           byte_size(Name) =< 64 ->
    re:run(Name, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) =:= match;
valid_tool_name(_) -> false.

valid_schema_name(Name) when is_binary(Name), byte_size(Name) > 0,
                             byte_size(Name) =< ?MAX_SCHEMA_NAME_BYTES ->
    re:run(Name, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) =:= match;
valid_schema_name(_) -> false.

strict_json_map(Value) when is_map(Value) ->
    case adk_json:normalize(Value) of
        {ok, Value} -> ok;
        _ -> {error, invalid_json}
    end.

safe_code(Value) when is_binary(Value), byte_size(Value) > 0,
                          byte_size(Value) =< 64 ->
    case re:run(Value, <<"^[A-Za-z0-9_.-]+$">>, [{capture, none}]) of
        match -> Value;
        nomatch -> <<"unknown">>
    end;
safe_code(_) -> <<"unknown">>.

valid_utf8(Value) when is_binary(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch _:_ -> false
    end.

bounded_list_length(Value, Max) ->
    bounded_list_length(Value, Max, 0).

bounded_list_length([], _Max, Count) -> {ok, Count};
bounded_list_length([_ | _], Max, Count) when Count >= Max -> too_many;
bounded_list_length([_ | Rest], Max, Count) ->
    bounded_list_length(Rest, Max, Count + 1);
bounded_list_length(_, _Max, _Count) -> improper.

put_optional(_Key, undefined, Map) -> Map;
put_optional(Key, Value, Map) -> Map#{Key => Value}.

maybe_metadata(_Key, Value, Value, Map) -> Map;
maybe_metadata(Key, Value, _Missing, Map) -> Map#{Key => Value}.
