%% @doc Deterministic validation for the provider-neutral JSON Schema subset
%% used by agent input and output contracts.
%%
%% Values are normalized through adk_json before validation. Errors contain a
%% structural path and constraint name, never the rejected value.
-module(adk_json_schema).

-export([compile/1, validate/2]).

-type path_part() :: binary() | non_neg_integer().
-type schema() :: undefined | true | false | map().
-type error_reason() ::
    {invalid_json_schema, [path_part()], term()} |
    {invalid_json_value, term()} |
    {schema_validation_failed, [path_part()], term()}.

-export_type([schema/0, error_reason/0]).

-spec compile(undefined | boolean() | map()) ->
    {ok, schema()} | {error, error_reason()}.
compile(undefined) ->
    {ok, undefined};
compile(Schema0) when is_boolean(Schema0); is_map(Schema0) ->
    case adk_json:normalize(Schema0) of
        {ok, Schema} ->
            case validate_schema(Schema, []) of
                ok -> {ok, Schema};
                {error, _} = Error -> Error
            end;
        {error, Reason} ->
            {error, {invalid_json_schema, [], {not_json_safe, safe_reason(Reason)}}}
    end;
compile(_Schema) ->
    schema_error([], expected_schema).

%% @doc Validate and return the canonical JSON representation of a value.
-spec validate(schema(), term()) ->
    {ok, term()} | {error, error_reason()}.
validate(Schema, Value0) ->
    case validate_schema(Schema, []) of
        ok ->
            case adk_json:normalize(Value0) of
                {ok, Value} ->
                    case validate_value(Schema, Value, []) of
                        ok -> {ok, Value};
                        {error, _} = Error -> Error
                    end;
                {error, Reason} ->
                    {error, {invalid_json_value, safe_reason(Reason)}}
            end;
        {error, _} = Error ->
            Error
    end.

validate_schema(undefined, _Path) -> ok;
validate_schema(true, _Path) -> ok;
validate_schema(false, _Path) -> ok;
validate_schema(Schema, Path) when is_map(Schema) ->
    case unknown_keywords(Schema) of
        [] -> validate_schema_keywords(Schema, Path);
        [Keyword | _] -> schema_error(Path ++ [Keyword], unsupported_keyword)
    end;
validate_schema(_Schema, Path) ->
    schema_error(Path, expected_schema).

validate_schema_keywords(Schema, Path) ->
    Validators = [
        fun() -> validate_type_keyword(Schema, Path) end,
        fun() -> validate_properties_keyword(Schema, Path) end,
        fun() -> validate_required_keyword(Schema, Path) end,
        fun() -> validate_additional_properties(Schema, Path) end,
        fun() -> validate_items_keyword(Schema, Path) end,
        fun() -> validate_schema_list(<<"allOf">>, Schema, Path) end,
        fun() -> validate_schema_list(<<"anyOf">>, Schema, Path) end,
        fun() -> validate_schema_list(<<"oneOf">>, Schema, Path) end,
        fun() -> validate_enum_keyword(Schema, Path) end,
        fun() -> validate_boolean_keyword(<<"nullable">>, Schema, Path) end,
        fun() -> validate_non_negative_integer(<<"minLength">>, Schema, Path) end,
        fun() -> validate_non_negative_integer(<<"maxLength">>, Schema, Path) end,
        fun() -> validate_non_negative_integer(<<"minItems">>, Schema, Path) end,
        fun() -> validate_non_negative_integer(<<"maxItems">>, Schema, Path) end,
        fun() -> validate_non_negative_integer(<<"minProperties">>, Schema, Path) end,
        fun() -> validate_non_negative_integer(<<"maxProperties">>, Schema, Path) end,
        fun() -> validate_number_keyword(<<"minimum">>, Schema, Path) end,
        fun() -> validate_number_keyword(<<"maximum">>, Schema, Path) end,
        fun() -> validate_number_keyword(<<"exclusiveMinimum">>, Schema, Path) end,
        fun() -> validate_number_keyword(<<"exclusiveMaximum">>, Schema, Path) end,
        fun() -> validate_pattern_keyword(Schema, Path) end,
        fun() -> validate_binary_keyword(<<"format">>, Schema, Path) end,
        fun() -> validate_binary_keyword(<<"title">>, Schema, Path) end,
        fun() -> validate_binary_keyword(<<"description">>, Schema, Path) end
    ],
    first_error(Validators).

unknown_keywords(Schema) ->
    Allowed = [<<"type">>, <<"properties">>, <<"required">>,
               <<"additionalProperties">>, <<"items">>, <<"enum">>,
               <<"const">>, <<"allOf">>, <<"anyOf">>, <<"oneOf">>,
               <<"nullable">>, <<"minLength">>, <<"maxLength">>,
               <<"minimum">>, <<"maximum">>, <<"exclusiveMinimum">>,
               <<"exclusiveMaximum">>, <<"minItems">>, <<"maxItems">>,
               <<"minProperties">>, <<"maxProperties">>, <<"pattern">>,
               <<"format">>, <<"title">>, <<"description">>,
               <<"default">>, <<"examples">>, <<"$id">>, <<"$schema">>],
    lists:sort([Key || Key <- maps:keys(Schema),
                       not lists:member(Key, Allowed)]).

validate_type_keyword(Schema, Path) ->
    case maps:find(<<"type">>, Schema) of
        error -> ok;
        {ok, Type} when is_binary(Type) ->
            valid_type(Type, Path ++ [<<"type">>]);
        {ok, Types} when is_list(Types), Types =/= [] ->
            case lists:all(fun is_binary/1, Types) andalso
                 length(Types) =:= length(lists:usort(Types)) of
                true -> first_type_error(Types, Path ++ [<<"type">>]);
                false -> schema_error(Path ++ [<<"type">>], invalid_type_union)
            end;
        {ok, _} -> schema_error(Path ++ [<<"type">>], invalid_type)
    end.

first_type_error([], _Path) -> ok;
first_type_error([Type | Rest], Path) ->
    case valid_type(Type, Path) of
        ok -> first_type_error(Rest, Path);
        {error, _} = Error -> Error
    end.

valid_type(Type, _Path)
  when Type =:= <<"object">>; Type =:= <<"array">>;
       Type =:= <<"string">>; Type =:= <<"number">>;
       Type =:= <<"integer">>; Type =:= <<"boolean">>;
       Type =:= <<"null">> -> ok;
valid_type(_Type, Path) -> schema_error(Path, unknown_type).

validate_properties_keyword(Schema, Path) ->
    case maps:find(<<"properties">>, Schema) of
        error -> ok;
        {ok, Properties} when is_map(Properties) ->
            validate_schema_pairs(lists:sort(maps:to_list(Properties)),
                                  Path ++ [<<"properties">>]);
        {ok, _} -> schema_error(Path ++ [<<"properties">>], expected_map)
    end.

validate_schema_pairs([], _Path) -> ok;
validate_schema_pairs([{Name, PropertySchema} | Rest], Path) ->
    case validate_schema(PropertySchema, Path ++ [Name]) of
        ok -> validate_schema_pairs(Rest, Path);
        {error, _} = Error -> Error
    end.

validate_required_keyword(Schema, Path) ->
    case maps:find(<<"required">>, Schema) of
        error -> ok;
        {ok, Required} when is_list(Required) ->
            case lists:all(fun is_binary/1, Required) andalso
                 length(Required) =:= length(lists:usort(Required)) of
                true -> ok;
                false -> schema_error(Path ++ [<<"required">>],
                                      invalid_required)
            end;
        {ok, _} -> schema_error(Path ++ [<<"required">>], expected_list)
    end.

validate_additional_properties(Schema, Path) ->
    case maps:find(<<"additionalProperties">>, Schema) of
        error -> ok;
        {ok, Value} when is_boolean(Value) -> ok;
        {ok, Value} -> validate_schema(Value,
                                       Path ++ [<<"additionalProperties">>])
    end.

validate_items_keyword(Schema, Path) ->
    case maps:find(<<"items">>, Schema) of
        error -> ok;
        {ok, Items} -> validate_schema(Items, Path ++ [<<"items">>])
    end.

validate_schema_list(Keyword, Schema, Path) ->
    case maps:find(Keyword, Schema) of
        error -> ok;
        {ok, Schemas} when is_list(Schemas), Schemas =/= [] ->
            validate_indexed_schemas(Schemas, Path ++ [Keyword], 0);
        {ok, _} -> schema_error(Path ++ [Keyword], expected_nonempty_list)
    end.

validate_indexed_schemas([], _Path, _Index) -> ok;
validate_indexed_schemas([Schema | Rest], Path, Index) ->
    case validate_schema(Schema, Path ++ [Index]) of
        ok -> validate_indexed_schemas(Rest, Path, Index + 1);
        {error, _} = Error -> Error
    end.

validate_enum_keyword(Schema, Path) ->
    case maps:find(<<"enum">>, Schema) of
        error -> ok;
        {ok, Values} when is_list(Values), Values =/= [] ->
            case length(Values) =:= length(lists:usort(Values)) of
                true -> ok;
                false -> schema_error(Path ++ [<<"enum">>], duplicate_values)
            end;
        {ok, _} -> schema_error(Path ++ [<<"enum">>], expected_nonempty_list)
    end.

validate_boolean_keyword(Keyword, Schema, Path) ->
    case maps:find(Keyword, Schema) of
        error -> ok;
        {ok, Value} when is_boolean(Value) -> ok;
        {ok, _} -> schema_error(Path ++ [Keyword], expected_boolean)
    end.

validate_non_negative_integer(Keyword, Schema, Path) ->
    case maps:find(Keyword, Schema) of
        error -> ok;
        {ok, Value} when is_integer(Value), Value >= 0 -> ok;
        {ok, _} -> schema_error(Path ++ [Keyword],
                                expected_non_negative_integer)
    end.

validate_number_keyword(Keyword, Schema, Path) ->
    case maps:find(Keyword, Schema) of
        error -> ok;
        {ok, Value} when is_integer(Value); is_float(Value) -> ok;
        {ok, _} -> schema_error(Path ++ [Keyword], expected_number)
    end.

validate_pattern_keyword(Schema, Path) ->
    case maps:find(<<"pattern">>, Schema) of
        error -> ok;
        {ok, Pattern} when is_binary(Pattern) ->
            case re:compile(Pattern, [unicode]) of
                {ok, _} -> ok;
                {error, _} -> schema_error(Path ++ [<<"pattern">>],
                                           invalid_pattern)
            end;
        {ok, _} -> schema_error(Path ++ [<<"pattern">>], expected_string)
    end.

validate_binary_keyword(Keyword, Schema, Path) ->
    case maps:find(Keyword, Schema) of
        error -> ok;
        {ok, Value} when is_binary(Value) -> ok;
        {ok, _} -> schema_error(Path ++ [Keyword], expected_string)
    end.

first_error([]) -> ok;
first_error([Validator | Rest]) ->
    case Validator() of
        ok -> first_error(Rest);
        {error, _} = Error -> Error
    end.

validate_value(undefined, _Value, _Path) -> ok;
validate_value(true, _Value, _Path) -> ok;
validate_value(false, _Value, Path) -> value_error(Path, schema_false);
validate_value(Schema, Value, Path) when is_map(Schema) ->
    Validators = [
        fun() -> validate_const_and_enum(Schema, Value, Path) end,
        fun() -> validate_compositions(Schema, Value, Path) end,
        fun() -> validate_value_type(Schema, Value, Path) end,
        fun() -> validate_object(Schema, Value, Path) end,
        fun() -> validate_array(Schema, Value, Path) end,
        fun() -> validate_string(Schema, Value, Path) end,
        fun() -> validate_number(Schema, Value, Path) end
    ],
    first_error(Validators).

validate_const_and_enum(Schema, Value, Path) ->
    case maps:find(<<"const">>, Schema) of
        {ok, Value} -> validate_enum(Schema, Value, Path);
        {ok, _Different} -> value_error(Path, const_mismatch);
        error -> validate_enum(Schema, Value, Path)
    end.

validate_enum(Schema, Value, Path) ->
    case maps:find(<<"enum">>, Schema) of
        {ok, Values} ->
            case lists:member(Value, Values) of
                true -> ok;
                false -> value_error(Path, enum_mismatch)
            end;
        error -> ok
    end.

validate_compositions(Schema, Value, Path) ->
    case validate_all_of(maps:get(<<"allOf">>, Schema, []), Value, Path) of
        ok ->
            case validate_any_of(maps:get(<<"anyOf">>, Schema, undefined),
                                 Value, Path) of
                ok -> validate_one_of(maps:get(<<"oneOf">>, Schema, undefined),
                                      Value, Path);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_all_of([], _Value, _Path) -> ok;
validate_all_of([Schema | Rest], Value, Path) ->
    case validate_value(Schema, Value, Path) of
        ok -> validate_all_of(Rest, Value, Path);
        {error, _} -> value_error(Path, all_of_mismatch)
    end.

validate_any_of(undefined, _Value, _Path) -> ok;
validate_any_of(Schemas, Value, Path) ->
    case lists:any(fun(Schema) -> validate_value(Schema, Value, Path) =:= ok end,
                   Schemas) of
        true -> ok;
        false -> value_error(Path, any_of_mismatch)
    end.

validate_one_of(undefined, _Value, _Path) -> ok;
validate_one_of(Schemas, Value, Path) ->
    Matches = length([ok || Schema <- Schemas,
                            validate_value(Schema, Value, Path) =:= ok]),
    case Matches of
        1 -> ok;
        _ -> value_error(Path, one_of_mismatch)
    end.

validate_value_type(Schema, Value, Path) ->
    Nullable = maps:get(<<"nullable">>, Schema, false),
    case {Value, Nullable, maps:find(<<"type">>, Schema)} of
        {null, true, _} -> ok;
        {_Any, _Nullable, error} -> ok;
        {_Any, _Nullable, {ok, Type}} when is_binary(Type) ->
            case type_matches(Type, Value) of
                true -> ok;
                false -> value_error(Path, {expected_type, Type})
            end;
        {_Any, _Nullable, {ok, Types}} ->
            case lists:any(fun(Type) -> type_matches(Type, Value) end, Types) of
                true -> ok;
                false -> value_error(Path, {expected_one_of_types, Types})
            end
    end.

type_matches(<<"object">>, Value) -> is_map(Value);
type_matches(<<"array">>, Value) -> is_list(Value);
type_matches(<<"string">>, Value) -> is_binary(Value);
type_matches(<<"number">>, Value) -> is_integer(Value) orelse is_float(Value);
type_matches(<<"integer">>, Value) -> is_integer(Value);
type_matches(<<"boolean">>, Value) -> is_boolean(Value);
type_matches(<<"null">>, Value) -> Value =:= null.

validate_object(Schema, Value, Path) when is_map(Value) ->
    Required = maps:get(<<"required">>, Schema, []),
    case first_missing(Required, Value) of
        none ->
            Properties = maps:get(<<"properties">>, Schema, #{}),
            case validate_known_properties(lists:sort(maps:to_list(Properties)),
                                           Value, Path) of
                ok ->
                    case validate_unknown_properties(Schema, Properties,
                                                     Value, Path) of
                        ok -> validate_map_size(Schema, Value, Path);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        Missing -> value_error(Path, {required_property, Missing})
    end;
validate_object(_Schema, _Value, _Path) -> ok.

first_missing([], _Value) -> none;
first_missing([Key | Rest], Value) ->
    case maps:is_key(Key, Value) of
        true -> first_missing(Rest, Value);
        false -> Key
    end.

validate_known_properties([], _Value, _Path) -> ok;
validate_known_properties([{Key, PropertySchema} | Rest], Value, Path) ->
    case maps:find(Key, Value) of
        {ok, PropertyValue} ->
            case validate_value(PropertySchema, PropertyValue, Path ++ [Key]) of
                ok -> validate_known_properties(Rest, Value, Path);
                {error, _} = Error -> Error
            end;
        error -> validate_known_properties(Rest, Value, Path)
    end.

validate_unknown_properties(Schema, Properties, Value, Path) ->
    Unknown = lists:sort(maps:keys(maps:without(maps:keys(Properties), Value))),
    case maps:get(<<"additionalProperties">>, Schema, true) of
        true -> ok;
        false ->
            case Unknown of
                [] -> ok;
                [Key | _] -> value_error(Path ++ [Key], additional_property)
            end;
        AdditionalSchema ->
            validate_additional_values(Unknown, AdditionalSchema, Value, Path)
    end.

validate_additional_values([], _Schema, _Value, _Path) -> ok;
validate_additional_values([Key | Rest], Schema, Value, Path) ->
    case validate_value(Schema, maps:get(Key, Value), Path ++ [Key]) of
        ok -> validate_additional_values(Rest, Schema, Value, Path);
        {error, _} = Error -> Error
    end.

validate_map_size(Schema, Value, Path) ->
    validate_size_bounds(Schema, map_size(Value),
                         <<"minProperties">>, <<"maxProperties">>, Path).

validate_array(Schema, Value, Path) when is_list(Value) ->
    case validate_size_bounds(Schema, length(Value),
                              <<"minItems">>, <<"maxItems">>, Path) of
        ok ->
            case maps:find(<<"items">>, Schema) of
                error -> ok;
                {ok, ItemSchema} -> validate_items(Value, ItemSchema, Path, 0)
            end;
        {error, _} = Error -> Error
    end;
validate_array(_Schema, _Value, _Path) -> ok.

validate_items([], _Schema, _Path, _Index) -> ok;
validate_items([Value | Rest], Schema, Path, Index) ->
    case validate_value(Schema, Value, Path ++ [Index]) of
        ok -> validate_items(Rest, Schema, Path, Index + 1);
        {error, _} = Error -> Error
    end.

validate_string(Schema, Value, Path) when is_binary(Value) ->
    Length = string:length(Value),
    case validate_size_bounds(Schema, Length,
                              <<"minLength">>, <<"maxLength">>, Path) of
        ok -> validate_pattern(Schema, Value, Path);
        {error, _} = Error -> Error
    end;
validate_string(_Schema, _Value, _Path) -> ok.

validate_pattern(Schema, Value, Path) ->
    case maps:find(<<"pattern">>, Schema) of
        error -> ok;
        {ok, Pattern} ->
            case re:run(Value, Pattern,
                        [unicode, {capture, none},
                         {match_limit, 100000},
                         {match_limit_recursion, 10000}]) of
                match -> ok;
                nomatch -> value_error(Path, pattern_mismatch);
                {error, _} -> value_error(Path, pattern_limit)
            end
    end.

validate_number(Schema, Value, Path)
  when is_integer(Value); is_float(Value) ->
    Bounds = [{<<"minimum">>, fun(Bound) -> Value >= Bound end},
              {<<"maximum">>, fun(Bound) -> Value =< Bound end},
              {<<"exclusiveMinimum">>, fun(Bound) -> Value > Bound end},
              {<<"exclusiveMaximum">>, fun(Bound) -> Value < Bound end}],
    validate_numeric_bounds(Bounds, Schema, Path);
validate_number(_Schema, _Value, _Path) -> ok.

validate_numeric_bounds([], _Schema, _Path) -> ok;
validate_numeric_bounds([{Keyword, Predicate} | Rest], Schema, Path) ->
    case maps:find(Keyword, Schema) of
        error -> validate_numeric_bounds(Rest, Schema, Path);
        {ok, Bound} ->
            case Predicate(Bound) of
                true -> validate_numeric_bounds(Rest, Schema, Path);
                false -> value_error(Path, {numeric_bound, Keyword})
            end
    end.

validate_size_bounds(Schema, Size, MinimumKey, MaximumKey, Path) ->
    case maps:find(MinimumKey, Schema) of
        {ok, Minimum} when Size < Minimum ->
            value_error(Path, {size_bound, MinimumKey});
        _ ->
            case maps:find(MaximumKey, Schema) of
                {ok, Maximum} when Size > Maximum ->
                    value_error(Path, {size_bound, MaximumKey});
                _ -> ok
            end
    end.

schema_error(Path, Reason) ->
    {error, {invalid_json_schema, Path, Reason}}.

value_error(Path, Reason) ->
    {error, {schema_validation_failed, Path, Reason}}.

safe_reason({unsupported_json_term, Path, Type}) ->
    {unsupported_json_term, Path, Type};
safe_reason({invalid_utf8, Path}) -> {invalid_utf8, Path};
safe_reason({invalid_map_key, Path, Type}) -> {invalid_map_key, Path, Type};
safe_reason({duplicate_map_key, Path, Key}) ->
    {duplicate_map_key, Path, Key}.
