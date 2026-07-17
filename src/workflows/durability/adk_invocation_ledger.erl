%% @doc Durable ownership and checkpoint ledger for resumable invocations.
%%
%% Implementations must make create/claim/checkpoint/finish atomic.  The
%% opaque owner token and lease are both write fences: renew/checkpoint/finish
%% validate the token, running phase, and explicit NowMs atomically.  A token
%% is expired when NowMs >= lease_until and cannot revive itself before a new
%% claimant arrives.  After takeover, writes from the previous coordinator
%% fail with `stale_owner'.
-module(adk_invocation_ledger).

-callback init(Options :: map()) ->
    {ok, Handle :: term()} | {error, term()}.

-callback create(Handle :: term(), InvocationId :: binary(),
                 Metadata :: map(), Checkpoint :: map()) ->
    ok | {error, already_exists | term()}.

-callback get(Handle :: term(), InvocationId :: binary()) ->
    {ok, Invocation :: map()} | {error, not_found | term()}.

-callback claim(Handle :: term(), InvocationId :: binary(),
                OwnerPid :: pid(), OwnerToken :: binary(),
                NowMs :: integer(), LeaseMs :: pos_integer()) ->
    {ok, Invocation :: map()}
    | {error, not_found | completed | invocation_owned | term()}.

-callback renew(Handle :: term(), InvocationId :: binary(),
                OwnerToken :: binary(), NowMs :: integer(),
                LeaseMs :: pos_integer()) ->
    ok | {error, stale_owner | lease_expired | not_found | term()}.

-callback checkpoint(Handle :: term(), InvocationId :: binary(),
                     OwnerToken :: binary(), Checkpoint :: map(),
                     NowMs :: integer(), LeaseMs :: pos_integer()) ->
    ok | {error, stale_owner | lease_expired | not_found | term()}.

-callback finish(Handle :: term(), InvocationId :: binary(),
                 OwnerToken :: binary(), Phase :: atom(), Outcome :: term(),
                 Checkpoint :: map(), NowMs :: integer()) ->
    ok | {error, stale_owner | lease_expired | not_found | term()}.

-callback delete(Handle :: term(), InvocationId :: binary()) ->
    ok | {error, invocation_owned | not_found | term()}.
