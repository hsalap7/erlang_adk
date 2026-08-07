# Erlang ADK 0.9.0 release contract

> **Status:** released on 2026-08-06. The deterministic release tests recorded
> below passed. Coverage, Hex/ExDoc packaging, and optional paid-provider runs
> were not recorded for this release and are not implied by the release status.

Version 0.9 focuses on two connected foundations: a durable, inspectable graph
runtime and a broader but still explicit model-adapter fabric. It preserves the
0.8 process ownership, bounded execution, provider-profile, and transport
security contracts.

## Architectural decisions

1. **One canonical graph representation.** `adk_workflow` with `kind => graph`
   is the runtime. The fluent `adk_graph` builder lowers to that representation
   and can be inspected or run through the workflow engine.
2. **A checkpoint binds to executable meaning.** Checkpoint schema v2 records
   a deterministic definition fingerprint, execution identity, sequence,
   durable attempts, node status, runnable/waiting work, joins, cycles, and
   interruptions. Identity is more than workflow ID/version/kind.
3. **Resume is at least once.** A committed result is not replayed. Work whose
   external effect happened before its result committed may run again. No
   checkpoint or lifecycle event implies exactly-once external effects.
4. **Graph data contracts are explicit.** Root and per-node JSON Schemas are
   compiled before execution. State keys may opt into deterministic reducers;
   the backwards-compatible default remains overwrite.
5. **Inspection never returns executable configuration.** The JSON-safe graph
   descriptor exposes topology, public policies, schemas, definition identity,
   and analysis, while omitting callbacks, captured values, tool arguments,
   credentials, and provider configuration.
6. **Provider breadth is evidence-based.** Native adapters preserve their own
   wire semantics. OpenAI-compatible local servers use a narrowly scoped
   loopback exception rather than weakening the general HTTPS and SSRF policy.
   A configuration recipe or injected transport test is not a blanket model
   certification.

## Implemented 0.9 scope

### Durable workflows and continuations

- [x] Emit checkpoint schema v2 with `definition_fingerprint`, stable
  `execution_id`, ordered checkpoint lineage, durable attempt records,
  node/runnable/waiting state, join/cycle state, and interruption metadata.
- [x] Accept a valid v1 checkpoint for the 0.8-to-0.9 migration and rewrite it
  as v2 at the next commit boundary. A v2 checkpoint with the wrong definition
  fingerprint fails as `checkpoint_definition_mismatch`.
- [x] Add optional `definition_revision` as a non-negative integer or non-empty
  binary. Anonymous callbacks without it are VM-build-specific and the
  definition is marked non-portable; applications that resume across code
  deployment must maintain an explicit revision.
- [x] Persist retry attempts. If a process dies while an attempt is marked
  running, resume repeats that same one-based attempt number, preserving the
  configured `max_attempts` bound and the at-least-once boundary.
- [x] Preserve nested pause/resume through sequential, top-level parallel,
  loop, transfer, graph workflow nodes, and graph-fork workflow branches.
  Uncommitted siblings cancelled to make a pause durable may run again.
- [x] Allow protected typed-workflow tool nodes to produce a structured
  `tool_confirmation` pause. Approval rechecks the correlated action and runs
  that exact call; rejection and malformed/mismatched responses fail closed.
- [x] Add a separate `lifecycle_receiver` option. It receives ordered,
  JSON-safe schema-v1 workflow/node/route/fork/join/attempt/retry/checkpoint/
  pause/resume/terminal events without changing the legacy event receiver.

### Graph execution and data contracts

- [x] Validate graph reachability, terminal visibility, strongly connected
  components, fork/join topology, shared branches/joins, and typed join targets.
  Provable unsafe topology is rejected; properties obscured by trusted dynamic
  callbacks are reported as inspection warnings.
- [x] Add fork completion policies `all`, `any`, `first_success`, and
  `{quorum, N}`. Early policies cancel still-running branches after their
  condition is met and merge only committed successful branch results.
  `first_success` alone tolerates branch failure; the other policies fail fast.
- [x] Compile optional `input_schema` and `output_schema` on every graph node,
  validate node input before its action, and validate node output before its
  delta becomes visible.
- [x] Add workflow `state_reducers` for binary state keys: `overwrite`,
  `append`, `sum`, and `reject_conflict` (with `reject_conflicts` accepted as
  an alias). Reducer type/conflict failures identify only the key and policy,
  not the state values.
- [x] Add deterministic, JSON-safe graph description and DOT/Mermaid rendering
  through `erlang_adk:inspect_graph/1`, `erlang_adk:render_graph/2`, and the
  corresponding `adk_graph` functions.
- [x] Add local factory commands `adk graph validate MODULE FUNCTION`,
  `adk graph describe MODULE FUNCTION`, and
  `adk graph render MODULE FUNCTION --format mermaid|dot|json`. Factory lookup
  is restricted to already available modules and exported zero-arity functions;
  command input does not create arbitrary atoms or select runtime modules.

### Model adapters and provider profiles

- [x] Route agent feature checks through adapter capability declarations and
  advertise provider-neutral generation configuration only where implemented.
- [x] Constrain profile-selected Live capabilities to the selected adapter's
  ceiling and derive trusted audio input rates from the resolved capabilities.
- [x] Add an explicit keyless local endpoint policy for
  `adk_llm_compatible`. It is limited to numeric `127.0.0.1` or `::1`, auth
  `none`, and non-Live requests; the general custom-origin HTTPS/private-address
  protections are unchanged.
- [x] Add native Vertex AI publisher-model GenerateContent/SSE support with
  fixed Google authority/path derivation, Gemini-compatible content/tool
  encoding, OAuth bearer handling, structured output, and bounded streaming.
- [x] Add trusted Vertex OAuth sources for an explicit access token or
  `google_adc`. A profile-selected `google_adc` source uses only the fixed,
  bounded `gcloud auth application-default print-access-token --quiet`
  invocation. A trusted direct configuration may instead inject an
  `adc_token_provider`; profile callers cannot. No caller-selected executable,
  arguments, URL, or headers cross that boundary.
- [x] Document implementation and evidence tiers for Gemini/Gemma, OpenAI,
  Claude, Vertex, Ollama, vLLM, LiteLLM Proxy, and transparent HTTPS gateways.
  This is not a claim that every model exposed by those products is supported.

## Compatibility and migration

- Existing workflows without `state_reducers` retain last-write/overwrite
  state-delta behavior.
- Existing root schemas continue to work; per-node schemas are optional.
- Existing fork nodes default to `join_policy => all`.
- Existing v1 checkpoints can be resumed only against a matching
  ID/version/kind and become definition-bound v2 checkpoints at the next
  boundary. After that rewrite, reverting to 0.8 is not a supported resume
  path.
- Durable applications should add and maintain `definition_revision` before a
  rolling code deployment. Changing the revision intentionally invalidates old
  v2 checkpoints.
- `lifecycle_receiver` is opt-in and separate from `event_receiver`.

See [`UPGRADING.md`](UPGRADING.md),
[`DURABLE_INVOCATIONS.md`](DURABLE_INVOCATIONS.md), and
[`GRAPH_WORKFLOWS.md`](GRAPH_WORKFLOWS.md) for operational details.

## Explicit limitations

- The runtime provides at-least-once recovery, not exactly-once actions,
  branches, tool calls, lifecycle delivery, or external side effects.
- The graph runtime executes the declared node/fork/nested-workflow model; it
  is not a general arbitrary multi-node branch-region scheduler.
- There is no drag-and-drop visual editor or upstream Agent Config code
  generator. The release adds read-only description and text rendering.
- There is no automatic cross-provider cost/latency router, fleet model
  discovery, or guarantee covering 100+ model names. Applications select a
  trusted adapter/profile and validate their exact endpoint.
- Upstream Agent Skills are not implemented or inferred from ordinary prompts,
  files, MCP resources, or Erlang modules.
- Vertex paid-provider success, arbitrary compatible-server behavior, and the
  final complete release gates are not implied by deterministic fixtures.
- The Vertex slice does not implement partner publishers, endpoint resources,
  custom origins, Live, thinking/built-in tools, or context caching.
- Local endpoints are loopback-only and development-oriented. Private LAN,
  container bridge, remote, or hostname-based cleartext endpoints remain
  rejected; use a trusted HTTPS gateway for those deployments.

## Release evidence ledger

The commands and interpretation rules are in [`TESTING.md`](TESTING.md).
Populate this ledger only from one reviewed release revision.

| Gate | 0.9 release result |
| --- | --- |
| Clean compile, EUnit, Common Test, Dialyzer | Passed: 242 production and 271 test modules compiled with `-Werror`; all 1,495 EUnit tests and all 6 Common Test cases passed; a fresh Dialyzer run reported 0 warnings |
| Deterministic line coverage | Not recorded for this release; the existing floor was not lowered or reinterpreted |
| Focused graph/workflow/model/provider/CLI tests | Passed within the 1,495-test aggregate run |
| Xref, escript, doctor, config validation | `./rebar3 xref` passed with 0 undefined or deprecated calls or functions; release-contract and CLI tests passed. A complete escript/doctor release execution was not recorded. |
| ExDoc, Hex build, extracted-package compile | Not recorded for this release |
| Phoenix gates | Passed: locked dependencies; warnings-as-errors compilation; 103 ExUnit and 40 browser/audio tests; production assets and release assembly; trusted-proxy and verified direct-TLS health smokes; exact documented advisory-exception verifier |
| Phoenix dependency audit | Bandit 1.12.4, Cowboy 2.18.0, and Cowlib 2.19.0 remove EEF-CVE-2026-65623, EEF-CVE-2026-65624, and EEF-CVE-2026-59248. Raw `mix hex.audit` remains non-zero for three package findings covering EEF-CVE-2026-43969 and EEF-CVE-2026-43966; the exact package/advisory verifier passed. |
| Paid Gemini/Vertex/OpenAI/Anthropic/compatible evidence | No new 0.9 remote-provider result recorded here |
