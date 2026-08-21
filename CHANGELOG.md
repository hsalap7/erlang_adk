# Changelog

All notable changes to Erlang ADK are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions 0.3.0 through 0.7.0 below are frozen delivery milestones in the
development history; their presence does not claim that a package was
published for each milestone. Version 0.9.0 is the current released version.
The detailed evidence and remaining limitations are in the corresponding
documents under [`docs/`](docs/README.md).

## [Unreleased]

The following expanded v0.10.0 implementation is **IN DEVELOPMENT**. It is not
a release record: merged-candidate validation is recorded below, while release
approval, tagging, and publication remain pending.

### Added

- Strict `ephemeral_local` and `durable_local` runtime-service profiles plus
  `adk_runtime_service_bundle`, which owns session, sharded artifact, and
  sharded memory selection as one supervised, fail-stop generation and exposes
  validated service references and a Runner-ready option split. The ephemeral
  profile uses one shared ETS adapter per component with global quotas; the
  durable profile uses exact-scope filesystem/Mnesia workers with per-shard
  quotas and lease-protected, LRU-on-capacity idle reclamation. `durable_local`
  also atomically owns and health-checks a private Mnesia ingestion outbox,
  exposes its redacted service/status surface, and injects validated durable
  memory ingestion into the standard Runner path. Pending jobs survive bundle
  process restarts; stale or unhealthy service references fail closed.
  Deterministic registry hydration gates bounded rotating claims by exact
  adapter identity; a constant-row four-table sentinel provides health, and
  due/lease/erasure/terminal work is indexed and bounded. Majority mode requires
  at least two shared nodes. Epoch-bound job IDs preserve same-epoch idempotency
  while allowing post-erasure resubmission, and a hard active-plus-terminal
  reservation supports explicit migration/pruning. Nested options and adapter
  capabilities are strict, status is redacted, and legacy named APIs resolve
  the one durable bundle owner without a duplicate processor. Disabled and
  `ephemeral_local` configurations preserve the standalone-outbox path without
  creating a profile-owned outbox.
- Reusable schema-v2 `adk_agent_config` compilation/loading for JSON and a
  strict YAML subset, with schema-1 compatibility, normalized cross-format
  snapshot-stable fingerprints and opaque registry lineage/revision
  provenance. Immutable-generation `adk_config_registry` snapshots now cover
  provider, MCP, OpenAPI, tool-pack, credential-profile, runtime-policy,
  workflow, and agent-template descriptors. `adk_agent_composition` resolves
  data-only references against the exact sealed snapshot and materializes
  bounded sub-agent trees, workflows, Runner policy, and opaque credential
  profile IDs. Agent names use the runtime identifier grammar, reserve `user`,
  and are limited to 256 bytes. Toolset references are capped at 64, duplicates
  are rejected, and one authenticated bulk lookup resolves the accepted list.
  Independently created non-empty registries have distinct instance IDs; every
  non-empty snapshot has a fresh revision. Neither ID is a descriptor-content
  digest, and the internal keyed content seal is never exposed.
- Registry-only connector descriptors and strict manifests for permissions,
  side-effect class, confirmation policy, and concurrency safety, plus
  in-tree Google, GitHub, Slack, and Postgres connector packages. The packages
  require application-owned backends/credentials and are prepared for a future
  publication; they are not claimed as published packages. Their local Hex
  workflow includes a required post-build normalizer because `rebar3_hex`
  7.1.0 omits the `_checkouts/erlang_adk` dependency from generated
  requirements. Only the normalized tarball, with non-optional
  `erlang_adk ~> 0.10.0`, is eligible for offline inspection or
  clean-extracted tests. It is not a publish input: `rebar3_hex` 7.1.0 rebuilds
  on `hex publish`. `packages/build_connector_packages.sh` is the sole offline
  all-connector release gate. Its package suites execute every advertised
  operation through the real registry, Agent Config, and `adk_toolset` path and
  assert the projected permission/side-effect/confirmation/concurrency policy
  metadata. All four connectors remain explicitly unpublished.
- A GCS-compatible, exactly scoped immutable artifact adapter with bounded
  ranges and credit/ack upload/download; a durable metadata-only artifact
  effect journal; and a bounded lease-fenced orphan reconciler. Reconciliation
  deliberately requires an operator/backend-specific handler to decide whether
  an external effect committed, was compensated, or was not applied.
- A bounded, killable embedding-provider boundary; a local volatile cosine and
  weighted lexical/vector ETS reference adapter; an opt-in fail-closed memory
  governance hook with a static consent/TTL/retention/legal-hold policy; durable
  erasure epochs shared by Mnesia memory and the ingestion outbox; and bounded
  terminal-outbox retention/pruning.
- Explicit MCP 2025-11-25 legacy and 2026-07-28 modern protocol eras, including
  stateless per-request metadata, discovery/cache metadata, deterministic
  catalogs, modern input-required and subscription flows, credit-driven
  incremental SSE, RFC 9728/RFC 8414 discovery with S256 PKCE, a bounded
  owner-leased connection pool, and immutable atomic tool/resource/prompt
  catalog generations. Legacy GET/SSE remains opt-in compatibility behavior;
  the modern era does not reintroduce removed GET/replay semantics.
- A supervised bounded `adk_eval_service` and `adk_eval_store` contract with
  immutable eval-set revisions, atomic set-plus-job creation, atomic job
  transitions, exact application scopes, named baselines, byte quotas,
  bounded default-safe pruning with explicit baseline cleanup, restart
  recovery, terminal-record quota headroom, and bounded ETS or local durable
  Mnesia adapters with strict schema/config checks and batched accounting
  repair. Backend-canonical store ownership, including across wrapper modules,
  prevents concurrent schedulers/recovery on one backend; ETS and Mnesia
  recovery are batched. Raw submissions are prepared in a hard-capped set of
  monitored timeout/heap-bounded workers outside the service mailbox.
- First-party bounded evaluation metrics for latency, token cost, safety, and
  deterministic semantic similarity; persisted-score ensembles and threshold
  calibration; operator-selected user/environment simulators; confidence and
  longitudinal-regression helpers; a revision-safe human-review state machine;
  one canonical `adk_eval_export` renderer for JSON, Markdown, JUnit, SARIF,
  and annotations; a stored-result `adk_eval_dev_api:report/5` API; an
  authenticated HTTP report route; `adk eval report`; a safe Developer UI
  authoring facade; and optional explicit-node RPC evaluation workers with
  owner-bound cancellation and no replay. Direct, API, HTTP, CLI, and existing
  eval-run report paths return the same canonical bytes under one 16 MiB
  default/hard report ceiling. `dev_evaluation_report_max_bytes` can lower the
  report-route ceiling; unrelated CLI responses stay at 1 MiB and Developer
  request bodies at 64 KiB.
- A supervised bounded `adk_trace_store` for principal-isolated metadata-only
  observability and workflow lifecycle retention, cursor paging, explicit
  replay gaps, content rejection/pruning, and global/per-principal quotas,
  plus a fixed-principal observability exporter and an opaque best-effort
  workflow lifecycle receiver that preserves PID-receiver compatibility.
- A bounded server-owned Developer UI graph catalog, metadata-only trace
  timelines and graph overlays, and evaluation authoring/history routes. A
  separate provider payload inspector is disabled by default and requires an
  explicit local-development opt-in; it is redacted, normalized, bounded, and
  short-lived rather than a production trace/audit store.
- Runner-backed A2A 1.0 execution, callback-driven incremental client streams,
  extended Agent Cards, bounded ETS or local Mnesia task-snapshot stores, and
  push-notification configuration CRUD plus SSRF/DNS/HTTPS-bounded delivery.
  Push secrets and the drop-new delivery queue remain process-local.
- Render/review-first deployment assets: an OTP/relx release, non-root
  read-only-root container contract, dependency-aware health and draining,
  Cloud Run and Helm/GKE manifests, explicit-apply CLI/scripts, and SBOM,
  scanning, signing, and provenance helpers. A bundled health-only HTTP profile
  serves `/livez` and `/readyz` on the platform-selected `PORT` while leaving
  agent/A2A/developer routes disabled. The container bounds inherited
  open-file limits before ERTS startup, and PID 1 owns one drain/forward/reap
  sequence with target-specific shutdown budgets.
- A strict deployment OTLP environment bridge. `ERLANG_ADK_OTLP_ENDPOINT`
  explicitly activates a bounded metadata-only OTLP/HTTP JSON exporter;
  optional `OTEL_EXPORTER_OTLP_HEADERS` are ignored without that activation,
  parsed as bounded W3C-Baggage-style headers with optional-whitespace trimming
  and one strict value percent-decoding pass. Raw semicolons, malformed escapes,
  decoded invalid UTF-8, and case-insensitive duplicate names fail closed
  without reflecting values; headers are never accepted from agent data. The
  bridge forces batch size one; the HTTP/exporter bounds are 3/4 seconds, and
  the bus timeout must exceed the
  sum of all final exporter descriptor timeouts plus 250 ms. It includes the
  trace-store exporter before validating/auto-sizing an absent timeout and
  rejects an explicit undersized value. Standard configured Runner paths emit
  through the asynchronous observability bus even when local trace retention
  is disabled.
- [`docs/VERSION_0_10_0.md`](docs/VERSION_0_10_0.md), the in-development 0.10
  contract and merged-candidate evidence ledger.

### Changed

- `adk config validate` now uses the reusable Agent Config compiler and reports
  schema version, registry generation, opaque registry instance/revision IDs,
  and configuration fingerprint. Direct module names in the `tools` field are
  disabled by default; trusted API callers must explicitly opt into that
  legacy path. Arbitrary `adk_llm_*` provider module names have a separate
  trusted opt-in and are also disabled by default; normal declarative configs
  use fixed/registry-backed provider IDs and registry-backed `toolsets` IDs.
- `adk_agent_config:current_schema_version/0` now returns 2. `.yaml` and `.yml`
  files use the strict YAML decoder; anchors, aliases, tags, directives, merge
  keys, multi-document input, non-JSON scalar behavior, and unbounded input are
  rejected instead of being interpreted.
- `adk serve --config` now compiles before application startup and merges the
  agent's bounded Runner options into developer configuration. Trusted
  operator options win conflicts, while profile-owned service references stay
  authoritative.
- `erlang_adk:runtime_runner_spec/0`, CLI run/console, the evaluation agent
  adapter, and developer HTTP setup now resolve an enabled application runtime
  profile. Its service references are authoritative, missing/mismatched enabled
  bundles fail closed, and console/evaluation cleanup uses the selected session
  backend.
- Enabling the trace store now strictly configures and starts its observability
  bus/exporter, injects asynchronous metadata-only observability into the
  configured Runner paths, and supplies store-minted lifecycle receivers to
  the public start/run workflow facade. Direct Runner/workflow constructors
  remain explicit. Lifecycle delivery has atomic pending admission and drop
  accounting; paging and expiry pruning use ordered indexes and bounded
  batches. Receiver TTL now follows monitored local workflow owners, retaining
  authority for a quiet live workflow and returning to normal expiry after
  every owner exits.
- Durable scope routers now carry one absolute deadline across admission,
  resolution, and handoff, and bind exactly-once operation leases to the caller
  and worker generation. Killed/timed-out callers cannot pin capacity or create
  a stale shard. Existing durable invocation-ledger Mnesia tables also fail
  closed unless their record schema, `set` type, majority, and local
  `disc_copies` durability match the configured contract.
- Development application, OTLP instrumentation, package-verifier, and
  Phoenix path-dependency version surfaces now identify `0.10.0`; this
  metadata bump does not mark the version as released.
- The Cloud Run manifest now selects the built-in health-only relx config at
  `/opt/erlang_adk/etc/health-http.sys.config` and relies on Cloud Run to inject
  its reserved `PORT`. Helm selects the same profile only when its Service is
  enabled and no custom runtime config is present. A custom runtime ConfigMap
  must provide the exact `sys.config` key mounted at
  `/opt/erlang_adk/etc/runtime/sys.config`; it replaces, rather than augments,
  the built-in profile. These form three explicit modes: a closed base release,
  the packaged health-only release, and an application-owned runtime config.
- The Cloud Run renderer now emits `maxScale: "1"` at both Service and revision
  scopes and accepts no other maximum. This is an autoscaling envelope, not a
  hard singleton lease or a promise that revisions cannot overlap during
  rollout.
- The container entrypoint now validates `ERLANG_ADK_NOFILE_CAP` from 1024
  through 1048576 (default 65536) and only lowers inherited soft/hard limits.
  Helm no longer adds a duplicate `preStop` drain; PID 1 performs the single
  drain and stays alive until BEAM exits. The default/Helm drain budget is 30
  seconds within a 60-second grace period, while Cloud Run uses 3 seconds.
- The read-only managed Agent Runtime feasibility probe now retrieves the
  bearer token exactly from a named environment variable, bounds and validates
  the RFC 6750 token shape, and passes its curl header through standard-input
  config rather than exposing the token as a process argument. This remains a
  feasibility boundary, not managed-runtime support or staging evidence.
- Feature documentation now describes the 0.9 release as the existing base:
  artifacts and Runner-integrated memory, evaluation v2, stdio and Streamable
  HTTP MCP, Developer UI/Phoenix, A2A 1.0, and partial Agent Config were already
  present before the expanded 0.10 work.

### Validation

- Evidence refers to the named `codex/version_0.10.0` working-tree candidate.
  Its HEAD, `78f31fd6b72295ebeb37cecbd7c11a6c5a666b34`, is the v0.9 baseline;
  the v0.10 work remains uncommitted and is not a reproducible commit or tag.
  The changed-candidate aggregate passed 1,826/1,826 non-coverage EUnit and an
  independent 1,826/1,826 coverage EUnit run, 6 deterministic Common Test cases
  with 22 expected paid-provider skips, clean compile/xref, Dialyzer over 309
  project files with 0 warnings, and 36,574/49,312 = 74.17% line coverage
  (12,738 missed; 83 covered lines over the exact floor). Escript, doctor, and
  checked config validation passed. README checks passed 30/30 plus 4/4,
  all three checked example modules compiled with `-Werror`, and ExDoc, local
  link/anchor/fence, root Hex/verifier/extracted compile, and diff gates passed.
  Root artifact hashes/freshness remain out of packaged documentation to avoid
  self-reference.
- Focused durable-runtime validation passed 46/46 EUnit with compile, xref, and
  Dialyzer clean. Focused canonical evaluation-report parity and size-boundary
  validation passed 56 tests across direct, stored-result API, authenticated
  HTTP, existing eval-run, stdout, and file paths, including an approximately
  1.4 MiB exact-parity report.
- The sole offline connector wrapper passed all four packages: 12/12 source and
  12/12 clean-extracted EUnit, including real registry/Agent Config/toolset
  execution for every advertised operation and policy projection. Warning-
  strict compilation, four normalized Hex archives with the exact non-optional
  `erlang_adk ~> 0.10.0` requirement and no checkout leakage, and four docs
  archives passed. These are inspection artifacts, not publication inputs; all
  connectors remain unpublished.
- The pinned official MCP Python/TypeScript 2.0.0 matrix passed modern
  2026-07-28 and legacy-auto-fallback 2025-11-25 in all four cells. The pinned
  official A2A 1.0 JSON-RPC TCK passed 100 tests with 165 expected
  transport/capability skips and no failures/errors/xfail; its selected
  JSON-RPC surface was 94 passed plus seven inapplicable skips.
- The Phoenix companion passed 107 ExUnit and 40 Node/browser-audio tests,
  production assets/release, and trusted-proxy plus CA-verified direct-TLS
  health smokes. The exact advisory verifier accepted only the two documented
  Cowlib advisories and Gun's duplicate response-splitting advisory. Live Hex
  registry access still failed with `Unknown CA`, so cached locked dependency
  success is not represented as a live-registry result.
- The final local image `erlang-adk:0.10.0-final` built with fresh locked
  dependencies at OCI/index digest
  `sha256:d74eb0a349d45692b5bb59e5ac7f1bbbe3710a59cd2e0be5301a179ce28f92d7`.
  A constrained non-root/read-only-root 1 GiB direct smoke passed health-only
  routing, nofile 65536 for PID 1/BEAM, memory/OOM/restart checks, and graceful
  SIGTERM. A disposable Kind cluster passed closed/headless and
  service-enabled Helm rollouts, nondefault `PORT=18081`, health/404 routing,
  drain readiness/liveness behavior, and graceful pod recovery, then was
  deleted.
- Complete aggregate Erlang, documentation/package, protocol, Phoenix, and
  deployment evidence is recorded in the in-development candidate ledger;
  these passing gates do not release 0.10.0.

### Compatibility and known limitations

- The 0.10 additions remain opt-in development APIs. They do not add a managed
  cloud product, visual/no-code builder, hosted evaluation control plane,
  durable/distributed trace backend, automatic instruction optimizer, or
  complete external MCP/A2A ecosystem.
- The pinned external protocol gates are recorded narrowly. Official MCP
  Python 2.0.0 (`6f69a3758ebf2ee55ce050f58b470ce11af71133`)
  and TypeScript client 2.0.0
  (`cc4b41617ce3601b1290d67216ea0b194a3cd9ac`) passed both modern
  2026-07-28 and legacy-auto-fallback 2025-11-25 modes without waivers. The
  official A2A 1.0 TCK at
  `5996b79f9cefa6fc390980e383e358a66fb9e49e` passed 100 tests with 165
  expected transport/capability skips and no failures, errors, or expected
  failures; the selected JSON-RPC surface was 94 passed plus 7 inapplicable
  skips. These loopback fixtures do not prove arbitrary peers, HTTPS/IAM, or
  unselected A2A transports. No multi-node node-loss Common Test proves
  Mnesia/task/outbox recovery. Cloud Run/GKE staging, registry push, generated
  SBOM/Grype scan, Cosign sign/attest, verified provenance, and managed Agent
  Runtime gates remain separate and unclaimed.
- The built-in deployment listener is health-only. A callable agent endpoint
  still requires a deployment-owned listener, authentication, TLS/proxy,
  ingress, and network policy. The Cloud Run template requests a one-instance
  maximum at both annotation scopes, but that is not a hard singleton
  guarantee; its writable storage is ephemeral, and no successful Cloud Run
  staging deployment is claimed.
- Artifact effect recovery is not automatic inference: an operator-owned
  backend handler must provide idempotency, observation, and compensation
  policy. Memory governance hooks are opt-in and must be invoked by the owning
  application/adapter path; the local vector implementation is not a managed
  or distributed vector database.
- Developer payload inspection is explicit development-only capture. Redaction
  is bounded defense in depth, not a general PII classifier. A2A push secrets
  and delivery jobs are process-local; queue saturation drops the new delivery,
  and restart does not guarantee webhook delivery.
- This section must remain unreleased until the complete candidate gates in
  [`docs/RELEASING.md`](docs/RELEASING.md) pass and the evidence ledger is
  populated from one reviewed revision.

## [0.9.0] - 2026-08-06

### Added

- Definition-bound workflow checkpoint schema v2 with a stable execution ID,
  ordered lineage, durable attempt/node/runnable/waiting/join/cycle/interruption
  state, optional portable definition revisions, and one-step v1 migration.
- Ordered schema-v1 workflow lifecycle delivery through the opt-in
  `lifecycle_receiver`, separate from the legacy event receiver.
- Checkpoint-resumable nested workflow pauses in parallel, loop, transfer,
  graph, and graph-fork execution, plus typed tool-confirmation pauses in every
  typed workflow shape.
- Canonical graph validation and non-executable JSON inspection, deterministic
  DOT/Mermaid rendering, public inspection APIs, and `adk graph validate`,
  `describe`, and `render` commands.
- Fork `all`, `any`, `first_success`, and quorum join policies; per-node input
  and output JSON Schemas; and per-key `overwrite`, `append`, `sum`, or
  conflict-rejecting state reducers.
- A constrained keyless loopback policy for local OpenAI-compatible servers,
  with model-support recipes and explicit evidence tiers.
- Native Vertex AI publisher-model GenerateContent/SSE with fixed authority
  derivation and bounded OAuth/Google ADC token acquisition.
- [`docs/VERSION_0_9_0.md`](docs/VERSION_0_9_0.md), the 0.9 release contract.

### Changed

- Agent generation features are checked against adapter capability
  declarations, and profile-selected Live capabilities cannot exceed the
  selected adapter's implementation ceiling.
- Workflow retry attempt numbers survive checkpoints. An ambiguous in-flight
  attempt repeats at the same number after recovery rather than receiving a
  fresh retry budget.
- Root and Phoenix locks now resolve Cowboy 2.18.0, Cowlib 2.19.0, Ranch 2.2.1,
  and Gun 2.4.1; the companion additionally resolves Bandit 1.12.4 and
  Plug.Crypto 2.2.0.
- The application and OTLP instrumentation versions are now `0.9.0`.

### Security

- Graph inspection omits executable callbacks, captures, tool arguments,
  nested options, credentials, and provider configuration.
- Graph factory CLI lookup is limited to already available modules and
  exported zero-arity functions, avoiding unbounded atom creation from command
  input.
- Keyless cleartext compatible endpoints are restricted to numeric IPv4/IPv6
  loopback with auth `none`; existing HTTPS, verified-TLS, redirect, and
  private-address policy remains in force elsewhere.
- Vertex profiles cannot expose OAuth tokens, ADC handles, arbitrary origins,
  headers, executables, or command arguments to public configuration.
- Dependency upgrades remove Bandit EEF-CVE-2026-65623, Cowboy
  EEF-CVE-2026-65624, and Cowlib EEF-CVE-2026-59248 from the Phoenix audit.
  The exact-exception verifier now matches package/advisory pairs, so a new
  GHSA-only finding cannot hide behind the two documented unresolved Cowlib
  advisories.

### Validation

- Release validation compiled 242 production modules and 271 test modules with
  warnings treated as errors. All 1,495 EUnit tests and all 6 deterministic
  Common Test cases passed.
- A fresh Dialyzer run completed with 0 warnings, and `./rebar3 xref` reported
  0 undefined or deprecated calls or functions. The passing aggregate includes
  the focused graph, durability, provider, model, and CLI regression suites.
- The Phoenix companion passed 103 ExUnit and 40 browser/audio tests,
  production asset and release assembly, locked-dependency validation, and
  trusted-proxy plus verified direct-TLS health smokes.

### Compatibility and known limitations

- Checkpoint recovery and lifecycle delivery remain at least once, never
  exactly once for external effects. A v1 checkpoint is readable for migration
  and is rewritten as definition-bound v2 at its next commit.
- There is no visual graph editor, arbitrary multi-node branch-region
  scheduler, automatic cross-vendor router, blanket 100+ model guarantee, or
  Agent Skills implementation.
- Coverage, package, and optional paid-provider results were not recorded for
  this release; deterministic fixtures do not prove arbitrary Vertex or
  OpenAI-compatible deployments.

## [0.8.0] - 2026-07-17

### Added

- Operator-owned model provider profiles with bounded binary profile/model
  aliases, adapter and endpoint validation, structured HTTPS endpoints,
  secret-free capabilities, and credential sources resolved only at the
  trusted runtime boundary.
- Generation-consistent profile/credential resolution using an opaque keyed
  snapshot, so a concurrent profile replacement cannot mix old authority with
  a new credential source.
- A native OpenAI Responses adapter with bounded one-shot and incremental SSE
  generation, canonical multimodal content, function call IDs and parallel
  calls, structured output, and operator-owned organization/project/storage
  settings.
- A native Anthropic Messages adapter with bounded one-shot and incremental
  SSE generation, canonical image/tool content, parallel tool blocks,
  operator-owned API versioning, and GA structured-output encoding.
- A deliberately narrow OpenAI-compatible Chat Completions adapter with a
  trusted HTTPS endpoint, fixed operation path, bearer/x-api-key/keyless auth
  modes, bounded content/tool/SSE handling, and an explicit structured-output
  capability switch.
- Shared model HTTP, Gun, header, and incremental SSE contracts with exact
  origin policy, verified TLS, deadline-bounded DNS, redirects disabled,
  private-address rejection by default, response limits, 64 KiB aggregate
  header/trailer block caps in both synchronous and streaming paths, and
  streaming flow control.
- An OpenAI Realtime Live adapter, GA event codec, and fixed-origin verified-
  TLS Gun WebSocket transport for bidirectional text/audio/image, audio/text
  output, transcription, function calls/results, interruption, usage, and
  rate-limit events.
- Provider-neutral ordered multi-frame Live actions and an explicit no-op
  action outcome, allowing one logical text/tool/manual-turn operation to be
  admitted atomically without interleaving or duplicate audio-buffer commits;
  once sending begins, a later priority action cannot splice into that batch.
- Trusted Live input-rate status and voice format negotiation: Gemini uses
  16 kHz PCM input and OpenAI Realtime uses 24 kHz, while the browser bridge
  continues to receive native 24 kHz PCM output.
- [`docs/PROVIDER_PROFILES.md`](docs/PROVIDER_PROFILES.md) and the
  [`0.8.0 release contract`](docs/VERSION_0_8_0.md).

### Changed

- Binary provider IDs now select configured profiles; direct atom-module
  provider maps remain a trusted-code compatibility path.
- New native OpenAI and Anthropic environment keys are accepted only at their
  exact official origins. A custom HTTPS origin requires a profile-resolved
  explicit credential, and an authenticated compatible endpoint never reads
  a process-wide ambient compatible key.
- Profile callers may set only adapter-specific inference/runtime options.
  Model IDs, endpoints, credentials, arbitrary headers, auth/storage/billing
  settings, HTTP/Live transports, and audio rates remain operator-owned.
- Anthropic `max_tokens` validation now enforces the provider-compatible
  minimum of one for both direct and profile-selected requests.
- Phoenix browser capture waits for the server's input-format frame and
  resamples to the negotiated 16 or 24 kHz rate instead of assuming Gemini's
  16 kHz input contract.
- Source and test layout documentation now identifies the provider profile,
  shared transport, native OpenAI/Anthropic, compatible, and Realtime
  ownership directories.

### Security

- Credentials are absent from normalized profiles, public configuration,
  errors, transport state diagnostics, model-visible content, and browser
  frames. Literal profile sources project only their source type.
- Custom endpoints are structured HTTPS configuration, not caller-provided
  URL strings; fixed adapter paths, host/scheme allowlists, DNS address policy,
  no redirects, and verified hostname/peer checks constrain credential
  delivery.
- Live binary profiles cannot select a transport module, endpoint, model ID,
  credential handle, CA file, billing headers, or input sample rate.
- Gun rejects an aggregate response-header or trailer block above 64 KiB in
  both synchronous and streaming paths, and Live preserves an in-flight
  multi-frame batch as one contiguous side-effect sequence even when a later
  priority action arrives.

### Verification and known limitations

- The 2026-07-17 deterministic release gates passed 1,414 EUnit tests, six
  Common Test cases, Dialyzer over 235 source modules with no warnings, 74.17% line
  coverage, 244/244 focused provider/profile/Realtime tests, 34/34 README and
  workflow tests, all three warning-as-error example compilations, and the
  xref/escript/doctor/configuration/documentation/package checks. Common Test
  intentionally skipped 22 opt-in paid cases in the deterministic command.
- The seven-module post-audit repair regression set passed 67/67.
- The Phoenix gate passed 103 ExUnit and 40 Node tests, production assets and
  release assembly, and both trusted-proxy and direct-TLS smokes. Raw Hex audit
  remained non-zero only for the two documented Cowlib advisories; the exact-
  exception verifier passed.
- The paid Gemini REST attempt reached Google but did not produce a pass: the
  configured credential was rejected with HTTP 401 `UNAUTHENTICATED` /
  `ACCESS_TOKEN_TYPE_UNSUPPORTED`. No v0.8 paid Gemini Live pass is recorded.
  Focused REST header tests passed 29/29 and Live broker/transport tests passed
  19/19; that deterministic evidence does not turn the remote credential
  failure into a pass, skip, or product regression.
- No paid OpenAI Responses, OpenAI Realtime, Anthropic, or compatible-vendor
  result is claimed by deterministic fixtures.
- Automatic routing/fallback, custom Live origins, OpenAI Realtime resumption,
  blanket compatible-vendor parity, browser WebRTC/direct-provider tokens,
  and distributed provider-profile rollout remain outside this release.

## [0.7.0] - 2026-07-15

### Added

- A separately supervised Gemini Live runtime for
  `gemini-3.1-flash-live-preview`, with text, PCM audio, image input, audio
  output, transcription, interruption, resumption, bounded credit, and
  explicitly allowlisted tool execution.
- A transport-neutral, owner-bound browser voice protocol and one lightweight
  bridge process per connection. The protocol provides bounded ingress,
  binary framing, exact audio-event acknowledgement, interruption cleanup,
  reconnect fences, and ambiguous-outcome protection.
- Runner-global plugins with ordered observation, amendment, explicit early
  return, bounded callbacks, supervised stateful instances, and reusable
  instruction, context-filter, logging, and reflect/retry plugins.
- Evaluation schema v2 with full-case response and trajectory criteria,
  repeated samples, aggregate thresholds, baseline comparison, stable
  JSON/Markdown reports, an explicit bounded Gemini rubric judge, and
  `adk eval run` CI exit semantics.
- Strict W3C Trace Context, metadata-first GenAI spans, bounded
  low-cardinality metrics, a supervised asynchronous export bus, Live
  telemetry, and an SDK-independent OTLP/HTTP JSON exporter.
- Authenticated developer projections for Live sessions, evaluation reports,
  and observability snapshots.
- A Phoenix Live operations view with server-owned session discovery,
  future-only Live delivery, realtime text, and a same-origin binary
  full-duplex voice socket backed by the Erlang bridge.
- An explicit loopback-only Phoenix development identity, allowing local use
  without an external OIDC provider. It is available only in `MIX_ENV=dev`,
  binds to `127.0.0.1`, and uses a CSRF-protected login POST.
- A complete Phoenix presentation layer, AudioWorklet capture/resampling,
  bounded Web Audio playback, static asset checks, and a favicon route.
- A reproducible EUnit plus Common Test coverage gate that discards stale
  exports, writes an HTML/per-module report, and enforces a 73% deterministic
  Erlang line-coverage floor in release validation.
- Deterministic boundary coverage for OIDCC authorization/OAuth adapters,
  OpenAPI compilation and execution, Live transport/voice leases, evaluation
  agents and limits, JSON/OpenAPI schemas, trace context, and secret-safe
  failure classification.

### Changed

- REST generation continues to default to `gemini-3.1-flash-lite`; Live is a
  distinct protocol and requires the explicit
  `gemini-3.1-flash-live-preview` model.
- A2A Agent Cards now derive their application version from the loaded
  `erlang_adk` application rather than retaining a hard-coded earlier
  release value. The A2A protocol version remains `1.0`.
- Phoenix local authentication no longer evaluates or requires `OIDC_*`
  configuration. Production configuration rejects local authentication.
- Phoenix voice playback uses continuous bounded scheduling and defers each
  ADK audio acknowledgement until its corresponding browser audio has been
  admitted, preventing credit from outrunning playback.
- Release validation now pins Node 24-native `actions/checkout` and
  `actions/setup-node` releases, eliminating the GitHub Actions Node 20
  deprecation fallback while retaining immutable commit-SHA references.
- Reorganized the production source tree into explicit agent, tool, workflow,
  Live, runtime, state, protocol, integration, auth, model, plugin, telemetry,
  and evaluation ownership directories. The `src` root now contains only the
  public facade and OTP application shell; Erlang module names, public APIs,
  and BEAM names are unchanged.
- Reorganized Erlang tests and their dedicated helpers to mirror production
  ownership under a test-profile-only recursive `test` root. Explicit Common
  Test paths and documentation now follow the same hierarchy, while default
  builds and packages continue to contain production modules only.
- Extracted canonical safety-setting validation into the provider-neutral
  model contract; Gemini retains provider-specific REST encoding.

### Fixed

- Corrected the local-login form's CSRF token handling and session rotation.
- Corrected Live audio framing and multi-chunk byte preservation across the
  Erlang bridge, Phoenix socket, AudioWorklet, and playback path.
- Added explicit interruption teardown so already scheduled browser audio is
  purged instead of playing stale model output.
- Added a `/favicon.ico` redirect and packaged SVG favicon so a normal browser
  request no longer produces a router error.
- Corrected stdio MCP initialization to use `initialize_timeout` rather than
  the shorter per-operation `request_timeout`, removing a startup race on
  loaded hosts while preserving bounded operation timeouts.

### Security

- Raised the production runtime baseline to OTP 27.3.4.14 / SSL 11.2.12.10
  so outbound TLS clients include the fix for CVE-2026-54891.
- Enforced IPv4/IPv6 loopback binding for the unauthenticated legacy
  `/a2a/prompt` listener; A2A v1 public-listener flags cannot weaken it.
- Voice WebSocket handshakes are same-origin and authenticated; every frame
  revalidates the opaque server session, exact principal, scopes, and
  server-owned Live session.
- Media, transcripts, credentials, provider handles, tool payloads, and
  thought signatures remain out of LiveView assigns and observability
  projections.
- Phoenix LiveView is pinned to the official upstream fix commit for
  CVE-2026-58228 until a fixed Hex release at or above 1.2.7 is available.

### Verification and known limitations

- The 2026-07-16 deterministic gate on OTP 27.3.4.14 passed 1,176 EUnit
  tests, six Common Test cases, 73.88% aggregate Erlang line coverage against
  an enforced 73% floor, Dialyzer over 210 project files, escript packaging,
  `adk doctor`,
  checked configuration validation, 29 README tests, four workflow tests,
  193 focused v0.7 tests, and both 1,000-operation stress suites.
- The Phoenix gate on OTP 27.3.4.14 passed 101 ExUnit tests and 31
  dependency-free browser audio tests, warnings-as-errors compilation,
  production assets, release
  assembly, and loopback health checks for trusted-proxy and verified direct
  TLS configurations.
- The paid Live suite passed all five cases against
  `gemini-3.1-flash-live-preview`.
- The paid REST suite passed 15 of 17 cases against
  `gemini-3.1-flash-lite`. Search grounding and context-cache creation each
  failed explicitly with HTTP 429 after one bounded retry; these are quota
  failures, not passing evidence.
- `mix hex.audit` remains non-zero for two unresolved Cowlib 2.18.0
  advisories. Reachability is reduced but the vulnerable routines remain in
  the dependency tree. See [`SECURITY.md`](SECURITY.md).
- Live subscribers receive future events only; a local CA-controlled Live
  WebSocket lifecycle harness remains open. A2A tasks, Phoenix web sessions,
  run lookup, and the reference Live gateway remain node-local.

## [0.6.0] - 2026-07-14

### Added

- Immutable provider profiles, strict OIDC/JWT validation, default-deny
  operation/resource authorization, opaque credential references, bounded
  single-flight token refresh, and supervised authorization-code flows with
  S256 PKCE.
- Principal-bound MCP 2025-11-25 and A2A 1.0 protocol paths with bounded
  parsers, discovery, SSRF/redirect/token-forwarding policy, TLS policy, and
  canonical structural errors.
- Issuer-bound run ownership and a same-BEAM Phoenix 1.8/LiveView companion
  with opaque server-side sessions, OIDC code+PKCE login, CSRF/origin/header
  policy, bounded rendering, typed human approval, production assets, and
  release assembly.

### Limitations

- The local `/dev` bearer remains single-operator developer administration,
  not production end-user identity.
- A2A tasks and web/run state are node-local; A2A push notifications,
  distributed task storage, client streaming decode, and compound
  multi-credential requirements remain incomplete or adapter-owned.
- The Cowlib advisories described for 0.7 were already visible in the Phoenix
  dependency tree and remain unresolved upstream.

## [0.5.0] - 2026-07-14

### Added

- Strictly scoped, immutable artifact versions with ETS and filesystem
  adapters, quotas, metadata pagination, repair, bounded inspection, and
  least-authority tool access.
- App/user-scoped long-term memory contracts with lexical ETS and local
  Mnesia adapters, provenance, idempotency, retrieval, erasure, and a durable
  bounded outbox path.
- Mandatory model-boundary context sanitation, complete-request budgets,
  exchange-aware selection, owner-bound compaction, fingerprints, and a
  provider-prefix-cache lifecycle.
- Optional exact-scope sharded services so unrelated artifact, memory, and
  cache scopes can overlap in lightweight processes while preserving
  same-scope ordering.

### Limitations

- Durable object-store/vector-store/KMS integrations remain adapters.
- Credit-based blob streaming, complete durable artifact orphan recovery,
  managed vector search, schema migration, and global cross-shard quota are
  not claimed.
- Provider context caching is prefix reuse, not model-response caching.

## [0.4.0] - 2026-07-14

### Added

- Invocation-scoped delegated history, exact-session invocation lanes,
  bounded agent topology, and private cycle/depth ancestry checks.
- Compiled tool catalogs, strict JSON Schema argument validation, explicit
  catalog drift, AgentTool isolation, confirmation, and bounded tool workers.
- Supervised sequential, parallel, loop, collaborative, and graph workflows
  with deterministic state merge, budgets, checkpoints, and explicit failure
  behavior.

### Limitations

- Legacy direct prompts intentionally remain a stateful FIFO compatibility
  path.
- Running agents do not receive automatic live tool-catalog swaps, and some
  nested workflow pause/resume shapes remain unsupported.

## [0.3.0] - 2026-07-14

### Added

- The OTP-native execution foundation: reusable agent admission processes,
  one supervised process per invocation, stable run IDs, deadlines, budgets,
  cancellation, event sequencing, replay, and exactly one terminal result.
- Bounded concurrency and admission control for agents, sessions, workflows,
  tools, model calls, and ambient invocations.
- Versioned JSON-safe events, ETS/Mnesia session services, state, pause/resume,
  callbacks, telemetry, plugins, evaluation, MCP, A2A, authenticated local
  developer tooling, CLI packaging, and an Erlang-hosted development UI.
- Explicit process ownership and secret-isolation rules used by later
  releases.

[Unreleased]: https://github.com/hsalap7/erlang_adk/compare/v0.9.0...main
[0.9.0]: https://github.com/hsalap7/erlang_adk/tree/v0.9.0
[0.8.0]: https://github.com/hsalap7/erlang_adk/tree/v0.8.0
[0.7.0]: https://github.com/hsalap7/erlang_adk/tree/v0.7.0
[0.6.0]: https://github.com/hsalap7/erlang_adk/tree/6448793
[0.5.0]: https://github.com/hsalap7/erlang_adk/tree/b93a79b
[0.4.0]: https://github.com/hsalap7/erlang_adk/tree/c7a4a83
[0.3.0]: https://github.com/hsalap7/erlang_adk/tree/941230d
