# Scoped long-term memory

Erlang ADK 0.5 uses version 2 of `adk_memory_service`. Long-term memory is
always authorized by an explicit application/user scope:

```erlang
{user, AppName, UserId}
```

The same user identifier in two applications is two independent principals.
Metadata cannot widen this scope. Entries contain bounded UTF-8 content,
JSON-safe metadata, optional session/event provenance, a stable identifier,
SHA-256 digest, and timestamp. Memory is reference data rather than executable
instructions; Runner frames retrieved text as untrusted input before it reaches
a model.

Long-term memory and its Runner retrieval/ingestion path were already released
in 0.9. The 0.10 branch adds an opt-in supervised configuration layer:
`adk_runtime_service_bundle:start_link(ephemeral_local, #{})` selects one
shared ETS memory adapter, while `durable_local` selects exact-scope local
Mnesia workers. The shared adapter enforces one global quota across users;
durable limits remain per worker/shard. The bundle returns the same native
memory service reference. `durable_local` also atomically owns a private
Mnesia ingestion outbox, validates its adapter registration and health, and
injects durable ingestion into standard Runner options. Pending jobs survive a
bundle process restart, while stale or unhealthy references fail closed.
Disabled and `ephemeral_local` profiles do not create this private outbox; the
standalone opt-in described below remains compatible. Separately, 0.10 adds
bounded embedding and vector/hybrid contracts, an opt-in governance hook,
durable erasure epochs, and terminal outbox retention. The included vector
adapter is local and volatile, not a managed or distributed vector database. See
[`VERSION_0_10_0.md`](VERSION_0_10_0.md); 0.10 is still **IN DEVELOPMENT**.

## ETS and Mnesia adapters

`adk_memory_ets` is volatile and intended for tests or local development.
`adk_memory_mnesia` uses `disc_copies` and preserves entries across a normal VM
restart when the node name and Mnesia directory are stable. Both implement the
same deterministic lexical-overlap search contract:

```erlang
{ok, MemoryPid} = adk_memory_ets:start_link(#{}),
Scope = {user, <<"my_app">>, <<"user-42">>},

{ok, Entry} = adk_memory_ets:add_entry(
    MemoryPid, Scope,
    #{content => <<"OTP supervisors restart failed child processes">>,
      metadata => #{<<"topic">> => <<"otp">>},
      provenance => #{session_id => <<"session-7">>,
                      author => <<"user">>,
                      timestamp => erlang:system_time(millisecond)}},
    #{idempotency_key => <<"session-7:fact-1">>}),

{ok, [Hit]} = adk_memory_ets:search(
    MemoryPid, Scope, <<"supervisors restart">>,
    #{filter => #{<<"topic">> => <<"otp">>}, limit => 5}),
EntryId = maps:get(id, Entry),
EntryId = maps:get(id, Hit),

ok = adk_memory_ets:delete_entry(
    MemoryPid, Scope, EntryId),
ok = adk_memory_ets:stop(MemoryPid).
```

Use the same calls with `adk_memory_mnesia`. The adapter starts Mnesia and
creates its two local tables if needed:

```erlang
{ok, DurableMemoryPid} = adk_memory_mnesia:start_link(#{}),
#{contract_version := 2, durable := true} =
    adk_memory_mnesia:capabilities(DurableMemoryPid).
```

In a release, configure Mnesia's directory and distributed table-copy policy
before starting this adapter. The bundled implementation is a durable local
lexical reference adapter, not a distributed vector database. Applications
that need a managed index, multi-region replication, or provider-specific
retention should implement the corresponding service/vector/policy contracts.

Both adapters reject unknown options and expose configured limits through
`capabilities/1`. Deadline-aware mutations accept
`#{timeout_ms => PositiveMilliseconds}` as their final argument. The deadline
travels with queued work, so an expired request cannot later become an
invisible write:

```erlang
adk_memory_ets:add_entry(
    MemoryPid, Scope, #{content => <<"bounded fact">>}, #{},
    #{timeout_ms => 2000}).
```

## Embeddings and vector/hybrid retrieval (0.10)

`adk_memory_embedding_provider:embed/5` invokes an application-selected
embedding provider in a monitored, killable worker. The request and reply are
validated before crossing the boundary. Defaults cap a call at 5 seconds, 128
inputs, 64 KiB per input, 1 MiB total input, 8,192 dimensions, and 16 MiB of
vector result storage. A provider must return the requested model and exactly
one finite, fixed-width vector per input; credentials and endpoints remain in
its trusted handle.

`adk_memory_vector_ets` is the bounded local reference implementation of
`adk_memory_vector_adapter` and `adk_memory_hybrid_adapter`. It supports
app/user-scoped batch upsert, cosine-similarity search, weighted lexical/vector
hybrid search, exact-scope deletion, and content-free status. It enforces
entry, byte, dimension, batch, result-count, and result-byte ceilings. All data
is volatile and one instance fixes one vector dimension after its first
upsert.

These contracts are not silently substituted for `adk_memory_ets` or
`adk_memory_mnesia`, and merely configuring `memory_svc` does not call an
embedding provider. Applications own embedding refresh, index synchronization,
managed-vector adapters, and any bridge from vector hits into Runner retrieval.

## Exact-user sharded concurrency

`adk_memory_sharded` implements the same version-2 behavior. Its default
`exact_scope` strategy uses one active supervised adapter worker per exact
`{user, App, User}` scope. Same-user calls remain ordered by that worker, while
unrelated users execute concurrently after a protected ETS routing fast path:

```erlang
{ok, ShardedMemory} = adk_memory_sharded:start_link(
    #{adapter => adk_memory_mnesia,
      adapter_config => #{},
      max_active_scopes => 1024,
      max_router_queue => 256}),
#{contract_version := 2,
  durable := true,
  quota_scope := exact_scope_shard,
  global_quota := false} =
    adk_memory_sharded:capabilities(ShardedMemory),
{ok, _} = adk_memory_sharded:add_entry(
    ShardedMemory, {user, <<"my_app">>, <<"user-42">>},
    #{content => <<"OTP isolates failures">>},
    #{idempotency_key => <<"user-42:otp-fact">>}),
ok = adk_memory_sharded:stop(ShardedMemory).
```

The default adapter is `adk_memory_ets`; select `adk_memory_mnesia` when local
restart durability is required. The wrapper validates the complete v2 callback
set before startup and can be passed to Runner as
`{adk_memory_sharded, ShardedMemory}` or registered as a durable-outbox
adapter. Owner death and explicit `stop/1` clean up the per-instance dynamic
supervisor and its children. A failed worker is removed and recreated on the
next call; volatile ETS data is lost with that worker, while Mnesia data remains
in the scoped tables.

`max_active_scopes` bounds worker cardinality, while `max_router_queue`
strictly caps simultaneous cold-scope resolutions before they enter the
router. A guard independently monitors each unresolved caller, owns and
releases its permit on death or timeout, and prevents a stale queued route from
creating an abandoned worker. Resolved scopes use the protected ETS fast path.

For the default volatile ETS adapter, idle reclamation is disabled because
evicting a worker would discard its entries. Its active-scope ceiling is thus a
lifetime/cardinality bound until a worker exits or the router restarts. With
the durable Mnesia adapter, the router may reclaim the least-recently-used
worker at capacity after all of its operation leases are idle for
`idle_scope_timeout_ms` (default 60000; range 1 through 86400000). The next
worker for that exact user reopens the same Mnesia data. If no worker is
eligible, a new scope returns `{error, max_active_scopes_reached}`.

Exact-scope limits and quotas belong to each shard, not one aggregate service
budget, and capabilities report `quota_scope => exact_scope_shard` and
`global_quota => false`. A direct wrapper can instead set
`scope_strategy => shared`, creating one adapter instance for every authorized
scope, reporting `active_scopes => 1`, and enforcing its limits globally as
`shared_adapter`. The 0.10 `ephemeral_local` profile uses this shared shape.
Status exposes routing, idle timeout, whether reclamation is active, and the
eviction count; sharding capabilities expose the strategy, timeout, and
reclamation mode. Use an outer admission controller or custom backend for a
deployment-wide quota over durable exact-scope shards.

## Incremental ingestion and erasure

`add_events/5` sanitizes canonical session events, creates deterministic
idempotency keys, and reports additions, duplicates, and skipped events:

```erlang
{ok, Session} = erlang_adk_session:get_session(
    <<"my_app">>, <<"user-42">>, <<"session-7">>),
{ok, #{added := Added, duplicates := Duplicates, skipped := Skipped}} =
    adk_memory_ets:add_events(
      MemoryPid, Scope, <<"session-7">>, maps:get(events, Session), #{}).
```

Repeating the same call is safe: already indexed events are counted as
duplicates. Entry content that looks like a credential is rejected, known
secret metadata keys are redacted, and control-only or unsupported event
content is skipped.

Erasure is explicitly scoped:

```erlang
ok = adk_memory_ets:delete_entry(MemoryPid, Scope, EntryId),
ok = adk_memory_ets:delete_session(MemoryPid, Scope, <<"session-7">>),
ok = adk_memory_ets:delete_user(MemoryPid, Scope).
```

`{error, not_found}` is returned when the requested scoped target does not
exist. There is no cross-user search or deletion API.

### Governance hooks and erasure epochs (0.10)

`adk_memory_policy:check/6` is an opt-in, fail-closed boundary for `ingest`,
`search`, `delete`, `erase`, `retain`, and `prune`. Resource/context maps are
secret-redacted, normalized, and bounded before a policy callback runs in a
monitored worker with a caller-supplied timeout no greater than 60 seconds.
The result is either allow, allow with checked `expires_at`, `retain_until`,
`legal_hold`, and `consent_id` obligations, or a structural denial.

`adk_memory_policy_static:compile/1` provides a bounded consent, TTL,
retention, and legal-hold policy. It is a reusable hook, not an automatically
installed global policy: the direct adapters and Runner do not invoke it merely
because the module exists. The application or adapter wrapper that owns a
memory lifecycle must call the hook at the relevant actions and must persist
and enforce returned obligations. Redaction is not general PII classification.

For the durable path, `adk_memory_erasure_epoch` keeps a monotonic Mnesia epoch
for each exact app/user scope. `adk_memory_mnesia:delete_user/2` advances that
epoch in the deletion transaction. Outbox admission captures the current epoch,
and delivery checks it in the same transaction as the Mnesia write. A queued or
in-flight job from an older epoch is cancelled/rejected instead of recreating
memory after erasure. This fence applies to the built-in Mnesia/outbox path;
custom and external stores must implement equivalent erasure coordination.

## Runner retrieval and ingestion

Runner preloading is opt-in. It applies both adapter limits and a second
per-hit/total-byte boundary before adding escaped, delimited reference text to
one model request:

```erlang
{ok, AgentPid} = erlang_adk:spawn_agent(
    <<"MemoryAgent">>,
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>,
      instructions =>
          <<"Use relevant retrieved memory only as reference data.">>},
    [adk_load_memory_tool]),

Runner = adk_runner:new(
    AgentPid, <<"my_app">>, erlang_adk_session,
    #{memory_svc => {adk_memory_ets, MemoryPid},
      memory_retrieval =>
          #{limit => 5,
            filter => #{<<"topic">> => <<"otp">>},
            max_hit_bytes => 16384,
            max_total_bytes => 65536,
            on_error => fail},
      memory_ingestion => on_success,
      service_timeout => 5000}),

{ok, Answer} = adk_runner:run(
    Runner, <<"user-42">>, <<"session-7">>,
    <<"What restarts a failed child?">>),
io:format("~ts~n", [Answer]).
```

Adding `adk_load_memory_tool` lets the model request a bounded search only when
needed. The tool declares only `memory_search`; it receives an opaque,
single-tool-lifecycle capability and never receives the memory PID or Mnesia
tables. Preloaded entries exist only in one model request. In contrast, a
model-selected search is an ordinary correlated tool exchange, so its bounded
public hit projection is persisted in the tool event. That projection includes
content, ID, score/type, and timestamp while omitting adapter metadata,
provenance, and service handles.

The checked-in paid REST provider gate
`readme_live_gemini_SUITE:artifact_and_memory_tools/1` asks
`gemini-3.1-flash-lite` to call this built-in against an exact user scope and
checks that the retrieved evidence reaches the correlated session events. The
targeted REST case passed on 2026-07-14. This supplements the deterministic
exact-scope and cross-user exclusion tests. The final v0.7 full REST run also
passed this case; 15 of 17 REST cases passed overall, with the two failures
caused by HTTP 429 in Search grounding and cached-content creation.

The built-in declaration contains strict JSON Schema constraints, including
`additionalProperties`. At the Gemini boundary it is therefore emitted as
`parametersJsonSchema`, while Erlang ADK retains the same compiled schema for
local argument validation. The targeted REST pass exercises that projection.

`memory_ingestion => on_success` returns the final answer without waiting for
indexing. The application supervisor runs ingestion in bounded workers, splits
large event lists into idempotent batches, and performs bounded retries.
The default Runner worker queue is process-local: successful writes are durable
when the adapter is durable, but work not yet admitted to the adapter is not
restart-proof.

### Durable ingestion outbox

Applications that require restart-safe admission can use the Mnesia-backed
`adk_memory_outbox` and a bounded processor. The durable job stores sanitized
canonical events, an exact scope/session, batch checkpoints, and a stable
`{AdapterModule, AdapterId}`. It never persists a PID, service handle,
credential, or resolver state:

```erlang
{ok, Outbox} = adk_memory_outbox:init(#{}),
{ok, Registry} = adk_memory_outbox_registry:start_link(),
MemoryService = {adk_memory_mnesia, DurableMemoryPid},
AdapterIdentity = {adk_memory_mnesia, <<"primary-memory">>},
ok = adk_memory_outbox_registry:register(
    Registry, AdapterIdentity, MemoryService),
{ok, Processor} = adk_memory_outbox_processor:start_link(
    #{outbox => Outbox,
      resolver => {adk_memory_outbox_registry, Registry},
      max_concurrency => 4,
      call_timeout_ms => 5000,
      lease_ms => 15000}),

{ok, Job} = adk_memory_outbox_processor:submit(
    Processor,
    #{scope => Scope,
      session_id => <<"session-7">>,
      adapter => AdapterIdentity,
      events => maps:get(events, Session),
      max_attempts => 5}),
JobId = maps:get(job_id, Job),
{ok, JobStatus} = adk_memory_outbox_processor:status(Processor, JobId).
```

Multiple processors may share the tables. Claims use an unguessable ownership
token and a bounded lease time; after a worker or node failure another
processor can retry the batch. Stable adapter resolution runs in a monitored,
timeout-bounded worker that is killed and drained on timeout. Capability
discovery is also bounded. After both finish and immediately before
`add_events`, the processor renews the lease and revalidates that the original
token still owns the job. A lost or expired owner does not begin the adapter
mutation. Delivery remains at-least-once, so the processor requires an adapter
advertising `contract_version >= 2`,
`idempotent_ingestion`, and `incremental_events`; `add_events/5` is required
and deadline-aware `add_events/6` is preferred. Stable event IDs make a
repeated batch a duplicate rather than a second memory entry.

The volatile registry is also an admission barrier. On initial startup and
after a registry child restart, processors claim no durable job until the
application has deterministically re-registered at least one adapter. The
registry then returns only the bounded set of hydrated stable identities, so
registering adapter A cannot release queued work for unavailable adapter B.
Claim discovery scans at most `max_claim_scan` entries in the ordered schedule
index and persists a rotating cursor; an unavailable identity at the front
cannot permanently starve later hydrated identities. Resolver readiness and
the identity snapshot run in bounded monitored workers and malformed,
oversized, timed-out, or failed replies close the barrier.

Jobs and total bytes have global and per-scope admission limits. Events are
size/count bounded and sanitized before the enqueue transaction. Retry uses
bounded exponential backoff and becomes terminal after `max_attempts`.
`adk_memory_outbox_processor:status/2` and the lower-level
`adk_memory_outbox:stats/1`, `cancel/3`, and terminal-job `delete/2` expose
explicit lifecycle operations without returning content or runtime handles.

The ordered schedule table indexes pending/retry due times, running-lease
expiry, and terminal completion time. Claims, expired-lease recovery, erasure-
epoch fencing, and terminal pruning therefore scan explicit bounded index
windows instead of folding the jobs table. Epoch fencing is rechecked inside
claim and immediately before mutation renewal.

Terminal capacity is a hard reservation across active plus terminal jobs:
every admitted active job reserves one eventual terminal slot. Defaults retain
terminal history for seven days, cap the combined reservation at 100,000
records, and cap one prune pass at 1,000 records. A pre-cap database that is
already over the configured ceiling remains startable for migration and
bounded pruning, but new admissions fail closed until delete/prune creates
headroom. Use `adk_memory_outbox:prune_terminal/2,3`,
`adk_memory_outbox_processor:prune_terminal/2`, or the supervised
`adk_memory_outbox_sup:prune_terminal/1` API to remove only terminal rows older
than the configured retention cutoff. Terminal counts and the ordered index
are rebuilt during migration from older jobs-only data. Pruning is explicit
and bounded; there
is no timer that silently deletes history.

The batch ceiling is 500 events and the default job ceiling is 5,000 events.
The processor validates `lease_ms >= 2 * call_timeout_ms + 250` to leave a
bounded resolution/capability phase and a fresh adapter-call lease. The token
fences outbox state transitions, but it is not a true generation fence inside
an arbitrary adapter: a lease can expire after the final pre-call check while
adapter code is running. Adapters must honor the supplied deadline where
available, and correctness across a retry relies on stable event-ID
idempotency. Job-level deduplication requires an exact adapter, scope, session,
and ordered event-ID sequence in one erasure epoch; the epoch is part of the
durable job identifier. Repeating the same request in the same epoch is
idempotent. After successful erasure advances the epoch, the same logical
request receives a new job ID and may be admitted again without reviving pre-
erasure work. Partially overlapping jobs rely on the v2 adapter's event-ID
idempotency. This is deliberately not an exactly-once outbox.

The outbox registry must re-register the stable adapter identity after an
adapter restart. Pending jobs remain durable while resolution is unavailable
and retry according to policy.

With the `durable_local` runtime profile, `adk_runtime_service_bundle` owns a
private outbox supervisor in the same atomic generation as the session,
artifact, and memory services. Startup validates the selected memory adapter's
durable-ingestion capabilities—including numeric `contract_version >= 2`,
idempotent/incremental ingestion, and erasure-epoch fencing—before exposing the
bundle. Unknown or invalid nested `outbox`, `registry`, and `processor` options
fail profile compilation; names are forced private and Runner attempts remain
within its hard ceiling. `services/1`,
`runner_spec/1`, `status/1`, and `health/1` expose validated, redacted outbox
service state; `runner_spec/1` injects the required `memory_ingestion` map into
standard Runner creation. Outbox Mnesia jobs survive a bundle/outbox process
restart and resume after the stable adapter is re-registered. A stale bundle
generation, dead private outbox, unhealthy registry/processor, or mismatched
adapter identity is an error rather than a fallback to process-local writes.

`ephemeral_local` and the disabled runtime-service profile intentionally own no
private outbox. Existing applications may continue to use the standalone
`memory_outbox_enabled` application setting and explicit Runner options below;
when `durable_local` is enabled, legacy module-named `adk_memory_outbox_sup`
APIs resolve the one bundle-owned supervisor rather than starting or addressing
a duplicate processor.

Outbox health is independent of retained-job cardinality. It validates the
jobs, usage, ordered schedule, and erasure-epoch table schemas/topology, then
performs fixed point reads and one sentinel write in a single transaction. The
sentinel leaves all four table row counts unchanged. `mnesia_majority` mode
fails admission, claims, renewal, and health closed unless the four tables
share at least two configured nodes; single-node mode is explicit and does not
claim multi-node readiness. Public status and crash formatting omit service
handles, event content, resolver state, owner tokens, and private inputs.

Runner can use the standalone compatibility outbox when it is enabled before
application startup:

```erlang
ok = application:set_env(erlang_adk, memory_outbox_enabled, true),
ok = application:set_env(
    erlang_adk, memory_outbox_options,
    #{outbox => #{max_active_per_scope => 1000,
                  max_active_bytes_per_scope => 67108864},
      registry => #{max_entries => 128},
      processor => #{max_concurrency => 4,
                     call_timeout_ms => 5000,
                     lease_ms => 15000}}),
{ok, _} = application:ensure_all_started(erlang_adk).
```

Select durable admission on the Runner with a stable adapter identifier. The
adapter module comes from `memory_svc`; the PID or handle is registered only in
the runtime registry:

```erlang
DurableRunner = adk_runner:new(
    AgentPid, <<"my_app">>, erlang_adk_session_mnesia,
    #{memory_svc => {adk_memory_mnesia, DurableMemoryPid},
      memory_ingestion =>
          #{mode => durable,
            adapter_id => <<"primary-memory">>,
            max_attempts => 5}}).
```

`on_success` remains the lower-latency process-local shorthand. Durable mode
performs a bounded local Mnesia admission transaction after the final session
events exist, then leaves adapter delivery to the processors. Runner creation
fails with `memory_outbox_runtime_required` if the configured supervisor,
registry, or processor is unavailable. If the bounded admission transaction
later fails, the run caller receives
`{error, {durable_memory_ingestion_not_admitted, Reason}}` instead of a
successful final answer. The already persisted final session event is not
rolled back; retry the same logical invocation only under the application's
normal invocation-id/idempotency policy.

Successful admission emits `[erlang_adk, memory, outbox, admitted]`; use
`adk_memory_outbox_sup:status/1` with the telemetry-correlated job ID for
operational status. Admission is the durable boundary, not delivery: a later
terminal adapter failure is visible through job status and does not change the
already completed model run. Submission waits only for sanitization and the
bounded local Mnesia transaction; it never waits for adapter resolution or
delivery.

## Custom least-authority tools

A local tool opts into only the context operations it needs:

```erlang
-module(memory_lookup_tool).
-behaviour(adk_tool).

-export([schema/0, context_capabilities/0, execute/2]).

schema() ->
    #{<<"name">> => <<"memory_lookup">>,
      <<"description">> => <<"Find relevant saved preferences">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"query">> => #{<<"type">> => <<"string">>}},
            <<"required">> => [<<"query">>],
            <<"additionalProperties">> => false}}.

context_capabilities() -> [memory_search].

execute(#{<<"query">> := Query}, Context) ->
    adk_context:search_memory(
      Context, Query, #{filter => #{}, limit => 5}).
```

Available memory declarations are `memory_search`, `memory_add`, and
`memory_delete`. A declared-capability tool is projected to public invocation
identity plus its opaque token. Operations outside the declaration return
`{error, {context_capability_denied, Operation}}`. Modules without
`context_capabilities/0` remain on the explicit compatibility path for 0.5;
new tools should always declare their authority.

The opaque capability verifies the embedded scope on every successful add and
every search hit. One foreign-scope or malformed record rejects the whole
adapter response as `{error, invalid_memory_service_reply}`; it is never
partially filtered or relabelled, and a rejected add records no effect.

## Developer inspection

The authenticated developer API/CLI exposes bounded search projections for one
exact `{user, App, User}` scope and exact confirmed erasure. It never returns
adapter metadata, provenance, handles, or tables. Every returned hit must
itself embed the requested scope; a mismatched adapter record is rejected as
unavailable instead of being relabelled under the HTTP path scope.

## Current limits

- The primary ETS/Mnesia `adk_memory_service` adapters search by lexical
  overlap. `adk_memory_vector_ets` supplies a separate local vector/hybrid
  reference contract; managed indexes and automatic synchronization remain
  adapter/application responsibilities.
- Direct ETS and Mnesia reference adapters perform storage and lexical ranking
  in one GenServer per service. The optional router wrapper overlaps unrelated
  exact user scopes while preserving same-scope ordering, or routes through one
  shared adapter. Durable exact-scope workers support idle LRU reclamation only
  at capacity; volatile exact-scope workers are not reclaimed. Exact-scope
  quotas are not aggregated.
- The core rejects known secret patterns and keys, but this is not general PII
  detection. The static governance policy exists but is opt-in; applications
  must invoke it and enforce its obligations on every relevant path.
- Explicit entry/session/user erasure is implemented. Built-in Mnesia memory
  and the durable outbox coordinate user erasure with transactional epochs;
  ETS, custom, and external backends need their own equivalent fencing.
- The built-in outbox defaults to local `disc_copies`. Explicit
  `mnesia_majority` mode requires at least two nodes shared by all four tables
  and otherwise fails closed. Cross-node recovery still needs the deployment's
  replication, backup, restore, and partition policy; no multi-node node-loss
  Common Test is claimed. Completed, failed, or cancelled history uses the hard
  active-plus-terminal reservation and bounded indexed explicit pruning, not an
  automatic timer.
- The outbox has lease-owned, idempotent at-least-once delivery, not an
  adapter-generation fence or exactly-once external side effects.
- Runner preloading and model-selected loading are independent opt-ins. Merely
  configuring `memory_svc` does not change the prompt.
