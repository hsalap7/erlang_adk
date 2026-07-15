%% @doc Convert a tool failure into bounded, model-visible retry guidance.
-module(adk_plugin_reflect_retry).
-behaviour(adk_plugin).

-export([on_tool_error/3]).

-define(DEFAULT_GUIDANCE,
        <<"Reflect on the tool error, correct the arguments, and retry only "
          "when the operation is safe and idempotent.">>).

on_tool_error(Context, Failure, Config) when is_map(Config) ->
    Enabled = maps:get(enabled, Config, true),
    MaxAttempts = maps:get(max_attempts, Config, 1),
    Attempt = maps:get(<<"retry_attempt">>, Context,
                       maps:get(retry_attempt, Context, 0)),
    Guidance = maps:get(guidance, Config, ?DEFAULT_GUIDANCE),
    case valid_config(Enabled, MaxAttempts, Guidance) of
        false -> erlang:error(invalid_reflect_retry_plugin_config);
        true when Enabled =:= false -> observe;
        true when Attempt >= MaxAttempts -> observe;
        true ->
            {return,
             #{<<"adk_retry">> =>
                   #{<<"retryable">> => true,
                     <<"attempt">> => Attempt + 1,
                     <<"max_attempts">> => MaxAttempts,
                     <<"guidance">> => Guidance,
                     <<"error">> => failure_summary(Failure)}}}
    end.

valid_config(Enabled, MaxAttempts, Guidance) ->
    is_boolean(Enabled) andalso is_integer(MaxAttempts) andalso
    MaxAttempts > 0 andalso MaxAttempts =< 16 andalso
    is_binary(Guidance) andalso byte_size(Guidance) > 0 andalso
    byte_size(Guidance) =< 4096.

failure_summary({adk_failure, Failure}) when is_map(Failure) ->
    #{<<"component">> => safe_scalar(maps:get(component, Failure, unknown)),
      <<"operation">> => safe_scalar(maps:get(operation, Failure, unknown)),
      <<"class">> => safe_scalar(maps:get(class, Failure, external)),
      <<"reason">> => safe_scalar(maps:get(reason, Failure,
                                           external_failure))};
failure_summary(_Failure) ->
    #{<<"reason">> => <<"external_failure">>}.

safe_scalar(Value) when is_binary(Value) -> Value;
safe_scalar(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
safe_scalar(Value) when is_integer(Value) -> Value;
safe_scalar(_) -> <<"external_failure">>.
