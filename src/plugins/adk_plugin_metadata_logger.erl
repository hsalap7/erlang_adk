%% @doc Content-free structured lifecycle metadata logger.
-module(adk_plugin_metadata_logger).
-behaviour(adk_plugin).

-export([on_user_message/3, before_run/3, after_run/3,
         before_agent/3, after_agent/3,
         before_model/3, after_model/3, on_model_error/3,
         before_tool/3, after_tool/3, on_tool_error/3,
         on_event/3, on_agent_error/3, on_run_error/3, on_error/3]).

on_user_message(C, V, O) -> emit(on_user_message, C, V, O).
before_run(C, V, O) -> emit(before_run, C, V, O).
after_run(C, V, O) -> emit(after_run, C, V, O).
before_agent(C, V, O) -> emit(before_agent, C, V, O).
after_agent(C, V, O) -> emit(after_agent, C, V, O).
before_model(C, V, O) -> emit(before_model, C, V, O).
after_model(C, V, O) -> emit(after_model, C, V, O).
on_model_error(C, V, O) -> emit(on_model_error, C, V, O).
before_tool(C, V, O) -> emit(before_tool, C, V, O).
after_tool(C, V, O) -> emit(after_tool, C, V, O).
on_tool_error(C, V, O) -> emit(on_tool_error, C, V, O).
on_event(C, V, O) -> emit(on_event, C, V, O).
on_agent_error(C, V, O) -> emit(on_agent_error, C, V, O).
on_run_error(C, V, O) -> emit(on_run_error, C, V, O).
on_error(C, V, O) -> emit(on_error, C, V, O).

emit(Hook, Context, Value, Config) ->
    Metadata = metadata(Hook, Context, Value, Config),
    telemetry:execute([erlang_adk, plugin, metadata], #{count => 1},
                      Metadata),
    maybe_log(Metadata, maps:get(log_level, Config, none)),
    observe.

metadata(Hook, Context, Value, Config) ->
    Allowed = [<<"run_id">>, <<"invocation_id">>, <<"session">>,
               <<"app_name">>, <<"user_id">>, <<"agent">>,
               <<"model">>, <<"phase">>, <<"tool">>, <<"call_id">>],
    Base = maps:with(Allowed, Context),
    Base#{hook => Hook,
          plugin_id => maps:get(id, Config, <<"metadata-logger">>),
          value_type => value_type(Value)}.

maybe_log(_Metadata, none) -> ok;
maybe_log(Metadata, Level)
  when Level =:= debug; Level =:= info;
       Level =:= notice; Level =:= warning ->
    logger:log(Level, "ADK plugin lifecycle metadata: ~p", [Metadata]);
maybe_log(_Metadata, _Invalid) ->
    erlang:error(invalid_metadata_logger_level).

value_type(Value) when is_binary(Value) -> binary;
value_type(Value) when is_map(Value) -> map;
value_type(Value) when is_list(Value) -> list;
value_type(Value) when is_tuple(Value) -> tuple;
value_type(Value) when is_atom(Value) -> atom;
value_type(Value) when is_number(Value) -> number;
value_type(_) -> other.
