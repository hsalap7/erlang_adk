-module(readme_agent_eval_adapter).
-behaviour(adk_eval_adapter).

-export([run_turn/5]).

run_turn(Agent, Turn, State, _Context, _Config) ->
    Input = maps:get(<<"input">>, Turn),
    case erlang_adk:prompt(Agent, Input) of
        {ok, Output} ->
            {ok, #{output => Output, state => State,
                   events => [], metadata => #{}}};
        {error, Reason} ->
            {error, Reason}
    end.
