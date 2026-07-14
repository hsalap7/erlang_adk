-module(adk_observability_test_exporter).
-behaviour(adk_observability_exporter).

-export([export/2]).

export(Envelope, Config) ->
    case maps:get(test_pid, Config, undefined) of
        Pid when is_pid(Pid) ->
            Pid ! {exported, maps:get(label, Config, undefined), Envelope};
        _ -> ok
    end,
    case maps:get(action, Config, ok) of
        ok -> ok;
        error -> {error, deliberately_failed};
        crash -> erlang:error(deliberately_crashed);
        timeout ->
            timer:sleep(maps:get(delay_ms, Config, 1000)),
            ok
    end.
