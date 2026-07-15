# Erlang ADK 0.5.0 delivery contract

> **Status:** frozen historical contract, completed on 2026-07-14 at branch
> checkpoint `b93a79b`. The final gate passed 765 EUnit tests, six Common Test
> scenarios, and Dialyzer over 160 project files. Unchecked items remain
> documented limitations.

This document is the implementation and verification contract for the
`version_0.5.0` branch. Version 0.5.0 focuses on **artifacts, memory, and
context**. It starts from the completed 0.4.0 agent/tool/workflow runtime, but
does not treat an existing module or happy-path API as proof that a complete
behavior family is implemented.

The comparison target is externally observable behavior in the official ADK
[artifact](https://adk.dev/artifacts/),
[memory](https://adk.dev/sessions/memory/),
[context](https://adk.dev/context/),
[context compression](https://adk.dev/context/compaction/), and
[context caching](https://adk.dev/context/caching/) documentation. Erlang ADK
preserves useful behavioral outcomes while using OTP supervision, lightweight
processes, monitors, explicit scopes, bounded admission, and message passing
instead of copying another SDK's class hierarchy.

## Status language

- **Implemented** means the public behavior, structural failure behavior,
  deterministic tests, concurrency/crash tests, and Dialyzer contract pass.
- **Partial** means a useful subset is implemented and tested, with its exact
  missing behavior documented.
- **In progress** means a branch change exists but has not passed all required
  gates.
- **Planned** means the target contract is agreed but no implementation claim
  is made.
- **Adapter** means core defines and tests a conformance contract while a
  provider- or deployment-specific implementation remains separate.

`docs/FEATURE_PARITY.md` is the current-state inventory. This document is the
0.5 delivery plan. A planned target here is not an implemented feature.

## Evidence-backed starting point

The 0.5 branch begins at commit `c7a4a83`, the completed 0.4.0 branch. On
2026-07-14 the clean deterministic command passed:

- 654 EUnit tests with no failures;
- four deterministic Common Test scenarios, including the 1,000-invocation
  concurrency stress case;
- warning-free Dialyzer analysis over 134 project files.

The same command skipped all 14 paid live Gemini cases because
`ERLANG_ADK_LIVE_GEMINI` was not set. Those skips are not counted as passes.
The first baseline attempt used an empty Rebar cache and failed to resolve Hex
dependencies before compilation; the measured gate above used the repository's
configured Erlang toolchain and dependency cache.

The starting implementation is meaningful, but its former broad
"Implemented" labels hide important release gaps:

- artifacts have immutable scoped versions, ETS and filesystem adapters, but
  no context facade, built-in loader, event delta, scoped authorization,
  bounded streaming data plane, or developer tooling;
- long-term memory has a lexical ETS reference adapter and Runner
  retrieval/whole-session ingestion, but scope is not mandatory, ingestion is
  neither sanitized nor idempotent, and no durable memory adapter exists;
- context selection has deterministic filtering, byte/token estimates,
  bounded compressor workers, and a fingerprint, but it is optional and
  Runner-only, does not budget the complete provider request, can split tool
  exchanges, has no automatic compaction, and has no actual provider cache.

### Current branch snapshot

The following 0.5 slices are present on the branch as of 2026-07-14. The clean
deterministic compile/EUnit/Common Test/Dialyzer gate and the separate packaged
CLI gate now pass; the paid live-provider outcome is recorded below:

- artifact adapters share strict validation, quotas, capability discovery,
  deadline-aware mutations, bounded name/version pagination, metadata-only
  listing, filesystem staging/publication/repair, and conformance tests.
  Multi-instance-safe filesystem slots cap lifetime scopes per root and names
  per scope at `max_scan_entries div 2`; reservations cap versions per scoped
  name at `max_scan_entries div 3`. Scope/name/version-specific errors occur
  before listing/repair scan exhaustion, and deletion/restart does not restore
  these durable slots;
- optional bounded artifact and memory shard routers create one stable
  supervised worker per exact scope. They preserve same-scope ordering while
  unrelated scopes overlap over the ETS/filesystem and ETS/Mnesia backends;
  deterministic sharding coverage passes 12 tests, including immediate permit
  release when an admitted caller dies and rejection of its queued stale route;
- Runner creates owner-bound scope capabilities. Declaring local tools receive
  only requested state/artifact/memory operations, while remote and opaque
  tools receive no local handles. Artifact/memory effects are correlated to
  their tool events. Artifact name-page envelopes carry scope provenance, and
  all scope-bearing adapter replies are checked against the capability's exact
  scope/name before data or effects can escape; hostile cross-principal
  artifact and memory replies fail closed;
- `adk_load_artifacts_tool` selects verified scoped versions for bounded,
  ephemeral one-next-request attachment. The durable event keeps only the
  reference metadata. The targeted checked-in live Gemini selection case
  passed on 2026-07-14;
- Gemini projects only a small positive legacy tool-schema subset through
  `parameters`. Schemas with `oneOf`, `additionalProperties`, type unions,
  boolean subschemas, top-level boolean roots, or unknown keywords use
  `parametersJsonSchema`; the targeted artifact/memory live case passes with
  this boundary;
- memory v2 requires `{user, App, User}`, provides structured provenance and
  stable idempotency, bounded lexical ETS and durable local Mnesia adapters,
  deadline-aware calls, incremental event ingestion, hard retrieval budgets,
  built-in model-selected search, and entry/session/user erasure. A separate
  bounded Mnesia outbox provides durable admission, batch checkpoints,
  bounded runtime adapter resolution, and a renewed/revalidated ownership
  lease immediately before lease-owned idempotent at-least-once delivery. It
  does not claim an adapter-generation fence. A targeted checked-in live
  Gemini model-selected memory case passed on 2026-07-14;
- model-boundary safety canonicalization is mandatory. Context policy v2 uses
  O(n) complete-exchange selection, and the complete provider envelope has a
  separate fail-closed byte/token budget and fingerprint;
- automatic compaction and provider-request-prefix caching have strict,
  owner-bound lifecycle cores with cancellation, deadlines, bounded workers,
  checkpoints/TTL, single flight, private leases, invalidation, and structural
  fallback. Successful cache creation synchronously rechecks every absolute
  waiter deadline before installation and deletes the provider resource when
  no live waiter remains. Runner compaction atomically persists through the
  bundled ETS and Mnesia session backends. Runner-to-Gemini cache wiring,
  create/reuse/bypass,
  lifecycle, privacy, usage, generate, and stream behavior have deterministic
  mock-provider coverage. A checked-in live Runner gate now verifies real
  create/reuse lifecycle and private-resource absence when quota permits. In
  the full 2026-07-14 run, cached-content creation received HTTP 429 after its
  one bounded retry, so the case failed as rate-limited and is not a live pass;
- the authenticated developer surface has redacted context diagnostics,
  content-free compaction/cache lifecycle and confirmed cache-scope
  invalidation, metadata-only artifact list/delete, scoped memory
  status/search/erase, CLI commands, and an exact-scope `resource_provider`
  contract. Artifact name-page, artifact-version, and memory-hit projections
  reject adapter results whose embedded scope differs from the requested path.
  The session-anchored cache operation explicitly invalidates the configured
  provider/app/user/model/policy scope across sessions;

Open integration work includes pending-outbox erasure coordination,
event-effect orphan recovery, credit-based artifact streaming, and a
quota-backed successful cache/Search live rerun.

## Architectural decisions

These decisions apply across the release.

1. **Scopes are explicit authority.** Internally, artifacts use explicit app,
   user, and session tuples; memory uses a mandatory app/user scope with
   session/event provenance. We will not depend on caller-supplied metadata
   filters or copy a `user:` filename convention into storage internals.
2. **Contexts are immutable views plus capabilities.** An invocation owns the
   complete runtime context. Callback and model views are redacted/read-only;
   tools receive only declared state, artifact, memory, auth, or confirmation
   capabilities. Raw storage handles are not ambient authority.
3. **Events are the durable effect boundary.** State deltas and committed
   artifact references are recorded in canonical event actions. Cross-service
   writes use a staged/committed protocol with explicit orphan recovery rather
   than implying an impossible distributed transaction.
4. **Safety at the model boundary is mandatory.** Secret-key pruning,
   canonical encoding, and request validation always run. Selection,
   truncation, compression, memory retrieval, and caching remain configurable.
5. **Every workload is bounded.** Item bytes, total bytes, counts, metadata,
   queue depth, concurrency, deadlines, retries, and replay/stream credits have
   finite validated limits. A caller timeout or death must not cause a later
   invisible "ghost" commit.
6. **Independent scopes should overlap.** Coordination may serialize one
   logical artifact name, memory key, session, or cache key, but unrelated
   scopes run in supervised lightweight workers. One global GenServer must not
   perform all file I/O, ranking, compression, or provider calls. The direct
   bundled artifact and memory reference adapters remain serialized reference
   paths. The opt-in bounded sharded wrappers meet the exact-scope overlap
   path with stable supervised workers and same-scope ordering. Their current
   limits are per-shard rather than global quotas and no idle-worker eviction.
7. **Local core and managed backends are separate.** ETS and Mnesia/filesystem
   adapters provide deterministic local behavior. Object stores, vector
   databases, and managed memory systems implement tested behaviors without
   becoming hard dependencies of the agent runtime.
8. **Context caching is not response caching.** The current SHA-256 value is a
   context fingerprint. Real context caching reuses a validated model-request
   prefix through a provider adapter, has a TTL/lifecycle, and never returns a
   cached model answer.

## Starting capability matrix

### Artifacts

| Behavior | Starting status | 0.5 release requirement |
| --- | --- | --- |
| Immutable versions and metadata | Implemented core | Preserve monotonic versions, MIME type, digest, size, creation time, and JSON-safe metadata across deletion and restart. |
| App/user/session namespaces | Partial | Keep explicit scope tuples, but bind service operations to invocation-scoped capabilities so possession of a root handle cannot cross principals. |
| Save/load/list/delete contract | Partial | Add context-level save/load, unique-name listing, version listing, metadata-only lookup, bounded pagination, and checked delete semantics. |
| Artifact content | Partial | Map artifact bytes/MIME types to the existing versioned `adk_content` part model without copying large blobs into session state or ordinary history. |
| Model-selected loading | Missing | Provide a built-in load-artifacts tool. Selected artifacts are attached only to the relevant model request and are not permanently copied into history. |
| Runner/event integration | Missing | Record committed artifact versions in canonical event actions and recover or collect staged orphans after an event-persistence failure. |
| Filesystem durability | Partial | Publish data/metadata atomically, sync required files/directories, recover interrupted writes, and avoid transient corruption across concurrent service instances. |
| Streaming and admission | Missing | Add credit/ack upload/download or range workers, incremental digesting, cancellation, deadlines, queue/concurrency bounds, quotas, and predictable overload. Keep bounded whole-binary wrappers for compatibility. |
| Lifecycle and health | Partial | Supervise configured services/workers and expose bounded health, capacity, repair, and telemetry data. |
| Developer tooling | Missing | Authenticated API, CLI, and UI support listing names/versions, upload/download, metadata, delete, health, and repair with scope enforcement. |

### Memory and supporting session state

| Behavior | Starting status | 0.5 release requirement |
| --- | --- | --- |
| Session history and state scopes | Implemented core / Partial operations | Preserve atomic event+state updates and session/user/app/temp scopes; add revisions, deletion/erasure, retention/compaction, and bounded storage/query behavior needed by memory/context. |
| Long-term memory service | Partial | Introduce a versioned, capability-advertising contract with mandatory app/user scope, structured entries, provenance, stable IDs, idempotency keys, timestamps, metadata bounds, and lifecycle operations. |
| ETS lexical adapter | Partial reference adapter | Make it supervised, validated, scoped, bounded, cancellable, and deterministic under overload and concurrent callers. It remains explicitly volatile. |
| Durable local memory | Missing | Add a Mnesia-backed local adapter with restart/recovery, deterministic lexical search, idempotent ingestion, retention, and subject/session erasure. Vector search remains an adapter. |
| Preloaded retrieval | Partial | Preserve opt-in preloading, but enforce scope, per-hit/total byte limits, provenance, policy, safe rendering, complete-request budgeting, and explicit fail/ignore behavior. |
| Model-selected retrieval | Missing | Add a built-in load-memory tool that performs bounded scoped search only when the model requests it. |
| Session/event ingestion | Partial | Canonicalize and sanitize input, support incremental `add_events` and whole-session ingestion, deduplicate retries/turns, and process a durable outbox in supervised workers. Durable mode performs a bounded synchronous admission transaction before reporting run success; adapter delivery remains asynchronous. |
| Privacy/lifecycle | Missing | Add delete-by-entry/session/user, retention/TTL policy, consent/policy hooks, and auditable redacted outcomes. Plain credentials and control continuations must never enter adapter input. |
| Developer tooling | Missing | Add scoped search, inspect, add, delete/erase, ingestion status, adapter health, and usage views to authenticated API/CLI/UI surfaces. |

### Context, compaction, and caching

| Behavior | Starting status | 0.5 release requirement |
| --- | --- | --- |
| Canonicalization and secret-key pruning | Implemented primitive / Partial integration | Apply at every model boundary, including Runner, fresh invocation, direct compatibility history, compression, memory, cache creation, telemetry, and developer preview. Document that this is key-based redaction, not general PII detection. |
| Filter compilation | Partial | Reject unknown options at Runner creation, validate compressor/provider capabilities eagerly, support canonical multimodal types, and group dependent exchanges. |
| Context budgeting | Partial | Budget the complete provider envelope: combined instructions, retrieved memory, history/current input, tool declarations, content parts, and framing. Use a provider estimator when available and a deterministic fallback. |
| History selection | Partial | Replace quadratic event-by-event suffix building with an incremental O(n) grouped selector that preserves current input, chronology, multimodal messages, and tool call/response pairs. |
| Compression | Partial | Bind workers to invocation owner/deadline, cap global/per-agent concurrency, validate provenance/order/pairs, keep current input outside compressor authority, and ensure no result enters the owner mailbox above configured bounds. |
| Automatic compaction | Missing | Add token-threshold/event-retention compaction plus optional interval/overlap triggering. Token pressure takes priority when both trigger families apply. Persist summaries as explicit versioned events/checkpoints while retaining recent raw events. |
| Context fingerprint | Partial | Rename/document the existing deterministic digest accurately and make it cover the complete sanitized provider envelope when used for diagnostics. |
| Provider context cache | Missing | Add a provider-neutral cache behavior and Gemini GenerateContent cached-content adapter with minimum-token, TTL, reuse, invalidation, single-flight creation, bounded registry, fallback, and usage telemetry. Scope by app/user/model/policy by default. |
| Tool/callback context authority | Partial | Introduce validated invocation/tool/callback views and per-tool capability declarations; remote MCP/OpenAPI calls continue to receive no local handles. |
| Developer tooling | Missing | Add redacted context explain/preview, group/budget decisions, compaction checkpoints, cache status/invalidate, and memory/artifact contribution views. |

## Delivery phases

### 0. Branch truth and contract

- [x] Audit artifact, memory, session/state, context, Runner, developer API,
  CLI/UI, and current deterministic tests.
- [x] Compare observable behavior with current official ADK documentation.
- [x] Run the inherited clean deterministic baseline.
- [x] Correct branch/version references and downgrade over-broad current-state
  claims to **Partial**.
- [x] Record this implementation and verification contract.

### A. Shared scopes, contexts, and service contracts

- [x] Define versioned scope, entry, artifact reference, context metadata, and
  capability types with strict size/count/UTF-8/JSON limits.
- [x] Add immutable invocation and tool context facades; declare
  per-tool capabilities and retain an explicit compatibility path.
- [ ] Compile service and context policies at Runner creation, reject unknown
  options, and propagate one absolute deadline/cancellation signal.
- [x] Add adapter capability discovery and shared conformance suites for ETS,
  filesystem, Mnesia, and test doubles.
- [x] Define canonical artifact, memory, compaction, and cache metadata
  without placing credentials or opaque runtime handles in events.
- [x] Preserve provider-neutral compiled tool validation while projecting
  non-legacy JSON Schema, including top-level boolean roots, through Gemini
  `parametersJsonSchema`.

### B. Artifact behavior and data plane

- [x] Add scoped context save/load/list-names/list-versions/delete helpers and
  bounded compatibility wrappers.
- [x] Add model-selected load-artifacts behavior for text and multimodal
  content without permanent history inflation.
- [ ] Introduce scoped capabilities, quotas, per-name coordination, supervised
  data-plane workers, bounded admission, cancellation, and credit/ack streams.
- [x] Add an opt-in bounded exact-scope shard router so unrelated artifact
  scopes overlap while operations inside one scope remain ordered.
- [x] Make filesystem publication atomically reader-visible and
  restart-repairable; preserve
  reservations so versions are never reused.
- [x] Enforce filesystem lifetime version admission before bounded scan
  exhaustion plus multi-instance-safe scope/name slot admission, and expose
  every persistent lifetime ceiling in capabilities.
- [x] Commit metadata-only artifact references through correlated Runner tool
  event effects.
- [ ] Complete durable orphan recovery when event persistence fails after an
  artifact mutation.
- [x] Add authenticated metadata-only artifact API/CLI/UI operations. Raw
  upload/download remains outside this developer surface.
- [ ] Add content-free artifact capacity, repair, and lifecycle telemetry.

### C. Scoped and durable memory

- [x] Replace the unscoped memory behavior with a versioned scoped contract;
  keep compatibility wrappers explicitly documented.
- [x] Define structured memory entries/search hits with source session/events,
  author, timestamp, digest, score type, and bounded custom metadata.
- [x] Rework ETS memory as a supervised bounded reference adapter and add a
  durable Mnesia adapter using the same conformance suite.
- [x] Add an opt-in bounded exact-user shard router so unrelated memory scopes
  overlap while operations for one app/user remain ordered.
- [x] Add sanitized incremental ingestion, stable idempotency keys, and a
  durable outbox with fail-closed admission, checkpoints, timeout-bounded
  resolution, pre-mutation ownership renewal/revalidation, idempotent
  at-least-once retry, and bounded backoff.
- [ ] Coordinate entry/session/user deletion with pending outbox jobs.
- [x] Support both automatic preload and model-selected load-memory retrieval,
  with hard hit/byte budgets and untrusted-reference framing.
- [x] Add scoped entry/session/user erase and exact-scope developer
  operations.
- [ ] Add automatic retention/TTL, application consent/policy hooks, and
  adapter lifecycle telemetry beyond durable-outbox admission.

### D. Complete request context, compaction, and caching

- [x] Make canonical safety processing mandatory for every model execution
  path while keeping selection/compression configuration explicit.
- [x] Build complete provider envelopes and account for instructions, memory,
  history, current input, tools, parts, and provider framing.
- [x] Implement O(n), exchange-aware selection and validate current-input,
  chronology, ID, role, multimodal, and tool-pair invariants.
- [x] Move compression into owner-bound workers with
  absolute deadlines, cancellation, and semantic output validation.
- [x] Add automatic token/turn compaction with retained recent events,
  persisted summary checkpoints, and an atomic expected-prefix session commit.
- [x] Rename the local digest to `context_fingerprint`; implement actual
  provider caching separately.
- [x] Add Gemini cached-content create/reuse/update/delete support for
  `gemini-3.1-flash-lite`, supervised single-flight creation, conservative
  tenant/model scoping, fallback, expiration, cached-token telemetry, and
  deterministic generate/stream coverage. Live evidence remains a separate
  gate.
- [x] Recheck all absolute waiter deadlines synchronously before cache result
  installation and delete a newly created orphan when no live waiter remains.

### E. Integrated developer tooling and documentation

- [x] Extend the authenticated `/dev/v1` API and dependency-free console with
  metadata-only artifact, scoped memory, and redacted context diagnostics.
  Raw artifact transfer and private provider-cache resources are intentionally
  omitted.
- [x] Add equivalent checked `adk inspect`/management commands, bounded
  pagination/streaming, structural errors, and machine-readable output.
- [x] Add content-free compaction checkpoint and cache lifecycle
  status/invalidate operations without returning leases or provider resource
  names.
- [x] Reject artifact-version and memory-hit developer projections when the
  adapter's embedded scope differs from the requested path.
- [x] Document the same endpoints so Phoenix/LiveView integrations can proxy
  scoped operations without receiving storage root handles or provider keys.
- [x] Add literal deterministic README examples for each public behavior and
  map every example to a test in `docs/README_EXAMPLE_COVERAGE.md`.
- [x] Reconcile `docs/ARTIFACTS.md`, memory/context guides, and
  `docs/FEATURE_PARITY.md` with the clean deterministic and live-provider
  results.

### F. Release evidence

- [x] Pass focused unit and adapter-conformance suites.
- [x] Pass crash-injection, property/invariant, and 1,000-operation
  concurrency Common Test suites with zero orphan workers or unbounded
  mailboxes.
- [x] Pass every README example and authenticated developer API/CLI/UI test in
  the clean deterministic gate.
- [x] Pass the clean compile, EUnit, Common Test, and Dialyzer command.
- [x] Pass escript packaging, doctor, and checked config validation.
- [x] Run the separate live Gemini suite with
  `gemini-3.1-flash-lite`; 14 cases passed and two failed with HTTP 429 after
  their bounded retries, with no skips.
- [x] Update package version/status evidence; capability rows remain
  **Partial** wherever complete release requirements or documented semantics
  remain open.

## Required failure and concurrency tests

Artifact tests must cover crashes after reservation/data/metadata/publication,
restart repair, no version reuse, concurrent service instances, no transient
corruption, independent-scope overlap, same-name ordering, overload, caller
death, cancellation, stream backpressure, quotas, traversal/symlink attacks,
cross-principal denial, staged-event orphan cleanup, and failure before
lifetime scope/name/version scan exhaustion with multi-instance admission and
deletion/restart persistence of every ceiling.

Memory tests must cover cross-app/user/session isolation, adversarial filters,
secret/control-data exclusion, malformed or oversized adapter replies,
incremental deduplication across retry/restart/concurrent completion, durable
recovery, retention/erasure, bounded ranking, queue pressure, timeout-bounded
resolver cleanup, ownership loss before adapter mutation, and 1,000 mixed
search/ingest/delete operations. Shard-router tests must also prove that caller
death releases a cold-route permit and cannot create an abandoned worker from
an already queued route.

Context tests must cover unknown configuration, complete-request budgeting,
multimodal messages, tool-pair preservation, immutable current input,
compressor crash/heap/timeout/owner death/cancellation, concurrent admission,
automatic compaction restart, provider-cache single flight/expiry/invalidation,
tenant isolation, fallback, queued provider completion after the last waiter
deadline, orphan-resource deletion, and zero secret values in cache resources,
telemetry, errors, logs, or developer previews. Developer tests must reject
artifact name-page, artifact-version, and memory-hit results whose embedded
scope differs from the requested path.

Provider-tool tests must preserve non-legacy JSON Schema through
`parametersJsonSchema`, including nested and top-level boolean schemas, without
crashing or weakening the locally compiled contract.

## Verification commands

The deterministic release gate is:

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
./rebar3 eunit --module=readme_examples_test
./rebar3 eunit --module=readme_workflow_examples_test
./rebar3 ct --suite test/adk_concurrency_stress_SUITE.erl
./rebar3 ct --suite test/adk_v05_stress_SUITE.erl
./rebar3 escriptize
_build/default/bin/adk doctor
_build/default/bin/adk config validate examples/agent.json
```

`adk_v05_stress_SUITE` passes two scenarios: 1,000 bounded artifact/memory
writes across isolated scopes, and 128 concurrent cache acquisitions across
four exact scopes collapsing to four provider creates/deletes. Live provider
behavior remains a separate opt-in gate:

```bash
ERLANG_ADK_LIVE_GEMINI=1 ./rebar3 ct \
  --suite test/readme_live_gemini_SUITE.erl
```

The clean deterministic release command passed on 2026-07-14: 765 EUnit tests
and six Common Test scenarios completed with no failures, and Dialyzer reported
no warnings across 160 project files. The paid live suite was not enabled in
that command, so its 16 cases were skipped and are not counted as passes.

The following focused deterministic evidence was also recorded in the current
shared tree:

```bash
./rebar3 eunit --module=readme_examples_test
# 29 tests, 0 failures after the v2 scoped-memory README fixture update
./rebar3 eunit --module=adk_context_cache_gemini_test
# 7 cache-wire tests, 0 failures
./rebar3 eunit --module=adk_llm_gemini_test
# 29 Gemini adapter tests, 0 failures; only the positive legacy subset uses
# parameters, while oneOf/additionalProperties/type unions/boolean subschemas
# and top-level boolean roots use parametersJsonSchema
./rebar3 eunit --module=adk_context_cache_test
# 10 tests, 0 failures, including exact-scope lifecycle and synchronous
# waiter-deadline recheck before provider-resource installation
./rebar3 eunit --module=adk_memory_outbox_test
# 6 tests, 0 failures, including resolver timeout, lease renewal, and
# ownership loss before adapter delivery
./rebar3 eunit --module=adk_dev_v05_http_test
# 9 tests, 0 failures, including lifecycle privacy, confirmation, and
# fail-closed embedded-scope mismatch projections
./rebar3 eunit --module=adk_artifact_fs_test
# 15 tests, 0 failures, including multi-instance-safe persistent
# scope/name/version lifetime admission
./rebar3 eunit --module=adk_scope_sharded_test
# 12 tests, 0 failures, including exact-scope ordering, overlap, isolation,
# strict atomic cold-route admission, killed-caller permit cleanup, and
# ETS/filesystem/Mnesia backends
./rebar3 dialyzer
# passed; 160 project files analyzed at that point in the shared tree
```

The sharded adapters deliberately enforce limits per shard; they do not
aggregate a global storage quota, and active scope workers are not idle-evicted
in 0.5.

An earlier combined 14-module artifact/memory/context gate covering adapter
conformance, ETS/filesystem/Mnesia storage, the durable outbox, context policy
and complete envelopes, capabilities, compaction, Runner integration, the
provider-neutral cache, and Gemini exact-wire caching passed 90 tests with no
failures. Additional Runner and lifecycle cases landed afterward, so 90 is not
the final combined 0.5 total; the clean 765-test result above supersedes it.
Socket-bearing README, developer HTTP, and cache-wire fixtures were run outside
the restricted sandbox against loopback only.

After the Gemini tool-schema projection fix, the targeted checked-in
`readme_live_gemini_SUITE:artifact_and_memory_tools/1` case passed 1/1 against
`gemini-3.1-flash-lite` on 2026-07-14, exercising both model-selected memory
and artifact rounds. Only the positive legacy subset remains in `parameters`;
`oneOf`, `additionalProperties`, type unions, nested or top-level boolean
schemas, and unknown keywords are preserved in `parametersJsonSchema`. The
subsequent full live run passed this case.

The live process must inherit `GEMINI_API_KEY`. The checked-in
`readme_live_gemini_SUITE:context_cache/1` case uses a sufficiently large stable
prefix and a real Runner to require resource creation, reuse it across two
sessions, assert public `created` then `hit` lifecycle metadata, and prove the
private resource name is absent from durable events. On the full 2026-07-14
run, its create request received HTTP 429 after the one bounded ten-second
retry, so it failed as rate-limited and does not replace deterministic adapter
tests.

Before that case was checked in, a sanitized manual `erl -noshell` probe on
2026-07-14 used a stable estimated 6,000-plus-token prefix, reached
`cachedContents.create`, and received HTTP 429. One bounded retry after ten
seconds also received 429. No resource was returned, so there was nothing to
delete, and the GenerateContent step was not reached. This historical result
is **RATE-LIMITED** (quota or billing), not a pass, skip, or deterministic
regression.

Overall, the full opt-in live suite against `gemini-3.1-flash-lite` passed 14
of 16 cases with no skips. `google_search_grounding` and `context_cache` were
the only failures; each received HTTP 429 after one bounded retry. They are
recorded as quota/rate-limit failures, not implementation passes.

## Explicit non-goals

- Erlang ADK will not embed a production vector database, object-store SDK, or
  KMS into every application; those are conformance-tested adapters.
- Raw multi-megabyte blobs will not pass through one global coordinator
  mailbox or be copied into session state/history.
- A context fingerprint will not be described as a cache, and context caching
  will not be described as model-response caching.
- Cross-service event/effect handling will not claim exactly-once external
  side effects. It will expose the commit boundary, idempotency key, recovery,
  and orphan policy.
- Python method names, zero-based artifact version numbers, and object models
  are not compatibility goals when the Erlang contract is clearer and safer.

## Documentation rule

Public examples describe only behavior that has passed its gate. Partial
features state their missing semantics next to the example. Unsupported input,
overload, scope violations, timeout, cancellation, and unavailable services
return explicit structural errors; none are silently accepted or counted as
successful compatibility.
