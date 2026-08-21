-module(adk_deployment_lifecycle_test).

-include_lib("eunit/include/eunit.hrl").

deployment_lifecycle_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun dependency_aware_health_is_ready/0,
      fun drain_is_bounded_and_rejects_new_admission/0]}.

setup() ->
    Keys = [runtime_service_profile, evaluation_service_enabled,
            trace_store_enabled, memory_outbox_enabled,
            observability_bus_enabled, a2a_enabled, a2a_v1_enabled,
            http_health_enabled, dev_enabled],
    Saved = [{Key, application:get_env(erlang_adk, Key)} || Key <- Keys],
    ok = application:set_env(erlang_adk, runtime_service_profile, disabled),
    lists:foreach(
      fun(Key) -> ok = application:set_env(erlang_adk, Key, false) end,
      lists:delete(runtime_service_profile, Keys)),
    {ok, _} = application:ensure_all_started(erlang_adk),
    Saved.

cleanup(Saved) ->
    _ = application:stop(erlang_adk),
    lists:foreach(fun restore_env/1, Saved),
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok.

dependency_aware_health_is_ready() ->
    ?assertMatch({ok, #{status := live}},
                 adk_deployment_lifecycle:liveness()),
    {ok, Ready} = adk_deployment_lifecycle:readiness(),
    ?assertEqual(true, maps:get(ready, Ready)),
    ?assertEqual(false, maps:get(draining, Ready)),
    ?assertEqual(0, adk_deployment_lifecycle:liveness_code()),
    ?assertEqual(0, adk_deployment_lifecycle:readiness_code()).

drain_is_bounded_and_rejects_new_admission() ->
    Parent = self(),
    Owner = spawn(
              fun() ->
                  {ok, Permit} = adk_admission_control:acquire(
                                   <<"deployment-drain-test">>, #{}),
                  Parent ! {admission_acquired, self(), Permit},
                  receive
                      release ->
                          ok = adk_admission_control:release(Permit)
                  end
              end),
    receive
        {admission_acquired, Owner, _Permit} -> ok
    after 1000 -> erlang:error(admission_not_acquired)
    end,
    ?assertMatch({error, {drain_timeout, 1}},
                 adk_deployment_lifecycle:begin_drain(1)),
    ?assertEqual(
       {error, deployment_draining},
       adk_admission_control:acquire(<<"new-work">>, #{})),
    ?assertMatch({error, {not_ready, _}},
                 adk_deployment_lifecycle:readiness()),
    Owner ! release,
    OwnerMonitor = erlang:monitor(process, Owner),
    receive
        {'DOWN', OwnerMonitor, process, Owner, normal} -> ok
    after 1000 -> erlang:error(admission_owner_not_stopped)
    end,
    {ok, Drained} = adk_deployment_lifecycle:begin_drain(1000),
    ?assertEqual(true, maps:get(draining, Drained)),
    ?assertEqual(0, maps:get(active_admissions, Drained)),
    ?assertEqual(1, adk_deployment_lifecycle:readiness_code()).

restore_env({Key, {ok, Value}}) ->
    application:set_env(erlang_adk, Key, Value);
restore_env({Key, undefined}) ->
    application:unset_env(erlang_adk, Key).
