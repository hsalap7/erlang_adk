# Erlang source layout

Erlang module names remain globally flat and unchanged. The directories below
express code ownership for maintainers; they do not create namespaces and do
not change any public API or generated BEAM name.

| Path | Responsibility |
| --- | --- |
| `src/` | Public `erlang_adk` facade and OTP application/supervisor shell only |
| `src/agents/` | Agent processes, specifications, instruction resolution, registries, trees, and agent-as-tool adaptation |
| `src/artifacts/` | Artifact contracts, services, and ETS, filesystem, and sharded implementations |
| `src/auth/` | Authentication, authorization, credentials, OAuth/OIDC, and protocol-bound auth adapters |
| `src/auth/credentials/` | Private credential stores, refresh workers, and generation-consistent model-provider credential resolution |
| `src/callbacks/` | Callback contracts and safe callback views; distinct from stateful plugins |
| `src/context/` | Context envelopes, policy, compaction, caching, and capability workers |
| `src/core/` | Cross-feature values and utilities: content, events, JSON, failures, retries, secrets, and service references |
| `src/developer/` | CLI and local developer HTTP/UI tooling |
| `src/evaluation/` | Evaluation schemas, criteria, adapters, judges, and report rendering |
| `src/integrations/openapi/` | OpenAPI schemas, toolsets, and HTTP transports |
| `src/integrations/web/` | Authenticated production/Phoenix web boundary |
| `src/live/core/` | Provider-neutral Live events, media, sessions, transports, and tool execution |
| `src/live/voice/` | Browser/transport voice framing, registry, and bridge processes |
| `src/memory/` | Conversation projection and long-term memory contracts, services, and stores |
| `src/memory/ingest/` | Supervised asynchronous memory ingestion |
| `src/memory/outbox/` | Durable memory outbox delivery and recovery |
| `src/models/` | Provider-neutral model result, safety, and REST/Live/cache provider contracts |
| `src/models/profiles/` | Operator-owned binary provider/model profiles, registry resolution, and bounded capability metadata |
| `src/models/transport/` | Shared bounded JSON HTTP/SSE contracts, 64 KiB aggregate header/trailer validation, Gun transport, and incremental SSE decoding |
| `src/models/gemini/` | Gemini REST, context-cache, safety encoding, Live codec, and WebSocket transport implementations |
| `src/models/openai/` | Native OpenAI Responses provider and pure request/content/stream codecs |
| `src/models/openai/realtime/` | OpenAI Realtime provider codec and fixed-origin verified-TLS WebSocket transport |
| `src/models/anthropic/` | Native Anthropic Messages provider and pure request/content/stream codecs |
| `src/models/compatible/` | Narrow OpenAI-compatible Chat Completions provider and pure request/content/stream codecs |
| `src/plugins/` | Stateless and stateful plugin contracts, instances, pipelines, and runtime supervision |
| `src/protocols/a2a/` | A2A v1 implementation and legacy compatibility adapters |
| `src/protocols/http/` | Shared HTTP listener lifecycle and route composition |
| `src/protocols/mcp/` | MCP client, server, supervision, and HTTP transport boundary |
| `src/runtime/admission/` | Global admission control |
| `src/runtime/ambient/` | Ambient jobs, triggers, and their supervisors |
| `src/runtime/invocations/` | Invocation and run identities, lifecycle, and registries |
| `src/runtime/runner/` | Runner composition, continuation/suspension, and runtime policy |
| `src/runtime/tasks/` | Lightweight supervised task processes and registries |
| `src/sessions/` | Session contracts, queries, ownership, and Mnesia implementation |
| `src/storage/` | Storage infrastructure shared by artifacts and memory |
| `src/telemetry/` | Runtime observability, W3C tracing, metrics, semantic conventions, and OTLP export |
| `src/tools/builtin/` | Built-in long-running, memory, and artifact tools |
| `src/tools/code/` | Code execution and code toolsets |
| `src/tools/core/` | Tool contracts, calls, confirmation, execution, toolsets, and parallel composition |
| `src/workflows/core/` | Workflow definitions, engines, run processes, and supervision |
| `src/workflows/durability/` | Durable workflow ledger contracts and Mnesia storage |
| `src/workflows/graph/` | Graph workflows, graph nodes, and compatibility orchestration helpers |
| `src/workflows/planning/` | Plans, planners, execution, and planning runtime |

Protocol-specific authentication is nested by owning integration rather than
mixed into the central auth contracts. Provider implementations stay under
`models/`; their pure wire codecs are nested with the provider, while shared
HTTP/SSE transport and profile selection remain provider-neutral. Model
credential source resolution belongs in `auth/credentials/`, but it returns
material only at the trusted adapter/Live-session boundary. Provider-neutral
Live and context-cache contracts stay in their owning feature directories.
Modules that merely emit telemetry stay with the feature whose lifecycle they
implement.

Place a module with the subsystem that owns its lifecycle, not every subsystem
it happens to call. For example, MCP is a protocol rather than a tool, durable
invocation ledgers belong to workflow durability, and shared shard routing is
storage infrastructure rather than an artifact or memory implementation.

Rebar3 has one recursive `src` root in `rebar.config`. Do not add overlapping
nested source roots. All modules still compile into one `ebin`, so module names
must be globally unique. Use `-include("name.hrl")` for application headers;
do not depend on a source file's relative depth.

Tests mirror this ownership hierarchy under one test-profile-only recursive
`test` root. See [`docs/TEST_LAYOUT.md`](../docs/TEST_LAYOUT.md) for test
placement, cross-feature integration suites, and fixture conventions.
