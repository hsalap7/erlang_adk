%% @doc Trusted adapter for the deterministic README planning example.
%%
%% Only a declared action vocabulary is interpreted. Source text and module
%% names in model-supplied plan data are never evaluated.
-module(readme_plan_executor).
-behaviour(adk_plan_executor).

-export([execute/4]).

execute(Target, Step, _Context, Config) ->
    notify(Target, {readme_plan_step_started,
                    maps:get(notify_ref, Config, undefined),
                    self(), maps:get(<<"id">>, Step)}),
    maybe_delay(Config),
    Action = maps:get(<<"action">>, Step),
    case maps:get(<<"kind">>, Action, undefined) of
        <<"return">> -> {ok, maps:get(<<"value">>, Action, null)};
        Kind -> {error, #{<<"kind">> => <<"unsupported_action">>,
                           <<"action_kind">> => json_value(Kind)}}
    end.

maybe_delay(Config) ->
    case maps:get(delay_ms, Config, 0) of
        Delay when is_integer(Delay), Delay > 0 -> timer:sleep(Delay);
        _ -> ok
    end.

notify(Pid, Message) when is_pid(Pid) -> Pid ! Message;
notify(_, _) -> ok.

json_value(undefined) -> null;
json_value(Value) when is_binary(Value) -> Value;
json_value(_) -> <<"invalid">>.
