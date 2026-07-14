# ADK behavior-parity matrix

This is the living feature inventory for Erlang ADK 0.3.0. It follows the
externally observable capability families in the official
[Agent Development Kit documentation](https://adk.dev/), while deliberately
using OTP processes, supervision, monitors, and message passing instead of
copying another language's object model.

Status meanings:

- **Implemented**: public Erlang API and deterministic coverage exist.
- **Partial**: useful, release-safe core behavior exists, but this upstream
  capability family is not claimed in full. The documented omissions are not
  necessarily blockers for the Erlang 0.3.0 contract.
- **Planned adapter**: the core extension contract is identified, but a
  provider- or deployment-specific implementation is intentionally outside the
  0.3.0 core.
- **Adapter**: the core defines the contract; provider-specific coverage may be
  delivered separately.
- **Deferred experimental**: the corresponding upstream feature is
  experimental or outside the 0.3.0 runtime contract and is not represented as
  silently supported.

The upstream comparison follows the current ADK 2.0 capability families. It
compares externally visible behavior, not Python/Go class names: an Erlang
workflow is expected to use supervised processes, monitors, immutable messages,
and explicit ownership where those are the stronger BEAM-native contract.
The primary references are the official [ADK 2.0 overview](https://adk.dev/2.0/),
[graph workflow guide](https://adk.dev/graphs/),
[runtime web interface](https://adk.dev/runtime/web-interface/), and
[tool-authentication guide](https://adk.dev/tools-custom/authentication/).
Experimental upstream surfaces are identified from the official
[Agent Config](https://adk.dev/agents/config/),
[Visual Builder](https://adk.dev/visual-builder/), and
[Skills](https://adk.dev/skills/) pages.

No row should be changed to **Implemented** until its README example, failure
behavior, EUnit/Common Test coverage, and Dialyzer checks pass.

The 2026-07-13 deterministic release gate passed 573 EUnit tests, four Common
Test scenarios (including 1,000 stable concurrent invocations), and Dialyzer
over 131 project files. The 14 billable live Gemini scenarios remain a
separate opt-in provider gate and are not counted as deterministic coverage.

## Build agents

| Capability family | 0.3.0 status | Erlang-native contract |
| --- | --- | --- |
| LLM agents, static instructions, model tools | Implemented | Agent contracts compile once as immutable configuration. Runner invocations are independently supervised; direct compatibility calls remain serialized by the agent process. |
| Dynamic/global instructions and state/artifact templating | Implemented | Static and bounded dynamic instructions resolve per invocation from an exact, secret-scrubbed scope without mutating agent configuration. A root `global_instruction` is prepended locally and carried explicitly across delegated BEAM-process boundaries; a child uses its own global instruction only when independently invoked as a root. |
| Input/output schemas and structured output | Implemented | Inputs are rejected before provider execution; final output and callback replacements are validated before an `output_key` delta is committed in the same final event. |
| Provider-neutral generation configuration | Implemented | Common generation options are validated, normalized, and checked against discovered provider capabilities instead of being silently ignored. Gemini rejects unknown provider/nested-generation keys, maps validated adjustable safety settings, and supports strict `googleSearch` grounding with bounded candidate metadata persisted on correlated events. |
| Planning and replanning | Implemented | Gemini model-native thinking is available through validated agent generation config. The public explicit-planning API runs versioned JSON-safe plans through trusted planner/executor adapters with monitored callbacks, step/replan/deadline/heap/byte limits, owner-bound cancellation, and secret-pruned results; plan data cannot select modules or execute source. |
| Multi-agent delegation and routing | Implemented | Sub-agent tools return to their caller; collaborative members hand off ownership through bounded transfer events and resolve binary registered agent names at dispatch time. |
| Sequential workflow | Implemented | Independently supervised coordinator, monitored step workers, ordered JSON-safe state deltas, absolute deadline, step budget, cancellation, checkpoint, and resume. |
| Parallel workflow | Implemented | Explicit concurrency cap, linked/monitored BEAM workers, declared-order collection, conflict-aware deterministic merge, deadline, and sibling cleanup. |
| Loop workflow | Implemented | Post-body predicates, explicit iteration and step budgets, one absolute deadline, cancellation, and resumable committed state. |
| Collaborative workflow | Implemented | Declared ownership, JSON-safe handoff input/state, `transfer_to_agent` events, stable agent identity, and a transfer budget that includes self-transfer. |
| Graph workflows and dynamic routes | Implemented | Typed action, agent, tool, nested-workflow, branch, loop, fork, and join nodes use explicit validated edges, target allow-lists, post-delta routes, deterministic branch merges, step/deadline/cancellation bounds, and resumable checkpoints. |
| Dynamic/code-defined workflows | Implemented | Erlang functions can build bounded workflow specs and route with ordinary pattern matching and recursion while execution remains supervised, checkpointed, and deadline-bound. Arbitrary workflow data cannot select a module or execute source code. |
| Agent routing | Implemented | Stable registered binary agent identities, explicit transfer budgets, graph route functions, and policy allow-lists provide deterministic routing. Automatic model-selected/A-B router products remain adapters rather than hidden defaults. |
| Human input and action confirmation | Implemented | Durable invocation-scoped suspension; supervised resume creates a linked run and rejects replay. |
| Declarative Agent Config | Partial | Checked JSON agent configuration is supported by the `adk` CLI and rejects embedded secrets. It is not presented as compatible with upstream's experimental YAML schema or Python-only generated tool modules. |

## Run agents

| Capability family | 0.3.0 status | Erlang-native contract |
| --- | --- | --- |
| Sync, async, streaming runs | Implemented | One independently supervised invocation per accepted run. Provider streaming executes outside the agent mailbox; correlated partials are replayable while one immutable final snapshot supplies the outcome exactly once. |
| Stable run ID, status, subscribe, replay, await | Implemented | Bounded replay, credit/ack delivery, explicit replay gaps, and subscriber monitoring; browser/caller lifetime is detached. |
| Cancel and absolute deadlines | Implemented | Cancellation reaches monitored workers and every run commits exactly one terminal outcome. |
| Resume agents | Implemented | Multiple pauses are correlated by invocation ID; a paused stable run resumes as one linked supervised run and replay is rejected. |
| Runtime configuration and admission control | Implemented | One supervised controller enforces monitored global/per-agent permits with immediate reject or bounded oldest-eligible FIFO queueing, absolute deadlines, cancellation, and owner/caller crash cleanup. |
| Web interface | Implemented | Opt-in dependency-free Erlang UI supports chat, traces, session inspection, cancellation, bounded credit-based replay/reconnect, and approval/resume. |
| Command line and API server | Implemented | Authenticated REST/SSE replay plus `run`, `serve`, `inspect`, `cancel`, `resume`, `evaluate`, `config validate`, and `doctor` CLI commands are packaged in the `adk` escript. |
| Visual workflow builder | Deferred experimental | The upstream visual builder and its Agent Config format are experimental. Erlang ADK 0.3.0 provides an inspectable developer UI and declarative workflow APIs, but does not claim drag-and-drop code generation. |
| Ambient/background agents | Implemented | The local/event runtime owns stable event references, bounded concurrency/queue/retention/bytes/waiters, one absolute deadline, idempotency, monitored retry, status/await/cancel, and explicit per-event/explicit/shared session policy. A supervised fixed-delay source is included; `adk_trigger_source` keeps Pub/Sub, Eventarc, Kafka, RabbitMQ, and cloud scheduler transports as backpressured application adapters without SDK dependencies. Durable distributed dedupe/trigger registration and provider delivery acknowledgements remain adapter responsibilities. |

## Components

| Capability family | 0.3.0 status | Erlang-native contract |
| --- | --- | --- |
| Function tools and agent tools | Implemented | Erlang modules and dynamic toolsets share model schema discovery, bounded isolated execution, errors as values, callbacks, and correlated call IDs in direct agents and Runner. |
| Parallel tool performance | Implemented | Execute only explicitly parallel-safe tools concurrently with bounded fan-out and stable result order. |
| Long-running tools and confirmations | Implemented | Generic suspension reasons and durable continuation data, not a special-case process mailbox. |
| Tool authentication | Implemented | Per-principal credentials use opaque references and private storage; OpenAPI auth is routed out of band and no secret is accepted in model arguments, context, events, logs, or prompts. Additional tool adapters can implement the same broker contract. |
| OpenAPI toolsets | Implemented | Strict OpenAPI 3.0/3.1 compilation, local references, deterministic schemas, JSON operations, production SSRF-resistant Gun transport, API-key/bearer/OAuth routing, and first-class direct-agent/Runner execution are covered; broader media/auth schemes remain explicit non-goals for 0.3.0. |
| MCP tools | Implemented | Supervised stdio and MCP 2025-11-25 Streamable HTTP clients negotiate lifecycle/version/session state (with 2025-06-18 compatibility) and expose tools, resources, and prompts. The bounded loopback-first server validates JSON-RPC, Origin, auth, bodies, sessions, deadlines, and concurrency; optional GET/SSE and advanced capabilities remain explicit limitations. |
| Versioned artifacts | Implemented | Scoped immutable versions, metadata/digest, ETS and filesystem adapters, lazy context references. |
| Sessions and scoped state | Partial | ETS/Mnesia scopes, HMAC snapshot cursors, filters, pagination, and immutable rewind/branch are implemented; schema migration and configurable conflict policies remain explicit adapters. |
| Events | Implemented | Versioned JSON-safe schema with checked encoding and legacy decoding. |
| Long-term memory | Implemented | Explicit retrieval/ingestion policy and bounded adapter calls; richer ranking and managed adapters remain application integrations. |
| Context filtering and token budgeting | Implemented | Secret-scrubbed deterministic event selection, bounded byte/token estimates, filters, and explicit error/truncation are integrated into Runner; exact provider token accounting remains provider-specific. |
| Context compression and caching | Implemented | Compression runs in a monitored, time/heap/output-bounded worker and produces stable secret-free cache identities; managed/provider cache adapters remain. |
| App callbacks | Implemented | Existing local callbacks remain compatible. Runner-global plugins precede corresponding local callbacks, intervention skips the local callback, and local callbacks run in monitored timeout/heap-bounded workers over credential-free projected values. |
| Plugins | Implemented | Ordered Runner-global run/agent/model/tool/event/error hooks compile once, run in monitored timeout/heap-bounded processes, support open/closed failures and observe/intervene modes, and preserve final event/schema invariants. |
| Agent skills | Deferred experimental | Upstream Skills are experimental. A future adapter must provide incremental discovery/loading plus an explicit filesystem/remote trust policy; 0.3.0 does not reinterpret ordinary prompts or MCP resources as Skills. |
| Agent optimization | Adapter | Eval sets, trajectories, metrics, judges, and saved results provide the measurement contract. Automated instruction mutation/samplers and provider-specific optimizers are separate, auditable adapters. |

## Interoperability, operations, and safety

| Capability family | 0.3.0 status | Erlang-native contract |
| --- | --- | --- |
| Incoming OIDC/OAuth/API authentication | Implemented | Local bearer auth and same-origin checks plus Oidcc-backed signature/JWKS verification and independent issuer, audience, algorithm, time, subject, claim, and scope policy are available for explicit endpoint wiring. |
| Outbound OAuth/API-key/bearer credentials | Implemented | Private per-principal credentials and supervised single-flight OAuth client/refresh grants are keyed by provider/scopes/audience; rotated refresh tokens are compare-and-swap persisted before access-token release. Production external secret-store adapters remain application integrations. |
| Google Application Default Credentials | Planned adapter | Follow ADC source precedence without mixing model, user, and service credentials. |
| A2A protocol | Implemented | Released A2A 1.0 Agent Card discovery and JSON-RPC `SendMessage`, `SendStreamingMessage`, `GetTask`, `ListTasks`, `CancelTask`, and `SubscribeToTask` are implemented with member-discriminated Parts, task history/artifacts, bounded supervised execution, ordered SSE replay, principal scoping, OIDC hook, and outbound discovery/unary/stream client. gRPC, HTTP+JSON, push notifications, extended/signed cards, and durable distributed task storage remain explicit adapters. The project-specific `/a2a/prompt` route remains legacy and separate. |
| Observability | Implemented | Connected invocation/model/tool correlation, `telemetry` emission, schema-versioned structured envelopes, recursive redaction, default-off content, and bounded ordered exporters are implemented. OpenTelemetry/vendor bridges remain application adapters. |
| Evaluation | Implemented | Legacy evaluation remains; versioned multi-turn eval sets/results, adapter state, captured event/tool trajectories, metric/judge thresholds, aggregate pass rates, redacted build metadata, deadlines, heap limits, and bounded case concurrency are implemented. Provider-specific judge/managed-service adapters remain separate. |
| Safety and policy | Implemented | Runner policies fail closed with deny-overrides-allow agent/tool rules, finite canonical argument/content budgets, post-resolution gates before callbacks/HITL, structural tool errors, secret-free telemetry, and canonical immutable denial audit events. Gemini request-level adjustable harm categories and thresholds are strictly validated and REST-encoded; non-adjustable provider protections remain provider-owned. Human confirmation remains the suspension mechanism. |
| Multimodal content | Implemented | Versioned JSON-safe text, bounded inline bytes, HTTPS/GCS file references, and function parts map to Gemini one-shot, SSE content, and Runner partial/final events without changing text-only APIs. MIME, base64, URI, JSON, role, part-count, and byte limits fail explicitly. |
| Google Search grounding | Implemented | Gemini GenerateContent accepts only the explicit `google_search` built-in, combines it safely with function declarations, and persists bounded, provider-discriminated JSON grounding metadata for one-shot and SSE results without breaking output schemas. Individual provider fields remain forward-compatible JSON rather than an Erlang-owned schema. URL Context, Maps, Enterprise Search, and the newer Interactions API remain explicit adapters. |
| Model routing and non-Gemini providers | Adapter | The provider behavior and capability negotiation are stable extension points. Automatic model fallback/routing and concrete Claude, Ollama, vLLM, LiteLLM, or managed-hosted adapters are not implied by the Gemini implementation. |
| Gemini Live | Planned adapter | Bidirectional WebSocket audio/video input, interruption, session resumption, and backpressure require a separately supervised session protocol. REST SSE is not presented as Live support; the selected `gemini-3.1-flash-lite` model itself does not support the Live API. |
| Deployment | Adapter | OTP releases/containers are core-neutral; Cloud Run/GKE/managed runtime guidance belongs in deployment adapters. |

## Developer web integration

Phoenix is compatible but optional. The recommended topology is a separate
Phoenix LiveView application that depends on `erlang_adk`, subscribes to stable
run IDs, and reconnects using bounded replay. It must not own or link the run
process from a LiveView process. The Erlang library itself retains a pure OTP
dependency graph and provides the authenticated REST/SSE contract used by both
Phoenix and the built-in developer UI.
