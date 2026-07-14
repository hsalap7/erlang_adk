# ADK behavior-parity matrix

This is the living feature inventory for Erlang ADK 0.4.0 development. It
records what the `version_0.4.0` branch proves now, not the intended end-state
of the release. It follows the externally observable capability families in
the official [Agent Development Kit documentation](https://adk.dev/), while deliberately
using OTP processes, supervision, monitors, and message passing instead of
copying another language's object model.

Status meanings:

- **Implemented**: public Erlang API and deterministic coverage exist.
- **Partial**: useful, release-safe core behavior exists, but this upstream
  capability family is not claimed in full. The documented omissions are not
  necessarily blockers for the Erlang 0.4.0 contract.
- **In progress**: an implementation slice is present or being developed, but
  its required deterministic gate has not completed and no release claim is
  made yet.
- **Planned**: the behavior contract is identified for 0.4.0, but it is not
  implemented yet.
- **Planned adapter**: the core extension contract is identified, but a
  provider- or deployment-specific implementation is intentionally outside the
  0.4.0 core.
- **Adapter**: the core defines the contract; provider-specific coverage may be
  delivered separately.
- **Deferred experimental**: the corresponding upstream feature is
  experimental or outside the 0.4.0 runtime contract and is not represented as
  silently supported.

The upstream comparison follows the current ADK capability families. It
compares externally visible behavior, not Python/Go class names: an Erlang
workflow is expected to use supervised processes, monitors, immutable messages,
and explicit ownership where those are the stronger BEAM-native contract.
The primary references are the official
[LLM agent guide](https://adk.dev/agents/llm-agents/),
[custom tool guide](https://adk.dev/tools-custom/),
[sequential workflow guide](https://adk.dev/agents/workflow-agents/sequential-agents/),
[graph workflow guide](https://adk.dev/graphs/),
[resume guide](https://adk.dev/runtime/resume/),
[runtime web interface](https://adk.dev/runtime/web-interface/), and
[tool-authentication guide](https://adk.dev/tools-custom/authentication/).
Experimental upstream surfaces are identified from the official
[Agent Config](https://adk.dev/agents/config/),
[Visual Builder](https://adk.dev/visual-builder/), and
[Skills](https://adk.dev/skills/) pages.

No row should be changed to **Implemented** until its README example, failure
behavior, EUnit/Common Test coverage, and Dialyzer checks pass.

The branch-start 2026-07-13 deterministic gate passed 573 EUnit tests, four
Common Test scenarios, and Dialyzer over 131 project files. The completed 0.4
clean gate passes 654 EUnit tests, four Common Test scenarios (including 1,000
stable correlated invocations), and warning-free Dialyzer analysis over 134
project files. Packaging, `adk doctor`, and checked agent-config validation
also pass. The separate billable live Gemini gate ran all 14 scenarios with
`gemini-3.1-flash-lite`: 13 passed, and Google Search grounding failed after
the bounded retry also received HTTP 429. Live results supplement and are not
counted as deterministic coverage.

## Build agents

| Capability family | 0.4.0 development status | Erlang-native contract |
| --- | --- | --- |
| LLM agents and static instructions | Implemented | Agent contracts compile once as immutable configuration. Fresh `invoke/3` calls use exact `{app_name, user_id, session_id}` lanes: one lane is FIFO, different lanes overlap up to a bounded default of 32, and ready lanes are admitted fairly. Unscoped fresh calls use one deterministic lane; direct compatibility calls retain their separate stateful FIFO. Model-visible tools are assessed separately below. |
| Dynamic/global instructions and state/artifact templating | Implemented | Static and bounded dynamic instructions resolve per invocation from an exact, secret-scrubbed scope without mutating agent configuration. A root `global_instruction` is prepended locally and carried explicitly across delegated BEAM-process boundaries; a child uses its own global instruction only when independently invoked as a root. |
| Input/output schemas and structured output | Implemented | Inputs are rejected before provider execution; final output and callback replacements are validated before an `output_key` delta is committed in the same final event. The opaque session-service reference follows the caller scope, so the write targets the invocation session rather than the reusable agent's configured default. |
| Provider-neutral generation configuration | Implemented | Common generation options are validated, normalized, and checked against discovered provider capabilities instead of being silently ignored. Gemini rejects unknown provider/nested-generation keys, maps validated adjustable safety settings, and supports strict `googleSearch` grounding with bounded candidate metadata persisted on correlated events. |
| Planning and replanning | Implemented | Gemini model-native thinking is available through validated agent generation config. The public explicit-planning API runs versioned JSON-safe plans through trusted planner/executor adapters with monitored callbacks, step/replan/deadline/heap/byte limits, owner-bound cancellation, and secret-pruned results; plan data cannot select modules or execute source. |
| Multi-agent delegation and routing | Partial | Sub-agent calls use fresh invocation history and a private bounded ancestry path. Spawn validates strict model-visible names, tree-wide uniqueness, ownership, cycles, 256-node/64-depth limits, child availability, and walk deadline. A child retains its own provider/model/tools/callbacks while receiving only scoped state/session-service and app/user/session/invocation/artifact identity, the root global-instruction source, and the private path; provider credentials and compatibility memory do not cross. Typed workflow dispatch also checks that a registry result reports the compiled canonical runtime name. AgentTool returns to its caller; one unified model-selected transfer-versus-call event/cancellation contract remains open. |
| Sequential workflow | Partial | `{output, Output, Delta}` commits and supplies `Output` as the next step's `Context.input`; `{stop, ...}` and legacy `{complete, ...}` terminate. Checkpoints restore committed output without replay. Nested child pauses bubble and resume through sequential parents. Per-action timeout/retry and root schemas are supported, but retry attempts are not durably checkpointed. |
| Parallel workflow | Partial | Explicit concurrency bounds, monitored workers, declared-order collection, deterministic state merge, deadlines, and sibling cleanup exist. Branch outputs form a deterministic `#{BranchId => Output}` result. A nested workflow pause inside a top-level parallel branch is not yet checkpoint-resumable. |
| Loop workflow | Partial | Predicates, iteration/step bounds, one deadline, cancellation, and resumable state exist. Reaching `max_iterations` is normal bounded completion and preserves the last output. A nested workflow pause inside a top-level loop body is not yet checkpoint-resumable. |
| Collaborative workflow | Partial | Declared ownership, JSON-safe handoff state, transfer events, stable identity, output propagation, a transfer budget, and invocation-scoped member calls exist. A nested workflow pause inside a transfer member is not yet checkpoint-resumable, and the broader model-selected transfer event contract remains open. |
| Graph workflows and dynamic routes | Partial | Typed nodes, validated edges, target allow-lists, explicit output/stop semantics, successor input propagation, versioned fork output/delta records, deterministic join-input maps, bounds, and checkpoints exist. Nested workflow pauses bubble through graph workflow nodes and workflow branches in graph forks without replaying the paused child; a concurrently in-flight sibling cancelled before commit is at-least-once and reruns after resume. Retry budgets reset when an uncommitted live node is cancelled and later resumed. |
| Dynamic/code-defined workflows | Partial | Trusted Erlang functions may build specs and choose a target from a compiled allowlist. This is safe code-defined construction and bounded routing, not a complete dynamic workflow contract; runtime data cannot select a module or execute source. |
| Agent routing | Partial | Registered binary identities, validated ownership trees, private cycle-safe delegation paths, transfer budgets, graph route functions, and policy allow-lists provide deterministic primitives. A unified model-selected delegation/transfer contract remains incomplete; automatic router products are adapters. |
| Human input and action confirmation | Partial | Durable invocation-scoped suspension and single-claim supervised resume exist. Nested workflow pauses propagate through sequential parents, graph workflow nodes, and graph fork workflow branches; top-level parallel, loop, and transfer nesting remains open. Generic tool-confirmation status is tracked separately under Components. |
| Declarative Agent Config | Partial | Checked JSON agent configuration is supported by the `adk` CLI and rejects embedded secrets. It is not presented as compatible with upstream's experimental YAML schema or Python-only generated tool modules. |

## Run agents

| Capability family | 0.4.0 development status | Erlang-native contract |
| --- | --- | --- |
| Sync, async, streaming runs | Implemented | One independently supervised invocation per accepted run. Provider streaming executes outside the agent mailbox; correlated partials are replayable while one immutable final snapshot supplies the outcome exactly once. |
| Stable run ID, status, subscribe, replay, await | Implemented | Bounded replay, credit/ack delivery, explicit replay gaps, and subscriber monitoring; browser/caller lifetime is detached. |
| Cancel and absolute deadlines | Implemented | Cancellation reaches monitored workers and every run commits exactly one terminal outcome. |
| Resume agents | Implemented | Multiple pauses are correlated by invocation ID; a paused stable run resumes as one linked supervised run and replay is rejected. |
| Runtime configuration and admission control | Implemented | One supervised controller enforces monitored global/per-agent permits with immediate reject or bounded oldest-eligible FIFO queueing, absolute deadlines, cancellation, and owner/caller crash cleanup. |
| Web interface | Implemented | Opt-in dependency-free Erlang UI supports chat, traces, session inspection, cancellation, bounded credit-based replay/reconnect, and approval/resume. |
| Command line and API server | Implemented | Authenticated REST/SSE replay plus `run`, `serve`, `inspect`, `cancel`, `resume`, `evaluate`, `config validate`, and `doctor` CLI commands are packaged in the `adk` escript. |
| Visual workflow builder | Deferred experimental | The upstream visual builder and its Agent Config format are experimental. Erlang ADK 0.4.0 provides an inspectable developer UI and declarative workflow APIs, but does not claim drag-and-drop code generation. |
| Ambient/background agents | Implemented | The local/event runtime owns stable event references, bounded concurrency/queue/retention/bytes/waiters, one absolute deadline, idempotency, monitored retry, status/await/cancel, and explicit per-event/explicit/shared session policy. A supervised fixed-delay source is included; `adk_trigger_source` keeps Pub/Sub, Eventarc, Kafka, RabbitMQ, and cloud scheduler transports as backpressured application adapters without SDK dependencies. Durable distributed dedupe/trigger registration and provider delivery acknowledgements remain adapter responsibilities. |

## Components

| Capability family | 0.4.0 development status | Erlang-native contract |
| --- | --- | --- |
| Function tools and agent tools | Partial | Erlang modules and dynamic toolsets compile normalized schemas into an immutable versioned catalog snapshot; module schemas are cached by loaded BEAM version. Duplicate/invalid schemas identify their sources, complete provider call batches and arguments are validated before callbacks or side effects, and dynamic removal fails closed as `tool_catalog_changed`. `refresh/1` builds a replacement snapshot, but a running agent cannot atomically swap catalogs, so additions are not advertised until recreation/replacement. AgentTool calls use invocation-scoped history and the same argument boundary. |
| Parallel tool performance | Partial | Runner executes only explicitly parallel-safe tools with bounded fan-out and stable result order. The direct compatibility path and catalog-wide callback/error semantics are not yet aligned. |
| Long-running tools | Partial | Runner provides invocation/action correlation, atomic single-claim terminal resume, correlated non-terminal updates, and Mnesia restart/resume coverage. An already-consumed continuation is rejected rather than returning an identical cached result, and non-Runner agent or typed-workflow tool paths do not provide universal durable continuation parity. |
| Per-call tool confirmation | Partial | Modules support static and argument-aware confirmation callbacks, and dynamic calls may carry validated internal confirmation metadata. After schema and runtime-policy checks, a required call becomes a serial/parallel barrier before lifecycle callbacks and execution. Dynamic metadata is obtained from a policy-admitted resolver, which may acquire scoped credentials but must remain free of business side effects. A resolved local module's declaration is combined fail-closed with metadata, preventing a toolset alias from weakening confirmation or ancestry. Runner/stable-run pauses with an opaque action ID; invalid boolean replies preserve the continuation, approval freshly resolves and rechecks policy before exactly one execution, and rejection returns a correlated structural response without callbacks or execution. Restoration failures are reported explicitly. A confirmed tool may enter a second long-running pause. The developer UI sends the typed boolean payload. Non-Runner agent execution (`prompt`, fresh `invoke`, delegation, and AgentTool-backed child calls) and typed-workflow tool actions fail closed with `tool_confirmation_requires_runner`; structured modify payloads and non-Runner pause/resume are not implemented. |
| Tool authentication | Partial | Per-principal credentials use opaque references and private storage, and OpenAPI auth is routed out of band. A catalog-wide proof that no schema/callback/error path can expose credentials and broader adapter behavior remain incomplete. |
| OpenAPI toolsets | Partial | OpenAPI 3.0/3.1 compilation, local references, deterministic schemas, JSON operations, SSRF-resistant Gun transport, and API-key/bearer/OAuth routing are covered. Catalog-wide argument semantics, dynamic authentication behavior, and broader media/auth schemes are not claimed. |
| MCP tools | Partial | Supervised stdio and Streamable HTTP clients plus a bounded loopback-first server implement the covered lifecycle, schema, resource, prompt, JSON-RPC, Origin, auth, body, deadline, and concurrency cases. After HTTP session loss, only allowlisted read-like operations are retried automatically. `tools/call` and unknown/mutating methods establish a replacement session but return `{mcp_session_lost, request_not_replayed}`. HTTP request serialization, bounded pending work, and live catalog replacement remain open. |
| Versioned artifacts | Implemented | Scoped immutable versions, metadata/digest, ETS and filesystem adapters, lazy context references. |
| Sessions and scoped state | Partial | ETS/Mnesia scopes, HMAC snapshot cursors, filters, pagination, and immutable rewind/branch are implemented; schema migration and configurable conflict policies remain explicit adapters. |
| Events | Implemented | Versioned JSON-safe schema with checked encoding and legacy decoding. |
| Long-term memory | Implemented | Explicit retrieval/ingestion policy and bounded adapter calls; richer ranking and managed adapters remain application integrations. |
| Context filtering and token budgeting | Implemented | Secret-scrubbed deterministic event selection, bounded byte/token estimates, filters, and explicit error/truncation are integrated into Runner; exact provider token accounting remains provider-specific. |
| Context compression and caching | Implemented | Compression runs in a monitored, time/heap/output-bounded worker and produces stable secret-free cache identities; managed/provider cache adapters remain. |
| App callbacks | Implemented | Existing local callbacks remain compatible. Runner-global plugins precede corresponding local callbacks, intervention skips the local callback, and local callbacks run in monitored timeout/heap-bounded workers over credential-free projected values. |
| Plugins | Implemented | Ordered Runner-global run/agent/model/tool/event/error hooks compile once, run in monitored timeout/heap-bounded processes, support open/closed failures and observe/intervene modes, and preserve final event/schema invariants. |
| Agent skills | Deferred experimental | Upstream Skills are experimental. A future adapter must provide incremental discovery/loading plus an explicit filesystem/remote trust policy; 0.4.0 does not reinterpret ordinary prompts or MCP resources as Skills. |
| Agent optimization | Adapter | Eval sets, trajectories, metrics, judges, and saved results provide the measurement contract. Automated instruction mutation/samplers and provider-specific optimizers are separate, auditable adapters. |

## Interoperability, operations, and safety

| Capability family | 0.4.0 development status | Erlang-native contract |
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
