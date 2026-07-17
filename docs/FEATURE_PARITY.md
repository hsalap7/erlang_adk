# ADK behavior-parity matrix

This is the release feature inventory for Erlang ADK 0.7.0. It records the
behavior proved by the final v0.7 release gates together with every explicitly
partial, adapter-owned, or deferred capability. It follows the externally
observable capability families in
the official [Agent Development Kit documentation](https://adk.dev/), while deliberately
using OTP processes, supervision, monitors, and message passing instead of
copying another language's object model.

Status meanings:

- **Implemented**: public Erlang API and deterministic coverage exist.
- **Partial**: useful, release-safe core behavior exists, but this upstream
  capability family is not claimed in full. The documented omissions are not
  necessarily blockers for the Erlang 0.7.0 contract.
- **In progress**: an implementation slice is present or being developed, but
  its required deterministic gate has not completed and no release claim is
  made yet.
- **Planned**: the behavior contract is identified for 0.7.0, but it is not
  implemented yet.
- **Planned adapter**: the core extension contract is identified, but a
  provider- or deployment-specific implementation is intentionally outside the
  0.7.0 core.
- **Adapter**: the core defines the contract; provider-specific coverage may be
  delivered separately.
- **Deferred experimental**: the corresponding upstream feature is
  experimental or outside the 0.7.0 runtime contract and is not represented as
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
[tool-authentication guide](https://adk.dev/tools-custom/authentication/);
the 0.5 data/context comparison also uses the official
[artifact guide](https://adk.dev/artifacts/),
[memory guide](https://adk.dev/sessions/memory/),
[context guide](https://adk.dev/context/),
[compaction guide](https://adk.dev/context/compaction/), and
[context-caching guide](https://adk.dev/context/caching/).
The 0.7 comparison additionally uses the official
[streaming/Live guide](https://adk.dev/streaming/),
[plugin guide](https://adk.dev/plugins/),
[evaluation guide](https://adk.dev/evaluate/), and
[observability guide](https://adk.dev/observability/).
Experimental upstream surfaces are identified from the official
[Agent Config](https://adk.dev/agents/config/),
[Visual Builder](https://adk.dev/visual-builder/), and
[Skills](https://adk.dev/skills/) pages.

An 0.7 row is marked **Implemented** only when its README example, failure
behavior, EUnit/Common Test coverage, and Dialyzer checks pass.

The completed 0.4 clean gate passed 654 EUnit tests, four Common Test scenarios
(including 1,000 stable correlated invocations), and warning-free Dialyzer
analysis over 134 project files. The final 0.5 clean gate passed 765 EUnit
tests, six Common Test scenarios, and warning-free Dialyzer over 160 project
files. The final v0.6 clean gate passed 899 EUnit tests, six Common Test
scenarios, and warning-free Dialyzer over 170 project files. Escript packaging,
`adk doctor`, checked agent-config validation, focused README/stress gates, 46
Phoenix tests, production assets, Phoenix release assembly, and a loopback
production-release health check in both trusted-proxy and direct-TLS modes
also passed. The full opt-in billable REST `gemini-3.1-flash-lite` run passed
14 of 16 cases;
Google Search grounding and context-cache creation are explicit HTTP 429
quota/rate-limit failures after one bounded retry, with no skips. Skips and
provider/quota failures are not counted as passes. The Phoenix dependency
audit remains non-zero for the two documented Cowlib 2.18.0 advisories and is
recorded as an explicit exception, not a passing gate.

The final 2026-07-16 v0.7 clean Erlang gate passes 1,176 EUnit tests, six
deterministic Common Test cases, 73.88% aggregate Erlang line coverage against
the enforced 73% floor, and warning-free Dialyzer analysis over 210 project
files.
Escript packaging, `adk doctor`, checked agent-config validation, all 29 README
tests, all four workflow tests, three warning-as-error example-module runtime
smokes, 193 focused v0.7 tests, and both 1,000-run stress suites also pass. The
billable REST GenerateContent/SSE suite and the separately billable Gemini
Live WebSocket suite remain opt-in and never count skips, quota failures, or
provider failures as passes. The final v0.7 provider runs pass all five Gemini
Live cases and 15 of 17 REST cases with no skips; Search grounding and context-
cache creation each fail explicitly on HTTP 429 after one bounded retry.

## Build agents

| Capability family | 0.7.0 status | Erlang-native contract |
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

| Capability family | 0.7.0 status | Erlang-native contract |
| --- | --- | --- |
| Sync, async, streaming runs | Implemented | One independently supervised invocation per accepted run. Provider streaming executes outside the agent mailbox; correlated partials are replayable while one immutable final snapshot supplies the outcome exactly once. |
| Stable run ID, status, subscribe, replay, await | Implemented | Bounded replay, credit/ack delivery, explicit replay gaps, and subscriber monitoring; browser/caller lifetime is detached. |
| Cancel and absolute deadlines | Implemented | Cancellation reaches monitored workers and every run commits exactly one terminal outcome. |
| Resume agents | Implemented | Multiple pauses are correlated by invocation ID; a paused stable run resumes as one linked supervised run and replay is rejected. |
| Runtime configuration and admission control | Implemented | One supervised controller enforces monitored global/per-agent permits with immediate reject or bounded oldest-eligible FIFO queueing, absolute deadlines, cancellation, and owner/caller crash cleanup. |
| Local developer web interface | Implemented local tool | The opt-in dependency-free Erlang `/dev` UI supports chat, traces, session inspection, cancellation, bounded run replay, approval/resume, redacted resource diagnostics, exact-principal Live status/text/future-only SSE, evaluation render/compare, and content-free observability snapshots. Run SSE reconnects from its bounded cursor; Live SSE explicitly rejects `Last-Event-ID` and never claims media/event replay. Every startup path is loopback-only, inputs/outputs are bounded, and unknown pause types fail closed. Its shared bearer is local administrator authentication, not per-user production authorization; the Live bearer cannot bypass the session's exact-principal digest check. |
| Production web gateway | Implemented bounded companion surface | `adk_scope_authorizer` validates issuer-bound principals and exact operation scopes. `adk_web_gateway` retains the server-owned stable-run catalog and owner scope. The v0.7 Phoenix `LiveGateway` separately authorizes `adk.live.read`, `adk.live.control`, `adk.observability.read`, and `adk.evaluation.read`, discovers only server-owned same-BEAM sessions/reports, uses future-only credit/ack, removes media bytes/signatures before LiveView assigns, and rejects browser-selected principals/modules/paths. Its exact-origin binary voice socket revalidates the opaque web session per frame and uses one bounded core bridge per connection for 16 kHz microphone ingress, native PCM playback, exact output ACKs, and interruption. Exact-scope artifact/memory/context administration, Live session creation/configuration, evaluation execution, and durable audit/revocation remain separate privileged APIs/adapters. |
| Command line and API server | Implemented | Authenticated REST/SSE plus `run`, `serve`, scoped `inspect` (including context lifecycle, Live and observability), exact cache-scope invalidation, Live text send, artifact delete, memory search/erase, `cancel`, `resume`, legacy `evaluate`, versioned `eval run`, `config validate`, and `doctor` are packaged in the `adk` escript. `eval run` supports repeats, baseline CI gates, JSON/Markdown, and exit codes 0/2/1. Destructive calls require an exact matching confirmation object. |
| Visual workflow builder | Deferred experimental | The upstream visual builder and its Agent Config format are experimental. Erlang ADK 0.7.0 provides inspectable developer/Phoenix surfaces and declarative workflow APIs, but does not claim drag-and-drop code generation. |
| Ambient/background agents | Implemented | The local/event runtime owns stable event references, bounded concurrency/queue/retention/bytes/waiters, one absolute deadline, idempotency, monitored retry, status/await/cancel, and explicit per-event/explicit/shared session policy. A supervised fixed-delay source is included; `adk_trigger_source` keeps Pub/Sub, Eventarc, Kafka, RabbitMQ, and cloud scheduler transports as backpressured application adapters without SDK dependencies. Durable distributed dedupe/trigger registration and provider delivery acknowledgements remain adapter responsibilities. |

## Components

| Capability family | 0.7.0 status | Erlang-native contract |
| --- | --- | --- |
| Function tools and agent tools | Partial | Erlang modules and dynamic toolsets compile normalized schemas into an immutable versioned catalog snapshot; module schemas are cached by loaded BEAM version. Duplicate/invalid schemas identify their sources, complete provider call batches and arguments are validated before callbacks or side effects, and dynamic removal fails closed as `tool_catalog_changed`. At the Gemini boundary only a small positive legacy subset uses `parameters`; schemas containing `oneOf`, `additionalProperties`, type unions, boolean subschemas, top-level boolean roots, or any unknown keyword use `parametersJsonSchema` without weakening local validation. Local modules may declare least-authority state/artifact/memory context operations and receive only a scope-bound opaque token; remote tools receive no local handles. Modules without a declaration retain an explicit 0.5 compatibility context. `refresh/1` builds a replacement snapshot, but a running agent cannot atomically swap catalogs, so additions are not advertised until recreation/replacement. AgentTool calls use invocation-scoped history and the same argument boundary. |
| Parallel tool performance | Partial | Runner executes only explicitly parallel-safe tools with bounded fan-out and stable result order. The direct compatibility path and catalog-wide callback/error semantics are not yet aligned. |
| Long-running tools | Partial | Runner provides invocation/action correlation, atomic single-claim terminal resume, correlated non-terminal updates, and Mnesia restart/resume coverage. An already-consumed continuation is rejected rather than returning an identical cached result, and non-Runner agent or typed-workflow tool paths do not provide universal durable continuation parity. |
| Per-call tool confirmation | Partial | Modules support static and argument-aware confirmation callbacks, and dynamic calls may carry validated internal confirmation metadata. After schema and runtime-policy checks, a required call becomes a serial/parallel barrier before lifecycle callbacks and execution. Dynamic metadata is obtained from a policy-admitted resolver, which may acquire scoped credentials but must remain free of business side effects. A resolved local module's declaration is combined fail-closed with metadata, preventing a toolset alias from weakening confirmation or ancestry. Runner/stable-run pauses with an opaque action ID; invalid boolean replies preserve the continuation, approval freshly resolves and rechecks policy before exactly one execution, and rejection returns a correlated structural response without callbacks or execution. Restoration failures are reported explicitly. A confirmed tool may enter a second long-running pause. The developer UI sends the typed boolean payload. Non-Runner agent execution (`prompt`, fresh `invoke`, delegation, and AgentTool-backed child calls) and typed-workflow tool actions fail closed with `tool_confirmation_requires_runner`; structured modify payloads and non-Runner pause/resume are not implemented. |
| Tool authentication | Partial | Per-principal credentials use opaque references and private bounded storage. Trusted immutable provider profiles enforce grant/scope/resource/TTL policy, single-flight refresh and CAS rotation run in supervised bounded workers, and OpenAPI credentials remain out of model-visible schemas and arguments. The bundled ETS store is volatile; durable encrypted storage, provider revocation, and a catalog-wide proof over every application callback remain adapters/open audit work. |
| OpenAPI toolsets | Partial | OpenAPI 3.0/3.1 compilation, local references, deterministic schemas, JSON operations, SSRF-resistant Gun transport, private immutable API-key/bearer/OAuth profiles, bounded concurrent auth workers, strict version parsing, redirect/method/IPv6 handling, and regression limits are covered. Broader media/auth schemes and complete OpenAPI semantics are not claimed. |
| MCP tools | Partial | Supervised stdio and MCP 2025-11-25 Streamable HTTP clients plus a bounded loopback-first server implement the covered lifecycle, schema, resource, prompt, JSON-RPC, Origin, principal-bound session, version-negotiation, RFC 9728 metadata/challenge, TLS/DNS/redirect/token-isolation, body, deadline, and concurrency cases. Client authentication/DNS and server authentication/authorization/tool/resource/prompt callbacks are off-heap/heap/result bounded, use absolute completion timestamps and aliases, and die with their request owner. Clear HTTP is an explicit all-loopback opt-in; a non-loopback server requires authentication plus direct TLS or an explicit trusted-proxy assertion. After session loss, only allowlisted read-like operations are retried automatically; mutating calls are not replayed. Automatic client-side OAuth discovery/PKCE, incremental concurrent SSE delivery, and live catalog replacement remain open. |
| Versioned artifacts | Partial | Strict app/user/session scopes, monotonic immutable versions, shared validation, quotas, metadata pagination, deadline-aware writes, ETS/filesystem adapters, atomic reader-visible filesystem publication/repair, least-authority context helpers, metadata-only event effects, bounded one-next-request model attachment, and exact-scope developer inspect/delete are implemented. Name-page envelopes carry exact scope provenance; capability and developer projections reject an envelope or record whose embedded scope/name differs from the bound request, and malformed bare names also fail closed. Durable multi-instance-safe filesystem slots cap lifetime scopes per root and names per scope at `max_scan_entries div 2`; reservations cap versions per scoped name at `max_scan_entries div 3`. Exhaustion returns a scope/name/version-specific capacity error before listing/repair scan exhaustion, and deletion does not replenish these lifetime slots. Deterministic attachment persistence coverage and the targeted billable REST Gemini selection case pass. The direct reference adapters serialize operations per service process; the opt-in bounded `adk_artifact_sharded` wrapper instead gives each exact scope a stable supervised worker, preserves same-scope ordering, and lets unrelated scopes overlap over ETS or filesystem storage. A caller-monitor guard releases cold-route admission on death/timeout and prevents a stale queued route from creating an abandoned shard. Its quotas are per shard, not globally aggregated. Credit/ack blob streaming, portable directory-fsync guarantees, raw developer upload/download, and complete durable orphan recovery after event-persistence failure remain open. |
| Sessions and scoped state | Partial | ETS/Mnesia scopes, HMAC snapshot cursors, filters, pagination, and immutable rewind/branch are implemented; schema migration and configurable conflict policies remain explicit adapters. |
| Events | Implemented | Versioned JSON-safe schema with checked encoding and legacy decoding. |
| Long-term memory | Partial | Versioned mandatory app/user scopes, bounded lexical ETS and durable local Mnesia adapters, structured provenance, stable idempotent event ingestion, hard adapter and Runner hit/byte bounds, safe untrusted framing, preload and model-selected retrieval, deadline-aware mutation, entry/session/user erasure, least-authority tools, and exact-scope developer search/erase are implemented. Capability and developer projections reject a successful add or any returned hit whose embedded app/user scope differs from the bound request; a rejected add creates no effect. Deterministic model-selected isolation coverage and the targeted billable REST Gemini tool case pass. A bounded Mnesia outbox and explicit Runner durable mode provide fail-closed durable admission, timeout-bounded stable adapter resolution, a renewed/revalidated ownership lease immediately before mutation, lease-owned idempotent at-least-once batches, checkpoints, and retry status. This is not an adapter-generation fence; retry safety relies on the v2 adapter's stable event IDs. The final session event exists before admission; an admission failure is returned to the run caller and is not a rollback. The `on_success` shorthand is process-local. The direct lexical adapters serialize ranking/storage per service process; the opt-in bounded `adk_memory_sharded` wrapper instead assigns each exact app/user scope a stable supervised worker, preserves same-scope ordering, and lets unrelated users overlap over ETS or Mnesia storage. A caller-monitor guard releases cold-route admission on death/timeout and prevents a stale queued route from creating an abandoned shard. Its quotas are per shard, not globally aggregated. Pending-outbox erasure coordination, managed vector search, and consent/retention policy remain application or adapter concerns. |
| Context filtering and token budgeting | Partial | Runner performs mandatory secret-key pruning, deterministic O(n) exchange-aware selection, canonical multimodal handling, event byte/token budgets, and a fail-closed complete-provider-envelope budget covering instructions, memory, history/current input, tools, parts, and framing. Selection/compression remains explicit; key pruning is not general PII detection, and provider-exact token estimators remain adapters. |
| Context compression and caching | Partial | Compression is owner/deadline/heap/input/output bounded and produces an explicit context fingerprint. Opt-in Runner compaction preserves complete recent exchanges and atomically replaces only an expected session prefix through the bundled ETS/Mnesia backends, persisting a versioned summary/checkpoint. An owner-bound provider-request-prefix cache provides TTL, single flight, isolation, invalidation, private leases, bypass/error policies, and an explicit Runner/Gemini contract without caching model answers. Before installing a provider result it synchronously rechecks every absolute waiter deadline; when all have expired, it deletes the orphan provider resource instead of retaining an unreachable entry. Deterministic exact-wire create/reuse/bypass/generate/stream coverage passes. In the final 2026-07-15 billable REST run, cached-content creation received HTTP 429 after its one bounded retry, so the case failed as rate-limited and is not a REST pass; 15 of the 17 REST cases passed, with Google Search grounding the other 429 failure. |
| App callbacks | Implemented | Existing local callbacks remain compatible. Runner-global plugins precede corresponding local callbacks; `{amend, Value}` continues into later plugins/local validation, while `{return, Value}` and legacy `{replace, Value}` are an early return that skip them. Local callbacks run in monitored timeout/heap-bounded workers over credential-free projected values. |
| Plugins | Implemented core | Up to 128 ordered Runner-global run/agent/model/tool/event hooks compile once with bounded IDs/configuration and run in monitored owner/deadline/heap/result-bounded workers. Open/closed failure policy, observe/intervene modes, explicit amend/return/halt, recoverable model/tool error phases, best-effort agent/run error notifications, success-only `after_run`, delegated plugin capsules, final event/schema invariants, supervised serialized stateful instances, and global-instruction/context-filter/reflect-retry/metadata built-ins are covered. Stateful initialization is isolated, all instance resource settings have hard maxima, and owner death prevents callback-state commit even when completion was dequeued first. A returned PID is an explicitly temporary identity, so a crash does not silently reset state behind a stale reference. Persistent/restarted/distributed plugin state and provider-specific plugins remain application adapters. |
| Agent skills | Deferred experimental | Upstream Skills are experimental. A future adapter must provide incremental discovery/loading plus an explicit filesystem/remote trust policy; 0.7.0 does not reinterpret ordinary prompts or MCP resources as Skills. |
| Agent optimization | Adapter | Eval sets, trajectories, metrics, judges, and saved results provide the measurement contract. Automated instruction mutation/samplers and provider-specific optimizers are separate, auditable adapters. |

## Interoperability, operations, and safety

| Capability family | 0.7.0 status | Erlang-native contract |
| --- | --- | --- |
| Incoming OIDC/OAuth/API authentication | Implemented release slice | Oidcc-backed signature/JWKS verification enforces issuer, access-token resource audience, algorithm, time, subject, claims, scopes, token type, and bounded input. OIDC ID-token mode separately applies authorized-party/client rules. The web gateway is default-deny for exact operations; MCP and A2A expose bounded per-operation policy hooks, and protocol resources are principal-bound. Applications must configure authoritative operation policy outside the RFC 9728 mode that requires it. IdP revocation, back-channel logout, and distributed session disconnect remain deployment integrations. |
| Outbound OAuth/API-key/bearer credentials | Implemented release slice | Private per-principal credentials, immutable trusted provider profiles, RFC 8707 resource targeting, bounded admission/cache/storage, supervised single-flight OAuth grants, CAS refresh-token rotation, explicit cache invalidation, and secret-free status/errors are covered. Provider revocation and a durable KMS/HSM-backed encrypted store remain adapters; ETS is explicitly a development/single-node store. |
| Google Application Default Credentials | Planned adapter | Follow ADC source precedence without mixing model, user, and service credentials. |
| A2A protocol | Hardened partial | Released A2A 1.0 Agent Card discovery and the six core JSON-RPC/SSE task methods have principal-scoped supervised execution, canonical errors, bounded extensions/card/data, absolute deadlines, isolated auth callbacks, and slow-subscriber overflow detachment. A public listener requires authentication plus direct TLS or an explicit trusted proxy. The client enforces verified HTTPS, all-loopback cleartext opt-in, bounded DNS/private-address and redirect policy, interface-origin validation, a satisfiable single declared security-scheme alternative, and discovery/RPC credential isolation. Authentication and DNS workers are heap/result bounded, suppress late replies, reject post-deadline queued results, and die with their request owner. Compound AND authentication is rejected as unsupported and server hook/card semantic alignment is operator policy. Outbound SSE is bounded but currently buffered; tasks and replay are node-local, and push notification is not enabled. The project-specific unauthenticated `/a2a/prompt` route remains legacy, separate, and startup-enforced loopback-only. |
| Observability | Implemented core | Legacy correlated `telemetry`/JSON-safe envelopes remain. Schema-v2 start/end spans now measure actual model, tool, and Live connect/receive boundaries with Unix nanoseconds plus monotonic duration. Strict W3C Trace Context extraction/injection, a pinned metadata-only OpenTelemetry GenAI Development mapping, bounded low-cardinality metrics, synchronous delivery, a supervised bounded-best-effort asynchronous bus with delayed transient retries/drop accounting, and a redirect-free OTLP/HTTP JSON traces/logs exporter are implemented. Content is default-off; the v2 GenAI mapper never accepts prompts, responses, media, arguments, or results. The registry/bus are node-local operational snapshots, not durable billing counters or a WAL; retries may duplicate and exhausted work is counted as dropped. Full OpenTelemetry SDK/vendor resource discovery remains an adapter. |
| Evaluation | Implemented core | Legacy evaluation remains. Set/result schema v2 adds full-case exact-response and exact/in-order/any-order/subset tool-trajectory criteria, exact/subset/ignored argument matching, explicit empty-criteria policy, repeated samples with deterministic IDs/distributions/min-success accounting, isolated per-case adapter lifecycle, strict nested/result/report bounds, stable JSON/Markdown, baseline regression comparison, and `adk eval run` CI exit semantics. The explicit first-party `adk_eval_llm_judge` defaults to `adk_llm_gemini`/`gemini-3.1-flash-lite`, requests and strictly validates bounded structured scores, records rubric/model/version metadata plus bounded rationale, and fail-closes provider errors without serializing concurrent sample workers. Custom metrics/judges remain extension points. Managed evaluation services, user/environment simulators, and automated instruction optimization are explicit provider/application adapters rather than hidden model calls. |
| Safety and policy | Implemented | Runner policies fail closed with deny-overrides-allow agent/tool rules, finite canonical argument/content budgets, post-resolution gates before callbacks/HITL, structural tool errors, secret-free telemetry, and canonical immutable denial audit events. Gemini request-level adjustable harm categories and thresholds are strictly validated and REST-encoded; non-adjustable provider protections remain provider-owned. Human confirmation remains the suspension mechanism. |
| Multimodal content | Implemented | Versioned JSON-safe text, bounded inline bytes, HTTPS/GCS file references, and function parts map to Gemini one-shot, SSE content, and Runner partial/final events without changing text-only APIs. MIME, base64, URI, JSON, role, part-count, and byte limits fail explicitly. |
| Google Search grounding | Implemented | Gemini GenerateContent accepts only the explicit `google_search` built-in, combines it safely with function declarations, and persists bounded, provider-discriminated JSON grounding metadata for one-shot and SSE results without breaking output schemas. Individual provider fields remain forward-compatible JSON rather than an Erlang-owned schema. Deterministic wire/metadata coverage passes; the 2026-07-15 billable REST case received HTTP 429 after its one bounded retry, so it failed as rate-limited rather than proving or disproving the behavior. URL Context, Maps, Enterprise Search, and the newer Interactions API remain explicit adapters. |
| Model routing and non-Gemini providers | Adapter | The provider behavior and capability negotiation are stable extension points. Automatic model fallback/routing and concrete Claude, Ollama, vLLM, LiteLLM, or managed-hosted adapters are not implied by the Gemini implementation. |
| Gemini Live | Implemented provider slice | A separate supervised `gen_statem` session protocol targets only `gemini-3.1-flash-live-preview`; the REST default remains `gemini-3.1-flash-lite`. It implements setup-before-input, text/current-v1beta `realtimeInput.audio` and `.video` ingress for 16 kHz PCM/JPEG/PNG, native 24 kHz PCM AUDIO output, input/output transcription, automatic/manual activity signaling, usage/grounding events, optional thinking/voice/media-resolution/context-compression/Google Search configuration, distinct interruption/generation/turn completion, GoAway/latest-handle resumption, fixed-v1beta-origin verified-TLS Gun flow control, exact-principal ownership, future-only byte/message credit, hard-capped per-session subscriber cardinality (64 default, 4096 hard maximum) with detach/death recovery, a race-safe supervisor-wide session ceiling (`live_session_limit`, 1024 default, 16384 hard maximum), bounded ingress/subscriber queues, and explicit manual or allowlisted bounded synchronous tool execution. A strict v1 owner-bound voice bridge adds monotonic 16 kHz PCM input, projected audio/transcription/lifecycle output, exact browser ACK credit, interruption signaling, and owner-death cleanup without exposing provider payloads. TLS uses the OS trust store or an explicit `cacertfile` and never falls back to `verify_none`. Sessions are server-owned and outlive starters. Disconnect drops and reports unacknowledged input/tool responses rather than replaying possible side effects. Browser-direct Gemini credentials/ephemeral-token sessions, proactive/affective audio, browser video capture, structured output/REST caching, durable/multi-node routing, Live event/media replay, a separate local CA-controlled TLS integration harness, and models beyond the pinned 3.1 preview are not claimed. REST SSE is never presented as Live support. |
| Deployment | Adapter | OTP releases/containers are core-neutral; Cloud Run/GKE/managed runtime guidance belongs in deployment adapters. |

## Developer web integration

Phoenix is compatible and remains a companion application rather than a core
dependency. The checked v0.7 Phoenix 1.8 project runs in the same BEAM release.
Its OIDC code/S256 PKCE boundary keeps login state and sessions in private
bounded server stores; every mount, action, and accepted event reauthorizes.
The existing `adk_web_gateway` owns stable runs and reconnect cursors. The new
server-configured `LiveGateway` owns exact-scope Live, observability, and
evaluation access: Live subscriptions are future-only, audio/video/signatures
are removed before assigns, and a separate authenticated binary socket uses one
bounded owner-bound bridge per browser voice connection. Core admission
requires an active session and one monitored bidirectional lease per Live
session; distinct sessions still run concurrently. A session-owned continuity
capability plus credit-independent invalidation prevents stale ingress and
lease retention across a fast reconnect, while ambiguous input/ACK deadlines
terminate the bridge. Socket authorization is checked on data/control/output
and a bounded timer, and browser worklet, socket, playback, transcript, and
server-credit queues are all finite. Reconnect tears down capture instead of
pretending to replay it. Operational snapshots are
content-free, and report
IDs resolve only through a trusted immutable catalog. Neither LiveView owns or
links the underlying run/session process. `/dev/v1` remains separate loopback
developer administration, not the production browser API. Node-local
session/run/Live routing, IdP single logout/revocation, browser video transport,
evaluation execution, privileged resource panels, and the documented Cowlib
audit exception remain explicit deployment/release limitations.
