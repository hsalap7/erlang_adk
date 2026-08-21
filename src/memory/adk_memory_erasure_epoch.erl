%% @doc Durable application/user erasure fences.
%%
%% An epoch is monotonically advanced when a user is erased. Durable work
%% captures the current epoch at admission and adapters compare it in the same
%% transaction as their write. This makes a stale queued or in-flight job
%% incapable of recreating data after erasure.
-module(adk_memory_erasure_epoch).

-export([default_table/0, ensure_table/0, ensure_table/1,
         current/1, current/2, advance/1, advance/2,
         current_tx/2, current_tx/3, assert_tx/3, advance_tx/2]).

-define(DEFAULT_TABLE, adk_memory_erasure_epoch).
-define(TABLE_WAIT_MS, 5000).

-record(adk_memory_erasure_epoch, {
    scope,
    epoch = 0,
    updated_at = 0
}).

-spec default_table() -> atom().
default_table() -> ?DEFAULT_TABLE.

-spec ensure_table() -> ok | {error, term()}.
ensure_table() -> ensure_table(?DEFAULT_TABLE).

-spec ensure_table(atom()) -> ok | {error, term()}.
ensure_table(Table) when is_atom(Table) ->
    case application:ensure_all_started(mnesia) of
        {ok, _} -> ensure_disk_table(Table);
        {error, Reason} ->
            {error, {memory_erasure_mnesia_start_failed, safe_reason(Reason)}}
    end;
ensure_table(_) -> {error, invalid_memory_erasure_epoch_table}.

-spec current(adk_memory_service:scope()) ->
    {ok, non_neg_integer()} | {error, term()}.
current(Scope) -> current(?DEFAULT_TABLE, Scope).

-spec current(atom(), adk_memory_service:scope()) ->
    {ok, non_neg_integer()} | {error, term()}.
current(Table, Scope) when is_atom(Table) ->
    case adk_memory_contract:validate_scope(Scope) of
        {ok, Canonical} ->
            transaction(fun() -> current_tx(Table, Canonical) end);
        {error, _} = Error -> Error
    end;
current(_, _) -> {error, invalid_memory_erasure_epoch_table}.

-spec advance(adk_memory_service:scope()) ->
    {ok, non_neg_integer()} | {error, term()}.
advance(Scope) -> advance(?DEFAULT_TABLE, Scope).

-spec advance(atom(), adk_memory_service:scope()) ->
    {ok, non_neg_integer()} | {error, term()}.
advance(Table, Scope) when is_atom(Table) ->
    case adk_memory_contract:validate_scope(Scope) of
        {ok, Canonical} ->
            transaction(fun() -> advance_tx(Table, Canonical) end);
        {error, _} = Error -> Error
    end;
advance(_, _) -> {error, invalid_memory_erasure_epoch_table}.

%% @doc Read inside the caller's Mnesia transaction.
-spec current_tx(atom(), adk_memory_service:scope()) -> non_neg_integer().
current_tx(Table, Scope) ->
    current_tx(Table, Scope, read).

-spec current_tx(atom(), adk_memory_service:scope(), read | write) ->
    non_neg_integer().
current_tx(Table, Scope, Lock) when Lock =:= read; Lock =:= write ->
    case mnesia:read(Table, Scope, Lock) of
        [#adk_memory_erasure_epoch{epoch = Epoch}] -> Epoch;
        [] -> 0
    end.

%% @doc Abort the current transaction if the captured fence is stale.
-spec assert_tx(atom(), adk_memory_service:scope(), non_neg_integer()) -> ok.
assert_tx(Table, Scope, Expected)
  when is_integer(Expected), Expected >= 0 ->
    case mnesia:read(Table, Scope, write) of
        [#adk_memory_erasure_epoch{epoch = Expected}] -> ok;
        [] when Expected =:= 0 -> ok;
        [#adk_memory_erasure_epoch{epoch = Actual}] ->
            mnesia:abort({memory_erasure_epoch_stale, Expected, Actual});
        [] -> mnesia:abort({memory_erasure_epoch_stale, Expected, 0})
    end;
assert_tx(_Table, _Scope, _Expected) ->
    mnesia:abort(invalid_memory_erasure_epoch).

%% @doc Advance inside the caller's Mnesia transaction.
-spec advance_tx(atom(), adk_memory_service:scope()) -> non_neg_integer().
advance_tx(Table, Scope) ->
    Current = case mnesia:read(Table, Scope, write) of
        [#adk_memory_erasure_epoch{epoch = Epoch}] -> Epoch;
        [] -> 0
    end,
    Next = Current + 1,
    mnesia:write(Table,
                 #adk_memory_erasure_epoch{
                    scope = Scope,
                    epoch = Next,
                    updated_at = erlang:system_time(millisecond)},
                 write),
    Next.

ensure_disk_table(Table) ->
    case mnesia:change_table_copy_type(schema, node(), disc_copies) of
        {atomic, ok} -> create_table(Table);
        {aborted, {already_exists, schema, Node, disc_copies}}
          when Node =:= node() -> create_table(Table);
        {aborted, Reason} ->
            {error, {memory_erasure_schema_configuration_failed,
                     safe_reason(Reason)}}
    end.

create_table(Table) ->
    Options = [{attributes,
                record_info(fields, adk_memory_erasure_epoch)},
               {record_name, adk_memory_erasure_epoch},
               {disc_copies, [node()]},
               {type, set},
               {majority, true}],
    case mnesia:create_table(Table, Options) of
        {atomic, ok} -> wait_for_table(Table);
        {aborted, {already_exists, Table}} -> verify_table(Table);
        {aborted, Reason} ->
            {error, {memory_erasure_table_creation_failed,
                     safe_reason(Reason)}}
    end.

wait_for_table(Table) ->
    case mnesia:wait_for_tables([Table], ?TABLE_WAIT_MS) of
        ok -> verify_table(Table);
        {timeout, _} -> {error, memory_erasure_table_wait_timeout};
        {error, Reason} ->
            {error, {memory_erasure_table_wait_failed, safe_reason(Reason)}}
    end.

verify_table(Table) ->
    Expected = record_info(fields, adk_memory_erasure_epoch),
    Actual = try
        {mnesia:table_info(Table, record_name),
         mnesia:table_info(Table, attributes),
         mnesia:table_info(Table, type),
         mnesia:table_info(Table, storage_type),
         mnesia:table_info(Table, majority)}
    catch
        exit:_ -> invalid
    end,
    case Actual of
        {adk_memory_erasure_epoch, Expected, set, disc_copies, true} -> ok;
        _ -> {error, memory_erasure_table_schema_mismatch}
    end.

transaction(Fun) ->
    case mnesia:transaction(Fun) of
        {atomic, Result} -> {ok, Result};
        {aborted, {memory_erasure_epoch_stale, _, _} = Reason} ->
            {error, Reason};
        {aborted, Reason} ->
            {error, {memory_erasure_transaction_failed, safe_reason(Reason)}}
    end.

safe_reason(Reason) ->
    adk_memory_outbox_payload:safe_reason(Reason).
