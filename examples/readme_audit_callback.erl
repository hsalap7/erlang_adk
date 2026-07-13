-module(readme_audit_callback).
-behaviour(adk_callbacks).

-export([before_model/3, after_model/2, before_tool/3, after_tool/4]).

before_model(Config, _Memory, Tools) ->
    notify(Config, {before_model, length(Tools)}),
    ok.

after_model(Config, ProviderResult) ->
    notify(Config, {after_model, ProviderResult}),
    ok.

before_tool(_ToolName, _Args, _Context) ->
    ok.

after_tool(_ToolName, _Args, _Context, _ToolResult) ->
    ok.

notify(Config, Message) ->
    case maps:get(callback_pid, Config, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.
