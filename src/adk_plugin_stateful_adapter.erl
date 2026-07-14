%% @doc adk_plugin adapter for an adk_plugin_instance process.
-module(adk_plugin_stateful_adapter).
-behaviour(adk_plugin).

-export([on_user_message/3, before_run/3, after_run/3,
         before_agent/3, after_agent/3,
         before_model/3, after_model/3, on_model_error/3,
         before_tool/3, after_tool/3, on_tool_error/3,
         on_event/3, on_agent_error/3, on_run_error/3, on_error/3]).

on_user_message(C, V, O) -> invoke(on_user_message, C, V, O).
before_run(C, V, O) -> invoke(before_run, C, V, O).
after_run(C, V, O) -> invoke(after_run, C, V, O).
before_agent(C, V, O) -> invoke(before_agent, C, V, O).
after_agent(C, V, O) -> invoke(after_agent, C, V, O).
before_model(C, V, O) -> invoke(before_model, C, V, O).
after_model(C, V, O) -> invoke(after_model, C, V, O).
on_model_error(C, V, O) -> invoke(on_model_error, C, V, O).
before_tool(C, V, O) -> invoke(before_tool, C, V, O).
after_tool(C, V, O) -> invoke(after_tool, C, V, O).
on_tool_error(C, V, O) -> invoke(on_tool_error, C, V, O).
on_event(C, V, O) -> invoke(on_event, C, V, O).
on_agent_error(C, V, O) -> invoke(on_agent_error, C, V, O).
on_run_error(C, V, O) -> invoke(on_run_error, C, V, O).
on_error(C, V, O) -> invoke(on_error, C, V, O).

invoke(Hook, Context, Value, Config) ->
    Instance = maps:get(instance, Config, undefined),
    Timeout = maps:get(timeout_ms, Config, 900),
    case adk_plugin_instance:invoke(
           Instance, Hook, Context, Value, Timeout) of
        {ok, Result} -> Result;
        {error, Reason} -> erlang:error({stateful_plugin_failed, Reason})
    end.
