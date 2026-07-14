# Durable workflow invocations

`adk_workflow:start/3` remains the lightweight, process-addressed API. Use
`start_invocation/3` when a workflow must survive loss of its coordinator or
an application/BEAM restart. It returns both a stable binary invocation ID and
the current supervised coordinator pid:

```erlang
{ok, LedgerHandle} = adk_invocation_ledger_mnesia:init(#{}),
DurableOpts = #{
    ledger => {adk_invocation_ledger_mnesia, LedgerHandle},
    lease_ms => 30000,
    timeout => 120000
},

{ok, Compiled} = erlang_adk:compile_workflow(WorkflowSpec),
{ok, InvocationId, WorkflowPid} =
    erlang_adk:start_workflow_invocation(
      Compiled, #{<<"request_id">> => RequestId}, DurableOpts),

%% WorkflowPid is intentionally ephemeral. Persist InvocationId instead.
case erlang_adk:await_workflow(WorkflowPid, 120000) of
    {completed, State, _Checkpoint} -> {ok, State};
    {failed, Reason, _Checkpoint} -> {error, Reason}
end.
```

An application can supply its own stable `invocation_id` in `DurableOpts`.
This makes upstream create requests idempotent: a duplicate ID is rejected
instead of starting a second invocation.

After an interruption, compile the same workflow ID/version/kind and claim its
latest checkpoint by ID:

```erlang
{ok, DurableStatus} =
    erlang_adk:workflow_invocation_status(InvocationId, DurableOpts),

{ok, NewWorkflowPid} =
    erlang_adk:resume_workflow_invocation(
      InvocationId, Compiled, DurableOpts),
Result = erlang_adk:await_workflow(NewWorkflowPid, 120000).
```

For a graph paused by an action/HITL request, include the JSON-safe response as
`resume_input` in the resume options. The runtime validates it once before
allocating a coordinator and again against the newest checkpoint after the
atomic ownership claim:

```erlang
{ok, NewWorkflowPid} =
    erlang_adk:resume_workflow_invocation(
      InvocationId, Compiled,
      DurableOpts#{resume_input => #{<<"approved">> => true}}).
```

The ledger persists the workflow identity, JSON-safe checkpoint, terminal
outcome, revision, and ownership lease. It deliberately does not persist
compiled Erlang funs or agent pids. The application must therefore load code
and reconstruct the same compiled workflow before resuming. A mismatched
workflow is rejected.

## Commit and ownership semantics

The workflow engine waits for an acknowledgement at every checkpoint. For a
durable invocation, the coordinator writes the state, cursor, and remaining
budgets in one Mnesia transaction before sending that acknowledgement. The
next action cannot start before that transaction commits.

Only one coordinator may own an invocation:

- a dead owner on the local node can be replaced immediately;
- any owner can be replaced when its lease expires, including a still-live
  owner process on the local node;
- the active coordinator renews its lease while an action is running; and
- each owner gets a random fencing token. A delayed write from an old owner is
  rejected after takeover.

The lease boundary is exact: an owner may renew, checkpoint, or finish only
when the operation's explicit wall-clock time is strictly less than the stored
`lease_until`; equality is already expired. An expired token cannot renew or
commit merely because no replacement has claimed the record yet. Local PID
liveness is therefore only an early-release optimization for a dead process,
not an implicit lease extension for a live one. Token, `running` phase, and
lease validity are checked together in the same write transaction.

A `completed` invocation is immutable. A `paused`, `failed`, `timed_out`,
`cancelled`, or unexpectedly interrupted invocation may be explicitly resumed
from its last committed checkpoint. `delete_workflow_invocation/2` removes an
unowned record when the application's retention policy permits it.

## Delivery guarantee and idempotency

Execution is **at least once** across a crash. A completed, acknowledged step
is not run again. An action whose external side effect happened after the last
checkpoint but whose result was not durably committed may run again.

Durable action callbacks receive these extra context fields:

```erlang
#{
    invocation_id => InvocationId,
    step_id => StepId,
    checkpoint_cursor => Cursor
}
```

Use the stable invocation ID plus step ID/cursor as an idempotency key when an
action calls a payment system, queue, database, or other side-effecting
service. The target service should atomically remember that key with its
result. Parallel branches have the same at-least-once rule independently.

## Mnesia operation

`adk_invocation_ledger_mnesia:init/1` creates a local `disc_copies` table with
Mnesia's `majority` property enabled. Set the Mnesia directory before startup
and back it up like other application state. Multi-node deployments should add
table replicas with normal Mnesia administration and choose a lease duration
longer than expected transaction and network jitter. Keep node clocks
synchronized because remote takeover compares the stored wall-clock lease.

The adapter stores checkpoint data as Erlang terms on disk; it does not add
encryption at rest. Do not put credentials or provider tokens in workflow
state. Deployments requiring encrypted storage can implement the
`adk_invocation_ledger` behaviour with their database/KMS policy while
retaining the same atomic claim, checkpoint, finish, and fencing contract.

Durable workflow recovery is separate from an intentional tool/HITL pause.
Paused Runner invocations continue to use `adk_run:resume/2` and the session
continuation store. This ledger is specifically for unexpected process or
application interruption at workflow checkpoint boundaries.
