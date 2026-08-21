-module(erlang_adk_google_test).

-include_lib("eunit/include/eunit.hrl").

native_google_connector_test() ->
    {ok, Toolset} = erlang_adk_google:new(
                      descriptor(),
                      {erlang_adk_google_test_backend, self()}),
    Args = #{<<"query">> => <<"Erlang OTP">>},
    {ok, {resolved, Call}} = adk_toolset:resolve(
                               [Toolset], <<"google_search">>, Args, #{}),
    ?assertEqual(true, maps:get(parallel_safe, Call)),
    ?assertEqual(#{required => false}, maps:get(confirmation, Call)),
    ?assertMatch({ok, _}, (maps:get(execute, Call))()),
    receive
        {google_invoked, google_search, Args,
         #{credential_ref := #{id := <<"google_workload_prod">>}}} -> ok
    after 1000 -> error(google_backend_not_invoked)
    end,
    VertexArgs = #{<<"model_ref">> => <<"vertex_model_prod">>,
                   <<"prompt">> => <<"Summarize this result">>},
    {ok, {resolved, Vertex}} = adk_toolset:resolve(
                                 [Toolset],
                                 <<"vertex_generate_content">>,
                                 VertexArgs, #{}),
    ?assertEqual(true, maps:get(parallel_safe, Vertex)),
    ?assertEqual(#{required => false}, maps:get(confirmation, Vertex)),
    ?assertMatch({ok, _}, (maps:get(execute, Vertex))()),
    receive
        {google_invoked, vertex_generate_content, VertexArgs,
         #{service_ref := #{kind := native,
                            id := <<"google_services_prod">>}}} -> ok
    after 1000 -> error(vertex_backend_not_invoked)
    end.

operator_registry_agent_config_round_trip_test() ->
    {ok, Toolset} = erlang_adk_google:new(
                      descriptor(),
                      {erlang_adk_google_test_backend, self()}),
    {ok, Registry} = adk_config_registry:new(
                       #{credentials =>
                             #{<<"google_workload_prod">> =>
                                   #{profile =>
                                         <<"google_workload_prod">>}},
                         tool_packs =>
                             #{<<"google-curated">> =>
                                   #{tools => [Toolset]}}}),
    {ok, Compiled} = adk_agent_config:compile(
                       agent_config(<<"google-curated">>),
                       #{registry => Registry}),
    [ConfiguredToolset] = maps:get(tools, Compiled),
    Args = #{<<"query">> => <<"OTP supervision trees">>},
    {ok, {resolved, Call}} = adk_toolset:resolve(
                               [ConfiguredToolset],
                               <<"google_search">>, Args, #{}),
    ?assertMatch({ok, _}, (maps:get(execute, Call))()),
    receive
        {google_invoked, google_search, Args, _Descriptor} -> ok
    after 1000 -> error(configured_google_backend_not_invoked)
    end,
    assert_policy(<<"google_search">>,
                  [<<"google.search:query">>], read, never, true),
    assert_policy(<<"vertex_generate_content">>,
                  [<<"google.vertex:invoke">>], none, never, true).

raw_credentials_are_not_accepted_test() ->
    Invalid = (descriptor())#{token => <<"secret">>},
    ?assertEqual(
       {error, invalid_connector_descriptor_keys},
       erlang_adk_google:new(
         Invalid, {erlang_adk_google_test_backend, self()})).

descriptor() ->
    #{connector_id => <<"google_prod">>,
      service_ref => #{kind => native, id => <<"google_services_prod">>},
      credential_ref => #{kind => credential,
                          id => <<"google_workload_prod">>}}.

agent_config(ToolPackId) ->
    #{<<"schema_version">> => 2,
      <<"name">> => <<"GoogleConnectorAgent">>,
      <<"provider">> => <<"gemini">>,
      <<"credential_profile">> => <<"google_workload_prod">>,
      <<"toolsets">> =>
          [#{<<"kind">> => <<"tool_pack">>, <<"id">> => ToolPackId}]}.

assert_policy(Name, Permissions, SideEffect, Confirmation, ParallelSafe) ->
    Policy = lists:keyfind(
               Name, 1,
               [{maps:get(name, Tool), Tool}
                || Tool <- maps:get(tools, erlang_adk_google:manifest())]),
    {Name, Values} = Policy,
    ?assertEqual(Permissions, maps:get(permissions, Values)),
    ?assertEqual(SideEffect, maps:get(side_effect, Values)),
    ?assertEqual(Confirmation, maps:get(confirmation, Values)),
    ?assertEqual(ParallelSafe, maps:get(parallel_safe, Values)).
