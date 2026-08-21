-module(adk_deployment_env_test).

-include_lib("eunit/include/eunit.hrl").

deployment_env_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun absent_environment_is_a_noop/0,
      fun valid_otlp_environment_installs_async_bus/0,
      fun standard_header_encoding_and_ows_are_canonicalized/0,
      fun repeated_configuration_is_idempotent/0,
      fun ambient_headers_do_not_enable_export/0,
      fun invalid_values_fail_without_reflection/0,
      fun invalid_encoded_header_fails_without_reflection/0,
      fun unsupported_header_metadata_and_invalid_utf8_are_rejected/0,
      fun incompatible_bus_timeout_fails_closed/0,
      fun trace_store_exporter_is_included_in_timeout_budget/0,
      fun reserved_exporter_id_fails_closed/0]}.

setup() ->
    #{endpoint => os:getenv("ERLANG_ADK_OTLP_ENDPOINT"),
      headers => os:getenv("OTEL_EXPORTER_OTLP_HEADERS"),
      bus_enabled => application:get_env(
                       erlang_adk, observability_bus_enabled),
      bus_options => application:get_env(
                       erlang_adk, observability_bus_options),
      trace_store_enabled => application:get_env(
                               erlang_adk, trace_store_enabled),
      trace_store_options => application:get_env(
                               erlang_adk, trace_store_options)}.

cleanup(Saved) ->
    restore_os("ERLANG_ADK_OTLP_ENDPOINT", maps:get(endpoint, Saved)),
    restore_os("OTEL_EXPORTER_OTLP_HEADERS", maps:get(headers, Saved)),
    restore_app(observability_bus_enabled, maps:get(bus_enabled, Saved)),
    restore_app(observability_bus_options, maps:get(bus_options, Saved)),
    restore_app(trace_store_enabled,
                maps:get(trace_store_enabled, Saved)),
    restore_app(trace_store_options,
                maps:get(trace_store_options, Saved)).

absent_environment_is_a_noop() ->
    reset(),
    ?assertEqual(ok, adk_deployment_env:configure()),
    ?assertEqual({ok, false},
                 application:get_env(
                   erlang_adk, observability_bus_enabled)),
    ?assertEqual({ok, #{}},
                 application:get_env(
                   erlang_adk, observability_bus_options)).

valid_otlp_environment_installs_async_bus() ->
    reset(),
    true = os:putenv("ERLANG_ADK_OTLP_ENDPOINT",
                     "https://collector.example"),
    true = os:putenv("OTEL_EXPORTER_OTLP_HEADERS",
                     "authorization=Bearer secret,x-tenant=blue"),
    ok = application:set_env(
           erlang_adk, observability_bus_options,
           #{batch_size => 7, max_attempts => 7}),
    ?assertEqual(ok, adk_deployment_env:configure()),
    ?assertEqual({ok, true},
                 application:get_env(
                   erlang_adk, observability_bus_enabled)),
    {ok, Options} = application:get_env(
                      erlang_adk, observability_bus_options),
    ?assertEqual(1, maps:get(batch_size, Options)),
    ?assertEqual(7, maps:get(max_attempts, Options)),
    [Descriptor] = maps:get(exporters, Options),
    ?assertEqual(adk_otlp_http_json_exporter,
                 maps:get(module, Descriptor)),
    Config = maps:get(config, Descriptor),
    ?assertEqual(<<"https://collector.example">>,
                 maps:get(endpoint, Config)),
    ?assertEqual(<<"Bearer secret">>,
                 maps:get(<<"authorization">>, maps:get(headers, Config))),
    ?assertEqual(3000, maps:get(timeout_ms, Config)),
    ?assertEqual(4000, maps:get(timeout_ms, Descriptor)),
    ?assertMatch(
       {ok, #{observability := #{delivery := async,
                                 capture_content := false}}},
       adk_trace_runtime:runner_options()).

standard_header_encoding_and_ows_are_canonicalized() ->
    reset(),
    true = os:putenv("ERLANG_ADK_OTLP_ENDPOINT",
                     "https://collector.example"),
    true = os:putenv("OTEL_EXPORTER_OTLP_HEADERS",
                     " authorization = Bearer%20secret , x-tenant = blue%2Cgreen "),
    ?assertEqual(ok, adk_deployment_env:configure()),
    {ok, Options} = application:get_env(
                      erlang_adk, observability_bus_options),
    [Descriptor] = maps:get(exporters, Options),
    Headers = maps:get(headers, maps:get(config, Descriptor)),
    ?assertEqual(<<"Bearer secret">>, maps:get(<<"authorization">>, Headers)),
    ?assertEqual(<<"blue,green">>, maps:get(<<"x-tenant">>, Headers)).

repeated_configuration_is_idempotent() ->
    reset(),
    true = os:putenv("ERLANG_ADK_OTLP_ENDPOINT",
                     "https://collector.example"),
    ?assertEqual(ok, adk_deployment_env:configure()),
    ?assertEqual(ok, adk_deployment_env:configure()),
    {ok, Options} = application:get_env(
                      erlang_adk, observability_bus_options),
    ?assertEqual(1, length(maps:get(exporters, Options))).

ambient_headers_do_not_enable_export() ->
    reset(),
    true = os:putenv("OTEL_EXPORTER_OTLP_HEADERS", "x-token=secret"),
    ?assertEqual(ok, adk_deployment_env:configure()),
    ?assertEqual({ok, false},
                 application:get_env(
                   erlang_adk, observability_bus_enabled)).

invalid_values_fail_without_reflection() ->
    reset(),
    Secret = "https://collector.example/path?token=do-not-reflect",
    true = os:putenv("ERLANG_ADK_OTLP_ENDPOINT", Secret),
    Error = adk_deployment_env:configure(),
    ?assertMatch(
       {error, {invalid_deployment_observability_config, exporter}}, Error),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Error),
                              unicode:characters_to_binary(Secret))).

invalid_encoded_header_fails_without_reflection() ->
    reset(),
    true = os:putenv("ERLANG_ADK_OTLP_ENDPOINT",
                     "https://collector.example"),
    Secret = "authorization=Bearer%20do-not-reflect,x=%GG",
    true = os:putenv("OTEL_EXPORTER_OTLP_HEADERS", Secret),
    Error = adk_deployment_env:configure(),
    ?assertEqual(
       {error, {invalid_deployment_observability_config, headers}}, Error),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Error),
                              unicode:characters_to_binary(Secret))).

unsupported_header_metadata_and_invalid_utf8_are_rejected() ->
    reset(),
    true = os:putenv("ERLANG_ADK_OTLP_ENDPOINT",
                     "https://collector.example"),
    true = os:putenv("OTEL_EXPORTER_OTLP_HEADERS",
                     "authorization=secret;property=value"),
    ?assertEqual(
       {error, {invalid_deployment_observability_config, headers}},
       adk_deployment_env:configure()),
    true = os:putenv("OTEL_EXPORTER_OTLP_HEADERS", "x-label=%FF"),
    ?assertEqual(
       {error, {invalid_deployment_observability_config, headers}},
       adk_deployment_env:configure()).

incompatible_bus_timeout_fails_closed() ->
    reset(),
    true = os:putenv("ERLANG_ADK_OTLP_ENDPOINT",
                     "https://collector.example"),
    ok = application:set_env(
           erlang_adk, observability_bus_options,
           #{batch_timeout_ms => 4000}),
    ?assertEqual(
       {error, {invalid_deployment_observability_config,
                incompatible_bus_timeout}},
       adk_deployment_env:configure()).

trace_store_exporter_is_included_in_timeout_budget() ->
    reset(),
    true = os:putenv("ERLANG_ADK_OTLP_ENDPOINT",
                     "https://collector.example"),
    ok = application:set_env(erlang_adk, trace_store_enabled, true),
    ok = application:set_env(erlang_adk, trace_store_options,
                             #{name => deployment_env_trace_store}),
    ?assertEqual(ok, adk_deployment_env:configure()),
    {ok, Options} = application:get_env(
                      erlang_adk, observability_bus_options),
    Exporters = maps:get(exporters, Options),
    ?assertEqual(
       [adk_otlp_http_json_exporter, adk_trace_store_exporter],
       [maps:get(module, Exporter) || Exporter <- Exporters]),
    ?assertEqual(1, maps:get(batch_size, Options)),
    TimeoutSum = lists:sum(
                   [maps:get(timeout_ms, Exporter) || Exporter <- Exporters]),
    ?assert(maps:get(batch_timeout_ms, Options) > TimeoutSum + 250).

reserved_exporter_id_fails_closed() ->
    reset(),
    true = os:putenv("ERLANG_ADK_OTLP_ENDPOINT",
                     "https://collector.example"),
    Conflict = #{id => <<"erlang-adk-deployment-otlp">>,
                 module => adk_trace_store_exporter,
                 config => #{server => some_store,
                             principal => <<"principal">>}},
    ok = application:set_env(
           erlang_adk, observability_bus_options,
           #{exporters => [Conflict]}),
    ?assertEqual(
       {error, {invalid_deployment_observability_config,
                exporter_id_conflict}},
       adk_deployment_env:configure()).

reset() ->
    _ = os:unsetenv("ERLANG_ADK_OTLP_ENDPOINT"),
    _ = os:unsetenv("OTEL_EXPORTER_OTLP_HEADERS"),
    ok = application:set_env(erlang_adk, observability_bus_enabled, false),
    ok = application:set_env(erlang_adk, observability_bus_options, #{}),
    ok = application:set_env(erlang_adk, trace_store_enabled, false),
    application:set_env(erlang_adk, trace_store_options, #{}).

restore_os(Name, false) -> _ = os:unsetenv(Name), ok;
restore_os(Name, Value) -> true = os:putenv(Name, Value), ok.

restore_app(Key, undefined) -> application:unset_env(erlang_adk, Key);
restore_app(Key, {ok, Value}) -> application:set_env(erlang_adk, Key, Value).
