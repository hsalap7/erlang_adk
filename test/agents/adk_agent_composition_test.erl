-module(adk_agent_composition_test).

-include_lib("eunit/include/eunit.hrl").

composition_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_Started) -> ok end,
     [fun resolves_and_spawns_trusted_composition/0,
      fun scoped_composition_names_every_agent/0,
      fun registry_provenance_mismatch_fails_closed/0]}.

resolves_and_spawns_trusted_composition() ->
    {Registry, Compiled, Policy, Workflow} = fixture(),
    {ok, Resolved} = adk_agent_composition:resolve(Compiled, Registry),
    RootCompiled = maps:get(compiled, Resolved),
    ?assertEqual(Policy,
                 maps:get(runtime_policy,
                          maps:get(runner_options, RootCompiled))),
    ?assertEqual(Workflow,
                 maps:get(<<"smoke">>, maps:get(workflows, Resolved))),
    {ok, Handle} = erlang_adk:spawn_agent_config(Compiled, Registry),
    try
        {ok, Root} = erlang_adk:agent_config_root(Handle),
        {ok, _Name, _Config, _Tools, SubAgents} =
            gen_server:call(Root, get_runtime),
        #{<<"ChildAgent">> := #{pid := Child}} = SubAgents,
        ?assert(is_process_alive(Child)),
        ?assertEqual(
           #{<<"RootAgent">> => <<"profile-a">>},
           maps:get(credential_profiles, Handle))
    after
        ok = erlang_adk:stop_agent_config(Handle)
    end.

scoped_composition_names_every_agent() ->
    {Registry, Compiled, Policy, Workflow} = fixture(),
    {ok, Handle} = adk_agent_composition:spawn_scoped(
                     Compiled, Registry, <<"eval_42">>),
    try
        {ok, Root} = adk_agent_composition:root(Handle),
        {ok, <<"RootAgent_eval_42">>, _Config, _Tools, SubAgents} =
            gen_server:call(Root, get_runtime),
        #{<<"ChildAgent_eval_42">> := #{pid := Child}} = SubAgents,
        {ok, <<"ChildAgent_eval_42">>, _, _, _} =
            gen_server:call(Child, get_runtime),
        {ok, RunnerOptions} = adk_agent_composition:runner_options(Handle),
        ?assertEqual(Policy, maps:get(runtime_policy, RunnerOptions)),
        {ok, Workflows} = adk_agent_composition:workflows(Handle),
        ?assertEqual(
           Workflow,
           maps:get(<<"smoke">>,
                    maps:get(<<"RootAgent_eval_42">>, Workflows))),
        {ok, Credentials} =
            adk_agent_composition:credential_profiles(Handle),
        ?assertEqual(
           <<"profile-a">>,
           maps:get(<<"RootAgent_eval_42">>, Credentials))
    after
        ok = adk_agent_composition:stop(Handle)
    end.

registry_provenance_mismatch_fails_closed() ->
    {Registry, Compiled, _Policy, _Workflow} = fixture(),
    {ok, Other} = adk_config_registry:replace(
                    Registry,
                    #{providers => #{<<"probe">> => adk_llm_probe}}),
    ?assertEqual(
       {error, agent_config_registry_provenance_mismatch},
       adk_agent_composition:resolve(Compiled, Other)).

fixture() ->
    {ok, Policy} = adk_runtime_policy:compile(
                     #{id => <<"locked">>,
                       agents => #{allow => [<<"RootAgent">>,
                                              <<"ChildAgent">>]},
                       tools => #{allow => all}}),
    {ok, Workflow} = adk_workflow:compile(
                       #{version => 1, id => <<"smoke-workflow">>,
                         kind => sequential,
                         steps => [#{id => <<"delegate">>,
                                     run => {agent, <<"ChildAgent">>,
                                             <<"hello">>}}]}),
    Definitions =
        #{providers => #{<<"probe">> => adk_llm_probe},
          credentials => #{<<"profile-a">> => <<"profile-a">>},
          runtime_policies => #{<<"locked">> => #{policy => Policy}},
          workflows => #{<<"workflow-a">> => #{workflow => Workflow}},
          agent_templates =>
              #{<<"child-template">> =>
                    #{template =>
                          #{<<"provider">> => <<"probe">>,
                            <<"response">> => <<"child">>}}}},
    {ok, Registry} = adk_config_registry:new(Definitions),
    Json = #{<<"schema_version">> => 2,
             <<"name">> => <<"RootAgent">>,
             <<"provider">> => <<"probe">>,
             <<"response">> => <<"root">>,
             <<"credential_profile">> => <<"profile-a">>,
             <<"runtime_policy">> => <<"locked">>,
             <<"sub_agents">> =>
                 [#{<<"name">> => <<"ChildAgent">>,
                    <<"agent_template">> => <<"child-template">>}],
             <<"workflows">> =>
                 [#{<<"name">> => <<"smoke">>,
                    <<"workflow">> => <<"workflow-a">>}]},
    {ok, Compiled} = adk_agent_config:compile(Json, #{registry => Registry}),
    {Registry, Compiled, Policy, Workflow}.
