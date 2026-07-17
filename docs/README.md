# Erlang ADK documentation

This index separates user guides, behavior contracts, release operations, and
historical delivery evidence. Start with the root [`README.md`](../README.md)
for installation and executable examples.

## Release and project documents

- [`CHANGELOG.md`](../CHANGELOG.md) — cumulative changes from 0.3.0 through
  0.7.0, fixes, evidence, and visible release limitations.
- [`TESTING.md`](TESTING.md) — deterministic, paid-provider, Phoenix, browser,
  packaging, and audit gates.
- [`TEST_LAYOUT.md`](TEST_LAYOUT.md) — test ownership, recursive discovery,
  helper placement, and fixture conventions.
- [`UPGRADING.md`](UPGRADING.md) — behavior and configuration changes between
  delivery milestones.
- [`RELEASING.md`](RELEASING.md) — the pre-tag, package, audit, approval, tag,
  and publication checklist. It does not claim that a tag or package was
  published.
- [`SECURITY.md`](../SECURITY.md) — supported versions, private reporting,
  deployment boundaries, secret handling, and known dependency advisories.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — toolchains, design rules, evidence,
  and pull-request expectations.
- [`FEATURE_PARITY.md`](FEATURE_PARITY.md) — current ADK behavior-family status
  with explicit partial and adapter-owned surfaces.
- [`README_EXAMPLE_COVERAGE.md`](README_EXAMPLE_COVERAGE.md) — stable fence IDs
  and the exact tests or prerequisites for every README example.

## Runtime and workflow guides

- [`RUNTIME_SAFETY.md`](RUNTIME_SAFETY.md) — process ownership, limits,
  cancellation, structured failures, and secret isolation.
- [`DURABLE_INVOCATIONS.md`](DURABLE_INVOCATIONS.md) — stable runs, replay,
  continuations, persistence, and restart behavior.
- [`AMBIENT_RUNTIME.md`](AMBIENT_RUNTIME.md) — local events and fixed-delay
  scheduled invocations with bounded admission and session policy.
- [`GRAPH_WORKFLOWS.md`](GRAPH_WORKFLOWS.md) — graph/fork control flow,
  checkpoints, deterministic state merge, and resume limitations.
- [`PLANNING_RUNTIME.md`](PLANNING_RUNTIME.md) — explicit planner/executor
  contracts, bounded replanning, and model-native thinking.
- [`CODE_EXECUTION.md`](CODE_EXECUTION.md) — the external-sandbox requirement
  for model-requested code execution.

## Artifacts, memory, and context

- [`ARTIFACTS.md`](ARTIFACTS.md) — scoped immutable versions, adapters,
  quotas, repair, tools, and current data-plane limits.
- [`MEMORY.md`](MEMORY.md) — scoped retrieval/ingestion, durable local
  behavior, outbox semantics, erasure, and adapter boundaries.
- [`CONTEXT.md`](CONTEXT.md) — mandatory request sanitation, budgeting,
  selection, compaction, fingerprints, and provider prefix caching.

## Providers, plugins, evaluation, and observability

- [`GEMINI_GROUNDING.md`](GEMINI_GROUNDING.md) — Google Search grounding,
  bounded provider metadata, streaming, and failure behavior.
- [`PLUGINS_OBSERVABILITY_EVALUATION.md`](PLUGINS_OBSERVABILITY_EVALUATION.md)
  — Runner-global plugins, trace/metric/export behavior, evaluation v2, and
  explicit content/privacy boundaries.
- [Phoenix companion guide](../examples/phoenix_adk_ui/README.md) — OIDC or
  loopback-only local authentication, same-BEAM gateways, agent runs, Live
  operations, browser voice, production TLS/proxy setup, and its independent
  release/audit gates.

## Version contracts

These contracts preserve what each development milestone set out to deliver,
what passed, and what remained incomplete. Unchecked items are limitations,
not implicit release claims.

- [`VERSION_0_3_0.md`](VERSION_0_3_0.md) — supervised runtime, services,
  protocols, developer tooling, and quality foundation.
- [`VERSION_0_4_0.md`](VERSION_0_4_0.md) — agent, tool, and workflow behavior.
- [`VERSION_0_5_0.md`](VERSION_0_5_0.md) — artifacts, memory, and context.
- [`VERSION_0_6_0.md`](VERSION_0_6_0.md) — authentication, protocols, and the
  production-capable Phoenix companion.
- [`VERSION_0_7_0.md`](VERSION_0_7_0.md) — Gemini Live/multimodal sessions,
  plugins, evaluation, expanded observability, developer projections, and
  browser voice.

## Model and test terminology

The project has two separate Gemini gates:

- REST GenerateContent/SSE and the ordinary agent default use
  `gemini-3.1-flash-lite` and `ERLANG_ADK_GEMINI_REST=1`.
- Gemini Live WebSocket uses `gemini-3.1-flash-live-preview` and
  `ERLANG_ADK_GEMINI_LIVE=1`.

Both require `GEMINI_API_KEY` in the same environment as Common Test. They use
network access, quota, and billable API calls, so they skip unless explicitly
enabled. A skip or quota failure is never counted as a deterministic pass.
