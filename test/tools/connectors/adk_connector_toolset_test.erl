-module(adk_connector_toolset_test).

-include_lib("eunit/include/eunit.hrl").

connector_toolset_test_() ->
    [fun rejects_manifest_catalog_drift/0,
     fun injects_policy_before_execution/0,
     fun fails_closed_when_conditional_decision_is_missing/0].

rejects_manifest_catalog_drift() ->
    Handle = #{names => [<<"read_item">>], target => self(), decisions => #{}},
    ?assertMatch(
       {error, {connector_manifest_schema_mismatch, _}},
       adk_connector_toolset:new(
         adk_connector_test_adapter, Handle, manifest())).

injects_policy_before_execution() ->
    Handle = handle(#{<<"write_item">> => false}),
    {ok, Descriptor} = adk_connector_toolset:new(
                         adk_connector_test_adapter, Handle, manifest()),
    {ok, {resolved, ReadCall}} = adk_toolset:resolve(
                                   [Descriptor], <<"read_item">>, #{}, #{}),
    ?assertEqual(true, maps:get(parallel_safe, ReadCall)),
    ?assertEqual(#{required => false}, maps:get(confirmation, ReadCall)),
    {ok, {resolved, WriteCall}} = adk_toolset:resolve(
                                    [Descriptor], <<"write_item">>, #{}, #{}),
    ?assertEqual(false, maps:get(parallel_safe, WriteCall)),
    ?assertEqual(#{required => true}, maps:get(confirmation, WriteCall)),
    receive
        {connector_resolved, <<"read_item">>, #{}, #{}} -> ok
    after 1000 -> error(read_connector_not_resolved)
    end,
    receive
        {connector_resolved, <<"write_item">>, #{}, #{}} -> ok
    after 1000 -> error(write_connector_not_resolved)
    end.

fails_closed_when_conditional_decision_is_missing() ->
    [Read, Write] = maps:get(tools, manifest()),
    Conditional = (manifest())#{tools =>
                                    [Read,
                                     Write#{confirmation => conditional}]},
    {ok, Descriptor} = adk_connector_toolset:new(
                         adk_connector_test_adapter, handle(#{}), Conditional),
    ?assertEqual(
       {error, connector_confirmation_decision_missing},
       adk_toolset:resolve([Descriptor], <<"write_item">>, #{}, #{})).

handle(Decisions) ->
    #{names => [<<"read_item">>, <<"write_item">>],
      target => self(),
      decisions => Decisions}.

manifest() ->
    #{schema_version => 1,
      connector_id => <<"test_connector">>,
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
