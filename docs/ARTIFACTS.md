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

`adk_artifact_sharded` preserves the artifact-service API while assigning one
stable supervised worker to each exact app, user, or session scope. Calls for
one scope retain the selected adapter's ordering; after first resolution,
callers reach that worker through a protected ETS fast path, so unrelated
scopes do not queue behind the router or one storage GenServer:

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
abandoned shard. There is no idle-worker eviction in 0.5, so reaching the
active-scope ceiling returns `{error, max_active_scopes_reached}` until a
worker exits or the router is restarted. Adapter quotas are enforced
independently inside each shard;
capabilities deliberately report `global_quota => false`. Use an outer
admission policy or a custom adapter when the deployment requires one aggregate
budget across all scopes.

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

Current 0.5 limitations are explicit:

- whole-binary operations are bounded, but credit/ack upload/download and
  byte-range streaming are not implemented;
- the filesystem adapter provides atomic reader visibility and repairable
  staging but cannot promise a portable directory `fsync` through Erlang's
  cross-platform `file` API;
- artifact event deltas are implemented, while full durable orphan recovery
  after a session-event persistence failure remains partial;
- direct ETS and filesystem services serialize operations per process; the
  optional sharded wrapper provides bounded exact-scope overlap, but does not
  aggregate quotas, idle-evict workers, or expose a cross-shard `repair/2`
  operation;
- filesystem lifetime allocation is deliberately finite for scopes, names,
  and versions; deletion preserves non-reuse slots/reservations and therefore
  does not replenish capacity;
- developer tooling deliberately supports inspection and deletion, not raw
  upload/download, filesystem repair, or content preview.
