-module(adk_json_schema_test).

-include_lib("eunit/include/eunit.hrl").

compile_base_contract_test() ->
    ?assertEqual({ok, undefined}, adk_json_schema:compile(undefined)),
    ?assertEqual({ok, true}, adk_json_schema:compile(true)),
    ?assertEqual({ok, false}, adk_json_schema:compile(false)),
    ?assertEqual(
       {error, {invalid_json_schema, [], expected_schema}},
       adk_json_schema:compile(not_a_schema)),
    ?assertEqual(
       {error, {invalid_json_schema, [<<"atom_key">>], unsupported_keyword}},
       adk_json_schema:compile(#{atom_key => true})),
    ?assertMatch(
       {error, {invalid_json_schema, [], {not_json_safe, _}}},
       adk_json_schema:compile(#{42 => true})),
    ?assertMatch(
       {error, {invalid_json_schema, [], {not_json_safe, _}}},
       adk_json_schema:compile(#{<<"default">> => make_ref()})),

    Schema = object_schema(),
    ?assertEqual({ok, Schema}, adk_json_schema:compile(Schema)),
    ?assertEqual({ok, valid_object()},
                 adk_json_schema:validate(Schema, valid_object())).

schema_keyword_rejection_contract_test() ->
    Vectors =
        [{#{<<"unsupported">> => true},
          [<<"unsupported">>], unsupported_keyword},
         {#{<<"type">> => <<"mystery">>},
          [<<"type">>], unknown_type},
         {#{<<"type">> => 42},
          [<<"type">>], invalid_type},
         {#{<<"type">> => [<<"string">>, <<"string">>]},
          [<<"type">>], invalid_type_union},
         {#{<<"properties">> => []},
          [<<"properties">>], expected_map},
         {#{<<"properties">> => #{<<"field">> => 42}},
          [<<"properties">>, <<"field">>], expected_schema},
         {#{<<"required">> => <<"field">>},
          [<<"required">>], expected_list},
         {#{<<"required">> => [<<"field">>, <<"field">>]},
          [<<"required">>], invalid_required},
         {#{<<"additionalProperties">> => 42},
          [<<"additionalProperties">>], expected_schema},
         {#{<<"items">> => 42},
          [<<"items">>], expected_schema},
         {#{<<"allOf">> => []},
          [<<"allOf">>], expected_nonempty_list},
         {#{<<"anyOf">> => [#{<<"type">> => 42}]},
          [<<"anyOf">>, 0, <<"type">>], invalid_type},
         {#{<<"enum">> => []},
          [<<"enum">>], expected_nonempty_list},
         {#{<<"enum">> => [1, 1]},
          [<<"enum">>], duplicate_values},
         {#{<<"nullable">> => 1},
          [<<"nullable">>], expected_boolean},
         {#{<<"minLength">> => -1},
          [<<"minLength">>], expected_non_negative_integer},
         {#{<<"minimum">> => <<"zero">>},
          [<<"minimum">>], expected_number},
         {#{<<"pattern">> => <<"(">>},
          [<<"pattern">>], invalid_pattern},
         {#{<<"pattern">> => 42},
          [<<"pattern">>], expected_string},
         {#{<<"format">> => 42},
          [<<"format">>], expected_string}],
    [assert_compile_error(Schema, Path, Reason)
     || {Schema, Path, Reason} <- Vectors].

invalid_schema_validation_preserves_compile_error_test() ->
    ?assertEqual(
       {error, {invalid_json_schema, [<<"type">>], unknown_type}},
       adk_json_schema:validate(
         #{<<"type">> => <<"mystery">>}, ignored_value)),
    ?assertEqual(
       {error, {invalid_json_schema, [<<"type">>], unknown_type}},
       adk_json_schema:compile(
         #{<<"type">> => [<<"string">>, <<"mystery">>]})).

schema_normalization_rejects_duplicate_canonical_keys_test() ->
    ?assertEqual(
       {error,
        {invalid_json_schema, [],
         {not_json_safe,
          {duplicate_map_key, [], <<"atom_key">>}}}},
       adk_json_schema:compile(
         #{atom_key => true, <<"atom_key">> => false})).

const_enum_and_composition_validation_test() ->
    ConstEnum = #{<<"const">> => <<"ready">>,
                  <<"enum">> => [<<"ready">>, <<"done">>]},
    ?assertEqual({ok, <<"ready">>},
                 adk_json_schema:validate(ConstEnum, <<"ready">>)),
    assert_value_error(ConstEnum, <<"done">>, [], const_mismatch),
    assert_value_error(#{<<"enum">> => [1, 2]}, 3, [], enum_mismatch),

    Composition =
        #{<<"allOf">> =>
              [#{<<"type">> => <<"integer">>},
               #{<<"minimum">> => 1}],
          <<"anyOf">> =>
              [#{<<"const">> => 2}, #{<<"const">> => 4}],
          <<"oneOf">> =>
              [#{<<"minimum">> => 0}, #{<<"minimum">> => 3}]},
    ?assertEqual({ok, 2}, adk_json_schema:validate(Composition, 2)),
    assert_value_error(Composition, 0, [], all_of_mismatch),
    assert_value_error(Composition, 1, [], any_of_mismatch),
    assert_value_error(Composition, 4, [], one_of_mismatch),
    assert_value_error(
      #{<<"oneOf">> => [#{<<"type">> => <<"string">>},
                          #{<<"type">> => <<"integer">>}]},
      false, [], one_of_mismatch),
    ?assertEqual({ok, <<"anything">>},
                 adk_json_schema:validate_compiled(undefined, anything)),
    ?assertEqual({ok, <<"anything">>},
                 adk_json_schema:validate_compiled(true, anything)),
    assert_value_error(false, anything, [], schema_false).

type_and_nullable_validation_test() ->
    Cases = [{<<"object">>, #{}}, {<<"array">>, []},
             {<<"string">>, <<"value">>}, {<<"number">>, 1.5},
             {<<"number">>, 1}, {<<"integer">>, 1},
             {<<"boolean">>, true}, {<<"null">>, null}],
    [?assertEqual({ok, Value},
                  adk_json_schema:validate(#{<<"type">> => Type}, Value))
     || {Type, Value} <- Cases],
    ?assertEqual({ok, null},
                 adk_json_schema:validate(
                   #{<<"type">> => <<"string">>, <<"nullable">> => true},
                   null)),
    Union = #{<<"type">> => [<<"string">>, <<"integer">>]},
    ?assertEqual({ok, <<"value">>},
                 adk_json_schema:validate(Union, <<"value">>)),
    ?assertEqual({ok, 7}, adk_json_schema:validate(Union, 7)),
    assert_value_error(
      #{<<"type">> => <<"string">>}, 7, [],
      {expected_type, <<"string">>}),
    assert_value_error(
      Union, false, [],
      {expected_one_of_types, [<<"string">>, <<"integer">>]}).

object_validation_contract_test() ->
    Schema = object_schema(),
    ?assertEqual({ok, valid_object()},
                 adk_json_schema:validate(Schema, valid_object())),
    assert_value_error(Schema, #{}, [], {required_property, <<"name">>}),
    assert_value_error(
      Schema, (valid_object())#{<<"name">> => 42}, [<<"name">>],
      {expected_type, <<"string">>}),
    assert_value_error(
      Schema, (valid_object())#{<<"extra">> => true}, [<<"extra">>],
      additional_property),
    assert_value_error(
      Schema#{<<"additionalProperties">> => true},
      (valid_object())#{<<"third">> => <<"too-many">>}, [],
      {size_bound, <<"maxProperties">>}),

    AdditionalSchema =
        #{<<"type">> => <<"object">>,
          <<"additionalProperties">> => #{<<"type">> => <<"integer">>}},
    ?assertEqual({ok, #{<<"count">> => 2}},
                 adk_json_schema:validate(
                   AdditionalSchema, #{<<"count">> => 2})),
    assert_value_error(
      AdditionalSchema, #{<<"count">> => <<"two">>}, [<<"count">>],
      {expected_type, <<"integer">>}),
    assert_value_error(
      #{<<"type">> => <<"object">>, <<"minProperties">> => 1},
      #{}, [], {size_bound, <<"minProperties">>}).

array_string_and_number_bounds_test() ->
    ArraySchema = #{<<"type">> => <<"array">>,
                    <<"minItems">> => 1, <<"maxItems">> => 2,
                    <<"items">> => #{<<"type">> => <<"integer">>}},
    ?assertEqual({ok, [1, 2]},
                 adk_json_schema:validate(ArraySchema, [1, 2])),
    assert_value_error(ArraySchema, [], [],
                       {size_bound, <<"minItems">>}),
    assert_value_error(ArraySchema, [1, 2, 3], [],
                       {size_bound, <<"maxItems">>}),
    assert_value_error(ArraySchema, [1, <<"two">>], [1],
                       {expected_type, <<"integer">>}),

    StringSchema = #{<<"type">> => <<"string">>,
                     <<"minLength">> => 2, <<"maxLength">> => 4,
                     <<"pattern">> => <<"^[a-z]+$">>},
    ?assertEqual({ok, <<"okay">>},
                 adk_json_schema:validate(StringSchema, <<"okay">>)),
    assert_value_error(StringSchema, <<"a">>, [],
                       {size_bound, <<"minLength">>}),
    assert_value_error(StringSchema, <<"longer">>, [],
                       {size_bound, <<"maxLength">>}),
    assert_value_error(StringSchema, <<"12">>, [], pattern_mismatch),

    NumberSchema = #{<<"type">> => <<"number">>,
                     <<"minimum">> => 1, <<"maximum">> => 10,
                     <<"exclusiveMinimum">> => 0,
                     <<"exclusiveMaximum">> => 11},
    ?assertEqual({ok, 5}, adk_json_schema:validate(NumberSchema, 5)),
    [assert_value_error(NumberSchema#{Keyword => Bound}, Value, [],
                        {numeric_bound, Keyword})
     || {Keyword, Bound, Value} <-
            [{<<"minimum">>, 2, 1}, {<<"maximum">>, 4, 5},
             {<<"exclusiveMinimum">>, 5, 5},
             {<<"exclusiveMaximum">>, 5, 5}]].

invalid_json_value_is_structural_test() ->
    ?assertMatch(
       {error, {invalid_json_value, {unsupported_json_term, _, _}}},
       adk_json_schema:validate_compiled(true, make_ref())),
    ?assertMatch(
       {error, {invalid_json_value, {invalid_utf8, _}}},
       adk_json_schema:validate_compiled(true, <<16#ff>>)),
    ?assertMatch(
       {error, {invalid_json_value, {invalid_map_key, _, _}}},
       adk_json_schema:validate_compiled(true, #{42 => true})).

object_schema() ->
    #{<<"type">> => <<"object">>,
      <<"properties">> =>
          #{<<"name">> => #{<<"type">> => <<"string">>},
            <<"age">> => #{<<"type">> => <<"integer">>,
                           <<"minimum">> => 0}},
      <<"required">> => [<<"name">>],
      <<"additionalProperties">> => false,
      <<"minProperties">> => 1,
      <<"maxProperties">> => 2}.

valid_object() ->
    #{<<"name">> => <<"Ada">>, <<"age">> => 37}.

assert_compile_error(Schema, Path, Reason) ->
    ?assertEqual(
       {error, {invalid_json_schema, Path, Reason}},
       adk_json_schema:compile(Schema)).

assert_value_error(Schema, Value, Path, Reason) ->
    ?assertEqual(
       {error, {schema_validation_failed, Path, Reason}},
       adk_json_schema:validate(Schema, Value)).
