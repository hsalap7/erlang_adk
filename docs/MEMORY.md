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
that need embeddings, managed retention, or multi-region replication should
implement the same `adk_memory_service` behavior.

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

## Exact-user sharded concurrency

`adk_memory_sharded` implements the same version-2 behavior with one stable
supervised adapter worker per exact `{user, App, User}` scope. Same-user calls
remain ordered by that worker, while unrelated users execute concurrently
after a protected ETS routing fast path:

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
There is no idle-worker eviction in 0.5. Limits and quotas belong to each
exact-scope shard, not one aggregate service budget, and capabilities
therefore report `global_quota => false`. Use an outer admission controller or
custom backend for a deployment-wide quota.

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

Jobs and total bytes have global and per-scope admission limits. Events are
size/count bounded and sanitized before the enqueue transaction. Retry uses
bounded exponential backoff and becomes terminal after `max_attempts`.
`adk_memory_outbox_processor:status/2` and the lower-level
`adk_memory_outbox:stats/1`, `cancel/3`, and terminal-job `delete/2` expose
explicit lifecycle operations without returning content or runtime handles.

The batch ceiling is 500 events and the default job ceiling is 5,000 events.
The processor validates `lease_ms >= 2 * call_timeout_ms + 250` to leave a
bounded resolution/capability phase and a fresh adapter-call lease. The token
fences outbox state transitions, but it is not a true generation fence inside
an arbitrary adapter: a lease can expire after the final pre-call check while
adapter code is running. Adapters must honor the supplied deadline where
available, and correctness across a retry relies on stable event-ID
idempotency. Job-level deduplication requires an exact adapter, scope, session,
and ordered event-ID
sequence; partially overlapping jobs rely on the v2 adapter's event-ID
idempotency. This is deliberately not an exactly-once outbox.

The outbox registry must re-register the stable adapter identity after an
adapter restart. Pending jobs remain durable while resolution is unavailable
and retry according to policy.

Runner can use this outbox when it is enabled before application startup:

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

- Search is lexical overlap; semantic/vector retrieval is an adapter.
- Direct ETS and Mnesia reference adapters perform storage and lexical ranking
  in one GenServer per service. The optional sharded wrapper overlaps unrelated
  user scopes while preserving same-scope ordering, but does not aggregate
  quotas or idle-evict workers.
- The core rejects known secret patterns and keys, but this is not general PII
  detection or a consent policy.
- Retention/TTL and managed-memory lifecycle policies are adapter concerns in
  0.5; explicit entry/session/user erasure is implemented. Applications must
  coordinate erasure with pending outbox jobs so deleted session data is not
  re-ingested later.
- The built-in outbox tables are local `disc_copies`. Cross-node recovery needs
  the deployment's normal Mnesia replication, majority, backup, and restore
  policy. Completed, failed, or cancelled job history has no automatic
  retention timer; operators delete terminal jobs explicitly with
  `adk_memory_outbox:delete/2`.
- The outbox has lease-owned, idempotent at-least-once delivery, not an
  adapter-generation fence or exactly-once external side effects.
- Runner preloading and model-selected loading are independent opt-ins. Merely
  configuring `memory_svc` does not change the prompt.
