-module(adk_trace_runtime_test).

-include_lib("eunit/include/eunit.hrl").

-define(KEYS, [trace_store_enabled, trace_store_options,
               trace_store_principal, observability_bus_options,
               observability_bus_enabled, runtime_service_profile]).

standard_runtime_paths_are_wired_when_trace_store_is_enabled_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Saved = save_env(),
    StoreName = adk_trace_runtime_test_store,
    BusName = adk_trace_runtime_test_bus,
    Principal = <<"trace-runtime-principal">>,
    {ok, Store} = adk_trace_store:start_link(
                    #{name => StoreName,
                      max_events => 64,
                      max_bytes => 1048576,
                      max_event_bytes => 65536,
                      max_principals => 4,
                      max_events_per_principal => 64,
                      max_bytes_per_principal => 1048576,
                      max_query_events => 64,
                      max_query_bytes => 1048576}),
    try
        application:set_env(erlang_adk, trace_store_enabled, true),
        application:set_env(erlang_adk, trace_store_options,
                            #{name => StoreName}),
        application:set_env(erlang_adk, trace_store_principal, Principal),
        application:set_env(erlang_adk, observability_bus_enabled, false),
        application:set_env(erlang_adk, observability_bus_options,
                            #{name => BusName}),
        application:set_env(erlang_adk, runtime_service_profile, disabled),

        {ok, true} = adk_trace_runtime:bus_enabled(false),
        {ok, BusOptions} = adk_trace_runtime:configure_bus_options(
                             #{name => BusName}),
        [Exporter] = maps:get(exporters, BusOptions),
        ?assertEqual(adk_trace_store_exporter,
                     maps:get(module, Exporter)),
        ?assertEqual(#{principal => Principal, server => StoreName},
                     maps:get(config, Exporter)),

        {ok, #{runner_options := RunnerOptions}} =
            erlang_adk:runtime_runner_spec(),
        ?assertEqual(
           #{delivery => async, bus => BusName, failure_policy => open,
             capture_content => false, attributes => #{}},
           maps:get(observability, RunnerOptions)),

        {ok, Compiled} = erlang_adk:compile_workflow(
                           #{version => 1,
                             id => <<"trace_runtime_workflow">>,
                             kind => sequential,
                             definition_revision => 1,
                             max_steps => 2,
                             steps =>
                                 [#{id => <<"work">>,
                                    run => fun(State) ->
                                        {output, <<"done">>, State}
                                    end}]}),
        ?assertMatch({completed, _, _},
                     erlang_adk:run_workflow(Compiled, #{})),
        Page = await_terminal(StoreName, Principal, 100),
        ?assert(lists:any(
                  fun(Event) ->
                      maps:get(<<"type">>, maps:get(<<"event">>, Event))
                        =:= <<"workflow_terminal">>
                  end, maps:get(<<"events">>, Page)))
    after
        gen_server:stop(Store),
        restore_env(Saved)
    end.

invalid_trace_runtime_configuration_fails_without_reflection_test() ->
    Saved = save_env(),
    SecretLikePrincipal = <<"identity-not-for-diagnostics">>,
    try
        application:set_env(erlang_adk, trace_store_enabled, true),
        application:set_env(erlang_adk, trace_store_options, #{}),
        application:set_env(erlang_adk, observability_bus_options, #{}),
        application:set_env(erlang_adk, trace_store_principal,
                            {invalid, SecretLikePrincipal}),
        Error = adk_trace_runtime:runner_options(),
        ?assertMatch(
           {error, {invalid_application_env, trace_store_principal}},
           Error),
        ?assertEqual(nomatch,
                     binary:match(term_to_binary(Error),
                                  SecretLikePrincipal))
    after
        restore_env(Saved)
    end.

await_terminal(_Store, _Principal, 0) ->
    error(trace_runtime_terminal_event_missing);
await_terminal(Store, Principal, Attempts) ->
    {ok, Page} = adk_trace_store:query(Store, Principal, all, #{}),
    case lists:any(
           fun(Event) ->
               maps:get(<<"type">>, maps:get(<<"event">>, Event))
                 =:= <<"workflow_terminal">>
           end, maps:get(<<"events">>, Page)) of
        true -> Page;
        false ->
            timer:sleep(5),
            await_terminal(Store, Principal, Attempts - 1)
    end.

save_env() ->
    [{Key, application:get_env(erlang_adk, Key)} || Key <- ?KEYS].

restore_env(Saved) ->
    lists:foreach(
      fun({Key, undefined}) -> application:unset_env(erlang_adk, Key);
         ({Key, {ok, Value}}) ->
              application:set_env(erlang_adk, Key, Value)
      end, Saved).
