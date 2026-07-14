-module(readme_exact_metric).
-behaviour(adk_eval_metric).

-export([score/4]).

score(Expected, Actual, _Context, _Config) ->
    case Expected =:= Actual of
        true -> 1.0;
        false -> 0.0
    end.
