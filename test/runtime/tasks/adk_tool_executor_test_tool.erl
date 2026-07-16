-module(adk_tool_executor_test_tool).
-behaviour(adk_tool).
-behaviour(adk_parallel_tool).

-export([schema/0, parallel_safe/0, execute/2]).

schema() ->
    #{<<"name">> => <<"executor_test_tool">>,
      <<"description">> => <<"Deterministic task-executor test tool">>,
      <<"parallel_safe">> => true,
      <<"parameters">> => #{<<"type">> => <<"object">>}}.

parallel_safe() ->
    true.

execute(Args, _Context) ->
    Table = maps:get(table, Args, undefined),
    Id = maps:get(id, Args),
    enter(Table),
    notify(Args, {tool_started, Id, self()}),
    try
        execute_mode(maps:get(mode, Args, success), Args, Id)
    after
        leave(Table)
    end.

execute_mode(success, Args, Id) ->
    receive after maps:get(delay, Args, 0) -> ok end,
    notify(Args, {tool_finished, Id, self()}),
    {ok, Id};
execute_mode(error, _Args, Id) ->
    {error, {tool_error, Id}};
execute_mode(crash, _Args, Id) ->
    erlang:error({tool_crash, Id});
execute_mode(pause, _Args, Id) ->
    erlang:throw({adk_pause, approval_required, {call, Id}});
execute_mode(invalid, _Args, Id) ->
    {invalid_result, Id};
execute_mode(block, _Args, _Id) ->
    receive
        release -> {ok, released}
    end.

enter(undefined) ->
    ok;
enter(Table) ->
    Active = ets:update_counter(Table, active, 1, {active, 0}),
    ets:insert(Table, {{seen, make_ref()}, Active}),
    ok.

leave(undefined) ->
    ok;
leave(Table) ->
    _ = ets:update_counter(Table, active, -1),
    ok.

notify(Args, Message) ->
    case maps:get(notify, Args, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        undefined -> ok
    end.
