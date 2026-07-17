%% Deterministic ledger double for public workflow boundary tests.
-module(adk_workflow_contract_ledger).
-behaviour(adk_invocation_ledger).

-export([init/1, create/4, get/2, claim/6, renew/5,
         checkpoint/6, finish/7, delete/2]).

init(Options) when is_map(Options) ->
    {ok, Options}.

create(Handle, _InvocationId, _Metadata, _Checkpoint) ->
    dispatch(create, Handle, ok).

get(Handle, _InvocationId) ->
    dispatch(get, Handle, {error, not_found}).

claim(Handle, _InvocationId, _OwnerPid, _OwnerToken, _NowMs, _LeaseMs) ->
    dispatch(claim, Handle, {error, invocation_owned}).

renew(Handle, _InvocationId, _OwnerToken, _NowMs, _LeaseMs) ->
    dispatch(renew, Handle, ok).

checkpoint(Handle, _InvocationId, _OwnerToken, _Checkpoint,
           _NowMs, _LeaseMs) ->
    dispatch(checkpoint, Handle, ok).

finish(Handle, _InvocationId, _OwnerToken, _Phase, _Outcome,
       _Checkpoint, _NowMs) ->
    dispatch(finish, Handle, ok).

delete(Handle, _InvocationId) ->
    dispatch(delete, Handle, ok).

dispatch(Operation, Handle, Default) ->
    case maps:get(Operation, Handle, Default) of
        {raise, Reason} -> erlang:error(Reason);
        Reply -> Reply
    end.
