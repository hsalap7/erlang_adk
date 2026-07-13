-module(adk_unloaded_callback).
-export([before_model/3, after_model/2]).

before_model(Config, _Memory, _Tools) ->
    notify(Config, before_model),
    case maps:get(callback_action, Config, continue) of
        halt -> {halt, {ok, <<"blocked by callback">>}};
        _ -> ok
    end.

after_model(Config, _Result) ->
    notify(Config, after_model),
    ok.

notify(Config, Event) ->
    case maps:get(callback_pid, Config, undefined) of
        Pid when is_pid(Pid) -> Pid ! Event;
        _ -> ok
    end.
