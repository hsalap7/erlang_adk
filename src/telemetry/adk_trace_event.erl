%% @doc Metadata-only projection for developer trace retention.
%%
%% The trace store accepts the already-versioned observability and workflow
%% lifecycle schemas, but deliberately applies a narrower persistence policy:
%% prompt, response, media, tool argument, and result fields are never retained.
%% The default policy rejects a content-bearing event.  A trusted local owner
%% may instead configure `prune', which removes those fields and marks the
%% retained wrapper without weakening either source schema validation.
-module(adk_trace_event).

-export([observability/2, workflow_lifecycle/2]).

-define(MAX_ID_BYTES, 512).
-define(MAX_TYPE_BYTES, 128).

-type content_policy() :: reject | prune.
-type projection() :: #{kind := observability | workflow_lifecycle,
                        timestamp_ms := non_neg_integer(),
                        identity := map(),
                        event := map(),
                        content_pruned := boolean()}.
-export_type([content_policy/0, projection/0]).

-spec observability(map(), content_policy()) ->
    {ok, projection()} | {error, term()}.
observability(Event0, Policy) when is_map(Event0) ->
    case adk_observability:encode(Event0) of
        {ok, Canonical0} ->
            case metadata_only_observability(Canonical0, Policy) of
                {ok, Canonical1, Pruned} ->
                    Canonical2 = adk_secret_redactor:redact(Canonical1),
                    case adk_observability:encode(Canonical2) of
                        {ok, Canonical} ->
                            project(observability, timestamp(Canonical),
                                    Canonical, Pruned);
                        {error, _} -> {error, invalid_trace_observability_event}
                    end;
                {error, _} = Error -> Error
            end;
        {error, Reason} ->
            {error, {invalid_trace_observability_event, Reason}}
    end;
observability(_Event, _Policy) ->
    {error, invalid_trace_observability_event}.

-spec workflow_lifecycle(map(), content_policy()) ->
    {ok, projection()} | {error, term()}.
workflow_lifecycle(Event0, Policy) when is_map(Event0) ->
    case adk_json:normalize(Event0) of
        {ok, Canonical0} when is_map(Canonical0) ->
            case valid_lifecycle(Canonical0) of
                true ->
                    case metadata_only_lifecycle(Canonical0, Policy) of
                        {ok, Canonical1, Pruned} ->
                            case adk_json:normalize(
                                   adk_secret_redactor:redact(Canonical1)) of
                                {ok, Canonical} when is_map(Canonical) ->
                                    case valid_lifecycle(Canonical) of
                                        true ->
                                            project(
                                              workflow_lifecycle,
                                              maps:get(<<"timestamp">>,
                                                       Canonical),
                                              Canonical, Pruned);
                                        false ->
                                            {error,
                                             invalid_trace_lifecycle_event}
                                    end;
                                _ ->
                                    {error, invalid_trace_lifecycle_event}
                            end;
                        {error, _} = Error -> Error
                    end;
                false -> {error, invalid_trace_lifecycle_event}
            end;
        _ -> {error, invalid_trace_lifecycle_event}
    end;
workflow_lifecycle(_Event, _Policy) ->
    {error, invalid_trace_lifecycle_event}.

project(Kind, Timestamp, Event, Pruned) ->
    case identity(Event) of
        {ok, Identity} when map_size(Identity) > 0 ->
            {ok, #{kind => Kind, timestamp_ms => Timestamp,
                   identity => Identity, event => Event,
                   content_pruned => Pruned}};
        _ -> {error, trace_identity_required}
    end.

timestamp(#{<<"schema_version">> := 1,
            <<"timestamp_ms">> := Timestamp})
  when is_integer(Timestamp), Timestamp >= 0 ->
    Timestamp;
timestamp(#{<<"schema_version">> := 2,
            <<"start_time_unix_nano">> := Timestamp})
  when is_integer(Timestamp), Timestamp >= 0 ->
    Timestamp div 1000000.

valid_lifecycle(#{<<"schema_version">> := 1,
                  <<"type">> := Type,
                  <<"sequence">> := Sequence,
                  <<"timestamp">> := Timestamp,
                  <<"workflow_id">> := WorkflowId,
                  <<"workflow_kind">> := WorkflowKind,
                  <<"invocation_id">> := InvocationId}) ->
    valid_text(Type, ?MAX_TYPE_BYTES) andalso
    is_integer(Sequence) andalso Sequence > 0 andalso
    is_integer(Timestamp) andalso Timestamp >= 0 andalso
    valid_id(WorkflowId) andalso valid_id(WorkflowKind) andalso
    valid_id(InvocationId);
valid_lifecycle(_) -> false.

identity(Event) ->
    Metadata = map_value(<<"metadata">>, Event),
    Attributes = map_value(<<"attributes">>, Event),
    MetadataAttributes = map_value(<<"attributes">>, Metadata),
    Sources = [Event, Metadata, Attributes, MetadataAttributes],
    identity_fields(
      [{<<"run_id">>, <<"run_id">>},
       {<<"trace_id">>, <<"trace_id">>},
       {<<"workflow_id">>, <<"workflow_id">>},
       {<<"invocation_id">>, <<"invocation_id">>}],
      Sources, #{}).

identity_fields([], _Sources, Acc) -> {ok, Acc};
identity_fields([{OutputKey, SourceKey} | Rest], Sources, Acc) ->
    case first_value(SourceKey, Sources) of
        undefined -> identity_fields(Rest, Sources, Acc);
        Value ->
            case valid_id(Value) of
                true ->
                    identity_fields(Rest, Sources,
                                    Acc#{OutputKey => Value});
                false -> {error, invalid_trace_identity}
            end
    end.

first_value(_Key, []) -> undefined;
first_value(Key, [Map | Rest]) ->
    case maps:get(Key, Map, undefined) of
        Value when is_binary(Value), byte_size(Value) > 0 -> Value;
        _ -> first_value(Key, Rest)
    end.

map_value(Key, Map) ->
    case maps:get(Key, Map, #{}) of
        Value when is_map(Value) -> Value;
        _ -> #{}
    end.

%% A denylist is not a confidentiality boundary: a caller can rename a prompt
%% to `payload', `completion', or an arbitrary future alias. These projections
%% are therefore closed over each source schema. Default mode rejects any
%% field which is not retained; trusted prune mode removes it and marks the
%% trace-store wrapper.
metadata_only_observability(
  #{<<"schema_version">> := 1} = Event, Policy) ->
    Safe = project_observability_v1(Event),
    apply_content_policy(Safe, Safe =/= Event, Policy);
metadata_only_observability(
  #{<<"schema_version">> := 2} = Event, Policy) ->
    Safe = project_observability_v2(Event),
    apply_content_policy(Safe, Safe =/= Event, Policy).

metadata_only_lifecycle(Event, Policy) ->
    Safe = project_lifecycle(Event),
    apply_content_policy(Safe, Safe =/= Event, Policy).

apply_content_policy(_Safe, true, reject) ->
    {error, trace_content_rejected};
apply_content_policy(Safe, false, reject) ->
    {ok, Safe, false};
apply_content_policy(Safe, Changed, prune) ->
    {ok, Safe, Changed};
apply_content_policy(_Safe, _Changed, _Policy) ->
    {error, invalid_trace_content_policy}.

project_observability_v1(Event) ->
    Metadata0 = maps:get(<<"metadata">>, Event),
    Measurements0 = maps:get(<<"measurements">>, Event),
    Attributes0 = maps:get(<<"attributes">>, Metadata0, #{}),
    MetadataBase = project_observability_metadata(Metadata0),
    Metadata = case maps:is_key(<<"attributes">>, Metadata0) of
        true -> MetadataBase#{
                  <<"attributes">> => project_attributes(Attributes0)};
        false -> MetadataBase
    end,
    Base = #{<<"schema_version">> => 1,
             <<"event">> => maps:get(<<"event">>, Event),
             <<"timestamp_ms">> => maps:get(<<"timestamp_ms">>, Event),
             <<"measurements">> => project_measurements(Measurements0),
             <<"metadata">> => Metadata},
    case maps:is_key(<<"content_captured">>, Event) of
        true -> Base#{<<"content_captured">> => false};
        false -> Base
    end.

project_observability_v2(Event) ->
    BaseKeys = [<<"schema_version">>, <<"signal">>, <<"phase">>,
                <<"name">>, <<"kind">>, <<"trace_id">>, <<"span_id">>,
                <<"parent_span_id">>, <<"trace_flags">>, <<"tracestate">>,
                <<"start_time_unix_nano">>, <<"end_time_unix_nano">>,
                <<"duration_nano">>, <<"status">>],
    (maps:with(BaseKeys, Event))#{
      <<"attributes">> => project_attributes(
                              maps:get(<<"attributes">>, Event))}.

project_measurements(Measurements) ->
    Allowed = [<<"count">>, <<"duration_ms">>, <<"duration">>,
               <<"system_time">>, <<"monotonic_time">>, <<"bytes">>,
               <<"frames">>],
    maps:filter(
      fun(Key, Value) ->
          lists:member(Key, Allowed) andalso safe_number(Value)
      end, Measurements).

project_observability_metadata(Metadata) ->
    TextKeys = [<<"run_id">>, <<"invocation_id">>, <<"session">>,
                <<"agent">>, <<"model">>, <<"tool">>, <<"call_id">>,
                <<"trace_id">>, <<"span_id">>, <<"parent_id">>,
                <<"tracestate">>],
    Text = lists:foldl(
             fun(Key, Acc) ->
                 case maps:get(Key, Metadata, undefined) of
                     null -> Acc#{Key => null};
                     Value when is_binary(Value), byte_size(Value) > 0,
                                byte_size(Value) =< ?MAX_ID_BYTES ->
                         Acc#{Key => Value};
                     _ -> Acc
                 end
             end, #{}, TextKeys),
    case maps:get(<<"trace_flags">>, Metadata, undefined) of
        Value when is_integer(Value), Value >= 0, Value =< 255 ->
            Text#{<<"trace_flags">> => Value};
        _ -> Text
    end.

project_attributes(Attributes) when is_map(Attributes) ->
    maps:filter(
      fun(Key, Value) -> safe_attribute(Key, Value) end,
      Attributes);
project_attributes(_Attributes) -> #{}.

safe_attribute(Key, Value) ->
    case lists:member(Key, count_attribute_keys()) of
        true -> is_integer(Value) andalso Value >= 0;
        false ->
            lists:member(Key, text_attribute_keys()) andalso
            safe_attribute_value(Value)
    end.

count_attribute_keys() ->
    [<<"gen_ai.usage.input_tokens">>,
     <<"gen_ai.usage.output_tokens">>,
     <<"gen_ai.usage.cache_read.input_tokens">>,
     <<"gen_ai.usage.reasoning_tokens">>].

text_attribute_keys() ->
    [<<"phase">>, <<"hook">>, <<"outcome">>, <<"status">>,
     <<"stream">>, <<"capture_error">>,
     <<"gen_ai.operation.name">>, <<"gen_ai.provider.name">>,
     <<"gen_ai.request.model">>, <<"gen_ai.response.model">>,
     <<"gen_ai.response.id">>, <<"gen_ai.tool.name">>,
     <<"gen_ai.tool.call.id">>, <<"gen_ai.response.finish_reasons">>,
     <<"erlang_adk.gen_ai.mapping.version">>, <<"error.type">>].

safe_attribute_value(Value) when is_binary(Value) ->
    byte_size(Value) =< 512;
safe_attribute_value(Value) when is_boolean(Value) -> true;
safe_attribute_value(Value) when is_integer(Value) -> true;
safe_attribute_value(Values) when is_list(Values), length(Values) =< 16 ->
    lists:all(fun(Value) ->
                      is_binary(Value) andalso byte_size(Value) =< 512
              end, Values);
safe_attribute_value(_Value) -> false.

project_lifecycle(Event) ->
    Required = [<<"schema_version">>, <<"type">>, <<"sequence">>,
                <<"timestamp">>, <<"workflow_id">>, <<"workflow_kind">>,
                <<"invocation_id">>],
    OptionalText = [<<"node_id">>, <<"node_type">>, <<"outcome">>,
                    <<"pause_kind">>, <<"parent">>, <<"join_id">>,
                    <<"from">>, <<"to">>, <<"fork_id">>],
    OptionalCounts = [<<"iteration">>, <<"branch_count">>,
                      <<"completed_count">>, <<"attempt">>],
    Base = maps:with(Required, Event),
    WithText = lists:foldl(
                 fun(Key, Acc) ->
                     case maps:get(Key, Event, undefined) of
                         Value when is_binary(Value), byte_size(Value) > 0,
                                    byte_size(Value) =< ?MAX_ID_BYTES ->
                             Acc#{Key => Value};
                         _ -> Acc
                     end
                 end, Base, OptionalText),
    lists:foldl(
      fun(Key, Acc) ->
          case maps:get(Key, Event, undefined) of
              Value when is_integer(Value), Value >= 0 -> Acc#{Key => Value};
              _ -> Acc
          end
      end, WithText, OptionalCounts).

safe_number(Value) when is_integer(Value); is_float(Value) -> true;
safe_number(_Value) -> false.

valid_id(Value) -> valid_text(Value, ?MAX_ID_BYTES).

valid_text(Value, Max) when is_binary(Value), byte_size(Value) > 0,
                            byte_size(Value) =< Max ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end;
valid_text(_Value, _Max) -> false.
