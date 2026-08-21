%% @doc Local durable Mnesia implementation of `adk_eval_store'.
%%
%% The adapter uses fixed, operator-owned table atoms and serializable records.
%% Operators may add replicas with normal Mnesia administration.  Every
%% capacity-changing mutation takes a write lock on the usage row, so limits
%% remain strict across concurrent callers and nodes.
-module(adk_eval_store_mnesia).
-behaviour(adk_eval_store).

-export([init/1, ownership_identity/1, capabilities/1,
         put_set/3, get_set/4, list_sets/3,
         create_job/3, create_evaluation/4,
         transition_job/6, get_job/3, list_jobs/3,
         put_baseline/4, get_baseline/3, recover_active/2, prune/3,
         table_names/1]).

-define(DEFAULT_SETS_TABLE, adk_eval_sets).
-define(DEFAULT_JOBS_TABLE, adk_eval_jobs).
-define(DEFAULT_BASELINES_TABLE, adk_eval_baselines).
-define(DEFAULT_USAGE_TABLE, adk_eval_store_usage).
-define(DEFAULT_MAX_SETS, 10000).
-define(DEFAULT_MAX_JOBS, 100000).
-define(DEFAULT_MAX_BASELINES, 10000).
-define(DEFAULT_MAX_PAGE_LIMIT, 100).
-define(DEFAULT_MAX_RECORD_BYTES, 16777216).
-define(DEFAULT_MAX_TOTAL_BYTES, 1073741824).
-define(DEFAULT_MAX_SCOPE_BYTES, 268435456).
-define(DEFAULT_MAX_PRUNE_LIMIT, 100).
-define(DEFAULT_MAX_PRUNE_SCAN, 1000).
-define(DEFAULT_RECOVERY_BATCH_SIZE, 100).
-define(DEFAULT_RECONCILIATION_BATCH_SIZE, 500).
-define(JOB_TERMINAL_HEADROOM_BYTES, 4608).
-define(MAX_PAGE_LIMIT, 1000).
-define(MAX_PRUNE_LIMIT, 10000).
-define(MAX_PRUNE_SCAN, 100000).
-define(DEFAULT_TABLE_WAIT_MS, 10000).

-record(adk_eval_set_row, {
    key, scope, id, version, digest, set, created_at
}).
-record(adk_eval_job_row, {
    key, scope, job_id, job, charged_bytes = 0
}).
-record(adk_eval_baseline_row, {
    key, scope, name, baseline
}).
-record(adk_eval_store_usage, {
    key, count = 0, bytes = 0, value = undefined
}).

-spec init(map()) -> {ok, map()} | {error, term()}.
init(Config0) when is_map(Config0) ->
    case normalize_config(Config0) of
        {ok, Handle} ->
            case application:ensure_all_started(mnesia) of
                {ok, _} -> ensure_schema_and_tables(Handle);
                {error, Reason} -> {error, {mnesia_start_failed, Reason}}
            end;
        {error, _} = Error -> Error
    end;
init(_Config) -> {error, invalid_eval_store_config}.

-spec ownership_identity(term()) -> {ok, term()} | {error, term()}.
ownership_identity(#{config_digest := Digest} = Handle)
  when is_binary(Digest) ->
    try
        case maps:get(config_digest, Handle, undefined) =:=
             config_digest(Handle) of
            true -> {ok, canonical_store_identity(Handle)};
            false -> {error, invalid_eval_store_handle}
        end
    catch
        _:_ -> {error, invalid_eval_store_handle}
    end;
ownership_identity(Config) when is_map(Config) ->
    case normalize_config(Config) of
        {ok, Handle} -> {ok, canonical_store_identity(Handle)};
        {error, _} = Error -> Error
    end;
ownership_identity(_ConfigOrHandle) ->
    {error, invalid_eval_store_config}.

-spec capabilities(map()) -> map().
capabilities(#{limits := Limits} = Handle) ->
    case validate_handle_config(Handle) of
        ok ->
            #{contract_version => 1, durable => true,
              immutable_set_revisions => true,
              atomic_job_transitions => true,
              atomic_evaluation_creation => true,
              baselines => true, pruning => true, limits => Limits};
        {error, _} -> #{}
    end;
capabilities(_Handle) -> #{}.

-spec table_names(map()) -> [atom()].
table_names(Handle) ->
    [maps:get(sets_table, Handle), maps:get(jobs_table, Handle),
     maps:get(baselines_table, Handle), maps:get(usage_table, Handle)].

put_set(Handle, Scope, Set0) ->
    case prepare_set(Scope, Set0) of
        {ok, Key, Set, Id, Version, Digest, Now} ->
            with_handle(Handle, fun(H) ->
                Table = maps:get(sets_table, H),
                Tx = fun() ->
                    case mnesia:read(Table, Key, write) of
                        [#adk_eval_set_row{digest = Digest} = Existing] ->
                            public_set(Existing);
                        [_] -> mnesia:abort(eval_set_revision_conflict);
                        [] ->
                            Row = #adk_eval_set_row{
                                    key = Key, scope = Scope, id = Id,
                                    version = Version, digest = Digest,
                                    set = Set, created_at = Now},
                            reserve(H, sets, Scope, stored_bytes(Row)),
                            mnesia:write(Table, Row, write),
                            public_set(Row)
                    end
                end,
                tx_value(mnesia:transaction(Tx))
            end);
        {error, _} = Error -> Error
    end.

get_set(Handle, Scope, Id, Version) ->
    case valid_set_lookup(Scope, Id, Version) of
        false -> {error, invalid_eval_set_lookup};
        true -> with_handle(Handle, fun(H) ->
            Table = maps:get(sets_table, H),
            case mnesia:transaction(
                   fun() -> mnesia:read(Table, {Scope, Id, Version}, read) end) of
                {atomic, [#adk_eval_set_row{set = Set}]} -> {ok, Set};
                {atomic, []} -> {error, not_found};
                {aborted, Reason} -> tx_error(Reason)
            end
        end)
    end.

list_sets(Handle, Scope, Options) ->
    list_rows(set, Handle, Scope, Options).

create_job(Handle, Scope, Job0) ->
    case prepare_job(Scope, Job0) of
        {ok, Key, Job} -> with_handle(Handle, fun(H) ->
            Table = maps:get(jobs_table, H),
            Sets = maps:get(sets_table, H),
            Tx = fun() ->
                case mnesia:read(Sets, job_set_key(Job), read) of
                    [] -> mnesia:abort(eval_set_not_found);
                    [_] -> ok
                end,
                case mnesia:read(Table, Key, write) of
                    [_] -> mnesia:abort(already_exists);
                    [] ->
                        Row = new_job_row(Key, Scope, Job),
                        reserve(H, jobs, Scope,
                                Row#adk_eval_job_row.charged_bytes),
                        mnesia:write(Table, Row, write),
                        increment_ref(H, set_ref_key(Job)),
                        adk_eval_store:public_job(Job)
                end
            end,
            tx_value(mnesia:transaction(Tx))
        end);
        {error, _} = Error -> Error
    end.

-spec create_evaluation(map(), adk_eval_store:scope(), map(), map()) ->
    {ok, map()} | {error, term()}.
create_evaluation(Handle, Scope, Set0, Job0) ->
    case prepare_evaluation(Scope, Set0, Job0) of
        {ok, SetKey, Set, Id, Version, Digest, Now, JobKey, Job} ->
            with_handle(Handle, fun(H) ->
                Sets = maps:get(sets_table, H),
                Jobs = maps:get(jobs_table, H),
                Tx = fun() ->
                    SetStatus = case mnesia:read(Sets, SetKey, write) of
                        [#adk_eval_set_row{digest = Digest} = Existing] ->
                            {existing, Existing};
                        [_] -> mnesia:abort(eval_set_revision_conflict);
                        [] -> new
                    end,
                    case mnesia:read(Jobs, JobKey, write) of
                        [_] -> mnesia:abort(already_exists);
                        [] -> ok
                    end,
                    PublicSet = case SetStatus of
                        {existing, ExistingSet} -> public_set(ExistingSet);
                        new ->
                            SetRow = #adk_eval_set_row{
                                       key = SetKey, scope = Scope, id = Id,
                                       version = Version, digest = Digest,
                                       set = Set, created_at = Now},
                            reserve(H, sets, Scope, stored_bytes(SetRow)),
                            mnesia:write(Sets, SetRow, write),
                            public_set(SetRow)
                    end,
                    JobRow = new_job_row(JobKey, Scope, Job),
                    reserve(H, jobs, Scope,
                            JobRow#adk_eval_job_row.charged_bytes),
                    mnesia:write(Jobs, JobRow, write),
                    increment_ref(H, set_ref_key(Job)),
                    #{set => PublicSet,
                      job => adk_eval_store:public_job(Job)}
                end,
                tx_value(mnesia:transaction(Tx))
            end);
        {error, _} = Error -> Error
    end.

transition_job(Handle, Scope, JobId, Expected, Phase, Patch) ->
    case prepare_transition(Scope, JobId, Expected, Phase, Patch) of
        {ok, Key, SafePatch} -> with_handle(Handle, fun(H) ->
            Table = maps:get(jobs_table, H),
            Tx = fun() ->
                case mnesia:read(Table, Key, write) of
                    [] -> mnesia:abort(not_found);
                    [#adk_eval_job_row{job = Job0} = Row] ->
                        Current = maps:get(phase, Job0),
                        case lists:member(Current, Expected) of
                            false -> mnesia:abort(stale_phase);
                            true ->
                                case legal_transition(Current, Phase) of
                                    false ->
                                        mnesia:abort(
                                          invalid_eval_job_transition);
                                    true ->
                                        Job = apply_transition(
                                                Job0, Phase, SafePatch),
                                        NewRow = transition_job_row(Row, Job),
                                        replace_job_charge(H, Scope, Row,
                                                           NewRow),
                                        mnesia:write(
                                          Table, NewRow,
                                          write),
                                        adk_eval_store:public_job(Job)
                                end
                        end
                end
            end,
            tx_value(mnesia:transaction(Tx))
        end);
        {error, _} = Error -> Error
    end.

get_job(Handle, Scope, JobId) ->
    case valid_job_lookup(Scope, JobId) of
        false -> {error, invalid_eval_job_lookup};
        true -> with_handle(Handle, fun(H) ->
            Table = maps:get(jobs_table, H),
            case mnesia:transaction(
                   fun() -> mnesia:read(Table, {Scope, JobId}, read) end) of
                {atomic, [#adk_eval_job_row{job = Job}]} -> {ok, Job};
                {atomic, []} -> {error, not_found};
                {aborted, Reason} -> tx_error(Reason)
            end
        end)
    end.

list_jobs(Handle, Scope, Options) ->
    list_rows(job, Handle, Scope, Options).

put_baseline(Handle, Scope, Name, JobId) ->
    case valid_baseline(Scope, Name, JobId) of
        false -> {error, invalid_eval_baseline};
        true -> with_handle(Handle, fun(H) ->
            Jobs = maps:get(jobs_table, H),
            Baselines = maps:get(baselines_table, H),
            JobKey = {Scope, JobId},
            Key = {Scope, Name},
            Tx = fun() ->
                case mnesia:read(Jobs, JobKey, read) of
                    [] -> mnesia:abort(not_found);
                    [#adk_eval_job_row{job = #{phase := completed,
                                               result := Result}}] ->
                        case mnesia:read(Baselines, Key, write) of
                            [] -> OldRow = undefined;
                            [Existing] -> OldRow = Existing
                        end,
                        Baseline = #{scope => Scope, name => Name,
                                     job_id => JobId,
                                     result_digest => adk_eval_store:digest(Result),
                                     result => Result, updated_at => now_ms()},
                        Row = #adk_eval_baseline_row{
                                key = Key, scope = Scope, name = Name,
                                baseline = Baseline},
                        case OldRow of
                            undefined ->
                                reserve(H, baselines, Scope,
                                        stored_bytes(Row));
                            #adk_eval_baseline_row{baseline = OldBaseline} ->
                                replace_bytes(H, Scope,
                                              stored_bytes(OldRow),
                                              stored_bytes(Row)),
                                update_baseline_ref(
                                  H, OldBaseline, Baseline)
                        end,
                        case OldRow of
                            undefined -> increment_ref(H, job_ref_key(Baseline));
                            _ -> ok
                        end,
                        mnesia:write(Baselines, Row, write),
                        Baseline;
                    [_] -> mnesia:abort(job_not_completed)
                end
            end,
            tx_value(mnesia:transaction(Tx))
        end)
    end.

get_baseline(Handle, Scope, Name) ->
    case adk_eval_store:validate_scope(Scope) =:= ok andalso
         adk_eval_store:valid_name(Name) of
        false -> {error, invalid_eval_baseline};
        true -> with_handle(Handle, fun(H) ->
            Table = maps:get(baselines_table, H),
            case mnesia:transaction(
                   fun() -> mnesia:read(Table, {Scope, Name}, read) end) of
                {atomic, [#adk_eval_baseline_row{baseline = Baseline}]} ->
                    {ok, Baseline};
                {atomic, []} -> {error, not_found};
                {aborted, Reason} -> tx_error(Reason)
            end
        end)
    end.

recover_active(Handle, Reason) when is_binary(Reason), byte_size(Reason) > 0,
                                    byte_size(Reason) =< 4096 ->
    with_handle(Handle, fun(H) ->
        recover_batches(H, Reason, first, 0)
    end);
recover_active(_Handle, _Reason) -> {error, invalid_eval_recovery_reason}.

-spec prune(map(), adk_eval_store:scope(), map()) ->
    {ok, map()} | {error, term()}.
prune(Handle, Scope, Options) ->
    case prune_options(Handle, Scope, Options) of
        {ok, Before, Limit, Cursor, IncludeBaselines} ->
          with_handle(Handle, fun(H) ->
            Tx = fun() -> prune_transaction(
                              H, Scope, Before, Limit, Cursor,
                              IncludeBaselines) end,
            tx_value(mnesia:transaction(Tx))
        end);
        {error, _} = Error -> Error
    end.

%% Configuration and tables

normalize_config(Config) ->
    Defaults = #{sets_table => ?DEFAULT_SETS_TABLE,
                 jobs_table => ?DEFAULT_JOBS_TABLE,
                 baselines_table => ?DEFAULT_BASELINES_TABLE,
                 usage_table => ?DEFAULT_USAGE_TABLE,
                 max_sets => ?DEFAULT_MAX_SETS,
                 max_jobs => ?DEFAULT_MAX_JOBS,
                 max_baselines => ?DEFAULT_MAX_BASELINES,
                 max_page_limit => ?DEFAULT_MAX_PAGE_LIMIT,
                 max_record_bytes => ?DEFAULT_MAX_RECORD_BYTES,
                 max_total_bytes => ?DEFAULT_MAX_TOTAL_BYTES,
                 max_scope_bytes => ?DEFAULT_MAX_SCOPE_BYTES,
                 max_prune_limit => ?DEFAULT_MAX_PRUNE_LIMIT,
                 max_prune_scan => ?DEFAULT_MAX_PRUNE_SCAN,
                 recovery_batch_size => ?DEFAULT_RECOVERY_BATCH_SIZE,
                 reconciliation_batch_size =>
                     ?DEFAULT_RECONCILIATION_BATCH_SIZE,
                 repair_usage => false,
                 table_wait_ms => ?DEFAULT_TABLE_WAIT_MS},
    Unknown = maps:keys(maps:without(maps:keys(Defaults), Config)),
    Merged = maps:merge(Defaults, Config),
    Tables = [maps:get(Key, Merged) || Key <-
                  [sets_table, jobs_table, baselines_table, usage_table]],
    Numbers = [{max_sets, 1000000}, {max_jobs, 1000000},
               {max_baselines, 1000000}, {max_page_limit, ?MAX_PAGE_LIMIT},
               {max_record_bytes, 1099511627776},
               {max_total_bytes, 1099511627776},
               {max_scope_bytes, 1099511627776},
               {max_prune_limit, ?MAX_PRUNE_LIMIT},
               {max_prune_scan, ?MAX_PRUNE_SCAN},
               {recovery_batch_size, 10000},
               {reconciliation_batch_size, 10000},
               {table_wait_ms, 60000}],
    case {Unknown, lists:all(fun is_atom/1, Tables),
          length(lists:usort(Tables)) =:= length(Tables),
          valid_numbers(Numbers, Merged), valid_byte_limits(Merged),
          is_boolean(maps:get(repair_usage, Merged))} of
        {[], true, true, true, true, true} ->
            Limits = maps:with([max_sets, max_jobs, max_baselines,
                                max_page_limit, max_record_bytes,
                                max_total_bytes, max_scope_bytes,
                                max_prune_limit, max_prune_scan], Merged),
            Handle0 = Merged#{limits => Limits},
            {ok, Handle0#{config_digest => config_digest(Handle0)}};
        {[_ | _], _, _, _, _, _} ->
            {error, {unknown_eval_store_options, lists:sort(Unknown)}};
        {_, false, _, _, _, _} -> {error, invalid_eval_store_table};
        {_, _, false, _, _, _} -> {error, duplicate_eval_store_tables};
        _ -> {error, invalid_eval_store_limits}
    end.

valid_numbers(Pairs, Config) ->
    lists:all(fun({Key, Ceiling}) ->
        Value = maps:get(Key, Config),
        is_integer(Value) andalso Value > 0 andalso Value =< Ceiling
    end, Pairs).

valid_byte_limits(Config) ->
    maps:get(max_record_bytes, Config) =< maps:get(max_scope_bytes, Config)
    andalso maps:get(max_scope_bytes, Config) =<
            maps:get(max_total_bytes, Config).

ensure_schema_and_tables(Handle) ->
    case ensure_disk_schema() of
        ok ->
            Specs = [
              {maps:get(sets_table, Handle), adk_eval_set_row,
               record_info(fields, adk_eval_set_row), ordered_set},
              {maps:get(jobs_table, Handle), adk_eval_job_row,
               record_info(fields, adk_eval_job_row), ordered_set},
              {maps:get(baselines_table, Handle), adk_eval_baseline_row,
               record_info(fields, adk_eval_baseline_row), ordered_set},
              {maps:get(usage_table, Handle), adk_eval_store_usage,
               record_info(fields, adk_eval_store_usage), ordered_set}],
            case create_tables(Specs) of
                ok ->
                    Tables = table_names(Handle),
                    case mnesia:wait_for_tables(
                           Tables, maps:get(table_wait_ms, Handle)) of
                        ok ->
                            case validate_tables(Specs) of
                                ok ->
                                    case ensure_config_fingerprint(Handle) of
                                        ok -> ensure_usage_consistent(Handle);
                                        {error, _} = Error -> Error
                                    end;
                                {error, _} = Error -> Error
                            end;
                        {timeout, Pending} ->
                            {error, {eval_store_table_wait_timeout, Pending}};
                        {error, Reason} ->
                            {error, {eval_store_table_wait_failed, Reason}}
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

ensure_disk_schema() ->
    case mnesia:change_table_copy_type(schema, node(), disc_copies) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, schema, Node, disc_copies}}
          when Node =:= node() -> ok;
        {aborted, Reason} -> {error, {schema_configuration_failed, Reason}}
    end.

create_tables([]) -> ok;
create_tables([{Table, RecordName, Fields, Type} | Rest]) ->
    Options = [{attributes, Fields}, {record_name, RecordName},
               {disc_copies, [node()]}, {type, Type}],
    case mnesia:create_table(Table, Options) of
        {atomic, ok} -> create_tables(Rest);
        {aborted, {already_exists, Table}} -> create_tables(Rest);
        {aborted, Reason} ->
            {error, {eval_store_table_creation_failed, Table, Reason}}
    end.

validate_tables([]) -> ok;
validate_tables([{Table, RecordName, Fields, Type} | Rest]) ->
    Expected = [{attributes, Fields}, {record_name, RecordName}, {type, Type}],
    case validate_table_properties(Table, Expected) of
        ok ->
            Copies = mnesia:table_info(Table, disc_copies),
            case lists:member(node(), Copies) of
                true -> validate_tables(Rest);
                false ->
                    {error, {eval_store_table_schema_mismatch, Table,
                             disc_copies, node(), lists:sort(Copies)}}
            end;
        {error, _} = Error -> Error
    end.

validate_table_properties(_Table, []) -> ok;
validate_table_properties(Table, [{Property, Expected} | Rest]) ->
    Actual = mnesia:table_info(Table, Property),
    case Actual =:= Expected of
        true -> validate_table_properties(Table, Rest);
        false -> {error, {eval_store_table_schema_mismatch, Table,
                          Property, Expected, Actual}}
    end.

ensure_config_fingerprint(Handle) ->
    Table = maps:get(usage_table, Handle),
    Digest = config_digest(Handle),
    Property = adk_eval_store_config_digest,
    case read_table_property(Table, Property) of
        {Property, Digest} -> ensure_config_usage_row(Table, Digest);
        undefined ->
            case ensure_config_usage_row(Table, Digest) of
                ok ->
                    case mnesia:write_table_property(
                           Table, {Property, Digest}) of
                        {atomic, ok} ->
                            case read_table_property(Table, Property) of
                                {Property, Digest} -> ok;
                                _ -> {error, eval_store_config_mismatch}
                            end;
                        {aborted, Reason} ->
                            {error, {eval_store_config_property_failed,
                                     Reason}}
                    end;
                {error, _} = Error -> Error
            end;
        _ -> {error, eval_store_config_mismatch}
    end.

read_table_property(Table, Property) ->
    try mnesia:read_table_property(Table, Property) of
        Value -> Value
    catch
        exit:{aborted, {no_exists, {Table, user_property, Property}}} ->
            undefined;
        exit:Reason -> {error, Reason}
    end.

ensure_config_usage_row(Table, Digest) ->
    Tx = fun() ->
        case mnesia:read(Table, config, write) of
            [] ->
                mnesia:write(
                  Table, #adk_eval_store_usage{key = config,
                                               value = Digest}, write),
                ok;
            [#adk_eval_store_usage{value = Digest}] -> ok;
            [_] -> mnesia:abort(eval_store_config_mismatch)
        end
    end,
    case mnesia:transaction(Tx) of
        {atomic, ok} -> ok;
        {aborted, eval_store_config_mismatch} ->
            {error, eval_store_config_mismatch};
        {aborted, Reason} -> tx_error(Reason)
    end.

config_digest(Handle) ->
    Keys = [sets_table, jobs_table, baselines_table, usage_table,
            limits,
            max_sets, max_jobs, max_baselines, max_page_limit,
            max_record_bytes, max_total_bytes, max_scope_bytes,
            max_prune_limit, max_prune_scan, recovery_batch_size,
            reconciliation_batch_size],
    adk_eval_store:digest(
      #{contract_version => 1, config => maps:with(Keys, Handle)}).

canonical_store_identity(Handle) ->
    {adk_eval_store_mnesia,
     #{tables => list_to_tuple(table_names(Handle)),
       config_digest => config_digest(Handle)}}.

ensure_usage_consistent(Handle) ->
    case maps:get(repair_usage, Handle) orelse
         not usage_is_ready_and_sized(Handle) of
        false -> {ok, Handle};
        true ->
            Resource = {adk_eval_store_usage_repair,
                        maps:get(usage_table, Handle), config_digest(Handle)},
            Lock = {Resource, self()},
            case global:trans(
                   Lock,
                   fun() ->
                       case usage_is_ready_and_sized(Handle) andalso
                            not maps:get(repair_usage, Handle) of
                           true -> {ok, Handle};
                           false -> repair_usage(Handle)
                       end
                   end) of
                aborted -> {error, eval_store_usage_repair_lock_failed};
                Result -> Result
            end
    end.

usage_is_ready_and_sized(Handle) ->
    Usage = maps:get(usage_table, Handle),
    try
        Ready = case mnesia:dirty_read(Usage, usage_state) of
            [#adk_eval_store_usage{value = ready}] -> true;
            _ -> false
        end,
        Ready andalso lists:all(
          fun({Kind, Table}) ->
              Count = case mnesia:dirty_read(Usage, Kind) of
                  [#adk_eval_store_usage{count = Value}] -> Value;
                  _ -> -1
              end,
              Count =:= mnesia:table_info(Table, size)
          end,
          [{sets, maps:get(sets_table, Handle)},
           {jobs, maps:get(jobs_table, Handle)},
           {baselines, maps:get(baselines_table, Handle)}])
    catch _:_ -> false end.

repair_usage(Handle) ->
    case reset_usage_for_repair(Handle) of
        ok ->
            case repair_kinds([sets, jobs, baselines], Handle) of
                ok -> finish_usage_repair(Handle);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

reset_usage_for_repair(Handle) ->
    Table = maps:get(usage_table, Handle),
    Mark = fun() ->
        mnesia:write(
          Table, #adk_eval_store_usage{key = usage_state,
                                       value = reconciling}, write)
    end,
    case tx_ok(mnesia:transaction(Mark)) of
        ok ->
            case clear_usage_batches(Handle, first) of
                ok -> seed_usage_repair(Handle);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

clear_usage_batches(Handle, Start) ->
    Table = maps:get(usage_table, Handle),
    Batch = maps:get(reconciliation_batch_size, Handle),
    Tx = fun() -> clear_usage_batch(Table, Start, Batch, undefined) end,
    case mnesia:transaction(Tx) of
        {atomic, {_Last, true}} -> ok;
        {atomic, {Last, false}} ->
            clear_usage_batches(Handle, {after_key, Last});
        {aborted, Reason} -> tx_error(Reason)
    end.

clear_usage_batch(_Table, _Start, 0, Last) -> {Last, false};
clear_usage_batch(Table, Start, Remaining, _Last) ->
    Key = case Start of
        first -> mnesia:first(Table);
        {after_key, Previous} -> mnesia:next(Table, Previous)
    end,
    case Key of
        '$end_of_table' -> {undefined, true};
        config ->
            clear_usage_batch(Table, {after_key, Key}, Remaining - 1, Key);
        usage_state ->
            clear_usage_batch(Table, {after_key, Key}, Remaining - 1, Key);
        _ ->
            mnesia:delete(Table, Key, write),
            clear_usage_batch(Table, {after_key, Key}, Remaining - 1, Key)
    end.

seed_usage_repair(Handle) ->
    Table = maps:get(usage_table, Handle),
    Tx = fun() ->
        lists:foreach(
          fun(Kind) ->
              mnesia:write(
                Table, #adk_eval_store_usage{key = Kind}, write)
          end, [sets, jobs, baselines]),
        mnesia:write(
          Table, #adk_eval_store_usage{key = total}, write),
        ok
    end,
    tx_ok(mnesia:transaction(Tx)).

repair_kinds([], _Handle) -> ok;
repair_kinds([Kind | Rest], Handle) ->
    case repair_kind(Kind, Handle, first) of
        ok -> repair_kinds(Rest, Handle);
        {error, _} = Error -> Error
    end.

repair_kind(Kind, Handle, Start) ->
    Table = kind_table(Kind, Handle),
    Batch = maps:get(reconciliation_batch_size, Handle),
    Tx = fun() -> repair_batch(
                      Kind, Table, Handle, Start, Batch, undefined) end,
    case mnesia:transaction(Tx) of
        {atomic, {_Last, true}} -> ok;
        {atomic, {Last, false}} ->
            repair_kind(Kind, Handle, {after_key, Last});
        {aborted, Reason} -> tx_error(Reason)
    end.

repair_batch(_Kind, _Table, _Handle, _Start, 0, Last) ->
    {Last, false};
repair_batch(Kind, Table, Handle, Start, Remaining, _Last) ->
    Key = case Start of
        first -> mnesia:first(Table);
        {after_key, Previous} -> mnesia:next(Table, Previous)
    end,
    case Key of
        '$end_of_table' -> {undefined, true};
        _ ->
            [Row] = mnesia:read(Table, Key, read),
            repair_add_row(Kind, Row, Handle),
            repair_batch(Kind, Table, Handle, {after_key, Key},
                         Remaining - 1, Key)
    end.

repair_add_row(sets, #adk_eval_set_row{scope = Scope} = Row, Handle) ->
    repair_account(sets, Scope, stored_bytes(Row), undefined, Handle);
repair_add_row(jobs,
               #adk_eval_job_row{scope = Scope, job = Job,
                                 charged_bytes = Charge} = Row, Handle) ->
    case Charge >= stored_bytes(Row) of
        true -> ok;
        false -> mnesia:abort(eval_store_job_charge_corrupt)
    end,
    case mnesia:read(maps:get(sets_table, Handle), job_set_key(Job), read) of
        [_] -> ok;
        [] -> mnesia:abort(eval_store_dangling_set_reference)
    end,
    repair_account(jobs, Scope, Charge, set_ref_key(Job), Handle);
repair_add_row(baselines,
               #adk_eval_baseline_row{scope = Scope,
                                      baseline = Baseline} = Row, Handle) ->
    case mnesia:read(maps:get(jobs_table, Handle),
                     {Scope, maps:get(job_id, Baseline)}, read) of
        [#adk_eval_job_row{job = #{phase := completed}}] -> ok;
        _ -> mnesia:abort(eval_store_dangling_job_reference)
    end,
    repair_account(baselines, Scope, stored_bytes(Row),
                   job_ref_key(Baseline), Handle).

repair_account(Kind, Scope, Bytes, Ref, Handle) ->
    ensure_record_size(Handle, Bytes),
    Table = maps:get(usage_table, Handle),
    KindRow = usage_row(Table, Kind),
    Count = KindRow#adk_eval_store_usage.count + 1,
    Limit = maps:get(limit_key(Kind), maps:get(limits, Handle)),
    case Count =< Limit of
        true -> mnesia:write(
                  Table, KindRow#adk_eval_store_usage{count = Count}, write);
        false -> mnesia:abort(eval_store_reconciled_usage_exceeds_limits)
    end,
    repair_adjust_bytes(Handle, Scope, Bytes),
    case Ref of
        undefined -> ok;
        _ -> increment_ref_unchecked(Handle, Ref)
    end.

repair_adjust_bytes(Handle, Scope, Bytes) ->
    Table = maps:get(usage_table, Handle),
    Total0 = usage_row(Table, total),
    ScopeKey = {scope, Scope},
    Scope0 = usage_row(Table, ScopeKey),
    Total = Total0#adk_eval_store_usage.bytes + Bytes,
    ScopeBytes = Scope0#adk_eval_store_usage.bytes + Bytes,
    Limits = maps:get(limits, Handle),
    case Total =< maps:get(max_total_bytes, Limits) andalso
         ScopeBytes =< maps:get(max_scope_bytes, Limits) of
        true ->
            mnesia:write(
              Table, Total0#adk_eval_store_usage{bytes = Total}, write),
            mnesia:write(
              Table, Scope0#adk_eval_store_usage{bytes = ScopeBytes}, write);
        false -> mnesia:abort(eval_store_reconciled_usage_exceeds_limits)
    end.

finish_usage_repair(Handle) ->
    Table = maps:get(usage_table, Handle),
    Tx = fun() ->
        [State] = mnesia:read(Table, usage_state, write),
        mnesia:write(
          Table, State#adk_eval_store_usage{value = ready}, write),
        ok
    end,
    case mnesia:transaction(Tx) of
        {atomic, ok} -> {ok, Handle};
        {aborted, Reason} -> tx_error(Reason)
    end.

kind_table(sets, Handle) -> maps:get(sets_table, Handle);
kind_table(jobs, Handle) -> maps:get(jobs_table, Handle);
kind_table(baselines, Handle) -> maps:get(baselines_table, Handle).

tx_ok({atomic, ok}) -> ok;
tx_ok({aborted, Reason}) -> tx_error(Reason).

reserve(Handle, Kind, Scope, Bytes) ->
    ensure_record_size(Handle, Bytes),
    Table = maps:get(usage_table, Handle),
    Usage = usage_row(Table, Kind),
    Limit = maps:get(limit_key(Kind), maps:get(limits, Handle)),
    case Usage#adk_eval_store_usage.count < Limit of
        true ->
            mnesia:write(
              Table, Usage#adk_eval_store_usage{
                       count = Usage#adk_eval_store_usage.count + 1}, write),
            adjust_bytes(Handle, Scope, Bytes);
        false -> mnesia:abort(capacity_reason(Kind))
    end.

release(Handle, Kind, Scope, Bytes) ->
    Table = maps:get(usage_table, Handle),
    Usage = usage_row(Table, Kind),
    case Usage#adk_eval_store_usage.count > 0 of
        true ->
            mnesia:write(
              Table, Usage#adk_eval_store_usage{
                       count = Usage#adk_eval_store_usage.count - 1}, write),
            adjust_bytes(Handle, Scope, -Bytes);
        false -> mnesia:abort(eval_store_usage_corrupt)
    end.

replace_bytes(Handle, Scope, OldBytes, NewBytes) ->
    ensure_record_size(Handle, NewBytes),
    adjust_bytes(Handle, Scope, NewBytes - OldBytes).

ensure_record_size(Handle, Bytes) ->
    case Bytes =< maps:get(max_record_bytes, maps:get(limits, Handle)) of
        true -> ok;
        false -> mnesia:abort(eval_record_byte_capacity_reached)
    end.

adjust_bytes(Handle, Scope, Delta) ->
    assert_usage_ready(Handle),
    Table = maps:get(usage_table, Handle),
    Total0 = usage_row(Table, total),
    ScopeKey = {scope, Scope},
    Scope0 = usage_row(Table, ScopeKey),
    Total = Total0#adk_eval_store_usage.bytes + Delta,
    ScopeBytes = Scope0#adk_eval_store_usage.bytes + Delta,
    Limits = maps:get(limits, Handle),
    case {Total >= 0, ScopeBytes >= 0,
          Total =< maps:get(max_total_bytes, Limits),
          ScopeBytes =< maps:get(max_scope_bytes, Limits)} of
        {true, true, true, true} ->
            mnesia:write(
              Table, Total0#adk_eval_store_usage{bytes = Total}, write),
            case ScopeBytes of
                0 -> mnesia:delete(Table, ScopeKey, write);
                _ -> mnesia:write(
                       Table,
                       Scope0#adk_eval_store_usage{bytes = ScopeBytes}, write)
            end,
            ok;
        {_, _, false, _} ->
            mnesia:abort(eval_store_total_byte_capacity_reached);
        {_, _, _, false} ->
            mnesia:abort(eval_scope_byte_capacity_reached);
        _ -> mnesia:abort(eval_store_usage_corrupt)
    end.

usage_row(Table, Key) ->
    case mnesia:read(Table, Key, write) of
        [Row] -> Row;
        [] -> #adk_eval_store_usage{key = Key}
    end.

increment_ref(Handle, Key) ->
    assert_usage_ready(Handle),
    increment_ref_unchecked(Handle, Key).

increment_ref_unchecked(Handle, Key) ->
    Table = maps:get(usage_table, Handle),
    Row = usage_row(Table, Key),
    mnesia:write(
      Table, Row#adk_eval_store_usage{
               count = Row#adk_eval_store_usage.count + 1}, write).

decrement_ref(Handle, Key) ->
    assert_usage_ready(Handle),
    Table = maps:get(usage_table, Handle),
    Row = usage_row(Table, Key),
    case Row#adk_eval_store_usage.count of
        Count when Count > 1 ->
            mnesia:write(
              Table, Row#adk_eval_store_usage{count = Count - 1}, write);
        1 -> mnesia:delete(Table, Key, write);
        _ -> mnesia:abort(eval_store_reference_usage_corrupt)
    end.

ref_count(Handle, Key) ->
    assert_usage_ready(Handle),
    Table = maps:get(usage_table, Handle),
    (usage_row(Table, Key))#adk_eval_store_usage.count.

assert_usage_ready(Handle) ->
    Table = maps:get(usage_table, Handle),
    case mnesia:read(Table, usage_state, read) of
        [#adk_eval_store_usage{value = ready}] -> ok;
        _ -> mnesia:abort(eval_store_reconciliation_in_progress)
    end.

set_ref_key(Job) ->
    {set_ref, maps:get(scope, Job), maps:get(eval_set_id, Job),
     maps:get(eval_set_version, Job)}.

job_set_key(Job) ->
    {maps:get(scope, Job), maps:get(eval_set_id, Job),
     maps:get(eval_set_version, Job)}.

job_ref_key(Baseline) ->
    {job_ref, maps:get(scope, Baseline), maps:get(job_id, Baseline)}.

update_baseline_ref(Handle, Old, New) ->
    OldKey = job_ref_key(Old),
    NewKey = job_ref_key(New),
    case OldKey =:= NewKey of
        true -> ok;
        false -> decrement_ref(Handle, OldKey), increment_ref(Handle, NewKey)
    end.

limit_key(sets) -> max_sets;
limit_key(jobs) -> max_jobs;
limit_key(baselines) -> max_baselines.
capacity_reason(sets) -> eval_set_capacity_reached;
capacity_reason(jobs) -> eval_job_capacity_reached;
capacity_reason(baselines) -> eval_baseline_capacity_reached.

%% Validation and projections

prepare_set(Scope, Set0) ->
    case {adk_eval_store:validate_scope(Scope),
          adk_eval_store:prepare_set(Set0)} of
        {ok, {ok, Set, Id, Version, Digest}} ->
            {ok, {Scope, Id, Version}, Set, Id, Version, Digest, now_ms()};
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

public_set(#adk_eval_set_row{scope = Scope, id = Id, version = Version,
                             digest = Digest, created_at = CreatedAt}) ->
    #{scope => Scope, id => Id, version => Version,
      digest => Digest, created_at => CreatedAt}.

valid_set_lookup(Scope, Id, Version) ->
    adk_eval_store:validate_scope(Scope) =:= ok andalso
    adk_eval_store:valid_name(Id) andalso adk_eval_store:valid_name(Version).

prepare_job(Scope, Job0) when is_map(Job0) ->
    JobId = maps:get(job_id, Job0, undefined),
    SetId = maps:get(eval_set_id, Job0, undefined),
    SetVersion = maps:get(eval_set_version, Job0, undefined),
    Metadata0 = maps:get(metadata, Job0, #{}),
    Unknown = maps:keys(maps:without(
                         [job_id, eval_set_id, eval_set_version, metadata], Job0)),
    case {adk_eval_store:validate_scope(Scope),
          adk_eval_store:valid_job_id(JobId),
          adk_eval_store:valid_name(SetId),
          adk_eval_store:valid_name(SetVersion),
          adk_eval_store:prepare_metadata(Metadata0), Unknown} of
        {ok, true, true, true, {ok, Metadata}, []} ->
            Now = now_ms(),
            Job = #{job_id => JobId, scope => Scope,
                    eval_set_id => SetId, eval_set_version => SetVersion,
                    metadata => Metadata, phase => queued, revision => 0,
                    created_at => Now, updated_at => Now,
                    started_at => undefined, finished_at => undefined,
                    reason => undefined},
            {ok, {Scope, JobId}, Job};
        {{error, _} = Error, _, _, _, _, _} -> Error;
        {_, _, _, _, {error, _} = Error, _} -> Error;
        _ -> {error, invalid_eval_job}
    end;
prepare_job(_Scope, _Job) -> {error, invalid_eval_job}.

prepare_evaluation(Scope, Set0, Job0) ->
    case {prepare_set(Scope, Set0), prepare_job(Scope, Job0)} of
        {{ok, SetKey, Set, Id, Version, Digest, Now},
         {ok, JobKey, Job}} ->
            case {maps:get(eval_set_id, Job),
                  maps:get(eval_set_version, Job)} of
                {Id, Version} ->
                    {ok, SetKey, Set, Id, Version, Digest, Now,
                     JobKey, Job};
                _ -> {error, eval_job_set_mismatch}
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

prepare_transition(Scope, JobId, Expected, Phase, Patch0) ->
    case {valid_job_lookup(Scope, JobId), valid_expected(Expected),
          valid_phase(Phase), prepare_patch(Phase, Patch0)} of
        {true, true, true, {ok, Patch}} -> {ok, {Scope, JobId}, Patch};
        {_, _, _, {error, _} = Error} -> Error;
        _ -> {error, invalid_eval_job_transition}
    end.

valid_job_lookup(Scope, JobId) ->
    adk_eval_store:validate_scope(Scope) =:= ok andalso
    adk_eval_store:valid_job_id(JobId).

valid_expected(Expected) when is_list(Expected), Expected =/= [] ->
    lists:all(fun valid_phase/1, Expected) andalso
    length(Expected) =:= length(lists:usort(Expected));
valid_expected(_) -> false.

valid_phase(queued) -> true;
valid_phase(running) -> true;
valid_phase(completed) -> true;
valid_phase(failed) -> true;
valid_phase(timed_out) -> true;
valid_phase(cancelled) -> true;
valid_phase(_) -> false.

legal_transition(queued, running) -> true;
legal_transition(queued, failed) -> true;
legal_transition(queued, cancelled) -> true;
legal_transition(running, completed) -> true;
legal_transition(running, failed) -> true;
legal_transition(running, timed_out) -> true;
legal_transition(running, cancelled) -> true;
legal_transition(_Current, _Next) -> false.

prepare_patch(completed, Patch0) when is_map(Patch0) ->
    case {patch_keys(Patch0, [result, finished_at]),
          maps:find(result, Patch0), maps:find(finished_at, Patch0)} of
        {true, {ok, Result0}, {ok, Finished}}
          when is_integer(Finished), Finished >= 0 ->
            case adk_eval_set:decode_result(Result0) of
                {ok, Result} ->
                    {ok, #{result => Result, finished_at => Finished}};
                {error, _} -> {error, invalid_eval_job_result}
            end;
        _ -> {error, invalid_eval_job_result}
    end;
prepare_patch(running, Patch0) when is_map(Patch0) ->
    Started = maps:get(started_at, Patch0, undefined),
    TaskRef = maps:get(task_ref, Patch0, undefined),
    case patch_keys(Patch0, [task_ref, started_at]) andalso
         is_integer(Started) andalso Started >= 0 andalso
         valid_optional_name(TaskRef) of
        true -> {ok, #{started_at => Started}};
        false -> {error, invalid_eval_job_patch}
    end;
prepare_patch(Phase, Patch0) when is_map(Patch0),
                                  (Phase =:= failed orelse
                                   Phase =:= timed_out orelse
                                   Phase =:= cancelled) ->
    Finished = maps:get(finished_at, Patch0, undefined),
    Reason = maps:get(reason, Patch0, undefined),
    case patch_keys(Patch0, [finished_at, reason]) andalso
         is_integer(Finished) andalso Finished >= 0 andalso
         valid_reason(Reason) andalso Reason =/= undefined of
        true -> {ok, #{finished_at => Finished, reason => Reason}};
        false -> {error, invalid_eval_job_patch}
    end;
prepare_patch(_Phase, _Patch) -> {error, invalid_eval_job_patch}.

patch_keys(Patch, Allowed) ->
    maps:keys(maps:without(Allowed, Patch)) =:= [].

valid_optional_name(undefined) -> true;
valid_optional_name(Value) -> adk_eval_store:valid_name(Value).
valid_reason(undefined) -> true;
valid_reason(Value) -> is_binary(Value) andalso byte_size(Value) > 0 andalso
                       byte_size(Value) =< 4096.

apply_transition(Job0, Phase, Patch) ->
    (maps:remove(task_ref, maps:merge(Job0, Patch)))#{
      phase => Phase,
      revision => maps:get(revision, Job0) + 1,
      updated_at => now_ms()}.

valid_baseline(Scope, Name, JobId) ->
    adk_eval_store:validate_scope(Scope) =:= ok andalso
    adk_eval_store:valid_name(Name) andalso
    adk_eval_store:valid_job_id(JobId).

%% Recovery is intentionally split into bounded transactions.  This keeps a
%% large durable history from holding a table lock for the whole sweep.

recover_batches(Handle, Reason, Start, Total) ->
    Table = maps:get(jobs_table, Handle),
    BatchSize = maps:get(recovery_batch_size, Handle),
    Tx = fun() -> recover_batch(
                      Handle, Table, Reason, Start, BatchSize, 0, undefined)
         end,
    case mnesia:transaction(Tx) of
        {atomic, {Count, _Last, true}} -> {ok, Total + Count};
        {atomic, {Count, Last, false}} ->
            recover_batches(Handle, Reason, {after_key, Last}, Total + Count);
        {aborted, TxReason} -> tx_error(TxReason)
    end.

recover_batch(_Handle, _Table, _Reason, _Start, 0, Count, Last) ->
    {Count, Last, false};
recover_batch(Handle, Table, Reason, Start, Remaining, Count, _Last) ->
    Key = case Start of
        first -> mnesia:first(Table);
        {after_key, Previous} -> mnesia:next(Table, Previous)
    end,
    case Key of
        '$end_of_table' -> {Count, undefined, true};
        _ ->
            [#adk_eval_job_row{scope = Scope, job = Job0} = Row] =
                mnesia:read(Table, Key, write),
            Added = case maps:get(phase, Job0) of
                Phase when Phase =:= queued; Phase =:= running ->
                    Job = apply_transition(
                            Job0, failed,
                            #{reason => Reason, finished_at => now_ms()}),
                    NewRow = transition_job_row(Row, Job),
                    replace_job_charge(Handle, Scope, Row, NewRow),
                    mnesia:write(Table, NewRow, write),
                    1;
                _ -> 0
            end,
            recover_batch(Handle, Table, Reason, {after_key, Key},
                          Remaining - 1, Count + Added, Key)
    end.

%% Listing

list_rows(Kind, Handle, Scope, Options) ->
    case {adk_eval_store:validate_scope(Scope), page_options(Options, Handle)} of
        {ok, {ok, Limit, Cursor}} -> with_handle(Handle, fun(H) ->
            Table = case Kind of
                set -> maps:get(sets_table, H);
                job -> maps:get(jobs_table, H)
            end,
            case decode_page_cursor(Kind, Scope, Cursor) of
                {ok, StartKey} ->
                    Tx = fun() ->
                        collect_ordered_page(
                          Kind, Table, Scope, StartKey, Limit + 1, [])
                    end,
                    case mnesia:transaction(Tx) of
                        {atomic, Items} ->
                            {Page, Next} = take_page(Kind, Items, Limit),
                            {ok, #{scope => Scope, items => Page,
                                   next_cursor => Next}};
                        {aborted, Reason} -> tx_error(Reason)
                    end;
                error -> {error, invalid_eval_store_page_options}
            end
        end);
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

decode_page_cursor(set, Scope, <<>>) -> {ok, {Scope, <<>>, <<>>}};
decode_page_cursor(set, Scope, Cursor) when byte_size(Cursor) =< 1032 ->
    try binary:decode_hex(Cursor) of
        <<IdLen:16/unsigned-big, Id:IdLen/binary,
          VersionLen:16/unsigned-big, Version:VersionLen/binary>> ->
            case adk_eval_store:valid_name(Id) andalso
                 adk_eval_store:valid_name(Version) of
                true -> {ok, {Scope, Id, Version}};
                false -> error
            end;
        _ -> error
    catch _:_ -> error end;
decode_page_cursor(job, Scope, <<>>) -> {ok, {Scope, <<>>}};
decode_page_cursor(job, Scope, Cursor) when byte_size(Cursor) =< 512 ->
    try binary:decode_hex(Cursor) of
        JobId ->
            case adk_eval_store:valid_job_id(JobId) of
                true -> {ok, {Scope, JobId}};
                false -> error
            end
    catch _:_ -> error end;
decode_page_cursor(_Kind, _Scope, _Cursor) -> error.

collect_ordered_page(_Kind, _Table, _Scope, _Key, 0, Acc) ->
    lists:reverse(Acc);
collect_ordered_page(Kind, Table, Scope, Key0, Remaining, Acc) ->
    case mnesia:next(Table, Key0) of
        '$end_of_table' -> lists:reverse(Acc);
        Key when element(1, Key) =:= Scope ->
            [Row] = mnesia:read(Table, Key, read),
            Item = case Kind of
                set -> public_set(Row);
                job -> adk_eval_store:public_job(
                         Row#adk_eval_job_row.job)
            end,
            collect_ordered_page(Kind, Table, Scope, Key,
                                 Remaining - 1, [Item | Acc]);
        _OtherScope -> lists:reverse(Acc)
    end.

page_options(Options, Handle) when is_map(Options) ->
    Max = maps:get(max_page_limit, maps:get(limits, Handle, #{}),
                   ?DEFAULT_MAX_PAGE_LIMIT),
    Unknown = maps:keys(maps:without([limit, cursor], Options)),
    Limit = maps:get(limit, Options, Max),
    Cursor = maps:get(cursor, Options, <<>>),
    case Unknown =:= [] andalso is_integer(Limit) andalso Limit > 0 andalso
         Limit =< Max andalso is_binary(Cursor) of
        true -> {ok, Limit, Cursor};
        false -> {error, invalid_eval_store_page_options}
    end;
page_options(_Options, _Handle) -> {error, invalid_eval_store_page_options}.

row_cursor(set, Row) ->
    Id = maps:get(id, Row),
    Version = maps:get(version, Row),
    binary:encode_hex(
      <<(byte_size(Id)):16/unsigned-big, Id/binary,
        (byte_size(Version)):16/unsigned-big, Version/binary>>,
      lowercase);
row_cursor(job, Row) ->
    binary:encode_hex(maps:get(job_id, Row), lowercase).

take_page(Kind, Items, Limit) ->
    case length(Items) > Limit of
        true ->
            Page = lists:sublist(Items, Limit),
            {Page, row_cursor(Kind, lists:last(Page))};
        false -> {Items, undefined}
    end.

%% Bounded retention. The primary tables are ordered by scope and stable ID,
%% so each call touches at most max_prune_scan rows and never walks unrelated
%% tenants. The returned cursor resumes after the last inspected row.

prune_options(Handle, Scope, Options) when is_map(Options) ->
    Limits = maps:get(limits, Handle, #{}),
    Unknown = maps:keys(maps:without(
                         [before, limit, cursor, include_baselines], Options)),
    Before = maps:get(before, Options, undefined),
    Limit = maps:get(limit, Options,
                     maps:get(max_prune_limit, Limits,
                              ?DEFAULT_MAX_PRUNE_LIMIT)),
    Cursor = maps:get(cursor, Options, <<>>),
    IncludeBaselines = maps:get(include_baselines, Options, false),
    Max = maps:get(max_prune_limit, Limits, ?DEFAULT_MAX_PRUNE_LIMIT),
    Decoded = case is_binary(Cursor) andalso byte_size(Cursor) =< 517 of
        true -> decode_prune_cursor(Cursor);
        false -> error
    end,
    case {adk_eval_store:validate_scope(Scope), Unknown,
          is_integer(Before) andalso Before >= 0,
          is_integer(Limit) andalso Limit > 0 andalso Limit =< Max,
          is_boolean(IncludeBaselines), Decoded} of
        {ok, [], true, true, true, {ok, CursorValue0}} ->
            CursorValue = case {IncludeBaselines, Cursor, CursorValue0} of
                {true, <<>>, _} -> {baseline, <<>>};
                _ -> CursorValue0
            end,
            case not (element(1, CursorValue) =:= baseline andalso
                      not IncludeBaselines) of
                true -> {ok, Before, Limit, CursorValue,
                         IncludeBaselines};
                false -> {error, invalid_eval_prune_options}
            end;
        {ok, [_ | _], _, _, _, _} ->
            {error, {unknown_eval_prune_options, lists:sort(Unknown)}};
        {{error, _} = Error, _, _, _, _, _} -> Error;
        _ -> {error, invalid_eval_prune_options}
    end;
prune_options(_Handle, _Scope, _Options) ->
    {error, invalid_eval_prune_options}.

decode_prune_cursor(<<>>) -> {ok, {job, <<>>}};
decode_prune_cursor(<<$b, Len:16/unsigned-big, Name:Len/binary>>) ->
    case adk_eval_store:valid_name(Name) of
        true -> {ok, {baseline, Name}};
        false -> error
    end;
decode_prune_cursor(<<$j, Len:16/unsigned-big, JobId:Len/binary>>) ->
    case adk_eval_store:valid_job_id(JobId) of
        true -> {ok, {job, JobId}};
        false -> error
    end;
decode_prune_cursor(<<$s, IdLen:16/unsigned-big, Id:IdLen/binary,
                      VersionLen:16/unsigned-big,
                      Version:VersionLen/binary>>) ->
    case adk_eval_store:valid_name(Id) andalso
         adk_eval_store:valid_name(Version) of
        true -> {ok, {set, Id, Version}};
        false -> error
    end;
decode_prune_cursor(_Cursor) -> error.

encode_prune_cursor({job, JobId}) ->
    <<$j, (byte_size(JobId)):16/unsigned-big, JobId/binary>>;
encode_prune_cursor({baseline, Name}) ->
    <<$b, (byte_size(Name)):16/unsigned-big, Name/binary>>;
encode_prune_cursor({set, Id, Version}) ->
    <<$s, (byte_size(Id)):16/unsigned-big, Id/binary,
      (byte_size(Version)):16/unsigned-big, Version/binary>>.

prune_transaction(Handle, Scope, Before, Limit, {baseline, Name}, true) ->
    Budget = maps:get(max_prune_scan, maps:get(limits, Handle)),
    {Baselines, BaseBytes, Scanned1, Remaining, Budget1, LastBase,
     BaselinesDone} = prune_baseline_scan(
                        Handle, Scope, Before, {Scope, Name},
                        Limit, Budget, 0, 0, 0),
    case BaselinesDone andalso Remaining > 0 andalso Budget1 > 0 of
        true ->
            Reply0 = prune_transaction(
                       Handle, Scope, Before, Remaining,
                       {job, <<>>}, true, Budget1),
            Reply0#{baselines_deleted =>
                        maps:get(baselines_deleted, Reply0) + Baselines,
                    bytes_reclaimed =>
                        maps:get(bytes_reclaimed, Reply0) + BaseBytes,
                    scanned => maps:get(scanned, Reply0) + Scanned1};
        false ->
            Cursor = case {BaselinesDone, Remaining} of
                {true, 0} ->
                    {_Scope, LastName} = LastBase,
                    encode_prune_cursor({baseline, LastName});
                _ -> prune_continuation(
                       BaselinesDone, Remaining, Budget1,
                       baseline, LastBase)
            end,
            prune_result(Baselines, 0, 0, BaseBytes, Scanned1, Cursor)
    end;
prune_transaction(Handle, Scope, Before, Limit, Cursor,
                  IncludeBaselines) ->
    Budget = maps:get(max_prune_scan, maps:get(limits, Handle)),
    prune_transaction(Handle, Scope, Before, Limit, Cursor,
                      IncludeBaselines, Budget).

prune_transaction(Handle, Scope, Before, Limit, {job, JobId},
                  _IncludeBaselines, Budget) ->
    {Jobs, JobBytes, Scanned1, Remaining, Budget1, LastJob, JobsDone} =
        prune_job_scan(Handle, Scope, Before, {Scope, JobId},
                       Limit, Budget, 0, 0, 0),
    case JobsDone andalso Remaining > 0 andalso Budget1 > 0 of
        true ->
            {Sets, SetBytes, Scanned2, Remaining2, Budget2, LastSet,
             SetsDone} = prune_set_scan(
                           Handle, Scope, Before, {Scope, <<>>, <<>>},
                           Remaining, Budget1, 0, 0, 0),
            Cursor = prune_continuation(
                       SetsDone, Remaining2, Budget2, set, LastSet),
            prune_result(0, Jobs, Sets, JobBytes + SetBytes,
                         Scanned1 + Scanned2, Cursor);
        false ->
            Cursor = case {JobsDone, Remaining} of
                {true, 0} ->
                    {_Scope, LastJobId} = LastJob,
                    encode_prune_cursor({job, LastJobId});
                _ -> prune_continuation(
                       JobsDone, Remaining, Budget1, job, LastJob)
            end,
            prune_result(0, Jobs, 0, JobBytes, Scanned1, Cursor)
    end;
prune_transaction(Handle, Scope, Before, Limit, {set, Id, Version},
                  _IncludeBaselines, Budget) ->
    {Sets, Bytes, Scanned, Remaining, Budget1, Last, Done} =
        prune_set_scan(Handle, Scope, Before, {Scope, Id, Version},
                       Limit, Budget, 0, 0, 0),
    Cursor = prune_continuation(Done, Remaining, Budget1, set, Last),
    prune_result(0, 0, Sets, Bytes, Scanned, Cursor).

prune_continuation(true, _Remaining, _Budget, _Kind, _Last) -> undefined;
prune_continuation(false, _Remaining, _Budget, job,
                   {_Scope, JobId}) ->
    encode_prune_cursor({job, JobId});
prune_continuation(false, _Remaining, _Budget, baseline,
                   {_Scope, Name}) ->
    encode_prune_cursor({baseline, Name});
prune_continuation(false, _Remaining, _Budget, set,
                   {_Scope, Id, Version}) ->
    encode_prune_cursor({set, Id, Version}).

prune_result(Baselines, Jobs, Sets, Bytes, Scanned, Cursor) ->
    #{baselines_deleted => Baselines, jobs_deleted => Jobs,
      set_revisions_deleted => Sets,
      bytes_reclaimed => Bytes, scanned => Scanned,
      next_cursor => Cursor, has_more => Cursor =/= undefined}.

prune_baseline_scan(_Handle, _Scope, _Before, Last, 0, Budget,
                    Count, Bytes, Scanned) ->
    {Count, Bytes, Scanned, 0, Budget, Last, false};
prune_baseline_scan(_Handle, _Scope, _Before, Last, Remaining, 0,
                    Count, Bytes, Scanned) ->
    {Count, Bytes, Scanned, Remaining, 0, Last, false};
prune_baseline_scan(Handle, Scope, Before, Last, Remaining, Budget,
                    Count, Bytes, Scanned) ->
    Table = maps:get(baselines_table, Handle),
    case mnesia:next(Table, Last) of
        '$end_of_table' ->
            {Count, Bytes, Scanned, Remaining, Budget, Last, true};
        {Scope, _Name} = Key ->
            [#adk_eval_baseline_row{baseline = Baseline} = Row] =
                mnesia:read(Table, Key, write),
            case maps:get(updated_at, Baseline) =< Before of
                true ->
                    Size = stored_bytes(Row),
                    mnesia:delete(Table, Key, write),
                    release(Handle, baselines, Scope, Size),
                    decrement_ref(Handle, job_ref_key(Baseline)),
                    prune_baseline_scan(
                      Handle, Scope, Before, Key, Remaining - 1, Budget - 1,
                      Count + 1, Bytes + Size, Scanned + 1);
                false ->
                    prune_baseline_scan(
                      Handle, Scope, Before, Key, Remaining, Budget - 1,
                      Count, Bytes, Scanned + 1)
            end;
        _OtherScope ->
            {Count, Bytes, Scanned, Remaining, Budget, Last, true}
    end.

prune_job_scan(_Handle, _Scope, _Before, Last, 0, Budget,
               Count, Bytes, Scanned) ->
    {Count, Bytes, Scanned, 0, Budget, Last, false};
prune_job_scan(_Handle, _Scope, _Before, Last, Remaining, 0,
               Count, Bytes, Scanned) ->
    {Count, Bytes, Scanned, Remaining, 0, Last, false};
prune_job_scan(Handle, Scope, Before, Last, Remaining, Budget,
               Count, Bytes, Scanned) ->
    Table = maps:get(jobs_table, Handle),
    case mnesia:next(Table, Last) of
        '$end_of_table' ->
            {Count, Bytes, Scanned, Remaining, Budget, Last, true};
        Key when element(1, Key) =:= Scope ->
            [#adk_eval_job_row{job = Job} = Row] =
                mnesia:read(Table, Key, write),
            Eligible = adk_eval_store:terminal_phase(maps:get(phase, Job))
                       andalso maps:get(updated_at, Job) =< Before
                       andalso ref_count(Handle, job_ref_key(Job)) =:= 0,
            case Eligible of
                true ->
                    Size = Row#adk_eval_job_row.charged_bytes,
                    mnesia:delete(Table, Key, write),
                    release(Handle, jobs, Scope, Size),
                    decrement_ref(Handle, set_ref_key(Job)),
                    prune_job_scan(
                      Handle, Scope, Before, Key, Remaining - 1, Budget - 1,
                      Count + 1, Bytes + Size, Scanned + 1);
                false ->
                    prune_job_scan(
                      Handle, Scope, Before, Key, Remaining, Budget - 1,
                      Count, Bytes, Scanned + 1)
            end;
        _OtherScope ->
            {Count, Bytes, Scanned, Remaining, Budget, Last, true}
    end.

prune_set_scan(_Handle, _Scope, _Before, Last, 0, Budget,
               Count, Bytes, Scanned) ->
    {Count, Bytes, Scanned, 0, Budget, Last, false};
prune_set_scan(_Handle, _Scope, _Before, Last, Remaining, 0,
               Count, Bytes, Scanned) ->
    {Count, Bytes, Scanned, Remaining, 0, Last, false};
prune_set_scan(Handle, Scope, Before, Last, Remaining, Budget,
               Count, Bytes, Scanned) ->
    Table = maps:get(sets_table, Handle),
    case mnesia:next(Table, Last) of
        '$end_of_table' ->
            {Count, Bytes, Scanned, Remaining, Budget, Last, true};
        {Scope, Id, Version} = Key ->
            [#adk_eval_set_row{created_at = CreatedAt} = Row] =
                mnesia:read(Table, Key, write),
            RefKey = {set_ref, Scope, Id, Version},
            Eligible = CreatedAt =< Before andalso
                       ref_count(Handle, RefKey) =:= 0,
            case Eligible of
                true ->
                    Size = stored_bytes(Row),
                    mnesia:delete(Table, Key, write),
                    release(Handle, sets, Scope, Size),
                    prune_set_scan(
                      Handle, Scope, Before, Key, Remaining - 1, Budget - 1,
                      Count + 1, Bytes + Size, Scanned + 1);
                false ->
                    prune_set_scan(
                      Handle, Scope, Before, Key, Remaining, Budget - 1,
                      Count, Bytes, Scanned + 1)
            end;
        _OtherScope ->
            {Count, Bytes, Scanned, Remaining, Budget, Last, true}
    end.

with_handle(#{sets_table := Sets, jobs_table := Jobs,
              baselines_table := Baselines, usage_table := Usage} = Handle,
            Fun)
  when is_atom(Sets), is_atom(Jobs), is_atom(Baselines), is_atom(Usage),
       is_function(Fun, 1) ->
    case validate_handle_config(Handle) of
        ok -> Fun(Handle);
        {error, _} = Error -> Error
    end;
with_handle(_Handle, _Fun) -> {error, invalid_eval_store_handle}.

validate_handle_config(Handle) when is_map(Handle) ->
    Computed = config_digest(Handle),
    case maps:get(config_digest, Handle, undefined) of
        Computed ->
            Table = maps:get(usage_table, Handle, undefined),
            case is_atom(Table) andalso
                 read_table_property(
                   Table, adk_eval_store_config_digest) =:=
                     {adk_eval_store_config_digest, Computed} of
                true -> ok;
                false -> {error, invalid_eval_store_handle}
            end;
        _ -> {error, invalid_eval_store_handle}
    end.

tx_value({atomic, Value}) -> {ok, Value};
tx_value({aborted, Reason}) -> tx_error(Reason).

tx_error(Reason) when Reason =:= already_exists;
                            Reason =:= eval_set_revision_conflict;
                            Reason =:= eval_set_not_found;
                            Reason =:= eval_set_capacity_reached;
                            Reason =:= eval_job_capacity_reached;
                            Reason =:= eval_baseline_capacity_reached;
                            Reason =:= eval_record_byte_capacity_reached;
                            Reason =:= eval_store_total_byte_capacity_reached;
                            Reason =:= eval_scope_byte_capacity_reached;
                            Reason =:= eval_store_reconciled_usage_exceeds_limits;
                            Reason =:= eval_store_usage_corrupt;
                            Reason =:= eval_store_reference_usage_corrupt;
                            Reason =:= eval_store_config_mismatch;
                            Reason =:= eval_store_dangling_set_reference;
                            Reason =:= eval_store_dangling_job_reference;
                            Reason =:= job_not_completed;
                            Reason =:= not_found;
                            Reason =:= invalid_eval_job_transition;
                            Reason =:= stale_phase -> {error, Reason};
tx_error(Reason) -> {error, {eval_store_transaction_aborted, Reason}}.

now_ms() -> erlang:system_time(millisecond).

stored_bytes(Value) -> erlang:external_size(Value).

new_job_row(Key, Scope, Job) ->
    Row0 = #adk_eval_job_row{key = Key, scope = Scope,
                             job_id = maps:get(job_id, Job), job = Job},
    Charge = stored_bytes(Row0) + ?JOB_TERMINAL_HEADROOM_BYTES,
    Row0#adk_eval_job_row{charged_bytes = Charge}.

transition_job_row(Row0, Job) ->
    case adk_eval_store:terminal_phase(maps:get(phase, Job)) of
        false -> Row0#adk_eval_job_row{job = Job};
        true ->
            Candidate0 = Row0#adk_eval_job_row{job = Job,
                                                charged_bytes = 0},
            Charge0 = stored_bytes(Candidate0),
            Candidate1 = Candidate0#adk_eval_job_row{
                           charged_bytes = Charge0},
            Charge = max(Charge0, stored_bytes(Candidate1)),
            Candidate0#adk_eval_job_row{charged_bytes = Charge}
    end.

replace_job_charge(Handle, Scope, OldRow, NewRow) ->
    OldCharge = OldRow#adk_eval_job_row.charged_bytes,
    NewCharge = NewRow#adk_eval_job_row.charged_bytes,
    ensure_record_size(Handle, stored_bytes(NewRow)),
    ensure_record_size(Handle, NewCharge),
    adjust_bytes(Handle, Scope, NewCharge - OldCharge).
