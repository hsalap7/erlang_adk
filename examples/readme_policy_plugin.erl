-module(readme_policy_plugin).
-behaviour(adk_plugin).

-export([before_run/3, before_tool/3]).

before_run(Context, _Value, Config) ->
    notify(before_run, Context, Config),
    observe.

before_tool(Context, _Value, Config) ->
    notify(before_tool, Context, Config),
    observe.

notify(Hook, Context, Config) ->
    case maps:get(notify, Config, undefined) of
        Pid when is_pid(Pid) -> Pid ! {adk_plugin, Hook, Context};
        _ -> ok
    end.
