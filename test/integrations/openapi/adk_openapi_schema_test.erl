-module(adk_openapi_schema_test).

-include_lib("eunit/include/eunit.hrl").

json_value_validation_contract_test() ->
    Valid = #{<<"array">> => [1, 2.5, true, false, null, <<"text">>, #{}]},
    ?assertEqual(ok, adk_openapi_schema:validate_json(Valid, 8)),
    [?assertEqual({error, invalid_json_limit},
                  adk_openapi_schema:validate_json(Valid, Limit))
     || Limit <- [0, -1, invalid]],
    ?assertEqual({error, non_binary_json_key},
                 adk_openapi_schema:validate_json(#{atom_key => true}, 8)),
    ?assertEqual({error, non_json_value},
                 adk_openapi_schema:validate_json(an_atom, 8)),
    ?assertEqual({error, improper_json_list},
                 adk_openapi_schema:validate_json([1 | improper], 8)),
    ?assertEqual({error, invalid_utf8},
                 adk_openapi_schema:validate_json(<<16#ff>>, 8)),
    ?assertEqual({error, json_too_deep},
                 adk_openapi_schema:validate_json(
                   #{<<"outer">> => #{<<"inner">> => true}}, 1)).

reference_scan_contract_test() ->
    Local = #{<<"schema">> =>
                  [#{<<"$ref">> => <<"#/components/schemas/Pet">>},
                   #{<<"nested">> => true}]},
    ?assertEqual(ok, adk_openapi_schema:reject_remote_refs(Local, 8)),
    ?assertEqual(ok, adk_openapi_schema:reject_remote_refs(42, 8)),
    [?assertEqual({error, invalid_reference_limit},
                  adk_openapi_schema:reject_remote_refs(Local, Limit))
     || Limit <- [0, -1, invalid]],
    ?assertEqual({error, remote_reference_not_allowed},
                 adk_openapi_schema:reject_remote_refs(
                   #{<<"nested">> =>
                         [#{<<"$ref">> => <<"https://example.test/Pet">>}]},
                   8)),
    ?assertEqual({error, improper_json_list},
                 adk_openapi_schema:reject_remote_refs([#{} | bad], 8)),
    ?assertEqual({error, reference_scan_too_deep},
                 adk_openapi_schema:reject_remote_refs(
                   #{<<"outer">> => #{<<"inner">> => true}}, 1)).

object_reference_resolution_contract_test() ->
    Root = reference_root(),
    Inline = #{<<"type">> => <<"object">>},
    ?assertEqual({ok, Inline},
                 adk_openapi_schema:resolve_object(Root, Inline, #{})),
    ?assertEqual(
       {ok, #{<<"type">> => <<"string">>}},
       adk_openapi_schema:resolve_object(
         Root, #{<<"$ref">> => <<"#/components/schemas/Alias">>}, #{})),
    ?assertEqual(
       {ok, #{<<"escaped">> => true}},
       adk_openapi_schema:resolve_object(
         Root, #{<<"$ref">> => <<"#/a~1b~0c">>}, #{})),
    ?assertEqual(
       {ok, #{<<"index">> => 0}},
       adk_openapi_schema:resolve_object(
         Root, #{<<"$ref">> => <<"#/list/0">>}, #{})).

object_reference_error_contract_test() ->
    Root = reference_root(),
    [?assertEqual({error, invalid_reference_object}, Result)
     || Result <-
            [adk_openapi_schema:resolve_object(invalid, #{}, #{}),
             adk_openapi_schema:resolve_object(Root, invalid, #{}),
             adk_openapi_schema:resolve_object(
               Root,
               #{<<"$ref">> => <<"#/components/schemas/Pet">>,
                 <<"description">> => <<"sibling">>}, #{}),
             adk_openapi_schema:resolve_object(
               Root, #{<<"$ref">> => <<"https://example.test/Pet">>},
               #{})]],
    ?assertEqual(
       {error, cyclic_reference},
       adk_openapi_schema:resolve_object(
         Root, #{<<"$ref">> => <<"#/components/schemas/CycleA">>}, #{})),
    ?assertEqual(
       {error, reference_depth_exceeded},
       adk_openapi_schema:resolve_object(
         Root, #{<<"$ref">> => <<"#/components/schemas/Alias">>},
         #{max_schema_depth => 0})),
    PointerErrors =
        [{<<"#/missing">>, reference_not_found},
         {<<"#/list/00">>, reference_not_found},
         {<<"#/list/-1">>, reference_not_found},
         {<<"#/list/not-an-index">>, reference_not_found},
         {<<"#/list/9">>, reference_not_found},
         {<<"#/list/0/missing">>, reference_not_found},
         {<<"#/percent%20encoded">>, encoded_json_pointer_not_supported},
         {<<"#/invalid~2escape">>, invalid_json_pointer}],
    [?assertEqual(
        {error, Reason},
        adk_openapi_schema:resolve_object(
          Root, #{<<"$ref">> => Ref}, #{}))
     || {Ref, Reason} <- PointerErrors].

schema_compilation_resolves_and_prunes_annotations_test() ->
    Root = reference_root(),
    Schema =
        #{<<"type">> => <<"object">>,
          <<"properties">> =>
              #{<<"name">> =>
                    #{<<"$ref">> => <<"#/components/schemas/Pet">>},
                <<"tags">> =>
                    #{<<"type">> => <<"array">>,
                      <<"items">> =>
                          #{<<"$ref">> => <<"#/components/schemas/Pet">>}},
                <<"metadata">> =>
                    #{<<"type">> => <<"object">>,
                      <<"additionalProperties">> =>
                          #{<<"$ref">> => <<"#/components/schemas/Pet">>}},
                <<"choice">> =>
                    #{<<"oneOf">> =>
                          [true,
                           #{<<"$ref">> =>
                                 <<"#/components/schemas/Pet">>}] }},
          <<"allOf">> => [true, #{}],
          <<"anyOf">> => [false, #{}],
          <<"additionalProperties">> => false,
          <<"example">> => #{<<"private">> => <<"ignored">>},
          <<"deprecated">> => true,
          <<"externalDocs">> => #{<<"url">> => <<"ignored">>}},
    {ok, Compiled} = adk_openapi_schema:compile(Root, Schema, #{}),
    ?assertNot(maps:is_key(<<"example">>, Compiled)),
    ?assertNot(maps:is_key(<<"deprecated">>, Compiled)),
    ?assertNot(maps:is_key(<<"externalDocs">>, Compiled)),
    Properties = maps:get(<<"properties">>, Compiled),
    ?assertEqual(#{<<"type">> => <<"string">>},
                 maps:get(<<"name">>, Properties)),
    ?assertEqual(#{<<"type">> => <<"string">>},
                 maps:get(<<"items">>, maps:get(<<"tags">>, Properties))),
    ?assertEqual(
       #{<<"type">> => <<"string">>},
       maps:get(<<"additionalProperties">>,
                maps:get(<<"metadata">>, Properties))).

schema_compilation_error_contract_test() ->
    Root = reference_root(),
    ?assertEqual({error, invalid_openapi_schema},
                 adk_openapi_schema:compile(invalid, #{}, #{})),
    ?assertEqual({error, invalid_openapi_schema},
                 adk_openapi_schema:compile(Root, invalid, #{})),
    ?assertEqual(
       {error, {unsupported_schema_keyword, <<"unknown">>}},
       adk_openapi_schema:compile(Root, #{<<"unknown">> => true}, #{})),
    [?assertEqual(
        {error, invalid_schema_reference},
        adk_openapi_schema:compile(Root, Schema, #{}))
     || Schema <-
            [#{<<"$ref">> => <<"https://example.test/Pet">>},
             #{<<"$ref">> => <<"#/components/schemas/Pet">>,
               <<"description">> => <<"sibling">>}]],
    ?assertEqual(
       {error, cyclic_schema_reference},
       adk_openapi_schema:compile(
         Root, #{<<"$ref">> => <<"#/components/schemas/CycleA">>}, #{})),
    ?assertEqual(
       {error, schema_depth_exceeded},
       adk_openapi_schema:compile(
         Root, #{<<"$ref">> => <<"#/components/schemas/Alias">>},
         #{max_schema_depth => 0})),
    ?assertEqual(
       {error, invalid_schema_list},
       adk_openapi_schema:compile(
         Root, #{<<"oneOf">> => [#{} | improper]}, #{})),
    [?assertEqual(
        {error, invalid_openapi_schema},
        adk_openapi_schema:compile(Root, Schema, #{}))
     || Schema <-
            [#{<<"type">> => <<"not-a-json-schema-type">>},
             #{<<"properties">> => not_a_map},
             #{<<"properties">> => #{<<"bad">> => invalid}},
             #{<<"allOf">> => not_a_list}]],
    [?assertEqual(
        {error, Reason},
        adk_openapi_schema:compile(Root, #{<<"$ref">> => Ref}, #{}))
     || {Ref, Reason} <-
            [{<<"#/missing">>, reference_not_found},
             {<<"#/percent%20encoded">>,
              encoded_json_pointer_not_supported},
             {<<"#/invalid~2escape">>, invalid_json_pointer}]].

reference_root() ->
    #{<<"components">> =>
          #{<<"schemas">> =>
                #{<<"Pet">> => #{<<"type">> => <<"string">>},
                  <<"Alias">> =>
                      #{<<"$ref">> => <<"#/components/schemas/Pet">>},
                  <<"CycleA">> =>
                      #{<<"$ref">> => <<"#/components/schemas/CycleB">>},
                  <<"CycleB">> =>
                      #{<<"$ref">> => <<"#/components/schemas/CycleA">>}}},
      <<"a/b~c">> => #{<<"escaped">> => true},
      <<"list">> => [#{<<"index">> => 0}]}.
