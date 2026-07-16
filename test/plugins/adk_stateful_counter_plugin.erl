-module(adk_stateful_counter_plugin).
-behaviour(adk_stateful_plugin).

-export([init/1, handle_hook/4, terminate/2]).

init(Config) ->
    notify_config(Config, {stateful_init_started, self()}),
    case maps:get(init_action, Config, normal) of
        normal -> ok;
        timeout -> timer:sleep(maps:get(init_delay_ms, Config, 500));
        crash -> erlang:error(deliberate_init_crash);
        heap -> _ = grow_heap(1000000, [])
    end,
    {ok, #{count => 0,
           test_pid => maps:get(test_pid, Config, undefined)}}.

handle_hook(_Hook, _Context, Value, State) ->
    notify(State, {stateful_hook_started, self(), Value}),
    case Value of
        delay -> timer:sleep(500);
        commit_race ->
            receive complete_stateful_hook -> ok
            after 5000 -> erlang:error(commit_race_release_timeout)
            end;
        _ -> ok
    end,
    Count = maps:get(count, State) + 1,
    {ok, {amend, Count}, State#{count => Count}}.

terminate(Reason, State) ->
    notify(State, {stateful_terminated, Reason}),
    ok.

notify(State, Message) ->
    case maps:get(test_pid, State, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.

notify_config(Config, Message) ->
    case maps:get(test_pid, Config, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.

grow_heap(0, Acc) -> Acc;
grow_heap(N, Acc) -> grow_heap(N - 1, [{N, N, N, N} | Acc]).
