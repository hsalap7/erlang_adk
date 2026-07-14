-module(adk_planning_test_executor).
-behaviour(adk_plan_executor).

-export([execute/4]).

execute(Target, Step, _Context, Config) ->
    notify(Target, {executor_started, self(), maps:get(<<"id">>, Step)}),
    Action = maps:get(<<"action">>, Step),
    Mode = case maps:get(mode, Config, from_action) of
        from_action -> mode_from_binary(maps:get(<<"mode">>, Action));
        Configured -> Configured
    end,
    case Mode of
        echo -> {ok, maps:get(<<"value">>, Action, null)};
        error -> {error, #{reason => deliberate,
                           access_token => <<"executor-secret">>}};
        invalid -> invalid_executor_return;
        opaque -> {ok, self()};
        crash -> erlang:error(executor_crash);
        timeout ->
            timer:sleep(maps:get(delay_ms, Config, 500)),
            {ok, late};
        heap ->
            {ok, lists:seq(1, maps:get(heap_items, Config, 1000000))}
    end.

mode_from_binary(<<"echo">>) -> echo;
mode_from_binary(<<"error">>) -> error;
mode_from_binary(<<"invalid">>) -> invalid;
mode_from_binary(<<"opaque">>) -> opaque;
mode_from_binary(<<"crash">>) -> crash;
mode_from_binary(<<"timeout">>) -> timeout;
mode_from_binary(<<"heap">>) -> heap.

notify(Pid, Message) when is_pid(Pid) -> Pid ! Message;
notify(_, _) -> ok.
