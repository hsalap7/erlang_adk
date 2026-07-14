# Graph workflows

`adk_workflow` graph specifications describe a finite, application-owned set
of nodes. Compilation rejects unknown entries, transitions, duplicate IDs,
unbounded graph loops, and malformed fork topologies before a coordinator is
started. Runtime route values may select a compiled node ID or `end_node`; they
cannot introduce Erlang source, an MFA, a tool module, or another node.

## Node types

- An `action` node is the backwards-compatible `#{id => Id, run => Action}`.
- An `agent` node declares `agent`, `prompt`, and optional `decide`. Its name is
  resolved through `adk_agent_registry` at dispatch time.
- A `tool` node declares an application-owned `module`, JSON-safe `args` (or a
  trusted resolver), and optional `result_key`. The module must implement
  `execute(Args, Context)`.
- A `workflow` node embeds an already compiled child workflow. The parent
  deadline is inherited, and a guardian cancels the child when the parent
  action process exits. A child that itself pauses currently fails the parent
  with `nested_workflow_paused`; pause the parent graph before entering that
  child when the decision must be resumed through the parent checkpoint.
- A `branch` or `dynamic` node declares a trusted `choose` callback and a
  non-empty `targets` allowlist. Returning another target fails the workflow.
- A `loop` node declares `while`, `body`, `done`, and `max_iterations`. The
  iteration count is stored in the public checkpoint.
- A `fork` node declares ordered `branches`, one `join`, an explicit `merge`
  policy, and `max_concurrency`. Each branch is a predeclared action-like node
  whose edge must point directly to that join.
- A `join` node is a no-op barrier by default and may optionally have `run`.

Action-like and join nodes require explicit entries in the graph `edges` map.
Branch, dynamic, loop, and fork transitions live in their typed node
descriptors, so they do not have edge entries.

## Fork and checkpoint semantics

Fork workers receive the same immutable input state. Results are recorded in
the fork cursor as each branch completes, while the visible state remains
unchanged. After every branch has committed, deltas are merged in declaration
order and the cursor advances to the join. `reject_conflicts` and
`ordered_last_wins` have the same behavior as top-level parallel workflows; a
trusted `{custom, Fun}` merger is also supported.

If cancellation or a coordinator restart occurs after one branch result was
committed, resume skips that branch. An action killed before its result reaches
the checkpoint boundary can run again; this is the normal at-least-once rule
for in-flight effects. Side-effecting actions should therefore use an
application idempotency key. The action context includes `workflow_id`,
`step_id`, `checkpoint_cursor`, and, for durable workflows, `invocation_id`.

Ordinary graph nodes use a two-phase checkpoint: their state delta is committed
with a `routing` cursor before a route callback runs. A blocked or failed route
can therefore be resumed without repeating the node action.

## Pause and resume

A graph action can return:

```erlang
{pause, Reason, Summary, StateDelta}
```

or throw the compatible `{adk_pause, Reason, Summary}` term. The runtime first
commits the delta and an `awaiting_resume` cursor, then returns
`{paused, Details, Checkpoint}`. Resume requires JSON-safe input:

```erlang
{ok, Ref} = adk_workflow:resume(
    Compiled, Checkpoint, #{resume_input => Decision}).
```

The original node is skipped. Its ordinary edge is evaluated with `Decision`
in `maps:get(input, Context)`, and the selected target is still checked against
the compiled graph. Durable invocations apply the same validation before and
after claiming their ledger lease.

When a fork branch pauses, its delta is checkpointed and sibling workers are
stopped. Resume treats that branch as committed and continues the remaining
branches. The resume value is not injected into the branch delta; applications
that need a decision to alter state should pause before the fork or route the
decision through a normal graph node.

## Safety bounds

`max_steps`, `max_iterations`, `max_concurrency`, and the workflow absolute
deadline are independent bounds. Cancellation and deadline expiry kill active
fork/action workers. Nested workflows inherit the absolute deadline and retain
their own compiled step, transfer, and concurrency limits.
