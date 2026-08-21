-module(adk_deployment_lifecycle_edge_test).

-include_lib("eunit/include/eunit.hrl").

-define(OUTBOX_JOBS, adk_deployment_lifecycle_edge_outbox_job).
-define(OUTBOX_USAGE, adk_deployment_lifecycle_edge_outbox_usage).
-define(OUTBOX_SCHEDULE, adk_deployment_lifecycle_edge_outbox_schedule).

liveness_follows_application_supervisor_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ?assertMatch({ok, #{status := live}},
                 adk_deployment_lifecycle:liveness()),
    ok = application:stop(erlang_adk),
    try
        ?assertEqual({error, not_live},
                     adk_deployment_lifecycle:liveness()),
        ?assertEqual(1, adk_deployment_lifecycle:liveness_code()),
        ?assertMatch({error, {not_ready, _}},
                     adk_deployment_lifecycle:readiness())
    after
        {ok, _} = application:ensure_all_started(erlang_adk)
    end.

dependency_status_is_fail_closed_for_invalid_or_missing_services_test() ->
    with_disabled_application(
      fun() ->
          with_mnesia_stopped(
            fun() ->
                ok = application:set_env(erlang_adk,
                                         runtime_service_profile,
                                         invalid_profile),
                ok = application:set_env(erlang_adk,
                                         evaluation_service_enabled, true),
                ok = application:set_env(erlang_adk,
                                         evaluation_service_options,
                                         #{name => 42}),
                ok = application:set_env(erlang_adk,
                                         evaluation_store, mnesia),
                ok = application:set_env(erlang_adk,
                                         trace_store_enabled, true),
                ok = application:set_env(erlang_adk,
                                         trace_store_options,
                                         #{name => undefined}),
                ok = application:set_env(
                       erlang_adk, dev_provider_payload_inspection,
                       #{enabled => true, name => undefined}),
                ok = application:set_env(erlang_adk,
                                         memory_outbox_enabled, true),
                ok = application:set_env(erlang_adk,
                                         a2a_v1_enabled, true),
                ok = application:set_env(erlang_adk,
                                         http_health_enabled, true),
                ok = application:set_env(erlang_adk,
                                         observability_bus_enabled, true),
                Snapshot = adk_deployment_lifecycle:status(),
                Dependencies = maps:get(dependencies, Snapshot),
                ?assertEqual(invalid,
                             maps:get(runtime_services, Dependencies)),
                ?assertEqual(invalid, maps:get(evaluation, Dependencies)),
                ?assertEqual(invalid, maps:get(trace, Dependencies)),
                ?assertEqual(invalid,
                             maps:get(developer_payloads, Dependencies)),
                ?assertEqual(unavailable,
                             maps:get(memory_outbox, Dependencies)),
                ?assertEqual(unavailable, maps:get(mnesia, Dependencies)),
                ?assertEqual(unavailable, maps:get(a2a, Dependencies)),
                ?assertEqual(unavailable, maps:get(http, Dependencies)),
                ?assertEqual(unavailable,
                             maps:get(observability, Dependencies)),
                ?assertEqual(false, maps:get(ready, Snapshot)),
                ?assert(lists:member(
                          runtime_services,
                          maps:get(failed_dependencies, Snapshot))),

                ok = application:set_env(erlang_adk,
                                         runtime_service_profile,
                                         ephemeral_local),
                ?assertEqual(
                   unavailable,
                   dependency(runtime_services,
                              adk_deployment_lifecycle:status())),
                ok = application:set_env(erlang_adk,
                                         runtime_service_profile,
                                         durable_local),
                ?assertEqual(
                   unavailable,
                   dependency(runtime_services,
                              adk_deployment_lifecycle:status()))
            end)
      end).

mnesia_dependency_reports_ready_when_required_test() ->
    with_disabled_application(
      fun() ->
          WasRunning = lists:keymember(mnesia, 1,
                                       application:which_applications()),
          {ok, _} = application:ensure_all_started(mnesia),
          try
              ok = application:set_env(erlang_adk,
                                       memory_outbox_enabled, true),
              ?assertEqual(ready,
                           dependency(mnesia,
                                      adk_deployment_lifecycle:status()))
          after
              case WasRunning of
                  true -> ok;
                  false -> _ = application:stop(mnesia)
              end
          end
      end).

independent_outbox_readiness_uses_transaction_health_test() ->
    with_disabled_application(
      fun() ->
          delete_outbox_tables(),
          Options =
              #{outbox =>
                    #{jobs_table => ?OUTBOX_JOBS,
                      usage_table => ?OUTBOX_USAGE,
                      schedule_table => ?OUTBOX_SCHEDULE}},
          {ok, Supervisor} = adk_memory_outbox_sup:start_link(Options),
          unlink(Supervisor),
          {ok, Adapter} = adk_memory_outbox_test_adapter:start_link(#{}),
          try
              ok = adk_memory_outbox_sup:register_adapter(
                     {adk_memory_outbox_test_adapter,
                      <<"deployment-health-v2">>},
                     {adk_memory_outbox_test_adapter, Adapter}),
              ok = application:set_env(
                     erlang_adk, memory_outbox_enabled, true),
              ?assertEqual(
                 ready,
                 dependency(memory_outbox,
                            adk_deployment_lifecycle:status())),
              {atomic, ok} = mnesia:delete_table(?OUTBOX_SCHEDULE),
              ?assertEqual(
                 unhealthy,
                 dependency(memory_outbox,
                            adk_deployment_lifecycle:status()))
          after
              adk_memory_outbox_test_adapter:stop(Adapter),
              ok = adk_memory_outbox_sup:stop(Supervisor),
              delete_outbox_tables()
          end
      end).

invalid_enablement_values_are_reported_not_crashed_test() ->
    with_disabled_application(
      fun() ->
          ok = application:set_env(erlang_adk,
                                   evaluation_service_enabled, invalid),
          ok = application:set_env(erlang_adk, trace_store_enabled, invalid),
          ok = application:set_env(erlang_adk,
                                   dev_provider_payload_inspection, invalid),
          ok = application:set_env(erlang_adk, memory_outbox_enabled, invalid),
          ok = application:set_env(erlang_adk, a2a_v1_enabled, invalid),
          Dependencies = maps:get(
                           dependencies,
                           adk_deployment_lifecycle:status()),
          lists:foreach(
            fun(Name) -> ?assertEqual(invalid,
                                      maps:get(Name, Dependencies)) end,
            [evaluation, trace, developer_payloads, memory_outbox, a2a])
      end).

observability_dependency_and_drain_are_bounded_test() ->
    with_disabled_application(
      fun() ->
          {ok, Bus} = adk_observability_bus:start_link(
                        #{name => adk_observability_bus,
                          exporters => [], flush_interval_ms => 1000}),
          try
              ok = application:set_env(erlang_adk,
                                       observability_bus_enabled, true),
              ?assertEqual(ready,
                           dependency(observability,
                                      adk_deployment_lifecycle:status())),
              ?assertEqual({error, invalid_drain_timeout},
                           adk_deployment_lifecycle:begin_drain(-1)),
              ?assertEqual({error, invalid_drain_timeout},
                           adk_deployment_lifecycle:begin_drain(600001)),
              ?assertEqual(1, adk_deployment_lifecycle:drain_code(invalid)),
              ?assertEqual({error, drain_timeout},
                           adk_deployment_lifecycle:begin_drain(0))
          after
              gen_server:stop(Bus)
          end
      end),
    with_disabled_application(
      fun() ->
          {ok, Bus} = adk_observability_bus:start_link(
                        #{name => adk_observability_bus,
                          exporters => [], flush_interval_ms => 1000}),
          try
              ?assertMatch({ok, #{draining := true}},
                           adk_deployment_lifecycle:begin_drain()),
              ?assertEqual(0, adk_deployment_lifecycle:drain_code(1000)),
              ?assertEqual(1, adk_deployment_lifecycle:readiness_code())
          after
              gen_server:stop(Bus)
          end
      end).

dependency(Name, Snapshot) ->
    maps:get(Name, maps:get(dependencies, Snapshot)).

with_mnesia_stopped(Fun) ->
    WasRunning = lists:keymember(mnesia, 1,
                                 application:which_applications()),
    _ = application:stop(mnesia),
    try Fun()
    after
        case WasRunning of
            true -> {ok, _} = application:ensure_all_started(mnesia);
            false -> ok
        end
    end.

with_disabled_application(Fun) ->
    Keys = [runtime_service_profile, evaluation_service_enabled,
            evaluation_service_options, evaluation_store,
            trace_store_enabled, trace_store_options,
            dev_provider_payload_inspection, memory_outbox_enabled,
            observability_bus_enabled, a2a_enabled, a2a_v1_enabled,
            http_health_enabled, dev_enabled],
    Saved = [{Key, application:get_env(erlang_adk, Key)} || Key <- Keys],
    _ = application:stop(erlang_adk),
    ok = application:set_env(erlang_adk, runtime_service_profile, disabled),
    lists:foreach(
      fun(Key) -> ok = application:set_env(erlang_adk, Key, false) end,
      [evaluation_service_enabled, trace_store_enabled,
       memory_outbox_enabled, observability_bus_enabled,
       a2a_enabled, a2a_v1_enabled, http_health_enabled, dev_enabled]),
    ok = application:set_env(erlang_adk,
                             dev_provider_payload_inspection, false),
    {ok, _} = application:ensure_all_started(erlang_adk),
    try Fun()
    after
        _ = application:stop(erlang_adk),
        lists:foreach(fun restore_env/1, Saved),
        {ok, _} = application:ensure_all_started(erlang_adk)
    end.

restore_env({Key, {ok, Value}}) ->
    application:set_env(erlang_adk, Key, Value);
restore_env({Key, undefined}) ->
    application:unset_env(erlang_adk, Key).

delete_outbox_tables() ->
    lists:foreach(
      fun(Table) -> _ = catch mnesia:delete_table(Table) end,
      [?OUTBOX_JOBS, ?OUTBOX_USAGE, ?OUTBOX_SCHEDULE]),
    ok.
