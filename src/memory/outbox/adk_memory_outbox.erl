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

-export([default_config/0, compile_config/1, init/1, table_names/1,
         enqueue/2, status/2, stats/1, semantics/1, health/1,
         validate_cluster_readiness/2,
         claim_due/4, claim_due/5, renew/5, complete_batch/5, retry/5,
         cancel/3, delete/2, prune_terminal/2, prune_terminal/3]).

-define(DEFAULT_JOBS_TABLE, adk_memory_outbox_job).
-define(DEFAULT_USAGE_TABLE, adk_memory_outbox_usage).
-define(DEFAULT_SCHEDULE_TABLE, adk_memory_outbox_schedule).

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
    finished_at = undefined,
    erasure_epoch = 0
}).

-record(adk_memory_outbox_usage, {
    key,
    active_jobs = 0,
    active_bytes = 0
}).

%% Active work uses `{JobsTable, DueAt, CreatedAt, JobId}' and terminal
%% retention uses `{JobsTable, terminal, FinishedAt, JobId}'.  Numbers sort
%% before atoms, so terminal rows cannot block due-work traversal. Including
%% the jobs table lets independently configured outboxes share this table.
-record(adk_memory_outbox_schedule, {
    key,
    format = 1
}).

default_config() ->
    #{jobs_table => ?DEFAULT_JOBS_TABLE,
      usage_table => ?DEFAULT_USAGE_TABLE,
      schedule_table => ?DEFAULT_SCHEDULE_TABLE,
      epochs_table => adk_memory_erasure_epoch,
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
      terminal_retention_ms => 604800000,
      max_prune_batch => 1000,
      max_claim_scan => 1000,
      max_terminal_records => 100000,
      cluster_mode => single_node,
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

table_names(#{jobs_table := Jobs, usage_table := Usage,
              schedule_table := Schedule,
              epochs_table := Epochs}) -> [Jobs, Usage, Schedule, Epochs];
table_names(#{jobs_table := Jobs, usage_table := Usage,
              epochs_table := Epochs}) -> [Jobs, Usage, Epochs];
table_names(#{jobs_table := Jobs, usage_table := Usage}) -> [Jobs, Usage];
table_names(_) -> [].

%% @doc Durably admit a job.  This performs only a bounded local transaction;
%% adapter resolution and ingestion are always left to a processor.
enqueue(Handle, Request) ->
    with_handle(
      Handle,
      fun(Jobs, Usage, Schedule, Epochs, Limits) ->
          case validate_store_topology(
                 Jobs, Usage, Schedule, Epochs, Limits) of
              {ok, _Cluster} ->
                  case adk_memory_outbox_payload:prepare(Request, Limits) of
                      {ok, Prepared} ->
                          enqueue_prepared(
                            Jobs, Usage, Schedule, Epochs, Limits, Prepared);
                      {error, _} = Error -> Error
                  end;
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

%% @doc Explicit delivery and clustering guarantees for operators.
semantics(Handle) ->
    with_handle(
      Handle,
      fun(Jobs, Usage, Schedule, Epochs, Limits) ->
          case store_topology(Jobs, Usage, Schedule, Epochs, Limits) of
              {ok, {Cluster0, NodesByTable}} ->
                  Cluster = Cluster0#{
                    job_table_nodes => maps:get(Jobs, NodesByTable),
                    usage_table_nodes => maps:get(Usage, NodesByTable),
                    schedule_table_nodes => maps:get(Schedule, NodesByTable),
                    epoch_table_nodes => maps:get(Epochs, NodesByTable),
                    quorum => mnesia_majority,
                    partition_behavior => fail_closed},
                  {ok, #{delivery => at_least_once,
                         mutation_replay => idempotency_keyed,
                         claim_fencing => lease_owner_token,
                         erasure_fencing => transactional_epoch,
                         terminal_retention_ms =>
                             maps:get(terminal_retention_ms, Limits),
                         cluster => Cluster}};
              {error, _} = Error -> Error
          end
      end).

%% @doc Constant-row readiness check for health probes.
%%
%% Unlike `stats/1', this never folds a jobs table. It verifies the fixed table
%% schemas and topology, then performs point reads plus a single sentinel write
%% in one transaction. Runtime health can therefore remain independent of the
%% number of retained jobs.
health(Handle) ->
    with_handle(
      Handle,
      fun(Jobs, Usage, Schedule, Epochs, Limits) ->
          case validate_store_topology(
                 Jobs, Usage, Schedule, Epochs, Limits) of
              {ok, Cluster} ->
                  case health_sentinel_transaction(
                         Jobs, Usage, Schedule, Epochs) of
                      ok ->
                          {ok, #{status => ready,
                                 persistence => mnesia,
                                 schema => ready,
                                 transaction => ready,
                                 tables => [Jobs, Usage, Schedule, Epochs],
                                 cluster => Cluster}};
                      {error, _} = Error -> Error
                  end;
              {error, _} = Error -> Error
          end
      end).

%% @doc Pure cluster-topology validation used by startup and health tests.
validate_cluster_readiness(Mode, Nodes0)
  when (Mode =:= single_node orelse Mode =:= mnesia_majority),
       is_list(Nodes0) ->
    case lists:all(fun is_atom/1, Nodes0) of
        true ->
            Nodes = lists:usort(Nodes0),
            validate_cluster_nodes(Mode, Nodes);
        false ->
            {error, {invalid_memory_outbox_cluster_nodes, Nodes0}}
    end;
validate_cluster_readiness(Mode, _Nodes) ->
    {error, {invalid_memory_outbox_cluster_mode, Mode}}.

validate_cluster_nodes(single_node, []) ->
    {error, {memory_outbox_cluster_not_ready,
             #{mode => single_node, shared_nodes => []}}};
validate_cluster_nodes(single_node, Nodes) ->
    {ok, #{mode => single_node,
           shared_nodes => Nodes,
           multi_node_ready => false}};
validate_cluster_nodes(mnesia_majority, [_Only] = Nodes) ->
    {error, {memory_outbox_cluster_not_ready,
             #{mode => mnesia_majority, shared_nodes => Nodes,
               required_shared_nodes => 2}}};
validate_cluster_nodes(mnesia_majority, []) ->
    {error, {memory_outbox_cluster_not_ready,
             #{mode => mnesia_majority, shared_nodes => [],
               required_shared_nodes => 2}}};
validate_cluster_nodes(mnesia_majority, Nodes) ->
    {ok, #{mode => mnesia_majority,
           shared_nodes => Nodes,
           multi_node_ready => true}}.

health_table_definitions(Jobs, Usage, Schedule, Epochs) ->
    [{Jobs, adk_memory_outbox_job,
      record_info(fields, adk_memory_outbox_job), set},
     {Usage, adk_memory_outbox_usage,
      record_info(fields, adk_memory_outbox_usage), set},
     {Schedule, adk_memory_outbox_schedule,
      record_info(fields, adk_memory_outbox_schedule), ordered_set},
     {Epochs, adk_memory_erasure_epoch,
      [scope, epoch, updated_at], set}].

validate_store_topology(Jobs, Usage, Schedule, Epochs, Limits) ->
    case store_topology(Jobs, Usage, Schedule, Epochs, Limits) of
        {ok, {Cluster, _NodesByTable}} -> {ok, Cluster};
        {error, _} = Error -> Error
    end.

store_topology(Jobs, Usage, Schedule, Epochs, Limits) ->
    Definitions = health_table_definitions(Jobs, Usage, Schedule, Epochs),
    case health_table_topology(Definitions, #{}) of
        {ok, NodesByTable} ->
            SharedNodes = shared_table_nodes(maps:values(NodesByTable)),
            case validate_cluster_readiness(
                   maps:get(cluster_mode, Limits), SharedNodes) of
                {ok, Cluster} -> {ok, {Cluster, NodesByTable}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

health_table_topology([], Acc) -> {ok, Acc};
health_table_topology(
  [{Table, RecordName, Attributes, Type} | Rest], Acc) ->
    Actual = try
        {mnesia:table_info(Table, record_name),
         mnesia:table_info(Table, attributes),
         mnesia:table_info(Table, type),
         mnesia:table_info(Table, storage_type),
         mnesia:table_info(Table, majority),
         lists:sort(mnesia:table_info(Table, all_nodes))}
    catch
        exit:Reason -> {error, Reason}
    end,
    case Actual of
        {RecordName, Attributes, Type, disc_copies, true, Nodes}
          when is_list(Nodes) ->
            health_table_topology(Rest, Acc#{Table => Nodes});
        _ ->
            {error, {memory_outbox_health_schema_mismatch, Table, Actual}}
    end.

shared_table_nodes([]) -> [];
shared_table_nodes([First | Rest]) ->
    lists:foldl(
      fun(Nodes, Shared) ->
          [Node || Node <- Shared, lists:member(Node, Nodes)]
      end, lists:usort(First), Rest).

health_sentinel_transaction(Jobs, Usage, Schedule, Epochs) ->
    Sentinel = {memory_outbox_health_sentinel, Jobs},
    Markers = [
        {Jobs, #adk_memory_outbox_job{
                  id = Sentinel, created_at = 0, updated_at = 0}},
        {Usage, #adk_memory_outbox_usage{key = Sentinel}},
        {Schedule, #adk_memory_outbox_schedule{key = Sentinel}},
        {Epochs, {adk_memory_erasure_epoch, Sentinel, 0, 0}}
    ],
    Tx = fun() ->
        %% Exercise write quorum and schema compatibility for every required
        %% table, then remove all four fixed markers in the same transaction.
        lists:foreach(
          fun({Table, Marker}) ->
              mnesia:write(Table, Marker, write),
              case mnesia:read(Table, Sentinel, read) of
                  [Marker] -> ok;
                  _ -> mnesia:abort(
                         {memory_outbox_health_sentinel_failed, Table})
              end
          end, Markers),
        lists:foreach(
          fun({Table, _Marker}) ->
              mnesia:delete(Table, Sentinel, write)
          end, Markers),
        ok
    end,
    case mnesia:transaction(Tx) of
        {atomic, ok} -> ok;
        {aborted, Reason} ->
            {error, {memory_outbox_health_transaction_failed, Reason}}
    end.

%% @doc Claim one due batch.  `OwnerToken' is an unguessable runtime binary;
%% unlike a pid it is safe to persist as a lease fence.
claim_due(Handle, OwnerToken, Now, LeaseMs)
  -> claim_due(Handle, OwnerToken, Now, LeaseMs, all).

claim_due(Handle, OwnerToken, Now, LeaseMs, Claimable0)
  when is_binary(OwnerToken), byte_size(OwnerToken) > 0,
       byte_size(OwnerToken) =< 256,
       is_integer(Now), is_integer(LeaseMs), LeaseMs > 0 ->
    case validate_claimable_filter(Claimable0) of
        {ok, Claimable} ->
            with_handle(
              Handle,
              fun(Jobs, Usage, Schedule, Epochs, Limits) ->
                  case validate_store_topology(
                         Jobs, Usage, Schedule, Epochs, Limits) of
                      {ok, _Cluster} ->
                          Tx = fun() -> claim_due_tx(
                                            Jobs, Usage, Schedule, Epochs,
                                            OwnerToken, Now, LeaseMs,
                                            maps:get(max_claim_scan, Limits),
                                            Claimable)
                               end,
                          case mnesia:transaction(Tx) of
                              {atomic, none} -> none;
                              {atomic, {ok, Work}} -> {ok, Work};
                              {aborted, Reason} -> tx_error(Reason)
                          end;
                      {error, _} = Error -> Error
                  end
              end);
        {error, _} = Error -> Error
    end;
claim_due(_Handle, _OwnerToken, _Now, _LeaseMs, _Claimable) ->
    {error, invalid_memory_outbox_claim}.

validate_claimable_filter(all) -> {ok, all};
validate_claimable_filter(Claimable)
  when is_map(Claimable), map_size(Claimable) =< 10000 ->
    case maps:fold(
           fun({Module, StableId}, true, Acc)
                 when is_atom(Module), is_binary(StableId),
                      byte_size(StableId) > 0,
                      byte_size(StableId) =< 256 -> Acc;
              (_Identity, _Value, _Acc) -> false
           end, true, Claimable) of
        true -> {ok, Claimable};
        false -> {error, invalid_memory_outbox_claimable_identities}
    end;
validate_claimable_filter(_Claimable) ->
    {error, invalid_memory_outbox_claimable_identities}.

renew(Handle, JobId, OwnerToken, Now, LeaseMs)
  when is_binary(JobId), is_binary(OwnerToken),
       is_integer(Now), is_integer(LeaseMs), LeaseMs > 0 ->
    renew_owned(Handle, JobId, OwnerToken, Now, LeaseMs);
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
      fun(Jobs, Usage, Schedule, Epochs, _Limits) ->
          Tx = fun() ->
              case read_owned_fenced_tx(
                     Jobs, Usage, Schedule, Epochs,
                     JobId, OwnerToken, Now) of
                  {ok, Record} ->
                      retry_record_tx(
                        Jobs, Usage, Schedule, Record, SafeReason, Now);
                  {cancelled, Status} -> Status;
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
      fun(Jobs, Usage, Schedule, _Epochs, _Limits) ->
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
                              write_job_tx(
                                Jobs, Usage, Schedule, Record, Finished),
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
      fun(Jobs, Usage, Schedule, _Epochs, _Limits) ->
          Tx = fun() ->
              case mnesia:read(Jobs, JobId, write) of
                  [] -> mnesia:abort(not_found);
                  [Record] ->
                      case terminal(Record#adk_memory_outbox_job.phase) of
                          true ->
                              delete_terminal_job_tx(
                                Jobs, Usage, Schedule, Record),
                              ok;
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

%% @doc Delete terminal records older than the configured retention window.
%% Work is explicitly bounded and active records are never touched.
prune_terminal(Handle, Now) ->
    case Handle of
        #{limits := Limits} ->
            prune_terminal(Handle, Now, maps:get(max_prune_batch, Limits));
        _ -> {error, invalid_memory_outbox_handle}
    end.

prune_terminal(Handle, Now, Limit)
  when is_integer(Now), is_integer(Limit), Limit > 0 ->
    with_handle(
      Handle,
      fun(Jobs, Usage, Schedule, _Epochs, Limits) ->
          Max = maps:get(max_prune_batch, Limits),
          case Limit =< Max of
              false -> {error, {memory_outbox_prune_limit_exceeded, Max}};
              true ->
                  Cutoff = Now - maps:get(terminal_retention_ms, Limits),
                  Tx = fun() ->
                      First = first_terminal_key_tx(Schedule, Jobs),
                      Deleted = prune_terminal_index_tx(
                                  Jobs, Usage, Schedule,
                                  Cutoff, Limit, First, 0),
                      #{deleted => Deleted, cutoff => Cutoff}
                  end,
                  case mnesia:transaction(Tx) of
                      {atomic, Result} -> {ok, Result};
                      {aborted, Reason} -> tx_error(Reason)
                  end
          end
      end);
prune_terminal(_Handle, _Now, _Limit) ->
    {error, invalid_memory_outbox_prune_request}.

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
    Schedule = maps:get(schedule_table, Config),
    Epochs = maps:get(epochs_table, Config),
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
               {max_prune_batch, 100000},
               {max_claim_scan, 100000},
               {max_terminal_records, 10000000},
               {table_wait_ms, 60000}],
    Retention = maps:get(terminal_retention_ms, Config),
    ClusterMode = maps:get(cluster_mode, Config),
    Distinct = length(lists:usort([Jobs, Usage, Schedule, Epochs])) =:= 4,
    DefaultEpochs = adk_memory_erasure_epoch:default_table(),
    case {is_atom(Jobs), is_atom(Usage), is_atom(Schedule),
          Epochs =:= DefaultEpochs, Distinct,
          first_bad_number(Numeric, Config),
          is_integer(Retention) andalso Retention >= 0 andalso
              Retention =< 315360000000,
          lists:member(ClusterMode, [single_node, mnesia_majority])} of
        {true, true, true, true, true, none, true, true} ->
            validate_config_relations(Config);
        {false, _, _, _, _, _, _, _} ->
            {error, {invalid_memory_outbox_config, jobs_table}};
        {_, false, _, _, _, _, _, _} ->
            {error, {invalid_memory_outbox_config, usage_table}};
        {_, _, false, _, _, _, _, _} ->
            {error, {invalid_memory_outbox_config, schedule_table}};
        {_, _, _, false, _, _, _, _} ->
            {error, {invalid_memory_outbox_config, epochs_table}};
        {_, _, _, _, false, _, _, _} ->
            {error, {invalid_memory_outbox_config, duplicate_table_names}};
        {_, _, _, _, _, Error, _, _} when Error =/= none ->
            {error, {invalid_memory_outbox_config, Error}};
        {_, _, _, _, _, _, false, _} ->
            {error, {invalid_memory_outbox_config,
                     terminal_retention_ms}};
        {_, _, _, _, _, _, _, false} ->
            {error, {invalid_memory_outbox_config, cluster_mode}};
        {_, _, _, _, _, Error, _, _} ->
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
            Limits = maps:without(
                       [jobs_table, usage_table, schedule_table,
                        epochs_table], Config),
            {ok, #{jobs_table => maps:get(jobs_table, Config),
                   usage_table => maps:get(usage_table, Config),
                   schedule_table => maps:get(schedule_table, Config),
                   epochs_table => maps:get(epochs_table, Config),
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
                schedule_table := Schedule,
                epochs_table := Epochs,
                limits := Limits} = Handle) ->
    Definitions = [
        {Jobs, adk_memory_outbox_job,
         record_info(fields, adk_memory_outbox_job), set},
        {Usage, adk_memory_outbox_usage,
         record_info(fields, adk_memory_outbox_usage), set},
        {Schedule, adk_memory_outbox_schedule,
         record_info(fields, adk_memory_outbox_schedule), ordered_set}
    ],
    case create_tables_list(Definitions) of
        ok ->
            Timeout = maps:get(table_wait_ms, Limits),
            case adk_memory_erasure_epoch:ensure_table(Epochs) of
                ok ->
                    case mnesia:wait_for_tables(
                           [Jobs, Usage, Schedule, Epochs], Timeout) of
                        ok ->
                            case verify_tables(Jobs, Usage, Schedule) of
                                ok -> case reconcile_usage(Handle) of
                                    ok -> {ok, Handle};
                                    {error, _} = Error -> Error
                                end;
                                {error, _} = Error -> Error
                            end;
                        {timeout, Missing} ->
                            {error, {memory_outbox_table_wait_timeout,
                                     Missing}};
                        {error, Reason} ->
                            {error, {memory_outbox_table_wait_failed, Reason}}
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

create_tables_list([]) -> ok;
create_tables_list([{Table, RecordName, Attributes, Type} | Rest]) ->
    Options = [{attributes, Attributes},
               {record_name, RecordName},
               {disc_copies, [node()]},
               {type, Type},
               {majority, true}],
    case mnesia:create_table(Table, Options) of
        {atomic, ok} -> create_tables_list(Rest);
        {aborted, {already_exists, Table}} -> create_tables_list(Rest);
        {aborted, Reason} ->
            {error, {memory_outbox_table_creation_failed, Table, Reason}}
    end.

verify_tables(Jobs, Usage, Schedule) ->
    Expected = [
        {Jobs, adk_memory_outbox_job,
         record_info(fields, adk_memory_outbox_job), set},
        {Usage, adk_memory_outbox_usage,
         record_info(fields, adk_memory_outbox_usage), set},
        {Schedule, adk_memory_outbox_schedule,
         record_info(fields, adk_memory_outbox_schedule), ordered_set}
    ],
    verify_table_list(Expected).

verify_table_list([]) -> ok;
verify_table_list([{Table, RecordName, Attributes, Type} | Rest]) ->
    Actual = try
        {mnesia:table_info(Table, record_name),
         mnesia:table_info(Table, attributes),
         mnesia:table_info(Table, type),
         mnesia:table_info(Table, storage_type),
         mnesia:table_info(Table, majority)}
    catch
        exit:Reason -> {error, Reason}
    end,
    case Actual of
        {RecordName, Attributes, Type, disc_copies, true} ->
            verify_table_list(Rest);
        {adk_memory_outbox_job, Legacy, set, disc_copies, true}
          when RecordName =:= adk_memory_outbox_job,
               length(Legacy) + 1 =:= length(Attributes) ->
            ExpectedLegacy = lists:sublist(
                               Attributes, length(Attributes) - 1),
            case Legacy =:= ExpectedLegacy of
                true ->
                    Transform = fun(Tuple) ->
                        list_to_tuple(tuple_to_list(Tuple) ++ [0])
                    end,
                    case mnesia:transform_table(
                           Table, Transform, Attributes, RecordName) of
                        {atomic, ok} -> verify_table_list(Rest);
                        {aborted, _} ->
                            {error, {memory_outbox_table_migration_failed,
                                     Table}}
                    end;
                false ->
                    {error, {memory_outbox_table_schema_mismatch,
                             Table, Actual}}
            end;
        _ -> {error, {memory_outbox_table_schema_mismatch, Table, Actual}}
    end.

reconcile_usage(#{jobs_table := Jobs, usage_table := Usage,
                  schedule_table := Schedule}) ->
    Tx = fun() ->
        mnesia:write_lock_table(Jobs),
        mnesia:write_lock_table(Usage),
        mnesia:write_lock_table(Schedule),
        clear_schedule_namespace_tx(Schedule, Jobs),
        UsageKeys = mnesia:foldl(
                      fun(#adk_memory_outbox_usage{key = Key}, Acc) ->
                              [Key | Acc]
                      end, [], Usage),
        lists:foreach(fun(Key) -> mnesia:delete(Usage, Key, write) end,
                      UsageKeys),
        {GlobalJobs, GlobalBytes, TerminalJobs, Scopes} = mnesia:foldl(
          fun(Record, {JobsAcc, BytesAcc, TerminalAcc, ScopeAcc}) ->
              case terminal(Record#adk_memory_outbox_job.phase) of
                  true ->
                      write_terminal_schedule_tx(Schedule, Jobs, Record),
                      {JobsAcc, BytesAcc, TerminalAcc + 1, ScopeAcc};
                  false ->
                      write_schedule_tx(Schedule, Jobs, Record),
                      Scope = record_scope(Record),
                      Bytes = Record#adk_memory_outbox_job.storage_bytes,
                      {ScopeJobs, ScopeBytes} = maps:get(
                                                   Scope, ScopeAcc, {0, 0}),
                      {JobsAcc + 1, BytesAcc + Bytes, TerminalAcc,
                       ScopeAcc#{Scope => {ScopeJobs + 1,
                                           ScopeBytes + Bytes}}}
              end
          end, {0, 0, 0, #{}}, Jobs),
        write_usage_tx(Usage, global_key(), GlobalJobs, GlobalBytes),
        write_terminal_count_tx(Usage, Jobs, TerminalJobs),
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

clear_schedule_namespace_tx(Schedule, Jobs) ->
    clear_schedule_namespace_tx(
      Schedule, Jobs, first_schedule_key_tx(Schedule, Jobs)).

clear_schedule_namespace_tx(_Schedule, _Jobs, '$end_of_table') -> ok;
clear_schedule_namespace_tx(Schedule, Jobs, Key)
  when is_tuple(Key), tuple_size(Key) > 0,
       element(1, Key) =:= Jobs ->
    Next = mnesia:next(Schedule, Key),
    mnesia:delete(Schedule, Key, write),
    clear_schedule_namespace_tx(Schedule, Jobs, Next);
clear_schedule_namespace_tx(_Schedule, _Jobs, _OtherNamespace) -> ok.

%% Admission and claim internals

enqueue_prepared(Jobs, Usage, Schedule, Epochs, Limits, Prepared) ->
    Now = erlang:system_time(millisecond),
    BaseJobId = maps:get(job_id, Prepared),
    Tx = fun() ->
        Scope = maps:get(scope, Prepared),
        Epoch = adk_memory_erasure_epoch:current_tx(
                  Epochs, Scope, write),
        JobId = epoch_job_id(BaseJobId, Epoch),
        Record = prepared_record(
                   Prepared#{job_id => JobId}, Limits, Now, Epoch),
        case mnesia:read(Jobs, JobId, write) of
            [] ->
                ensure_terminal_capacity_tx(
                  Jobs, Usage, maps:get(max_terminal_records, Limits)),
                reserve_usage_tx(Usage, Limits, Record),
                write_job_tx(Jobs, Usage, Schedule, undefined, Record),
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

prepared_record(Prepared, Limits, Now, Epoch) ->
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
        erasure_epoch = Epoch,
        created_at = Now,
        updated_at = Now}.

ensure_terminal_capacity_tx(Jobs, Usage, Max) ->
    TerminalCount = terminal_count_tx(Usage, Jobs),
    Active = read_usage_tx(Usage, global_key()),
    Reserved = TerminalCount
               + Active#adk_memory_outbox_usage.active_jobs,
    case Reserved >= Max of
        true ->
            mnesia:abort({memory_outbox_terminal_retention_full, Max});
        false -> ok
    end.

same_job(Existing, Proposed) ->
    Existing#adk_memory_outbox_job.payload_digest =:=
        Proposed#adk_memory_outbox_job.payload_digest andalso
    record_scope(Existing) =:= record_scope(Proposed) andalso
    Existing#adk_memory_outbox_job.session_id =:=
        Proposed#adk_memory_outbox_job.session_id andalso
    Existing#adk_memory_outbox_job.adapter_module =:=
        Proposed#adk_memory_outbox_job.adapter_module andalso
    Existing#adk_memory_outbox_job.adapter_id =:=
        Proposed#adk_memory_outbox_job.adapter_id andalso
    Existing#adk_memory_outbox_job.erasure_epoch =:=
        Proposed#adk_memory_outbox_job.erasure_epoch.

%% Epoch zero preserves the pre-fencing identifier for upgrade idempotency.
%% Once erasure advances the fence, identical event IDs intentionally produce
%% a distinct durable job in the new privacy generation.
epoch_job_id(BaseJobId, 0) -> BaseJobId;
epoch_job_id(BaseJobId, Epoch) when is_integer(Epoch), Epoch > 0 ->
    <<Prefix:20/binary, _/binary>> = crypto:hash(
                                      sha256,
                                      term_to_binary(
                                        {BaseJobId, Epoch},
                                        [deterministic])),
    <<"memout-", (hex_bytes(Prefix))/binary>>.

hex_bytes(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 15))>>
       || <<Byte>> <= Binary >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.

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

claim_due_tx(Jobs, Usage, Schedule, Epochs,
             OwnerToken, Now, LeaseMs, MaxScan, Claimable) ->
    First = claim_scan_start_tx(Schedule, Jobs),
    claim_due_index_tx(Jobs, Usage, Schedule, Epochs,
                       OwnerToken, Now, LeaseMs, MaxScan, Claimable,
                       First, 0, undefined).

claim_due_index_tx(Jobs, _Usage, Schedule, _Epochs,
                   _OwnerToken, _Now, _LeaseMs, MaxScan, _Claimable,
                   _Key, Seen, Last)
  when Seen >= MaxScan ->
    write_claim_cursor_tx(Schedule, Jobs, Last),
    none;
claim_due_index_tx(Jobs, _Usage, Schedule, _Epochs,
                   _OwnerToken, _Now, _LeaseMs, _MaxScan, _Claimable,
                   '$end_of_table', _Seen, _Last) ->
    clear_claim_cursor_tx(Schedule, Jobs),
    none;
claim_due_index_tx(Jobs, Usage, Schedule, Epochs,
                   OwnerToken, Now, LeaseMs, MaxScan, Claimable,
                   {Jobs, Due, _Created, JobId} = Key, Seen, _Last)
  when is_integer(Due), Due =< Now ->
    Next = mnesia:next(Schedule, Key),
    case mnesia:read(Schedule, Key, write) of
        [] ->
            claim_due_index_tx(
              Jobs, Usage, Schedule, Epochs, OwnerToken, Now, LeaseMs,
              MaxScan, Claimable, Next, Seen + 1, Key);
        [_] ->
            case mnesia:read(Jobs, JobId, write) of
                [] ->
                    mnesia:delete(Schedule, Key, write),
                    claim_due_index_tx(
                      Jobs, Usage, Schedule, Epochs,
                      OwnerToken, Now, LeaseMs, MaxScan, Claimable,
                      Next, Seen + 1, Key);
                [Record] ->
                    claim_indexed_record_tx(
                      Jobs, Usage, Schedule, Epochs, Record, Key, Next,
                      OwnerToken, Now, LeaseMs, MaxScan, Claimable, Seen)
            end
    end;
claim_due_index_tx(Jobs, _Usage, Schedule, _Epochs,
                   _OwnerToken, _Now, _LeaseMs, _MaxScan, _Claimable,
                   {_OtherJobs, _Due, _Created, _JobId}, _Seen, _Last) ->
    clear_claim_cursor_tx(Schedule, Jobs),
    none;
claim_due_index_tx(Jobs, _Usage, Schedule, _Epochs,
                   _OwnerToken, _Now, _LeaseMs, _MaxScan, _Claimable,
                   _Malformed, _Seen, _Last) ->
    clear_claim_cursor_tx(Schedule, Jobs),
    none.

claim_indexed_record_tx(Jobs, Usage, Schedule, Epochs, Record, Key, Next,
                        OwnerToken, Now, LeaseMs, MaxScan, Claimable, Seen) ->
    case schedule_key(Jobs, Record) of
        Key ->
            process_due_record_tx(
              Jobs, Usage, Schedule, Epochs, Record, Key, Next,
              OwnerToken, Now, LeaseMs, MaxScan, Claimable, Seen);
        Expected ->
            mnesia:delete(Schedule, Key, write),
            write_schedule_key_tx(Schedule, Expected),
            claim_due_index_tx(
              Jobs, Usage, Schedule, Epochs,
              OwnerToken, Now, LeaseMs, MaxScan, Claimable,
              Next, Seen + 1, Key)
    end.

process_due_record_tx(Jobs, Usage, Schedule, Epochs, Record, Key, Next,
                      OwnerToken, Now, LeaseMs, MaxScan, Claimable, Seen) ->
    case lease_attempts_exhausted(Record, Now) of
        true ->
            Reason = #{<<"type">> =>
                           <<"lease_expired_after_max_attempts">>},
            Failed = terminal_record(Record, failed, Reason, Now),
            write_job_tx(Jobs, Usage, Schedule, Record, Failed),
            release_usage_tx(Usage, Record),
            claim_due_index_tx(
              Jobs, Usage, Schedule, Epochs,
              OwnerToken, Now, LeaseMs, MaxScan, Claimable,
              Next, Seen + 1, Key);
        false ->
            process_epoch_fenced_record_tx(
              Jobs, Usage, Schedule, Epochs, Record, Key, Next,
              OwnerToken, Now, LeaseMs, MaxScan, Claimable, Seen)
    end.

process_epoch_fenced_record_tx(Jobs, Usage, Schedule, Epochs,
                               Record, Key, Next, OwnerToken, Now,
                               LeaseMs, MaxScan, Claimable, Seen) ->
    Scope = record_scope(Record),
    Current = adk_memory_erasure_epoch:current_tx(Epochs, Scope, read),
    case Current =:= Record#adk_memory_outbox_job.erasure_epoch of
        false ->
            Reason = #{<<"type">> => <<"erasure_epoch_advanced">>},
            Cancelled = terminal_record(Record, cancelled, Reason, Now),
            write_job_tx(Jobs, Usage, Schedule, Record, Cancelled),
            release_usage_tx(Usage, Record),
            claim_due_index_tx(
              Jobs, Usage, Schedule, Epochs,
              OwnerToken, Now, LeaseMs, MaxScan, Claimable,
              Next, Seen + 1, Key);
        true ->
            case record_claimable(Record, Claimable) of
                false ->
                    claim_due_index_tx(
                      Jobs, Usage, Schedule, Epochs,
                      OwnerToken, Now, LeaseMs, MaxScan, Claimable,
                      Next, Seen + 1, Key);
                true ->
                    Claimed = Record#adk_memory_outbox_job{
                        phase = running,
                        attempt = Record#adk_memory_outbox_job.attempt + 1,
                        next_attempt_at = 0,
                        owner_token = OwnerToken,
                        lease_until = Now + LeaseMs,
                        revision = Record#adk_memory_outbox_job.revision + 1,
                        updated_at = Now},
                    write_job_tx(Jobs, Usage, Schedule, Record, Claimed),
                    clear_claim_cursor_tx(Schedule, Jobs),
                    {ok, work_item(Claimed)}
            end
    end.

record_claimable(_Record, all) -> true;
record_claimable(Record, Claimable) ->
    Identity = {Record#adk_memory_outbox_job.adapter_module,
                Record#adk_memory_outbox_job.adapter_id},
    maps:get(Identity, Claimable, false) =:= true.

claim_scan_start_tx(Schedule, Jobs) ->
    case mnesia:read(Schedule, claim_cursor_key(Jobs), write) of
        [#adk_memory_outbox_schedule{format = Last}]
          when is_tuple(Last), tuple_size(Last) =:= 4,
               element(1, Last) =:= Jobs ->
            case mnesia:next(Schedule, Last) of
                '$end_of_table' ->
                    clear_claim_cursor_tx(Schedule, Jobs),
                    first_schedule_key_tx(Schedule, Jobs);
                Next -> Next
            end;
        [_Malformed] ->
            clear_claim_cursor_tx(Schedule, Jobs),
            first_schedule_key_tx(Schedule, Jobs);
        [] -> first_schedule_key_tx(Schedule, Jobs)
    end.

write_claim_cursor_tx(_Schedule, _Jobs, undefined) -> ok;
write_claim_cursor_tx(Schedule, Jobs, Last) ->
    mnesia:write(
      Schedule,
      #adk_memory_outbox_schedule{key = claim_cursor_key(Jobs),
                                  format = Last},
      write).

clear_claim_cursor_tx(Schedule, Jobs) ->
    mnesia:delete(Schedule, claim_cursor_key(Jobs), write).

claim_cursor_key(Jobs) -> {Jobs, claim_cursor}.

lease_attempts_exhausted(
  #adk_memory_outbox_job{phase = running,
                         lease_until = Lease,
                         attempt = Attempt,
                         max_attempts = Max}, Now) ->
    Lease =< Now andalso Attempt >= Max;
lease_attempts_exhausted(_Record, _Now) -> false.

first_schedule_key_tx(Schedule, Jobs) ->
    mnesia:next(Schedule, {Jobs, -1, -1, <<>>}).

first_terminal_key_tx(Schedule, Jobs) ->
    mnesia:next(Schedule, {Jobs, terminal, -1, <<>>}).

schedule_key(Jobs,
             #adk_memory_outbox_job{phase = pending,
                                    attempt = Attempt,
                                    max_attempts = Max,
                                    created_at = Created,
                                    id = Id}) when Attempt < Max ->
    {Jobs, 0, Created, Id};
schedule_key(Jobs,
             #adk_memory_outbox_job{phase = retry_wait,
                                    next_attempt_at = Due,
                                    attempt = Attempt,
                                    max_attempts = Max,
                                    created_at = Created,
                                    id = Id}) when Attempt < Max ->
    {Jobs, Due, Created, Id};
schedule_key(Jobs,
             #adk_memory_outbox_job{phase = running,
                                    lease_until = Lease,
                                    created_at = Created,
                                    id = Id}) ->
    {Jobs, Lease, Created, Id};
schedule_key(_Jobs, _Record) -> none.

terminal_schedule_key(
  Jobs,
  #adk_memory_outbox_job{id = Id, phase = Phase,
                         finished_at = Finished})
  when is_integer(Finished) ->
    case terminal(Phase) of
        true -> {Jobs, terminal, Finished, Id};
        false -> none
    end;
terminal_schedule_key(_Jobs, _Record) -> none.

write_job_tx(Jobs, Usage, Schedule, Previous, Updated) ->
    delete_schedule_tx(Schedule, Jobs, Previous),
    delete_terminal_schedule_tx(Schedule, Jobs, Previous),
    adjust_terminal_count_tx(Usage, Jobs, Previous, Updated),
    mnesia:write(Jobs, Updated, write),
    write_schedule_tx(Schedule, Jobs, Updated),
    write_terminal_schedule_tx(Schedule, Jobs, Updated).

delete_schedule_tx(_Schedule, _Jobs, undefined) -> ok;
delete_schedule_tx(Schedule, Jobs, Record) ->
    case schedule_key(Jobs, Record) of
        none -> ok;
        Key -> mnesia:delete(Schedule, Key, write)
    end.

delete_terminal_schedule_tx(_Schedule, _Jobs, undefined) -> ok;
delete_terminal_schedule_tx(Schedule, Jobs, Record) ->
    case terminal_schedule_key(Jobs, Record) of
        none -> ok;
        Key -> mnesia:delete(Schedule, Key, write)
    end.

write_schedule_tx(Schedule, Jobs, Record) ->
    write_schedule_key_tx(Schedule, schedule_key(Jobs, Record)).

write_terminal_schedule_tx(Schedule, Jobs, Record) ->
    write_schedule_key_tx(
      Schedule, terminal_schedule_key(Jobs, Record)).

write_schedule_key_tx(_Schedule, none) -> ok;
write_schedule_key_tx(Schedule, Key) ->
    mnesia:write(
      Schedule, #adk_memory_outbox_schedule{key = Key}, write).

adjust_terminal_count_tx(Usage, Jobs, Previous, Updated) ->
    Delta = terminal_indicator(Updated) - terminal_indicator(Previous),
    adjust_terminal_count_tx(Usage, Jobs, Delta).

adjust_terminal_count_tx(_Usage, _Jobs, 0) -> ok;
adjust_terminal_count_tx(Usage, Jobs, Delta) ->
    Current = terminal_count_tx(Usage, Jobs),
    Updated = Current + Delta,
    case Updated >= 0 of
        true -> write_terminal_count_tx(Usage, Jobs, Updated);
        false -> mnesia:abort(
                   {memory_outbox_terminal_count_underflow, Jobs})
    end.

terminal_indicator(undefined) -> 0;
terminal_indicator(#adk_memory_outbox_job{phase = Phase}) ->
    case terminal(Phase) of
        true -> 1;
        false -> 0
    end.

delete_terminal_job_tx(Jobs, Usage, Schedule, Record) ->
    delete_schedule_tx(Schedule, Jobs, Record),
    delete_terminal_schedule_tx(Schedule, Jobs, Record),
    adjust_terminal_count_tx(Usage, Jobs, -1),
    mnesia:delete(
      Jobs, Record#adk_memory_outbox_job.id, write).

prune_terminal_index_tx(_Jobs, _Usage, _Schedule, _Cutoff,
                        Limit, _Key, Scanned)
  when Scanned >= Limit ->
    0;
prune_terminal_index_tx(_Jobs, _Usage, _Schedule, _Cutoff,
                        _Limit, '$end_of_table', _Scanned) ->
    0;
prune_terminal_index_tx(Jobs, Usage, Schedule, Cutoff, Limit,
                        {Jobs, terminal, Finished, JobId} = Key, Scanned)
  when is_integer(Finished), Finished =< Cutoff ->
    Next = mnesia:next(Schedule, Key),
    Deleted = case mnesia:read(Schedule, Key, write) of
        [] -> 0;
        [_] -> prune_terminal_key_tx(
                 Jobs, Usage, Schedule, JobId, Key)
    end,
    Deleted + prune_terminal_index_tx(
                Jobs, Usage, Schedule, Cutoff, Limit,
                Next, Scanned + 1);
prune_terminal_index_tx(_Jobs, _Usage, _Schedule, _Cutoff,
                        _Limit, _Key, _Scanned) ->
    0.

prune_terminal_key_tx(Jobs, Usage, Schedule, JobId, Key) ->
    case mnesia:read(Jobs, JobId, write) of
        [] ->
            %% A stale index cannot arise through this API, but removing it
            %% keeps bounded maintenance self-healing after manual repair.
            mnesia:delete(Schedule, Key, write),
            0;
        [Record] ->
            case terminal_schedule_key(Jobs, Record) of
                Key ->
                    delete_terminal_job_tx(
                      Jobs, Usage, Schedule, Record),
                    1;
                none ->
                    mnesia:delete(Schedule, Key, write),
                    0;
                CorrectedKey ->
                    mnesia:delete(Schedule, Key, write),
                    write_schedule_key_tx(Schedule, CorrectedKey),
                    0
            end
    end.

%% Completion, retry, and lease fences

complete_batch_result(Handle, JobId, OwnerToken, Result, Now) ->
    with_handle(
      Handle,
      fun(Jobs, Usage, Schedule, Epochs, _Limits) ->
          Tx = fun() ->
              case read_owned_fenced_tx(
                     Jobs, Usage, Schedule, Epochs,
                     JobId, OwnerToken, Now) of
                  {ok, Record} ->
                      complete_record_tx(
                        Jobs, Usage, Schedule, Record, Result, Now);
                  {cancelled, Status} -> Status;
                  {error, Reason} -> mnesia:abort(Reason)
              end
          end,
          tx_status_result(mnesia:transaction(Tx))
      end).

complete_record_tx(Jobs, Usage, Schedule, Record, Result, Now) ->
    Aggregate = sum_results(Record#adk_memory_outbox_job.result, Result),
    Next = Record#adk_memory_outbox_job.next_batch + 1,
    case Next > Record#adk_memory_outbox_job.total_batches of
        true ->
            Completed0 = terminal_record(Record, completed, undefined, Now),
            Completed = Completed0#adk_memory_outbox_job{result = Aggregate},
            write_job_tx(Jobs, Usage, Schedule, Record, Completed),
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
            write_job_tx(Jobs, Usage, Schedule, Record, Updated),
            public_status(Updated)
    end.

retry_record_tx(Jobs, Usage, Schedule, Record, SafeReason, Now) ->
    case Record#adk_memory_outbox_job.attempt >=
         Record#adk_memory_outbox_job.max_attempts of
        true ->
            Failed = terminal_record(Record, failed, SafeReason, Now),
            write_job_tx(Jobs, Usage, Schedule, Record, Failed),
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
            write_job_tx(Jobs, Usage, Schedule, Record, Waiting),
            public_status(Waiting)
    end.

retry_delay(Record) ->
    Attempt = Record#adk_memory_outbox_job.attempt,
    Shift = erlang:min(Attempt - 1, 20),
    erlang:min(Record#adk_memory_outbox_job.max_backoff_ms,
               Record#adk_memory_outbox_job.backoff_base_ms bsl Shift).

renew_owned(Handle, JobId, OwnerToken, Now, LeaseMs) ->
    with_handle(
      Handle,
      fun(Jobs, Usage, Schedule, Epochs, Limits) ->
          %% Renewal is the last ownership check before an external adapter
          %% mutation. Revalidate topology here as well as at claim time so a
          %% degraded majority configuration cannot authorize new effects.
          case validate_store_topology(
                 Jobs, Usage, Schedule, Epochs, Limits) of
              {ok, _Cluster} ->
                  Tx = fun() ->
                      case read_owned_fenced_tx(
                             Jobs, Usage, Schedule, Epochs,
                             JobId, OwnerToken, Now) of
                          {ok, Record} ->
                              Updated = Record#adk_memory_outbox_job{
                                  lease_until = Now + LeaseMs,
                                  revision =
                                      Record#adk_memory_outbox_job.revision + 1,
                                  updated_at = Now},
                              write_job_tx(
                                Jobs, Usage, Schedule, Record, Updated),
                              public_status(Updated);
                          {cancelled, Status} -> Status;
                          {error, Reason} -> mnesia:abort(Reason)
                      end
                  end,
                  tx_status_result(mnesia:transaction(Tx));
              {error, _} = Error -> Error
          end
      end).

read_owned_fenced_tx(Jobs, Usage, Schedule, Epochs,
                     JobId, OwnerToken, Now) ->
    case read_owned_tx(Jobs, JobId, OwnerToken, Now) of
        {ok, Record} ->
            Scope = record_scope(Record),
            Current = adk_memory_erasure_epoch:current_tx(
                        Epochs, Scope, read),
            case Current =:= Record#adk_memory_outbox_job.erasure_epoch of
                true -> {ok, Record};
                false ->
                    Reason = #{<<"type">> =>
                                   <<"erasure_epoch_advanced">>},
                    Cancelled = terminal_record(
                                  Record, cancelled, Reason, Now),
                    write_job_tx(
                      Jobs, Usage, Schedule, Record, Cancelled),
                    release_usage_tx(Usage, Record),
                    {cancelled, public_status(Cancelled)}
            end;
        {error, _} = Error -> Error
    end.

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

terminal_count_tx(Usage, Jobs) ->
    Record = read_usage_tx(Usage, terminal_count_key(Jobs)),
    Record#adk_memory_outbox_usage.active_jobs.

write_terminal_count_tx(Usage, Jobs, Count)
  when is_integer(Count), Count >= 0 ->
    mnesia:write(
      Usage,
      #adk_memory_outbox_usage{key = terminal_count_key(Jobs),
                               active_jobs = Count,
                               active_bytes = 0},
      write).

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
terminal_count_key(Jobs) -> {terminal_count, Jobs}.

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
      erasure_epoch => Record#adk_memory_outbox_job.erasure_epoch,
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
      erasure_epoch => Record#adk_memory_outbox_job.erasure_epoch,
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
              schedule_table := Schedule,
              epochs_table := Epochs, limits := Limits}, Fun)
  when is_atom(Jobs), is_atom(Usage), is_atom(Schedule), is_atom(Epochs),
       is_map(Limits), is_function(Fun, 5) ->
    Fun(Jobs, Usage, Schedule, Epochs, Limits);
with_handle(#{jobs_table := Jobs, usage_table := Usage,
              epochs_table := Epochs, limits := Limits}, Fun)
  when is_atom(Jobs), is_atom(Usage), is_atom(Epochs), is_map(Limits),
       is_function(Fun, 4) ->
    Fun(Jobs, Usage, Epochs, Limits);
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
