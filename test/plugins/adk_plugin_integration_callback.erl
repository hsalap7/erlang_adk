-module(adk_plugin_integration_callback).
-behaviour(adk_callbacks).

-export([on_agent_start/2, on_agent_end/2,
         on_tool_start/2, on_tool_end/2,
         before_agent/2, after_agent/2,
         before_model/3, after_model/2,
         before_tool/3, after_tool/4,
         on_error/1]).

on_agent_start(_Name, _Input) -> notify(on_agent_start), ok.
on_agent_end(_Name, _Output) -> notify(on_agent_end), ok.
on_tool_start(_Name, _Args) -> notify(on_tool_start), ok.
on_tool_end(_Name, _Result) -> notify(on_tool_end), ok.
before_agent(_Name, _Input) -> notify(before_agent), continue.
after_agent(_Name, _Output) -> notify(after_agent), continue.
before_model(_Config, _Memory, _Tools) -> notify(before_model), continue.
after_model(_Config, _Result) -> notify(after_model), continue.
before_tool(_Name, _Args, _Context) -> notify(before_tool), continue.
after_tool(_Name, _Args, _Context, _Result) -> notify(after_tool), continue.
on_error(_Reason) -> notify(on_error), ok.

notify(Hook) ->
    case persistent_term:get({?MODULE, target}, undefined) of
        Pid when is_pid(Pid) -> Pid ! {integration_callback, Hook};
        _ -> ok
    end.
