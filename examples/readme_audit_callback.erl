-module(readme_audit_callback).
-behaviour(adk_callbacks).

-export([set_observer/1, clear_observer/0,
         before_model/3, after_model/2, before_tool/3, after_tool/4]).

set_observer(Pid) when is_pid(Pid) ->
    persistent_term:put({?MODULE, observer}, Pid),
    ok.

clear_observer() ->
    persistent_term:erase({?MODULE, observer}),
    ok.

before_model(_Config, _Memory, Tools) ->
    notify({before_model, length(Tools)}),
    ok.

after_model(_Config, ProviderResult) ->
    notify({after_model, ProviderResult}),
    ok.

before_tool(_ToolName, _Args, _Context) ->
    ok.

after_tool(_ToolName, _Args, _Context, _ToolResult) ->
    ok.

notify(Message) ->
    case persistent_term:get({?MODULE, observer}, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.
