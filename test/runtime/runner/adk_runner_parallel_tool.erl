-module(adk_runner_parallel_tool).
-behaviour(adk_tool).
-behaviour(adk_parallel_tool).

-export([schema/0, parallel_safe/0, execute/2]).

schema() ->
    #{<<"name">> => <<"parallel_probe">>,
      <<"description">> => <<"Runner parallel execution probe">>,
      <<"parallel_safe">> => true,
      <<"parameters">> => #{<<"type">> => <<"object">>}}.

parallel_safe() ->
    true.

execute(Args, Context) ->
    Id = maps:get(<<"id">>, Args),
    enter_metrics(),
    notify({runner_tool_started, Id, self(), Context}),
    try execute_mode(maps:get(<<"mode">>, Args, <<"success">>),
                     Args, Id)
    after
        leave_metrics()
    end.

execute_mode(<<"success">>, Args, Id) ->
    receive after maps:get(<<"delay">>, Args, 0) -> ok end,
    notify({runner_tool_finished, Id, self()}),
    {ok, #{<<"id">> => Id}};
execute_mode(<<"crash">>, _Args, Id) ->
    erlang:error({parallel_probe_crash, Id});
execute_mode(<<"block">>, _Args, _Id) ->
    receive
        release -> {ok, released}
    end.

enter_metrics() ->
    case metrics_table() of
        undefined ->
            ok;
        Table ->
            Active = ets:update_counter(Table, active, 1, {active, 0}),
            ets:insert(Table, {{seen, make_ref()}, Active}),
            ok
    end.

leave_metrics() ->
    case metrics_table() of
        undefined -> ok;
        Table ->
            _ = catch ets:update_counter(Table, active, -1),
            ok
    end.

metrics_table() ->
    persistent_term:get({?MODULE, metrics}, undefined).

notify(Message) ->
    case persistent_term:get({?MODULE, target}, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.
