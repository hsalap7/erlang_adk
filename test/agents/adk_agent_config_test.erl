-module(adk_agent_config_test).

-include_lib("eunit/include/eunit.hrl").

legacy_config_has_stable_versioned_fingerprint_test() ->
    Legacy = base_config(),
    Explicit = Legacy#{<<"schema_version">> => 1},
    {ok, First} = adk_agent_config:compile(Legacy),
    {ok, Second} = adk_agent_config:compile(Explicit),
    ?assertEqual(1, maps:get(schema_version, First)),
    ?assertEqual(1, maps:get(registry_generation, First)),
    Fingerprint = maps:get(fingerprint, First),
    ?assertEqual(64, byte_size(Fingerprint)),
    ?assertEqual(Fingerprint, maps:get(fingerprint, Second)),
    ?assertEqual({ok, Fingerprint}, adk_agent_config:fingerprint(First)),
    ?assertEqual(adk_llm_probe, maps:get(provider, First)).

strict_version_unknown_field_and_boundary_rejection_test() ->
    Base = base_config(),
    ?assertEqual(
       {error, {unsupported_agent_config_version, 3}},
       adk_agent_config:compile(Base#{<<"schema_version">> => 3})),
    ?assertEqual(
       {error, invalid_agent_config_version},
       adk_agent_config:compile(Base#{<<"schema_version">> => <<"1">>})),
    ?assertMatch(
       {error, {unknown_agent_config_keys, [<<"mcp">>]}},
       adk_agent_config:compile(Base#{<<"mcp">> => <<"server-id">>})),
    ?assertEqual(
       {error, secret_in_config_file},
       adk_agent_config:compile(
         Base#{<<"generation_config">> =>
                   #{<<"client_secret">> => <<"must-not-compile">>}})),
    ?assertEqual(
       {error, raw_transport_in_config_file},
       adk_agent_config:compile(
         Base#{<<"generation_config">> =>
                   #{<<"base_url">> => <<"https://attacker.invalid">>}})).

schema_property_names_do_not_create_transport_authority_test() ->
    Config = (base_config())#{
        <<"input_schema">> =>
            #{<<"type">> => <<"object">>,
              <<"properties">> =>
                  #{<<"url">> => #{<<"type">> => <<"string">>}},
              <<"additionalProperties">> => false}},
    {ok, Compiled} = adk_agent_config:compile(Config),
    ?assertEqual(1, maps:get(schema_version, Compiled)).

unknown_tool_names_do_not_create_atoms_test() ->
    {ok, _Warm} = adk_agent_config:compile(base_config()),
    CountBefore = erlang:system_info(atom_count),
    Unknown = <<"adk_never_loaded_tool_",
                (integer_to_binary(
                   erlang:unique_integer([positive, monotonic])))/binary>>,
    ?assertEqual(
       {error, {unknown_tool_module, Unknown}},
       adk_agent_config:compile(
         (base_config())#{<<"tools">> => [Unknown]},
         #{allow_legacy_module_tools => true})),
    ?assertEqual(CountBefore, erlang:system_info(atom_count)).

trusted_registry_snapshot_and_generation_test() ->
    {ok, Toolset} = adk_toolset:new(adk_test_toolset, self()),
    Definitions = registry_definitions(Toolset, adk_llm_probe),
    {ok, Registry1} = adk_config_registry:new(Definitions),
    {ok, Snapshot1} = adk_config_registry:snapshot(Registry1),
    ?assertEqual({ok, 1}, adk_config_registry:generation(Snapshot1)),
    {ok, Description1} = adk_config_registry:describe(Snapshot1),
    ?assertEqual(
       #{provider => 1, mcp => 1, openapi => 1,
         tool_pack => 1, credential => 0, runtime_policy => 0,
         workflow => 0, agent_template => 0},
       maps:get(counts, Description1)),

    {ok, Registry2} = adk_config_registry:replace(
                        Registry1,
                        registry_definitions(Toolset, adk_llm_gemini)),
    {ok, Snapshot2} = adk_config_registry:snapshot(Registry2),
    ?assertEqual({ok, 2}, adk_config_registry:generation(Snapshot2)),
    ?assertEqual({ok, #{provider => adk_llm_probe}},
                 adk_config_registry:lookup(
                   Snapshot1, provider, <<"operator-provider">>)),
    ?assertEqual({ok, #{provider => adk_llm_gemini}},
                 adk_config_registry:lookup(
                   Snapshot2, provider, <<"operator-provider">>)).

trusted_ids_compile_provider_and_toolsets_from_one_snapshot_test() ->
    {ok, Toolset} = adk_toolset:new(adk_test_toolset, self()),
    {ok, Registry} = adk_config_registry:new(
                       registry_definitions(Toolset, adk_llm_probe)),
    Config = #{<<"schema_version">> => 1,
               <<"name">> => <<"TrustedConfigAgent">>,
               <<"provider">> => <<"operator-provider">>,
               <<"model">> => <<"probe">>,
               <<"response">> => <<"ok">>,
               <<"toolsets">> =>
                   [#{<<"kind">> => <<"tool_pack">>,
                      <<"id">> => <<"core-pack">>},
                    #{<<"kind">> => <<"mcp">>,
                      <<"id">> => <<"mcp-tools">>}]},
    {ok, Compiled1} = adk_agent_config:compile(
                        Config, #{registry => Registry}),
    ?assertEqual(adk_llm_probe, maps:get(provider, Compiled1)),
    ?assertEqual(1, maps:get(registry_generation, Compiled1)),
    ?assertEqual(2, length(maps:get(tools, Compiled1))),

    {ok, Registry2} = adk_config_registry:replace(
                        Registry,
                        registry_definitions(Toolset, adk_llm_probe)),
    {ok, Compiled2} = adk_agent_config:compile(
                        Config, #{registry => Registry2}),
    ?assertNotEqual(maps:get(fingerprint, Compiled1),
                    maps:get(fingerprint, Compiled2)),
    ?assertEqual(2, maps:get(registry_generation, Compiled2)).

registry_instance_is_part_of_config_provenance_test() ->
    Config = (base_config())#{
               <<"toolsets">> =>
                   [#{<<"kind">> => <<"tool_pack">>,
                      <<"id">> => <<"core-pack">>}]},
    {ok, Registry1} = adk_config_registry:new(
                        #{tool_packs =>
                              #{<<"core-pack">> =>
                                    #{tools => [dummy_tool]}}}),
    {ok, Registry2} = adk_config_registry:new(
                        #{tool_packs =>
                              #{<<"core-pack">> =>
                                    #{tools => [adk_load_memory_tool]}}}),
    ?assertEqual({ok, 1}, adk_config_registry:generation(Registry1)),
    ?assertEqual({ok, 1}, adk_config_registry:generation(Registry2)),
    {ok, Instance1} = adk_config_registry:instance_id(Registry1),
    {ok, Instance2} = adk_config_registry:instance_id(Registry2),
    {ok, Revision1} = adk_config_registry:snapshot_revision_id(Registry1),
    {ok, Revision2} = adk_config_registry:snapshot_revision_id(Registry2),
    ?assertNotEqual(Instance1, Instance2),
    ?assertNotEqual(Revision1, Revision2),
    {ok, Compiled1} = adk_agent_config:compile(
                        Config, #{registry => Registry1}),
    {ok, Compiled2} = adk_agent_config:compile(
                        Config, #{registry => Registry2}),
    ?assertNotEqual(maps:get(fingerprint, Compiled1),
                    maps:get(fingerprint, Compiled2)),
    ?assertEqual(Instance1, maps:get(registry_instance_id, Compiled1)),
    ?assertEqual(Instance2, maps:get(registry_instance_id, Compiled2)),
    ?assertEqual(Revision1,
                 maps:get(registry_snapshot_revision_id, Compiled1)),
    ?assertEqual(Revision2,
                 maps:get(registry_snapshot_revision_id, Compiled2)).

branched_registry_replacements_have_unique_provenance_test() ->
    {ok, Empty} = adk_config_registry:new(),
    {ok, BranchA} = adk_config_registry:replace(
                      Empty,
                      #{tool_packs =>
                            #{<<"core-pack">> =>
                                  #{tools => [dummy_tool]}}}),
    {ok, BranchB} = adk_config_registry:replace(
                      Empty,
                      #{tool_packs =>
                            #{<<"core-pack">> =>
                                  #{tools => [adk_load_memory_tool]}}}),
    ?assertEqual(adk_config_registry:instance_id(BranchA),
                 adk_config_registry:instance_id(BranchB)),
    ?assertEqual({ok, 2}, adk_config_registry:generation(BranchA)),
    ?assertEqual({ok, 2}, adk_config_registry:generation(BranchB)),
    ?assertNotEqual(adk_config_registry:snapshot_revision_id(BranchA),
                    adk_config_registry:snapshot_revision_id(BranchB)),
    Config = (base_config())#{
               <<"toolsets">> =>
                   [#{<<"kind">> => <<"tool_pack">>,
                      <<"id">> => <<"core-pack">>}]},
    {ok, CompiledA} = adk_agent_config:compile(
                        Config, #{registry => BranchA}),
    {ok, CompiledB} = adk_agent_config:compile(
                        Config, #{registry => BranchB}),
    ?assertNotEqual(maps:get(fingerprint, CompiledA),
                    maps:get(fingerprint, CompiledB)).

application_registry_definitions_are_compiled_once_test() ->
    Previous = application:get_env(erlang_adk, agent_config_registry),
    Definitions = #{providers =>
                        #{<<"operator-provider">> =>
                              #{provider => adk_llm_probe}}},
    Config = (base_config())#{<<"provider">> => <<"operator-provider">>},
    try
        ok = application:set_env(erlang_adk, agent_config_registry,
                                 Definitions),
        {ok, First} = adk_agent_config:compile(Config),
        {ok, Second} = adk_agent_config:compile(Config),
        ?assertEqual(maps:get(fingerprint, First),
                     maps:get(fingerprint, Second)),
        ?assertEqual(maps:get(registry_snapshot_revision_id, First),
                     maps:get(registry_snapshot_revision_id, Second)),
        {ok, Cached} = application:get_env(
                         erlang_adk, agent_config_registry),
        ?assertMatch({ok, _}, adk_config_registry:snapshot(Cached))
    after
        restore_registry_env(Previous)
    end.

direct_module_tools_are_trusted_legacy_opt_in_test() ->
    Config = (base_config())#{<<"tools">> => [<<"dummy_tool">>]},
    ?assertEqual({error, direct_module_tools_disabled},
                 adk_agent_config:compile(Config)),
    {ok, Compiled} = adk_agent_config:compile(
                       Config, #{allow_legacy_module_tools => true}),
    ?assertEqual([dummy_tool], maps:get(tools, Compiled)).

arbitrary_provider_modules_are_trusted_legacy_opt_in_test() ->
    {module, adk_llm_dummy} = code:ensure_loaded(adk_llm_dummy),
    Config = (base_config())#{<<"provider">> => <<"adk_llm_dummy">>},
    ?assertEqual({error, legacy_provider_modules_disabled},
                 adk_agent_config:compile(Config)),
    {ok, Compiled} = adk_agent_config:compile(
                       Config,
                       #{allow_legacy_provider_modules => true}),
    ?assertEqual(adk_llm_dummy, maps:get(provider, Compiled)).

direct_compile_rejects_non_json_terms_and_invalid_paths_test() ->
    Base = base_config(),
    InvalidValues = [self(), make_ref(), fun() -> ok end,
                     {'not', json}, [<<"ok">> | improper], undefined],
    lists:foreach(
      fun(Value) ->
          ?assertMatch(
             {error, {invalid_agent_config_json, _}},
             adk_agent_config:compile(Base#{<<"response">> => Value}))
      end, InvalidValues),
    ?assertMatch(
       {error, {invalid_agent_config_json, _}},
       adk_agent_config:compile(Base#{atom_key => <<"value">>})),
    ?assertEqual({error, invalid_agent_config_path},
                 adk_agent_config:load_file(make_ref())).

declarative_runner_options_have_conservative_ceilings_test() ->
    Cases = [{<<"run_timeout">>, 600001},
             {<<"service_timeout">>, 60001},
             {<<"max_llm_calls">>, 65},
             {<<"max_tool_rounds">>, 33}],
    lists:foreach(
      fun({Key, Value}) ->
          ?assertEqual(
             {error, {invalid_runner_option, Key}},
             adk_agent_config:compile(
               (base_config())#{<<"runner_options">> => #{Key => Value}}))
      end, Cases),
    TooWide = #{<<"mode">> => <<"parallel">>,
                <<"max_concurrency">> => 17,
                <<"tool_timeout">> => 1000},
    TooLong = TooWide#{<<"max_concurrency">> => 1,
                       <<"tool_timeout">> => 120001},
    lists:foreach(
      fun(Policy) ->
          ?assertEqual(
             {error, invalid_parallel_tool_policy},
             adk_agent_config:compile(
               (base_config())#{
                 <<"runner_options">> =>
                     #{<<"tool_execution">> => Policy}}))
      end, [TooWide, TooLong]).

agent_name_validation_matches_runtime_tree_test() ->
    Invalid = [<<"user">>, <<"hyphen-name">>, <<"9starts_with_digit">>,
               binary:copy(<<"a">>, 257)],
    lists:foreach(
      fun(Name) ->
          ?assertEqual(
             {error, invalid_agent_name},
             adk_agent_config:compile(
               (base_config())#{<<"name">> => Name}))
      end, Invalid),
    {ok, Compiled} = adk_agent_config:compile(
                       (base_config())#{<<"name">> => <<"Agent_9">>}),
    ?assertEqual({ok, <<"Agent_9">>},
                 adk_agent_tree:validate_name(maps:get(name, Compiled))).

direct_compile_rejects_oversized_and_deep_terms_test() ->
    Oversized = (base_config())#{
                  <<"instructions">> =>
                      binary:copy(<<"x">>, 1048577)},
    ?assertMatch(
       {error, {agent_config_limit_exceeded, _}},
       adk_agent_config:compile(Oversized)),
    Deep = (base_config())#{<<"input_schema">> => deep_schema(70)},
    ?assertEqual(
       {error, {agent_config_limit_exceeded,
                eval_data_depth_exceeded}},
       adk_agent_config:compile(Deep)).

trusted_toolset_references_are_id_only_test() ->
    Raw = (base_config())#{
        <<"toolsets">> =>
            [#{<<"kind">> => <<"mcp">>,
               <<"id">> => <<"missing">>,
               <<"url">> => <<"https://attacker.invalid">>}]},
    ?assertEqual({error, raw_transport_in_config_file},
                 adk_agent_config:compile(Raw)),
    ?assertEqual(
       {error, {unknown_trusted_toolset, mcp, <<"missing">>}},
       adk_agent_config:compile(
         (base_config())#{
             <<"toolsets">> =>
                 [#{<<"kind">> => <<"mcp">>,
                    <<"id">> => <<"missing">>}]})).

toolset_references_are_bounded_unique_and_bulk_resolved_test() ->
    Duplicate = #{<<"kind">> => <<"tool_pack">>,
                  <<"id">> => <<"core-pack">>},
    ?assertEqual(
       {error, {duplicate_toolset_reference, tool_pack, <<"core-pack">>}},
       adk_agent_config:compile(
         (base_config())#{<<"toolsets">> => [Duplicate, Duplicate]})),
    TooMany =
        [#{<<"kind">> => <<"tool_pack">>,
           <<"id">> => <<"pack-", (integer_to_binary(Index))/binary>>}
         || Index <- lists:seq(1, 65)],
    ?assertEqual(
       {error, {toolset_reference_limit_exceeded, 64}},
       adk_agent_config:compile(
         (base_config())#{<<"toolsets">> => TooMany})),

    {ok, Registry} = adk_config_registry:new(
                       #{providers =>
                             #{<<"probe">> =>
                                   #{provider => adk_llm_probe}},
                         tool_packs =>
                             #{<<"core-pack">> =>
                                   #{tools => [dummy_tool]}}}),
    ?assertEqual(
       {ok, [#{provider => adk_llm_probe},
             #{tools => [dummy_tool]}]},
       adk_config_registry:lookup_many(
         Registry,
         [{provider, <<"probe">>},
          {tool_pack, <<"core-pack">>}])).

registry_rejects_invalid_shapes_and_ids_test() ->
    ?assertMatch(
       {error, {unknown_registry_keys, [unknown]}},
       adk_config_registry:new(#{unknown => #{}})),
    ?assertMatch(
       {error, {invalid_registry_id, provider}},
       adk_config_registry:new(
         #{providers =>
               #{<<"bad/id">> => #{provider => adk_llm_probe}}})),
    ?assertMatch(
       {error, {invalid_registry_descriptor, mcp, _, _}},
       adk_config_registry:new(
         #{mcp => #{<<"bad-mcp">> => #{toolset => not_a_toolset}}})),
    Token = binary:copy(<<"a">>, 64),
    ForgedSnapshot = {adk_config_registry_snapshot, 1, 1,
                      Token, Token, #{}},
    ForgedRegistry = {adk_config_registry, 1, 1,
                      Token, Token, ForgedSnapshot},
    ?assertEqual({error, invalid_config_registry},
                 adk_config_registry:snapshot(ForgedSnapshot)),
    ?assertEqual({error, invalid_config_registry},
                 adk_config_registry:lookup(
                   ForgedSnapshot, provider, <<"provider">>)),
    ?assertEqual({error, invalid_config_registry},
                 adk_config_registry:replace(ForgedRegistry, #{})),
    BadIdRegistry = {adk_config_registry, 1, 1,
                     <<"short">>, Token, ForgedSnapshot},
    ?assertEqual({error, invalid_config_registry},
                 adk_config_registry:replace(BadIdRegistry, #{})).

registry_snapshot_seal_rejects_same_provenance_changed_tools_test() ->
    {ok, Registry} = adk_config_registry:new(
                       #{tool_packs =>
                             #{<<"core-pack">> =>
                                   #{tools => [dummy_tool]}}}),
    {ok, Snapshot} = adk_config_registry:snapshot(Registry),
    {adk_config_registry_snapshot, 1, Generation, InstanceId,
     RevisionId, Seal, Entries} = Snapshot,
    ForgedEntries = Entries#{
        tool_pack =>
            #{<<"core-pack">> =>
                  #{tools => [adk_load_memory_tool]}}},
    Forged = {adk_config_registry_snapshot, 1, Generation, InstanceId,
              RevisionId, Seal, ForgedEntries},
    ?assertEqual({error, invalid_config_registry},
                 adk_config_registry:snapshot(Forged)),
    ?assertEqual(
       {error, invalid_agent_config_registry},
       adk_agent_config:compile(
         (base_config())#{
             <<"toolsets">> =>
                 [#{<<"kind">> => <<"tool_pack">>,
                    <<"id">> => <<"core-pack">>}]},
         #{registry => Forged})).

json_and_yaml_v2_compile_to_identical_canonical_ir_test() ->
    {ok, Policy} = adk_runtime_policy:compile(
                     #{agents => #{allow => all},
                       tools => #{allow => all}}),
    {ok, Workflow} = adk_workflow:compile(
                       #{version => 1, id => <<"main-flow">>,
                         kind => sequential,
                         steps => [#{id => <<"step">>,
                                     run => fun(State) ->
                                                {ok, State}
                                            end}]}),
    {ok, Registry} = adk_config_registry:new(
                       #{credentials =>
                             #{<<"main-credential">> =>
                                   #{profile => <<"provider-credential">>,
                                     metadata =>
                                         #{secret =>
                                               <<"operator-secret-never-in-ir">>}}},
                         runtime_policies =>
                             #{<<"safe-policy">> => #{policy => Policy}},
                         workflows =>
                             #{<<"main-flow">> =>
                                   #{workflow => Workflow}},
                         agent_templates =>
                             #{<<"root-template">> =>
                                   #{template => #{<<"kind">> => <<"agent">>},
                                     sub_agents => [<<"child-template">>]},
                               <<"child-template">> =>
                                   #{template =>
                                         #{<<"kind">> => <<"agent">>}}}}),
    Config = (base_config())#{
        <<"schema_version">> => 2,
        <<"agent_template">> => <<"root-template">>,
        <<"credential_profile">> => <<"main-credential">>,
        <<"runtime_policy">> => <<"safe-policy">>,
        <<"sub_agents">> =>
            [#{<<"name">> => <<"ChildAgent">>,
               <<"agent_template">> => <<"child-template">>}],
        <<"workflows">> =>
            [#{<<"name">> => <<"main">>,
               <<"workflow">> => <<"main-flow">>}]},
    Yaml =
        <<"schema_version: 2\n"
          "name: ConfigCompilerAgent\n"
          "provider: adk_llm_probe\n"
          "model: probe\n"
          "response: compiled\n"
          "runner_options:\n"
          "  max_llm_calls: 2\n"
          "  max_tool_rounds: 1\n"
          "agent_template: root-template\n"
          "credential_profile: main-credential\n"
          "runtime_policy: safe-policy\n"
          "sub_agents:\n"
          "  - name: ChildAgent\n"
          "    agent_template: child-template\n"
          "workflows:\n"
          "  - name: main\n"
          "    workflow: main-flow\n">>,
    with_config_files(
      jsx:encode(Config), Yaml,
      fun(JsonPath, YamlPath) ->
          {ok, JsonCompiled} = adk_agent_config:load_file(
                                 JsonPath, #{registry => Registry}),
          {ok, YamlCompiled} = adk_agent_config:load_file(
                                 YamlPath, #{registry => Registry}),
          ?assertEqual(2, adk_agent_config:current_schema_version()),
          ?assertEqual(maps:get(fingerprint, JsonCompiled),
                       maps:get(fingerprint, YamlCompiled)),
          ?assertEqual(maps:get(references, JsonCompiled),
                       maps:get(references, YamlCompiled)),
          ?assertEqual(
             nomatch,
             binary:match(term_to_binary(JsonCompiled),
                          <<"operator-secret-never-in-ir">>)),
          ?assertEqual(
             #{agent_template => <<"root-template">>,
               credential_profile => <<"main-credential">>,
               runtime_policy => <<"safe-policy">>,
               sub_agents =>
                   [#{name => <<"ChildAgent">>,
                      agent_template => <<"child-template">>,
                      sub_agents => []}],
               workflows =>
                   [#{name => <<"main">>,
                      workflow => <<"main-flow">>}]},
             maps:get(references, JsonCompiled))
      end).

schema_v1_shape_and_fingerprint_input_remain_compatible_test() ->
    Config = base_config(),
    {ok, Implicit} = adk_agent_config:compile(Config),
    {ok, Explicit} = adk_agent_config:compile(
                       Config#{<<"schema_version">> => 1}),
    ?assertEqual(1, maps:get(schema_version, Implicit)),
    ?assertEqual(maps:get(fingerprint, Implicit),
                 maps:get(fingerprint, Explicit)),
    ?assertEqual(false, maps:is_key(references, Implicit)),
    ?assertMatch(
       {error, {unknown_agent_config_keys, [<<"runtime_policy">>]}},
       adk_agent_config:compile(
         Config#{<<"runtime_policy">> => <<"policy">>})).

strict_yaml_rejects_unsafe_or_ambiguous_features_test() ->
    Invalid = [
        <<"name: One\nname: Two\n">>,
        <<"defaults: &defaults\n  name: One\nagent: *defaults\n">>,
        <<"name: !!str One\n">>,
        <<"base: value\n<<: base\n">>,
        <<"---\nname: One\n">>,
        <<"name: One\n---\nname: Two\n">>,
        <<"value: .nan\n">>,
        <<"value: 01\n">>,
        <<"value: {name: duplicate, name: hidden}\n">>,
        <<"name:\n   child: bad-indent\n">>
    ],
    lists:foreach(
      fun(Yaml) -> ?assertMatch({error, _}, adk_agent_yaml:decode(Yaml)) end,
      Invalid),
    ?assertEqual(
       {ok, #{<<"literal">> => <<"A&B ! and * are text">>}},
       adk_agent_yaml:decode(
         <<"literal: 'A&B ! and * are text' # comment\n">>)).

yaml_unknown_keys_do_not_create_atoms_test() ->
    _ = adk_agent_yaml:decode(<<"warmup: value\n">>),
    CountBefore = erlang:system_info(atom_count),
    Lines = [<<"unknown_", (integer_to_binary(Index))/binary,
               ": value\n">> || Index <- lists:seq(1, 1000)],
    {ok, Parsed} = adk_agent_yaml:decode(iolist_to_binary(Lines)),
    ?assertEqual(1000, map_size(Parsed)),
    ?assertEqual(CountBefore, erlang:system_info(atom_count)).

v2_reference_boundaries_and_template_graph_cycles_test() ->
    {ok, Registry} = adk_config_registry:new(
                       #{agent_templates =>
                             #{<<"child">> =>
                                   #{template => #{<<"v">> => 1}}}}),
    Base = (base_config())#{<<"schema_version">> => 2},
    ?assertEqual(
       {error, {unknown_trusted_reference,
                runtime_policy, <<"missing">>}},
       adk_agent_config:compile(
         Base#{<<"runtime_policy">> => <<"missing">>},
         #{registry => Registry})),
    Repeated =
        [#{<<"name">> => <<"Child">>,
           <<"agent_template">> => <<"child">>,
           <<"sub_agents">> =>
               [#{<<"name">> => <<"Grandchild">>,
                  <<"agent_template">> => <<"child">>}]}],
    ?assertEqual(
       {error, {sub_agent_reference_cycle, <<"child">>}},
       adk_agent_config:compile(
         Base#{<<"sub_agents">> => Repeated},
         #{registry => Registry})),
    ?assertMatch(
       {error, {agent_template_cycle, _}},
       adk_config_registry:new(
         #{agent_templates =>
               #{<<"a">> => #{template => #{}, sub_agents => [<<"b">>]},
                 <<"b">> =>
                     #{template => #{}, sub_agents => [<<"a">>]}}})).

with_config_files(Json, Yaml, Fun) ->
    Unique = integer_to_list(
               erlang:unique_integer([positive, monotonic])),
    Tmp = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    JsonPath = filename:join(Tmp, "adk-agent-" ++ Unique ++ ".json"),
    YamlPath = filename:join(Tmp, "adk-agent-" ++ Unique ++ ".yaml"),
    ok = file:write_file(JsonPath, Json),
    ok = file:write_file(YamlPath, Yaml),
    try Fun(JsonPath, YamlPath)
    after
        _ = file:delete(JsonPath),
        _ = file:delete(YamlPath)
    end.

base_config() ->
    #{<<"name">> => <<"ConfigCompilerAgent">>,
      <<"provider">> => <<"adk_llm_probe">>,
      <<"model">> => <<"probe">>,
      <<"response">> => <<"compiled">>,
      <<"runner_options">> =>
          #{<<"max_llm_calls">> => 2,
            <<"max_tool_rounds">> => 1}}.

registry_definitions(Toolset, Provider) ->
    #{providers =>
          #{<<"operator-provider">> => #{provider => Provider}},
      mcp => #{<<"mcp-tools">> => #{toolset => Toolset}},
      openapi => #{<<"openapi-tools">> => #{toolset => Toolset}},
      tool_packs => #{<<"core-pack">> => #{tools => [dummy_tool]}}}.

deep_schema(0) -> #{<<"type">> => <<"string">>};
deep_schema(Depth) ->
    #{<<"nested">> => deep_schema(Depth - 1)}.

restore_registry_env({ok, Value}) ->
    application:set_env(erlang_adk, agent_config_registry, Value);
restore_registry_env(undefined) ->
    application:unset_env(erlang_adk, agent_config_registry).
