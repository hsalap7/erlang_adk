# Erlang test layout

Erlang test and fixture module names remain globally flat and unchanged. The
directories below mirror the ownership hierarchy under `src/`; they do not
create namespaces or change EUnit/Common Test module names.

| Test path | Production owner |
| --- | --- |
| `test/agents/` | `src/agents/` |
| `test/artifacts/` | `src/artifacts/` |
| `test/auth/` | `src/auth/` |
| `test/callbacks/` | `src/callbacks/` |
| `test/context/` | `src/context/` |
| `test/core/` | `src/core/` |
| `test/developer/` | `src/developer/` |
| `test/evaluation/` | `src/evaluation/` |
| `test/integrations/` | `src/integrations/`, plus explicit cross-feature integration and stress suites |
| `test/live/` | `src/live/` |
| `test/memory/` | `src/memory/` |
| `test/models/` | `src/models/` |
| `test/plugins/` | `src/plugins/` |
| `test/protocols/` | `src/protocols/` |
| `test/runtime/` | `src/runtime/` |
| `test/sessions/` | `src/sessions/` |
| `test/storage/` | `src/storage/` |
| `test/telemetry/` | `src/telemetry/` |
| `test/tools/` | `src/tools/` |
| `test/workflows/` | `src/workflows/` |
| `test/readme/` | README examples and opt-in provider integration evidence |

The 0.8 and 0.9 model-provider slices mirror their deeper production
ownership:

| Test path | Production owner |
| --- | --- |
| `test/auth/credentials/` | Provider credential/profile-generation resolution and the existing credential lifecycle |
| `test/models/profiles/` | Binary model profiles, aliases, capability ceilings, locked request options, and Live resolution |
| `test/models/transport/` | Shared HTTP headers, synchronous/streaming 64 KiB header/trailer bounds, Gun request/SSE transport, incremental SSE, and injected transport fixtures |
| `test/models/openai/` | Native OpenAI Responses request/content/provider behavior |
| `test/models/openai/request/` | Pure Responses content, request, response, and SSE event codecs |
| `test/models/openai/realtime/` | OpenAI Realtime provider codec and fixed-origin WebSocket transport |
| `test/models/anthropic/` | Native Anthropic Messages provider behavior |
| `test/models/anthropic/request/` | Pure Messages content, request, response, and SSE lifecycle codecs |
| `test/models/compatible/` | Compatible Chat Completions provider behavior |
| `test/models/compatible/request/` | Pure compatible content, request/response, and SSE codecs |
| `test/models/vertex/` | Vertex publisher-model validation plus deterministic GenerateContent/SSE request, response, and transport behavior |
| `test/live/core/` | Provider-neutral contiguous multi-frame/no-op admission, priority ordering, profile resolution, ownership, and flow control |
| `test/live/voice/` | Negotiated format framing, 16/24 kHz input, bridge ownership, and acknowledgement behavior |

The expanded in-development 0.10 scope keeps the same ownership rule:

| Test path | 0.10 development owner |
| --- | --- |
| `test/storage/adk_scope_sharded_test.erl` | Shared/global-quota routing, exact-scope concurrency, volatile capacity, and durable idle reclamation |
| `test/runtime/services/` | Built-in service-profile compilation, atomic bundle generations, application supervision, and `durable_local` ownership/health/restart/fail-closed coverage for its private Mnesia memory outbox |
| `test/agents/adk_agent_config_test.erl` and `adk_agent_composition_test.erl` | Schema-v2 JSON/strict-YAML config, sealed immutable registry, and data-only composition |
| `test/tools/connectors/` | Connector descriptor/manifest/toolset policy boundaries; package suites under `packages/*/test/` execute every advertised operation through the registry, Agent Config, and `adk_toolset` and verify policy metadata, with `packages/build_connector_packages.sh` as the sole offline all-package build/test/extraction gate |
| `test/artifacts/adk_artifact_gcs_test.erl`, `adk_artifact_stream_test.erl`, and `adk_artifact_effect_journal*_test.erl` | GCS-compatible immutable storage, bounded transfer, and journal/reconciliation boundaries |
| `test/memory/embedding/`, `test/memory/vector/`, `test/memory/policy/`, and `test/memory/outbox/` | Bounded embedding/vector/hybrid references, opt-in governance, epoch-bound durable ingestion, registry hydration/identity claim barriers, constant-row health/majority readiness, indexed maintenance, and terminal-cap migration/pruning |
| `test/protocols/mcp/adk_mcp_*foundation_test.erl`, `adk_mcp_oauth_test.erl`, `adk_mcp_pool_test.erl`, and `adk_mcp_sse_stream_test.erl` | Explicit protocol eras, catalogs, OAuth/PKCE, pooling, and incremental SSE; the streamable-HTTP CT fixture is local, not an external SDK matrix |
| `test/protocols/a2a/v1/adk_a2a_v1_{agent_executor,client_stream,task_store,push}_test.erl` | Runner execution, callback streaming, bounded persistence, and process-local push |
| `test/evaluation/adk_eval_service_test.erl` | Evaluation service, bounded raw-submission workers, canonical store ownership, and ETS/Mnesia lifecycle/recovery |
| `test/evaluation/adk_eval_store_hardening_test.erl` | Atomic creation, byte quotas/headroom, baseline-aware pruning, ordered paging, and Mnesia restore repair checks |
| `test/evaluation/adk_eval_report_parity_test.erl` | Canonical JSON/Markdown/JUnit/SARIF/annotations byte parity across direct, stored-result API, authenticated HTTP, existing eval-run, stdout, and file paths; approximately 1.4 MiB and exact/one-byte-under/16 MiB boundaries |
| `test/evaluation/adk_eval_{builtin_metric,ensemble,simulation,statistics,review,export,worker_rpc,dev_api}_test.erl` | Advanced bounded metric/simulator/ensemble/review/statistics/export/RPC/developer foundations |
| `test/telemetry/adk_trace_store*_test.erl` | Metadata retention, cursor/capacity/privacy behavior, and observability exporter |
| `test/telemetry/adk_trace_runtime_test.erl` | Strict app configuration and automatic bus/Runner/workflow-facade trace wiring |
| `test/workflows/core/adk_workflow_trace_store_test.erl` | Opaque workflow lifecycle integration, owner-bound TTL renewal, and PID compatibility |
| `test/developer/adk_dev_{graph_trace,eval_http,payload_inspection}_test.erl` | Bounded graph/trace/evaluation surfaces and explicit redacted development-only payload inspection |
| `test/runtime/deployment/`, `test/deployment/`, and `erlang_adk_startup_test` | Lifecycle/draining, strict OTLP environment wiring, closed/health/application-config mode boundaries, health-only listener startup, descriptor-limit/PID1 contracts, both Cloud Run maximum annotations (not a singleton proof), render-first Cloud/GKE assets, and credential-safe managed-runtime feasibility boundaries; not live infrastructure evidence |

These paths do not imply that 0.10 is released; their candidate evidence stays
in [`VERSION_0_10_0.md`](VERSION_0_10_0.md).

Keep remote provider calls out of ordinary `*_test.erl` modules. Deterministic
provider tests inject `adk_model_fixture_transport`, fake Live transports, or
pure wire frames. A billable/network suite belongs in the owning provider
directory, must use an explicit opt-in environment flag, and must report a
missing credential as a skip rather than silently falling back to fixtures.

Only tests for the public facade and OTP application shell remain directly in
`test/`, matching the root production modules. Shared helpers belong beside
the subsystem that owns their behavior. Repository-level shell and TLS
fixtures remain at `test/` and `test/fixtures/` because README and Phoenix
release checks consume those stable paths.

Rebar3 enables one recursive `test` source root only in the `test` profile.
Do not configure overlapping nested roots: ordinary EUnit/Common Test
discovery must have one source entry per module, while default builds,
releases, and Hex packages must not contain test helpers. Rebar3 may create
temporary suite-directory copies internally when an explicit `ct --suite`
path is selected; those are build artifacts, not additional source roots.

Use application include paths such as `-include("adk_event.hrl").`; never make
an include depend on a test module's directory depth. Add new test modules and
their dedicated fixtures to the directory that owns the tested lifecycle.
Shared fixtures should still have one clear owner: for example, the injected
model HTTP fixture belongs under `test/models/transport/`, while a provider-
specific event fixture belongs under that provider's `request/` or `realtime/`
directory. Test helper modules must never enter default builds or Hex packages.

Run the complete deterministic gate from the repository root:

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
```
