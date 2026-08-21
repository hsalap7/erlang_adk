-module(erlang_adk_slack_test).

-include_lib("eunit/include/eunit.hrl").

openapi_read_and_post_policy_test() ->
    {ok, Toolset} = erlang_adk_slack:new(
                      descriptor(),
                      {erlang_adk_slack_test_openapi, self()}),
    Args = #{<<"channel">> => <<"C123">>, <<"text">> => <<"hello">>},
    InvocationContext = #{session => should_not_cross_http_boundary},
    {ok, {resolved, Post}} = adk_toolset:resolve(
                               [Toolset], <<"slack_post_message">>, Args,
                               InvocationContext),
    ?assertEqual(false, maps:get(parallel_safe, Post)),
    ?assertEqual(#{required => true}, maps:get(confirmation, Post)),
    receive
        {slack_openapi_resolved, <<"slack_post_message">>, Args, #{}} -> ok
    after 1000 -> error(slack_openapi_not_resolved)
    end,
    ?assertMatch({ok, _}, (maps:get(execute, Post))()),
    receive
        {slack_openapi_executed, <<"slack_post_message">>, Args} -> ok
    after 1000 -> error(slack_openapi_post_not_executed)
    end,
    SearchArgs = #{<<"query">> => <<"incident">>},
    {ok, {resolved, Search}} = adk_toolset:resolve(
                                 [Toolset], <<"slack_search_messages">>,
                                 SearchArgs, InvocationContext),
    ?assertEqual(true, maps:get(parallel_safe, Search)),
    ?assertEqual(#{required => false}, maps:get(confirmation, Search)),
    receive
        {slack_openapi_resolved, <<"slack_search_messages">>,
         SearchArgs, #{}} -> ok
    after 1000 -> error(slack_openapi_search_not_resolved)
    end,
    ?assertMatch({ok, _}, (maps:get(execute, Search))()),
    receive
        {slack_openapi_executed, <<"slack_search_messages">>, SearchArgs} -> ok
    after 1000 -> error(slack_openapi_search_not_executed)
    end.

operator_registry_agent_config_round_trip_test() ->
    {ok, Toolset} = erlang_adk_slack:new(
                      descriptor(),
                      {erlang_adk_slack_test_openapi, self()}),
    {ok, Registry} = adk_config_registry:new(
                       #{credentials =>
                             #{<<"slack_bot_prod">> =>
                                   #{profile => <<"slack_bot_prod">>}},
                         tool_packs =>
                             #{<<"slack-curated">> =>
                                   #{tools => [Toolset]}}}),
    {ok, Compiled} = adk_agent_config:compile(
                       agent_config(<<"slack-curated">>),
                       #{registry => Registry}),
    [ConfiguredToolset] = maps:get(tools, Compiled),
    Args = #{<<"query">> => <<"release">>},
    {ok, {resolved, Call}} = adk_toolset:resolve(
                               [ConfiguredToolset],
                               <<"slack_search_messages">>, Args, #{}),
    receive
        {slack_openapi_resolved, <<"slack_search_messages">>, Args, #{}} -> ok
    after 1000 -> error(configured_slack_openapi_not_resolved)
    end,
    ?assertMatch({ok, _}, (maps:get(execute, Call))()),
    receive
        {slack_openapi_executed, <<"slack_search_messages">>, Args} -> ok
    after 1000 -> error(configured_slack_openapi_not_executed)
    end,
    assert_policy(<<"slack_search_messages">>,
                  [<<"slack.messages:read">>], read, never, true),
    assert_policy(<<"slack_post_message">>,
                  [<<"slack.messages:write">>], external_action,
                  required, false).

catalog_extensions_fail_closed_test() ->
    ?assertMatch(
       {error, {connector_manifest_schema_mismatch, _}},
       erlang_adk_slack:new(
         descriptor(), {erlang_adk_slack_extra_toolset, self()})).

descriptor() ->
    #{connector_id => <<"slack_prod">>,
      service_ref => #{kind => openapi, id => <<"slack_openapi_prod">>},
      credential_ref => #{kind => credential,
                          id => <<"slack_bot_prod">>}}.

agent_config(ToolPackId) ->
    #{<<"schema_version">> => 2,
      <<"name">> => <<"SlackConnectorAgent">>,
      <<"provider">> => <<"gemini">>,
      <<"credential_profile">> => <<"slack_bot_prod">>,
      <<"toolsets">> =>
          [#{<<"kind">> => <<"tool_pack">>, <<"id">> => ToolPackId}]}.

assert_policy(Name, Permissions, SideEffect, Confirmation, ParallelSafe) ->
    Policy = lists:keyfind(
               Name, 1,
               [{maps:get(name, Tool), Tool}
                || Tool <- maps:get(tools, erlang_adk_slack:manifest())]),
    {Name, Values} = Policy,
    ?assertEqual(Permissions, maps:get(permissions, Values)),
    ?assertEqual(SideEffect, maps:get(side_effect, Values)),
    ?assertEqual(Confirmation, maps:get(confirmation, Values)),
    ?assertEqual(ParallelSafe, maps:get(parallel_safe, Values)).
