# ADK behavior-parity matrix

This is the feature inventory for the released Erlang ADK 0.9.0 base plus the
0.10.0 implementation currently **IN DEVELOPMENT**. The released 0.9 evidence is
recorded in [`VERSION_0_9_0.md`](VERSION_0_9_0.md); the unreleased additions and
merged-candidate ledger are isolated in
[`VERSION_0_10_0.md`](VERSION_0_10_0.md). Development coverage is not a release,
paid-provider, or arbitrary-deployment claim.
It follows the externally observable capability families in
the official [Agent Development Kit documentation](https://adk.dev/), while deliberately
using OTP processes, supervision, monitors, and message passing instead of
copying another language's object model.

Status meanings:

- **Implemented**: public Erlang API and deterministic coverage exist.
- **Partial**: useful, release-safe core behavior exists, but this upstream
  capability family is not claimed in full. The documented omissions are not
  necessarily blockers for the released Erlang 0.9.0 contract.
- **In progress**: an implementation slice is present or being developed, but
  its required deterministic gate has not completed and no release claim is
  made yet.
- **Planned**: the behavior contract is identified for a future milestone but
  is not implemented yet.
- **Planned adapter**: the core extension contract is identified, but a
  provider- or deployment-specific implementation is intentionally outside the
  current core.
- **Adapter**: the core defines the contract; provider-specific coverage may be
  delivered separately.
- **Deferred experimental**: the corresponding upstream feature is
  experimental or outside the current runtime contract and is not represented
  as silently supported.

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
The 0.8 provider comparison uses the official
[OpenAI Responses reference](https://platform.openai.com/docs/api-reference/responses),
[OpenAI Realtime WebSocket guide](https://developers.openai.com/api/docs/guides/realtime-websocket),
[Anthropic Messages reference](https://platform.claude.com/docs/en/api/messages/create),
and [Anthropic streaming guide](https://platform.claude.com/docs/en/build-with-claude/streaming).
Experimental upstream surfaces are identified from the official
[Agent Config](https://adk.dev/agents/config/),
[Visual Builder](https://adk.dev/visual-builder/), and
[Skills](https://adk.dev/skills/) pages.

A released addition is marked **Implemented** only when its public contract and
dedicated deterministic coverage exist in released source. An unreleased 0.10
addition is labeled **In development** even when focused tests pass; the final
candidate gate and approval have not completed. A fixture is not evidence that
a paid remote model or arbitrary compatible endpoint works.

The comparison baseline is important: 0.9 already shipped versioned artifacts
and Runner-integrated long-term memory, evaluation v2, MCP clients over stdio
and Streamable HTTP plus a bounded server, the local Developer UI and Phoenix
companion, A2A 1.0, and partial declarative Agent Config. Version 0.10 adds
supervised/configurable foundations around those implementations; it does not
introduce those families for the first time.

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
provider/quota failures are not counted as passes. At that recorded gate, the
Phoenix dependency audit was non-zero for the two documented Cowlib 2.18.0
advisories and was recorded as an explicit exception, not a passing gate.

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

The final 2026-07-17 v0.8 deterministic gate passed 1,414 EUnit tests, six
Common Test cases, Dialyzer over 235 source modules with no warnings, and 74.17% line
coverage. Common Test intentionally skipped 22 opt-in paid cases in that
deterministic command. The focused provider/profile/Realtime set passed
244/244; the seven-module post-audit repair set passed 67/67; 30 README plus
four workflow tests passed, all three example modules compiled with warnings
as errors, and xref, escript, doctor/configuration, documentation, package,
and extracted-package gates passed. The Phoenix
companion passed 103 ExUnit and 40 Node tests, production assets/release, and
proxy/direct-TLS smokes. Its raw audit remained non-zero only for the same two
documented Cowlib advisories, and the exact-exception verifier passed.
The 67/67 repair set confirms that an in-flight multi-frame Live batch remains
contiguous despite later priority actions, Anthropic requires
`max_tokens >= 1`, and synchronous and streaming Gun paths both cap aggregate
header/trailer blocks at 64 KiB.

The opt-in Gemini REST attempt reached Google but failed HTTP 401
`UNAUTHENTICATED` / `ACCESS_TOKEN_TYPE_UNSUPPORTED` because the configured
credential shape was rejected. That is an external credential failure, not a
pass, skip, or product regression. No v0.8 paid Gemini Live pass is recorded;
deterministic REST and Live protocol tests remain separate from remote-provider
evidence. No paid OpenAI or Anthropic result is claimed. Historical v0.7
evidence remains separate above.

The 0.9 release adds definition-bound checkpoint v2, durable attempts,
ordered lifecycle events, nested continuation parity, typed-workflow tool
confirmation, graph analysis/inspection, join policies, node schemas, state
reducers, constrained loopback-compatible endpoints, and native Vertex/ADC.
The deterministic release validation compiled 242 production and 271 test
modules with `-Werror`, passed all 1,495 EUnit tests and all 6 Common Test cases,
reported 0 Dialyzer warnings, and reported 0 undefined or deprecated
call/function findings from `./rebar3 xref`. The Phoenix companion passed
103 ExUnit tests, 40 browser/audio tests, production assets/release, and both
release health smokes. No package, coverage, or new paid-provider result is
claimed for this release.

## Build agents

| Capability family | Current status | Erlang-native contract |
| --- | --- | --- |
| LLM agents and static instructions | Implemented | Agent contracts compile once as immutable configuration. Fresh `invoke/3` calls use exact `{app_name, user_id, session_id}` lanes: one lane is FIFO, different lanes overlap up to a bounded default of 32, and ready lanes are admitted fairly. Unscoped fresh calls use one deterministic lane; direct compatibility calls retain their separate stateful FIFO. Model-visible tools are assessed separately below. |
| Dynamic/global instructions and state/artifact templating | Implemented | Static and bounded dynamic instructions resolve per invocation from an exact, secret-scrubbed scope without mutating agent configuration. A root `global_instruction` is prepended locally and carried explicitly across delegated BEAM-process boundaries; a child uses its own global instruction only when independently invoked as a root. |
| Input/output schemas and structured output | Implemented | Inputs are rejected before provider execution; final output and callback replacements are validated before an `output_key` delta is committed in the same final event. The opaque session-service reference follows the caller scope, so the write targets the invocation session rather than the reusable agent's configured default. Gemini, Vertex, and OpenAI use their native checked schema forms, Anthropic uses GA `output_config.format`, and compatible endpoints use an explicit response-format mode which an operator profile can lock to `unsupported`. Remote compatible behavior still needs endpoint-specific evidence. |
| Provider-neutral generation configuration | Implemented | Common generation options are validated, normalized, and checked against adapter capability declarations instead of being silently ignored. Gemini retains strict nested generation/safety/Search behavior. Bounded binary provider/model aliases resolve operator-owned adapter, endpoint, credential, API/auth/privacy settings, and capability ceilings; caller allowlists retain only adapter-specific inference/runtime options. Profile-selected Live capabilities are intersected with the selected adapter ceiling, including its trusted audio rate. Direct atom-module configuration remains a trusted-code compatibility path. |
| Planning and replanning | Implemented | Gemini model-native thinking is available through validated agent generation config. The public explicit-planning API runs versioned JSON-safe plans through trusted planner/executor adapters with monitored callbacks, step/replan/deadline/heap/byte limits, owner-bound cancellation, and secret-pruned results; plan data cannot select modules or execute source. |
| Multi-agent delegation and routing | Partial | Sub-agent calls use fresh invocation history and a private bounded ancestry path. Spawn validates strict model-visible names, tree-wide uniqueness, ownership, cycles, 256-node/64-depth limits, child availability, and walk deadline. A child retains its own provider/model/tools/callbacks while receiving only scoped state/session-service and app/user/session/invocation/artifact identity, the root global-instruction source, and the private path; provider credentials and compatibility memory do not cross. Typed workflow dispatch also checks that a registry result reports the compiled canonical runtime name. AgentTool returns to its caller; one unified model-selected transfer-versus-call event/cancellation contract remains open. |
| Sequential workflow | Partial | `{output, Output, Delta}` commits and supplies `Output` as the next step's `Context.input`; `{stop, ...}` and legacy `{complete, ...}` terminate. Checkpoint v2 restores committed output and durable attempt numbers without replay. Nested child pauses and typed tool confirmations bubble and resume through sequential parents. Root schemas and per-key state reducers are supported. |
| Parallel workflow | Partial | Explicit concurrency bounds, monitored workers, declared-order collection, deterministic state merge, deadlines, and sibling cleanup exist. Branch outputs form a deterministic `#{BranchId => Output}` result. Nested workflow and typed tool-confirmation pauses are checkpoint-resumable; an uncommitted sibling cancelled to make the pause durable remains at least once and may rerun. |
| Loop workflow | Partial | Predicates, iteration/step bounds, one deadline, cancellation, and resumable state exist. Reaching `max_iterations` is normal bounded completion and preserves the last output. Nested workflow and typed tool-confirmation pauses in the loop body are checkpoint-resumable. |
| Collaborative workflow | Partial | Declared ownership, JSON-safe handoff state, transfer events, stable identity, output propagation, a transfer budget, and invocation-scoped member calls exist. Nested workflow and typed tool-confirmation pauses in a transfer member are checkpoint-resumable; the broader model-selected transfer event contract remains open. |
| Graph workflows and dynamic routes | Partial | Typed nodes/joins, whole-graph validation and warnings, target allow-lists, explicit output/stop semantics, successor input propagation, root/per-node schemas, state reducers, durable attempts, definition-bound checkpoint v2, and non-executable JSON/DOT/Mermaid inspection exist. Forks support `all`, `any`, `first_success`, and quorum completion. Nested workflow and typed tool-confirmation pauses resume through graph nodes/forks without replaying committed child work; uncommitted cancelled sibling effects remain at least once. This is not an arbitrary multi-node branch-region scheduler. |
| Dynamic/code-defined workflows | Partial | Trusted Erlang functions may build specs and choose a target from a compiled allowlist. This is safe code-defined construction and bounded routing, not a complete dynamic workflow contract; runtime data cannot select a module or execute source. |
| Agent routing | Partial | Registered binary identities, validated ownership trees, private cycle-safe delegation paths, transfer budgets, graph route functions, and policy allow-lists provide deterministic primitives. A unified model-selected delegation/transfer contract remains incomplete; automatic router products are adapters. |
| Human input and action confirmation | Partial | Durable invocation-scoped suspension and single-claim supervised resume exist. Nested workflow pauses propagate through sequential, parallel, loop, transfer, graph workflow nodes, and graph-fork branches. Typed workflow tool actions emit correlated confirmation pauses and fail closed on rejection, invalid input, or action mismatch. Generic agent-tool confirmation status is tracked separately under Components. |
| Declarative Agent Config | Implemented Erlang slice; 0.10 in development | The reusable schema-v2 `adk_agent_config:compile/1,2` and `load_file/1,2` accept checked JSON or a strict YAML subset and retain schema-1 compatibility. Both formats normalize to one IR/fingerprint against the same immutable sealed registry snapshot. Schema 2 adds data-only agent-template, credential-profile, runtime-policy, bounded sub-agent-tree, and workflow references; `adk_agent_composition` resolves the exact snapshot and materializes the tree bottom-up without returning credential descriptors. Registry kinds are provider, MCP, OpenAPI, tool pack, credential, runtime policy, workflow, and agent template. Opaque lineage/revision IDs and generation supply provenance without content/secret digests. Names share the runtime grammar, reserve `user`, and cap at 256 bytes. Toolset references cap at 64, reject duplicates, and use one authenticated bulk lookup. Embedded transport targets, commands, headers, and secrets are rejected; direct tool/provider modules remain trusted legacy opt-ins. YAML anchors, aliases, tags, directives, merge keys, multi-document input, and non-JSON scalars fail closed. This is not a visual builder, code generator, or exact-compatibility claim for another ADK's config dialect. |

## Run agents

| Capability family | Current status | Erlang-native contract |
| --- | --- | --- |
| Sync, async, streaming runs | Implemented | One independently supervised invocation per accepted run. Provider streaming executes outside the agent mailbox; correlated partials are replayable while one immutable final snapshot supplies the outcome exactly once. |
| Stable run ID, status, subscribe, replay, await | Implemented | Bounded replay, credit/ack delivery, explicit replay gaps, and subscriber monitoring; browser/caller lifetime is detached. |
| Cancel and absolute deadlines | Implemented | Cancellation reaches monitored workers and every run commits exactly one terminal outcome. |
| Resume agents | Implemented | Multiple pauses are correlated by invocation ID; a paused stable run resumes as one linked supervised run and replay is rejected. |
| Runtime configuration and admission control | Implemented | One supervised controller enforces monitored global/per-agent permits with immediate reject or bounded oldest-eligible FIFO queueing, absolute deadlines, cancellation, and owner/caller crash cleanup. |
| Runtime service profiles | 0.10 foundation in development | `adk_runtime_service_profile` strictly selects `ephemeral_local` (ETS) or `durable_local` (Mnesia session/memory plus filesystem artifacts) without accepting configuration-selected modules. The durable profile adds a private Mnesia memory outbox to the atomic bundle generation: strict nested option/capability validation, deterministic registry hydration, identity-filtered bounded rotating claims, four-table constant-row health, redacted status, epoch-bound job IDs, and a hard active-plus-terminal reservation. Jobs survive bundle restart while stale/unhealthy references fail closed; explicit majority mode requires at least two nodes shared by all tables. Legacy named APIs route to the one private owner without a duplicate processor, while disabled/ephemeral profiles retain standalone compatibility. `erlang_adk:runtime_runner_spec/0` supplies authoritative services and durable ingestion to standard CLI run/console, evaluation-agent, and developer HTTP paths. The durable profile requires an absolute artifact root. These are local built-ins, not managed cloud services or distributed-storage orchestration. |
| Local developer web interface | Implemented local tool | The opt-in dependency-free Erlang `/dev` UI supports chat, sessions, cancellation, bounded run replay, approval/resume, redacted resources, exact-principal Live, and content-free observability. The 0.10 development layer adds a bounded server-owned compiled-graph catalog, metadata-only trace timelines/graph overlays with replay-gap semantics, and safe evaluation authoring/job/set/result/baseline routes. Browser evaluation input can select only a registered agent and first-party metric IDs. A separate provider-payload inspector is disabled by default and requires explicit loopback development enablement; captured values are secret-redacted, JSON-normalized, short-lived, and count/byte/time bounded. It is not production audit/telemetry or general PII detection. Every startup path is loopback-only, outputs are bounded, and the shared bearer is local administrator authentication rather than per-user production authorization. |
| Production web gateway | Implemented | `adk_scope_authorizer` validates issuer-bound principals and exact operation scopes. `adk_web_gateway` retains the server-owned stable-run catalog and owner scope. The Phoenix `LiveGateway` separately authorizes Live, observability, evaluation, graph, and trace reads; discovers only server-owned same-BEAM sessions/reports/graphs; applies bounded metadata-only graph/trace projections; uses future-only Live credit/ack; removes media bytes/signatures before LiveView assigns; and rejects browser-selected principals/modules/paths/stores. Its exact-origin binary voice socket revalidates the opaque web session per frame and uses one bounded core bridge per connection. Exact-scope artifact/memory/context administration, Live creation/configuration, evaluation execution, payload inspection, and durable audit/revocation remain separate privileged APIs/adapters. |
| Command line and API server | Implemented | Authenticated REST/SSE plus `run`, `serve`, scoped `inspect` (including context lifecycle, Live and observability), exact cache-scope invalidation, Live text send, artifact delete, memory search/erase, `cancel`, `resume`, evaluation, `config validate`, and `doctor` are packaged in the `adk` escript. On the 0.10 branch, validation reports opaque registry lineage/revision provenance, while `serve --config` compiles before application startup and merges bounded agent Runner options below trusted operator options and authoritative runtime-profile service references. Local `graph validate`, `graph describe`, and `graph render` inspect an already available zero-arity graph factory as JSON, DOT, or Mermaid without unbounded atom creation. Destructive calls require an exact matching confirmation object. |
| Visual workflow builder | Deferred experimental | Erlang ADK 0.9.0 provides deterministic read-only JSON/DOT/Mermaid graph inspection and declarative workflow APIs, but no drag-and-drop editor, upstream Agent Config generator, or code-generation claim. |
| Ambient/background agents | Implemented | The local/event runtime owns stable event references, bounded concurrency/queue/retention/bytes/waiters, one absolute deadline, idempotency, monitored retry, status/await/cancel, and explicit per-event/explicit/shared session policy. A supervised fixed-delay source is included; `adk_trigger_source` keeps Pub/Sub, Eventarc, Kafka, RabbitMQ, and cloud scheduler transports as backpressured application adapters without SDK dependencies. Durable distributed dedupe/trigger registration and provider delivery acknowledgements remain adapter responsibilities. |

## Components

| Capability family | Current status | Erlang-native contract |
| --- | --- | --- |
| Function tools and agent tools | Partial | Erlang modules and dynamic toolsets compile normalized schemas into an immutable versioned catalog snapshot; module schemas are cached by loaded BEAM version. Duplicate/invalid schemas identify their sources, complete provider call batches and arguments are validated before callbacks or side effects, and dynamic removal fails closed as `tool_catalog_changed`. At the Gemini boundary only a small positive legacy subset uses `parameters`; schemas containing `oneOf`, `additionalProperties`, type unions, boolean subschemas, top-level boolean roots, or any unknown keyword use `parametersJsonSchema` without weakening local validation. Local modules may declare least-authority state/artifact/memory context operations and receive only a scope-bound opaque token; remote tools receive no local handles. Modules without a declaration retain an explicit 0.5 compatibility context. `refresh/1` builds a replacement snapshot, but a running agent cannot atomically swap catalogs, so additions are not advertised until recreation/replacement. AgentTool calls use invocation-scoped history and the same argument boundary. |
| Parallel tool performance | Partial | Runner executes only explicitly parallel-safe tools with bounded fan-out and stable result order. The direct compatibility path and catalog-wide callback/error semantics are not yet aligned. |
| Long-running tools | Partial | Runner provides invocation/action correlation, atomic single-claim terminal resume, correlated non-terminal updates, and Mnesia restart/resume coverage. An already-consumed continuation is rejected rather than returning an identical cached result, and non-Runner agent or typed-workflow tool paths do not provide universal durable continuation parity. |
| Per-call tool confirmation | Partial | Modules support static and argument-aware confirmation callbacks, and dynamic calls may carry validated internal confirmation metadata. Runner/stable-run pauses with an opaque action ID; approval freshly resolves and rechecks policy, while rejection and malformed/mismatched replies fail closed. Typed-workflow tool actions now use the same structured confirmation detail/action-ID model and checkpoint-resume through sequential, parallel, loop, transfer, graph, and graph-fork shapes. Direct non-Runner agent execution (`prompt`, fresh `invoke`, delegation, and AgentTool-backed child calls) still fails closed with `tool_confirmation_requires_runner`; structured modify payloads are not implemented. |
| Tool authentication | Partial | Per-principal credentials use opaque references and private bounded storage. Trusted immutable auth-provider profiles (distinct from 0.8 model `provider_profiles`) enforce grant/scope/resource/TTL policy, single-flight refresh and CAS rotation run in supervised bounded workers, and OpenAPI credentials remain out of model-visible schemas and arguments. The bundled ETS store is volatile; durable encrypted storage, provider revocation, and a catalog-wide proof over every application callback remain adapters/open audit work. |
| OpenAPI toolsets | Partial | OpenAPI 3.0/3.1 compilation, local references, deterministic schemas, JSON operations, SSRF-resistant Gun transport, private immutable API-key/bearer/OAuth profiles, bounded concurrent auth workers, strict version parsing, redirect/method/IPv6 handling, and regression limits are covered. Broader media/auth schemes and complete OpenAPI semantics are not claimed. |
| Curated connector ecosystem | Implemented bounded slice; 0.10 in development | Registry-only descriptors carry stable service/credential IDs and reject URLs, headers, tokens, passwords, and keys. Every connector manifest must exactly match its advertised schemas and declare least-authority permissions, side-effect class, confirmation policy, and parallel safety; unsafe combinations or catalog drift fail closed before execution. In-tree Google, GitHub, Slack, and Postgres packages bind only application-owned native/MCP/OpenAPI/prepared-statement backends. Package integration suites execute every advertised operation through the real registry, Agent Config, and `adk_toolset` path and verify projected policy metadata. They remain unpublished and do not imply arbitrary third-party ecosystem or managed credential support. |
| MCP tools | Hardened partial; modern 0.10 runtime in development | Supervised stdio and Streamable HTTP client/server paths explicitly separate legacy 2025-11-25 handshake/session behavior from modern 2026-07-28 stateless per-request metadata; no era is guessed. The modern runtime covers discover/cache metadata, deterministic list results, exact-match input-required retries, subscriptions, credit-driven incremental SSE, immutable atomic tool/resource/prompt catalog generations, bounded FIFO owner-leased pooling, and RFC 9728/RFC 8414 discovery with redirect-free S256 PKCE helpers. Caller-owned fetch/transport handles keep TLS pinning and credentials outside protocol documents. Legacy GET/SSE and deprecated roots/sampling/logging remain explicit compatibility behavior; modern does not reintroduce removed GET/replay semantics. Mutating disconnects report uncertain delivery and are never replayed. A pinned official Python/TypeScript 2.0.0 client matrix passed modern 2026-07-28 and legacy auto-fallback 2025-11-25 without waivers; it is scoped evidence for those exact SDK commits, not the complete MCP server ecosystem. |
| Versioned artifacts | Partial | Strict scopes, immutable versions, validation/quotas/pagination/deadlines, ETS/filesystem adapters, atomic filesystem publication/repair, least-authority helpers, metadata-only event effects, one-request attachments, and exact-scope developer inspect/delete remain. The 0.10 GCS-compatible adapter adds create-only reservations/manifests, fixed trusted credential/transport boundaries, bounded byte ranges, and capability-negotiated owner-bound credit/ack upload/download. A metadata-only Mnesia effect journal records intent/applied/commit phases and exposes bounded lease-fenced orphan reconciliation. The core cannot infer remote outcome: an operator/backend-specific handler must return committed/compensated/not-applied under an explicit idempotency/compensation policy. Sharded routers support shared global-quota or exact-scope routing; durable workers use LRU-on-capacity reclamation with owner-bound exactly-once operation leases and absolute deadlines, while volatile workers are not reclaimed. Portable filesystem directory-fsync and raw Developer UI upload/download remain unclaimed. |
| Sessions and scoped state | Partial | ETS/Mnesia scopes, HMAC snapshot cursors, filters, pagination, and immutable rewind/branch are implemented; schema migration and configurable conflict policies remain explicit adapters. |
| Events | Implemented | Versioned JSON-safe schema with checked encoding and legacy decoding. |
| Long-term memory | Partial | Mandatory app/user scopes, bounded lexical ETS and local durable Mnesia, provenance, idempotent event ingestion, Runner hit/byte limits, preload/model-selected retrieval, deadline-aware mutation, explicit erasure, least-authority tools, and developer search/erase remain. 0.10 adds bounded embedding/vector/hybrid references, opt-in governance, transactional erasure epochs, and the bundle-owned durable outbox. Epoch-bound job IDs preserve same-epoch idempotency but allow a fresh submission after erasure; due/lease/epoch/terminal work and pruning use bounded ordered indexes. Active jobs reserve terminal slots under one hard cap, while inherited over-cap stores remain startable only for migration/pruning. The outbox retains lease-owned idempotent at-least-once semantics, not exactly-once external effects. Built-in Mnesia topology still needs deployment-owned replication/backup/restore; majority mode merely fails closed below two shared nodes, and no multi-node node-loss CT is claimed. |
| Context filtering and token budgeting | Partial | Runner performs mandatory secret-key pruning, deterministic O(n) exchange-aware selection, canonical multimodal handling, event byte/token budgets, and a fail-closed complete-provider-envelope budget covering instructions, memory, history/current input, tools, parts, and framing. Selection/compression remains explicit; key pruning is not general PII detection, and provider-exact token estimators remain adapters. |
| Context compression and caching | Partial | Compression is owner/deadline/heap/input/output bounded and produces an explicit context fingerprint. Opt-in Runner compaction preserves complete recent exchanges and atomically replaces only an expected session prefix through the bundled ETS/Mnesia backends, persisting a versioned summary/checkpoint. An owner-bound provider-request-prefix cache provides TTL, single flight, isolation, invalidation, private leases, bypass/error policies, and an explicit Runner/Gemini contract without caching model answers. Before installing a provider result it synchronously rechecks every absolute waiter deadline; when all have expired, it deletes the orphan provider resource instead of retaining an unreachable entry. Deterministic exact-wire create/reuse/bypass/generate/stream coverage passes. In the final 2026-07-15 billable REST run, cached-content creation received HTTP 429 after its one bounded retry, so the case failed as rate-limited and is not a REST pass; 15 of the 17 REST cases passed, with Google Search grounding the other 429 failure. |
| App callbacks | Implemented | Existing local callbacks remain compatible. Runner-global plugins precede corresponding local callbacks; `{amend, Value}` continues into later plugins/local validation, while `{return, Value}` and legacy `{replace, Value}` are an early return that skip them. Local callbacks run in monitored timeout/heap-bounded workers over credential-free projected values. |
| Plugins | Implemented core | Up to 128 ordered Runner-global run/agent/model/tool/event hooks compile once with bounded IDs/configuration and run in monitored owner/deadline/heap/result-bounded workers. Open/closed failure policy, observe/intervene modes, explicit amend/return/halt, recoverable model/tool error phases, best-effort agent/run error notifications, success-only `after_run`, delegated plugin capsules, final event/schema invariants, supervised serialized stateful instances, and global-instruction/context-filter/reflect-retry/metadata built-ins are covered. Stateful initialization is isolated, all instance resource settings have hard maxima, and owner death prevents callback-state commit even when completion was dequeued first. A returned PID is an explicitly temporary identity, so a crash does not silently reset state behind a stale reference. Persistent/restarted/distributed plugin state and provider-specific plugins remain application adapters. |
| Agent skills | Deferred experimental | A future adapter must provide incremental discovery/loading plus an explicit filesystem/remote trust policy; 0.9.0 does not reinterpret ordinary prompts, files, MCP resources, or Erlang modules as Skills. |
| Agent optimization | Adapter | Eval sets, trajectories, metrics, judges, and saved results provide the measurement contract. Automated instruction mutation/samplers and provider-specific optimizers are separate, auditable adapters. |

## Interoperability, operations, and safety

| Capability family | Current status | Erlang-native contract |
| --- | --- | --- |
| Incoming OIDC/OAuth/API authentication | Implemented release slice | Oidcc-backed signature/JWKS verification enforces issuer, access-token resource audience, algorithm, time, subject, claims, scopes, token type, and bounded input. OIDC ID-token mode separately applies authorized-party/client rules. The web gateway is default-deny for exact operations; MCP and A2A expose bounded per-operation policy hooks, and protocol resources are principal-bound. Applications must configure authoritative operation policy outside the RFC 9728 mode that requires it. IdP revocation, back-channel logout, and distributed session disconnect remain deployment integrations. |
| Outbound OAuth/API-key/bearer credentials | Implemented | Existing private per-principal tool/API credentials, immutable auth profiles, RFC 8707 targeting, bounded refresh/rotation, and secret-free status/errors remain. Model `provider_profiles` bind a binary alias to an adapter, endpoint, concrete model, locked options, and trusted credential source; an opaque keyed profile snapshot makes credential lookup generation-consistent. Native ambient OpenAI/Anthropic keys are bound to exact official origins, authenticated compatible endpoints require profile-materialized explicit credentials, and Vertex uses the narrow OAuth/ADC contract described below. Durable KMS/HSM storage, provider revocation, and distributed profile rollout remain adapters. |
| Google Application Default Credentials | Implemented Vertex slice | `adk_llm_vertex` accepts an explicit OAuth access token or trusted `google_adc`. Profile-selected ADC uses only the fixed bounded `gcloud auth application-default print-access-token --quiet` command; a trusted direct configuration may instead inject a token-provider handle. Profiles cannot select that provider, a command, arguments, URL, or headers. This is a narrow Vertex request credential contract, not general Google credential propagation across tools, users, or services. |
| A2A protocol | Hardened partial; expanded 0.10 runtime in development | Released A2A 1.0 discovery/core task methods retain principal-scoped supervision, canonical errors, bounded payloads, absolute deadlines, isolated auth, verified HTTPS/private-address policy, and slow-subscriber detachment. The 0.10 server executes a registered agent through Runner, emits incremental SSE, supports extended cards, and can persist bounded public task snapshots in ETS or Mnesia; client `send_stream/4` and subscription callbacks process events incrementally and may stop early. Push configuration CRUD and delivery add HTTPS/allowlist/DNS-rebind/SSRF checks, bounded retries, and stable delivery IDs. Push secrets and the drop-new queue are process-local; restart loses secrets/in-flight jobs and does not guarantee webhook delivery. Only Mnesia `disc_copies` is restart durable, and task persistence is not transparent multi-node failover. The pinned official A2A 1.0 TCK passed 100 cases with 165 expected transport/capability skips and no failures/errors/xfail; its selected JSON-RPC surface was 94 passed and 7 inapplicable skips. That loopback fixture does not prove an authenticated public HTTPS peer, push delivery, other transports, or multi-node node-loss recovery. The project-specific unauthenticated `/a2a/prompt` route remains legacy, separate, and startup-enforced loopback-only. |
| Observability | Implemented core; 0.10 retention in development | Legacy correlated `telemetry`/JSON-safe envelopes remain. Schema-v2 start/end spans measure actual model, tool, and Live connect/receive boundaries with Unix nanoseconds plus monotonic duration. Strict W3C Trace Context extraction/injection, a pinned metadata-only OpenTelemetry GenAI Development mapping, bounded low-cardinality metrics, synchronous delivery, a supervised bounded-best-effort asynchronous bus with delayed transient retries/drop accounting, and a redirect-free OTLP/HTTP JSON traces/logs exporter are implemented. The 0.10 `adk_trace_store` adds bounded, principal-hashed, indexed cursor-paged retention for metadata-only observability and workflow lifecycle projections, with explicit replay gaps, indexed/batched expiry, atomic pending lifecycle admission/drop accounting, and reject-by-default content policy. Local workflow-owner monitoring keeps an otherwise expired receiver alive for a quiet active workflow, then returns it to normal TTL pruning after every owner exits; status reports active owners. Application enablement auto-wires the standard configured Runner and public start/run workflow-facade paths to one strict store/principal; direct constructors stay explicit. The store is volatile and node-local, not a durable audit log, billing counter, WAL, vendor backend, or distributed trace store. |
| Evaluation | Implemented Erlang harness; expanded 0.10 service in development | The released schema-v2 engine retains full-case response/tool-trajectory criteria, repeated isolated samples, stable reports/regression comparison, CLI execution, and the explicit bounded rubric judge. The 0.10 service adds immutable exact-app revisions, atomic set-plus-job lifecycle, named baselines, byte quotas, protected pruning, canonical ownership, bounded preparation, and batched ETS/local-Mnesia recovery. One canonical `adk_eval_export` renderer supplies JSON, Markdown, JUnit, SARIF, and annotations to direct callers, stored-result `report/5`, authenticated HTTP, `adk eval report`, and existing eval-run output with byte parity. All report paths share a 16 MiB default/hard ceiling; `dev_evaluation_report_max_bytes` may lower only the report route, leaving unrelated CLI responses at 1 MiB and request bodies at 64 KiB. Provider-free metrics, ensembles, simulators, review/statistics, and allowlisted RPC workers remain bounded. Hosted datasets, automatic instruction optimization, managed evaluation control plane, and multi-node node-loss evidence remain unclaimed. |
| Safety and policy | Implemented | Runner policies fail closed with deny-overrides-allow agent/tool rules, finite canonical argument/content budgets, post-resolution gates before callbacks/HITL, structural tool errors, secret-free telemetry, and canonical immutable denial audit events. Gemini request-level adjustable harm categories and thresholds are strictly validated and REST-encoded; non-adjustable provider protections remain provider-owned. Human confirmation remains the suspension mechanism. |
| Multimodal content | Implemented | Versioned JSON-safe text, bounded inline bytes, HTTPS/GCS file references, and function parts map to Gemini/Vertex one-shot/SSE and Runner events without changing text-only APIs. Native OpenAI Responses, Anthropic Messages, and compatible Chat Completions add bounded adapter-specific image/file and tool translations; unsupported MIME/part combinations fail explicitly rather than being coerced. MIME, base64, URI, JSON, role, part-count, and byte limits remain enforced. |
| Google Search grounding | Implemented | Gemini GenerateContent accepts only the explicit `google_search` built-in, combines it safely with function declarations, and persists bounded, provider-discriminated JSON grounding metadata for one-shot and SSE results without breaking output schemas. Individual provider fields remain forward-compatible JSON rather than an Erlang-owned schema. Deterministic wire/metadata coverage passes; the 2026-07-15 billable REST case received HTTP 429 after its one bounded retry, so it failed as rate-limited rather than proving or disproving the behavior. URL Context, Maps, Enterprise Search, and the newer Interactions API remain explicit adapters. |
| Model providers and routing | Implemented / Partial | Binary profiles select native Gemini, Vertex GenerateContent, OpenAI Responses, Anthropic Messages, or an explicitly configured OpenAI-compatible Chat Completions adapter without allowing untrusted module/URL/header selection. Keyless local compatible use is restricted to numeric loopback and auth `none`; remote/private deployments require the normal trusted HTTPS boundary. Native adapters preserve their own content/tool/stream/error semantics and every exact target needs endpoint-specific evidence. There is no automatic fallback/discovery/cost routing, retry across vendors, or blanket guarantee for 100+ model names. |
| Gemini Live | Implemented provider slice | A separate supervised `gen_statem` session protocol targets only `gemini-3.1-flash-live-preview`; the REST default remains `gemini-3.1-flash-lite`. It implements setup-before-input, text/current-v1beta `realtimeInput.audio` and `.video` ingress for 16 kHz PCM/JPEG/PNG, native 24 kHz PCM AUDIO output, input/output transcription, automatic/manual activity signaling, usage/grounding events, optional thinking/voice/media-resolution/context-compression/Google Search configuration, distinct interruption/generation/turn completion, GoAway/latest-handle resumption, fixed-v1beta-origin verified-TLS Gun flow control, exact-principal ownership, future-only byte/message credit, hard-capped per-session subscriber cardinality (64 default, 4096 hard maximum) with detach/death recovery, a race-safe supervisor-wide session ceiling (`live_session_limit`, 1024 default, 16384 hard maximum), bounded ingress/subscriber queues, and explicit manual or allowlisted bounded synchronous tool execution. A strict v1 owner-bound voice bridge adds monotonic 16 kHz PCM input, projected audio/transcription/lifecycle output, exact browser ACK credit, interruption signaling, and owner-death cleanup without exposing provider payloads. TLS uses the OS trust store or an explicit `cacertfile` and never falls back to `verify_none`. Sessions are server-owned and outlive starters. Disconnect drops and reports unacknowledged input/tool responses rather than replaying possible side effects. Browser-direct Gemini credentials/ephemeral-token sessions, proactive/affective audio, browser video capture, structured output/REST caching, durable/multi-node routing, Live event/media replay, a separate local CA-controlled TLS integration harness, and models beyond the pinned 3.1 preview are not claimed. REST SSE is never presented as Live support. |
| OpenAI Realtime | Implemented | `adk_live_openai` reuses the supervised owner/principal/bounded-credit Live runtime with a provider-owned GA event codec and fixed `api.openai.com` verified-TLS Gun WebSocket transport. It covers setup, ordered multi-frame text/image/tool operations, 24 kHz PCM input/output, text/audio response modes, input/output transcription, server or manual VAD, interruption, function call/results, completion, usage, rate-limit events, and safe structural errors. Once an in-flight frame batch starts, a later priority action cannot splice into it. Manual `activity_end` commits exactly once; the browser's later `audio_stream_end` is a deliberate no-op, while server VAD owns automatic commits. The trusted 24 kHz input rate is announced by the voice bridge before capture. Session resumption, WebRTC/ephemeral direct-browser sessions, custom Realtime origins, provider-event replay, and durable/multi-node routing are not claimed. |
| Deployment | Implemented render-first assets; 0.10 in development | The tree includes an OTP/relx release, non-root multi-stage container, read-only-root writable-mount contract, dependency-aware liveness/readiness/draining, immutable render-first Cloud Run and Helm/GKE manifests, validate-only-by-default `adk_deploy:cloud_run/1` and `gke/1`, explicit target/context checks before apply, and SBOM/scan/sign/provenance helpers. The container validates a 1024..1048576 open-file cap (65536 default) before ERTS, and PID 1 owns one drain/forward/reap sequence with a 30-second generic/Helm budget or 3-second Cloud Run budget. Deployment configuration has three explicit modes: closed/no listener, packaged health-only, and application-owned `sys.config`. The packaged config listens on the platform `PORT` only for `/livez` and `/readyz`; Cloud Run selects it directly, while Helm selects it only when Service is enabled and no custom ConfigMap is used. A custom ConfigMap must contain `sys.config` and replaces the profile. `ERLANG_ADK_OTLP_ENDPOINT` explicitly activates a validated bounded metadata-only OTLP environment bridge; headers alone cannot enable it. Helm defaults retain one replica, no public agent service/ingress, no literal secrets, and fail-closed network/runtime policy. Cloud Run renders Service- and revision-scope `maxScale: "1"`, an intended operating envelope rather than a hard singleton lease. The final local candidate passed constrained non-root/read-only-root OCI smoke and disposable Kind rollouts for closed/headless plus service-enabled health-only Helm modes, including nondefault `PORT`, health/404/drain behavior, bounded memory observations, and graceful recovery. This does not establish the application-owned third mode, GKE/Cloud Run staging, registry promotion, generated SBOM/scan/sign/attest/provenance, or managed Agent Runtime support; the feasibility probe protects its environment-sourced bearer from process arguments but does not establish managed-service identity. |

## Developer web integration

Phoenix is compatible and remains a companion application rather than a core
dependency. The v0.8 candidate Phoenix 1.8 project runs in the same BEAM
release; its 103 ExUnit, 40 Node, production assets/release, and both loopback
smoke gates passed on 2026-07-17.
Its OIDC code/S256 PKCE boundary keeps login state and sessions in private
bounded server stores; every mount, action, and accepted event reauthorizes.
The existing `adk_web_gateway` owns stable runs and reconnect cursors. The
server-configured `LiveGateway` owns exact-scope Live, observability,
evaluation, graph, and trace-read access. Graph and trace results are bounded
server-owned metadata projections; Phoenix cannot select modules, stores,
principals, or payload capture. Live subscriptions are future-only,
audio/video/signatures are removed before assigns, and a separate authenticated
binary socket uses one bounded owner-bound bridge per browser voice
connection. Its 0.8 format frame
announces the trusted provider input rate before capture, so the AudioWorklet
resamples to 16 kHz for Gemini or 24 kHz for OpenAI Realtime without accepting
a browser-selected rate. Core admission
requires an active session and one monitored bidirectional lease per Live
session; distinct sessions still run concurrently. A session-owned continuity
capability plus credit-independent invalidation prevents stale ingress and
lease retention across a fast reconnect, while ambiguous input/ACK deadlines
terminate the bridge. Socket authorization is checked on data/control/output
and a bounded timer, and browser worklet, socket, playback, transcript, and
server-credit queues are all finite. Reconnect tears down capture instead of
pretending to replay it. Operational snapshots are content-free, and report
and graph IDs resolve only through trusted immutable catalogs. Neither LiveView owns or
links the underlying run/session process. `/dev/v1` remains separate loopback
developer administration, including the explicit development-only payload
inspector, not the production browser API. Node-local
session/run/Live routing, IdP single logout/revocation, browser video transport,
evaluation execution, privileged resource panels, and the documented Cowlib
audit exception remain explicit deployment/release limitations.
