-module(adk_v010_supervision_test).
-include_lib("eunit/include/eunit.hrl").

-define(KEYS,
        [runtime_service_profile, runtime_service_profile_config,
         evaluation_service_enabled, evaluation_store,
         evaluation_store_options, evaluation_service_options,
         trace_store_enabled, trace_store_options,
         trace_store_principal, observability_bus_enabled,
         observability_bus_options, memory_outbox_enabled,
         memory_outbox_options]).

optional_v010_services_test_() ->
    {setup,
     fun save_environment/0,
     fun restore_environment/1,
     [fun disabled_services_keep_default_tree_lean_case/0,
      fun enabled_services_have_safe_order_and_owned_stores_case/0,
      fun durable_profile_owns_outbox_and_absorbs_compatibility_case/0,
      fun independent_outbox_compatibility_case/0,
      fun invalid_service_environment_fails_closed_case/0]}.

save_environment() ->
    [{Key, application:get_env(erlang_adk, Key)} || Key <- ?KEYS].

restore_environment(Saved) ->
    lists:foreach(
      fun({Key, undefined}) -> application:unset_env(erlang_adk, Key);
         ({Key, {ok, Value}}) ->
              application:set_env(erlang_adk, Key, Value)
      end, Saved),
    ok.

disabled_services_keep_default_tree_lean_case() ->
    set_defaults(),
    Specs = child_specs(),
    ?assertEqual(false, has_child(adk_runtime_service_bundle, Specs)),
    ?assertEqual(false, has_child(adk_eval_service, Specs)),
    ?assertEqual(false, has_child(adk_trace_store, Specs)),
    ?assertEqual(false, has_child(adk_memory_outbox_sup, Specs)),
    ?assertEqual(false, has_child(adk_observability_bus, Specs)).

enabled_services_have_safe_order_and_owned_stores_case() ->
    set_defaults(),
    application:set_env(erlang_adk, runtime_service_profile,
                        ephemeral_local),
    application:set_env(
      erlang_adk, runtime_service_profile_config,
      #{artifact => #{max_active_scopes => 8, max_router_queue => 4},
        memory => #{max_active_scopes => 8, max_router_queue => 4}}),
    application:set_env(erlang_adk, evaluation_service_enabled, true),
    application:set_env(erlang_adk, evaluation_store, mnesia),
    application:set_env(erlang_adk, evaluation_store_options,
                        #{max_jobs => 25}),
    application:set_env(erlang_adk, evaluation_service_options,
                        #{max_concurrency => 2, max_queue => 5}),
    application:set_env(erlang_adk, trace_store_enabled, true),
    application:set_env(erlang_adk, trace_store_options,
                        #{max_events => 64, max_bytes => 1048576,
                          max_event_bytes => 65536,
                          max_events_per_principal => 32,
                          max_bytes_per_principal => 524288,
                          max_query_events => 32,
                          max_query_bytes => 524288}),
    Specs = child_specs(),
    ?assert(has_child(adk_runtime_service_bundle, Specs)),
    ?assert(has_child(adk_eval_service, Specs)),
    ?assert(has_child(adk_trace_store, Specs)),
    ?assert(has_child(adk_observability_bus, Specs)),
    ?assertEqual(false, has_child(adk_memory_outbox_sup, Specs)),
    ?assert(index_of(erlang_adk_session_owner, Specs) <
            index_of(adk_runtime_service_bundle, Specs)),
    ?assert(index_of(adk_runtime_service_bundle, Specs) <
            index_of(adk_agent_registry, Specs)),
    ?assert(index_of(adk_task_sup, Specs) <
            index_of(adk_eval_service, Specs)),
    ?assert(index_of(adk_eval_service, Specs) <
            index_of(adk_run_registry, Specs)),
    ?assert(index_of(adk_trace_store, Specs) <
            index_of(adk_agent_registry, Specs)),
    ?assert(index_of(adk_trace_store, Specs) <
            index_of(adk_observability_metrics, Specs)),
    ?assert(index_of(adk_trace_store, Specs) <
            index_of(adk_observability_bus, Specs)),

    Runtime = child(adk_runtime_service_bundle, Specs),
    {adk_runtime_service_bundle, start_link,
     [adk_runtime_service_bundle, ephemeral_local, _RuntimeConfig]} =
        maps:get(start, Runtime),

    Eval = child(adk_eval_service, Specs),
    {adk_eval_service, start_link, [EvalOptions]} = maps:get(start, Eval),
    ?assertEqual(adk_eval_service, maps:get(name, EvalOptions)),
    ?assertEqual(
       {owned, adk_eval_store_mnesia, #{max_jobs => 25}},
       maps:get(store, EvalOptions)),
    Trace = child(adk_trace_store, Specs),
    {adk_trace_store, start_link, [TraceOptions]} = maps:get(start, Trace),
    ?assertEqual(adk_trace_store, maps:get(name, TraceOptions)),
    Bus = child(adk_observability_bus, Specs),
    {adk_observability_bus, start_link, [BusOptions]} = maps:get(start, Bus),
    [TraceExporter] = maps:get(exporters, BusOptions),
    ?assertEqual(adk_trace_store_exporter,
                 maps:get(module, TraceExporter)).

durable_profile_owns_outbox_and_absorbs_compatibility_case() ->
    set_defaults(),
    Root = <<"/tmp/erlang-adk-v010-supervision-outbox">>,
    application:set_env(erlang_adk, runtime_service_profile,
                        durable_local),
    application:set_env(erlang_adk, runtime_service_profile_config,
                        #{artifact_root => Root}),
    Specs = child_specs(),
    ?assert(has_child(adk_runtime_service_bundle, Specs)),
    ?assertEqual(false, has_child(adk_memory_outbox_sup, Specs)),
    Runtime = child(adk_runtime_service_bundle, Specs),
    {adk_runtime_service_bundle, start_link,
     [adk_runtime_service_bundle, durable_local, DefaultConfig]} =
        maps:get(start, Runtime),
    {ok, DefaultPlan} = adk_runtime_service_profile:compile(
                          durable_local, DefaultConfig),
    ?assertMatch(
       #{ingestion := #{mode := durable,
                        adapter_id := <<"durable-local-memory-v1">>}},
       maps:get(memory_outbox, DefaultPlan)),

    Compatibility =
        #{outbox =>
              #{jobs_table => adk_v010_supervision_outbox_job,
                usage_table => adk_v010_supervision_outbox_usage,
                schedule_table => adk_v010_supervision_outbox_schedule,
                default_max_attempts => 3},
          registry => #{max_entries => 17},
          processor => #{max_concurrency => 2}},
    application:set_env(erlang_adk, memory_outbox_enabled, true),
    application:set_env(erlang_adk, memory_outbox_options,
                        Compatibility),
    application:set_env(
      erlang_adk, runtime_service_profile_config,
      #{artifact_root => Root,
        memory_outbox =>
            #{outbox => #{max_claim_scan => 7},
              processor => #{poll_interval_ms => 25}}}),
    CompatibilitySpecs = child_specs(),
    ?assertEqual(false,
                 has_child(adk_memory_outbox_sup, CompatibilitySpecs)),
    CompatibilityRuntime = child(
                             adk_runtime_service_bundle,
                             CompatibilitySpecs),
    {adk_runtime_service_bundle, start_link,
     [adk_runtime_service_bundle, durable_local, CompatibilityConfig]} =
        maps:get(start, CompatibilityRuntime),
    MergedOutbox = maps:get(memory_outbox, CompatibilityConfig),
    ?assertEqual(
       #{jobs_table => adk_v010_supervision_outbox_job,
         usage_table => adk_v010_supervision_outbox_usage,
         schedule_table => adk_v010_supervision_outbox_schedule,
         default_max_attempts => 3,
         max_claim_scan => 7},
       maps:get(outbox, MergedOutbox)),
    ?assertEqual(#{max_entries => 17},
                 maps:get(registry, MergedOutbox)),
    ?assertEqual(#{max_concurrency => 2, poll_interval_ms => 25},
                 maps:get(processor, MergedOutbox)),
    {ok, CompatibilityPlan} = adk_runtime_service_profile:compile(
                                durable_local, CompatibilityConfig),
    ?assertEqual(
       3,
       maps:get(max_attempts,
                maps:get(ingestion,
                         maps:get(memory_outbox, CompatibilityPlan)))).

independent_outbox_compatibility_case() ->
    set_defaults(),
    application:set_env(erlang_adk, memory_outbox_enabled, true),
    DisabledSpecs = child_specs(),
    ?assert(has_child(adk_memory_outbox_sup, DisabledSpecs)),
    ?assert(index_of(adk_memory_outbox_sup, DisabledSpecs) <
            index_of(adk_agent_registry, DisabledSpecs)),
    application:set_env(erlang_adk, runtime_service_profile,
                        ephemeral_local),
    EphemeralSpecs = child_specs(),
    ?assert(has_child(adk_runtime_service_bundle, EphemeralSpecs)),
    ?assert(has_child(adk_memory_outbox_sup, EphemeralSpecs)),
    ?assert(index_of(adk_runtime_service_bundle, EphemeralSpecs) <
            index_of(adk_memory_outbox_sup, EphemeralSpecs)),
    ?assert(index_of(adk_memory_outbox_sup, EphemeralSpecs) <
            index_of(adk_agent_registry, EphemeralSpecs)).

invalid_service_environment_fails_closed_case() ->
    set_defaults(),
    application:set_env(erlang_adk, evaluation_service_enabled,
                        <<"yes">>),
    ?assertError(
       {invalid_application_env, evaluation_service_enabled, <<"yes">>},
       erlang_adk_sup:init([])),
    application:set_env(erlang_adk, evaluation_service_enabled, false),
    application:set_env(erlang_adk, trace_store_enabled, enabled),
    ?assertError(
       {invalid_application_env, trace_store_enabled, enabled},
       erlang_adk_sup:init([])),
    application:set_env(erlang_adk, trace_store_enabled, false),
    application:set_env(erlang_adk, runtime_service_profile, remote),
    ?assertError(
       {invalid_application_env, runtime_service_profile, remote},
       erlang_adk_sup:init([])),
    application:set_env(erlang_adk, runtime_service_profile, disabled),
    application:set_env(erlang_adk, memory_outbox_enabled, invalid),
    ?assertError(
       {invalid_application_env, memory_outbox_enabled, invalid},
       erlang_adk_sup:init([])).

set_defaults() ->
    application:set_env(erlang_adk, runtime_service_profile, disabled),
    application:set_env(erlang_adk, runtime_service_profile_config, #{}),
    application:set_env(erlang_adk, evaluation_service_enabled, false),
    application:set_env(erlang_adk, evaluation_store, ets),
    application:set_env(erlang_adk, evaluation_store_options, #{}),
    application:set_env(erlang_adk, evaluation_service_options, #{}),
    application:set_env(erlang_adk, trace_store_enabled, false),
    application:set_env(erlang_adk, trace_store_options, #{}),
    application:set_env(erlang_adk, trace_store_principal,
                        <<"local-runtime">>),
    application:set_env(erlang_adk, observability_bus_enabled, false),
    application:set_env(erlang_adk, observability_bus_options, #{}),
    application:set_env(erlang_adk, memory_outbox_enabled, false),
    application:set_env(erlang_adk, memory_outbox_options, #{}),
    ok.

child_specs() ->
    {ok, {_Flags, Specs}} = erlang_adk_sup:init([]),
    Specs.

has_child(Id, Specs) ->
    lists:any(fun(#{id := ChildId}) -> ChildId =:= Id end, Specs).

child(Id, Specs) ->
    hd([Spec || #{id := ChildId} = Spec <- Specs, ChildId =:= Id]).

index_of(Id, Specs) ->
    index_of(Id, Specs, 1).

index_of(Id, [#{id := Id} | _], Index) -> Index;
index_of(Id, [_ | Rest], Index) -> index_of(Id, Rest, Index + 1).
