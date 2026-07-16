-module(adk_eval_set_exact_metric).
-behaviour(adk_eval_metric).

-export([score/4]).

score(Expected, Actual, _Context, Config) ->
    case maps:get(action, Config, score) of
        crash -> erlang:error(metric_crash);
        invalid -> not_a_score;
        score ->
            Score = case Expected =:= Actual of true -> 1.0; false -> 0.0 end,
            {ok, Score, #{deterministic => true,
                          access_token => <<"metric-secret">>}}
    end.
