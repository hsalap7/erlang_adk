-module(adk_eval_set_static_judge).
-behaviour(adk_eval_metric).

-export([score/4]).

score(_Expected, _Actual, _Context, Config) ->
    {ok, maps:get(score, Config, 0.8),
     #{judge => <<"deterministic-static">>}}.
