-module(adk_failure_security_plugin).
-behaviour(adk_plugin).

-export([on_model_error/3, on_tool_error/3, on_error/3]).

on_model_error(_Context, Value, Config) ->
    notify(on_model_error, Value, Config),
    observe.

on_tool_error(_Context, Value, Config) ->
    notify(on_tool_error, Value, Config),
    observe.

on_error(_Context, Value, Config) ->
    notify(on_error, Value, Config),
    observe.

notify(Hook, Value, Config) ->
    case maps:get(observer, Config, undefined) of
        Pid when is_pid(Pid) ->
            Pid ! {security_plugin, Hook, Value};
        _ -> ok
    end.
