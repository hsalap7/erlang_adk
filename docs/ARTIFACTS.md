# Artifact services

Erlang ADK stores immutable, versioned binary artifacts behind the
`adk_artifact_service` behaviour. Artifact authority is an explicit scope:

```erlang
{app, AppName}
{user, AppName, UserId}
{session, AppName, UserId, SessionId}
```

The same logical name in two scopes is two independent artifacts. A successful
`put` always allocates a new positive version; deletion never makes that
version reusable. The filesystem adapter also has an explicit lifetime
allocation ceiling for scopes, names, and versions, described below. A service
handle is passed to a Runner as `{Module, Handle}`.
Provider code never receives an ETS table or filesystem root.

The 0.9 release already included these artifact adapters and their Runner
integration. The 0.10 branch adds an opt-in supervised configuration layer:
`adk_runtime_service_bundle:start_link(ephemeral_local, #{})` selects one
shared ETS artifact adapter, while `durable_local` selects exact-scope
filesystem workers and requires an absolute `artifact_root`. The shared
adapter enforces one global quota across scopes; durable limits remain per
worker/shard. Separately, 0.10 adds a GCS-compatible object-store adapter,
bounded transfer facade, and durable effect journal. The runtime profile does
not select or operate those external services automatically. See
[`VERSION_0_10_0.md`](VERSION_0_10_0.md) and note that 0.10 remains **IN
DEVELOPMENT**.

## Capability and listing API

Adapters expose their versioned contract and configured bounds:

```erlang
{ok, #{api_version := 1,
       immutable_versions := true,
       scopes := [app, user, session],
       pagination := Pagination,
       quotas := Quotas}} = adk_artifact_ets:capabilities(ArtifactPid).
```

Use `list_names/3` to enumerate unique logical names and `list_versions/4` to
enumerate metadata-only versions. Both use an exclusive cursor and return at
most `limit` entries:

```erlang
{ok, #{scope := Scope, items := Names, next_cursor := NameCursor}} =
    adk_artifact_ets:list_names(
      ArtifactPid, Scope, #{limit => 100}),

{ok, #{items := Versions, next_cursor := VersionCursor}} =
    adk_artifact_ets:list_versions(
      ArtifactPid, Scope, <<"reports/summary.txt">>, #{limit => 100}),

NextNames = case NameCursor of
    undefined -> [];
    _ ->
        {ok, #{scope := Scope, items := Page}} = adk_artifact_ets:list_names(
            ArtifactPid, Scope, #{limit => 100, cursor => NameCursor}),
        Page
end.
```

Name cursors are the final binary name returned by the previous page. Version
cursors are the final positive integer version returned. Results are sorted
by name and then version. Version pages never contain the artifact `data`.

The original `list/2` API remains for compatibility. It returns every version
only when the result fits `legacy_list_limit`; otherwise it returns
`{error, result_limit_exceeded}`. New code should use the distinct paginated
operations.

`put/6`, `get/5`, and `delete/5` add bounded call options while the original
arities keep their existing defaults:

```erlang
adk_artifact_ets:put(
  ArtifactPid, Scope, <<"result.txt">>, <<"ready">>,
  #{mime_type => <<"text/plain">>},
  #{timeout_ms => 2000}).
```

The absolute deadline calculated by the caller is carried with the request
and is checked by the adapter immediately before a mutation is committed. If
a request expires while queued, it returns `{error, timeout}` and is not
silently committed after the caller has stopped waiting. A filesystem request
that has already reserved a version may leave a gap, but it cannot publish an
artifact after observing an expired deadline.

## Shared validation limits

Both bundled adapters fail closed with the same structural limits:

- each app name, user ID, and session ID is non-empty UTF-8, contains no NUL,
  and is at most 256 bytes;
- an artifact name is non-empty UTF-8, contains no empty, `.` or `..` path
  segment, contains no NUL, and is at most 1,024 bytes;
- a MIME type is valid UTF-8 without CR, LF or NUL, contains `/`, and is at
  most 255 bytes;
- custom metadata is a JSON-safe map with binary UTF-8 keys, at most 16,384
  encoded bytes, 128 aggregate map/list entries, and eight levels of nesting;
- call timeouts are positive and no greater than 300,000 milliseconds.

Unknown configuration, artifact, pagination, call, and repair options are
rejected. `capabilities/1` exposes these limits for tooling without requiring
callers to duplicate constants.

## In-memory ETS adapter

`adk_artifact_ets` is intended for tests and ephemeral nodes:

```erlang
{ok, ArtifactPid} = adk_artifact_ets:start_link(
    #{max_artifact_bytes => 67108864,
      max_scope_bytes => 268435456,
      max_total_bytes => 536870912,
      max_scope_artifacts => 25000,
      max_total_artifacts => 100000,
      max_page_limit => 1000,
      legacy_list_limit => 1000}),
ArtifactService = {adk_artifact_ets, ArtifactPid}.
```

The adapter enforces item, per-scope, and service-wide byte and count quotas
before inserting an artifact. Deletion releases byte/count capacity but keeps
the high-water version counter. Quota failures are explicit, for example
`{error, artifact_too_large}` or
`{error, {quota_exceeded, max_scope_bytes}}`.

All data and counters disappear when the service process stops. The current
reference adapter coordinates operations through one GenServer; deployments
that require filesystem/object-store-scale independent-scope throughput
should use a persistent adapter with sharded workers rather than increasing
ETS quotas without bound.

## Exact-scope sharded adapter

`adk_artifact_sharded` preserves the artifact-service API. Its default
`exact_scope` strategy assigns one active supervised worker to each exact app,
user, or session scope. Calls for one scope retain the selected adapter's
ordering; after first resolution, callers reach that worker through a
protected ETS fast path, so unrelated scopes do not queue behind the router or
one storage GenServer:

```erlang
{ok, ShardedArtifacts} = adk_artifact_sharded:start_link(
    #{adapter => adk_artifact_ets,
      adapter_config => #{max_artifact_bytes => 1048576},
      max_active_scopes => 1024,
      max_router_queue => 256}),
{ok, #{version := 1}} = adk_artifact_sharded:put(
    ShardedArtifacts,
    {session, <<"my_app">>, <<"user-42">>, <<"session-7">>},
    <<"reports/summary.txt">>, <<"ready">>,
    #{mime_type => <<"text/plain">>}),
{ok, #{active_scopes := 1, routing := exact_scope}} =
    adk_artifact_sharded:status(ShardedArtifacts),
ok = adk_artifact_sharded:stop(ShardedArtifacts).
```

The default worker adapter is ETS. For durable shards, select
`adapter => adk_artifact_fs` and put the base `root` in `adapter_config`; the
router derives a deterministic SHA-256, path-safe subroot for each scope, so a
router restart reopens the same data. The owner process and explicit `stop/1`
both synchronously clean up the per-instance dynamic supervisor and children.
A failed worker is removed and recreated on the next call; an ETS shard is
volatile, while a filesystem shard reloads its published versions.

`max_active_scopes` and `max_router_queue` are hard admission bounds. An
independent guard monitors each unresolved caller, owns the atomic cold-route
permit, and releases it on caller death or timeout. The router rechecks that
caller before starting a worker, so a stale queued request cannot create an
abandoned shard.

For the default volatile ETS adapter, idle reclamation is disabled: evicting a
worker would discard its artifacts. Its active-scope ceiling is therefore a
lifetime/cardinality bound until a worker exits or the router restarts, and a
new scope at capacity returns `{error, max_active_scopes_reached}`. With the
durable filesystem adapter, the router can instead reclaim the
least-recently-used worker at capacity after all of its operation leases are
idle for `idle_scope_timeout_ms` (default 60000; range 1 through 86400000).
The next worker for that scope reopens the same durable data. If no worker is
eligible, admission still returns `max_active_scopes_reached`.

Exact-scope adapter quotas are enforced independently inside each shard;
capabilities report `quotas.enforcement_scope => exact_scope_shard` and
`global_quota => false`. A direct wrapper can instead set
`scope_strategy => shared`, creating one adapter instance that preserves all
authorized scopes, reports `active_scopes => 1`, and enforces the adapter
limits globally (`shared_adapter` and `global_quota => true`). The 0.10
`ephemeral_local` profile uses that shared shape. Status exposes routing, idle
timeout, whether reclamation is active, and the eviction count; sharding
capabilities expose the strategy, timeout, and reclamation mode. Use an outer
admission policy or a custom adapter when a durable exact-scope deployment
requires one aggregate budget across all scopes.

## Durable filesystem adapter

`adk_artifact_fs` persists data and metadata below a dedicated root:

```erlang
{ok, ArtifactPid} = adk_artifact_fs:start_link(
    #{root => <<"/var/lib/my_app/adk-artifacts">>,
      max_artifact_bytes => 67108864,
      max_page_limit => 1000,
      legacy_list_limit => 1000,
      max_scan_entries => 10000,
      recovery_grace_ms => 300000}),
ArtifactService = {adk_artifact_fs, ArtifactPid},

Scope = {session, <<"my_app">>, <<"user-42">>, <<"session-7">>},
{ok, #{version := 1}} = adk_artifact_fs:put(
    ArtifactPid, Scope, <<"reports/summary.txt">>, <<"ready">>,
    #{mime_type => <<"text/plain">>,
      metadata => #{<<"source">> => <<"agent">>}}),
{ok, #{data := <<"ready">>}} = adk_artifact_fs:get(
    ArtifactPid, Scope, <<"reports/summary.txt">>, latest).
```

The configured root must be a real directory, not a symbolic link. Scope and
logical names are SHA-256-addressed and never become path components. Metadata
is checked against the requested scope, name, and version on every read. The
stored size and digest are checked before content is returned. Metadata and
data files are size-checked before being read into the VM. Corruption fails as
`{error, corrupt_artifact}` rather than returning untrusted bytes.

`max_scan_entries` must be at least three. To ensure allocation fails before
the bounded directory scans themselves become unreadable, the adapter admits:

- `max_scan_entries div 2` lifetime scopes per storage root;
- `max_scan_entries div 2` lifetime logical names per scope; and
- `max_scan_entries div 3` lifetime versions per scoped logical name.

Capabilities expose these values as `max_lifetime_scopes`,
`max_lifetime_names_per_scope`, and `max_lifetime_versions_per_name` in the
`quotas` map. A new allocation beyond them returns
`{error, artifact_scope_capacity_reached}`,
`{error, artifact_name_capacity_reached}`, or
`{error, artifact_version_capacity_reached}` respectively. Scope/name slots
and version reservations are created exclusively, making admission safe across
multiple service processes sharing one root. Choose the scan bound from
lifetime churn, not only concurrently retained artifacts.

### Publication and crash recovery

Each `put` creates an exclusively written, synced `.reserve` file first. The
payload and metadata are then written and synced under request-unique staging
names. The payload is renamed into place before the metadata; the atomic
metadata rename is the only publication point. Readers and list operations
only consider final metadata names, so they ignore an interrupted payload or
partial staging file. Multiple service processes using the same root race on
exclusive reservations and therefore allocate distinct versions.

The reference filesystem adapter still coordinates each configured service
through one GenServer, so filesystem scans and mutations for independent
scopes are serialized within that process. The reservation protocol keeps
multiple service instances safe, but it is not a throughput-sharding policy.
High-throughput deployments should partition scopes across supervised workers
with `adk_artifact_sharded`, or implement the same service contract over a
sharded object store.

A crash can leave staging files or a final payload without published metadata.
They are invisible, and `repair/2` can remove them after a safety grace period:

```erlang
{ok, #{scanned := Scanned,
       removed := Removed,
       reservations_preserved := Preserved,
       corrupt := Corrupt}} =
    adk_artifact_fs:repair(
      ArtifactPid, #{limit => 1000, min_age_ms => 300000}).
```

Repair never removes reservation files, so an interrupted or deleted version
is not reused after restart. It reports, but does not automatically erase, a
published metadata record whose data file is missing. `min_age_ms => 0` is
useful in a stopped-writer maintenance window and deterministic tests; do not
use it while another service instance may still be staging a write. Traversal
and repair are bounded by `max_scan_entries` and the requested repair `limit`.

Because scope/name slots and version reservations are durable non-reuse
tombstones, deleting artifacts does not restore any lifetime allocation
capacity. Repair recognizes and preserves the slot records; it does not count
them as ordinary staging garbage. Once a bound is reached, rotate to a new
name, scope, or root as appropriate, or restart with a deliberately larger
`max_scan_entries`. Focused filesystem coverage passes 15 tests, including
multi-instance slot races, failure before listing/repair scan exhaustion,
delete/restart persistence of every ceiling, publication, repair, corruption,
and deadline cases.

Erlang's portable `file` API can sync each created file but does not expose a
portable directory `fsync`. The adapter therefore guarantees atomic reader
visibility and synced file contents; deployments requiring a documented
power-loss directory-entry guarantee should provide an object-store adapter or
a platform-specific storage layer with that durability contract.

The artifact directory is an application-owned trust boundary. Give it
least-privilege filesystem permissions, keep it outside a served document
root, and use an encrypted volume when artifact confidentiality requires it.
The adapter does not encrypt content itself and must not be used as a secret
store.

## GCS-compatible object storage and bounded transfer (0.10)

`adk_artifact_gcs` implements the same exactly scoped immutable-version
contract over Google Cloud Storage-compatible object operations. Scope and
logical names become deterministic SHA-256 tokens rather than object-name
components. A create-only reservation allocates a version, the data object is
written create-only, and a create-only manifest is the publication point.
Loaded manifests are validated against the requested scope, name, and version.

```erlang
{ok, Gcs} = adk_artifact_gcs:start_link(
    #{bucket => <<"my-artifacts">>,
      project => <<"my-project">>,
      credential => {my_gcs_credential, credential_handle},
      max_artifact_bytes => 67108864,
      max_concurrency => 32,
      stream => #{chunk_bytes => 65536,
                  max_credit_messages => 8,
                  timeout_ms => 30000}}),
GcsService = {adk_artifact_gcs, Gcs}.
```

The default transport is `adk_artifact_gcs_http_transport`; applications may
inject only a trusted module implementing `adk_artifact_gcs_transport`. The
credential handle must implement `access_token/1`; resolution runs in a
deadline- and heap-bounded worker and the token is never accepted from an
artifact request. Operators still own bucket policy, endpoint and TLS trust,
credential lifecycle, retention, encryption, audit, and regional durability.
This is an adapter, not a managed GCS provisioning service.

`get_range/6` performs a bounded byte-range read. `adk_artifact_stream`
negotiates transfer support through `capabilities/1` and exposes
`open_upload/5`, `send_chunk/3,4`, `finish_upload/1,2`, `open_download/5`,
`credit/3`, `ack/2`, `recv/2`, and `cancel/2`. Upload chunks receive a
synchronous acknowledgement and next credit grant. Downloads require explicit
message/byte credit and an acknowledgement for every chunk; at most one chunk
is in flight. A stream is owner-bound, size/deadline limited, and cancelled
when its owner exits. Unsupported adapters return `unsupported_transfer`
instead of silently falling back. The current GCS transfer worker applies
mailbox backpressure but still materializes the complete bounded artifact; it
is not a resumable/multipart zero-copy GCS upload or download.

## Durable artifact effects and reconciliation (0.10)

Pass an initialized `adk_artifact_effect_journal` handle as Runner option
`artifact_effect_journal` to protect least-authority artifact writes whose
storage effect and session-event commit cross two durability boundaries. The
Mnesia journal stores only intent, request digests, opaque resource IDs,
bounded metadata/receipts, phases, and lease state—never artifact bytes,
credentials, or service handles. The context path records intent before the
external mutation, records the applied effect, and marks it committed only
after the correlated event is durable. If the effect may have happened but the
journal/event boundary cannot complete, the call returns
`artifact_effect_pending_reconciliation` rather than pretending it rolled
back.

`adk_artifact_orphan_reconciler:run/3` performs a bounded synchronous pass over
lease-fenced orphan claims. Its application-owned
The `adk_artifact_reconcile_handler` callback `reconcile/3` must return `committed`,
`compensated`, or `not_applied`; callback time and item count are bounded, and
failures return to bounded retry policy. The core cannot infer an external
backend's outcome. Each deployment must supply an idempotent observation and
compensation policy appropriate to its backend. Terminal journal history has
explicit bounded retention/pruning; no automatic background reconciler or
universal compensation algorithm is claimed.

## Runner integration

Pass a validated service reference to `adk_runner:new/4`:

```erlang
Runner = adk_runner:new(
    AgentPid, <<"my_app">>, erlang_adk_session,
    #{artifact_svc => ArtifactService}).
```

Artifact instruction placeholders are resolved only from the exact invocation
scope through a bounded service call. A local tool that declares artifact
authority receives an opaque single-call capability, not `ArtifactService`:

```erlang
-module(save_report_tool).
-behaviour(adk_tool).

-export([schema/0, context_capabilities/0, execute/2]).

schema() ->
    #{<<"name">> => <<"save_report">>,
      <<"description">> => <<"Save the generated report">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"text">> => #{<<"type">> => <<"string">>}},
            <<"required">> => [<<"text">>],
            <<"additionalProperties">> => false}}.

context_capabilities() -> [artifact_put].

execute(#{<<"text">> := Text}, Context) ->
    adk_context:save_artifact(
      Context, <<"reports/final.txt">>, Text,
      #{mime_type => <<"text/plain">>}).
```

The public helpers are `save_artifact/4`, `load_artifact/3`,
`list_artifacts/2`, `list_artifact_versions/3`, `delete_artifact/3`, and
`attach_artifact/3`. Corresponding declarations are `artifact_put`,
`artifact_get`, `artifact_list`, `artifact_list_versions`, `artifact_delete`,
and `artifact_attach`. An undeclared operation fails as
`{error, {context_capability_denied, Operation}}`.

The opaque capability is also the adapter trust boundary. Successful
put/get/version-list and legacy-list records must embed the exact bound scope
and requested name; modern name-page envelopes also carry the exact scope and
their bare names are shape/name validated. A foreign-scope, wrong-name, or
malformed successful response fails closed as
`{error, invalid_artifact_service_reply}` before data or an effect escapes.

Successful tool mutations are correlated to the tool call and projected into
the canonical tool event's `<<"context_effects">>` action as metadata-only
artifact deltas. Artifact data and service handles are never stored there.

### Model-selected attachment

Add `adk_load_artifacts_tool` to an agent's tool list when the model should be
able to select existing artifacts:

```erlang
{ok, AgentPid} = erlang_adk:spawn_agent(
    <<"ArtifactReader">>,
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>,
      instructions =>
          <<"Load a relevant artifact before answering questions about it.">>},
    [adk_load_artifacts_tool]),
Runner = adk_runner:new(
    AgentPid, <<"my_app">>, erlang_adk_session,
    #{artifact_svc => ArtifactService,
      context_policy =>
          #{max_bytes => 1048576,
            max_request_bytes => 2097152,
            overflow => error}}).
```

The tool returns metadata only. Runner resolves the exact committed
name/version, verifies scope, size, MIME type, and SHA-256 digest, and injects
bounded `adk_content` parts into only the next model request. A later model
round must request the artifact again. Bytes are not copied into session state,
ordinary history, the durable tool response, or developer diagnostics.

The built-in supports at most eight selected artifacts and Runner applies a
10 MiB aggregate attachment bound. The underlying artifact service may impose
a smaller item limit.

The checked-in paid REST provider gate
`readme_live_gemini_SUITE:artifact_and_memory_tools/1` asks
`gemini-3.1-flash-lite` to select a real scoped image, proves the correlated
attachment effect, and proves the bytes are absent from persisted session
events. The targeted REST case passed on 2026-07-14. This supplements the
deterministic scope, attachment, and persistence tests. The final v0.7 full
REST run also passed this case; 15 of 17 REST cases passed overall, with the
two failures caused by HTTP 429 in Search grounding and cached-content
creation.

The built-in declaration contains strict JSON Schema constraints, including
`additionalProperties`. At the Gemini boundary it is therefore emitted as
`parametersJsonSchema`, while Erlang ADK retains the same compiled schema for
local argument validation. The targeted REST pass exercises that projection.

### Developer inspection

The authenticated developer API and CLI can list names and metadata-only
versions and can delete an exact scope after a matching confirmation payload.
They never return artifact bytes or custom metadata. Configure an exact-scope
`resource_provider` as documented in the README; a provider receives the
requested `{session, App, User, Session}` and may return `{error, forbidden}`.
Each returned version must also embed that exact scope. A mismatched adapter
record is rejected as unavailable instead of being relabelled under the HTTP
path scope.

## Current limits

- ETS and filesystem operations remain whole-binary. Capability-negotiated
  credit/ack transfer and byte ranges are implemented by the GCS-compatible
  adapter; callers must handle `unsupported_transfer` for other adapters;
- the filesystem adapter provides atomic reader visibility and repairable
  staging but cannot promise a portable directory `fsync` through Erlang's
  cross-platform `file` API;
- the effect journal makes ambiguous artifact writes visible and lease-fenced,
  but recovery requires an operator/backend-specific reconcile handler and
  explicit idempotency/compensation policy;
- direct ETS and filesystem services serialize operations per process; the
  optional router wrapper provides bounded exact-scope overlap or shared
  routing. Durable exact-scope workers support idle LRU reclamation only at
  capacity; volatile exact-scope workers are not reclaimed. The wrapper does
  not aggregate exact-scope quotas or expose a cross-shard `repair/2`
  operation;
- filesystem lifetime allocation is deliberately finite for scopes, names,
  and versions; deletion preserves non-reuse slots/reservations and therefore
  does not replenish capacity;
- developer tooling deliberately supports inspection and deletion, not raw
  upload/download, filesystem repair, or content preview.
