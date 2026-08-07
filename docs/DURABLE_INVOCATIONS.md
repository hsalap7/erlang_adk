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

The ledger persists the workflow identity, definition-bound JSON-safe
checkpoint, terminal outcome, record revision, and ownership lease. It
deliberately does not persist compiled Erlang funs or agent pids. The
application must therefore load code and reconstruct the same compiled
workflow before resuming. A mismatched ID/version/kind is rejected as
`checkpoint_workflow_mismatch`; a v2 checkpoint built from different compiled
semantics is rejected as `checkpoint_definition_mismatch`.

## Checkpoint schema v2 and definition identity

New checkpoints use schema version 2. Alongside state, cursor, remaining
budgets, output, and completion, they carry:

- the compiled `definition_fingerprint` and stable `execution_id`;
- monotonically increasing `sequence`, `parent_sequence`, and `created_at`;
- durable per-node attempt entries and node status;
- currently runnable and waiting work;
- fork/join accumulators and cycle counters; and
- interruption records needed to restore a typed pause.

The fingerprint covers the compiled workflow kind and canonical definition.
An optional root `definition_revision` may be a non-negative integer or
non-empty binary. When it is present, callback identity omits VM-local fun
identity/captures, making the definition suitable for an application-managed
cross-deployment resume contract. The application must bump that revision
when callback meaning changes. Without a revision, a workflow containing
anonymous callbacks is marked non-portable and should be resumed only against
the exact compatible build.

Valid schema-v1 checkpoints remain readable for the 0.8-to-0.9 upgrade. They
are checked against workflow ID/version/kind and rewritten as v2 at the next
checkpoint boundary. Once rewritten, resume is definition-bound and reverting
that invocation to a 0.8 runtime is unsupported.

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

Retry attempt state is durable in v2. If recovery finds an attempt marked
running but without a committed result, it reruns that same one-based attempt
number. It does not grant a new retry budget. This makes configured
`max_attempts` stable across restarts, but it does not make an in-flight action
exactly once.

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

When a nested child pauses inside sequential, parallel, loop, transfer, graph,
or graph-fork execution, the parent commits the child's checkpoint and
propagates the pause. Resume re-enters that child without replaying its already
committed work. A sibling cancelled before its own result commits may run
again, so sibling effects need the same idempotency treatment.

A protected workflow tool node produces structured `tool_confirmation`
details with a stable action ID. Resume accepts only a correlated boolean
decision: approval re-evaluates the confirmation requirement and executes that
exact call, while rejection and malformed or mismatched input fail closed.

## Lifecycle delivery

Set `lifecycle_receiver => Pid` in workflow options to receive:

```erlang
{adk_workflow_lifecycle, WorkflowRef, EventMap}
```

Events are JSON-safe schema-v1 maps with a per-execution sequence, timestamp,
workflow/invocation identity, type, and type-specific metadata. They cover
workflow start/terminal, node start/completion/failure, routing, fork/join,
attempt/retry, checkpoint commit, and pause/resume. The receiver is separate
from `event_receiver` for compatibility.

Lifecycle messages are operational observations, not a durable transaction
log. A receiver process can die or miss messages, and a recovered execution
starts a new lifecycle sequence. Use committed checkpoints and the invocation
ledger—not lifecycle delivery—as the recovery source of truth.

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

Typed workflow tool/HITL pauses are stored in the workflow checkpoint and may
be resumed through the workflow invocation API. Paused Runner agent
invocations continue to use `adk_run:resume/2` and the separate session
continuation store. The two continuation formats are not interchangeable.
