-module(adk_eval_simulation_test).

-include_lib("eunit/include/eunit.hrl").

bounded_user_and_environment_test() ->
    User = #{module => adk_eval_simulation_test_user},
    Environment = #{module => adk_eval_simulation_test_environment},
    {ok, Simulation0} = adk_eval_simulation:start(
                          User, Environment, #{}, #{max_steps => 2}),
    {continue, #{<<"input">> := <<"0">>}, Simulation1} =
        adk_eval_simulation:next_user(Simulation0, [], #{}),
    {ok, #{<<"total">> := 3}, Simulation2} =
        adk_eval_simulation:handle_effect(
          Simulation1, #{<<"add">> => 3}, #{}),
    {continue, _, Simulation3} =
        adk_eval_simulation:next_user(Simulation2, [], #{}),
    ?assertEqual({error, eval_simulation_step_limit_exceeded},
                 adk_eval_simulation:next_user(Simulation3, [], #{})),
    ?assertEqual(ok, adk_eval_simulation:stop(Simulation3)).

strict_module_and_value_boundaries_test() ->
    ?assertMatch({error, {eval_simulator_missing_callback, user}},
                 adk_eval_simulation:start(
                   #{module => ?MODULE}, undefined, #{}, #{})),
    User = #{module => adk_eval_simulation_test_user},
    ?assertEqual({error, invalid_eval_simulation_scenario},
                 adk_eval_simulation:start(
                   User, undefined, #{<<"pid">> => self()}, #{})),
    ?assertMatch({error, {unknown_eval_simulation_options, _}},
                 adk_eval_simulation:start(
                   User, undefined, #{}, #{raw_command => <<"no">>})).
