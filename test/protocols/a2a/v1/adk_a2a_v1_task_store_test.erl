-module(adk_a2a_v1_task_store_test).

-include_lib("eunit/include/eunit.hrl").

ets_store_survives_server_restart_and_preserves_scope_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    {ok, Store} = adk_a2a_v1_task_store_ets:start_link(
                    #{max_tasks => 10, max_bytes => 1048576}),
    Scope = adk_a2a_v1_auth:scope(<<"alice">>),
    Auth = #{principal => #{subject => <<"alice">>}, scope => Scope,
             secret_seeds => []},
    try
        Server1 = start_server(Store),
        {ok, #{task_id := TaskId}} = adk_a2a_v1_server:send_message(
                                      Server1, Auth, params(<<"persist">>)),
        wait_terminal(Server1, Scope, TaskId),
        gen_server:stop(Server1),
        {ok, Snapshots} = adk_a2a_v1_task_store_ets:load(Store),
        ?assertEqual(1, length(Snapshots)),
        Server2 = start_server(Store),
        try
            {ok, Task} = adk_a2a_v1_server:get_task(
                           Server2, Scope, #{<<"id">> => TaskId}),
            ?assertEqual(<<"TASK_STATE_COMPLETED">>, state(Task)),
            ?assertEqual(
               {error, task_not_found},
               adk_a2a_v1_server:get_task(
                 Server2, adk_a2a_v1_auth:scope(<<"bob">>),
                 #{<<"id">> => TaskId}))
        after
            gen_server:stop(Server2)
        end
    after
        adk_a2a_v1_task_store_ets:stop(Store)
    end.

active_snapshot_is_failed_deterministically_on_restart_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    {ok, Store} = adk_a2a_v1_task_store_ets:start_link(),
    Scope = adk_a2a_v1_auth:scope(<<"alice">>),
    Snapshot = active_snapshot(Scope),
    try
        ok = adk_a2a_v1_task_store_ets:put(Store, Snapshot),
        Server = start_server(Store),
        try
            {ok, Task} = adk_a2a_v1_server:get_task(
                           Server, Scope, #{<<"id">> => <<"task-active">>}),
            ?assertEqual(<<"TASK_STATE_FAILED">>, state(Task)),
            {ok, [Recovered]} = adk_a2a_v1_task_store_ets:load(Store),
            ?assert(is_integer(maps:get(terminal_at, Recovered)))
        after
            gen_server:stop(Server)
        end
    after
        adk_a2a_v1_task_store_ets:stop(Store)
    end.

mnesia_adapter_round_trip_test() ->
    {ok, _} = application:ensure_all_started(mnesia),
    Table = adk_a2a_v1_task_store_test_table,
    _ = mnesia:delete_table(Table),
    {ok, Handle} = adk_a2a_v1_task_store_mnesia:open(
                     #{table => Table, namespace => <<"test">>,
                       storage => ram_copies, max_tasks => 4,
                       max_bytes => 1048576}),
    Snapshot = active_snapshot(adk_a2a_v1_auth:scope(<<"mnesia">>)),
    try
        ok = adk_a2a_v1_task_store_mnesia:put(Handle, Snapshot),
        {ok, [Loaded]} = adk_a2a_v1_task_store_mnesia:load(Handle),
        ?assertEqual(Snapshot, Loaded),
        ok = adk_a2a_v1_task_store_mnesia:delete(
               Handle, maps:get(id, Snapshot)),
        ?assertEqual({ok, []},
                     adk_a2a_v1_task_store_mnesia:load(Handle))
    after
        _ = mnesia:delete_table(Table)
    end.

start_server(Store) ->
    {ok, Card} = adk_a2a_v1_card:new(
                   #{url => <<"http://127.0.0.1:1/a2a/v1">>}),
    {ok, Server} = adk_a2a_v1_server:start_link(
                     #{name => undefined, card => Card,
                       executor => fun(_Request, _Emit) -> {ok, <<"done">>} end,
                       task_store => {adk_a2a_v1_task_store_ets, Store},
                       task_timeout => 2000, retention_ms => 60000,
                       max_tasks => 10, max_active => 4, max_events => 32}),
    Server.

params(Text) ->
    #{<<"message">> =>
          #{<<"messageId">> => <<"message-1">>,
            <<"role">> => <<"ROLE_USER">>,
            <<"parts">> => [#{<<"text">> => Text}]},
      <<"configuration">> => #{<<"returnImmediately">> => true}}.

active_snapshot(Scope) ->
    Status = #{<<"state">> => <<"TASK_STATE_WORKING">>,
               <<"timestamp">> => <<"2026-08-19T00:00:00.000Z">>},
    Task = #{<<"id">> => <<"task-active">>,
             <<"contextId">> => <<"context-active">>,
             <<"status">> => Status,
             <<"artifacts">> => [],
             <<"history">> =>
                 [#{<<"messageId">> => <<"message-active">>,
                    <<"contextId">> => <<"context-active">>,
                    <<"taskId">> => <<"task-active">>,
                    <<"role">> => <<"ROLE_USER">>,
                    <<"parts">> => [#{<<"text">> => <<"hello">>}]}]},
    #{id => <<"task-active">>, scope => Scope, task => Task,
      events => [{1, #{<<"task">> => Task}}], next_seq => 2,
      updated_ms => 1, terminal_at => undefined}.

state(#{<<"status">> := #{<<"state">> := State}}) -> State.

wait_terminal(Server, Scope, TaskId) ->
    Deadline = erlang:monotonic_time(millisecond) + 3000,
    wait_terminal_until(Server, Scope, TaskId, Deadline).

wait_terminal_until(Server, Scope, TaskId, Deadline) ->
    {ok, Task} = adk_a2a_v1_server:get_task(
                   Server, Scope, #{<<"id">> => TaskId}),
    case adk_a2a_v1_codec:terminal_state(state(Task)) of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(5),
                    wait_terminal_until(Server, Scope, TaskId, Deadline);
                false ->
                    error({terminal_timeout, TaskId})
            end
    end.
