-module(adk_eval_simulation_test_environment).
-behaviour(adk_eval_environment_simulator).

-export([init/3, handle_effect/4]).

init(_Scenario, _Context, _Config) -> {ok, 0}.
handle_effect(#{<<"add">> := Value}, State, _Context, _Config)
  when is_integer(Value) ->
    Total = State + Value,
    {ok, #{<<"total">> => Total}, Total}.
