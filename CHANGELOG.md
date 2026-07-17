# Changelog

All notable changes to Erlang ADK are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions 0.3.0 through 0.6.0 below are frozen delivery milestones in the
development history; their presence does not claim that a package was
published for each milestone. Version 0.7.0 is the cumulative release line.
The detailed evidence and remaining limitations are in the corresponding
documents under [`docs/`](docs/README.md).

The `0.7.0` and `Unreleased` references at the end of this file intentionally
target the prospective `v0.7.0` tag. They become usable only after the release
checklist is approved and that tag is created; this candidate does not claim
the tag or Hex package already exists.

## [Unreleased]

No changes have been assigned to the next release.

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

[Unreleased]: https://github.com/hsalap7/erlang_adk/compare/v0.7.0...version_0.7.0
[0.7.0]: https://github.com/hsalap7/erlang_adk/tree/v0.7.0
[0.6.0]: https://github.com/hsalap7/erlang_adk/tree/6448793
[0.5.0]: https://github.com/hsalap7/erlang_adk/tree/b93a79b
[0.4.0]: https://github.com/hsalap7/erlang_adk/tree/c7a4a83
[0.3.0]: https://github.com/hsalap7/erlang_adk/tree/941230d
