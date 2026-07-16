# Erlang ADK 0.3.0 delivery contract

> **Status:** frozen historical contract, completed on 2026-07-14 at branch
> checkpoint `941230d`. The final gate passed 573 EUnit tests, four Common Test
> scenarios, and Dialyzer over 131 project files. Unchecked items remain
> documented limitations.

This document is the living implementation and verification contract for the
`version_0.3.0` branch. A capability is marked complete only after its public
API, deterministic tests, executable README example, failure behavior, and
Dialyzer contract are all present.

Erlang ADK follows the externally observable behavior of Google ADK where it
maps cleanly to the BEAM. It does not copy Python class structure. Processes,
supervision, monitors, message passing, explicit admission control, and
deterministic state ownership are part of the public design.

## Release definition

Version 0.3.0 is intended to provide the complete Erlang-native core needed to
build, run, inspect, secure, and evaluate agents. Provider- or cloud-specific
managed services remain adapters rather than core runtime dependencies.

In scope:

- supervised agent and invocation lifecycles;
- synchronous, asynchronous, streaming, resumable, bounded, and cancellable
  runs;
- local, queue-delivered, and scheduled ambient invocations with bounded
  concurrency, idempotency, retry, deadlines, and explicit session ownership;
- safe concurrent model calls, tools, agents, workflow branches, and sessions;
- LLM agent configuration, schemas, planners, state output, callbacks, and
  provider capabilities;
- function tools, agent tools, toolsets, OpenAPI tools, confirmation, long
  running tools, and tool authentication;
- sequential, parallel, loop, collaborative, and graph workflows;
- sessions, scoped state, events, memory, artifacts, context construction,
  context compression, rewind, and persistence adapters;
- robust incoming and outbound authentication with credential isolation;
- MCP client/server transports and standards-compliant A2A interoperability;
- observability, evaluation, plugins, retry, and fault isolation;
- integrated developer tooling: CLI, local API, SSE event stream, run/session
  inspection, human-action handling, and an Erlang-hosted developer UI;
- documented Phoenix LiveView integration as an optional companion, without
  making Elixir a dependency of the Erlang library.

Not release blockers:

- pixel-for-pixel parity with Google's developer UI;
- managed Google Cloud deployment products;
- bundled adapters for every model, vector store, identity provider, or secret
  manager;
- Google Application Default Credentials/Vertex-specific identity, automatic
  model routing, and the Gemini Interactions or bidirectional Live APIs; these
  require provider adapters and the selected `gemini-3.1-flash-lite` model does
  not support Live;
- upstream experimental Agent Config YAML compatibility, Visual Builder, and
  Agent Skills, or automated instruction optimization built on eval results;
- unsafe in-process code execution. Code execution must use an isolated port
  or external sandbox.

## Architectural rules

1. An agent owns immutable configuration and admission policy. Potentially
   blocking model and tool work does not execute in the agent mailbox.
2. Every accepted invocation has one supervised process, stable ID, absolute
   deadline, budgets, cancellation path, event sequence, and exactly one
   terminal outcome.
3. Concurrency is explicit. Legacy calls remain serial by default; independent
   sessions and explicitly parallel-safe work may overlap.
4. Events use a versioned, JSON-safe public schema. Internal records and tuples
   are not transport contracts.
5. Credentials never enter prompts, ordinary session state, events, callbacks,
   telemetry metadata, or crash reports.
6. Network listeners and persistent backends are opt-in, supervised, bounded,
   and fail explicitly during initialization.
7. UI clients subscribe to independently supervised runs. A browser disconnect
   never terminates a run unless the caller explicitly requests cancellation.

## Delivery checklist

### M0: correctness and security foundation

- [x] Upgrade Cowboy to a non-vulnerable supported version.
- [x] Make all listeners and Mnesia startup opt-in and supervised.
- [x] Add a versioned JSON-safe content/event codec with legacy decoding.
- [x] Scope continuations and temporary state by invocation.
- [x] Bound asynchronous runs, model rounds, tool rounds, and tool calls.
- [x] Add explicit cancellation and caller-detach semantics.
- [x] Remove application-wide ETS session serialization.
- [x] Reject service configuration that is accepted but not used.

### M1: unified supervised execution

- [x] Add invocation and isolated model/tool/turn task supervisors.
- [x] Add stable run references, subscribe, replay, await, cancel, and status.
- [x] Commit exactly one terminal outcome per invocation.
- [x] Keep direct agent, Runner, workflow, and graph execution behind shared
  supervised lifecycle, failure, cancellation, and event contracts while
  retaining specialized lightweight coordinators for each execution shape.
- [x] Preserve serial compatibility and add bounded concurrency policies.
- [x] Supervise monitored global/per-agent admission with explicit reject and
  bounded FIFO queue policies, absolute deadlines, cancellation, and
  caller/owner fault cleanup.
- [x] Add supervised ambient event jobs with stable references, bounded
  queue/concurrency/retention/bytes/waiters, idempotency, absolute deadlines,
  monitored retry, cancellation cleanup, explicit session policies, and a
  fixed-delay `adk_trigger_source` adapter. Cloud broker transports remain
  application adapters.

### M2: agents, tools, and workflows

- [x] Dynamic/global instructions and state/artifact templating.
- [x] Input/output schemas, structured output, and atomic `output_key` state.
- [x] Provider-neutral generation configuration and capability discovery.
- [x] Provider streaming through Runner without duplicate final content.
- [x] Monitored parallel-safe tool execution with stable result ordering.
- [x] Generic confirmation/auth suspension and durable continuation handling.
- [x] Add fail-closed agent/tool allow-deny policy, canonical argument/content
  budgets, and immutable secret-free denial audit events before callbacks and
  confirmation.
- [x] First-class sequential, parallel, loop, collaborative, and graph specs.
- [x] Deterministic branch state merges, transfer budgets, and checkpoints.

### M3: services and context

- [x] Versioned artifact service with ETS and filesystem adapters.
- [x] Runner-integrated memory retrieval and ingestion.
- [x] Context budgeting, filtering, compression, and cache capabilities.
- [x] Session pagination, rewind/branch, and ETS/Mnesia backend contract tests.

### M4: auth and interoperability

- [x] Auth provider, credential store, token manager, policy, and redaction APIs.
- [x] OIDC/OAuth/API-key/bearer flows and per-user tool credentials.
- [x] OpenAPI toolsets with validation and security-scheme routing.
- [x] MCP stdio and Streamable HTTP clients plus bounded MCP server
  capabilities.
- [x] A2A 1.0 JSON-RPC Agent Card, messages/tasks, SSE streaming/replay,
  history/artifacts, cancellation, principal scoping, OIDC hook, and outbound
  client. gRPC, HTTP+JSON, push notifications, extended/signed cards, and
  durable distributed task storage remain future adapters.

### M5: developer platform and quality

- [x] CLI for run, serve, inspect, evaluate, and configuration validation.
- [x] Authenticated REST/SSE developer API with replay and credit-based
  backpressure.
- [x] Erlang-hosted developer UI for chat, trace, tools, state, and approvals.
- [x] Phoenix LiveView integration guide with public API contract tests and
  manually reviewed companion syntax. This Erlang repository has no Mix
  compile gate and does not claim otherwise.
- [x] Ordered plugins and connected invocation/model/tool traces.
- [x] Eval sets, trajectory/multi-turn evaluation, and saved result metadata.
- [x] Multimodal content and provider contract suite.
- [x] Gemini Google Search grounding through GenerateContent, including strict
  built-in-tool config, bounded metadata, SSE accumulation, output-schema-safe
  event persistence, and escaped developer-console display.

### Explicit adapters and deferred experimental surfaces

These are tracked in `FEATURE_PARITY.md`, but are not represented by unchecked
core items above:

- Google ADC/Vertex credential-source precedence and managed Agent Identity;
- Gemini Interactions and Live WebSocket sessions, plus URL Context, Maps, and
  Enterprise Search grounding;
- concrete non-Gemini providers and automatic model routing/fallback;
- cloud broker, managed memory/vector store, secret-manager, telemetry, and
  deployment adapters;
- session schema migrations and configurable backend conflict policies;
- experimental Agent Config/Visual Builder/Skills compatibility and automated
  optimization samplers.

Each adapter must use the same capability discovery, opaque credentials,
bounded worker, structural failure, cancellation, and test-fixture contracts as
the built-in runtime. An unsupported adapter is reported explicitly; it is not
silently simulated by a superficially similar core feature.

## Verification gates

Every milestone runs:

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
./rebar3 eunit --module=readme_examples_test
./rebar3 eunit --module=readme_workflow_examples_test
```

The deterministic release gate additionally requires:

- event and persistence property/round-trip tests;
- shared ETS and Mnesia backend contract tests;
- cancellation, caller death, timeout, worker crash, replay, restart, and
  concurrency fault-injection tests;
- seeded-secret redaction and cross-user authorization tests;
- MCP, A2A, OpenAPI, OIDC, and SSE protocol fixtures;
- browser reconnect, slow-subscriber, event-order, and approval-resume tests;
- a bounded stress test with at least 1,000 deterministic invocations and no
  crossed events, orphan children, or unbounded mailbox growth;
- all README examples executed as tests;
- `./rebar3 escriptize`, a successful `adk doctor`, and validation of the
  checked-in `examples/agent.json` configuration.

The separate real-provider gate uses `gemini-3.1-flash-lite`. Live Gemini
verification remains explicit because it uses network access, quota, and
billable API calls:

```bash
ERLANG_ADK_LIVE_GEMINI=1 ./rebar3 ct \
  --suite test/readme/readme_live_gemini_SUITE.erl
```

## Documentation policy

- New public behavior is documented in the README in the same change.
- README snippets are copied into, or directly exercised by, executable tests.
- Partial behavior is labelled partial; unsupported behavior returns an
  explicit error rather than being silently accepted.
- This checklist is updated whenever a capability crosses its verification
  gate.

## Development log

### 2026-07-13 foundation and developer-platform slice

- Added stable supervised runs, bounded replay, caller-detached subscriptions,
  cancellation, retention, and exactly-one terminal outcomes.
- Added supervised paused-run resume with immutable parent/child run links and
  atomic replay rejection.
- Added bounded supervised tasks and serial-by-default, explicitly
  parallel-safe tool batches with ordering and HITL barriers.
- Added a supervised Erlang-native admission controller with global/per-agent
  limits, immediate rejection or bounded oldest-eligible FIFO queueing,
  absolute deadlines, explicit cancellation, monitored requesters/owners, and
  exactly-once permit return across normal completion and process failure.
- Added a supervised ambient/background runtime with bounded local queue
  submission, stable event status/await/cancel, node-local retained
  idempotency, explicit per-event/explicit/shared session policies, one
  deadline across queue/retry/run time, synchronous admission cleanup, and a
  one-timer fixed-delay trigger. Pub/Sub/Eventarc and other broker transports
  implement the `adk_trigger_source` adapter contract outside the core.
- Added Runner-integrated fail-closed runtime policy for agent/tool allow-deny,
  canonical argument/input/tool-result/final-output byte budgets, post-toolset
  enforcement before callbacks and HITL, structural model-visible denials, and
  canonical immutable audit events containing no arguments, content,
  credentials, or runtime handles.
- Added versioned checked event JSON, immutable ETS artifacts, explicit memory
  retrieval/ingestion, and monitored service calls.
- Added immutable agent contracts: scoped static/dynamic instructions,
  provider-neutral generation settings, input/output schemas, history policy,
  and atomic final-event `output_key` state.
- Added root-scoped static/dynamic `global_instruction` propagation across
  delegated agent processes, strict Gemini config-key validation, and
  request-level adjustable Gemini safety category/threshold encoding.
- Added Gemini GenerateContent Google Search grounding with a strict built-in
  tool allow-list, safe combination with custom function declarations, a
  versioned checked provider-result envelope, 256 KiB JSON metadata cap,
  streaming accumulation, and persisted provider/type-discriminated actions.
- Added secret-scrubbed Runner context filtering, byte/token budgets, bounded
  compression, deterministic cache identities, and context-build telemetry.
- Added HMAC snapshot cursors, filtered session/event pagination, and
  non-destructive, stale-plan-checked session branch/rewind.
- Added private principal/provider-scoped credentials, single-flight token
  refresh, expiry skew, caller/orphan handling, and recursive redaction.
- Added Oidcc-backed incoming JWT verification and explicit issuer, audience,
  signing-algorithm, time, subject, claim, and scope policy, plus outbound OAuth
  client-credential and refresh-token adapters. Rotated refresh tokens are
  atomically persisted before access-token release and conflicts fail closed.
- Added a strict OpenAPI 3.0/3.1 compiler, production SSRF-resistant Gun
  transport, per-principal credential broker, and a generic dynamic-toolset
  path used by both direct agents and Runner. OpenAPI and MCP operations now
  execute with the same bounded task, callback, correlation, and declared
  parallel-safety contracts as Erlang tool modules.
- Added supervised stdio and MCP 2025-11-25 Streamable HTTP clients, including
  lifecycle/version/session negotiation and bounded JSON/SSE POST responses.
  Added a loopback-first, authenticated, Origin-validating MCP server for
  tools, resources, and prompts with session/body/time/concurrency limits and
  deterministic EUnit/Common Test protocol fixtures.
- Added a versioned provider-neutral multimodal content contract with bounded
  text, canonical inline base64, HTTPS/GCS file references, and correlated
  function parts. Gemini one-shot and SSE requests/responses preserve this
  structure, while legacy text generation/streaming remains binary-compatible
  and unsupported media or provider parts fail explicitly. Gemini Live remains
  a separate, unimplemented WebSocket lifecycle.
- Added Runner-native text and canonical-content provider streaming. Blocking
  provider I/O stays in the independently supervised invocation worker, each
  correlated delta is a durable partial event, and one immutable final event
  replaces provisional content for synchronous and stable-run outcomes. Output
  bytes and canonical content remain bounded, and partials are not replayed
  into subsequent model context.
- Added the opt-in Erlang-hosted `/dev` console and authenticated REST/SSE API;
  browser disconnect detaches without cancelling the run.
- Added the Phoenix LiveView companion pattern with credit/ack delivery,
  bounded rendered history, replay-gap handling, reconnect cursors, stable run
  ownership, and authenticated server-side principals. Its Erlang API contract
  is exercised here; the Elixir syntax is manually reviewed because this pure
  Erlang repository intentionally has no Mix toolchain gate.
- Added a deterministic 1,000-run Common Test stress gate with bounded
  concurrent batches, exact response/session/invocation correlation, unique
  run IDs, supervisor-child cleanup, and mailbox stability checks.
- Added ordered Runner-global plugins across run, agent, model, tool, event,
  and error phases. Plugin callbacks are isolated in monitored lightweight
  processes with explicit timeout, heap, observation/intervention, and
  fail-open/fail-closed contracts; interventions precede and may skip the
  corresponding local callback without bypassing final event/schema rules.
- Added connected invocation/model/tool telemetry and schema-versioned,
  JSON-safe observability envelopes with trace/run/session/agent/model/tool
  correlation, bounded ordered exporters, recursive secret pruning, and
  explicit opt-in content capture that degrades safely for opaque BEAM terms.
- Added versioned multi-turn evaluation sets/results, stateful adapters,
  captured ADK event and tool trajectories, ordered metric/judge thresholds,
  pass-rate gates, saved build metadata, deadlines, heap limits, and bounded
  per-case concurrency while preserving the lightweight `adk_eval` API.
- Moved agent turns, stable invocations, and workflow coordinators behind
  opaque supervisor child arguments and validated one-shot handoff. Added
  adversarial tests proving that seeded request, option, closure, state,
  checkpoint, ledger, and credential data do not enter child specs, `sys`
  diagnostics, public failures, or persisted failed/cancelled outcomes.
- Tightened durable Mnesia leases so expiry itself fences renew, checkpoint,
  and finish; equality is expired, a live local PID does not extend a lease,
  concurrent takeover has one winner, and old owner tokens become stale.
- Completed the deterministic release gate: 573 EUnit tests, four Common Test
  scenarios including 1,000 stable invocations, and Dialyzer over 131 project
  files all passed. The 14 billable live Gemini scenarios remain a separate
  opt-in gate in the shell that owns `GEMINI_API_KEY`.
- Built the `adk` escript, validated the checked-in agent configuration, and
  extended `adk doctor` to verify the Gemini provider plus Cowboy, Gun, JSX,
  telemetry, Oidcc, and JOSE without exposing environment credential values.
- Fixed packaged `adk serve` cold startup so the loaded application cannot
  restore `dev_enabled=false` after the CLI has configured the listener.
  Verified the packaged binary against a real loopback listener: `/dev`
  returned HTTP 200 and `adk inspect agents` discovered the configured agent.
  Developer-API transport failures now use bounded structured JSON instead of
  leaking nested Erlang tuples and character lists.
