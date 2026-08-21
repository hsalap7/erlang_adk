-module(erlang_adk_github_test).

-include_lib("eunit/include/eunit.hrl").

mcp_read_and_write_policy_test() ->
    {ok, Toolset} = erlang_adk_github:new(
                      descriptor(), {erlang_adk_github_test_mcp, self()}),
    SearchArgs = #{<<"query">> => <<"language:erlang">>},
    {ok, {resolved, Search}} = adk_toolset:resolve(
                                 [Toolset],
                                 <<"github_search_repositories">>,
                                 SearchArgs, #{}),
    ?assertEqual(true, maps:get(parallel_safe, Search)),
    ?assertEqual(#{required => false}, maps:get(confirmation, Search)),
    {ok, {resolved, Create}} = adk_toolset:resolve(
                                 [Toolset], <<"github_create_issue">>,
                                 #{<<"owner">> => <<"o">>,
                                   <<"repo">> => <<"r">>,
                                   <<"title">> => <<"t">>}, #{}),
    ?assertEqual(false, maps:get(parallel_safe, Create)),
    ?assertEqual(#{required => true}, maps:get(confirmation, Create)),
    ?assertMatch({ok, _}, (maps:get(execute, Search))()),
    receive
        {github_mcp_call, <<"search_repositories">>, SearchArgs} -> ok
    after 1000 -> error(github_mcp_not_invoked)
    end,
    CreateArgs = #{<<"owner">> => <<"o">>,
                   <<"repo">> => <<"r">>,
                   <<"title">> => <<"t">>},
    ?assertMatch({ok, _}, (maps:get(execute, Create))()),
    receive
        {github_mcp_call, <<"create_issue">>, CreateArgs} -> ok
    after 1000 -> error(github_mcp_mutation_not_invoked)
    end.

operator_registry_agent_config_round_trip_test() ->
    {ok, Toolset} = erlang_adk_github:new(
                      descriptor(), {adk_mcp_client, self()}),
    %% A real core MCP client is accepted at construction time. For the
    %% deterministic execution below use the package fixture because this
    %% process is not a running MCP gen_server.
    {ok, ExecutableToolset} = erlang_adk_github:new(
                                descriptor(),
                                {erlang_adk_github_test_mcp, self()}),
    ?assert(adk_toolset:is_descriptor(Toolset)),
    {ok, Registry} = adk_config_registry:new(
                       #{credentials =>
                             #{<<"github_app_prod">> =>
                                   #{profile => <<"github_app_prod">>}},
                         tool_packs =>
                             #{<<"github-curated">> =>
                                   #{tools => [ExecutableToolset]}}}),
    {ok, Compiled} = adk_agent_config:compile(
                       agent_config(<<"github-curated">>),
                       #{registry => Registry}),
    [ConfiguredToolset] = maps:get(tools, Compiled),
    Args = #{<<"query">> => <<"topic:erlang">>},
    {ok, {resolved, Call}} = adk_toolset:resolve(
                               [ConfiguredToolset],
                               <<"github_search_repositories">>, Args, #{}),
    ?assertMatch({ok, _}, (maps:get(execute, Call))()),
    receive
        {github_mcp_call, <<"search_repositories">>, Args} -> ok
    after 1000 -> error(configured_github_mcp_not_invoked)
    end,
    assert_policy(<<"github_search_repositories">>,
                  [<<"github.repositories:read">>], read, never, true),
    assert_policy(<<"github_create_issue">>,
                  [<<"github.issues:write">>], write, required, false).

credential_profile_is_mandatory_test() ->
    NoCredential = (descriptor())#{credential_ref => none},
    ?assertEqual(
       {error, github_credential_profile_required},
       erlang_adk_github:new(
         NoCredential, {erlang_adk_github_test_mcp, self()})).

descriptor() ->
    #{connector_id => <<"github_prod">>,
      service_ref => #{kind => mcp, id => <<"github_mcp_prod">>},
      credential_ref => #{kind => credential,
                          id => <<"github_app_prod">>}}.

agent_config(ToolPackId) ->
    #{<<"schema_version">> => 2,
      <<"name">> => <<"GithubConnectorAgent">>,
      <<"provider">> => <<"gemini">>,
      <<"credential_profile">> => <<"github_app_prod">>,
      <<"toolsets">> =>
          [#{<<"kind">> => <<"tool_pack">>, <<"id">> => ToolPackId}]}.

assert_policy(Name, Permissions, SideEffect, Confirmation, ParallelSafe) ->
    Policy = lists:keyfind(
               Name, 1,
               [{maps:get(name, Tool), Tool}
                || Tool <- maps:get(tools, erlang_adk_github:manifest())]),
    {Name, Values} = Policy,
    ?assertEqual(Permissions, maps:get(permissions, Values)),
    ?assertEqual(SideEffect, maps:get(side_effect, Values)),
    ?assertEqual(Confirmation, maps:get(confirmation, Values)),
    ?assertEqual(ParallelSafe, maps:get(parallel_safe, Values)).
