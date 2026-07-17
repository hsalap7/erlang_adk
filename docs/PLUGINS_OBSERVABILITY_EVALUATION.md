# Plugins, observability, and evaluation

This document defines the Erlang ADK 0.7.0 cross-cutting runtime contracts. It
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
- `adk_live_observability_test` covers Gemini Live connect/receive/tool
  operation signals.
- `adk_eval_set_test`, `adk_eval_criteria_test`, `adk_eval_v2_test`,
  `adk_eval_llm_judge_test`, and `adk_eval_dev_view_test` cover v2 validation,
  sampling/concurrency, fresh-runtime isolation, built-in criteria, bounded
  rubric judging, reports, and baselines. The opt-in REST suite contains a
  real `gemini-3.1-flash-lite` rubric-judge case.
- `adk_cli_test` covers `adk eval run`, developer observability/Live commands,
  exit statuses, bounds, and structured connection failures.
- `readme_examples_test` compiles and runs the stateless example plugin,
  exporter, direct-agent adapter, and evaluation metric shown in the README;
  the verification commands compile the v0.7 stateful and Live-executor
  modules with warnings treated as errors.
