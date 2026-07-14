# Plugins, observability, and evaluation

This document defines the Erlang ADK 0.3.0 cross-cutting runtime contracts. It
tracks the externally observable behavior of the official
[plugin](https://adk.dev/plugins/),
[observability](https://adk.dev/observability/), and
[evaluation](https://adk.dev/evaluate/) capability families without copying
Python's object or thread model.

## Runner plugin lifecycle

Plugins belong to a Runner, not an agent. `adk_runner:new/4` compiles the
ordered descriptor list once and rejects malformed configuration before a run
is accepted. Each implemented hook executes in its own monitored lightweight
process with `timeout_ms` and `max_heap_words` limits.

For a corresponding lifecycle phase, precedence is:

1. ordered Runner-global plugins;
2. the agent's existing local callback, unless a global plugin intervened;
3. the model, tool, agent, or run operation;
4. ordered global after/error plugins;
5. the corresponding local after/error callback, unless a global plugin
   intervened.

Observation plugins return `observe`, `continue`, or `ok`. Intervention plugins
may return `{replace, Value}` or `{halt, Reason}`. `failure_policy => open`
records a bounded structural trace and continues with the prior value;
`failure_policy => closed` returns a typed, secret-free error. Exceptions,
worker death, timeout, invalid results, and observer attempts to intervene are
all handled by that policy.

`on_event` runs before persistence. A replacement is accepted only when it
preserves the event ID, invocation ID, author, actions/state delta,
continuations, partial/final flags, and content kind. Final content cannot be
rewritten after output-schema validation. This keeps plugins useful for policy
and presentation without allowing them to bypass durable state or schema
boundaries.

Direct `erlang_adk:prompt/2` compatibility calls do not inherit Runner-global
plugins. Agent-local callbacks continue to work there.

## Correlated observability

Runner lifecycle, model, and tool phases emit the same schema-versioned,
JSON-safe envelope delivered through `telemetry` and any configured exporters.
Correlation metadata includes:

- `trace_id`, `span_id`, and `parent_id`;
- `run_id`, `invocation_id`, and session;
- agent and model;
- tool and `call_id` when applicable.

The default Runner configuration emits metadata only. Configure
`observability => disabled` to disable it. Set `capture_content => true` only
in a controlled environment: prompts, responses, tool arguments, and tool
results are otherwise absent. Secret-like keys are recursively removed even
when capture is enabled. Unsupported opaque terms such as pids, ports,
references, and functions produce a metadata-only `capture_error` marker; they
do not fail the run.

An exporter implements `adk_observability_exporter:export/2`. Exporters run in
descriptor order in monitored, timeout/heap-limited workers. Open failures are
reported and later exporters still run; closed failures fail the lifecycle
operation. No OpenTelemetry SDK is required by the core. An application can
bridge the stable envelopes or `telemetry` events into its chosen logging,
metrics, or tracing backend.

## Evaluation sets

`adk_eval_set` complements the legacy `adk_eval` API with two versioned storage
contracts: evaluation sets and evaluation results. An evaluation set contains
one or more cases; each case contains ordered turns and threads adapter state
between those turns.

An `adk_eval_adapter` owns how a turn reaches an agent, Runner, remote service,
or deterministic fixture. It returns output plus optional canonical ADK events,
state, and metadata. Tool calls and responses in those events form a stable
trajectory. Event capture is configurable, while tool arguments/results are
off by default.

Ordered metric descriptors implement `adk_eval_metric`. `kind => metric` and
`kind => judge` use the same bounded score contract and independently declare a
0..1 threshold. A result records turn scores, case pass/fail/error status,
trajectory, aggregate metric averages, pass rate, dataset revision, duration,
and caller-supplied build metadata. Saved sets/results are checked, secret
pruned, and JSON round-trippable.

Cases use monitored lightweight processes with explicit overall and per-case
deadlines, a heap limit, and bounded concurrency. Turns inside a case remain
sequential because they represent a conversation. If cases require isolation,
the adapter must allocate a distinct agent/session target per case rather than
sharing a single stateful agent process.

## Verification map

- `adk_plugin_pipeline_test` covers order, intervention, failure policy,
  timeout, heap isolation, trace safety, and atom safety.
- `adk_plugin_runner_integration_test` covers Runner/local precedence, skipped
  callbacks, model/tool intervention, event invariants, and correlated export.
- `adk_observability_test` covers correlation, default-off content, explicit
  redacted capture, opaque-content fallback, exporter order/failure/timeout,
  and JSON round trips.
- `adk_eval_set_test` covers multi-turn state, trajectories, metrics/judges,
  thresholds, adapter errors, deadlines, bounded concurrency, redaction, and
  saved-result round trips.
- `readme_examples_test` compiles and runs the example plugin, exporter,
  direct-agent evaluation adapter, and exact metric shown in the README.
