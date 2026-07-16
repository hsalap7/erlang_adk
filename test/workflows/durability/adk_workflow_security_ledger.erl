-module(adk_workflow_security_ledger).
-behaviour(adk_invocation_ledger).

-export([init/1, create/4, get/2, claim/6, renew/5,
         checkpoint/6, finish/7, delete/2]).

init(Opts) when is_map(Opts) ->
    {ok, Opts};
init(_Opts) ->
    {error, invalid_options}.

create(Handle, InvocationId, Metadata, Checkpoint) ->
    Table = maps:get(table, Handle),
    Record = Metadata#{invocation_id => InvocationId,
                       checkpoint => Checkpoint,
                       phase => ready,
                       outcome => undefined,
                       owned => false,
                       owner_node => undefined,
                       lease_until => 0,
                       revision => 0,
                       created_at => 1,
                       updated_at => 1},
    true = ets:insert_new(Table, {InvocationId, Record}),
    ok.

get(Handle, InvocationId) ->
    case ets:lookup(maps:get(table, Handle), InvocationId) of
        [{InvocationId, Record}] -> {ok, Record};
        [] -> {error, not_found}
    end.

claim(Handle, InvocationId, _Owner, _Token, Now, LeaseMs) ->
    case get(Handle, InvocationId) of
        {ok, Record} ->
            Claimed = Record#{phase => running,
                              owned => true,
                              owner_node => node(),
                              lease_until => Now + LeaseMs,
                              revision => maps:get(revision, Record) + 1,
                              updated_at => Now},
            true = ets:insert(maps:get(table, Handle),
                              {InvocationId, Claimed}),
            {ok, Claimed};
        {error, _} = Error -> Error
    end.

renew(Handle, _InvocationId, _Token, _Now, _LeaseMs) ->
    maybe_fail(renew, Handle).

checkpoint(Handle, InvocationId, _Token, Checkpoint, Now, LeaseMs) ->
    case maybe_fail(checkpoint, Handle) of
        ok ->
            {ok, Record} = get(Handle, InvocationId),
            Updated = Record#{checkpoint => Checkpoint,
                              lease_until => Now + LeaseMs,
                              revision => maps:get(revision, Record) + 1,
                              updated_at => Now},
            true = ets:insert(maps:get(table, Handle),
                              {InvocationId, Updated}),
            ok;
        {error, _} = Error -> Error
    end.

finish(Handle, InvocationId, _Token, Phase, Outcome, Checkpoint, Now) ->
    case maybe_fail(finish, Handle) of
        ok ->
            {ok, Record} = get(Handle, InvocationId),
            Updated = Record#{phase => Phase,
                              outcome => Outcome,
                              checkpoint => Checkpoint,
                              owned => false,
                              owner_node => undefined,
                              lease_until => 0,
                              revision => maps:get(revision, Record) + 1,
                              updated_at => Now},
            true = ets:insert(maps:get(table, Handle),
                              {InvocationId, Updated}),
            ok;
        {error, _} = Error -> Error
    end.

delete(Handle, InvocationId) ->
    true = ets:delete(maps:get(table, Handle), InvocationId),
    ok.

maybe_fail(Operation, #{mode := Operation, seed := Seed}) ->
    {error, {ledger_failure, Operation,
             #{body => Seed, authorization => Seed}}};
maybe_fail(_Operation, _Handle) ->
    ok.
