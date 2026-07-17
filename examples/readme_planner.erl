%% @doc Deterministic explicit planner used by the README and public API tests.
-module(readme_planner).
-behaviour(adk_planner).

-export([plan/4, review/6]).

plan(_Target, Goal, Context, Config) ->
    Value = maps:get(
              result, Config,
              #{<<"goal">> => Goal,
                <<"invocation_id">> =>
                    maps:get(<<"invocation_id">>, Context, null)}),
    {ok, Step} = adk_plan:step(
                   <<"return-result">>,
                   <<"Return the application-approved result">>,
                   #{<<"kind">> => <<"return">>,
                     <<"value">> => Value}),
    adk_plan:new(<<"readme-plan">>, 0, Goal, [Step],
                 #{<<"source">> => <<"readme_planner">>}).

review(_Target, _Plan, _Step, Observation, _Context, _Config) ->
    case maps:get(<<"status">>, Observation) of
        <<"ok">> -> {complete, maps:get(<<"output">>, Observation)};
        <<"error">> -> {fail, maps:get(<<"error">>, Observation)}
    end.
