%% @doc Mnesia-backed durable invocation ledger.
%%
%% The table uses disc_copies on the local node by default.  A deployment may
%% replicate the table with normal Mnesia administration.  Lease time is the
%% authoritative write fence on every node: an owner may mutate a running
%% invocation only while Now &lt; lease_until.  Local process liveness is used
%% only as an early-release optimization, so a dead local owner can be replaced
%% before expiry; a live local pid never extends an expired lease.
-module(adk_invocation_ledger_mnesia).
-behaviour(adk_invocation_ledger).

-export([init/1, create/4, get/2, claim/6, renew/5,
         checkpoint/6, finish/7, delete/2]).

-define(DEFAULT_TABLE, adk_durable_invocation).
-define(TABLE_WAIT_MS, 5000).

-record(adk_durable_invocation, {
    id,
    format = 1,
    workflow_id,
    workflow_version,
    kind,
    checkpoint,
    phase = ready,
    outcome = undefined,
    owner_token = undefined,
    owner_pid = undefined,
    owner_node = undefined,
    lease_until = 0,
    revision = 0,
    created_at,
    updated_at
}).

%% @doc Ensure Mnesia and the durable ledger table are available.
%% `table' is primarily useful for isolated applications/tests; it must be an
%% existing atom and always uses the record schema above.
init(Opts) when is_map(Opts) ->
    Table = maps:get(table, Opts, ?DEFAULT_TABLE),
    case is_atom(Table) of
        false -> {error, {invalid_table, Table}};
        true ->
            case application:ensure_all_started(mnesia) of
                {ok, _} -> ensure_table(Table);
                {error, Reason} -> {error, {mnesia_start_failed, Reason}}
            end
    end;
init(Opts) ->
    {error, {invalid_options, Opts}}.

create(Handle, InvocationId, Metadata, Checkpoint)
  when is_binary(InvocationId), byte_size(InvocationId) > 0,
       is_map(Metadata), is_map(Checkpoint) ->
    with_table(
      Handle,
      fun(Table) ->
          Now = erlang:system_time(millisecond),
          Tx = fun() ->
              case mnesia:read(Table, InvocationId, write) of
                  [] ->
                      Record = #adk_durable_invocation{
                          id = InvocationId,
                          workflow_id = maps:get(workflow_id, Metadata),
                          workflow_version = maps:get(workflow_version,
                                                      Metadata),
                          kind = maps:get(kind, Metadata),
                          checkpoint = Checkpoint,
                          created_at = Now,
                          updated_at = Now},
                      mnesia:write(Table, Record, write),
                      ok;
                  [_] ->
                      mnesia:abort(already_exists)
              end
          end,
          tx_result(mnesia:transaction(Tx))
      end);
create(_Handle, _InvocationId, _Metadata, _Checkpoint) ->
    {error, invalid_create_arguments}.

get(Handle, InvocationId) when is_binary(InvocationId) ->
    with_table(
      Handle,
      fun(Table) ->
          Tx = fun() -> mnesia:read(Table, InvocationId, read) end,
          case mnesia:transaction(Tx) of
              {atomic, [Record]} -> {ok, public_record(Record)};
              {atomic, []} -> {error, not_found};
              {aborted, Reason} -> {error, {transaction_aborted, Reason}}
          end
      end);
get(_Handle, _InvocationId) ->
    {error, invalid_invocation_id}.

claim(Handle, InvocationId, OwnerPid, OwnerToken, Now, LeaseMs)
  when is_binary(InvocationId), is_pid(OwnerPid),
       is_binary(OwnerToken), byte_size(OwnerToken) > 0,
       is_integer(Now), is_integer(LeaseMs), LeaseMs > 0 ->
    with_table(
      Handle,
      fun(Table) ->
          Tx = fun() ->
              case mnesia:read(Table, InvocationId, write) of
                  [] -> mnesia:abort(not_found);
                  [#adk_durable_invocation{phase = completed}] ->
                      mnesia:abort(completed);
                  [Record] ->
                      case claimable(Record, Now) of
                          false -> mnesia:abort(invocation_owned);
                          true ->
                              Claimed = Record#adk_durable_invocation{
                                  phase = running,
                                  outcome = undefined,
                                  owner_token = OwnerToken,
                                  owner_pid = OwnerPid,
                                  owner_node = node(OwnerPid),
                                  lease_until = Now + LeaseMs,
                                  revision = Record#adk_durable_invocation.revision + 1,
                                  updated_at = Now},
                              mnesia:write(Table, Claimed, write),
                              public_record(Claimed)
                      end
              end
          end,
          case mnesia:transaction(Tx) of
              {atomic, Invocation} -> {ok, Invocation};
              {aborted, Reason} when Reason =:= not_found;
                                      Reason =:= completed;
                                      Reason =:= invocation_owned ->
                  {error, Reason};
              {aborted, Reason} -> {error, {transaction_aborted, Reason}}
          end
      end);
claim(_Handle, _InvocationId, _OwnerPid, _OwnerToken, _Now, _LeaseMs) ->
    {error, invalid_claim_arguments}.

renew(Handle, InvocationId, OwnerToken, Now, LeaseMs)
  when is_binary(InvocationId), is_binary(OwnerToken),
       is_integer(Now), is_integer(LeaseMs), LeaseMs > 0 ->
    update_owned(
      Handle, InvocationId, OwnerToken, Now,
      fun(Record) ->
          Record#adk_durable_invocation{
              lease_until = Now + LeaseMs,
              revision = Record#adk_durable_invocation.revision + 1,
              updated_at = Now}
      end);
renew(_Handle, _InvocationId, _OwnerToken, _Now, _LeaseMs) ->
    {error, invalid_renew_arguments}.

checkpoint(Handle, InvocationId, OwnerToken, Checkpoint, Now, LeaseMs)
  when is_binary(InvocationId), is_binary(OwnerToken), is_map(Checkpoint),
       is_integer(Now), is_integer(LeaseMs), LeaseMs > 0 ->
    update_owned(
      Handle, InvocationId, OwnerToken, Now,
      fun(Record) ->
          Record#adk_durable_invocation{
              checkpoint = Checkpoint,
              phase = running,
              outcome = undefined,
              lease_until = Now + LeaseMs,
              revision = Record#adk_durable_invocation.revision + 1,
              updated_at = Now}
      end);
checkpoint(_Handle, _InvocationId, _OwnerToken, _Checkpoint,
           _Now, _LeaseMs) ->
    {error, invalid_checkpoint_arguments}.

finish(Handle, InvocationId, OwnerToken, Phase, Outcome, Checkpoint, Now)
  when is_binary(InvocationId), is_binary(OwnerToken), is_atom(Phase),
       is_map(Checkpoint), is_integer(Now) ->
    case lists:member(Phase,
                      [completed, failed, timed_out, cancelled, paused]) of
        false -> {error, {invalid_terminal_phase, Phase}};
        true ->
            SafeOutcome = persisted_outcome(Phase, Outcome, Checkpoint),
            update_owned(
              Handle, InvocationId, OwnerToken, Now,
              fun(Record) ->
                  Record#adk_durable_invocation{
                      checkpoint = Checkpoint,
                      phase = Phase,
                      outcome = SafeOutcome,
                      owner_token = undefined,
                      owner_pid = undefined,
                      owner_node = undefined,
                      lease_until = 0,
                      revision = Record#adk_durable_invocation.revision + 1,
                      updated_at = Now}
              end)
    end;
finish(_Handle, _InvocationId, _OwnerToken, _Phase, _Outcome,
       _Checkpoint, _Now) ->
    {error, invalid_finish_arguments}.

delete(Handle, InvocationId) when is_binary(InvocationId) ->
    with_table(
      Handle,
      fun(Table) ->
          Tx = fun() ->
              case mnesia:read(Table, InvocationId, write) of
                  [] -> mnesia:abort(not_found);
                  [Record] ->
                      case actively_owned(Record) of
                          true -> mnesia:abort(invocation_owned);
                          false ->
                              mnesia:delete({Table, InvocationId}),
                              ok
                      end
              end
          end,
          tx_result(mnesia:transaction(Tx))
      end);
delete(_Handle, _InvocationId) ->
    {error, invalid_invocation_id}.

ensure_table(Table) ->
    case ensure_disk_schema() of
        ok ->
            Options = [
                {attributes, record_info(fields, adk_durable_invocation)},
                {record_name, adk_durable_invocation},
                {disc_copies, [node()]},
                %% Once operators add replicas, majority transactions prevent
                %% both sides of a network partition from claiming ownership.
                {majority, true}
            ],
            case mnesia:create_table(Table, Options) of
                {atomic, ok} -> wait_for_table(Table);
                {aborted, {already_exists, Table}} -> wait_for_table(Table);
                {aborted, Reason} ->
                    {error, {table_creation_failed, Table, Reason}}
            end;
        {error, _} = Error -> Error
    end.

ensure_disk_schema() ->
    case mnesia:change_table_copy_type(schema, node(), disc_copies) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, schema, Node, disc_copies}}
          when Node =:= node() -> ok;
        {aborted, Reason} ->
            {error, {schema_configuration_failed, Reason}}
    end.

wait_for_table(Table) ->
    case mnesia:wait_for_tables([Table], ?TABLE_WAIT_MS) of
        ok -> {ok, #{table => Table}};
        {timeout, Tables} -> {error, {table_wait_timeout, Tables}};
        {error, Reason} -> {error, {table_wait_failed, Reason}}
    end.

with_table(#{table := Table}, Fun) when is_atom(Table), is_function(Fun, 1) ->
    Fun(Table);
with_table(Handle, _Fun) ->
    {error, {invalid_ledger_handle, Handle}}.

update_owned(Handle, InvocationId, OwnerToken, Now, UpdateFun) ->
    with_table(
      Handle,
      fun(Table) ->
          Tx = fun() ->
              case mnesia:read(Table, InvocationId, write) of
                  [] -> mnesia:abort(not_found);
                  [#adk_durable_invocation{
                       phase = running,
                       owner_token = OwnerToken,
                       lease_until = LeaseUntil} = Record]
                    when Now < LeaseUntil ->
                      Updated = UpdateFun(Record),
                      mnesia:write(Table, Updated, write),
                      ok;
                  [#adk_durable_invocation{
                       phase = running,
                       owner_token = OwnerToken}] ->
                      %% Expiry is a fence in its own right.  The old token
                      %% cannot revive itself merely because no successor has
                      %% committed a claim yet.
                      mnesia:abort(lease_expired);
                  [_] -> mnesia:abort(stale_owner)
              end
          end,
          tx_result(mnesia:transaction(Tx))
      end).

tx_result({atomic, Result}) -> Result;
tx_result({aborted, Reason})
  when Reason =:= already_exists;
       Reason =:= invocation_owned;
       Reason =:= lease_expired;
       Reason =:= not_found;
       Reason =:= stale_owner ->
    {error, Reason};
tx_result({aborted, Reason}) ->
    {error, {transaction_aborted, Reason}}.

claimable(#adk_durable_invocation{owner_token = undefined}, _Now) -> true;
claimable(#adk_durable_invocation{phase = running,
                                  owner_pid = OwnerPid,
                                  owner_node = OwnerNode,
                                  lease_until = LeaseUntil}, Now) ->
    Now >= LeaseUntil orelse local_owner_dead(OwnerPid, OwnerNode);
claimable(_Record, _Now) ->
    false.

local_owner_dead(OwnerPid, OwnerNode) ->
    OwnerNode =:= node()
    andalso is_pid(OwnerPid)
    andalso not erlang:is_process_alive(OwnerPid).

%% The workflow layer already normalizes its own terminal values.  Repeat the
%% failure/cancellation projection at the persistence boundary so a direct
%% ledger caller cannot put an arbitrary exception or cancellation payload on
%% disk.  Successful and pause payloads retain their public contract.
persisted_outcome(Phase, Outcome, Checkpoint)
  when Phase =:= failed; Phase =:= cancelled ->
    adk_workflow:terminal_outcome(Phase, Outcome, Checkpoint);
persisted_outcome(_Phase, Outcome, _Checkpoint) ->
    Outcome.

actively_owned(#adk_durable_invocation{owner_token = undefined}) -> false;
actively_owned(Record) ->
    not claimable(Record, erlang:system_time(millisecond)).

public_record(#adk_durable_invocation{
                 id = Id, workflow_id = WorkflowId,
                 workflow_version = WorkflowVersion, kind = Kind,
                 checkpoint = Checkpoint, phase = Phase,
                 outcome = Outcome, owner_token = OwnerToken,
                 owner_node = OwnerNode, lease_until = LeaseUntil,
                 revision = Revision, created_at = CreatedAt,
                 updated_at = UpdatedAt}) ->
    #{invocation_id => Id,
      workflow_id => WorkflowId,
      workflow_version => WorkflowVersion,
      kind => Kind,
      checkpoint => Checkpoint,
      phase => Phase,
      outcome => Outcome,
      owned => OwnerToken =/= undefined,
      owner_node => OwnerNode,
      lease_until => LeaseUntil,
      revision => Revision,
      created_at => CreatedAt,
      updated_at => UpdatedAt}.
