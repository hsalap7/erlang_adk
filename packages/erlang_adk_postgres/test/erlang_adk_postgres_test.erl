-module(erlang_adk_postgres_test).

-include_lib("eunit/include/eunit.hrl").

prepared_statement_boundary_test() ->
    {ok, Toolset} = erlang_adk_postgres:new(
                      descriptor(),
                      {erlang_adk_postgres_test_backend, self()}),
    Args = #{<<"statement_id">> => <<"users.by_id">>,
             <<"parameters">> => [<<"42">>]},
    {ok, {resolved, Query}} = adk_toolset:resolve(
                                [Toolset],
                                <<"postgres_query_prepared">>, Args, #{}),
    ?assertEqual(true, maps:get(parallel_safe, Query)),
    ?assertEqual(#{required => false}, maps:get(confirmation, Query)),
    ?assertMatch({ok, _}, (maps:get(execute, Query))()),
    receive
        {postgres_executed, query, <<"users.by_id">>, [<<"42">>],
         _Descriptor} -> ok
    after 1000 -> error(postgres_backend_not_invoked)
    end,
    MutationArgs = #{<<"statement_id">> => <<"users.rename">>,
                     <<"parameters">> => [<<"42">>, <<"Ada">>]},
    {ok, {resolved, Mutation}} = adk_toolset:resolve(
                                   [Toolset],
                                   <<"postgres_execute_prepared">>,
                                   MutationArgs, #{}),
    ?assertEqual(false, maps:get(parallel_safe, Mutation)),
    ?assertEqual(#{required => true}, maps:get(confirmation, Mutation)),
    ?assertMatch({ok, _}, (maps:get(execute, Mutation))()),
    receive
        {postgres_executed, mutation, <<"users.rename">>,
         [<<"42">>, <<"Ada">>], _MutationDescriptor} -> ok
    after 1000 -> error(postgres_mutation_not_invoked)
    end.

operator_registry_agent_config_round_trip_test() ->
    {ok, Toolset} = erlang_adk_postgres:new(
                      descriptor(),
                      {erlang_adk_postgres_test_backend, self()}),
    {ok, Registry} = adk_config_registry:new(
                       #{credentials =>
                             #{<<"postgres_role_prod">> =>
                                   #{profile => <<"postgres_role_prod">>}},
                         tool_packs =>
                             #{<<"postgres-curated">> =>
                                   #{tools => [Toolset]}}}),
    {ok, Compiled} = adk_agent_config:compile(
                       agent_config(<<"postgres-curated">>),
                       #{registry => Registry}),
    [ConfiguredToolset] = maps:get(tools, Compiled),
    Args = #{<<"statement_id">> => <<"users.recent">>,
             <<"parameters">> => []},
    {ok, {resolved, Call}} = adk_toolset:resolve(
                               [ConfiguredToolset],
                               <<"postgres_query_prepared">>, Args, #{}),
    ?assertMatch({ok, _}, (maps:get(execute, Call))()),
    receive
        {postgres_executed, query, <<"users.recent">>, [], _Descriptor} -> ok
    after 1000 -> error(configured_postgres_backend_not_invoked)
    end,
    assert_policy(<<"postgres_query_prepared">>,
                  [<<"postgres.statements:read">>], read, never, true),
    assert_policy(<<"postgres_execute_prepared">>,
                  [<<"postgres.statements:write">>], write, required, false).

sql_and_database_urls_are_not_model_arguments_test() ->
    {ok, Toolset} = erlang_adk_postgres:new(
                      descriptor(),
                      {erlang_adk_postgres_test_backend, self()}),
    {ok, [QuerySchema, MutationSchema]} = adk_toolset:schemas(Toolset),
    assert_no_unsafe_properties(QuerySchema),
    assert_no_unsafe_properties(MutationSchema),
    ?assertMatch(
       {error, {invalid_tool_arguments, _}},
       adk_toolset:resolve(
         [Toolset], <<"postgres_query_prepared">>,
         #{<<"statement_id">> => <<"users.by_id">>,
           <<"sql">> => <<"select * from users">>}, #{})).

assert_no_unsafe_properties(#{<<"parameters">> :=
                                  #{<<"properties">> := Properties}}) ->
    ?assertEqual(false, maps:is_key(<<"sql">>, Properties)),
    ?assertEqual(false, maps:is_key(<<"url">>, Properties)),
    ?assertEqual(false, maps:is_key(<<"password">>, Properties)).

descriptor() ->
    #{connector_id => <<"postgres_prod">>,
      service_ref => #{kind => native, id => <<"postgres_cluster_prod">>},
      credential_ref => #{kind => credential,
                          id => <<"postgres_role_prod">>}}.

agent_config(ToolPackId) ->
    #{<<"schema_version">> => 2,
      <<"name">> => <<"PostgresConnectorAgent">>,
      <<"provider">> => <<"gemini">>,
      <<"credential_profile">> => <<"postgres_role_prod">>,
      <<"toolsets">> =>
          [#{<<"kind">> => <<"tool_pack">>, <<"id">> => ToolPackId}]}.

assert_policy(Name, Permissions, SideEffect, Confirmation, ParallelSafe) ->
    Policy = lists:keyfind(
               Name, 1,
               [{maps:get(name, Tool), Tool}
                || Tool <- maps:get(tools, erlang_adk_postgres:manifest())]),
    {Name, Values} = Policy,
    ?assertEqual(Permissions, maps:get(permissions, Values)),
    ?assertEqual(SideEffect, maps:get(side_effect, Values)),
    ?assertEqual(Confirmation, maps:get(confirmation, Values)),
    ?assertEqual(ParallelSafe, maps:get(parallel_safe, Values)).
