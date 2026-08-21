%% @doc Durable write-ahead journal for external artifact effects.
%%
%% The journal stores intent and opaque resource identifiers, never artifact
%% bytes or credentials. Reconciliation claims are lease-fenced and terminal
%% history has bounded retention/pruning.
-module(adk_artifact_effect_journal).

-export([default_config/0, validate_config/1, init/1, is_handle/1,
         table_names/1, record_intent/2,
         effect_applied/4, commit/4, status/3, list_unresolved/3,
         claim_orphan/4, resolve/5, retry/5, prune_terminal/3]).

-record(adk_artifact_effect, {
    id,
    scope,
    operation,
    resource_id,
    request_digest,
    metadata = #{},
    phase = prepared,
    attempt = 0,
    max_attempts = 5,
    next_attempt_at = 0,
    owner_token = undefined,
    lease_until = 0,
    receipt = undefined,
    last_error = undefined,
    revision = 0,
    created_at,
    updated_at,
    finished_at = undefined
}).

default_config() ->
    #{table => adk_artifact_effect,
      max_records => 100000,
      max_active => 10000,
      max_metadata_bytes => 16384,
      max_receipt_bytes => 16384,
      max_list_limit => 1000,
      max_attempts => 20,
      default_max_attempts => 5,
      orphan_grace_ms => 300000,
      retry_base_ms => 1000,
      max_retry_ms => 300000,
      terminal_retention_ms => 604800000,
      table_wait_ms => 5000}.

-spec validate_config(term()) -> ok | {error, term()}.
validate_config(Config) when is_map(Config) ->
    case compile_config(Config) of
        {ok, _Handle} -> ok;
        {error, _} = Error -> Error
    end;
validate_config(_) -> {error, invalid_artifact_journal_config}.

init(Config) when is_map(Config) ->
    case compile_config(Config) of
        {ok, Handle} ->
            case application:ensure_all_started(mnesia) of
                {ok, _} -> ensure_table(Handle);
                {error, _} -> {error, artifact_journal_unavailable}
            end;
        {error, _} = Error -> Error
    end;
init(_) -> {error, invalid_artifact_journal_config}.

%% Journal handles are deliberately opaque to callers. Recompile the
%% normalized configuration so a forged or partial map cannot cross a Runner
%% or context-capability boundary and fail later, after an external mutation.
-spec is_handle(term()) -> boolean().
is_handle(#{table := Table, limits := Limits} = Handle)
  when is_atom(Table), is_map(Limits) ->
    case compile_config(Limits#{table => Table}) of
        {ok, Handle} -> true;
        _ -> false
    end;
is_handle(_) -> false.

table_names(#{table := Table}) -> [Table];
table_names(_) -> [].

record_intent(Handle, Spec) when is_map(Spec) ->
    with_handle(Handle, fun(Table, Limits) ->
        case prepare_intent(Spec, Limits) of
            {ok, Prepared} -> insert_intent(Table, Limits, Prepared);
            {error, _} = Error -> Error
        end
    end);
record_intent(_, _) -> {error, invalid_artifact_effect_intent}.

effect_applied(Handle, Scope, EffectId, Receipt0) when is_binary(EffectId) ->
    with_handle(Handle, fun(Table, Limits) ->
        case safe_map(Receipt0, maps:get(max_receipt_bytes, Limits)) of
            {ok, Receipt} ->
                mark_effect_applied(Table, Scope, EffectId, Receipt);
            {error, _} -> {error, invalid_artifact_effect_receipt}
        end
    end);
effect_applied(_, _, _, _) -> {error, invalid_artifact_effect_id}.

commit(Handle, Scope, EffectId, Receipt0) when is_binary(EffectId) ->
    with_handle(Handle, fun(Table, Limits) ->
        case safe_map(Receipt0, maps:get(max_receipt_bytes, Limits)) of
            {ok, Receipt} ->
                commit_effect(Table, Scope, EffectId, Receipt);
            {error, _} -> {error, invalid_artifact_effect_receipt}
        end
    end);
commit(_, _, _, _) -> {error, invalid_artifact_effect_id}.

status(Handle, Scope, EffectId) when is_binary(EffectId) ->
    with_handle(Handle, fun(Table, _Limits) ->
        case adk_artifact_core:validate_scope(Scope) of
            ok ->
                case mnesia:transaction(
                       fun() -> mnesia:read(Table, EffectId, read) end) of
                    {atomic, [#adk_artifact_effect{scope = Scope} = Record]} ->
                        {ok, public_status(Record)};
                    {atomic, [_]} -> {error, not_found};
                    {atomic, []} -> {error, not_found};
                    {aborted, _} -> {error, artifact_journal_unavailable}
                end;
            {error, _} -> {error, invalid_scope}
        end
    end);
status(_, _, _) -> {error, invalid_artifact_effect_id}.

list_unresolved(Handle, Scope, Limit) when is_integer(Limit), Limit > 0 ->
    with_handle(Handle, fun(Table, Limits) ->
        case {adk_artifact_core:validate_scope(Scope),
              Limit =< maps:get(max_list_limit, Limits)} of
            {_, false} -> {error, artifact_journal_list_limit_exceeded};
            {ok, true} ->
                Tx = fun() ->
                    Items0 = mnesia:foldl(fun(Record, Acc) ->
                        case Record#adk_artifact_effect.scope =:= Scope
                             andalso not terminal(
                                       Record#adk_artifact_effect.phase) of
                            true -> [public_status(Record) | Acc];
                            false -> Acc
                        end
                    end, [], Table),
                    lists:sublist(lists:sort(fun status_before/2, Items0),
                                  Limit)
                end,
                tx_result(mnesia:transaction(Tx));
            {{error, _}, _} -> {error, invalid_scope}
        end
    end);
list_unresolved(_, _, _) -> {error, invalid_artifact_journal_list_limit}.

claim_orphan(Handle, OwnerToken, Now, LeaseMs)
  when is_binary(OwnerToken), byte_size(OwnerToken) > 0,
       byte_size(OwnerToken) =< 256, is_integer(Now),
       is_integer(LeaseMs), LeaseMs > 0, LeaseMs =< 3600000 ->
    with_handle(Handle, fun(Table, _Limits) ->
        Tx = fun() -> claim_tx(Table, OwnerToken, Now, LeaseMs) end,
        case mnesia:transaction(Tx) of
            {atomic, none} -> none;
            {atomic, {ok, Work}} -> {ok, Work};
            {aborted, _} -> {error, artifact_journal_unavailable}
        end
    end);
claim_orphan(_, _, _, _) -> {error, invalid_artifact_journal_claim}.

resolve(Handle, EffectId, OwnerToken, Outcome, Now)
  when is_binary(EffectId), is_binary(OwnerToken), is_integer(Now) ->
    case lists:member(Outcome, [committed, compensated, not_applied]) of
        false -> {error, invalid_artifact_reconcile_outcome};
        true -> with_handle(Handle, fun(Table, _Limits) ->
            Tx = fun() ->
                case read_owned(Table, EffectId, OwnerToken, Now) of
                    {ok, Record} ->
                        FinalPhase = case Outcome of
                            committed -> committed;
                            _ -> compensated
                        end,
                        Updated = terminal_record(
                                    Record, FinalPhase, undefined, Now),
                        mnesia:write(Table, Updated, write),
                        public_status(Updated);
                    {error, Reason} -> mnesia:abort(Reason)
                end
            end,
            tx_status(mnesia:transaction(Tx))
        end)
    end;
resolve(_, _, _, _, _) -> {error, invalid_artifact_reconcile_request}.

retry(Handle, EffectId, OwnerToken, Reason0, Now)
  when is_binary(EffectId), is_binary(OwnerToken), is_integer(Now) ->
    SafeReason = adk_memory_outbox_payload:safe_reason(Reason0),
    with_handle(Handle, fun(Table, Limits) ->
        Tx = fun() ->
            case read_owned(Table, EffectId, OwnerToken, Now) of
                {ok, Record} ->
                    Updated = retry_record(Record, SafeReason, Now, Limits),
                    mnesia:write(Table, Updated, write),
                    public_status(Updated);
                {error, Reason} -> mnesia:abort(Reason)
            end
        end,
        tx_status(mnesia:transaction(Tx))
    end);
retry(_, _, _, _, _) -> {error, invalid_artifact_reconcile_request}.

prune_terminal(Handle, Now, Limit)
  when is_integer(Now), is_integer(Limit), Limit > 0 ->
    with_handle(Handle, fun(Table, Limits) ->
        Max = maps:get(max_list_limit, Limits),
        case Limit =< Max of
            false -> {error, artifact_journal_prune_limit_exceeded};
            true ->
                Cutoff = Now - maps:get(terminal_retention_ms, Limits),
                Tx = fun() ->
                    Candidates0 = mnesia:foldl(fun(Record, Acc) ->
                        Finished = Record#adk_artifact_effect.finished_at,
                        case terminal(Record#adk_artifact_effect.phase)
                             andalso is_integer(Finished)
                             andalso Finished =< Cutoff of
                            true -> [{Finished,
                                      Record#adk_artifact_effect.id} | Acc];
                            false -> Acc
                        end
                    end, [], Table),
                    Candidates = lists:sublist(lists:sort(Candidates0), Limit),
                    lists:foreach(fun({_Time, Id}) ->
                        mnesia:delete(Table, Id, write)
                    end, Candidates),
                    #{deleted => length(Candidates), cutoff => Cutoff}
                end,
                tx_result(mnesia:transaction(Tx))
        end
    end);
prune_terminal(_, _, _) -> {error, invalid_artifact_journal_prune_request}.

compile_config(Config) ->
    Defaults = default_config(),
    Unknown = lists:sort(maps:keys(maps:without(maps:keys(Defaults), Config))),
    Full = maps:merge(Defaults, Config),
    Table = maps:get(table, Full),
    Numbers = [{max_records, 10000000}, {max_active, 1000000},
               {max_metadata_bytes, 262144}, {max_receipt_bytes, 262144},
               {max_list_limit, 100000}, {max_attempts, 100},
               {default_max_attempts, 100},
               {orphan_grace_ms, 86400000}, {retry_base_ms, 3600000},
               {max_retry_ms, 86400000},
               {terminal_retention_ms, 315360000000},
               {table_wait_ms, 60000}],
    ValidNumbers = lists:all(fun({Key, Max}) ->
        Value = maps:get(Key, Full),
        is_integer(Value) andalso Value >= 0 andalso Value =< Max andalso
            (not lists:member(Key, [max_records, max_active,
                                    max_metadata_bytes, max_receipt_bytes,
                                    max_list_limit, max_attempts,
                                    default_max_attempts, retry_base_ms,
                                    max_retry_ms, table_wait_ms])
             orelse Value > 0)
    end, Numbers),
    Relations = maps:get(max_active, Full) =< maps:get(max_records, Full)
        andalso maps:get(default_max_attempts, Full) =<
                    maps:get(max_attempts, Full)
        andalso maps:get(retry_base_ms, Full) =<
                    maps:get(max_retry_ms, Full),
    case {Unknown, is_atom(Table), ValidNumbers, Relations} of
        {[], true, true, true} ->
            {ok, #{table => Table, limits => maps:remove(table, Full)}};
        {[_ | _], _, _, _} ->
            {error, {invalid_artifact_journal_config,
                     {unknown_keys, Unknown}}};
        _ -> {error, invalid_artifact_journal_config}
    end.

ensure_table(#{table := Table, limits := Limits} = Handle) ->
    case mnesia:change_table_copy_type(schema, node(), disc_copies) of
        {atomic, ok} -> create_table(Table, Limits, Handle);
        {aborted, {already_exists, schema, Node, disc_copies}}
          when Node =:= node() -> create_table(Table, Limits, Handle);
        {aborted, _} -> {error, artifact_journal_unavailable}
    end.

create_table(Table, Limits, Handle) ->
    Attrs = record_info(fields, adk_artifact_effect),
    Options = [{attributes, Attrs}, {record_name, adk_artifact_effect},
               {disc_copies, [node()]}, {type, set}, {majority, true}],
    case mnesia:create_table(Table, Options) of
        {atomic, ok} -> wait_verify(Table, Limits, Handle);
        {aborted, {already_exists, Table}} ->
            wait_verify(Table, Limits, Handle);
        {aborted, _} -> {error, artifact_journal_unavailable}
    end.

wait_verify(Table, Limits, Handle) ->
    case mnesia:wait_for_tables([Table], maps:get(table_wait_ms, Limits)) of
        ok ->
            ExpectedFields = record_info(fields, adk_artifact_effect),
            Actual = try {mnesia:table_info(Table, record_name),
                          mnesia:table_info(Table, attributes),
                          mnesia:table_info(Table, storage_type),
                          mnesia:table_info(Table, majority)}
                     catch exit:_ -> invalid end,
            case Actual of
                {adk_artifact_effect, ExpectedFields, disc_copies, true} ->
                    {ok, Handle};
                _ -> {error, artifact_journal_schema_mismatch}
            end;
        _ -> {error, artifact_journal_unavailable}
    end.

prepare_intent(Spec, Limits) ->
    Allowed = [scope, operation, resource_id, request_digest,
               metadata, idempotency_key, max_attempts],
    Unknown = lists:sort(maps:keys(maps:without(Allowed, Spec))),
    Scope = maps:get(scope, Spec, undefined),
    Op = maps:get(operation, Spec, undefined),
    Resource = maps:get(resource_id, Spec, undefined),
    Digest = maps:get(request_digest, Spec, undefined),
    Idempotency = maps:get(idempotency_key, Spec, undefined),
    Attempts = maps:get(max_attempts, Spec,
                        maps:get(default_max_attempts, Limits)),
    case {Unknown, adk_artifact_core:validate_scope(Scope), valid_op(Op),
          bounded_binary(Resource, 2048), bounded_binary(Digest, 256),
          bounded_binary(Idempotency, 512),
          safe_map(maps:get(metadata, Spec, #{}),
                   maps:get(max_metadata_bytes, Limits)),
          is_integer(Attempts) andalso Attempts > 0 andalso
              Attempts =< maps:get(max_attempts, Limits)} of
        {[], ok, true, true, true, true, {ok, Metadata}, true} ->
            Identity = {Scope, Op, Resource, Digest, Idempotency},
            Id = <<"arteffect-", (short_hash(Identity))/binary>>,
            {ok, #{id => Id, scope => Scope, operation => Op,
                   resource_id => Resource, request_digest => Digest,
                   metadata => Metadata, max_attempts => Attempts}};
        {[_ | _], _, _, _, _, _, _, _} ->
            {error, {invalid_artifact_effect_intent,
                     {unknown_keys, Unknown}}};
        _ -> {error, invalid_artifact_effect_intent}
    end.

insert_intent(Table, Limits, Prepared) ->
    Now = erlang:system_time(millisecond),
    Record = #adk_artifact_effect{
      id = maps:get(id, Prepared), scope = maps:get(scope, Prepared),
      operation = maps:get(operation, Prepared),
      resource_id = maps:get(resource_id, Prepared),
      request_digest = maps:get(request_digest, Prepared),
      metadata = maps:get(metadata, Prepared),
      max_attempts = maps:get(max_attempts, Prepared),
      next_attempt_at = Now + maps:get(orphan_grace_ms, Limits),
      created_at = Now, updated_at = Now},
    Tx = fun() ->
        case mnesia:read(Table, Record#adk_artifact_effect.id, write) of
            [] ->
                ensure_capacity(Table, Limits),
                mnesia:write(Table, Record, write),
                {new, public_status(Record)};
            [Existing] ->
                case same_intent(Existing, Record) of
                    true -> {duplicate, public_status(Existing)};
                    false -> mnesia:abort(effect_id_conflict)
                end
        end
    end,
    case mnesia:transaction(Tx) of
        {atomic, {new, Status}} -> {ok, Status#{deduplicated => false}};
        {atomic, {duplicate, Status}} ->
            {ok, Status#{deduplicated => true}};
        {aborted, effect_id_conflict} -> {error, effect_id_conflict};
        {aborted, artifact_journal_capacity_exceeded} ->
            {error, artifact_journal_capacity_exceeded};
        {aborted, _} -> {error, artifact_journal_unavailable}
    end.

ensure_capacity(Table, Limits) ->
    {Total, Active} = mnesia:foldl(fun(Record, {T, A}) ->
        IsActive = not terminal(Record#adk_artifact_effect.phase),
        {T + 1, A + case IsActive of true -> 1; false -> 0 end}
    end, {0, 0}, Table),
    case Total < maps:get(max_records, Limits) andalso
         Active < maps:get(max_active, Limits) of
        true -> ok;
        false -> mnesia:abort(artifact_journal_capacity_exceeded)
    end.

%% Both foreground transitions are idempotent. This matters when a context
%% contains several artifact effects: a later commit can fail after an earlier
%% journal row committed, and retrying the context receipt must remain safe.
mark_effect_applied(Table, Scope, Id, Receipt) ->
    Now = erlang:system_time(millisecond),
    Tx = fun() ->
        case read_foreground(Table, Scope, Id) of
            {ok, #adk_artifact_effect{phase = applied,
                                      receipt = Receipt} = Record} ->
                public_status(Record);
            {ok, #adk_artifact_effect{phase = prepared} = Record} ->
                Updated = Record#adk_artifact_effect{
                  phase = applied, receipt = Receipt,
                  next_attempt_at = Now,
                  revision = Record#adk_artifact_effect.revision + 1,
                  updated_at = Now},
                mnesia:write(Table, Updated, write),
                public_status(Updated);
            {ok, #adk_artifact_effect{phase = applied}} ->
                mnesia:abort(receipt_conflict);
            {ok, #adk_artifact_effect{phase = Phase}}
              when Phase =:= committed; Phase =:= compensated;
                   Phase =:= abandoned ->
                mnesia:abort(already_terminal);
            {ok, _Record} ->
                mnesia:abort(invalid_effect_phase);
            {error, Reason} ->
                mnesia:abort(Reason)
        end
    end,
    tx_status(mnesia:transaction(Tx)).

commit_effect(Table, Scope, Id, Receipt) ->
    Now = erlang:system_time(millisecond),
    Tx = fun() ->
        case read_foreground(Table, Scope, Id) of
            {ok, #adk_artifact_effect{phase = committed,
                                      receipt = Receipt} = Record} ->
                public_status(Record);
            {ok, #adk_artifact_effect{phase = committed}} ->
                mnesia:abort(receipt_conflict);
            {ok, #adk_artifact_effect{phase = applied} = Record} ->
                Updated = terminal_record(
                            Record#adk_artifact_effect{receipt = Receipt},
                            committed, undefined, Now),
                mnesia:write(Table, Updated, write),
                public_status(Updated);
            {ok, #adk_artifact_effect{phase = prepared}} ->
                mnesia:abort(effect_not_applied);
            {ok, #adk_artifact_effect{phase = Phase}}
              when Phase =:= compensated; Phase =:= abandoned ->
                mnesia:abort(already_terminal);
            {ok, _Record} ->
                mnesia:abort(invalid_effect_phase);
            {error, Reason} ->
                mnesia:abort(Reason)
        end
    end,
    tx_status(mnesia:transaction(Tx)).

read_foreground(Table, Scope, Id) ->
    case mnesia:read(Table, Id, write) of
        [] -> {error, not_found};
        [#adk_artifact_effect{scope = Seen}] when Seen =/= Scope ->
            {error, not_found};
        [#adk_artifact_effect{owner_token = Owner}]
          when Owner =/= undefined ->
            {error, effect_reconciliation_active};
        [Record] -> {ok, Record}
    end.

claim_tx(Table, Owner, Now, LeaseMs) ->
    mnesia:write_lock_table(Table),
    case choose_due(Table, Now) of
        none -> none;
        Record ->
            Claimed = Record#adk_artifact_effect{
              phase = reconciling,
              attempt = Record#adk_artifact_effect.attempt + 1,
              owner_token = Owner, lease_until = Now + LeaseMs,
              revision = Record#adk_artifact_effect.revision + 1,
              updated_at = Now},
            mnesia:write(Table, Claimed, write),
            {ok, work_item(Claimed)}
    end.

choose_due(Table, Now) ->
    case mnesia:foldl(fun(Record, Best) ->
        case due_key(Record, Now) of
            none -> Best;
            Key when Best =:= none -> {Key, Record};
            Key -> case Best of
                {BestKey, _} when Key < BestKey -> {Key, Record};
                _ -> Best
            end
        end
    end, none, Table) of
        none -> none;
        {_Key, Record} -> Record
    end.

due_key(#adk_artifact_effect{phase = Phase, next_attempt_at = Due,
                             attempt = Attempt, max_attempts = Max,
                             id = Id}, Now)
  when (Phase =:= prepared orelse Phase =:= applied orelse
        Phase =:= retry_wait), Due =< Now, Attempt < Max -> {Due, Id};
due_key(#adk_artifact_effect{phase = reconciling, lease_until = Lease,
                             attempt = Attempt, max_attempts = Max,
                             id = Id}, Now)
  when Lease =< Now, Attempt < Max -> {Lease, Id};
due_key(_, _) -> none.

read_owned(Table, Id, Owner, Now) ->
    case mnesia:read(Table, Id, write) of
        [] -> {error, not_found};
        [#adk_artifact_effect{phase = reconciling,
                              owner_token = Owner,
                              lease_until = Lease} = Record]
          when Now < Lease -> {ok, Record};
        [#adk_artifact_effect{phase = reconciling,
                              owner_token = Owner}] -> {error, lease_expired};
        [_] -> {error, stale_owner}
    end.

retry_record(Record, Reason, Now, Limits) ->
    case Record#adk_artifact_effect.attempt >=
         Record#adk_artifact_effect.max_attempts of
        true -> terminal_record(Record, abandoned, Reason, Now);
        false ->
            Shift = erlang:min(Record#adk_artifact_effect.attempt - 1, 20),
            Delay = erlang:min(maps:get(max_retry_ms, Limits),
                               maps:get(retry_base_ms, Limits) bsl Shift),
            Record#adk_artifact_effect{
              phase = retry_wait, owner_token = undefined, lease_until = 0,
              next_attempt_at = Now + Delay, last_error = Reason,
              revision = Record#adk_artifact_effect.revision + 1,
              updated_at = Now}
    end.

terminal_record(Record, Phase, Error, Now) ->
    Record#adk_artifact_effect{
      phase = Phase, owner_token = undefined, lease_until = 0,
      next_attempt_at = 0, last_error = Error,
      revision = Record#adk_artifact_effect.revision + 1,
      updated_at = Now, finished_at = Now}.

work_item(Record) ->
    #{effect_id => Record#adk_artifact_effect.id,
      scope => Record#adk_artifact_effect.scope,
      operation => Record#adk_artifact_effect.operation,
      resource_id => Record#adk_artifact_effect.resource_id,
      request_digest => Record#adk_artifact_effect.request_digest,
      metadata => Record#adk_artifact_effect.metadata,
      receipt => Record#adk_artifact_effect.receipt,
      attempt => Record#adk_artifact_effect.attempt,
      lease_until => Record#adk_artifact_effect.lease_until}.

public_status(Record) ->
    Base = #{effect_id => Record#adk_artifact_effect.id,
             scope => Record#adk_artifact_effect.scope,
             operation => Record#adk_artifact_effect.operation,
             resource_digest => short_hash(
                                  Record#adk_artifact_effect.resource_id),
             phase => Record#adk_artifact_effect.phase,
             attempt => Record#adk_artifact_effect.attempt,
             max_attempts => Record#adk_artifact_effect.max_attempts,
             revision => Record#adk_artifact_effect.revision,
             created_at => Record#adk_artifact_effect.created_at,
             updated_at => Record#adk_artifact_effect.updated_at},
    WithError = case Record#adk_artifact_effect.last_error of
        undefined -> Base;
        Error -> Base#{last_error => Error}
    end,
    case Record#adk_artifact_effect.finished_at of
        undefined -> WithError;
        Finished -> WithError#{finished_at => Finished}
    end.

same_intent(A, B) ->
    A#adk_artifact_effect.scope =:= B#adk_artifact_effect.scope andalso
    A#adk_artifact_effect.operation =:= B#adk_artifact_effect.operation andalso
    A#adk_artifact_effect.resource_id =:=
        B#adk_artifact_effect.resource_id andalso
    A#adk_artifact_effect.request_digest =:=
        B#adk_artifact_effect.request_digest.

status_before(A, B) ->
    {maps:get(created_at, A), maps:get(effect_id, A)} =<
    {maps:get(created_at, B), maps:get(effect_id, B)}.

valid_op(put) -> true;
valid_op(delete) -> true;
valid_op(copy) -> true;
valid_op(_) -> false.

terminal(committed) -> true;
terminal(compensated) -> true;
terminal(abandoned) -> true;
terminal(_) -> false.

safe_map(Map, Max) when is_map(Map) ->
    case adk_json:normalize(adk_secret_redactor:redact(Map)) of
        {ok, Safe} when is_map(Safe) ->
            case byte_size(jsx:encode(Safe)) =< Max of
                true -> {ok, Safe};
                false -> {error, size_limit_exceeded}
            end;
        _ -> {error, invalid_map}
    end;
safe_map(_, _) -> {error, invalid_map}.

bounded_binary(Value, Max) when is_binary(Value) ->
    Size = byte_size(Value),
    Size > 0 andalso Size =< Max andalso
        unicode:characters_to_binary(Value, utf8, utf8) =:= Value andalso
        binary:match(Value, <<0>>) =:= nomatch;
bounded_binary(_, _) -> false.

short_hash(Term) ->
    <<Prefix:20/binary, _/binary>> = crypto:hash(
      sha256, term_to_binary(Term, [deterministic])),
    hex(Prefix).

hex(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 15))>>
       || <<Byte>> <= Binary >>.
hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.

tx_result({atomic, Result}) -> {ok, Result};
tx_result({aborted, _}) -> {error, artifact_journal_unavailable}.

tx_status({atomic, Status}) -> {ok, Status};
tx_status({aborted, Reason})
  when Reason =:= not_found; Reason =:= already_terminal;
       Reason =:= effect_reconciliation_active; Reason =:= stale_owner;
       Reason =:= lease_expired; Reason =:= receipt_conflict;
       Reason =:= effect_not_applied; Reason =:= invalid_effect_phase ->
    {error, Reason};
tx_status({aborted, _}) -> {error, artifact_journal_unavailable}.

with_handle(#{table := Table, limits := Limits}, Fun)
  when is_atom(Table), is_map(Limits), is_function(Fun, 2) ->
    Fun(Table, Limits);
with_handle(_, _) -> {error, invalid_artifact_journal_handle}.
