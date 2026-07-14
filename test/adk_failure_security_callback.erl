-module(adk_failure_security_callback).
-behaviour(adk_callbacks).

-export([set_observer/1, clear_observer/0,
         before_model/3, on_tool_end/2, on_error/1]).

set_observer(Pid) when is_pid(Pid) ->
    persistent_term:put({?MODULE, observer}, Pid),
    ok.

clear_observer() ->
    persistent_term:erase({?MODULE, observer}),
    ok.

before_model(Config, _Memory, _Tools) ->
    notify({security_callback, before_model, Config}),
    continue.

on_tool_end(_Name, Result) ->
    notify({security_callback, on_tool_end, Result}),
    ok.

on_error(Failure) ->
    notify({security_callback, on_error, Failure}),
    ok.

notify(Message) ->
    case persistent_term:get({?MODULE, observer}, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.
