-module(adk_connector_manifest_test).

-include_lib("eunit/include/eunit.hrl").

manifest_validation_test_() ->
    [fun accepts_complete_least_authority_manifest/0,
     fun rejects_unknown_and_missing_fields/0,
     fun rejects_unsafe_side_effect_policy/0,
     fun rejects_duplicate_or_invalid_permissions/0,
     fun requires_exact_schema_coverage/0,
     fun enforces_required_and_conditional_confirmation/0].

accepts_complete_least_authority_manifest() ->
    {ok, Manifest} = adk_connector_manifest:validate(valid_manifest()),
    {ok, Read} = adk_connector_manifest:tool(Manifest, <<"read_item">>),
    ?assertEqual(read, maps:get(side_effect, Read)),
    Description = adk_connector_manifest:describe(Manifest),
    ?assertEqual(<<"example">>, maps:get(<<"connector_id">>, Description)),
    ?assertEqual(2, length(maps:get(<<"tools">>, Description))).

rejects_unknown_and_missing_fields() ->
    ?assertEqual(
       {error, invalid_connector_manifest_keys},
       adk_connector_manifest:validate((valid_manifest())#{url => <<"https://bad">>})),
    Missing = maps:remove(tools, valid_manifest()),
    ?assertEqual({error, invalid_connector_manifest_keys},
                 adk_connector_manifest:validate(Missing)),
    [Read | Rest] = maps:get(tools, valid_manifest()),
    Invalid = (valid_manifest())#{tools =>
                                     [maps:remove(permissions, Read) | Rest]},
    ?assertEqual({error, invalid_connector_tool_keys},
                 adk_connector_manifest:validate(Invalid)).

rejects_unsafe_side_effect_policy() ->
    [Read, Write] = maps:get(tools, valid_manifest()),
    Never = Write#{confirmation => never},
    ?assertEqual({error, unsafe_connector_tool_policy},
                 adk_connector_manifest:validate(
                   (valid_manifest())#{tools => [Read, Never]})),
    ParallelWrite = Write#{parallel_safe => true},
    ?assertEqual({error, unsafe_connector_tool_policy},
                 adk_connector_manifest:validate(
                   (valid_manifest())#{tools => [Read, ParallelWrite]})),
    Destructive = Write#{side_effect => destructive,
                         confirmation => conditional},
    ?assertEqual({error, unsafe_connector_tool_policy},
                 adk_connector_manifest:validate(
                   (valid_manifest())#{tools => [Read, Destructive]})).

rejects_duplicate_or_invalid_permissions() ->
    [Read | Rest] = maps:get(tools, valid_manifest()),
    Duplicate = Read#{permissions => [<<"items:read">>, <<"items:read">>]},
    ?assertEqual({error, invalid_connector_permissions},
                 adk_connector_manifest:validate(
                   (valid_manifest())#{tools => [Duplicate | Rest]})),
    SecretLike = Read#{permissions => [<<"items/read">>]},
    ?assertEqual({error, invalid_connector_permissions},
                 adk_connector_manifest:validate(
                   (valid_manifest())#{tools => [SecretLike | Rest]})).

requires_exact_schema_coverage() ->
    {ok, Manifest} = adk_connector_manifest:validate(valid_manifest()),
    Schemas = [schema(<<"read_item">>), schema(<<"write_item">>)],
    ?assertEqual(ok, adk_connector_manifest:validate_schemas(Manifest, Schemas)),
    ?assertMatch(
       {error, {connector_manifest_schema_mismatch, _}},
       adk_connector_manifest:validate_schemas(
         Manifest, [schema(<<"read_item">>)])),
    ?assertEqual(
       {error, invalid_connector_schema_name},
       adk_connector_manifest:validate_schemas(
         Manifest, [schema(<<"read_item">>), schema(<<"read_item">>)])).

enforces_required_and_conditional_confirmation() ->
    [Read, Write] = maps:get(tools, valid_manifest()),
    Base = #{name => <<"write_item">>, args => #{},
             execute => fun() -> ok end},
    {ok, Required} = adk_connector_manifest:apply_execution_policy(Base, Write),
    ?assertEqual(true, maps:get(confirmation, Required)),
    ?assertEqual(false, maps:get(parallel_safe, Required)),
    ConditionalPolicy = Write#{confirmation => conditional},
    ?assertEqual(
       {error, connector_confirmation_decision_missing},
       adk_connector_manifest:apply_execution_policy(Base, ConditionalPolicy)),
    {ok, Conditional} = adk_connector_manifest:apply_execution_policy(
                          Base#{confirmation => false}, ConditionalPolicy),
    ?assertEqual(false, maps:get(confirmation, Conditional)),
    ReadCall = Base#{name => <<"read_item">>, confirmation => true},
    ?assertEqual(
       {error, connector_confirmation_policy_mismatch},
       adk_connector_manifest:apply_execution_policy(ReadCall, Read)).

valid_manifest() ->
    #{schema_version => 1,
      connector_id => <<"example">>,
      service => native,
      tools =>
          [#{name => <<"read_item">>,
             permissions => [<<"items:read">>],
             side_effect => read,
             confirmation => never,
             parallel_safe => true},
           #{name => <<"write_item">>,
             permissions => [<<"items:write">>],
             side_effect => write,
             confirmation => required,
             parallel_safe => false}]}.

schema(Name) ->
    #{<<"name">> => Name,
      <<"parameters">> => #{<<"type">> => <<"object">>}}.
