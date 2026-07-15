# Erlang ADK 0.4.0 delivery contract

> **Status:** frozen historical contract, completed on 2026-07-14 at branch
> checkpoint `c7a4a83`. The final gate passed 654 EUnit tests, four Common Test
> scenarios, and Dialyzer over 134 project files. Unchecked items remain
> documented limitations.

This document is the implementation and verification contract for the
`version_0.4.0` branch. Version 0.4.0 is focused on **agent, tool, and workflow
behavior**. It starts from the 0.3.0 runtime and developer-platform foundation;
it does not treat the presence of an API as proof that the complete behavior
family is implemented.

The comparison target is externally observable behavior in the official
[LLM agent](https://adk.dev/agents/llm-agents/),
[custom tool](https://adk.dev/tools-custom/),
[callback](https://adk.dev/callbacks/),
[sequential workflow](https://adk.dev/agents/workflow-agents/sequential-agents/),
[multi-agent](https://adk.dev/agents/multi-agents/),
[graph workflow](https://adk.dev/graphs/), and
[resume](https://adk.dev/runtime/resume/) documentation. Erlang ADK preserves
those behavioral outcomes where they are useful while using OTP supervision,
lightweight processes, monitors, explicit admission/queue bounds, and message
passing rather than copying another language's class hierarchy.

## Status language

- **Implemented** means the public behavior, structural failure behavior,
  deterministic tests, and Dialyzer contract have passed.
- **Partial** means a useful subset is implemented and tested, with the exact
  missing behavior documented.
- **In progress** means a branch change exists or is being developed but has
  not passed all of its required gates.
- **Planned** means the target contract is agreed but no implementation claim
  is made.

`docs/FEATURE_PARITY.md` is the current-state inventory. This document is the
0.4 delivery plan. A planned target in this document must not be read as an
implemented feature.

## Evidence-backed starting point

The 0.4 branch began from a passing 0.3 deterministic gate:

- 573 EUnit tests passed with no failures;
- four deterministic Common Test scenarios passed, including the 1,000-run
  concurrency stress scenario;
- Dialyzer completed over 131 project files without warnings;
- 14 live Gemini Common Test scenarios were skipped because the paid live gate
  is opt-in. They are not counted as passed by the deterministic baseline.

The completed 0.4 clean gate passes 654 EUnit tests, four deterministic Common
Test scenarios (including 1,000 correlated concurrent invocations), and
warning-free Dialyzer analysis over 134 project files. The packaged escript,
`adk doctor`, and checked agent-config validation also pass; the two focused
README example modules pass all 33 tests. The separate live
Gemini gate ran all 14 scenarios with `gemini-3.1-flash-lite`: 13 passed, while
Google Search grounding failed explicitly after two HTTP 429 responses. That
provider quota result is recorded as a failure, not converted into a skip or a
deterministic pass.

## 0.4 behavior contract

### Agents

An agent process is primarily an immutable, reusable specification and
admission point. Invocation history belongs to the Runner session or the
individual invocation, not to a shared child process.

| Behavior | Current 0.4 status | Required release behavior |
| --- | --- | --- |
| Invocation-scoped delegated history | Implemented | Runner and delegated child calls start from the child's configured instructions plus the current invocation input; no prior caller's direct memory is read or mutated. |
| Legacy direct prompt history | Implemented | `prompt/2,3` and asynchronous `delegate/2,3,4` remain one FIFO, stateful compatibility path. Documentation must distinguish them from isolated Runner/delegated execution. |
| Exact-session invocation lanes | Implemented | Scoped `invoke/3` and `run_with_events/4` calls serialize within one `{app_name, user_id, session_id}` lane and overlap across lanes up to `max_concurrent_invocations` (default 32). Ready lanes are admitted FIFO without allowing one active lane to occupy another slot. Unscoped invocation calls share one deterministic lane; legacy direct calls retain their own FIFO. |
| Agent topology validation | Implemented | Model-visible names use `[A-Za-z_][A-Za-z0-9_]*`; `user` is reserved. Spawn rejects name/runtime mismatches, self-reference, cycles, duplicates anywhere in the tree, multiple parents, unavailable children, more than 256 nodes, depth beyond 64, and a walk exceeding its two-second deadline. Typed workflow dispatch also requires the registry result to report the compiled canonical runtime name and otherwise fails as `agent_identity_mismatch`. |
| Runtime delegation path | Implemented | A private, normalized ancestry list follows model-visible calls, rejects cycles and depth 64 before entering the target provider, and is never placed in model history or provider configuration. |
| Agent configuration inheritance | Partial | The child retains its own provider/model configuration, local instructions, tools, and callbacks. Sub-agent delegation carries only `state`, app/user/session/invocation identity, the opaque session-service module (`state_ref`), artifact service/scope, the root global-instruction source, and the private ancestry path; AgentTool may additionally carry its scoped memory-service reference. Invocation `output_key` writes use that exact scope rather than the reusable agent's configured default. Provider credentials and compatibility memory do not cross. A broader user-configurable inheritance policy is not claimed. |
| Delegation versus transfer | Partial | AgentTool-style calls return a result to the caller. Ownership transfer exists in collaborative workflows, but its model-selected agent behavior and event contract require a single validated contract. |
| Invocation modes and final output | Partial | Stateful direct prompt and fresh invocation-scoped behavior are distinct, and final output schemas apply to final responses rather than tool traffic. A separate public taxonomy of chat/task modes is not claimed. |
| Agent callback context | Partial | Existing callbacks are bounded and monitored. 0.4 must make invocation, agent path, session-safe state, and structural callback failures consistent across direct, Runner, and delegated calls. |

Agent concurrency remains BEAM-native: independent invocations may execute in
separate supervised processes, while the legacy direct compatibility mailbox
preserves ordering. Sharing an agent definition must never imply sharing one
conversation history.

### Tools

A model-visible tool catalog is compiled before a provider call. Model output
is untrusted input: argument validation and policy checks happen before a tool
callback, confirmation request, credential lookup, or side effect.

| Behavior | Current 0.4 status | Required release behavior |
| --- | --- | --- |
| Catalog/schema compilation | Partial | Module schemas are normalized and cached per loaded BEAM code version; `adk_toolset:new/2` creates one immutable compiled catalog snapshot. Malformed schemas and duplicate names report their sources. `refresh/1` returns a replacement snapshot, but a running agent has no live catalog-swap API, so additions are not auto-advertised. |
| Model argument validation | Implemented | Complete provider call batches are checked structurally, and each known call is validated against the compiled parameter schema. Invalid calls return value-free structural errors before tool callbacks, resolution side effects, or execution in direct and Runner paths. |
| Catalog drift | Partial | A snapshotted name that disappears from a dynamic backend fails closed with `tool_catalog_changed`; a new name is invisible until explicit refresh. Refreshing does not mutate an already-running agent's tool list. |
| Direct and Runner execution | Partial | Both module and dynamic-tool paths share argument validation and malformed-call failure behavior. Full equivalence for every callback, timeout, cancellation, confirmation, and provider adapter remains a release-level claim. |
| Bounded parallel execution | Partial | Runner uses bounded workers and stable result order for explicitly parallel-safe tools. The direct compatibility path and catalog-wide behavior still require alignment. |
| Agent as a tool | Partial | Sub-agents are invocation-isolated; their schemas are argument-validated, collide safely with ordinary tools, and use the bounded private delegation path. Cancellation and transfer-versus-call semantics still require one cross-workflow contract. |
| Long-running work | Partial | Runner provides invocation/action correlation, atomic single-claim terminal resume, correlated non-terminal updates, and Mnesia-backed restart/resume coverage. It does not promise identical-result idempotent replay after a continuation has been consumed, and non-Runner agent or typed-workflow tool paths do not provide universal durable continuation parity. |
| Per-call confirmation | Partial | Modules support static `require_confirmation/0` and argument-aware `require_confirmation/2`; dynamic resolved calls can carry internal confirmation metadata. Runner/stable-run evaluates confirmation after schema and runtime policy but before tool lifecycle callbacks and execution, and treats a required call as an execution barrier. Dynamic metadata is available only after the policy-admitted resolver materializes the call, so resolvers may acquire scoped credentials but must not perform the business side effect. A toolset alias which resolves to a trusted local module cannot weaken that module: metadata and module requirements combine fail-closed, and only the local module receives private ancestry. Runner pauses with an opaque action ID that embeds no raw arguments; invalid boolean replies preserve the continuation, approval freshly resolves and rechecks policy before exactly one execution, and rejection emits a correlated structural tool response without callbacks or execution. Failed continuation restoration is surfaced structurally rather than hidden behind the original validation/admission error. A confirmed tool may subsequently enter its own long-running pause. Non-Runner agent execution (`prompt`, fresh `invoke`, delegation, and AgentTool-backed child calls) and typed-workflow tool paths have no resume channel and fail closed with `tool_confirmation_requires_runner`. The developer UI emits the typed `confirmed` payload. Structured modify payloads and universal non-Runner pause/resume are not claimed. |
| MCP/OpenAPI safety | Partial | After HTTP session loss, only `tools/list`, `resources/list`, `resources/read`, `prompts/list`, `prompts/get`, and `ping` are automatically retried. `tools/call` and unknown/mutating methods establish a new session but return `{mcp_session_lost, request_not_replayed}`; the caller must decide whether to issue a new operation. HTTP request serialization/pending-work bounds and live catalog replacement remain open. |

Tool execution uses lightweight monitored workers and explicit concurrency
limits. A slow or failed tool must not block an agent mailbox, leak credentials
into model-visible state, or leave an unowned worker behind.

### Workflows

Workflow coordinators own durable control state. Node workers are replaceable
and monitored. A committed checkpoint is the boundary between work that may be
replayed and work that must be skipped on resume.

| Behavior | Current 0.4 status | Required release behavior |
| --- | --- | --- |
| Normal output versus termination | Implemented | `{output, Output, Delta}` commits and continues; `{stop, Output, Delta}` commits and terminates. Legacy `{complete, ...}` remains a documented terminal compatibility form. |
| Durable value propagation | Implemented | Output is JSON-checked, checkpointed, restored without replay, and supplied as successor `Context.input`. Final workflow output is the last output, falling back to final state only when no output exists. |
| Sequential workflow | Partial | Each step receives the previous output; nested child pause/resume, per-action timeout/retry, schemas, cancellation, and checkpoints are covered. The retry attempt counter is live-execution state, not a durable checkpoint budget. |
| Parallel workflow | Partial | Branches remain bounded and state merge remains deterministic; the workflow output is a deterministic `#{BranchId => Output}` map. A nested child pause inside a top-level parallel branch is not yet checkpointed and bubbled. |
| Loop workflow | Partial | Reaching `max_iterations` is normal bounded completion and preserves the last output. A nested child pause inside a top-level loop body is not yet checkpointed and bubbled. |
| Collaborative workflow | Partial | Explicit owners and transfer budgets exist, members use invocation-scoped agent calls, and output propagates. A nested child pause inside a transfer member is not yet checkpointed and bubbled. |
| Graph workflow | Partial | Successor output/input, explicit stop, versioned fork output/delta records, deterministic join inputs, graph-node nested pause, and nested fork-branch resume are covered. The paused child checkpoint is not replayed; an in-flight sibling cancelled before commit is at-least-once and runs again after resume, so external sibling effects require idempotency. Retry budgets reset if an uncommitted live node is cancelled and later resumed. |
| Dynamic/code-defined workflow | Partial | Trusted Erlang callbacks can select from compiled targets and applications can build specs in code. This is bounded routing, not yet a complete dynamic workflow behavior contract. Runtime data may never select arbitrary modules or execute source. |
| Per-action policy and schemas | Partial | Sequential/parallel/transfer members and graph action/agent/tool/workflow nodes accept per-attempt timeout and bounded retry. Root input/output schemas compile once. Resume does not revalidate initial input; invalid final output leaves a non-complete checkpoint. There is no durable per-node attempt ledger. |
| Human-in-the-loop resume | Partial | Durable single-claim resume exists. Nested child pauses bubble through sequential parents, graph workflow nodes, and workflow branches in graph forks, preserving the paused child's checkpoints and repeated pauses. A graph-fork sibling which was still in flight can replay as described above. Top-level parallel, loop, and transfer nesting remains open. |

For side-effecting nodes, checkpoint/resume is at least once for work that had
not crossed its commit boundary. Applications must supply an idempotency key;
the runtime must not imply exactly-once external effects.

## Delivery phases

### A. Agent isolation and topology

- [x] Add a fresh-history invocation path for Runner and delegated sub-agents.
- [x] Prove that two Runner users/sessions sharing one child process do not
  share child prompt history.
- [x] Compile and validate agent topology and model-visible name uniqueness.
- [x] Bound runtime delegation paths and keep them private to the runtime.
- [x] Add fair, bounded exact-session lanes while retaining direct FIFO.
- [ ] Complete one transfer/call cancellation contract and final public examples.

### B. Tool catalog and execution

- [x] Compile tool catalog snapshots and reject duplicate catalog names.
- [x] Validate arguments before policy callbacks, confirmation, credentials,
  and side effects in direct and Runner paths.
- [x] Reject malformed provider call batches before persistence or callbacks.
- [ ] Complete live catalog replacement plus final callback/deadline/cancellation
  equivalence across direct and Runner execution.
- [x] Add generic boolean per-call confirmation to Runner/stable-run and make
  non-Runner agent and typed-workflow execution fail closed when confirmation
  is required.
- [ ] Add structured modify decisions and complete the durable long-running
  action contract across every execution path.
- [x] Prevent automatic replay of ambiguous MCP mutations after session loss.

### C. Workflow values and control flow

- [x] Separate normal output from explicit workflow termination.
- [x] Persist and propagate node/branch/loop/nested-workflow outputs.
- [x] Make loop exhaustion a documented bounded completion policy.
- [x] Bubble nested pause/resume through sequential, graph-node, and graph-fork
  workflow-child paths.
- [x] Add per-action timeout/retry and root input/output schemas.
- [ ] Add nested pause checkpoints for top-level parallel, loop, and transfer
  members and decide whether retry attempts need a durable ledger.

### D. Examples and release evidence

- [x] Update README agent, tool, and workflow examples only after their public
  contracts pass deterministic tests.
- [x] Execute every updated README example through the example-test suites.
- [x] Pass the full deterministic release command and Dialyzer.
- [x] Run the separate live Gemini suite with
  `gemini-3.1-flash-lite`; report skips and failures rather than converting them
  into deterministic passes.
- [x] Reconcile this contract and `FEATURE_PARITY.md` with final evidence.

## Verification gates

Each behavior change begins with a regression that fails for the observed
contract violation. Focused module tests must pass before running the complete
gate:

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
./rebar3 eunit --module=readme_examples_test
./rebar3 eunit --module=readme_workflow_examples_test
./rebar3 ct --suite test/adk_concurrency_stress_SUITE.erl
./rebar3 escriptize
_build/default/bin/adk doctor
_build/default/bin/adk config validate examples/agent.json
```

The deterministic workflow/tool gate includes malformed schemas and calls,
duplicate names, callback and side-effect exclusion, cancellation, deadlines,
worker crashes, branch conflicts, checkpoint restart, resume replay, and
cross-session isolation. Concurrency tests must also check stable output order,
bounded active workers, coordinator/owner death cleanup, and mailbox growth.

Live provider behavior is a separate, opt-in gate because it requires network
access, quota, and billable API calls. The suite is pinned to
`gemini-3.1-flash-lite`:

```bash
ERLANG_ADK_LIVE_GEMINI=1 ./rebar3 ct \
  --suite test/readme_live_gemini_SUITE.erl
```

The test process must receive `GEMINI_API_KEY`; exporting it in a different
shell does not prove that the suite inherited it. A skipped live suite is
reported as skipped, never passed.

## Documentation rule

Public examples describe only behavior that has passed its gate. Partial
features state their missing semantics next to the example. Unsupported input
returns an explicit structural error; it is not silently accepted or described
as compatible because a similarly named API exists.
