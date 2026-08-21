# Plugins, observability, and evaluation

This document defines the released cross-cutting runtime contracts introduced
in Erlang ADK 0.7 and the bounded service foundations being added for 0.10. It
tracks the externally observable behavior of the official
[plugin](https://adk.dev/plugins/),
[observability](https://adk.dev/observability/), and
[evaluation](https://adk.dev/evaluate/) capability families while preserving
Erlang's process-isolation and supervision model.

## Runner plugin lifecycle

Plugins belong to a Runner, not an agent. `adk_runner:new/4` compiles the
ordered descriptor list once and rejects malformed configuration before a run
is accepted. Each stateless hook executes in its own monitored lightweight
process with descriptor-level `timeout_ms`, `max_heap_words`, and result-size
bounds.

For a corresponding lifecycle phase, precedence is:

1. ordered Runner-global plugins;
2. the agent's existing local callback, unless a global plugin completed the
   phase early;
3. the model, tool, agent, or run operation;
4. ordered global after/error plugins;
5. the corresponding local after/error callback, unless a global plugin
   completed the phase early.

### Outcomes

| Outcome | Behavior |
| --- | --- |
| `observe`, `continue`, or `ok` | Keep the current phase value and continue. |
| `{amend, Value}` | Replace the current phase value and continue through the remaining plugins, local callback, and operation. |
| `{return, Value}` | Return immediately from that phase and skip the remaining plugins, local callback, and operation. |
| `{replace, Value}` | Compatibility alias for `{return, Value}`; it does **not** mean amend-and-continue. |
| `{halt, Reason}` | Stop with a typed, bounded error. |

The same intervention vocabulary applies to the recoverable
`on_model_error` and `on_tool_error` phases. `on_agent_error`, `on_run_error`,
and success-only `after_run` are best-effort notifications: failures are
recorded structurally, but neither a callback failure nor an intervention
result can replace or halt the outcome being reported, even when the
descriptor's ordinary failure policy is closed. The legacy `on_error` hook
remains supported as a compatibility fallback.

`failure_policy => open` records a bounded structural trace and continues with
the previous value. `failure_policy => closed` returns a typed, secret-free
error. Exceptions, worker death, timeout, invalid results, oversized results,
and observer attempts to intervene are all handled by that policy.

`on_event` runs before persistence. An amended event is accepted only when it
preserves the event ID, invocation ID, author, actions/state delta,
continuations, partial/final flags, and content kind. Final content cannot be
rewritten after output-schema validation. This keeps plugins useful for policy
and presentation without allowing them to bypass durable state or schema
boundaries.

Direct `erlang_adk:prompt/2` compatibility calls do not inherit Runner-global
plugins. Agent-local callbacks continue to work there.

### Stateful plugins

Stateful plugins implement `adk_stateful_plugin` and run behind one supervised
`adk_plugin_instance` actor per descriptor. The adapter serializes callbacks
through that actor, so plugin state changes are ordered even when Runner cases
are concurrent. State commits only while the callback remains within its
deadline and the owning process is alive; a timed-out or abandoned callback
cannot install late state. The descriptor still applies bounded queue, heap,
timeout, and result-size policy. Initialization also runs in a separate
timeout/heap-bounded worker. The returned PID is the stable identity and its
supervisor child is `temporary`: a crash does not silently replace it with an
empty-state process behind a stale reference. Explicit recreation or an
application persistence adapter is required for restart/durable state.

### Built-ins

0.7 includes four opt-in plugins:

- `adk_plugin_global_instruction` adds a Runner-wide instruction through an
  amend-and-continue hook;
- `adk_plugin_context_filter` applies bounded context policy before model I/O;
- `adk_plugin_reflect_retry` converts bounded tool failures into explicit
  model-visible retry guidance;
- `adk_plugin_metadata_logger` records structural metadata without prompt,
  response, argument, result, media, credential, or token content.

They are ordinary descriptors and obey the same ordering, ownership, limits,
and failure policy as application plugins.

## Correlated observability

0.7 retains the legacy schema-version-1 lifecycle envelope and adds
schema-version-2 operation signals at the actual model, tool, and Gemini Live
boundaries. Operation spans carry nanosecond timing and duration. Correlation
metadata includes W3C trace identifiers, run/invocation/session identifiers,
agent/model, and tool/call identifiers where applicable.

`adk_trace_context` strictly parses and formats W3C `traceparent` and
`tracestate`. Invalid, all-zero, oversized, duplicate, or malformed context is
rejected rather than partly accepted. New child spans retain the caller's
trace and sampling decision while receiving a fresh span ID.

The semantic mapping is pinned to
`gen-ai-semconv-development-2026-07-14`. It is deliberately metadata-only:
prompt/response text, tool arguments/results, audio/video bytes, thought
signatures, authorization data, provider tokens, and API keys are not semantic
attributes. This is true even when older lifecycle capture is explicitly
enabled.

### Metrics and delivery

`adk_observability_metrics` maintains a fixed instrument catalog and a bounded
number of label series. New high-cardinality combinations overflow into a
bounded aggregate rather than growing ETS state without limit.

Runner observability supports two delivery modes:

- synchronous exporters execute in descriptor order in monitored,
  timeout/heap-limited workers;
- `delivery => async` submits to a supervised `adk_observability_bus` with
  bounded item/byte/batch queues, retry and backoff, and explicit drop
  accounting.

The asynchronous bus provides bounded-best-effort delivery. An exporter must be
idempotent because a delayed retry can repeat a batch; exhausted retries are
dropped and counted. The queue, delayed-retry reservation, in-flight batches,
and expiring owner-monitored drain waiters are all capped. Per-run exporter
descriptors are not accepted in asynchronous mode because the long-lived bus
owns its exporter configuration.

`adk_otlp_http_json_exporter` exports schema-v2 completed spans to the OTLP
HTTP JSON trace endpoint and schema-v1 lifecycle records as logs. Span-start
signals are not sent independently. The exporter enforces an explicit
HTTP(S) origin/private-host policy, header/body limits, request timeout, and
no redirects. It performs one HTTP attempt; retry belongs to the supervised
asynchronous bus. The exporter classifies bounded failures as transient or
permanent; the bus retries only transient failures and accounts permanent
failures without looping.

The authenticated developer endpoint exposes only bounded operational
snapshots and metadata. It is not a prompt, media, tool-payload, or trace
archive.

### Deployment-owned OTLP environment bridge (0.10, in development)

Container/Helm deployments can opt into the existing OTLP/HTTP JSON exporter
without enabling local trace retention. `ERLANG_ADK_OTLP_ENDPOINT` is the only
activation switch. If it is absent, `OTEL_EXPORTER_OTLP_HEADERS` is ignored;
ambient header credentials never silently enable export.

When activated, `adk_deployment_env` validates an endpoint of at most 2048
bytes and at most 32 headers from a 32768-byte
`OTEL_EXPORTER_OTLP_HEADERS`. The header string uses standard
W3C-Baggage-style comma-separated `key=value` entries. Optional whitespace is
trimmed around entries, names, and values; names are lowercased without percent
decoding, while values are strict percent-decoded exactly once. Semicolon
metadata, malformed escapes, invalid decoded UTF-8, and case-insensitive
duplicate names fail startup closed. The endpoint must be an HTTP(S) origin;
userinfo, query, fragment, and non-root path components are rejected because
the exporter owns its traces/logs paths. Endpoint and header values are not
returned through failure terms.

The bridge reserves `<<"erlang-adk-deployment-otlp">>`, installs a bounded
failure-open exporter descriptor, and enables the asynchronous observability
bus. Installation is idempotent only for the exact descriptor; a conflicting
reserved ID fails startup. It forces `batch_size => 1`. The OTLP HTTP attempt
is capped at 3000 ms and the exporter worker at 4000 ms. The effective
`observability_bus_options.batch_timeout_ms` must exceed the sum of every final
exporter descriptor timeout plus 250 ms; otherwise startup fails with an
incompatible-timeout error. The bridge installs the configured trace-store
exporter before validating the final list. If the timeout is absent, it selects
the greater of 5000 ms and the final timeout sum plus 251 ms, capped by the
bus's 300000 ms maximum; an explicit undersized timeout fails. This accounts
for combinations such as deployment OTLP plus the local trace-store exporter.
Standard configured Runner paths emit metadata-only observations through that
bus even when
`trace_store_enabled` is false. This remains bounded best-effort delivery, not
a durable trace store, audit log, or WAL.

### Metadata-only trace retention (0.10, in development)

`adk_trace_store` adds an opt-in supervised store for existing observability
and workflow lifecycle events. This is retention, not a new tracing schema.
Application enablement through `trace_store_enabled` wires the standard
configured Runner and `erlang_adk` workflow-facade paths as described below;
direct `adk_runner:new` and direct `adk_workflow:*` callers must still pass the
corresponding observability options or lifecycle receiver explicitly.
`adk_trace_event` first validates the source schema, redacts secrets, and keeps
only a metadata projection selected by closed schema-specific allowlists for
observability v1/v2 and workflow lifecycle v1. Unknown or content-bearing
fields are rejected by default. Prompt/response fields, media, tool arguments,
and tool results are never retained.

```erlang
{ok, Store} = adk_trace_store:start_link(
    #{name => my_trace_store,
      max_events => 4096,
      max_bytes => 16777216,
      max_event_bytes => 262144,
      max_principals => 1024,
      max_events_per_principal => 1024,
      max_bytes_per_principal => 4194304,
      retention_ms => 300000,
      lifecycle_receiver_ttl_ms => 86400000,
      max_lifecycle_pending => 1024,
      max_prune_batch => 1024,
      max_query_events => 256,
      max_query_bytes => 1048576,
      content_policy => reject}).
```

`append_observability/2,3` and `append_lifecycle/2,3` bind each event to a
caller-supplied principal. The store retains only that principal's SHA-256
digest and creates streams for applicable combinations of `run_id`,
`trace_id`, `workflow_id`, and `invocation_id`. `query/3,4` accepts `all` or a
map of those four selector keys, plus bounded `after_cursor`, `limit`, and
`max_bytes` options. Each stream uses an ordered cursor index, so a small page
does not scan all prior stream events.

Global and per-principal event/byte quotas evict the oldest entries. A stream
keeps an expiring eviction watermark so a stale cursor receives explicit
`replay_gap`; a cursor beyond the stream returns `cursor_ahead`. Time-based
retention uses ordered event/tombstone/receiver expiry indexes and at most
`max_prune_batch` removals of each kind per pass. `prune/0,1` returns
`more_pending` and schedules an immediate next batch when needed.
`status/0,1` and `principal_status/1,2` return content-free counters and limits;
global status includes `lifecycle_pending`, `lifecycle_active_owners`, and
`lifecycle_delivery_dropped`. `format_status` redacts in-flight messages,
logs, and reasons as well as retained state.

For normal observability delivery, use `adk_trace_store_exporter` in an
`adk_observability` exporter descriptor. Its closed configuration contains
exactly the trace-store `server` and authenticated `principal`; event data
cannot replace either value:

```erlang
#{id => <<"local-trace-retention">>,
  module => adk_trace_store_exporter,
  config => #{server => adk_trace_store,
              principal => <<"authenticated-user-id">>},
  failure_policy => closed,
  timeout_ms => 1000,
  max_heap_words => 100000}.
```

For workflow lifecycle retention, create an opaque receiver and pass it through
the existing workflow option:

```erlang
{ok, LifecycleReceiver} = adk_trace_store:lifecycle_receiver(
                            adk_trace_store,
                            <<"authenticated-user-id">>),
WorkflowOptions = #{lifecycle_receiver => LifecycleReceiver}.
```

The running store mints the opaque capability and binds it to the principal
digest; a forged reference has no scope and cannot inject an event. Receiver
registrations are bounded by `max_principals`, reuse one capability per
principal, and normally expire after `lifecycle_receiver_ttl_ms` of inactivity.
That TTL defaults to 24 hours and must be at least the event retention.
Workflow delivery calls owner-aware `adk_trace_store:deliver_lifecycle/3` with
its local coordinator, and the store monitors all owners bound to the
capability. `deliver_lifecycle/2` remains an ownerless compatibility path.
When expiry is reached with any owner still alive, the bounded prune pass
renews the TTL; normal expiry resumes after every owner is down. A quiet
workflow can therefore outlive the TTL and still deliver its terminal event
without a heartbeat or synchronous store call. Existing PID lifecycle
receivers remain compatible. Once the receiver exists, delivery is
non-blocking and best-effort on the workflow path. Before casting, a shared
atomic counter admits at most `max_lifecycle_pending` events; the adapter also
drops inputs larger than 64 KiB and uses `nosuspend`/`noconnect`. Back-pressure,
an oversized/forged event, retention/capacity rejection, or an unavailable
store therefore cannot fail successful workflow execution. Exporter delivery
is synchronous and follows the configured observability failure policy.

With `trace_store_enabled => true`, `adk_trace_runtime` strictly resolves the
store name, `trace_store_principal` (default `<<"local-runtime">>`, non-empty
UTF-8, at most 256 bytes), and the observability-bus name. It starts the bus
even when `observability_bus_enabled` is `false`, reserves exporter ID
`<<"erlang-adk-trace-store">>`, and supplies asynchronous, open-failure,
metadata-only options through `erlang_adk:runtime_runner_spec/0`.
`erlang_adk:start_workflow/2,3` and `run_workflow/2,3` auto-mint a receiver
unless one is already present. Direct constructors are not rewritten.

The default `content_policy => reject` rejects a content-bearing event. A
trusted local deployment may select `prune`, which strips prohibited fields
and marks the retained event as pruned. This process-local, volatile service is
not a durable audit log, billing ledger, OpenTelemetry backend, or distributed
trace database.

Provider payload inspection is a separate Developer UI feature and does not
change that trace-store contract. It is disabled by default and starts only
when `dev_provider_payload_inspection` is the explicit map
`#{enabled => true, ...}` for the local developer listener. The observe-only
plugin secret-redacts and JSON-normalizes model request, response, and error
values, retains only a bounded projected context, and drops values that exceed
the event bound. The local volatile store defaults to 128 events, 64 KiB per
event, 1 MiB total, and five-minute retention; its hard ceilings are 10,000
events, 1 MiB per event, 16 MiB total, and one hour. The route remains behind
the existing developer bearer and loopback-only startup boundary. This is an
explicit development diagnostic, not production telemetry, a compliance log,
or a promise that field-name redaction detects all sensitive content.

## Evaluation v2

`adk_eval_set` persists schema-version-2 evaluation sets and results. A case
contains ordered turns and may run multiple samples. Cases can run concurrently
up to `concurrency`; samples can run concurrently up to
`sample_concurrency`; turns inside one conversation remain sequential.

The built-in criteria support:

- exact response matching;
- tool trajectory matching in `exact`, `in_order`, `any_order`, or `subset`
  mode;
- tool argument comparison in `exact`, `subset`, or `ignored` mode.

Criteria have explicit thresholds, minimum successful-sample requirements,
and strict numeric/size bounds. An explicitly empty criteria list is an error;
the `adk eval run` CLI chooses the exact-response criterion when `--criteria`
is omitted.

`adk_eval_agent_adapter` creates a fresh agent, Runner, guardian, and session
for each case/sample, and tears them down after completion. This is the default
isolation path for an Erlang agent evaluation. Custom `adk_eval_adapter`
implementations can target deterministic fixtures or remote systems, but they
must preserve the same bounded output/event/trajectory contract.

Results include per-turn and per-sample outcomes, aggregate criteria, pass
rate, thresholds, dataset revision, duration, and bounded caller build
metadata. `adk_eval_report` renders JSON or Markdown and compares a candidate
with a saved baseline using pass-drop and per-metric tolerance policy. Saved
sets/results are checked, secret-pruned, and JSON round-trippable.

`adk_eval_llm_judge` is the first-party, explicit full-case rubric judge. Its
metric descriptor uses `kind => judge`, `scope => 'case'`, and
`module => adk_eval_llm_judge`. Configuration requires binary `rubric`,
`rubric_id`, and `rubric_version`; it defaults to `adk_llm_gemini` with
`gemini-3.1-flash-lite`. The adapter forces a bounded structured-JSON response
schema and validates an exact `{score, rationale}` object with score in
`0..1`. Prompt, output, rationale, token, timeout, and provider-worker heap
bounds are finite. A monitored request worker dies on timeout or evaluation
owner death and counts shared binaries in its heap ceiling. Independent sample
workers continue to judge concurrently; no global judge server exists.

Provider modules and `provider_config` are trusted Erlang-only injection
points for applications or deterministic tests and must satisfy the normal
`adk_llm` provider contract. They are not accepted from the CLI criteria JSON.
Provider credentials are not placed in the prompt or successful metadata;
secret-bearing case fields are pruned, sensitive provider-config values are
redacted from rationale, and raw provider failures are reduced to structural
errors. Rationale remains evaluation content and is persisted in reports, so
it must be protected under the case-data policy. The judge is never enabled
implicitly and every call has provider cost/latency.

The non-interactive CLI entry point is:

```bash
adk eval run --config AGENT.json --eval-set SET.json \
  [--criteria CRITERIA.json] [--baseline BASELINE.json] \
  [--samples N] [--concurrency N] [--sample-concurrency N] \
  [--format json|markdown] [--output REPORT]
```

The command exits 0 when the candidate passes, 2 when evaluation completes but
fails criteria or regression policy, and 1 for configuration/runtime errors.

### Supervised evaluation jobs (0.10, in development)

`adk_eval_service` schedules the existing `adk_eval_set:run/4` engine behind
bounded concurrency and queue limits. `adk_eval_store` defines exact
`{app, AppBinary}` scope, immutable eval-set revisions, atomic set-plus-job
creation, atomic expected-phase job transitions, bounded pagination, named
baselines, protected pruning, and recovery of work that was active when the
service stopped.

```erlang
{ok, Service} = adk_eval_service:start_link(
    #{name => my_eval_service,
      store => {owned, adk_eval_store_ets, #{}},
      max_concurrency => 4,
      max_queue => 1000,
      max_queue_bytes => 67108864,
      task_timeout_ms => 3600000,
      task_retention_ms => 30000}).
```

Use `{owned, adk_eval_store_mnesia, Config}` for local durable Mnesia storage,
or `{StoreModule, Handle}` when the application owns the store. The ETS and
Mnesia adapters both enforce `max_sets`, `max_jobs`, `max_baselines`,
`max_page_limit`, `max_record_bytes`, `max_total_bytes`, `max_scope_bytes`, and
`max_prune_limit`. Byte defaults are 16 MiB per record, 256 MiB per exact app
scope, and 1 GiB total. The Mnesia adapter additionally accepts fixed
operator-owned table atoms, `table_wait_ms`, `max_prune_scan` (default 1000),
`recovery_batch_size` (default 100), `reconciliation_batch_size` (default 500),
and `repair_usage` (default `false`).

The store behavior requires `ownership_identity/1`. The service holds one lock
for the canonical identity so two schedulers cannot use or recover the same
store at once. An owned Mnesia service acquires that identity before
initialization/reconciliation; the same table/capacity/schema configuration
has the same identity even if `repair_usage` or `table_wait_ms` differs. A
custom adapter must return one stable identity for its config and opened
handle, and wrapper modules must reuse the underlying backend identity. It may
return `defer` only until a `start_link/1` process-backed store has been opened;
an init-only durable adapter must identify itself before initialization or the
service fails with `eval_store_preinit_identity_required`.

`submit/3` accepts an eval `set`, runtime `adapter`, metric list,
evaluation `options`, and optional metadata. Request preparation runs in at
most 64 monitored workers outside the service mailbox, with a one-second
timeout and 1,048,576-word heap ceiling per worker. This preserves service
responsiveness under large or malformed submissions. Admission can return
`evaluation_request_validation_busy`,
`evaluation_request_validation_timeout`,
`evaluation_request_validation_failed`, or
`evaluation_request_validation_unavailable`; `capabilities/1` exposes the
current `pending_submissions` count. Runtime adapter handles stay in the
service/task processes, not the store. Submission calls
`create_evaluation/4`, atomically storing the immutable set revision and queued
job so a rejected job cannot leave an orphan revision. Public jobs omit the
private task reference. The service exposes `status/3`, `result/3`, `cancel/3`,
`list_jobs/3`, `get_set/4`, `list_sets/3`, `put_baseline/4`,
`get_baseline/3`, `prune/3`, and `capabilities/1`.

`prune/3` is exact-app and requires `#{before => EpochMilliseconds}`. An
optional bounded `limit` and opaque `cursor` make repeated calls incremental.
The reply contains `baselines_deleted`, `jobs_deleted`,
`set_revisions_deleted`, `bytes_reclaimed`, `scanned`, `next_cursor`, and
`has_more`. By default, only terminal jobs not referenced by a baseline and set
revisions with no remaining job references are eligible; active, baselined,
and referenced data remains protected. The deliberate
`include_baselines => true` option first makes baselines older than the cutoff
eligible, then lets their newly unreferenced terminal jobs and set revisions
follow in the same cursor walk.

On startup, stored `queued` or `running` jobs are transitioned to `failed`
with `evaluation_service_restarted`. They are not replayed because doing so
could repeat model calls or external effects. A terminal-result persistence
failure stops the service rather than presenting an unrecorded completion. The
ETS store performs recovery in internal 100-row continuations. The Mnesia
adapter provides local durability, ordered scope-local paging, atomic capacity
accounting, and configurable recovery batches (default 100). It validates
ordered table schemas and local disk copies, persists/rejects mismatched
configuration fingerprints, and uses an O(1) ready path when persisted usage
state and table counts match. Missing, mismatched, or explicitly forced usage
state is rebuilt in checkpointed reconciliation batches under a global repair
lock; writes are rejected while repair is active. A controlled startup with
`repair_usage => true` forces byte/count/reference reconstruction after an
external restore and fails closed on quota or referential-integrity errors.
Queued jobs reserve 4608 bytes of terminal-record quota headroom, later
reconciled to the actual terminal row. Replica administration and a managed
evaluation control plane remain outside this service.

### Metrics, simulation, review, statistics, and CI export (0.10)

`adk_eval_builtin_metric` provides provider-free bounded metrics for latency,
token cost, safety-violation counts, and deterministic semantic quality. Every
score is normalized to `0..1`; unavailable operational fields become an
explicit `not_evaluated` result rather than guessed data. LLM-backed judging
remains the separate explicit `adk_eval_llm_judge` path.

`adk_eval_ensemble` aggregates already-persisted bounded votes by weighted mean
or majority, reports disagreement/human-review signals, and can calibrate and
apply a classification threshold. It never calls a provider. `adk_eval_review`
implements a bounded revision-checked human-review state machine with immutable
terminal decisions and stale/duplicate reviewer rejection. Persistence and
reviewer identity policy remain application responsibilities.

`adk_eval_user_simulator` and `adk_eval_environment_simulator` are trusted
behavior contracts executed by `adk_eval_simulation`. Modules come from
operator code, never an evaluation document. Scenario, transcript, turn,
effect, and public result values cross a strict bounded JSON boundary, while
simulator-private state remains inside the evaluation worker and is not
persisted. Each callback is deadline/heap/result bounded; the whole simulation
has a step ceiling. These are deterministic runtime contracts, not a hosted
scenario marketplace or automatic prompt optimizer.

`adk_eval_statistics` supplies deterministic summaries, confidence intervals,
Wilson pass-rate intervals, and a longitudinal regression gate over bounded
score series. `adk_eval_export:render/3` is the canonical renderer for `json`,
`markdown`, `junit`, `sarif`, and `annotations`; the format-specific helpers
delegate to the same bounded content-minimal projections. Reports contain
identifiers, aggregate scores, and failure states—not prompts, responses, tool
arguments, or adapter metadata.

All five canonical formats share one 16 MiB default and hard output ceiling.
The stored-report HTTP route has its own validated
`dev_evaluation_report_max_bytes` application setting (also capped at 16 MiB),
which is projected into `evaluation_report_max_bytes` for the Developer
router. This response limit is deliberately independent of the Developer API's
64 KiB request-body ceiling and the 1 MiB response cap retained by unrelated
CLI/Developer endpoints. `adk eval report` uses the report-specific 16 MiB
receiver for both stdout and `--output`; it does not raise any other CLI path.

`adk_eval_worker_rpc` is the optional distributed worker transport. Nodes are
an explicit trusted allowlist, no node name comes from dataset/config JSON, a
local proxy owns the remote coordinator, cancellation/owner death kills remote
work, and a request is never replayed. This is not automatic cluster discovery
or transparent failover. No multi-node node-loss Common Test is currently
claimed.

`adk_eval_dev_api` is the Developer UI facade for authoring and history. Browser
JSON can select only an already registered agent plus first-party metric IDs;
adapter/metric modules, stores, RPC nodes, credentials, and paths remain fixed
by trusted server configuration. Its stored-result `report/5` API, the
authenticated `/dev/v1/evaluation/jobs/:job_id/report` route, `adk eval report
JOB_ID`, and the existing `adk eval run` reporting path all call the canonical
renderer. Given the same stored result, format, and bounded options, direct,
API, HTTP, and CLI access returns the same bytes. Focused boundary coverage
includes an approximately 1.4 MiB stored JSON report—larger than the unrelated
1 MiB client ceiling—and verifies exact API, authenticated HTTP, stdout, and
file parity, inclusive exact-size acceptance, one-byte-under rejection, and
the 16 MiB hard configuration ceiling.

## Verification map

- `adk_plugin_pipeline_test` and `adk_plugin_runner_integration_test` cover
  ordering, amend/return compatibility, phase-specific errors, local/global
  precedence, intervention, failure policy, limits, and event invariants.
- `adk_plugin_builtin_test` and `adk_plugin_stateful_test` cover built-ins,
  actor serialization, deadline fencing, owner death, and state isolation.
- `adk_observability_test`, `adk_observability_v2_test`,
  `adk_observability_runner_test`, and `adk_trace_context_test` cover legacy
  compatibility, actual operation spans, semantic attributes, bounded metrics,
  synchronous/asynchronous delivery, and strict W3C propagation.
- `adk_otlp_json_test` and `adk_otlp_http_json_exporter_test` cover OTLP JSON,
  endpoint/header/body policy, redirects, timeouts, retry ownership, and
  metadata-only export.
- `adk_trace_store_test` covers metadata projection, principal isolation,
  cursor paging and replay gaps, global/per-principal capacity, retention,
  indexed/batched expiry, bounded lifecycle admission, independent receiver
  TTL, content rejection/pruning, and status redaction for the 0.10
  development store.
- `adk_trace_store_exporter_test` and `adk_workflow_trace_store_test` cover
  fixed-principal observability export, structural error redaction, opaque
  store-minted workflow receiver validation, forged-capability rejection,
  end-to-end lifecycle retention, non-blocking unavailable/suspended-store
  delivery, and legacy PID receiver compatibility.
- `adk_trace_runtime_test` covers strict application configuration, automatic
  bus/exporter/Runner wiring, workflow-facade receiver injection, and
  secret-free configuration failures.
- `adk_live_observability_test` covers Gemini Live connect/receive/tool
  operation signals.
- `adk_eval_set_test`, `adk_eval_criteria_test`, `adk_eval_v2_test`,
  `adk_eval_llm_judge_test`, and `adk_eval_dev_view_test` cover v2 validation,
  sampling/concurrency, fresh-runtime isolation, built-in criteria, bounded
  rubric judging, reports, and baselines. The opt-in REST suite contains a
  real `gemini-3.1-flash-lite` rubric-judge case.
- `adk_eval_service_test` covers the 0.10 development store contract, bounded
  scheduling, lifecycle/result/baseline APIs, active-job restart recovery, and
  ETS/Mnesia persistence behavior.
- `adk_eval_store_hardening_test` covers atomic creation, record/scope/global
  byte quotas and terminal headroom, scope-local ordered paging, default-safe
  and explicit-baseline cursor pruning, Mnesia schema/config validation, and
  bounded restore-time accounting repair.
- `adk_eval_builtin_metric_test`, `adk_eval_ensemble_test`,
  `adk_eval_simulation_test`, `adk_eval_statistics_test`,
  `adk_eval_review_test`, `adk_eval_export_test`, and
  `adk_eval_report_parity_test` cover the bounded
  operational/semantic metrics, persisted-vote aggregation/calibration,
  trusted simulators, deterministic statistics, review transitions,
  content-minimal formats, and byte-for-byte direct/API/HTTP/CLI parity.
- `adk_eval_worker_rpc_test`, `adk_eval_dev_api_test`, and
  `adk_dev_eval_http_test` cover explicit-node worker ownership/cancellation,
  the safe browser authoring boundary, and authenticated evaluation routes.
- `adk_dev_graph_trace_test` and `adk_dev_payload_inspection_test` cover
  owner-bound graph/metadata-trace projections and the separate disabled-by-
  default, redacted, bounded payload-inspection path.
- `adk_cli_test` covers `adk eval run`, `adk eval report`, developer
  observability/Live commands, exit statuses, bounds, and structured connection
  failures.
- `readme_examples_test` compiles and runs the stateless example plugin,
  exporter, direct-agent adapter, and evaluation metric shown in the README;
  the verification commands compile the v0.7 stateful and Live-executor
  modules with warnings treated as errors.
