-module(adk_plugin_test_plugin).
-behaviour(adk_plugin).

-export([on_user_message/3, before_run/3, after_run/3,
         before_agent/3, after_agent/3,
         before_model/3, after_model/3, on_model_error/3,
         before_tool/3, after_tool/3, on_tool_error/3,
         on_event/3, on_agent_error/3, on_run_error/3, on_error/3]).

on_user_message(Context, Value, Config) -> execute(Context, Value, Config).
before_run(Context, Value, Config) -> execute(Context, Value, Config).
after_run(Context, Value, Config) -> execute(Context, Value, Config).
before_agent(Context, Value, Config) -> execute(Context, Value, Config).
after_agent(Context, Value, Config) -> execute(Context, Value, Config).
before_model(Context, Value, Config) -> execute(Context, Value, Config).
after_model(Context, Value, Config) -> execute(Context, Value, Config).
on_model_error(Context, Value, Config) -> execute(Context, Value, Config).
before_tool(Context, Value, Config) -> execute(Context, Value, Config).
after_tool(Context, Value, Config) -> execute(Context, Value, Config).
on_tool_error(Context, Value, Config) -> execute(Context, Value, Config).
on_event(Context, Value, Config) -> execute(Context, Value, Config).
on_agent_error(Context, Value, Config) -> execute(Context, Value, Config).
on_run_error(Context, Value, Config) -> execute(Context, Value, Config).
on_error(Context, Value, Config) -> execute(Context, Value, Config).

execute(Context, Value, Config) ->
    notify(Config, Context, Value),
    case maps:get(action, Config, observe) of
        observe -> observe;
        amend -> {amend, maps:get(amendment, Config)};
        return -> {return, maps:get(returned, Config)};
        replace -> {replace, maps:get(replacement, Config)};
        halt -> {halt, maps:get(reason, Config, stopped)};
        invalid -> invalid_callback_result;
        crash -> erlang:error(plugin_test_crash);
        timeout ->
            timer:sleep(maps:get(delay_ms, Config, 1000)),
            observe;
        unsafe_result -> {return, self()};
        large_result ->
            {return, binary:copy(<<"x">>,
                                 maps:get(result_bytes, Config, 1048576))};
        heap_bomb -> heap_bomb([])
    end.

notify(Config, Context, Value) ->
    case maps:get(test_pid, Config, undefined) of
        Pid when is_pid(Pid) ->
            Pid ! {plugin_called, maps:get(label, Config, undefined),
                   Context, Value},
            case maps:get(report_worker, Config, false) of
                true -> Pid ! {plugin_worker, self()};
                false -> ok
            end;
        _ -> ok
    end.

heap_bomb(Acc) ->
    heap_bomb([lists:duplicate(1000, 42) | Acc]).
