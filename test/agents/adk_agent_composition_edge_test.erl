-module(adk_agent_composition_edge_test).

-include_lib("eunit/include/eunit.hrl").

public_boundaries_reject_invalid_values_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    {ok, Registry} = adk_config_registry:new(),
    {ok, Compiled} = adk_agent_config:compile(base_json()),
    ?assertEqual({error, invalid_compiled_agent_config},
                 adk_agent_composition:resolve(not_compiled, Registry)),
    ?assertEqual({error, invalid_compiled_agent_config},
                 adk_agent_composition:resolve(#{schema_version => 99},
                                               Registry)),
    ?assertEqual({error, invalid_agent_composition_scope},
                 adk_agent_composition:spawn_scoped(Compiled, Registry, <<>>)),
    ?assertEqual({error, invalid_agent_composition_scope},
                 adk_agent_composition:spawn_scoped(
                   Compiled, Registry, <<"not-valid-scope">>)),
    ?assertEqual({error, invalid_agent_composition_scope},
                 adk_agent_composition:spawn_scoped(Compiled, Registry,
                                                    not_binary)),
    ?assertEqual({error, invalid_agent_composition},
                 adk_agent_composition:root(#{})),
    ?assertEqual({error, invalid_agent_composition},
                 adk_agent_composition:runner_options(#{})),
    ?assertEqual({error, invalid_agent_composition},
                 adk_agent_composition:workflows(#{})),
    ?assertEqual({error, invalid_agent_composition},
                 adk_agent_composition:credential_profiles(#{})),
    ?assertEqual(ok, adk_agent_composition:stop(invalid_handle)).

default_registry_is_snapshot_bound_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Previous = application:get_env(erlang_adk, agent_config_registry),
    Definitions = #{providers => #{<<"probe">> => adk_llm_probe}},
    try
        ok = application:set_env(erlang_adk, agent_config_registry,
                                 Definitions),
        Json = (base_json())#{<<"schema_version">> => 2,
                              <<"provider">> => <<"probe">>},
        {ok, Compiled} = adk_agent_config:compile(Json),
        {ok, _Resolved} = adk_agent_composition:resolve(Compiled),
        {ok, Handle} = adk_agent_composition:spawn_scoped(
                         Compiled, <<"default_registry">>),
        ok = adk_agent_composition:stop(Handle),

        %% Rebuilding the same raw definitions produces a distinct sealed
        %% snapshot. A compiled IR must not silently cross that boundary.
        ok = application:set_env(erlang_adk, agent_config_registry,
                                 Definitions),
        ?assertEqual(
           {error, agent_config_registry_provenance_mismatch},
           adk_agent_composition:resolve(Compiled)),
        ok = application:set_env(erlang_adk, agent_config_registry,
                                 invalid_registry),
        ?assertEqual({error, agent_config_registry_unavailable},
                     adk_agent_composition:resolve(Compiled))
    after
        restore_env(Previous)
    end,
    {ok, Legacy} = adk_agent_config:compile(base_json()),
    {ok, LegacyResolved} = adk_agent_composition:resolve(Legacy),
    ?assertEqual([], maps:get(children, LegacyResolved)).

template_dependencies_materialize_bottom_up_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Definitions =
        #{providers => #{<<"probe">> => adk_llm_probe},
          agent_templates =>
              #{<<"leaf-id">> =>
                    #{template => template_json(<<"leaf">>)},
                <<"parent-template">> =>
                    #{template => template_json(<<"parent">>),
                      sub_agents => [<<"leaf-id">>]}}},
    {ok, Registry} = adk_config_registry:new(Definitions),
    Json = (base_json())#{
             <<"schema_version">> => 2,
             <<"provider">> => <<"probe">>,
             <<"sub_agents">> =>
                 [#{<<"name">> => <<"ParentAgent">>,
                    <<"agent_template">> => <<"parent-template">>}]},
    {ok, Compiled} = adk_agent_config:compile(Json,
                                              #{registry => Registry}),
    {ok, Resolved} = adk_agent_composition:resolve(Compiled, Registry),
    [Parent] = maps:get(children, Resolved),
    [Leaf] = maps:get(children, Parent),
    ?assertEqual(<<"sub_1_leaf_id">>,
                 maps:get(name, maps:get(compiled, Leaf))),
    {ok, Handle} = adk_agent_composition:spawn(Compiled, Registry),
    try
        {ok, Root} = adk_agent_composition:root(Handle),
        {ok, _RootName, _RootConfig, _RootTools, RootChildren} =
            gen_server:call(Root, get_runtime),
        #{<<"ParentAgent">> := #{pid := ParentPid}} = RootChildren,
        {ok, <<"ParentAgent">>, _ParentConfig, _ParentTools,
         ParentChildren} = gen_server:call(ParentPid, get_runtime),
        #{<<"sub_1_leaf_id">> := #{pid := LeafPid}} = ParentChildren,
        ?assert(is_process_alive(LeafPid)),
        ?assertEqual({ok, #{}},
                     adk_agent_composition:credential_profiles(Handle))
    after
        ok = adk_agent_composition:stop(Handle)
    end.

reference_resolution_errors_fail_closed_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    {ok, Registry} = adk_config_registry:new(
                       #{providers => #{<<"probe">> => adk_llm_probe},
                         agent_templates =>
                             #{<<"leaf">> =>
                                   #{template => template_json(<<"leaf">>)}}}),
    Json = (base_json())#{<<"schema_version">> => 2,
                          <<"provider">> => <<"probe">>},
    {ok, Compiled} = adk_agent_config:compile(Json,
                                              #{registry => Registry}),
    ?assertEqual(
       {error, {unknown_runtime_policy, <<"missing-policy">>}},
       adk_agent_composition:resolve(
         with_refs(Compiled,
                   #{runtime_policy => <<"missing-policy">>}), Registry)),
    ?assertEqual(
       {error, {unknown_workflow, <<"missing-workflow">>}},
       adk_agent_composition:resolve(
         with_refs(Compiled,
                   #{workflows =>
                         [#{name => <<"main">>,
                            workflow => <<"missing-workflow">>}]}), Registry)),
    ?assertEqual(
       {error, invalid_agent_composition_workflows},
       adk_agent_composition:resolve(
         with_refs(Compiled, #{workflows => invalid}), Registry)),
    ?assertEqual(
       {error, {unknown_agent_template, <<"missing-template">>}},
       adk_agent_composition:resolve(
         with_refs(Compiled,
                   #{sub_agents =>
                         [child_ref(<<"ChildAgent">>,
                                    <<"missing-template">>, [])]}), Registry)),
    ?assertEqual(
       {error, invalid_agent_composition_children},
       adk_agent_composition:resolve(
         with_refs(Compiled, #{sub_agents => [invalid]}), Registry)),
    ?assertEqual(
       {error, {agent_composition_cycle, <<"ConfigCompilerAgent">>}},
       adk_agent_composition:resolve(
         with_refs(Compiled,
                   #{sub_agents =>
                         [child_ref(<<"ConfigCompilerAgent">>,
                                    <<"leaf">>, [])]}), Registry)).

partial_tree_is_cleaned_when_a_later_child_cannot_start_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    {ok, Registry} = adk_config_registry:new(
                       #{providers => #{<<"probe">> => adk_llm_probe},
                         agent_templates =>
                             #{<<"leaf">> =>
                                   #{template => template_json(<<"leaf">>)}}}),
    Json = (base_json())#{
             <<"schema_version">> => 2,
             <<"provider">> => <<"probe">>,
             <<"sub_agents">> =>
                 [#{<<"name">> => <<"CleanupChildOne">>,
                    <<"agent_template">> => <<"leaf">>},
                  #{<<"name">> => <<"CleanupChildTwo">>,
                    <<"agent_template">> => <<"leaf">>}]},
    {ok, Compiled} = adk_agent_config:compile(Json,
                                              #{registry => Registry}),
    {ok, Blocker} = erlang_adk:spawn_agent(
                      <<"CleanupChildTwo">>,
                      #{provider => adk_llm_probe,
                        model => <<"probe">>, response => <<"block">>}, []),
    try
        ?assertMatch({error, {agent_start_failed, _}},
                     adk_agent_composition:spawn(Compiled, Registry)),
        await_absent(<<"CleanupChildOne">>, 1000),
        ?assertEqual({ok, Blocker},
                     adk_agent_registry:lookup(<<"CleanupChildTwo">>))
    after
        _ = catch erlang_adk:stop_agent(Blocker)
    end.

scoped_long_name_is_deterministic_and_bounded_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Name = binary:copy(<<"A">>, 250),
    {ok, Compiled} = adk_agent_config:compile(
                       (base_json())#{<<"name">> => Name}),
    {ok, Registry} = adk_config_registry:new(),
    {ok, Handle} = adk_agent_composition:spawn_scoped(
                     Compiled, Registry, <<"edge_scope">>),
    try
        {ok, Root} = adk_agent_composition:root(Handle),
        {ok, ScopedName, _Config, _Tools, _Children} =
            gen_server:call(Root, get_runtime),
        ?assertEqual(256, byte_size(ScopedName)),
        ?assertEqual({byte_size(ScopedName) - byte_size(<<"_edge_scope">>),
                      byte_size(<<"_edge_scope">>)},
                     binary:match(ScopedName, <<"_edge_scope">>)),
        ?assertNotEqual(nomatch, binary:match(ScopedName, <<"_">>))
    after
        ok = adk_agent_composition:stop(Handle)
    end.

base_json() ->
    #{<<"name">> => <<"ConfigCompilerAgent">>,
      <<"provider">> => <<"adk_llm_probe">>,
      <<"model">> => <<"probe">>,
      <<"response">> => <<"compiled">>}.

template_json(Response) ->
    #{<<"provider">> => <<"probe">>,
      <<"model">> => <<"probe">>,
      <<"response">> => Response}.

with_refs(Compiled, References) ->
    Compiled#{references => References}.

child_ref(Name, Template, Children) ->
    #{name => Name, agent_template => Template, sub_agents => Children}.

await_absent(Name, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_absent_until(Name, Deadline).

await_absent_until(Name, Deadline) ->
    case adk_agent_registry:lookup(Name) of
        {error, not_found} -> ok;
        {ok, _Pid} ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(5),
                    await_absent_until(Name, Deadline);
                false -> error({agent_still_registered, Name})
            end
    end.

restore_env({ok, Value}) ->
    application:set_env(erlang_adk, agent_config_registry, Value);
restore_env(undefined) ->
    application:unset_env(erlang_adk, agent_config_registry).
