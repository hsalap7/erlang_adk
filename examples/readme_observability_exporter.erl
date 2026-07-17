-module(readme_observability_exporter).
-behaviour(adk_observability_exporter).

-export([export/2]).

export(Envelope, Config) ->
    case maps:get(target, Config, undefined) of
        Pid when is_pid(Pid) ->
            Pid ! {adk_observation, Envelope},
            ok;
        _ ->
            {error, missing_target}
    end.
