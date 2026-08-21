# Erlang ADK 0.10.0 development contract

> **Status: IN DEVELOPMENT.** Version 0.10.0 has not been released. The APIs
> described here are present in the development worktree and merged-candidate
> evidence is recorded below, but release approval, tagging, and package
> publication are not complete.

Version 0.9.0 remains the current released version.

## Expanded 0.10 scope

The work previously proposed for 0.11.0 and 0.12.0 has been folded into this
unreleased 0.10.0 milestone. There is no intermediate 0.11/0.12 release claim.

| Workstream | Development implementation | Release status |
| --- | --- | --- |
| Runtime services | Supervised ephemeral/durable local profiles, one atomic bundle generation, private durable-memory outbox, bounded shard routing and reclamation | Implemented; focused and changed-candidate aggregate gates passed |
| Agent Config and tools | Schema-v2 JSON/strict-YAML config, immutable registry, composition, runtime policy, and curated connector foundations | Implemented; aggregate plus four-package offline connector gate passed |
| Artifacts and memory | GCS-compatible artifacts, bounded transfer/effect reconciliation, vector/hybrid memory, governance hooks, erasure epochs, and bundle-integrated outbox retention | Implemented; focused and changed-candidate aggregate gates passed |
| MCP | Explicit legacy/modern eras, incremental SSE, OAuth/PKCE, pooling, atomic catalogs, and modern runtime capability families | Implemented on the branch; pinned official Python/TypeScript 2.0.0 client matrix passed |
| Evaluation | Durable bounded jobs, built-in metrics, simulators, ensembles, review/statistics, canonical multi-format report parity, and optional RPC workers | Implemented; focused report-parity and changed-candidate aggregate gates passed |
| Developer platform and A2A | Graph/trace/evaluation surfaces, opt-in payload inspection, Runner-backed A2A, incremental streaming, task stores, and push | Implemented on the branch; pinned official A2A 1.0 JSON-RPC TCK passed with scoped skips |
| Deployment | OTP/container assets, health-only HTTP profile, bounded ERTS startup, one PID1-owned drain, strict OTLP environment bridge, Cloud Run and Helm/GKE render/apply boundaries, and supply-chain helpers | Local candidate OCI and two-mode Kind/Helm gate passed; application-owned config, cloud/GKE, registry, and supply-chain artifacts remain pending |

“Implemented on the branch” means the public Erlang surface and focused
deterministic tests exist. It does not mean a package was released, a remote
provider accepted a request, another SDK interoperated, a cluster survived
node loss, or a cloud deployment was promoted.

The 0.9 release already included versioned artifacts, Runner-integrated
long-term memory, evaluation schema v2, MCP over stdio and Streamable HTTP, a
bounded MCP server, the local Developer UI and Phoenix companion, A2A 1.0, and
checked declarative JSON through the CLI. The sections below describe 0.10
additions, not the first implementation of those capability families.

## Implemented development scope

### Supervised runtime-service profiles

`adk_runtime_service_profile` and `adk_runtime_service_bundle` provide one
strict supervised selection point for session, artifact, and memory services:

| Profile | Session | Artifacts | Memory | Routing and quota |
| --- | --- | --- | --- | --- |
| `ephemeral_local` | `erlang_adk_session` | shared `adk_artifact_ets` | shared `adk_memory_ets` | one adapter/component, `active_scopes => 1`, global adapter quota |
| `durable_local` | `erlang_adk_session_mnesia` | exact-scope `adk_artifact_fs` | exact-scope `adk_memory_mnesia` | per-shard quota with bounded idle LRU reclamation |

The profile selects trusted modules; configuration cannot choose an arbitrary
adapter. `durable_local` requires an absolute `artifact_root`. Component maps
accept bounded `adapter_config`, `max_active_scopes`, `max_router_queue`, and
`idle_scope_timeout_ms` values. The default active-scope ceiling is 1024. The
durable idle timeout defaults to 60000 ms and accepts 1 through 86400000 ms.

```erlang
{ok, Bundle} = adk_runtime_service_bundle:start_link(
    durable_local,
    #{artifact_root => <<"/var/lib/my_app/artifacts">>,
      artifact => #{max_active_scopes => 1024},
      memory => #{max_active_scopes => 1024}}),
{ok, #{session_service := SessionService,
       runner_options := RunnerOptions}} =
    adk_runtime_service_bundle:runner_spec(Bundle).
```

`services/1`, `runner_spec/1`, `status/1`, and `stop/1` accept a PID or
registered name. `start/2`, `start_link/2`, and their named arity-3 forms are
available; `child_spec/1` accepts `id`, optional `name`, `profile`, and
`config`. The application supervisor remains opt-in through
`runtime_service_profile` and `runtime_service_profile_config`. An enabled
application bundle is registered as `adk_runtime_service_bundle`.

`adk_runtime_service_bundle:configured_runner_spec/0` and
`erlang_adk:runtime_runner_spec/0` resolve the application setting. Standard
CLI run/console, evaluation-agent, and developer HTTP paths use that split.
Profile-owned artifact/memory references are authoritative. An enabled but
missing/mismatched bundle fails closed instead of silently falling back to an
unrelated ETS service, and cleanup uses the selected session backend.

For `durable_local`, the bundle also starts and owns a private Mnesia memory
outbox in the same atomic generation. Startup validates the selected memory
adapter's durable-ingestion capabilities and registry binding before exposing
the bundle. `services/1`, `runner_spec/1`, `status/1`, and `health/1` return
validated, redacted outbox state, and the Runner spec includes the required
`memory_ingestion` options. Pending jobs survive bundle/outbox process restarts
and continue after adapter re-registration. A stale bundle generation, dead or
unhealthy outbox component, or mismatched adapter reference fails closed.
Disabled and `ephemeral_local` modes create no private outbox and preserve the
released standalone `memory_outbox_enabled` compatibility path.

The volatile adapter registry provides a deterministic claim barrier: initial
startup and registry restart block claims until hydration, and each bounded
claim sees only the exact stable identities currently registered. An ordered
schedule table indexes pending/retry due time, running-lease expiry, and
terminal completion; `max_claim_scan` plus a persisted rotating cursor bounds
each pass without allowing an unavailable identity at the front to starve later
hydrated work. Claim/renew transactions recheck the erasure epoch. Job IDs are
epoch-bound, preserving idempotency within one privacy generation while
allowing an identical logical submission after erasure advances the epoch.

Health validates the jobs, usage, ordered schedule, and erasure-epoch schemas
and topology, then uses constant point reads plus one sentinel write in a
single transaction without changing row counts. Explicit `mnesia_majority`
mode fails health, admission, claim, and renewal closed unless all four tables
share at least two nodes. Active jobs reserve their eventual terminal slots;
the active-plus-terminal ceiling is hard. An inherited over-cap database can
start for migration and bounded indexed pruning, but rejects new admission
until headroom exists. Unknown nested outbox/registry/processor options,
invalid numeric capabilities, missing idempotent/incremental/epoch fencing, and
excess Runner attempts fail before use. Status/crash output is redacted.
Legacy module-named outbox APIs resolve the private bundle-owned supervisor, so
compatibility configuration does not create a second processor.

Every cold-route operation carries one absolute monotonic deadline through
admission, worker resolution, and handoff. A resolved call obtains an
owner-bound token for the exact worker generation and releases that token
exactly once on completion or owner exit. A killed/timed-out caller cannot pin
capacity or allow a late handoff to create or revive a stale shard. Durable
workers are reclaimed only when their operation leases are idle; filesystem
and Mnesia data survives the worker lifecycle. If no eligible worker exists,
the new scope receives `max_active_scopes_reached`.

### Schema-v2 Agent Config, immutable registry, and composition

`adk_agent_config` exposes `compile/1,2`, `load_file/1,2`,
`current_schema_version/0`, and `fingerprint/1`. The current schema is 2;
schema 1 remains accepted for compatibility. Files are limited to 1 MiB.

Schema 2 accepts JSON or Erlang ADK's strict YAML subset. `.yaml`/`.yml` files
select YAML automatically, or trusted callers may set `format`. Equivalent
JSON/YAML normalizes to the same intermediate representation and fingerprint
when compiled against the same registry snapshot. YAML is deliberately small:
two-space block maps/sequences plus JSON scalars. Tabs, anchors, aliases, tags,
merge keys, directives, multiple documents, block scalars, ambiguous YAML
booleans/null, non-empty flow collections, and non-JSON scalar behavior are
rejected. Decoder limits include depth 64, 50,000 nodes, and 100,000 lines.

Schema 2 adds data-only `agent_template`, `credential_profile`,
`runtime_policy`, `sub_agents`, and `workflows` references. Sub-agent trees cap
at 64 nodes and depth 16; workflows cap at 64. Agent names share
`adk_agent_tree` validation, reserve `user`, and cap at 256 bytes. Bounded
Runner fields cap run timeout at 600000 ms, service timeout at 60000 ms, model
calls at 64, tool rounds at 32, parallel tool concurrency at 16, and tool
timeout at 120000 ms.

`adk_config_registry` exposes `new/0,1`, `replace/2`, `snapshot/1`,
`generation/1`, `instance_id/1`, `snapshot_revision_id/1`, `lookup/3`,
`lookup_many/2`, `describe/1`, and `kinds/0`. Registry definition keys are:

- `providers`, `mcp`, `openapi`, and `tool_packs`;
- `credentials` and `runtime_policies`; and
- `workflows` and `agent_templates`.

Each kind caps at 1,024 entries, IDs at 128 bytes, and one registry at 16 MiB.
Agent Config `toolsets` may contain at most 64 unique `{kind,id}` references
for MCP, OpenAPI, or tool packs. Duplicates and excess entries fail before
descriptor expansion. One `lookup_many/2` call authenticates the sealed
snapshot once and resolves the accepted list.

Every independently created non-empty registry has a new opaque instance ID.
`replace/2` preserves that lineage and advances generation, while every
non-empty snapshot receives a new opaque revision. The initial empty registry
alone has stable default IDs. Fingerprints include generation, instance, and
revision provenance, but none is a digest of trusted descriptor/secret
content. Registry/snapshot terms have an internal keyed content seal; a copied
tuple with changed entries is rejected. The seal is not exposed through
diagnostics, CLI output, or fingerprints.

Direct module names in `tools` are rejected by default and require trusted API
option `allow_legacy_module_tools => true`. Arbitrary binary `adk_llm_*`
provider modules separately require `allow_legacy_provider_modules => true`.
Normal declarative files use fixed/registry-backed provider IDs and
registry-backed toolsets. Transport destinations, commands, headers,
credentials, and secret material cannot be selected in an agent file.

`adk_agent_composition` exposes `resolve/1,2`, `spawn/1,2`,
`spawn_scoped/2,3`, `root/1`, `runner_options/1`, `workflows/1`,
`credential_profiles/1`, and `stop/1`. It verifies the exact generation,
lineage, revision, and seal; resolves templates/workflows/policy; and spawns
children bottom-up. Credential descriptors never leave the registry—the
composition projects only opaque profile IDs. Public convenience wrappers are
`erlang_adk:spawn_agent_config/1,2`, `agent_config_root/1`, and
`stop_agent_config/1`.

`adk config validate` reports schema version, registry generation,
`registry_instance_id`, `registry_snapshot_revision_id`, and the 64-byte hex
fingerprint. `adk serve --config` compiles before application startup and
merges bounded agent Runner options below trusted `dev_runner_options`; runtime
profile service references remain authoritative.

### Registry-only connector foundations

`adk_connector_descriptor:validate/2` accepts exactly a connector ID, a
stable service reference, and an optional credential reference. It accepts
only `{kind,id}` references for native/MCP/OpenAPI services and credentials;
URLs, headers, tokens, passwords, and keys are not descriptor fields.

`adk_connector_manifest` requires every advertised tool to declare up to 64
permission labels, one side-effect class (`none`, `read`, `write`,
`external_action`, or `destructive`), a confirmation policy (`never`,
`required`, or `conditional`), and `parallel_safe`. The manifest and schema
catalog must match exactly. `adk_connector_toolset` applies confirmation and
parallel-safety metadata to each resolved call and rejects catalog drift.

Permission strings and side-effect labels are validated policy metadata, not
a complete authorization engine. Applications still own identity-to-
permission decisions. Connector adapter callbacks are trusted application
code and must provide their own backend timeout/isolation contract.

The tree includes curated Google, GitHub, Slack, and Postgres packages. They
bind stable IDs to application-owned native, MCP, OpenAPI, or prepared-
statement backends and keep credentials/raw SQL outside model arguments. They
are prepared for future package publication; this development tree does not
claim that those packages are published or that arbitrary ecosystem
connectors are compatible.

Each package integration suite resolves its descriptor through the real
registry and Agent Config path, constructs the actual `adk_toolset`, executes
every advertised operation against an injected application-owned backend, and
asserts the projected permission, side-effect, confirmation, and
parallel-safety metadata. These tests cover the packaged execution contract;
they are not live-service authorization or transport evidence.

For local validation, each package uses a `_checkouts/erlang_adk` source link.
Because `rebar3_hex` 7.1.0 intentionally omits checkout dependencies from Hex
requirements, its raw local tarball is not the artifact to retain. The sole
supported offline gate for all four packages is run from the repository root:

```console
$ packages/build_connector_packages.sh
```

The wrapper warning-strict compiles/tests source, internally normalizes and
hashes package/docs archives, rejects checkout leakage, and warning-strict
compiles/tests clean extractions. Only its normalized archive may be inspected;
it must carry the non-optional `erlang_adk ~> 0.10.0` requirement. This gate
does not publish a connector. `rebar3_hex` 7.1.0 rebuilds during `hex publish`
and cannot upload the normalized tarball. Any future publication must first
make core Erlang ADK 0.10.0 available in the target Hex repository, remove the
checkout, freshly resolve and lock that published dependency, use the ordinary
publish flow, and verify the requirement on the remote package. All four
connectors remain unpublished.

### Artifacts: object storage, transfer, and effect reconciliation

`adk_artifact_gcs` is an exactly scoped GCS-compatible immutable artifact
adapter. Required config is `bucket`, `project`, and an opaque
`credential => {Module,Handle}`; optional trusted configuration includes
`transport`, `prefix`, bounded item/response/page/scan/concurrency/reservation/
timeout limits, and `stream`. The default artifact limit is 64 MiB and the
configurable hard maximum is 128 MiB. The first-party HTTP transport uses the
fixed Google Storage HTTPS origin; it does not accept an endpoint/header from
an artifact request.

Scope/name values are hashed into object identifiers. Create-only reservation
allocates a version, data is written create-only, and a create-only manifest is
the publication point. `get_range/6` provides bounded ranges.

`adk_artifact_stream` exposes `open_upload/5`, `open_download/5`,
`send_chunk/3,4`, `finish_upload/1,2`, `credit/3`, `ack/2`, `recv/2`, and
`cancel/2`. Upload ACKs return the next grant; downloads require explicit
message/byte credit and one ACK per chunk, with at most one chunk in flight.
Streams are owner/deadline/size bound. The current worker applies mailbox
backpressure but materializes the complete bounded artifact; it is not GCS
resumable/multipart zero-copy transfer.

`adk_artifact_effect_journal` is a Mnesia write-ahead journal for
least-authority artifact effects. Runner option `artifact_effect_journal`
records intent before the external mutation, an applied receipt after it, and
commit only after the correlated event is durable. It stores opaque IDs,
digests, bounded metadata/receipts, and lease state—never bytes or credentials.
Ambiguous outcomes return `artifact_effect_pending_reconciliation`.

`adk_artifact_orphan_reconciler:run/3` performs a bounded synchronous pass.
The operator/backend-specific `adk_artifact_reconcile_handler` callback
`reconcile/3` must decide `committed`, `compensated`, or `not_applied`. Core cannot infer an
external store's outcome; deployments must supply idempotency, observation,
and compensation policy. The runtime bundle may own the journal but does not
run a universal continuous reconciler.

### Long-term memory: vector contracts, governance, and erasure

`adk_memory_embedding_provider:embed/5` invokes a trusted provider in a
killable bounded worker. Defaults are 5 seconds, 128 inputs, 64 KiB/input,
1 MiB total input, 8,192 dimensions, and 16 MiB result. The provider must
return the requested model and one finite fixed-width vector per input.

`adk_memory_vector_ets` is a local volatile reference implementation for
cosine vector search and weighted lexical/vector hybrid search. It supports
bounded app/user-scoped upsert/search/deletion with count, byte, dimension,
batch, and result limits. It is not automatically wired into `memory_svc`, a
managed index, or a distributed vector database; applications own embedding
refresh and synchronization.

`adk_memory_policy:check/6` is a fail-closed isolated hook for `ingest`,
`search`, `delete`, `erase`, `retain`, and `prune`. It redacts/normalizes
bounded input and accepts checked obligations for expiry, retention, legal
hold, and consent. `adk_memory_policy_static:compile/1` provides a bounded
consent/TTL/retention/legal-hold policy. These governance hooks are opt-in:
the owning application/adapter must invoke them and enforce obligations.

`adk_memory_erasure_epoch` keeps a durable per-app/user Mnesia fence. Built-in
Mnesia `delete_user` advances it transactionally. Durable outbox admission
captures the epoch, and delivery asserts it in the write transaction, so stale
queued/in-flight work cannot recreate erased data.

The outbox now caps terminal history and exposes bounded explicit
`prune_terminal` APIs through the store, processor, and supervisor. Defaults
are seven-day retention, 100,000 terminal rows, and at most 1,000 removals per
pass. No timer silently removes history. Delivery remains idempotency-keyed
at-least-once, not exactly-once. Mnesia replication, backup, restore, and
multi-node policy remain operator responsibilities; no multi-node node-loss
Common Test is recorded.

### Modern MCP runtime

`adk_mcp_protocol` requires an explicit era. Legacy session/handshake behavior
covers the 2025 line (including 2025-06-18 compatibility and the 2025-11-25
version); modern `2026-07-28` is stateless and carries self-describing metadata
on each HTTP request. The modern runtime does not guess from a session and
does not reintroduce removed GET/SSE/replay behavior. Legacy GET/SSE is an
explicit `legacy_sse_compat` option; stdio remains legacy.

Modern support includes discovery result/cache scope and TTL, deterministic
tools/resources/prompts lists, exact-key `input_required` retries,
completion/elicitation, and modern subscriptions. Deprecated roots, sampling,
and server logging remain legacy-only.

`adk_mcp_sse_stream` incrementally decodes SSE under message/byte credit and
explicit pause/backpressure. `adk_mcp_pool` provides bounded FIFO owner-bound
leases (default size 4 and 256 waiters). Borrower death/cancellation discards
an uncertain connection. Request callbacks are never replayed; a mutation
disconnect returns `{delivery_uncertain,not_replayed}`.

`adk_mcp_oauth` implements RFC 9728 protected-resource discovery followed by
RFC 8414 authorization metadata, with OIDC well-known fallback only after a
404. It requires S256 PKCE, follows no redirect, sends no credential through
its fetch callback, and leaves TLS pinning/trust to that caller-owned callback.

`adk_mcp_catalog` and `adk_mcp_catalog_store` publish immutable atomic
generations for tools, resources, and prompts. Limits are 1,024 entries/kind,
16 MiB total, and bounded authenticated cursor pages. Old snapshots remain
immutable and replacement notifications are explicit. Catalog values contain
descriptors, not executable handlers or credentials.

`adk_mcp_client`/`adk_mcp_server` expose modern discovery/catalog,
completion/elicitation/subscription and legacy compatibility through their
existing transport APIs. On 2026-08-19 the external fixture passed official
Python `mcp` 2.0.0 at
`6f69a3758ebf2ee55ce050f58b470ce11af71133` and official TypeScript client
2.0.0 at `cc4b41617ce3601b1290d67216ea0b194a3cd9ac`. Both clients passed
modern 2026-07-28 and legacy-auto-fallback 2025-11-25 modes with no waiver or
runtime download; exact locks, assertions, and toolchains are recorded in
`scripts/conformance/mcp_external_sdk/RESULTS.json`. This proves those four
loopback matrix cells, not every SDK, server, transport, or deployed HTTPS
peer.

### Supervised evaluation and enterprise test foundations

The released evaluation-v2 engine remains. `adk_eval_service` adds bounded
supervised scheduling over `adk_eval_store` with exact `{app,App}` scope,
immutable set revisions, atomic set-plus-job creation, expected-state job
transitions, named baselines, record/scope/global byte quotas, and protected
cursor pruning. Built-in ETS is volatile; built-in Mnesia is local durable.

Public service calls include `submit/3`, `status/3`, `result/3`, `cancel/3`,
`list_jobs/3`, `get_set/4`, `list_sets/3`, `put_baseline/4`,
`get_baseline/3`, `prune/3`, and `capabilities/1`. Defaults include concurrency
4, queue 1,000, queue bytes 64 MiB, task timeout one hour, and retained task
workers for 30 seconds; all have hard maxima.

Raw submission preparation runs outside the service mailbox in at most 64
monitored workers, each with a one-second deadline and bounded heap. The store
requires a backend-canonical `ownership_identity/1`, so two services cannot
schedule/recover one backend concurrently. Mnesia validates ordered local
disk tables, persists a configuration fingerprint, supports checkpointed
accounting repair under a global lock, and fails writes closed during repair.
Queued/running jobs recovered after restart are marked failed and never
silently replay model/external work.

`prune/3` requires `before` epoch milliseconds plus bounded optional limit and
opaque cursor. It preserves active, baselined, and referenced rows by default.
`include_baselines => true` deliberately removes old baselines first and may
then reclaim newly unreferenced terminal jobs/sets. Results report baseline,
job, set, byte, scan, cursor, and continuation counts.

Advanced foundations are:

- `adk_eval_builtin_metric` for deterministic latency, token cost, safety, and
  semantic quality without provider calls;
- `adk_eval_ensemble` for persisted-vote weighted/majority aggregation,
  disagreement, and threshold calibration;
- `adk_eval_simulation` with trusted user/environment behaviors and bounded
  step/deadline/heap/JSON crossings while private state stays unpersisted;
- `adk_eval_review` for revision-safe human decisions and immutable terminal
  review state;
- `adk_eval_statistics` for summaries, confidence/pass-rate intervals, and
  longitudinal regression; and
- `adk_eval_export:render/3` as the canonical content-minimal bounded renderer
  for JSON, Markdown, JUnit, SARIF, and annotations.

The canonical renderer, stored-result API, authenticated report endpoint, and
report-specific CLI receiver share one 16 MiB default/hard output ceiling. The
application can lower the route with `dev_evaluation_report_max_bytes`, which
the HTTP runtime projects to `evaluation_report_max_bytes`. This does not raise
the 64 KiB Developer request-body limit or the 1 MiB response limit for
unrelated CLI/Developer operations. `adk eval report` applies the report limit
equally to stdout and `--output` files.

`adk_eval_worker_rpc` optionally runs work on operator-allowlisted Erlang
nodes. Owner death/cancellation kills remote work, node names cannot come from
evaluation JSON, and work is never replayed. This relies on deployment-owned
Erlang distribution security and is not transparent failover; no multi-node
node-loss CT is claimed.

`adk_eval_dev_api` allows browser input to select only a registered agent and
first-party metric IDs. Modules, stores, nodes, credentials, and paths remain
trusted server configuration. Its stored-result `report/5` API, the
authenticated `/dev/v1/evaluation/jobs/:job_id/report` endpoint, `adk eval
report`, and the existing eval-run report path all use the canonical renderer;
for identical inputs and options, direct/API/HTTP/CLI paths return identical
bytes. Boundary coverage includes an approximately 1.4 MiB JSON report with
exact API, authenticated HTTP, stdout, and file parity, inclusive exact-size
acceptance, one-byte-under rejection, and rejection above 16 MiB. Hosted
datasets, automatic instruction
optimization, and a managed evaluation control plane are not included.

### Metadata tracing and Developer UI

`adk_trace_store` retains bounded, principal-isolated metadata projections for
observability and workflow lifecycle events. It uses indexed cursor paging,
explicit replay gaps, global/per-principal quotas, indexed/batched expiry, and
atomic pending admission/drop accounting. Disallowed content is rejected by
default; trusted `content_policy => prune` strips it and marks the event.

`trace_store_enabled => true` strictly resolves the store/bus names and
`trace_store_principal` (default `<<"local-runtime">>`, UTF-8, at most 256
bytes), auto-starts the bus, installs reserved exporter ID
`<<"erlang-adk-trace-store">>`, and injects async metadata capture into the
configured Runner paths. Public `erlang_adk:start_workflow`/`run_workflow`
facades mint an opaque lifecycle receiver unless one was supplied. Direct
Runner/workflow constructors remain explicit.

Lifecycle ingress is atomics-bounded by `max_lifecycle_pending`; capability
expiry uses bounded `max_prune_batch`; `lifecycle_receiver_ttl_ms` is at least
event retention. The store monitors workflow owners and keeps an expired
receiver usable while one bound owner is alive, then resumes normal expiry.
Status reports pending, active owners, and dropped delivery. This volatile
node-local cache is not a durable audit/billing/WAL/distributed trace store.

The Developer UI adds:

- `adk_dev_graph_catalog`, a bounded owner-bound catalog accepting only
  compiled graphs and exposing non-executable descriptors;
- `adk_dev_trace_view`, bounded metadata timelines and graph overlays that
  preserve replay-gap/cursor semantics; and
- evaluation job/set/result/baseline authoring/history through
  `adk_eval_dev_api`.

Provider payload inspection is separate and disabled by default. Explicit
`dev_provider_payload_inspection => #{enabled => true,name => Atom,...}`
installs an observe-only plugin and local volatile store behind the existing
loopback developer bearer. Values are secret-redacted, JSON-normalized, and
bounded. Defaults are 128 events, 64 KiB/event, 1 MiB total, and five-minute
retention; hard ceilings are 10,000 events, 1 MiB/event, 16 MiB total, and one
hour. The plugin is failure-open and not raw wire capture. This is a deliberate
development-only diagnostic, not production telemetry, general PII detection,
or a compliance log.

The Phoenix companion adds server-owned graph detail/overlay and metadata
trace timelines behind explicit gateway authorization/scopes. It never lets a
browser choose owners, trace principals, modules, stores, or filesystem paths.

### A2A 1.0 execution, persistence, and push

`adk_a2a_v1_agent_executor` runs a registered agent through Runner. The server
retains bounded principal-scoped tasks and emits incremental SSE; the client
offers callback-driven `send_stream/4` and subscription variants that apply
backpressure and may stop early, while the collecting forms remain bounded.
Extended Agent Cards are server-configured.

`adk_a2a_v1_task_store` persists only validated public snapshots. ETS defaults
to 10,000 tasks/256 MiB and is volatile. Mnesia defaults to 100,000 tasks/1 GiB
and accepts `disc_copies` or `ram_copies`; only local `disc_copies` provides
normal restart durability. Snapshots exclude subscribers, worker refs, raw
principals, headers, credentials, and push secrets. Restored submitted/working
tasks become failed instead of replaying execution.

Push configuration CRUD validates tenant/task/config identity and splits
public configuration from token/authentication secrets. Delivery applies
HTTPS/loopback policy, allowlists, bounded DNS/private-address checks,
redirect rejection, response limits, and bounded retries with a stable
delivery ID.

Push secrets exist only in the server process. The delivery queue is bounded
(default 128, hard maximum 1024), uses one active worker, and drops the **new**
job when full. There is no durable delivery ledger. Server restart loses push
registrations/secrets and queued/in-flight delivery; webhook delivery is not
guaranteed. The official A2A 1.0 TCK at
`5996b79f9cefa6fc390980e383e358a66fb9e49e` passed 100 tests against the
loopback JSON-RPC fixture, with 165 expected transport/capability skips and no
failures, errors, or expected failures. The selected JSON-RPC surface was 94
passed plus seven inapplicable skips. This does not cover authenticated public
HTTPS, a separate external push receiver, gRPC/HTTP+JSON, or multi-node
node-loss behavior.

### Deployment lifecycle and render-first assets

`adk_deployment_lifecycle` exposes liveness/readiness/status, bounded draining,
and shell-friendly exit codes. Readiness covers admission plus enabled runtime
services, evaluation, trace, developer payloads, memory outbox, Mnesia, A2A,
HTTP, and observability. Drain atomically rejects new/queued admission, waits
for already active owners, then drains observability. It has no undrain API.

The OTP/relx release and multi-stage `Dockerfile` run as uid/gid 10001 and
document writable state/log/tmp mounts for read-only-root operation. Health
and entrypoint helpers remove readiness before SIGTERM forwarding. Before ERTS
starts, PID 1 validates `ERLANG_ADK_NOFILE_CAP` from 1024 through 1048576
(default 65536) and lowers the inherited soft/hard descriptor limit to the
smallest applicable value; it never raises an operator limit. This avoids
unbounded ERTS descriptor-table sizing under container runtimes that inherit a
near-billion soft limit.

The first termination signal starts one PID1-owned drain, and subsequent
signals cannot start a duplicate. PID 1 removes readiness, invokes the bounded
runtime drain, forwards SIGTERM to BEAM, and remains alive until the child is
reaped. The generic drain default is 30000 ms. Helm uses that budget within a
60-second termination grace period and deliberately has no second `preStop`
drain; Cloud Run sets 3000 ms for its shorter platform shutdown window.

The deployment assets expose three deliberate configuration modes: a closed
base release with every HTTP listener disabled, the packaged health-only
profile, and an application-owned runtime config that explicitly enables the
intended listeners. The release contains the deployment-specific health
template at
`etc/health-http.sys.config.src`. Selecting the exact runtime path
`/opt/erlang_adk/etc/health-http.sys.config` deliberately gives relx the base
path: relx probes its paired `.src` and renders through
`RELX_OUT_FILE_PATH=/tmp/erlang_adk` for read-only-root operation. The result
enables a wildcard listener on `${PORT:-8080}` with only content-minimal
`/livez` and `/readyz` routes. Agent, A2A v1, developer, and legacy prompt
routes remain disabled. Public agent listeners, TLS, IAM, durable storage, and
secrets remain deployment-owned.

`adk_deployment_env` activates only when `ERLANG_ADK_OTLP_ENDPOINT` is present.
It bounds and validates the endpoint and parses a bounded
`OTEL_EXPORTER_OTLP_HEADERS` using W3C-Baggage-style comma-separated
`key=value` syntax. Optional whitespace is trimmed, percent escapes are
decoded exactly once for values only; names are lowercased without decoding.
Raw semicolons, malformed encoding, invalid decoded UTF-8, more than 32
entries, or case-insensitive duplicate names fail closed without reflecting
endpoint/header values. The endpoint must be an HTTP(S) origin without
userinfo, query, fragment, or non-root path. It atomically reserves a fixed
deployment-exporter ID, forces bus `batch_size => 1`, and enables the
observability bus. Its HTTP timeout is 3000 ms and exporter worker guard is
4000 ms. The effective bus batch timeout must exceed the sum of every final
exporter descriptor timeout plus 250 ms or startup fails as incompatible. The
bridge installs the configured trace-store exporter before this validation.
When no timeout is configured, it selects the greater of 5000 ms and the final
sum plus 251 ms, subject to the bus's 300000 ms ceiling; it does not raise an
explicit undersized timeout. The
standard configured Runner paths then emit metadata-only observations to the
asynchronous bus even when `trace_store_enabled` is false. Headers alone do not
activate export, and delivery is not a durable audit/WAL.

`adk_deploy:cloud_run/1` accepts `manifest`, exact `project`/`region`, and
optional `apply`; `gke/1` accepts `manifest`, exact `context`/`namespace`, and
optional `apply`. Both default to validate-only, bound manifest/command output
and command time, avoid a shell, and mutate only with explicit apply. Marker
validation is not a semantic Kubernetes validator, and apply does not wait for
rollout or perform rollback/IAM/secret creation.

Cloud Run/Helm render scripts require immutable image references. The Cloud
Run renderer accepts only one as its requested maximum and places
`maxScale: "1"` at both Service and revision-template scopes. These settings
define the intended operating envelope; they are not a hard distributed
singleton lease or proof that rollout revisions never overlap. Cloud Run uses
ephemeral writable mounts, selects the built-in health-only config at
`/opt/erlang_adk/etc/health-http.sys.config`, and relies on the platform to
inject its reserved `PORT`; it does not expose an agent route. Helm defaults to
one replica, `Recreate`, no Service/Ingress, read-only root, default-deny
networking, and existing Secret references only. Enabling its Service selects
the same health-only profile unless `runtimeConfig.existingConfigMap` is set.
That ConfigMap must provide the exact `sys.config` key, mounted at
`/opt/erlang_adk/etc/runtime/sys.config`, and replaces the built-in profile.
Helm OTLP settings feed the strict environment bridge; optional headers come
only from an existing Secret. Supply-chain scripts support BuildKit/Syft SBOM,
Grype scan, and explicit Cosign sign/attest flows.

A final local candidate OCI gate and disposable Kind cluster exercised the
closed/headless and packaged health-only Helm modes as recorded below. This is
candidate-local evidence, not a promoted registry, application-owned config,
GKE, Cloud Run, or release claim. Generated SBOM, Grype scan, Cosign
sign/attest, provenance verification, registry push, and managed Agent Runtime
remain not run; only their static script contracts were checked. The Agent
Runtime material is feasibility-only; managed lifecycle, identity, network,
state, and conformance blockers remain explicit.
Its read-only probe extracts the bounded RFC 6750 bearer exactly from a named
environment variable and supplies curl through standard-input config so the
credential is not placed in the process command line. This hardening is not
target-environment identity or authorization evidence.

### Runtime governance and durable-ledger startup

`adk_runtime_policy` provides opt-in deny-overrides-allow agent/tool policy and
bounded argument/content checks. `compile/1`, `describe/1`, `check_agent/3`,
`check_tool/3`, and `check_content/3` are available. Policy is injected through
trusted Runner/composition configuration; merely having the module in the
application does not establish organization roles, permissions, or governance.

`adk_invocation_ledger_mnesia:init/1` now fails closed when an existing table
does not match the invocation record name/attributes, `set` type, majority
setting, and local `disc_copies` durability. Startup never reinterprets or
downgrades an incompatible/volatile table; operators must migrate it or select
a separate table atom.

## Compatibility and explicit boundaries

- Version 0.9.0 remains the public released base. All 0.10 surfaces are still
  development APIs and may change before release approval.
- JSON schema 1 remains accepted, but schema 2/YAML/composition is Erlang ADK's
  own contract. There is no drag-and-drop builder, code generator, or exact
  compatibility promise for another ADK's config language.
- The GCS adapter does not provision storage or credentials. The artifact
  reconciler needs operator/backend-specific observation, idempotency, and
  compensation policy.
- Vector/hybrid memory is a bounded local reference. Governance hooks are
  opt-in and require application/adapter enforcement. Cross-node Mnesia
  replication/backup/restore and node-loss validation remain deployment work.
- The pinned MCP Python/TypeScript matrix and official A2A JSON-RPC TCK passed
  as recorded below. Their loopback scope does not establish arbitrary-peer,
  deployed HTTPS/IAM, unselected-transport, durable-push, or node-loss
  interoperability.
- Trace storage is metadata-only. The separate payload inspector is explicit
  development-only, redacted, bounded, volatile, and disabled by default.
- A2A push secrets and delivery queue are process-local; capacity drops the new
  job, and restart does not preserve registrations or guarantee delivery.
- Deployment files are render/review/apply tools, not a managed cloud product.
  The final local OCI and two-mode Kind/Helm gate does not imply the
  application-owned config mode, GKE/Cloud Run, supply-chain artifacts,
  promoted-registry, or managed Agent Runtime success.
- The built-in deployment HTTP profile is health-only. Applications exposing
  an agent route must supply and review their own listener, authentication,
  TLS/proxy, ingress, and network policy. A custom Helm `sys.config` replaces
  the health profile and must enable every intended listener explicitly.
- Cloud Run's Service- and revision-scope one-instance maxima do not provide a
  hard singleton or distributed-state guarantee. Treat possible rollout
  overlap as part of deployment design.
- Curated connector packages are present but not claimed as published, and
  permission labels do not replace an application authorization engine.

## Development validation ledger

The results below apply to the named 0.10 working-tree candidate. HEAD remains
the v0.9 baseline and all v0.10 work is uncommitted, so the candidate cannot be
reproduced from that commit or from a tag. These are development results, not a
release, publication, or claim for an explicitly unrun external gate.

| Candidate identity | Current value |
| --- | --- |
| Named working-tree candidate | `codex/version_0.10.0` |
| Git baseline only | `78f31fd6b72295ebeb37cecbd7c11a6c5a666b34` (v0.9 baseline; not the v0.10 candidate identity) |
| Reproducibility | All v0.10 changes remain uncommitted; no candidate commit or tag is claimed |
| Toolchain | Rebar 3.27.0; OTP 27 / ERTS 15.2.7.10 |

Focused deterministic ownership now includes:

- runtime/service/shard and governance modules:
  `adk_scope_sharded_test`, `adk_runtime_service_bundle_test`,
  `adk_v010_supervision_test`, `adk_runtime_policy_test`, and
  `adk_deployment_lifecycle_test`;
- config/connectors: `adk_agent_config_test`, `adk_agent_composition_test`,
  `adk_connector_descriptor_test`, `adk_connector_manifest_test`, and
  `adk_connector_toolset_test`;
- artifacts/memory: `adk_artifact_gcs_test`, `adk_artifact_stream_test`, the
  three artifact-effect-journal/context/bundle modules,
  `adk_memory_embedding_provider_test`, `adk_memory_vector_ets_test`,
  `adk_memory_policy_test`, and `adk_memory_erasure_epoch_test`;
- MCP: `adk_mcp_protocol_foundation_test`, `adk_mcp_modern_runtime_test`,
  `adk_mcp_catalog_foundation_test`, `adk_mcp_oauth_test`,
  `adk_mcp_pool_test`, `adk_mcp_sse_stream_test`, and
  `adk_mcp_streamable_http_SUITE`;
- evaluation: `adk_eval_service_test`, `adk_eval_store_hardening_test`,
  `adk_eval_builtin_metric_test`, `adk_eval_ensemble_test`,
  `adk_eval_simulation_test`, `adk_eval_statistics_test`,
  `adk_eval_review_test`, `adk_eval_export_test`,
  `adk_eval_report_parity_test`, `adk_eval_worker_rpc_test`, and
  `adk_eval_dev_api_test`;
- Developer UI/A2A: `adk_dev_graph_trace_test`, `adk_dev_eval_http_test`,
  `adk_dev_payload_inspection_test`, `adk_a2a_v1_agent_executor_test`,
  `adk_a2a_v1_client_stream_test`, `adk_a2a_v1_push_test`,
  `adk_a2a_v1_task_store_test`, and the existing A2A HTTP/server/security
  modules; and
- deployment/package foundations: `adk_deployment_contract_test`,
  `adk_deployment_env_test`, `adk_deployment_lifecycle_test`,
  `erlang_adk_startup_test`, `adk_agent_runtime_feasibility_test`, and the four
  curated connector-package test suites.

These module names are an ownership/coverage map, not aggregate passing
counts. The protocol and deployment rows below remain independently scoped.
Multi-node node-loss CT, Cloud Run/GKE staging, generated SBOM/scan/sign/
attest/provenance, promoted registry, and managed Agent Runtime gates remain
unrecorded unless a later row explicitly says otherwise.

| Candidate gate | Current merged-candidate record |
| --- | --- |
| Clean aggregate EUnit and deterministic Common Test | Passed on 2026-08-20. The final non-coverage run passed 1,826/1,826 EUnit with 0 failures in 59.083 seconds. The independent coverage run passed 1,826/1,826 EUnit with 0 failures in 57.537 seconds, then deterministic Common Test passed all 6 cases with 22 documented paid-provider cases skipped because their opt-in flags were absent. |
| Warning-as-error compile, Dialyzer, xref, and coverage | Passed on 2026-08-20. Warning-strict compilation and xref were clean. Dialyzer analyzed 669 PLT files and 309 project files with 0 warnings. Aggregate line coverage was 36,574/49,312 executable lines = 74.168559377027904% (reported 74.17%), with 12,738 missed lines and 83 covered lines of headroom over the exact 74% floor. Independently scoped durable-runtime validation passed 46/46 focused EUnit. |
| Canonical evaluation-report parity | Passed 56 focused tests on 2026-08-20. Direct `adk_eval_export`, stored-result `adk_eval_dev_api:report/5`, authenticated HTTP, existing eval-run, and `adk eval report` paths produced the same canonical JSON/Markdown/JUnit/SARIF/annotations bytes. An approximately 1.4 MiB JSON report matched exactly across API, HTTP, stdout, and file delivery; exact and one-byte-under boundaries and the 16 MiB hard ceiling were covered. This focused result complements, rather than substitutes for, the aggregate gate above. |
| README, links, ExDoc, CLI, root Hex package, and extracted-package compile | Passed on 2026-08-20. README EUnit passed 30/30 examples plus 4/4 workflows; all three checked modules compiled with `erlc -Werror`; ExDoc completed without warnings; and the 31-file local Markdown target/anchor/fence plus diff checks passed. Escript assembly, `adk doctor`, checked Agent Config validation, root Hex build, package verifier, and clean extracted-package compile passed. Root package/docs/escript hashes and post-ledger freshness are intentionally reported out of band to avoid self-referential packaged evidence. No publish was attempted. |
| Curated connector offline package gate | `packages/build_connector_packages.sh` exited 0 on 2026-08-20: 4 packages, 12/12 source EUnit and 12/12 clean-extracted EUnit (3/3 per package in each mode), warning-strict compilation, 4 normalized package archives, and 4 documentation archives. The suites executed every advertised operation through the real registry, Agent Config, and `adk_toolset` path and verified policy metadata. Every normalized package carried the exact non-optional `erlang_adk ~> 0.10.0` requirement and no checkout leakage. Package SHA-256: Google `e8ff9bd48fc2b942fc275051a84033dbc61ede681eaac51d2857a99aafd551a9`; GitHub `800149284cb47a789186c3755bba58865a10085fbcd05ec0af21cf2fbf1218cb`; Slack `6b52aa6abafed5f5c1e124f52b58134b3e2470eef1e1dc96641621a44327fd12`; Postgres `8141c4c35ffdf4fa51e0484aac31f6857acf09b554d25c3cff278f02fc027ac8`. This is offline inspection evidence only: all connectors remain unpublished, and actual publication is blocked until core 0.10.0 exists in the target Hex repository and the checkout-free fresh-lock/server-side requirement gate is run. |
| Phoenix, Node/browser-audio, assets/release, TLS/proxy, and advisory review | Passed on the merged candidate: locked dependency/version check resolved Erlang ADK 0.10.0; `mix precommit` passed 107/107 ExUnit and 40/40 Node tests; production assets and release assembly passed; trusted-proxy and CA-verified direct-TLS `/health` smokes passed with clean shutdown. Raw `mix hex.audit` remains non-zero only for the three documented findings—Cowlib EEF-CVE-2026-43969, Cowlib EEF-CVE-2026-43966, and Gun GHSA-w4f7-4cxr-rv3c—and the exact advisory-set verifier passed. The earlier Bandit, Cowboy, and HPACK findings are absent. Live Rebar Hex access still failed with `Unknown CA`; cached locked builds passed, so no live-registry success is claimed. |
| External MCP SDK matrix and A2A TCK | Passed on 2026-08-19. Official Python `mcp` 2.0.0 (`6f69a3758ebf2ee55ce050f58b470ce11af71133`) and TypeScript client 2.0.0 (`cc4b41617ce3601b1290d67216ea0b194a3cd9ac`) each passed modern 2026-07-28 and legacy-auto-fallback 2025-11-25; external fixture EUnit 1/1, MCP regression EUnit 98/98, MCP CT 2/2, compile/xref pass, Dialyzer 0, no waivers. Official A2A 1.0 TCK `5996b79f9cefa6fc390980e383e358a66fb9e49e` passed 100 with 165 expected skips and 0 failure/error/xfail; selected JSON-RPC was 94 pass plus 7 inapplicable skips. Local A2A regression EUnit passed 81/81. These are loopback protocol gates, not public HTTPS/IAM, other A2A transports, durable push, or arbitrary-peer certification. |
| Multi-node node-loss fault injection | Not run |
| Focused deployment/runtime EUnit | Passed after the final OTLP ordering fix: 24/24 across deployment environment, trace runtime, deployment contract, and lifecycle modules. A separate health/startup-inclusive batch had passed 20/20 before that OTLP-only fix. Together they cover the relx health-config base path and nondefault `PORT`, health-only routing, descriptor cap, PID1 drain/reap, final trace-plus-OTLP ordering, and timeout boundary; they are focused, not aggregate or image/cluster evidence. |
| Local OCI image/runtime and Kind/Helm gate | Passed on the final local candidate. `erlang-adk:0.10.0-final` built from fresh locked dependencies with OCI/index digest `sha256:d74eb0a349d45692b5bb59e5ac7f1bbbe3710a59cd2e0be5301a179ce28f92d7`. Direct constrained smoke: uid/gid 10001, read-only root, cap-drop/no-new-privileges, 1 GiB/1 CPU, `/livez` and `/readyz` 200, agent route 404, PID1/BEAM nofile 65536, about 103.9 MiB current, OOM false/restart zero, SIGTERM exit 0 in 1.218 seconds. Disposable Kind: closed/headless and service-enabled health-only Helm rollouts both passed at 1 GiB/read-only/non-root; headless had no Service and current/peak 119,377,920/397,217,792 bytes; service rendered nondefault `PORT=18081`, health 200/200, agent 404, current/peak 110,538,752/388,038,656 bytes, restart zero. Drain set ready false and `/readyz` 503 while `/livez` stayed 200; pod deletion/graceful recovery completed in 1.822 seconds. The cluster was deleted. The application-owned third mode was not runtime-tested. |
| Cloud Run/GKE, supply-chain artifacts, and promoted registry | Not run. Cloud Run staging and GKE were not attempted. No registry identity was authorized; registry push, generated SBOM, Grype scan, Cosign sign/attest, and provenance verification did not run. Static render/apply and supply-chain script contracts passed, but they are not external artifacts or infrastructure evidence. |
| Paid-provider evidence | No merged-candidate result recorded here |

Passing focused development tests is necessary but does not release 0.10.0.
Tagging, package publication, and release claims remain separate maintainer
actions governed by [`RELEASING.md`](RELEASING.md).
