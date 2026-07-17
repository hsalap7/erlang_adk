%% @doc Bounded Mnesia outbox for asynchronous long-term-memory ingestion.
%%
%% Jobs contain exact application/user/session and `{Module, StableId}' adapter
%% identities, canonical sanitized events, and a durable batch checkpoint.  No
%% runtime pid, credential, resolver state, or service handle is persisted.
%%
%% Claims are lease-fenced and retries are at-least-once.  A processor can
%% repeat a batch after an uncertain crash; the memory adapter's event-ID
%% idempotency is what deduplicates effects.  This module does not claim
%% distributed exactly-once delivery.
-module(adk_memory_outbox).

-export([default_config/0, init/1, table_names/1,
         enqueue/2, status/2, stats/1,
         claim_due/4, renew/5, complete_batch/5, retry/5,
         cancel/3, delete/2]).

-define(DEFAULT_JOBS_TABLE, adk_memory_outbox_job).
-define(DEFAULT_USAGE_TABLE, adk_memory_outbox_usage).

-record(adk_memory_outbox_job, {
    id,
    format = 1,
    app_name,
    user_id,
    session_id,
    adapter_module,
    adapter_id,
    payload_digest,
    batches = [],
    next_batch = 1,
    total_batches = 0,
    event_count = 0,
    input_duplicates = 0,
    storage_bytes = 0,
    phase = pending,
    attempt = 0,
    max_attempts = 5,
    backoff_base_ms = 250,
    max_backoff_ms = 30000,
    next_attempt_at = 0,
    owner_token = undefined,
    lease_until = 0,
    result = #{added => 0, duplicates => 0, skipped => 0},
    last_error = undefined,
    revision = 0,
    created_at,
    updated_at,
    finished_at = undefined
}).

-record(adk_memory_outbox_usage, {
    key,
    active_jobs = 0,
    active_bytes = 0
}).

default_config() ->
    #{jobs_table => ?DEFAULT_JOBS_TABLE,
      usage_table => ?DEFAULT_USAGE_TABLE,
      max_active_global => 10000,
      max_active_per_scope => 1000,
      max_active_bytes_global => 268435456,
      max_active_bytes_per_scope => 67108864,
      max_events_per_job => 5000,
      max_event_bytes => 262144,
      max_job_bytes => 16777216,
      max_attempts => 10,
      default_max_attempts => 5,
      backoff_base_ms => 250,
      max_backoff_ms => 30000,
      table_wait_ms => 5000}.

%% @doc Ensure durable tables exist and reconcile admission counters from jobs.
init(Config) when is_map(Config) ->
    case compile_config(Config) of
        {ok, Handle} ->
            case application:ensure_all_started(mnesia) of
                {ok, _} -> ensure_schema_and_tables(Handle);
                {error, Reason} ->
                    {error, {memory_outbox_mnesia_start_failed, Reason}}
            end;
        {error, _} = Error -> Error
    end;
init(_) ->
    {error, {invalid_memory_outbox_config, expected_map}}.

table_names(#{jobs_table := Jobs, usage_table := Usage}) -> [Jobs, Usage];
table_names(_) -> [].

%% @doc Durably admit a job.  This performs only a bounded local transaction;
%% adapter resolution and ingestion are always left to a processor.
enqueue(Handle, Request) ->
    with_handle(
      Handle,
      fun(Jobs, Usage, Limits) ->
          case adk_memory_outbox_payload:prepare(Request, Limits) of
              {ok, Prepared} ->
                  enqueue_prepared(Jobs, Usage, Limits, Prepared);
              {error, _} = Error -> Error
          end
      end).

status(Handle, JobId) when is_binary(JobId) ->
    with_handle(
      Handle,
      fun(Jobs, _Usage, _Limits) ->
          case mnesia:transaction(
                 fun() -> mnesia:read(Jobs, JobId, read) end) of
              {atomic, [Record]} -> {ok, public_status(Record)};
              {atomic, []} -> {error, not_found};
              {aborted, Reason} -> tx_error(Reason)
          end
      end);
status(_Handle, _JobId) -> {error, invalid_memory_outbox_job_id}.

stats(Handle) ->
    with_handle(
      Handle,
      fun(Jobs, Usage, _Limits) ->
          Tx = fun() ->
              Global = read_usage_tx(Usage, global_key()),
              Phases = mnesia:foldl(
                         fun(Record, Acc) ->
                             Phase = Record#adk_memory_outbox_job.phase,
                             Acc#{Phase => maps:get(Phase, Acc, 0) + 1}
                         end, #{}, Jobs),
              #{active_jobs => Global#adk_memory_outbox_usage.active_jobs,
                active_bytes => Global#adk_memory_outbox_usage.active_bytes,
                phases => Phases}
          end,
          case mnesia:transaction(Tx) of
              {atomic, Result} -> {ok, Result};
              {aborted, Reason} -> tx_error(Reason)
          end
      end).

%% @doc Claim one due batch.  `OwnerToken' is an unguessable runtime binary;
%% unlike a pid it is safe to persist as a lease fence.
claim_due(Handle, OwnerToken, Now, LeaseMs)
  when is_binary(OwnerToken), byte_size(OwnerToken) > 0,
       byte_size(OwnerToken) =< 256,
       is_integer(Now), is_integer(LeaseMs), LeaseMs > 0 ->
    with_handle(
      Handle,
      fun(Jobs, Usage, _Limits) ->
          Tx = fun() -> claim_due_tx(Jobs, Usage, OwnerToken, Now, LeaseMs) end,
          case mnesia:transaction(Tx) of
              {atomic, none} -> none;
              {atomic, {ok, Work}} -> {ok, Work};
              {aborted, Reason} -> tx_error(Reason)
          end
      end);
claim_due(_Handle, _OwnerToken, _Now, _LeaseMs) ->
    {error, invalid_memory_outbox_claim}.

renew(Handle, JobId, OwnerToken, Now, LeaseMs)
  when is_binary(JobId), is_binary(OwnerToken),
       is_integer(Now), is_integer(LeaseMs), LeaseMs > 0 ->
    update_owned(
      Handle, JobId, OwnerToken, Now,
      fun(Record) ->
          Record#adk_memory_outbox_job{
              lease_until = Now + LeaseMs,
              revision = Record#adk_memory_outbox_job.revision + 1,
              updated_at = Now}
      end);
renew(_Handle, _JobId, _OwnerToken, _Now, _LeaseMs) ->
    {error, invalid_memory_outbox_renewal}.

complete_batch(Handle, JobId, OwnerToken, Result0, Now)
  when is_binary(JobId), is_binary(OwnerToken), is_integer(Now) ->
    case normalize_result(Result0) of
        {ok, Result} -> complete_batch_result(
                          Handle, JobId, OwnerToken, Result, Now);
        {error, _} = Error -> Error
    end;
complete_batch(_Handle, _JobId, _OwnerToken, _Result, _Now) ->
    {error, invalid_memory_outbox_completion}.

retry(Handle, JobId, OwnerToken, Reason0, Now)
  when is_binary(JobId), is_binary(OwnerToken), is_integer(Now) ->
    SafeReason = adk_memory_outbox_payload:safe_reason(Reason0),
    with_handle(
      Handle,
      fun(Jobs, Usage, _Limits) ->
          Tx = fun() ->
              case read_owned_tx(Jobs, JobId, OwnerToken, Now) of
                  {ok, Record} ->
                      retry_record_tx(Jobs, Usage, Record, SafeReason, Now);
                  {error, Reason} -> mnesia:abort(Reason)
              end
          end,
          tx_status_result(mnesia:transaction(Tx))
      end);
retry(_Handle, _JobId, _OwnerToken, _Reason, _Now) ->
    {error, invalid_memory_outbox_retry}.

cancel(Handle, JobId, Reason0) when is_binary(JobId) ->
    SafeReason = adk_memory_outbox_payload:safe_reason(Reason0),
    with_handle(
      Handle,
      fun(Jobs, Usage, _Limits) ->
          Now = erlang:system_time(millisecond),
          Tx = fun() ->
              case mnesia:read(Jobs, JobId, write) of
                  [] -> mnesia:abort(not_found);
                  [Record] ->
                      case terminal(Record#adk_memory_outbox_job.phase) of
                          true -> mnesia:abort(already_terminal);
                          false ->
                              Finished = terminal_record(
                                           Record, cancelled, SafeReason, Now),
                              mnesia:write(Jobs, Finished, write),
                              release_usage_tx(Usage, Record),
                              public_status(Finished)
                      end
              end
          end,
          tx_status_result(mnesia:transaction(Tx))
      end);
cancel(_Handle, _JobId, _Reason) ->
    {error, invalid_memory_outbox_job_id}.

delete(Handle, JobId) when is_binary(JobId) ->
    with_handle(
      Handle,
      fun(Jobs, _Usage, _Limits) ->
          Tx = fun() ->
              case mnesia:read(Jobs, JobId, write) of
                  [] -> mnesia:abort(not_found);
                  [Record] ->
                      case terminal(Record#adk_memory_outbox_job.phase) of
                          true -> mnesia:delete(Jobs, JobId, write), ok;
                          false -> mnesia:abort(job_active)
                      end
              end
          end,
          case mnesia:transaction(Tx) of
              {atomic, ok} -> ok;
              {aborted, Reason} -> tx_error(Reason)
          end
      end);
delete(_Handle, _JobId) -> {error, invalid_memory_outbox_job_id}.

%% Configuration and table lifecycle

compile_config(Config) ->
    Defaults = default_config(),
    Allowed = maps:keys(Defaults),
    case lists:sort(maps:keys(maps:without(Allowed, Config))) of
        [] -> validate_config(maps:merge(Defaults, Config));
        Unknown -> {error, {invalid_memory_outbox_config,
                            {unknown_keys, Unknown}}}
    end.

validate_config(Config) ->
    Jobs = maps:get(jobs_table, Config),
    Usage = maps:get(usage_table, Config),
    Numeric = [{max_active_global, 1000000},
               {max_active_per_scope, 1000000},
               {max_active_bytes_global, 10737418240},
               {max_active_bytes_per_scope, 10737418240},
               {max_events_per_job, 100000},
               {max_event_bytes, 1048576},
               {max_job_bytes, 1073741824},
               {max_attempts, 100},
               {default_max_attempts, 100},
               {backoff_base_ms, 3600000},
               {max_backoff_ms, 86400000},
               {table_wait_ms, 60000}],
    case {is_atom(Jobs), is_atom(Usage), Jobs =/= Usage,
          first_bad_number(Numeric, Config)} of
        {true, true, true, none} -> validate_config_relations(Config);
        {false, _, _, _} ->
            {error, {invalid_memory_outbox_config, jobs_table}};
        {_, false, _, _} ->
            {error, {invalid_memory_outbox_config, usage_table}};
        {_, _, false, _} ->
            {error, {invalid_memory_outbox_config, duplicate_table_names}};
        {_, _, _, Error} ->
            {error, {invalid_memory_outbox_config, Error}}
    end.

validate_config_relations(Config) ->
    Checks = [
        {maps:get(max_active_per_scope, Config) =<
         maps:get(max_active_global, Config), per_scope_jobs_above_global},
        {maps:get(max_active_bytes_per_scope, Config) =<
         maps:get(max_active_bytes_global, Config), per_scope_bytes_above_global},
        {maps:get(default_max_attempts, Config) =<
         maps:get(max_attempts, Config), default_attempts_above_max},
        {maps:get(backoff_base_ms, Config) =<
         maps:get(max_backoff_ms, Config), backoff_base_above_max},
        {maps:get(max_event_bytes, Config) =<
         maps:get(max_job_bytes, Config), event_bytes_above_job_bytes}
    ],
    case [Reason || {false, Reason} <- Checks] of
        [] ->
            Limits = maps:without([jobs_table, usage_table], Config),
            {ok, #{jobs_table => maps:get(jobs_table, Config),
                   usage_table => maps:get(usage_table, Config),
                   limits => Limits}};
        [Reason | _] -> {error, {invalid_memory_outbox_config, Reason}}
    end.

first_bad_number([], _Config) -> none;
first_bad_number([{Key, Ceiling} | Rest], Config) ->
    Value = maps:get(Key, Config),
    case is_integer(Value) andalso Value > 0 andalso Value =< Ceiling of
        true -> first_bad_number(Rest, Config);
        false -> {Key, Value, {allowed_range, 1, Ceiling}}
    end.

ensure_schema_and_tables(Handle) ->
    case mnesia:change_table_copy_type(schema, node(), disc_copies) of
        {atomic, ok} -> create_tables(Handle);
        {aborted, {already_exists, schema, Node, disc_copies}}
          when Node =:= node() -> create_tables(Handle);
        {aborted, Reason} ->
            {error, {memory_outbox_schema_configuration_failed, Reason}}
    end.

create_tables(#{jobs_table := Jobs, usage_table := Usage,
                limits := Limits} = Handle) ->
    Definitions = [
        {Jobs, adk_memory_outbox_job,
         record_info(fields, adk_memory_outbox_job)},
        {Usage, adk_memory_outbox_usage,
         record_info(fields, adk_memory_outbox_usage)}
    ],
    case create_tables_list(Definitions) of
        ok ->
            Timeout = maps:get(table_wait_ms, Limits),
            case mnesia:wait_for_tables([Jobs, Usage], Timeout) of
                ok ->
                    case verify_tables(Jobs, Usage) of
                        ok -> case reconcile_usage(Handle) of
                            ok -> {ok, Handle};
                            {error, _} = Error -> Error
                        end;
                        {error, _} = Error -> Error
                    end;
                {timeout, Missing} ->
                    {error, {memory_outbox_table_wait_timeout, Missing}};
                {error, Reason} ->
                    {error, {memory_outbox_table_wait_failed, Reason}}
            end;
        {error, _} = Error -> Error
    end.

create_tables_list([]) -> ok;
create_tables_list([{Table, RecordName, Attributes} | Rest]) ->
    Options = [{attributes, Attributes},
               {record_name, RecordName},
               {disc_copies, [node()]},
               {type, set},
               {majority, true}],
    case mnesia:create_table(Table, Options) of
        {atomic, ok} -> create_tables_list(Rest);
        {aborted, {already_exists, Table}} -> create_tables_list(Rest);
        {aborted, Reason} ->
            {error, {memory_outbox_table_creation_failed, Table, Reason}}
    end.

verify_tables(Jobs, Usage) ->
    Expected = [
        {Jobs, adk_memory_outbox_job,
         record_info(fields, adk_memory_outbox_job)},
        {Usage, adk_memory_outbox_usage,
         record_info(fields, adk_memory_outbox_usage)}
    ],
    verify_table_list(Expected).

verify_table_list([]) -> ok;
verify_table_list([{Table, RecordName, Attributes} | Rest]) ->
    Actual = try
        {mnesia:table_info(Table, record_name),
         mnesia:table_info(Table, attributes),
         mnesia:table_info(Table, type),
         mnesia:table_info(Table, storage_type)}
    catch
        exit:Reason -> {error, Reason}
    end,
    case Actual of
        {RecordName, Attributes, set, disc_copies} ->
            verify_table_list(Rest);
        _ -> {error, {memory_outbox_table_schema_mismatch, Table, Actual}}
    end.

reconcile_usage(#{jobs_table := Jobs, usage_table := Usage}) ->
    Tx = fun() ->
        mnesia:write_lock_table(Jobs),
        mnesia:write_lock_table(Usage),
        UsageKeys = mnesia:foldl(
                      fun(#adk_memory_outbox_usage{key = Key}, Acc) ->
                              [Key | Acc]
                      end, [], Usage),
        lists:foreach(fun(Key) -> mnesia:delete(Usage, Key, write) end,
                      UsageKeys),
        {GlobalJobs, GlobalBytes, Scopes} = mnesia:foldl(
          fun(Record, {JobsAcc, BytesAcc, ScopeAcc}) ->
              case terminal(Record#adk_memory_outbox_job.phase) of
                  true -> {JobsAcc, BytesAcc, ScopeAcc};
                  false ->
                      Scope = record_scope(Record),
                      Bytes = Record#adk_memory_outbox_job.storage_bytes,
                      {ScopeJobs, ScopeBytes} = maps:get(
                                                   Scope, ScopeAcc, {0, 0}),
                      {JobsAcc + 1, BytesAcc + Bytes,
                       ScopeAcc#{Scope => {ScopeJobs + 1,
                                           ScopeBytes + Bytes}}}
              end
          end, {0, 0, #{}}, Jobs),
        write_usage_tx(Usage, global_key(), GlobalJobs, GlobalBytes),
        maps:foreach(
          fun(Scope, {Count, Bytes}) ->
              write_usage_tx(Usage, scope_key(Scope), Count, Bytes)
          end, Scopes),
        ok
    end,
    case mnesia:transaction(Tx) of
        {atomic, ok} -> ok;
        {aborted, Reason} -> tx_error(Reason)
    end.

%% Admission and claim internals

enqueue_prepared(Jobs, Usage, Limits, Prepared) ->
    Now = erlang:system_time(millisecond),
    Record = prepared_record(Prepared, Limits, Now),
    JobId = Record#adk_memory_outbox_job.id,
    Tx = fun() ->
        case mnesia:read(Jobs, JobId, write) of
            [] ->
                reserve_usage_tx(Usage, Limits, Record),
                mnesia:write(Jobs, Record, write),
                {new, public_status(Record)};
            [Existing] ->
                case same_job(Existing, Record) of
                    true -> {duplicate, public_status(Existing)};
                    false -> mnesia:abort(memory_outbox_dedupe_conflict)
                end
        end
    end,
    case mnesia:transaction(Tx) of
        {atomic, {new, Status}} -> {ok, Status#{deduplicated => false}};
        {atomic, {duplicate, Status}} ->
            {ok, Status#{deduplicated => true}};
        {aborted, Reason} -> tx_error(Reason)
    end.

prepared_record(Prepared, Limits, Now) ->
    {user, App, User} = maps:get(scope, Prepared),
    {Module, AdapterId} = maps:get(adapter, Prepared),
    Batches = maps:get(batches, Prepared),
    #adk_memory_outbox_job{
        id = maps:get(job_id, Prepared),
        app_name = App,
        user_id = User,
        session_id = maps:get(session_id, Prepared),
        adapter_module = Module,
        adapter_id = AdapterId,
        payload_digest = maps:get(payload_digest, Prepared),
        batches = Batches,
        total_batches = length(Batches),
        event_count = maps:get(event_count, Prepared),
        input_duplicates = maps:get(input_duplicates, Prepared),
        storage_bytes = maps:get(storage_bytes, Prepared),
        max_attempts = maps:get(max_attempts, Prepared),
        backoff_base_ms = maps:get(backoff_base_ms, Limits),
        max_backoff_ms = maps:get(max_backoff_ms, Limits),
        created_at = Now,
        updated_at = Now}.

same_job(Existing, Proposed) ->
    Existing#adk_memory_outbox_job.payload_digest =:=
        Proposed#adk_memory_outbox_job.payload_digest andalso
    record_scope(Existing) =:= record_scope(Proposed) andalso
    Existing#adk_memory_outbox_job.session_id =:=
        Proposed#adk_memory_outbox_job.session_id andalso
    Existing#adk_memory_outbox_job.adapter_module =:=
        Proposed#adk_memory_outbox_job.adapter_module andalso
    Existing#adk_memory_outbox_job.adapter_id =:=
        Proposed#adk_memory_outbox_job.adapter_id.

reserve_usage_tx(Usage, Limits, Record) ->
    Bytes = Record#adk_memory_outbox_job.storage_bytes,
    Scope = record_scope(Record),
    Global0 = read_usage_tx(Usage, global_key()),
    Scoped0 = read_usage_tx(Usage, scope_key(Scope)),
    Global = add_usage(Global0, 1, Bytes),
    Scoped = add_usage(Scoped0, 1, Bytes),
    ensure_capacity(Global,
                    maps:get(max_active_global, Limits),
                    maps:get(max_active_bytes_global, Limits), global),
    ensure_capacity(Scoped,
                    maps:get(max_active_per_scope, Limits),
                    maps:get(max_active_bytes_per_scope, Limits), Scope),
    mnesia:write(Usage, Global, write),
    mnesia:write(Usage, Scoped, write).

ensure_capacity(#adk_memory_outbox_usage{active_jobs = Jobs}, MaxJobs,
                _MaxBytes, Dimension) when Jobs > MaxJobs ->
    mnesia:abort({memory_outbox_capacity_exceeded,
                  Dimension, active_jobs, MaxJobs});
ensure_capacity(#adk_memory_outbox_usage{active_bytes = Bytes}, _MaxJobs,
                MaxBytes, Dimension) when Bytes > MaxBytes ->
    mnesia:abort({memory_outbox_capacity_exceeded,
                  Dimension, active_bytes, MaxBytes});
ensure_capacity(_, _, _, _) -> ok.

claim_due_tx(Jobs, Usage, OwnerToken, Now, LeaseMs) ->
    mnesia:write_lock_table(Jobs),
    expire_exhausted_tx(Jobs, Usage, Now),
    case choose_due_tx(Jobs, Now) of
        none -> none;
        Record ->
            Claimed = Record#adk_memory_outbox_job{
                phase = running,
                attempt = Record#adk_memory_outbox_job.attempt + 1,
                next_attempt_at = 0,
                owner_token = OwnerToken,
                lease_until = Now + LeaseMs,
                revision = Record#adk_memory_outbox_job.revision + 1,
                updated_at = Now},
            mnesia:write(Jobs, Claimed, write),
            {ok, work_item(Claimed)}
    end.

expire_exhausted_tx(Jobs, Usage, Now) ->
    Exhausted = mnesia:foldl(
      fun(#adk_memory_outbox_job{phase = running,
                                 lease_until = Lease,
                                 attempt = Attempt,
                                 max_attempts = Max} = Record, Acc)
            when Lease =< Now, Attempt >= Max -> [Record | Acc];
         (_Record, Acc) -> Acc
      end, [], Jobs),
    lists:foreach(
      fun(Record) ->
          Reason = #{<<"type">> => <<"lease_expired_after_max_attempts">>},
          Failed = terminal_record(Record, failed, Reason, Now),
          mnesia:write(Jobs, Failed, write),
          release_usage_tx(Usage, Record)
      end, Exhausted).

choose_due_tx(Jobs, Now) ->
    case mnesia:foldl(
           fun(Record, Best) -> choose_earlier(Record, Best, Now) end,
           none, Jobs) of
        none -> none;
        {_Key, Record} -> Record
    end.

choose_earlier(Record, Best, Now) ->
    case due_key(Record, Now) of
        none -> Best;
        Key ->
            case Best of
                none -> {Key, Record};
                {BestKey, _} when Key < BestKey -> {Key, Record};
                _ -> Best
            end
    end.

due_key(#adk_memory_outbox_job{phase = pending,
                               attempt = Attempt,
                               max_attempts = Max,
                               created_at = Created,
                               id = Id}, _Now) when Attempt < Max ->
    {0, Created, Id};
due_key(#adk_memory_outbox_job{phase = retry_wait,
                               next_attempt_at = Due,
                               attempt = Attempt,
                               max_attempts = Max,
                               created_at = Created,
                               id = Id}, Now) when Due =< Now, Attempt < Max ->
    {Due, Created, Id};
due_key(#adk_memory_outbox_job{phase = running,
                               lease_until = Lease,
                               attempt = Attempt,
                               max_attempts = Max,
                               created_at = Created,
                               id = Id}, Now) when Lease =< Now, Attempt < Max ->
    {Lease, Created, Id};
due_key(_, _) -> none.

%% Completion, retry, and lease fences

complete_batch_result(Handle, JobId, OwnerToken, Result, Now) ->
    with_handle(
      Handle,
      fun(Jobs, Usage, _Limits) ->
          Tx = fun() ->
              case read_owned_tx(Jobs, JobId, OwnerToken, Now) of
                  {ok, Record} ->
                      complete_record_tx(Jobs, Usage, Record, Result, Now);
                  {error, Reason} -> mnesia:abort(Reason)
              end
          end,
          tx_status_result(mnesia:transaction(Tx))
      end).

complete_record_tx(Jobs, Usage, Record, Result, Now) ->
    Aggregate = sum_results(Record#adk_memory_outbox_job.result, Result),
    Next = Record#adk_memory_outbox_job.next_batch + 1,
    case Next > Record#adk_memory_outbox_job.total_batches of
        true ->
            Completed0 = terminal_record(Record, completed, undefined, Now),
            Completed = Completed0#adk_memory_outbox_job{result = Aggregate},
            mnesia:write(Jobs, Completed, write),
            release_usage_tx(Usage, Record),
            public_status(Completed);
        false ->
            Updated = Record#adk_memory_outbox_job{
                next_batch = Next,
                phase = pending,
                attempt = 0,
                next_attempt_at = 0,
                owner_token = undefined,
                lease_until = 0,
                result = Aggregate,
                last_error = undefined,
                revision = Record#adk_memory_outbox_job.revision + 1,
                updated_at = Now},
            mnesia:write(Jobs, Updated, write),
            public_status(Updated)
    end.

retry_record_tx(Jobs, Usage, Record, SafeReason, Now) ->
    case Record#adk_memory_outbox_job.attempt >=
         Record#adk_memory_outbox_job.max_attempts of
        true ->
            Failed = terminal_record(Record, failed, SafeReason, Now),
            mnesia:write(Jobs, Failed, write),
            release_usage_tx(Usage, Record),
            public_status(Failed);
        false ->
            Delay = retry_delay(Record),
            Waiting = Record#adk_memory_outbox_job{
                phase = retry_wait,
                next_attempt_at = Now + Delay,
                owner_token = undefined,
                lease_until = 0,
                last_error = SafeReason,
                revision = Record#adk_memory_outbox_job.revision + 1,
                updated_at = Now},
            mnesia:write(Jobs, Waiting, write),
            public_status(Waiting)
    end.

retry_delay(Record) ->
    Attempt = Record#adk_memory_outbox_job.attempt,
    Shift = erlang:min(Attempt - 1, 20),
    erlang:min(Record#adk_memory_outbox_job.max_backoff_ms,
               Record#adk_memory_outbox_job.backoff_base_ms bsl Shift).

update_owned(Handle, JobId, OwnerToken, Now, UpdateFun) ->
    with_handle(
      Handle,
      fun(Jobs, _Usage, _Limits) ->
          Tx = fun() ->
              case read_owned_tx(Jobs, JobId, OwnerToken, Now) of
                  {ok, Record} ->
                      Updated = UpdateFun(Record),
                      mnesia:write(Jobs, Updated, write),
                      public_status(Updated);
                  {error, Reason} -> mnesia:abort(Reason)
              end
          end,
          tx_status_result(mnesia:transaction(Tx))
      end).

read_owned_tx(Jobs, JobId, OwnerToken, Now) ->
    case mnesia:read(Jobs, JobId, write) of
        [] -> {error, not_found};
        [#adk_memory_outbox_job{phase = running,
                                owner_token = OwnerToken,
                                lease_until = Lease} = Record]
          when Now < Lease -> {ok, Record};
        [#adk_memory_outbox_job{phase = running,
                                owner_token = OwnerToken}] ->
            {error, lease_expired};
        [_] -> {error, stale_owner}
    end.

terminal_record(Record, Phase, LastError, Now) ->
    Record#adk_memory_outbox_job{
        phase = Phase,
        owner_token = undefined,
        lease_until = 0,
        next_attempt_at = 0,
        last_error = LastError,
        revision = Record#adk_memory_outbox_job.revision + 1,
        updated_at = Now,
        finished_at = Now}.

normalize_result(Result) when is_map(Result) ->
    Unknown = maps:keys(maps:without([added, duplicates, skipped], Result)),
    Values = [{Key, maps:get(Key, Result, 0)}
              || Key <- [added, duplicates, skipped]],
    case {Unknown, lists:all(fun({_Key, Value}) ->
                                is_integer(Value) andalso Value >= 0
                            end, Values)} of
        {[], true} -> {ok, maps:from_list(Values)};
        {[_ | _], _} ->
            {error, {invalid_memory_outbox_adapter_result,
                     {unknown_keys, lists:sort(Unknown)}}};
        {_, false} -> {error, invalid_memory_outbox_adapter_result}
    end;
normalize_result(_) -> {error, invalid_memory_outbox_adapter_result}.

sum_results(Left, Right) ->
    maps:from_list([{Key, maps:get(Key, Left, 0) + maps:get(Key, Right, 0)}
                    || Key <- [added, duplicates, skipped]]).

%% Usage, output projection, and generic helpers

release_usage_tx(Usage, Record) ->
    Bytes = Record#adk_memory_outbox_job.storage_bytes,
    ScopeKey = scope_key(record_scope(Record)),
    decrement_usage_tx(Usage, global_key(), Bytes),
    decrement_usage_tx(Usage, ScopeKey, Bytes).

decrement_usage_tx(Usage, Key, Bytes) ->
    Current = read_usage_tx(Usage, Key),
    Count = erlang:max(0,
                       Current#adk_memory_outbox_usage.active_jobs - 1),
    NewBytes = erlang:max(0,
                          Current#adk_memory_outbox_usage.active_bytes - Bytes),
    write_usage_tx(Usage, Key, Count, NewBytes).

read_usage_tx(Usage, Key) ->
    case mnesia:read(Usage, Key, write) of
        [Record] -> Record;
        [] -> #adk_memory_outbox_usage{key = Key}
    end.

write_usage_tx(Usage, Key, 0, 0) ->
    mnesia:delete(Usage, Key, write);
write_usage_tx(Usage, Key, Count, Bytes) ->
    mnesia:write(Usage,
                 #adk_memory_outbox_usage{key = Key,
                                          active_jobs = Count,
                                          active_bytes = Bytes}, write).

add_usage(Record, Jobs, Bytes) ->
    Record#adk_memory_outbox_usage{
        active_jobs = Record#adk_memory_outbox_usage.active_jobs + Jobs,
        active_bytes = Record#adk_memory_outbox_usage.active_bytes + Bytes}.

global_key() -> {global, 1}.
scope_key(Scope) -> {scope, Scope}.

record_scope(Record) ->
    {user, Record#adk_memory_outbox_job.app_name,
           Record#adk_memory_outbox_job.user_id}.

work_item(Record) ->
    Batch = lists:nth(Record#adk_memory_outbox_job.next_batch,
                      Record#adk_memory_outbox_job.batches),
    #{job_id => Record#adk_memory_outbox_job.id,
      scope => record_scope(Record),
      session_id => Record#adk_memory_outbox_job.session_id,
      adapter => {Record#adk_memory_outbox_job.adapter_module,
                  Record#adk_memory_outbox_job.adapter_id},
      batch_id => maps:get(batch_id, Batch),
      batch_index => Record#adk_memory_outbox_job.next_batch,
      batch_count => Record#adk_memory_outbox_job.total_batches,
      event_ids => maps:get(event_ids, Batch),
      events => maps:get(events, Batch),
      attempt => Record#adk_memory_outbox_job.attempt,
      max_attempts => Record#adk_memory_outbox_job.max_attempts,
      lease_until => Record#adk_memory_outbox_job.lease_until}.

public_status(Record) ->
    Next = Record#adk_memory_outbox_job.next_batch,
    Completed = case Record#adk_memory_outbox_job.phase of
        completed -> Record#adk_memory_outbox_job.total_batches;
        _ -> erlang:max(0, Next - 1)
    end,
    Base = #{job_id => Record#adk_memory_outbox_job.id,
      scope => record_scope(Record),
      session_id => Record#adk_memory_outbox_job.session_id,
      adapter => {Record#adk_memory_outbox_job.adapter_module,
                  Record#adk_memory_outbox_job.adapter_id},
      phase => Record#adk_memory_outbox_job.phase,
      event_count => Record#adk_memory_outbox_job.event_count,
      input_duplicates => Record#adk_memory_outbox_job.input_duplicates,
      batch_count => Record#adk_memory_outbox_job.total_batches,
      checkpoint => #{completed_batches => Completed,
                      next_batch => case terminal(
                                           Record#adk_memory_outbox_job.phase) of
                          true -> undefined;
                          false -> Next
                      end},
      attempt => Record#adk_memory_outbox_job.attempt,
      max_attempts => Record#adk_memory_outbox_job.max_attempts,
      next_attempt_at => Record#adk_memory_outbox_job.next_attempt_at,
      lease_until => Record#adk_memory_outbox_job.lease_until,
      result => Record#adk_memory_outbox_job.result,
      revision => Record#adk_memory_outbox_job.revision,
      created_at => Record#adk_memory_outbox_job.created_at,
      updated_at => Record#adk_memory_outbox_job.updated_at},
    Base1 = case Record#adk_memory_outbox_job.last_error of
        undefined -> Base;
        Error -> Base#{last_error => Error}
    end,
    case Record#adk_memory_outbox_job.finished_at of
        undefined -> Base1;
        Finished -> Base1#{finished_at => Finished}
    end.

terminal(completed) -> true;
terminal(failed) -> true;
terminal(cancelled) -> true;
terminal(_) -> false.

with_handle(#{jobs_table := Jobs, usage_table := Usage,
              limits := Limits}, Fun)
  when is_atom(Jobs), is_atom(Usage), is_map(Limits), is_function(Fun, 3) ->
    Fun(Jobs, Usage, Limits);
with_handle(_Handle, _Fun) ->
    {error, invalid_memory_outbox_handle}.

tx_status_result({atomic, Status}) -> {ok, Status};
tx_status_result({aborted, Reason}) -> tx_error(Reason).

tx_error(Reason) when Reason =:= not_found;
                            Reason =:= already_terminal;
                            Reason =:= job_active;
                            Reason =:= stale_owner;
                            Reason =:= lease_expired;
                            Reason =:= memory_outbox_dedupe_conflict ->
    {error, Reason};
tx_error({memory_outbox_capacity_exceeded, _, _, _} = Reason) ->
    {error, Reason};
tx_error(Reason) -> {error, {memory_outbox_transaction_aborted, Reason}}.
