-module(adk_plugin_integration_plugin).
-behaviour(adk_plugin).

-export([on_user_message/3, before_run/3, after_run/3,
         before_agent/3, after_agent/3,
         before_model/3, after_model/3, on_model_error/3,
         before_tool/3, after_tool/3, on_tool_error/3,
         on_event/3, on_error/3]).

on_user_message(C, V, O) -> execute(on_user_message, C, V, O).
before_run(C, V, O) -> execute(before_run, C, V, O).
after_run(C, V, O) -> execute(after_run, C, V, O).
before_agent(C, V, O) -> execute(before_agent, C, V, O).
after_agent(C, V, O) -> execute(after_agent, C, V, O).
before_model(C, V, O) -> execute(before_model, C, V, O).
after_model(C, V, O) -> execute(after_model, C, V, O).
on_model_error(C, V, O) -> execute(on_model_error, C, V, O).
before_tool(C, V, O) -> execute(before_tool, C, V, O).
after_tool(C, V, O) -> execute(after_tool, C, V, O).
on_tool_error(C, V, O) -> execute(on_tool_error, C, V, O).
on_event(C, V, O) -> execute(on_event, C, V, O).
on_error(C, V, O) -> execute(on_error, C, V, O).

execute(Hook, _Context, Value, Config) ->
    case maps:get(test_pid, Config, undefined) of
        Pid when is_pid(Pid) -> Pid ! {integration_plugin, Hook};
        _ -> ok
    end,
    Actions = maps:get(actions, Config, #{}),
    case maps:get(Hook, Actions, observe) of
        observe -> observe;
        {replace, Replacement} -> {replace, Replacement};
        {halt, Replacement} -> {halt, Replacement};
        {replace_fun, Fun} when is_function(Fun, 1) ->
            {replace, Fun(Value)}
    end.
