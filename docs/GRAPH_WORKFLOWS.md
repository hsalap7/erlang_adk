# Graph workflows

`adk_workflow` graph specifications describe a finite, application-owned set
of nodes. Compilation rejects unknown entries, transitions, duplicate IDs,
unbounded graph loops, malformed fork topologies, invalid action policies, and
invalid root schemas before a coordinator is started. Runtime route values may
select a compiled node ID or `end_node`; they cannot introduce Erlang source,
an MFA, a tool module, or another node.

## Node types

- An `action` node is the backwards-compatible `#{id => Id, run => Action}`.
- An `agent` node declares `agent`, `prompt`, and optional `decide`. Its name is
  resolved through `adk_agent_registry` at dispatch time and invoked through
  `adk_agent:invoke/3`, not the stateful direct-prompt compatibility path. The
  workflow supplies an exact app/user/session lane, and separate workflow
  executions receive separate execution session IDs. The resolved process must
  report the compiled canonical name through `adk_agent:get_runtime/1`; a
  registry alias mismatch fails closed as `agent_identity_mismatch`.
- A `tool` node declares an application-owned `module`, JSON-safe `args` (or a
  trusted resolver), and optional `result_key`. The module must implement
  `execute(Args, Context)`.
- A `workflow` node embeds an already compiled child workflow. The parent
  deadline is inherited, and a guardian cancels the child when the parent
  action process exits. A child pause is stored in the parent checkpoint and
  bubbles to the caller; resume re-enters the child checkpoint without replaying
  its completed nodes.
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

## Action results and value propagation

An ordinary graph action-like node may return:

```erlang
{ok, StateDelta}
{output, Output, StateDelta}
{stop, Output, StateDelta}
{complete, Output, StateDelta}
```

`{output, Output, StateDelta}` commits the delta, checkpoints `Output`, and
supplies it as `maps:get(input, Context)` to the successor. `{stop, ...}`
commits and terminates the workflow. `{complete, ...}` is retained as a legacy
terminal compatibility form; new code should use `output` to continue and
`stop` to terminate explicitly. `{ok, StateDelta}` continues with `null` as the
node output. These termination semantics apply to ordinary nodes; inside a
fork, `output`, `stop`, and legacy `complete` all commit that branch's local
output for fan-in rather than letting one branch terminate its siblings.

The workflow's final output is the most recently committed output. If no node
has produced one, final state is the compatibility fallback. Committed output
is part of the checkpoint and is restored without replay.

Fork branches record versioned output-and-delta entries. After all branches
commit, deltas merge in declaration order and the join receives a deterministic
`#{BranchId => Output}` map as its input. The same map becomes the current
workflow output. `reject_conflicts` and `ordered_last_wins` have the same state
merge behavior as top-level parallel workflows; a trusted `{custom, Fun}`
merger is also supported.

## Checkpoint and replay semantics

Fork workers receive the same immutable input state. Results are checkpointed
as branches finish while visible state remains unchanged. If cancellation or a
coordinator restart occurs after one branch result commits, resume skips that
branch. An action killed before its result crosses the checkpoint boundary can
run again; this is the normal at-least-once rule for in-flight effects.
Side-effecting actions should therefore use an application idempotency key.
This includes a graph fork whose other branch pauses: active siblings are
cancelled so the pause can become durable, and any sibling without a committed
result runs again after resume. The paused child's own nested checkpoint is
preserved. Do not interpret that checkpoint as a transaction over external
sibling effects.

Ordinary graph nodes use a two-phase checkpoint: their state delta and output
are committed with a `routing` cursor before a route callback runs. A blocked or
failed route can therefore resume without repeating the node action. The action
context includes `workflow_id`, `step_id`, `checkpoint_cursor`, `input`, the
exact invocation lane fields, and, for durable workflows, `invocation_id`.

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

For an ordinary paused node, the node is skipped and `Decision` becomes the
input used to select and enter its successor. For an ordinary paused fork
branch, `Decision` becomes that branch's output while its already committed
delta is retained; remaining branches then run and the join receives the full
branch-output map.

When an embedded child workflow pauses in a graph workflow node or in a
workflow branch of a graph fork, the parent stores the JSON-safe child
checkpoint. Details retain the child's `nested_node_id` and add the outer
`node_id`; fork details also add `fork_id`. Resume input is passed into the
child, completed child nodes are not replayed, and a child that pauses again
replaces the stored child checkpoint. Its eventual output and state delta then
propagate through the parent node or fork branch normally.

This nested-pause contract currently covers graph workflow nodes, workflow
branches inside graph forks, and sequential parent steps. It does not yet make
a nested child pause checkpoint-resumable inside a top-level parallel branch,
top-level loop body, or transfer member.

## Per-action timeout and retry

Graph `action`, `agent`, `tool`, and `workflow` nodes, including action-like
fork branches, accept:

```erlang
#{timeout => Milliseconds | infinity,
  retry => #{max_attempts => PositiveInteger,
             backoff_ms => NonNegativeMilliseconds}}
```

Each attempt runs in a monitored lightweight process and receives its one-based
number as `maps:get(attempt, Context)`. Exceptions, returned `{error, Reason}`
values, attempt-process death, and per-attempt timeout are retried within the
declared bound. A pause, successful result, invalid control value, schema
failure, cancellation, or global workflow deadline is not retried. Per-attempt
timeout kills only that attempt; cancellation and the global deadline interrupt
backoff and reap active workers.

The attempt counter belongs to one live execution of an uncommitted node. It is
not a durable retry ledger: cancelling or checkpointing and later resuming that
node starts a fresh retry budget. Applications must not use the retry attempt
number as an external idempotency identity.

## Root schemas and safety bounds

An optional root `input_schema` and `output_schema` is compiled once with the
workflow. A fresh start validates its initial input before any action runs.
Resume trusts the already validated initial checkpoint instead of validating it
again. Final output validation uses the most recently committed output, falling
back to final state only when no output exists. An invalid final output returns
`output_schema_validation_failed` and leaves a non-complete checkpoint.

`max_steps`, `max_iterations`, `max_concurrency`, per-action timeout/retry, and
the workflow absolute deadline are independent bounds. Cancellation and
deadline expiry kill active fork/action workers. Nested workflows inherit the
absolute deadline and retain their own compiled step, transfer, schema, and
concurrency limits.
