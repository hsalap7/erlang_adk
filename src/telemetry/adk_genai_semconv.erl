%% @doc Metadata-only OpenTelemetry GenAI semantic-convention projection.
%%
%% The upstream GenAI conventions are still marked Development.  This module
%% pins Erlang ADK's mapping independently of any OpenTelemetry SDK so an
%% application can choose when to translate these attributes into spans,
%% metrics, or logs.  Prompt, response, media, tool arguments and tool results
%% are intentionally not accepted by the mapper.
-module(adk_genai_semconv).

-export([mapping_version/0, attributes/3, metric_labels/1]).

-define(MAPPING_VERSION, <<"gen-ai-semconv-development-2026-07-14">>).
-define(MAX_ATTRIBUTE_BYTES, 256).
-define(MAX_FINISH_REASONS, 16).

-spec mapping_version() -> binary().
mapping_version() -> ?MAPPING_VERSION.

%% @doc Build a bounded, content-free attribute map for one operation.
-spec attributes(atom() | binary(), map(), map()) ->
    {ok, map()} | {error, term()}.
attributes(Operation0, Context, Details)
  when is_map(Context), is_map(Details) ->
    case operation_name(Operation0) of
        {ok, Operation} ->
            Base = #{
              <<"gen_ai.operation.name">> => Operation,
              <<"erlang_adk.gen_ai.mapping.version">> => ?MAPPING_VERSION},
            Fields = [
              {<<"gen_ai.provider.name">>, provider, binary},
              {<<"gen_ai.request.model">>, request_model, binary},
              {<<"gen_ai.response.model">>, response_model, binary},
              {<<"gen_ai.response.id">>, response_id, binary},
              {<<"gen_ai.tool.name">>, tool, binary},
              {<<"gen_ai.tool.call.id">>, call_id, binary},
              {<<"gen_ai.usage.input_tokens">>, input_tokens, count},
              {<<"gen_ai.usage.output_tokens">>, output_tokens, count},
              {<<"gen_ai.usage.cache_read.input_tokens">>,
               cached_input_tokens, count},
              {<<"gen_ai.usage.reasoning_tokens">>, reasoning_tokens, count},
              {<<"error.type">>, error_type, binary}
            ],
            Source = maps:merge(context_projection(Context),
                                details_projection(Details)),
            case add_fields(Fields, Source, Base) of
                {ok, Attributes0} -> add_finish_reasons(Source, Attributes0);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
attributes(_, _, _) ->
    {error, invalid_genai_attributes}.

%% @doc Return only labels suitable for bounded metric streams.  IDs, raw
%% errors and user/session values are excluded even if present in the input.
-spec metric_labels(map()) -> {ok, map()} | {error, term()}.
metric_labels(Attributes) when is_map(Attributes) ->
    Allowed = [<<"gen_ai.operation.name">>, <<"gen_ai.provider.name">>,
               <<"gen_ai.request.model">>, <<"gen_ai.tool.name">>,
               <<"error.type">>, <<"status">>, <<"stream">>],
    Candidate = maps:with(Allowed, Attributes),
    validate_metric_labels(maps:to_list(Candidate), #{});
metric_labels(_) -> {error, invalid_metric_labels}.

context_projection(Context) ->
    #{tool => get_either(Context, tool, <<"tool">>, undefined),
      call_id => get_either(Context, call_id, <<"call_id">>, undefined),
      request_model => get_either(Context, model, <<"model">>, undefined)}.

details_projection(Details) ->
    Keys = [provider, request_model, response_model, response_id, tool,
            call_id, input_tokens, output_tokens, cached_input_tokens,
            reasoning_tokens, error_type, finish_reasons],
    maps:from_list(
      [{Key, get_either(Details, Key, atom_to_binary(Key, utf8), undefined)}
       || Key <- Keys,
          get_either(Details, Key, atom_to_binary(Key, utf8), undefined)
            =/= undefined]).

add_fields([], _Source, Acc) -> {ok, Acc};
add_fields([{Attribute, Key, Type} | Rest], Source, Acc) ->
    case maps:get(Key, Source, undefined) of
        undefined -> add_fields(Rest, Source, Acc);
        null -> add_fields(Rest, Source, Acc);
        Value ->
            case validate_value(Type, Value) of
                {ok, Canonical} ->
                    add_fields(Rest, Source, Acc#{Attribute => Canonical});
                {error, _} = Error -> Error
            end
    end.

add_finish_reasons(Source, Acc) ->
    case maps:get(finish_reasons, Source, undefined) of
        undefined -> {ok, Acc};
        Values when is_list(Values), length(Values) =< ?MAX_FINISH_REASONS ->
            case validate_string_list(Values, []) of
                {ok, Canonical} ->
                    {ok, Acc#{<<"gen_ai.response.finish_reasons">> =>
                                  Canonical}};
                {error, _} = Error -> Error
            end;
        _ -> {error, invalid_finish_reasons}
    end.

validate_string_list([], Acc) -> {ok, lists:reverse(Acc)};
validate_string_list([Value | Rest], Acc) ->
    case validate_value(binary, Value) of
        {ok, Canonical} -> validate_string_list(Rest, [Canonical | Acc]);
        {error, _} -> {error, invalid_finish_reasons}
    end.

validate_value(binary, Value) when is_atom(Value) ->
    validate_value(binary, atom_to_binary(Value, utf8));
validate_value(binary, Value) when is_binary(Value), byte_size(Value) > 0,
                                   byte_size(Value) =< ?MAX_ATTRIBUTE_BYTES ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> {ok, Value};
        _ -> {error, invalid_genai_attribute}
    end;
validate_value(count, Value) when is_integer(Value), Value >= 0 ->
    {ok, Value};
validate_value(_, _) -> {error, invalid_genai_attribute}.

validate_metric_labels([], Acc) -> {ok, Acc};
validate_metric_labels([{Key, Value} | Rest], Acc)
  when is_binary(Key) ->
    case Value of
        Bool when is_boolean(Bool) ->
            validate_metric_labels(Rest, Acc#{Key => Bool});
        _ ->
            case validate_value(binary, Value) of
                {ok, Canonical} ->
                    validate_metric_labels(Rest, Acc#{Key => Canonical});
                {error, _} -> {error, invalid_metric_labels}
            end
    end.

operation_name(Value) when is_atom(Value) ->
    operation_name(atom_to_binary(Value, utf8));
operation_name(Value) when is_binary(Value), byte_size(Value) > 0,
                            byte_size(Value) =< 64 ->
    Allowed = [<<"chat">>, <<"generate_content">>, <<"invoke_agent">>,
               <<"execute_tool">>, <<"workflow">>, <<"live_connect">>,
               <<"live_receive">>, <<"evaluate">>],
    case lists:member(Value, Allowed) of
        true -> {ok, Value};
        false -> {error, {unsupported_genai_operation, Value}}
    end;
operation_name(_) -> {error, invalid_genai_operation}.

get_either(Map, AtomKey, BinaryKey, Default) ->
    case maps:find(AtomKey, Map) of
        {ok, Value} -> Value;
        error -> maps:get(BinaryKey, Map, Default)
    end.
