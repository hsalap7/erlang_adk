-module(adk_eval_case_metric_probe).
-behaviour(adk_eval_case_metric).

-export([score_case/2]).

score_case(Input, Config) ->
    case maps:get(action, Config, score) of
        score ->
            Turns = maps:get(<<"turns">>, Input),
            Trajectory = maps:get(<<"trajectory">>, Input),
            {ok, maps:get(score, Config, 1.0),
             #{turn_count => length(Turns),
               trajectory_count => length(Trajectory)}};
        not_evaluated ->
            {not_evaluated, #{reason => <<"fixture">>}};
        error ->
            {error, fixture_failure};
        crash ->
            erlang:error(fixture_crash)
    end.
