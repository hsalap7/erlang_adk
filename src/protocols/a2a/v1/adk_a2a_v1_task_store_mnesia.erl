%% @doc Mnesia-backed durable A2A task snapshot adapter.
-module(adk_a2a_v1_task_store_mnesia).
-behaviour(adk_a2a_v1_task_store).

-export([open/1, capabilities/1, load/1, put/2, delete/2]).

-record(adk_a2a_task_row, {key, snapshot, bytes}).

-define(DEFAULT_TABLE, adk_a2a_v1_tasks).
-define(DEFAULT_MAX_TASKS, 100000).
-define(DEFAULT_MAX_BYTES, 1073741824).
-define(DEFAULT_TIMEOUT, 5000).

open(Options) when is_map(Options) ->
    Table = maps:get(table, Options, ?DEFAULT_TABLE),
    Namespace = maps:get(namespace, Options, <<"default">>),
    MaxTasks = maps:get(max_tasks, Options, ?DEFAULT_MAX_TASKS),
    MaxBytes = maps:get(max_bytes, Options, ?DEFAULT_MAX_BYTES),
    Storage = maps:get(storage, Options, disc_copies),
    case is_atom(Table) andalso valid_namespace(Namespace) andalso
         positive(MaxTasks) andalso positive(MaxBytes) andalso
         (Storage =:= disc_copies orelse Storage =:= ram_copies) of
        false -> {error, invalid_a2a_task_store_options};
        true ->
            case application:ensure_all_started(mnesia) of
                {ok, _} -> ensure_table(Table, Storage, Namespace,
                                        MaxTasks, MaxBytes);
                {error, Reason} -> {error, {mnesia_start_failed, Reason}}
            end
    end;
open(_) -> {error, invalid_a2a_task_store_options}.

capabilities(Handle) ->
    #{contract_version => 1, durable => true, atomic_replace => true,
      limits => maps:with([max_tasks, max_bytes], Handle)}.

load(Handle) ->
    with_handle(Handle, fun(H) ->
        Table = maps:get(table, H),
        Namespace = maps:get(namespace, H),
        Tx = fun() ->
            Match = #adk_a2a_task_row{key = {Namespace, '_'}, _ = '_'},
            Rows = mnesia:match_object(Table, Match, read),
            [Snapshot || #adk_a2a_task_row{snapshot = Snapshot} <- Rows]
        end,
        tx(mnesia:transaction(Tx))
    end).

put(Handle, Snapshot0) ->
    case adk_a2a_v1_task_store:prepare_snapshot(Snapshot0) of
        {ok, Snapshot, Bytes} ->
            with_handle(Handle, fun(H) -> put_tx(H, Snapshot, Bytes) end);
        {error, _} = Error -> Error
    end.

delete(Handle, TaskId) when is_binary(TaskId) ->
    with_handle(Handle, fun(H) ->
        Table = maps:get(table, H),
        Key = {maps:get(namespace, H), TaskId},
        tx(mnesia:transaction(fun() ->
            mnesia:delete(Table, Key, write), ok
        end))
    end);
delete(_Handle, _TaskId) -> {error, invalid_a2a_task_id}.

put_tx(H, Snapshot, Bytes) ->
    Table = maps:get(table, H),
    Namespace = maps:get(namespace, H),
    Key = {Namespace, maps:get(id, Snapshot)},
    Tx = fun() ->
        Rows = mnesia:match_object(
                 Table,
                 #adk_a2a_task_row{key = {Namespace, '_'}, _ = '_'}, read),
        {Count0, Total0} = lists:foldl(
          fun(#adk_a2a_task_row{bytes = RowBytes}, {Count, Total}) ->
                  {Count + 1, Total + RowBytes}
          end, {0, 0}, Rows),
        ExistingBytes = case mnesia:read(Table, Key, write) of
            [#adk_a2a_task_row{bytes = Value}] -> Value;
            [] -> 0
        end,
        Count = case ExistingBytes of 0 -> Count0 + 1; _ -> Count0 end,
        Total = Total0 - ExistingBytes + Bytes,
        case Count =< maps:get(max_tasks, H) andalso
             Total =< maps:get(max_bytes, H) of
            true ->
                mnesia:write(Table,
                             #adk_a2a_task_row{key = Key,
                                               snapshot = Snapshot,
                                               bytes = Bytes}, write),
                ok;
            false -> mnesia:abort(a2a_task_store_capacity_reached)
        end
    end,
    tx(mnesia:transaction(Tx)).

ensure_table(Table, Storage, Namespace, MaxTasks, MaxBytes) ->
    Options = [{attributes, record_info(fields, adk_a2a_task_row)},
               {record_name, adk_a2a_task_row}, {type, set},
               {Storage, [node()]}],
    case mnesia:create_table(Table, Options) of
        {atomic, ok} -> wait_table(Table, Namespace, MaxTasks, MaxBytes);
        {aborted, {already_exists, Table}} ->
            wait_table(Table, Namespace, MaxTasks, MaxBytes);
        {aborted, Reason} -> {error, {mnesia_table_failed, Reason}}
    end.

wait_table(Table, Namespace, MaxTasks, MaxBytes) ->
    case mnesia:wait_for_tables([Table], ?DEFAULT_TIMEOUT) of
        ok -> {ok, #{table => Table, namespace => Namespace,
                     max_tasks => MaxTasks, max_bytes => MaxBytes}};
        {timeout, _} -> {error, a2a_task_store_unavailable};
        {error, Reason} -> {error, {mnesia_table_failed, Reason}}
    end.

with_handle(#{table := Table, namespace := Namespace,
              max_tasks := MaxTasks, max_bytes := MaxBytes} = Handle, Fun)
  when is_atom(Table), is_binary(Namespace),
       is_integer(MaxTasks), MaxTasks > 0,
       is_integer(MaxBytes), MaxBytes > 0 -> Fun(Handle);
with_handle(_Handle, _Fun) -> {error, invalid_a2a_task_store_handle}.

tx({atomic, Value}) -> case Value of
    List when is_list(List) -> {ok, List};
    ok -> ok;
    _ -> {ok, Value}
end;
tx({aborted, Reason}) -> {error, Reason}.

valid_namespace(Value) when is_binary(Value), byte_size(Value) > 0,
                                  byte_size(Value) =< 256 ->
    unicode:characters_to_binary(Value, utf8, utf8) =:= Value;
valid_namespace(_) -> false.

positive(Value) -> is_integer(Value) andalso Value > 0.
