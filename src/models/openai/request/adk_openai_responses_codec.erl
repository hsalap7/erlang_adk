%% @doc Bounded request/response codec for OpenAI's Responses API.
%%
%% Transport and credentials intentionally live outside this module. All wire
%% maps are binary-keyed. Provider error messages are not retained because
%% they can contain request/model content; callers receive only a bounded code.
-module(adk_openai_responses_codec).

-export([encode_request/4, decode_response/2, decode_api_error/1,
         content_limits/1]).

-define(MAX_MODEL_BYTES, 256).
-define(MAX_FORMAT_NAME_BYTES, 64).
-define(MAX_OUTPUT_TOKENS, 1000000).

-spec encode_request(map(), term(), term(), boolean()) ->
    {ok, map()} | {error, term()}.
encode_request(Config, History, Tools, Stream)
  when is_map(Config), is_boolean(Stream) ->
    Limits = content_limits(Config),
    case {validate_model(maps:get(model, Config, undefined)),
          adk_openai_responses_content:encode_history(History, Limits),
          adk_openai_responses_content:encode_tools(Tools)} of
        {{ok, Model}, {ok, Instructions, Input}, {ok, EncodedTools}} ->
            case Input of
                [] -> {error, openai_input_required};
                _ ->
                    Base0 = #{<<"model">> => Model,
                              <<"input">> => Input,
                              <<"stream">> => Stream},
                    Base1 = maybe_put(<<"instructions">>, Instructions,
                                      <<>>, Base0),
                    Base2 = maybe_put(<<"tools">>, EncodedTools, [], Base1),
                    case add_request_options(Config, Base2) of
                        {ok, Payload} -> {ok, Payload};
                        {error, _} = Error -> Error
                    end
            end;
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end;
encode_request(_Config, _History, _Tools, _Stream) ->
    {error, invalid_openai_request}.

-spec decode_response(term(), map()) ->
    {ok, adk_provider_result:result()} | {error, term()}.
decode_response(Response, ConfigOrLimits) when is_map(Response),
                                               is_map(ConfigOrLimits) ->
    Limits = content_limits(ConfigOrLimits),
    case maps:get(<<"status">>, Response, undefined) of
        <<"completed">> -> decode_completed_response(Response, Limits);
        <<"incomplete">> ->
            {error, {openai_response_incomplete,
                     incomplete_reason(Response)}};
        <<"failed">> ->
            decode_api_error(maps:get(<<"error">>, Response, #{}));
        <<"cancelled">> -> {error, openai_response_cancelled};
        _ -> {error, invalid_openai_response_status}
    end;
decode_response(_Response, _ConfigOrLimits) ->
    {error, invalid_openai_response}.

%% @doc Sanitize either a top-level API error body or an error object. Only a
%% conservative code/type token is retained; `message', `param' and request
%% values are deliberately discarded.
-spec decode_api_error(term()) -> {error, term()}.
decode_api_error(#{<<"error">> := Error}) ->
    decode_api_error(Error);
decode_api_error(Error) when is_map(Error) ->
    Candidate = case maps:get(<<"code">>, Error, undefined) of
        undefined -> maps:get(<<"type">>, Error, undefined);
        Code -> Code
    end,
    {error, {openai_api_error, safe_code(Candidate)}};
decode_api_error(_) ->
    {error, {openai_api_error, <<"unknown">>}}.

%% @doc Accept either a full provider config or a raw ADK content-limit map.
-spec content_limits(map()) -> map().
content_limits(#{content_limits := Limits}) when is_map(Limits) -> Limits;
content_limits(Map) when is_map(Map) ->
    Allowed = maps:keys(adk_content:default_limits()),
    case lists:all(fun(Key) -> lists:member(Key, Allowed) end,
                   maps:keys(Map)) of
        true -> Map;
        false -> #{}
    end.

add_request_options(Config, Payload0) ->
    case validate_store(maps:get(store, Config, false)) of
        {ok, Store} ->
            Payload1 = Payload0#{<<"store">> => Store},
            case add_numeric_options(Config, Payload1) of
                {ok, Payload2} ->
                    case add_parallel_tool_calls(Config, Payload2) of
                        {ok, Payload3} -> add_text_format(Config, Payload3);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

add_numeric_options(Config, Payload0) ->
    case normalized_max_tokens(Config) of
        {ok, MaxTokens} ->
            Payload1 = maybe_put(<<"max_output_tokens">>, MaxTokens,
                                 undefined, Payload0),
            case validate_optional_number(
                   temperature, maps:get(temperature, Config, undefined),
                   0.0, 2.0) of
                {ok, Temperature} ->
                    Payload2 = maybe_put(<<"temperature">>, Temperature,
                                         undefined, Payload1),
                    case validate_optional_number(
                           top_p, maps:get(top_p, Config, undefined),
                           0.0, 1.0) of
                        {ok, TopP} ->
                            {ok, maybe_put(<<"top_p">>, TopP,
                                           undefined, Payload2)};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

normalized_max_tokens(Config) ->
    A = maps:get(max_tokens, Config, undefined),
    B = maps:get(max_output_tokens, Config, undefined),
    case {A, B} of
        {undefined, undefined} -> {ok, undefined};
        {Value, undefined} -> validate_max_tokens(Value);
        {undefined, Value} -> validate_max_tokens(Value);
        {Value, Value} -> validate_max_tokens(Value);
        {_, _} -> {error, conflicting_openai_max_tokens}
    end.

validate_max_tokens(Value) when is_integer(Value), Value > 0,
                                Value =< ?MAX_OUTPUT_TOKENS ->
    {ok, Value};
validate_max_tokens(_) -> {error, invalid_openai_max_output_tokens}.

validate_optional_number(_Key, undefined, _Min, _Max) ->
    {ok, undefined};
validate_optional_number(_Key, Value, Min, Max)
  when is_number(Value), Value >= Min, Value =< Max ->
    {ok, Value};
validate_optional_number(Key, _Value, _Min, _Max) ->
    {error, {invalid_openai_option, Key}}.

add_parallel_tool_calls(Config, Payload) ->
    case maps:get(parallel_tool_calls, Config, undefined) of
        undefined -> {ok, Payload};
        Value when is_boolean(Value) ->
            {ok, Payload#{<<"parallel_tool_calls">> => Value}};
        _ -> {error, {invalid_openai_option, parallel_tool_calls}}
    end.

add_text_format(Config, Payload) ->
    Schema = maps:get(response_schema, Config, undefined),
    Mime = maps:get(response_mime_type, Config, undefined),
    case {Schema, Mime} of
        {undefined, undefined} -> {ok, Payload};
        {undefined, <<"text/plain">>} -> {ok, Payload};
        {undefined, <<"application/json">>} ->
            {ok, Payload#{<<"text">> =>
                              #{<<"format">> =>
                                    #{<<"type">> => <<"json_object">>}}}};
        {undefined, _} ->
            {error, unsupported_openai_response_mime_type};
        {SchemaMap, MimeValue}
          when is_map(SchemaMap),
               (MimeValue =:= undefined orelse
                MimeValue =:= <<"application/json">>) ->
            case structured_format(SchemaMap, Config) of
                {ok, Format} ->
                    {ok, Payload#{<<"text">> =>
                                      #{<<"format">> => Format}}};
                {error, _} = Error -> Error
            end;
        {_SchemaValue, _MimeValue} ->
            {error, invalid_openai_response_schema}
    end.

structured_format(Schema, Config) ->
    Name = maps:get(response_schema_name, Config, <<"adk_response">>),
    Normalized = normalize_json_map(Schema),
    Compiled = case Normalized of
        {ok, Canonical} -> adk_json_schema:compile(Canonical);
        {error, _} = Error -> Error
    end,
    case {validate_format_name(Name), Normalized, Compiled} of
        {{ok, FormatName}, {ok, _Canonical}, {ok, CompiledSchema}} ->
            {ok, #{<<"type">> => <<"json_schema">>,
                   <<"name">> => FormatName,
                   <<"schema">> => CompiledSchema,
                   <<"strict">> => true}};
        {{error, _}, _, _} -> {error, invalid_openai_schema_name};
        {_, {error, _}, _} -> {error, invalid_openai_response_schema};
        {_, _, {error, _}} -> {error, invalid_openai_response_schema}
    end.

decode_completed_response(Response, Limits) ->
    case maps:get(<<"error">>, Response, null) of
        null -> decode_completed_output(Response, Limits);
        undefined -> decode_completed_output(Response, Limits);
        Error -> decode_api_error(Error)
    end.

decode_completed_output(Response, Limits) ->
    case {bounded_utf8_field(Response, <<"id">>, 256),
          bounded_utf8_field(Response, <<"model">>, ?MAX_MODEL_BYTES),
          maps:find(<<"output">>, Response),
          normalize_usage(maps:get(<<"usage">>, Response, undefined))} of
        {{ok, ResponseId}, {ok, Model}, {ok, Output}, {ok, Usage}} ->
            case adk_openai_responses_content:decode_output(Output, Limits) of
                {ok, Content, Calls} ->
                    Outcome = case Calls of
                        [_ | _] -> {tool_calls, Calls};
                        [] ->
                            Text = iolist_to_binary(
                                     adk_openai_responses_content:text_parts(
                                       Content)),
                            case Text of
                                <<>> -> {ok, Content};
                                _ -> {ok, Text}
                            end
                    end,
                    Metadata0 = #{<<"response_id">> => ResponseId,
                                  <<"response_model">> => Model,
                                  <<"status">> => <<"completed">>},
                    Metadata = case map_size(Usage) of
                        0 -> Metadata0;
                        _ -> Metadata0#{<<"usage">> => Usage}
                    end,
                    case adk_provider_result:new(
                           <<"openai">>, <<"responses">>,
                           Outcome, Metadata) of
                        {ok, ProviderResult} -> {ok, ProviderResult};
                        {error, _} -> {error, invalid_openai_metadata}
                    end;
                {error, _} = Error -> Error
            end;
        {{error, _}, _, _, _} -> {error, invalid_openai_response_id};
        {_, {error, _}, _, _} -> {error, invalid_openai_response_model};
        {_, _, error, _} -> {error, invalid_openai_response_output};
        {_, _, _, {error, _}} -> {error, invalid_openai_usage}
    end.

normalize_usage(undefined) -> {ok, #{}};
normalize_usage(null) -> {ok, #{}};
normalize_usage(Usage) when is_map(Usage) ->
    Fields = [{<<"input_tokens">>, <<"input_tokens">>},
              {<<"output_tokens">>, <<"output_tokens">>},
              {<<"total_tokens">>, <<"total_tokens">>}],
    case copy_nonnegative_integers(Fields, Usage, #{}) of
        {ok, Basic0} ->
            case nested_usage_integer(
                   Usage, <<"input_tokens_details">>, <<"cached_tokens">>) of
                {ok, Cached} ->
                    Basic1 = maybe_put(<<"cached_input_tokens">>, Cached,
                                       undefined, Basic0),
                    case nested_usage_integer(
                           Usage, <<"output_tokens_details">>,
                           <<"reasoning_tokens">>) of
                        {ok, Reasoning} ->
                            {ok, maybe_put(<<"reasoning_tokens">>, Reasoning,
                                           undefined, Basic1)};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
normalize_usage(_) -> {error, invalid_usage}.

copy_nonnegative_integers([], _Source, Acc) -> {ok, Acc};
copy_nonnegative_integers([{SourceKey, TargetKey} | Rest], Source, Acc) ->
    case maps:find(SourceKey, Source) of
        error -> copy_nonnegative_integers(Rest, Source, Acc);
        {ok, Value} when is_integer(Value), Value >= 0 ->
            copy_nonnegative_integers(
              Rest, Source, Acc#{TargetKey => Value});
        {ok, _} -> {error, invalid_usage_integer}
    end.

nested_usage_integer(Source, ParentKey, ChildKey) ->
    case maps:find(ParentKey, Source) of
        error -> {ok, undefined};
        {ok, null} -> {ok, undefined};
        {ok, Parent} when is_map(Parent) ->
            case maps:find(ChildKey, Parent) of
                error -> {ok, undefined};
                {ok, Value} when is_integer(Value), Value >= 0 ->
                    {ok, Value};
                {ok, _} -> {error, invalid_usage_integer}
            end;
        {ok, _} -> {error, invalid_usage_details}
    end.

incomplete_reason(Response) ->
    case maps:get(<<"incomplete_details">>, Response, undefined) of
        Details when is_map(Details) ->
            safe_code(maps:get(<<"reason">>, Details, undefined));
        _ -> <<"unknown">>
    end.

validate_model(Model) when is_binary(Model), byte_size(Model) > 0,
                           byte_size(Model) =< ?MAX_MODEL_BYTES ->
    case valid_utf8(Model) of
        true -> {ok, Model};
        false -> {error, invalid_openai_model}
    end;
validate_model(_) -> {error, invalid_openai_model}.

validate_store(Value) when is_boolean(Value) -> {ok, Value};
validate_store(_) -> {error, {invalid_openai_option, store}}.

validate_format_name(Name) when is_binary(Name), byte_size(Name) > 0,
                                byte_size(Name) =< ?MAX_FORMAT_NAME_BYTES ->
    case re:run(Name, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) of
        match -> {ok, Name};
        nomatch -> {error, invalid_name}
    end;
validate_format_name(_) -> {error, invalid_name}.

normalize_json_map(Value) when is_map(Value) ->
    case adk_json:normalize(Value) of
        {ok, Normalized} when is_map(Normalized) -> {ok, Normalized};
        _ -> {error, invalid_json}
    end.

bounded_utf8_field(Map, Key, Max) ->
    case maps:find(Key, Map) of
        {ok, Value} when is_binary(Value), byte_size(Value) > 0,
                         byte_size(Value) =< Max ->
            case valid_utf8(Value) of
                true -> {ok, Value};
                false -> {error, invalid_utf8}
            end;
        _ -> {error, invalid_field}
    end.

safe_code(Value) when is_binary(Value), byte_size(Value) > 0,
                          byte_size(Value) =< 64 ->
    case re:run(Value, <<"^[A-Za-z0-9_.-]+$">>, [{capture, none}]) of
        match -> Value;
        nomatch -> <<"unknown">>
    end;
safe_code(_) -> <<"unknown">>.

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.

maybe_put(_Key, Value, Value, Map) -> Map;
maybe_put(Key, Value, _Missing, Map) -> Map#{Key => Value}.
