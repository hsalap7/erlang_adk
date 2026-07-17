-module(readme_stateful_counter_plugin).
-behaviour(adk_stateful_plugin).

-export([init/1, handle_hook/4, terminate/2]).

init(Config) ->
    {ok, #{count => 0, notify => maps:get(notify, Config, undefined)}}.

handle_hook(before_run, _Context, _Value,
            #{count := Count, notify := Notify} = State) ->
    NewCount = Count + 1,
    case Notify of
        Pid when is_pid(Pid) -> Pid ! {stateful_before_run, NewCount};
        _ -> ok
    end,
    {ok, observe, State#{count => NewCount}};
handle_hook(_Hook, _Context, _Value, State) ->
    {ok, observe, State}.

terminate(_Reason, _State) ->
    ok.
