-module(adk_unloaded_callback).
-export([before_model/3, after_model/2]).

before_model(Config, _Memory, _Tools) ->
    notify(before_model),
    CallbackConfig = maps:get(callback_config, Config, #{}),
    case maps:get(action, CallbackConfig, continue) of
        halt -> {halt, {ok, <<"blocked by callback">>}};
        _ -> ok
    end.

after_model(Config, _Result) ->
    _ = Config,
    notify(after_model),
    ok.

notify(Event) ->
    case persistent_term:get({?MODULE, observer}, undefined) of
        Pid when is_pid(Pid) -> Pid ! Event;
        _ -> ok
    end.
