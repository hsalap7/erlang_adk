-module(adk_eval_simulation_test_user).
-behaviour(adk_eval_user_simulator).

-export([init/3, next_turn/4, terminate/2]).

init(_Scenario, _Context, _Config) -> {ok, 0}.
next_turn(_Transcript, State, _Context, _Config) when State < 2 ->
    {continue, #{<<"input">> => integer_to_binary(State)}, State + 1};
next_turn(_Transcript, State, _Context, _Config) -> {done, State}.
terminate(_State, _Config) -> ok.
