-module(erlang_adk_planning_test).
-include_lib("eunit/include/eunit.hrl").

public_planning_api_test_() ->
    {setup,
     fun setup_examples/0,
     fun cleanup_examples/1,
     [fun sync_defaults/0,
      fun sync_options/0,
      fun async_default_cancel_and_await/0,
      fun async_timeout_custom_cancel_and_ownership/0,
      fun malformed_refs_fail_explicitly/0]}.

sync_defaults() ->
    Goal = #{<<"task">> => <<"prepare release">>},
    Context = #{<<"invocation_id">> => <<"planning-public-default">>},
    {ok, Result} = erlang_adk:run_planning(
                     planner(#{}), executor(undefined, #{}),
                     Goal, Context),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Result)),
    ?assertEqual(
       #{<<"goal">> => Goal,
         <<"invocation_id">> => <<"planning-public-default">>},
       maps:get(<<"result">>, Result)),
    ?assertEqual(1, maps:get(<<"steps_executed">>, Result)).

sync_options() ->
    Expected = #{<<"release">> => <<"0.3.0">>,
                 <<"ready">> => true},
    {ok, Result} = erlang_adk:run_planning(
                     planner(#{result => Expected}),
                     executor(undefined, #{}),
                     <<"check release">>, #{},
                     #{max_steps => 1,
                       max_replans => 0,
                       result_metadata =>
                           #{<<"build">> => <<"public-wrapper">>,
                             <<"api_key">> => <<"must-not-leak">>}}),
    ?assertEqual(Expected, maps:get(<<"result">>, Result)),
    ?assertEqual(#{<<"build">> => <<"public-wrapper">>},
                 maps:get(<<"metadata">>, Result)).

async_default_cancel_and_await() ->
    NotifyRef = make_ref(),
    {ok, PlanningRef} = erlang_adk:start_planning(
                          planner(#{}),
                          executor(self(),
                                   #{delay_ms => 5000,
                                     notify_ref => NotifyRef}),
                          <<"cancel default">>, #{}),
    _Worker = await_executor_start(NotifyRef),
    ok = erlang_adk:cancel_planning(PlanningRef),
    {ok, Result} = erlang_adk:await_planning(PlanningRef),
    ?assertEqual(<<"cancelled">>, maps:get(<<"status">>, Result)),
    Error = maps:get(<<"error">>, Result),
    ?assertEqual(<<"user_cancelled">>, maps:get(<<"reason">>, Error)).

async_timeout_custom_cancel_and_ownership() ->
    NotifyRef = make_ref(),
    {ok, PlanningRef} = erlang_adk:start_planning(
                          planner(#{}),
                          executor(self(),
                                   #{delay_ms => 5000,
                                     notify_ref => NotifyRef}),
                          <<"cancel custom">>, #{},
                          #{timeout_ms => 10000,
                            callback_timeout_ms => 9000}),
    ?assertEqual({error, planning_await_timeout},
                 erlang_adk:await_planning(PlanningRef, 0)),
    _Worker = await_executor_start(NotifyRef),
    Parent = self(),
    Other = spawn(fun() ->
        Parent ! {foreign_planning_results,
                  erlang_adk:await_planning(PlanningRef, 0),
                  erlang_adk:cancel_planning(PlanningRef)}
    end),
    OtherMonitor = erlang:monitor(process, Other),
    receive
        {foreign_planning_results,
         {error, not_planning_owner},
         {error, not_planning_owner}} -> ok
    after 1000 -> erlang:error(foreign_owner_check_timed_out)
    end,
    receive
        {'DOWN', OtherMonitor, process, Other, normal} -> ok
    after 1000 -> erlang:error(foreign_owner_did_not_exit)
    end,
    ok = erlang_adk:cancel_planning(
           PlanningRef,
           #{reason => caller_requested,
             access_token => <<"must-not-leak">>}),
    {ok, Result} = erlang_adk:await_planning(PlanningRef, 1000),
    ?assertEqual(<<"cancelled">>, maps:get(<<"status">>, Result)),
    Reason = maps:get(<<"reason">>, maps:get(<<"error">>, Result)),
    ?assertEqual(<<"caller_requested">>, maps:get(<<"reason">>, Reason)),
    ?assertNot(maps:is_key(<<"access_token">>, Reason)).

malformed_refs_fail_explicitly() ->
    ?assertEqual({error, invalid_planning_ref},
                 erlang_adk:await_planning(not_a_planning_ref, 0)),
    ?assertEqual({error, invalid_planning_ref},
                 erlang_adk:cancel_planning(not_a_planning_ref)),
    SwappedTypes = {adk_planning_ref, self(), make_ref(), self()},
    ?assertEqual({error, invalid_planning_ref},
                 erlang_adk:await_planning(SwappedTypes, 0)),
    ?assertEqual({error, invalid_planning_ref},
                 erlang_adk:cancel_planning(SwappedTypes, test)).

planner(Config) ->
    #{module => readme_planner, target => undefined, config => Config}.

executor(Target, Config) ->
    #{module => readme_plan_executor, target => Target, config => Config}.

await_executor_start(NotifyRef) ->
    receive
        {readme_plan_step_started, NotifyRef, Worker, <<"return-result">>}
          when is_pid(Worker) -> Worker
    after 1000 -> erlang:error(plan_executor_not_started)
    end.

setup_examples() ->
    Modules = [readme_planner, readme_plan_executor],
    lists:foreach(fun compile_and_load_example/1, Modules),
    Modules.

cleanup_examples(Modules) ->
    lists:foreach(
      fun(Module) ->
          _ = code:purge(Module),
          _ = code:delete(Module)
      end, Modules),
    ok.

compile_and_load_example(Module) ->
    Path = filename:absname(
             filename:join("examples", atom_to_list(Module) ++ ".erl")),
    case compile:file(Path, [binary, return_errors, return_warnings]) of
        {ok, Module, Beam} -> load_example(Module, Path, Beam);
        {ok, Module, Beam, []} -> load_example(Module, Path, Beam);
        {ok, Module, _Beam, Warnings} ->
            erlang:error({example_compile_warnings, Module, Warnings});
        {error, Errors, Warnings} ->
            erlang:error(
              {example_compile_failed, Module, Errors, Warnings})
    end.

load_example(Module, Path, Beam) ->
    _ = code:purge(Module),
    _ = code:delete(Module),
    {module, Module} = code:load_binary(Module, Path, Beam),
    ok.
