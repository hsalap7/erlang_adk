# Testing Erlang ADK

This guide defines the release gates and how to interpret them. Run commands
from the repository root unless a section changes directory.

## Toolchains

- Core: Erlang/OTP 27; the verified and minimum production patch is OTP
  27.3.4.14.
- Phoenix: Elixir 1.17 or newer on OTP 27; verified with Elixir 1.19.5.
- Browser assets/tests: Node.js; verified with Node 24.3.0.
- Use the repository's `./rebar3` for core commands.

## Test source organization

Erlang tests mirror the production ownership hierarchy under `test/`; the
complete map and placement rules are in [`TEST_LAYOUT.md`](TEST_LAYOUT.md).
The recursive test root is enabled only in Rebar3's `test` profile, so EUnit
and Common Test discover nested modules while ordinary builds and packages do
not compile test helpers.  Explicit Common Test commands must use each suite's
full path; EUnit module selection remains path-independent.

## Complete deterministic Erlang gate

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
```

The final 2026-07-16 v0.7 run passed:

- 1,176 EUnit tests;
- six deterministic Common Test cases;
- Dialyzer over 210 project files with no warnings; and
- both 1,000-operation concurrency/resource stress scenarios.

Those are historical v0.7 numbers, not v0.8 evidence.

The final 2026-07-17 v0.8 command exited zero and passed:

- 1,414 EUnit tests;
- six deterministic Common Test cases; and
- Dialyzer analysis over 235 source modules with no warnings.

Common Test intentionally skipped 22 paid-provider cases because their opt-in
flags were absent from this deterministic command. Those skips are expected
and are not included in the six passing deterministic cases.

Some HTTP and protocol fixtures open loopback listeners. A restricted build
environment must allow local sockets; otherwise a permission failure is an
environment failure, not passing test evidence.

## Deterministic line coverage gate

```bash
./scripts/coverage.sh
```

The script resets all previously exported Cover data, performs a clean build,
instruments the complete EUnit and Common Test suites, aggregates both exports,
and fails below 74% executable-line coverage. The HTML summary and per-module
reports are written under `_build/test/cover/`. Do not run `rebar3 cover`
against exports from an earlier source tree: `rebar3 clean` does not remove
stale Cover data.

`./rebar3 cover --verbose` only aggregates previously exported `.coverdata`;
it does not execute or instrument tests. Therefore `No coverdata found` is the
expected result on a clean tree or immediately after `cover --reset`. Use
`./scripts/coverage.sh` to produce both the EUnit and Common Test exports before
rendering the report.

Paid Gemini cases remain explicitly skipped without their opt-in flags, and
Phoenix/ExUnit coverage is a separate project concern. The 74% floor therefore
measures the deterministic Erlang release contract only; it must be raised as
new deterministic behavior becomes covered and must not be weakened to hide a
regression. The final 2026-07-16 aggregate is 73.88% across 210 production
modules. That is historical v0.7 evidence. The final 2026-07-17 v0.8 coverage
script exited zero at 74.17% against the enforced 74% floor, while repeating
1,414 EUnit and six deterministic Common Test passes.

## Path to 100% deterministic coverage

Coverage work must protect behavior, not optimize a number. Add tests for
supported feature and contract branches first: documented public API
preservation, structural failure/cancellation paths, concurrency ownership and
cleanup, persistence/recovery, security boundaries, and provider-neutral wire
behavior. Never remove, deaden, merge away, or make unreachable a supported
feature merely to raise coverage.

Ratchet the merged deterministic Erlang report in reviewed stages:

| Stage | Aggregate floor | Per-module floor for eligible production modules |
| --- | ---: | ---: |
| Current | 74% (74.17% recorded) | No regression from the recorded per-module report |
| Contract breadth | 80% | 60% |
| Failure and concurrency depth | 90% | 75% |
| Boundary completion | 95% | 90% |
| Complete | 100% | 100% |

Each stage merges fresh EUnit and deterministic Common Test line-hit data from
the same source revision; percentages from separate reports must never be
averaged or added. Phoenix ExUnit/Node results and paid-provider evidence stay
separate because they do not instrument the Erlang source report. A module may
be excluded only when it is generated code or a behaviour-only declaration
with no executable product behavior; every exclusion must be narrow,
documented, and release-reviewed. Adapters, error branches, unsupported-input
guards, and concurrency code are not exclusion candidates merely because they
are difficult to exercise.

A release is accepted only when all deterministic gates pass, aggregate and
per-module floors do not regress, the public feature ledger remains intact,
and any exclusion list is unchanged or explicitly approved. Once a stage is
reached on the release branch, raise the enforced floor and do not lower it to
accommodate a later regression. The 100% milestone requires every eligible
production line to be reached by behavior-asserting tests; remote credentials,
quota, or provider availability are never substitutes for deterministic
contract coverage.

## README and focused v0.8 gates

```bash
./rebar3 eunit --module=readme_examples_test
./rebar3 eunit --module=readme_workflow_examples_test

erlc -Werror -pa _build/default/lib/erlang_adk/ebin -o /tmp \
  examples/readme_weather_tool.erl \
  examples/readme_live_weather_executor.erl \
  examples/readme_stateful_counter_plugin.erl

./rebar3 eunit \
  --module=adk_live_media_test,adk_live_gemini_codec_test,adk_live_gun_transport_test,adk_live_public_api_test,adk_live_session_test,adk_live_tool_execution_test,adk_live_observability_test,adk_live_voice_protocol_test,adk_live_voice_bridge_test,adk_plugin_pipeline_test,adk_plugin_runner_integration_test,adk_plugin_builtin_test,adk_plugin_stateful_test,adk_trace_context_test,adk_observability_v2_test,adk_observability_runner_test,adk_otlp_json_test,adk_otlp_http_json_exporter_test,adk_eval_criteria_test,adk_eval_v2_test,adk_eval_llm_judge_test,adk_eval_dev_view_test,adk_dev_v07_http_test,adk_cli_test

./rebar3 eunit \
  --module=adk_provider_credential_test,adk_provider_profile_test,adk_provider_profile_snapshot_test,adk_provider_registry_test,adk_provider_registry_live_test,adk_provider_request_options_test,adk_provider_capabilities_test,adk_model_http_headers_test,adk_model_gun_transport_test,adk_model_sse_decoder_test,adk_llm_openai_test,adk_openai_responses_content_test,adk_openai_responses_codec_test,adk_openai_responses_stream_test,adk_llm_anthropic_test,adk_llm_anthropic_content_test,adk_llm_anthropic_request_test,adk_llm_anthropic_stream_test,adk_llm_compatible_test,adk_llm_compatible_content_test,adk_llm_compatible_request_test,adk_llm_compatible_stream_test,adk_live_openai_codec_test,adk_live_openai_gun_transport_test,adk_live_session_multi_frame_test,adk_live_session_profile_test,adk_live_voice_protocol_test,adk_live_voice_bridge_test,adk_llm_test,adk_cli_test

./rebar3 ct --suite test/runtime/invocations/adk_concurrency_stress_SUITE.erl
./rebar3 ct --suite test/integrations/stress/adk_v05_stress_SUITE.erl
```

The historical v0.7 evidence is 29 README tests, four workflow tests, warning-as-error
compilation/runtime smoke for all three example modules, and 193 focused
Live/plugin/observability/evaluation/developer tests. The stress suites cover
1,000 correlated stable runs, 1,000 isolated artifact/memory writes, and 128
cache acquisitions collapsing to four exact-scope provider lifecycles.
The stable-run stress assertions correlate every response with its exact
session and invocation, require unique run IDs, verify supervisor cleanup, and
leave the test-process mailbox stable after each bounded concurrent batch.

The second focused EUnit command isolates the 0.8 additions. The final
2026-07-17 focused provider/profile/Realtime run passed 244/244. It remains
diagnostic; the clean complete gate is authoritative. A deterministic HTTP
fixture or WebSocket state-machine test does not prove that a paid remote
provider accepted the request.

The final README gates passed 30 README and four workflow tests (34/34), and
all three example modules compiled with warnings as errors. The v0.7 totals in
the preceding paragraph remain historical rather than being silently updated.

After the final audit repairs, the seven-module targeted regression set passed
67/67. It covers multi-frame priority ordering, Anthropic
`max_tokens >= 1` validation, and synchronous/streaming Gun header and trailer
limits.

## Focused v0.9 graph, durability, and model gates

Use this focused set when maintaining the released 0.9 line:

```bash
./rebar3 eunit \
  --module=adk_workflow_v09_runtime_test,adk_workflow_data_contract_test,adk_workflow_first_success_recovery_test,adk_workflow_join_policy_test,adk_workflow_graph_test,adk_graph_foundation_test

./rebar3 eunit \
  --module=adk_agent_provider_capability_test,adk_provider_profile_test,adk_provider_registry_live_test,adk_provider_request_options_test,adk_provider_vertex_test,adk_local_model_endpoint_test,adk_google_adc_test,adk_model_http_client_test,adk_llm_vertex_test,adk_cli_test
```

These tests cover checkpoint-v2 identity and v1 migration, durable attempts,
lifecycle ordering, nested continuation, typed workflow tool confirmation,
join policies, node schemas, state reducers, graph inspection/CLI, effective
provider capabilities, loopback-only local endpoints, and injected-transport
Vertex/ADC behavior. They are diagnostic; they do not replace the clean EUnit,
Common Test, Dialyzer, coverage, xref, package, and documentation gates.

The Vertex and local-server cases are deterministic configuration/codec/
transport-boundary evidence. They are not evidence that a paid Vertex project
or every Ollama, vLLM, LiteLLM, compatible gateway, or model version accepted a
request. Record optional remote smokes separately, including exact project,
region, server/version/model, date, and failure/skip status.

The recorded 0.9 deterministic release validation compiled 242 production and
271 test modules with `-Werror`, passed all 1,495 EUnit tests and all 6 Common
Test cases, and reported 0 Dialyzer warnings and 0 undefined or deprecated
call/function findings from `./rebar3 xref`. These direct gates do not
substitute for the unrecorded coverage, package, or paid-provider gates.

## Focused v0.10 merged-capability gates (in development)

Use subsystem-focused diagnostics while developing the unreleased 0.10
branch. These commands are intentionally split so a failure keeps one clear
owner; they do not replace the clean aggregate gate.

```bash
./rebar3 eunit \
  --module=adk_scope_sharded_test,adk_runtime_service_bundle_test,adk_v010_supervision_test,adk_agent_config_test,adk_agent_composition_test,adk_connector_descriptor_test,adk_connector_manifest_test,adk_connector_toolset_test

./rebar3 eunit \
  --module=adk_artifact_gcs_test,adk_artifact_stream_test,adk_artifact_effect_journal_test,adk_artifact_effect_journal_context_test,adk_artifact_effect_journal_bundle_test,adk_memory_embedding_provider_test,adk_memory_vector_ets_test,adk_memory_policy_test,adk_memory_erasure_epoch_test,adk_memory_outbox_test,adk_memory_outbox_supervision_test,adk_runner_durable_memory_test

./rebar3 eunit \
  --module=adk_mcp_protocol_foundation_test,adk_mcp_modern_runtime_test,adk_mcp_catalog_foundation_test,adk_mcp_oauth_test,adk_mcp_pool_test,adk_mcp_sse_stream_test,adk_a2a_v1_agent_executor_test,adk_a2a_v1_client_stream_test,adk_a2a_v1_task_store_test,adk_a2a_v1_push_test

./rebar3 eunit \
  --module=adk_eval_service_test,adk_eval_store_hardening_test,adk_eval_builtin_metric_test,adk_eval_ensemble_test,adk_eval_simulation_test,adk_eval_statistics_test,adk_eval_review_test,adk_eval_export_test,adk_eval_report_parity_test,adk_eval_worker_rpc_test,adk_eval_dev_api_test

./rebar3 eunit \
  --module=adk_trace_store_test,adk_trace_store_exporter_test,adk_trace_runtime_test,adk_workflow_trace_store_test,adk_dev_graph_trace_test,adk_dev_eval_http_test,adk_dev_payload_inspection_test,adk_runtime_policy_test,adk_deployment_lifecycle_test,adk_deployment_env_test,adk_deployment_contract_test,adk_agent_runtime_feasibility_test,erlang_adk_startup_test,adk_cli_test

./rebar3 ct \
  --suite test/protocols/mcp/adk_mcp_streamable_http_SUITE.erl
```

These focused owners cover:

- strict local profiles, shared/global versus exact-scope routing, owner-bound
  exactly-once operation leases and absolute deadlines, durable idle
  reclamation, fail-stop generations, and fail-closed application resolution;
  `durable_local` also atomically owns/health-checks its private Mnesia memory
  outbox, injects validated Runner ingestion, and preserves jobs across bundle
  process restarts while rejecting stale/unhealthy service references. This
  includes deterministic identity-filtered registry hydration, rotating bounded
  indexed claims/pruning, four-table constant-row health, majority readiness,
  epoch-bound resubmission, hard active-plus-terminal capacity/migration, strict
  nested validation, legacy named-API routing, and redacted status;
- schema-v2 JSON/strict-YAML normalization plus schema-1 compatibility,
  sealed immutable registry lineage/revision provenance, 64 unique toolset
  references resolved by one authenticated bulk lookup, data-only composition,
  connector policy projection, and default-disabled legacy module/provider
  selection;
- GCS-compatible immutable artifacts, bounded range/credit transfer and
  operator/backend-owned effect reconciliation; bounded embedding/vector/
  hybrid memory, opt-in governance, erasure epochs, and explicit terminal
  pruning;
- explicit legacy/modern MCP eras, incremental SSE, OAuth/PKCE, pooling and
  atomic catalogs; Runner-backed A2A, callback streaming, task stores, and
  process-local bounded push;
- atomic/quota-bound evaluation scheduling/storage plus simulators, built-in
  metrics, ensembles/calibration, review, statistics, CI export and allowlisted
  RPC workers, including byte-identical canonical JSON/Markdown/JUnit/SARIF/
  annotations across direct, stored-result API, authenticated HTTP, existing
  eval-run, and `adk eval report` paths; a roughly 1.4 MiB report covers exact
  API/HTTP/stdout/file parity and the independent 16 MiB report ceiling while
  unrelated CLI/request limits remain 1 MiB/64 KiB; and
- metadata-only trace retention, graph/trace/evaluation Developer UI surfaces,
  explicit bounded/redacted payload inspection, opt-in runtime policy,
  fail-closed durable-ledger schema checks, health-only startup, bounded
  descriptor startup, one PID1-owned drain, strict deployment OTLP wiring, and
  render-first deployment contracts. Deployment coverage distinguishes the
  closed, packaged-health, and application-config modes; checks both Cloud Run
  `maxScale` annotation scopes without treating them as a singleton proof; and
  verifies that the read-only Agent Runtime probe keeps its bounded bearer out
  of process arguments.

The curated connector packages own additional package-local deterministic
tests (`erlang_adk_google_test`, `erlang_adk_github_test`,
`erlang_adk_slack_test`, and `erlang_adk_postgres_test` plus their injected
backend fixtures). They execute every advertised operation through the real
registry, Agent Config, and `adk_toolset` path and assert projected permission,
side-effect, confirmation, and parallel-safety metadata. Root EUnit does not
turn those packages into published ecosystem or live-service evidence.

Local source testing uses `_checkouts/erlang_adk`, which `rebar3_hex` 7.1.0
intentionally omits from the generated requirements metadata. Therefore the
raw local `rebar3 hex build` tarball is not the connector package artifact to
inspect or retain. Run the sole supported offline connector package gate from
the repository root:

```console
$ packages/build_connector_packages.sh
```

The wrapper warning-strict compiles/tests source, builds and internally
normalizes all four package tarballs, prints package/docs SHA-256 hashes,
rejects checkout leakage, and recompiles/tests clean extractions. Each
normalized archive must contain the non-optional `erlang_adk ~> 0.10.0`
requirement. The [connector package guide](../packages/README.md) explains the
normalizer's use of the declared `rebar.config` dependency and Hex's tarball
implementation. This is an offline inspection/build gate only:
`rebar3_hex` 7.1.0 rebuilds during `hex publish` and cannot upload a normalized
local tarball. The gate is not publication evidence, and all four connectors
remain unpublished.

No focused or internal fixture run by itself proves an external protocol peer,
multi-node node-loss recovery, Docker runtime build, Cloud Run staging,
Helm/Kind/GKE deployment, supply-chain execution, or managed Agent Runtime.
Record those gates only if they were actually run against the reviewed
candidate.

Two explicit loopback protocol gates are now recorded separately. The pinned
official MCP Python/TypeScript 2.0.0 client matrix passed modern 2026-07-28 and
legacy-auto-fallback 2025-11-25 in all four cells; exact commits, locks, and
assertions are in `scripts/conformance/mcp_external_sdk/RESULTS.json`. The
official A2A 1.0 TCK at
`5996b79f9cefa6fc390980e383e358a66fb9e49e` passed 100 tests with 165
expected transport/capability skips and no failures/errors/xfail; the selected
JSON-RPC surface was 94 passed plus seven inapplicable skips. Neither result
replaces an application-owned authenticated HTTPS peer/push smoke, other A2A
transports, or multi-node failure testing.

After the final OTLP ordering fix, the deployment-environment, trace-runtime,
deployment-contract, and lifecycle EUnit modules passed 24/24. A separate
health/startup-inclusive focused batch had passed 20/20 before that OTLP-only
fix. These checks cover the relx health-config path and nondefault `PORT`
rendering, open-file-cap validation, PID1 drain/reap structure, health-only
listener, final trace-plus-OTLP ordering, and timeout boundary. The batches
overlap and are focused evidence, not aggregate or image/cluster evidence.

The final local image `erlang-adk:0.10.0-final` built from fresh locked
dependencies at OCI/index digest
`sha256:d74eb0a349d45692b5bb59e5ac7f1bbbe3710a59cd2e0be5301a179ce28f92d7`.
A constrained direct smoke passed uid/gid 10001, read-only root,
cap-drop/no-new-privileges, 1 GiB/1 CPU, 200/200 health, agent-route 404,
PID1/BEAM nofile 65536, about 103.9 MiB current memory, no OOM/restart, and
SIGTERM exit 0 in 1.218 seconds. A disposable Kind cluster passed both
closed/headless and service-enabled health-only Helm modes. The latter rendered
nondefault `PORT=18081`, returned 200/200 health and 404 for an agent route,
and recorded 110,538,752/388,038,656 current/peak bytes with zero restarts;
headless recorded 119,377,920/397,217,792 bytes. Drain made readiness false and
`/readyz` 503 while `/livez` stayed 200; pod deletion/recovery completed in
1.822 seconds. The cluster was deleted. This does not satisfy the custom
application-config mode, GKE/Cloud Run staging, registry promotion,
SBOM/Grype/Cosign/provenance execution, or managed-runtime gates; see the
[deployment guide](../deploy/README.md).

The merged-candidate Phoenix gate passed 107 ExUnit and 40 Node/browser-audio
tests, production assets and release assembly, and both trusted-proxy and
CA-verified direct-TLS `/health` smokes with clean shutdown. The exact audit
wrapper accepted only Cowlib EEF-CVE-2026-43969, Cowlib EEF-CVE-2026-43966,
and Gun GHSA-w4f7-4cxr-rv3c; raw `mix hex.audit` therefore remains non-zero.
The earlier Bandit, Cowboy, and HPACK advisories were absent. Live registry
access failed with `Unknown CA`, so only the cached locked dependency gate is
claimed.

Current evidence names the `codex/version_0.10.0` working-tree candidate.
HEAD `78f31fd6b72295ebeb37cecbd7c11a6c5a666b34` is only the v0.9 baseline;
all v0.10 work remains uncommitted, so the state is not reproducible from a
commit or tag. The changed-candidate non-coverage and coverage EUnit runs each
passed 1,826/1,826; deterministic Common Test passed 6 with 22 expected paid-
provider skips. Compile/xref passed, Dialyzer analyzed 669 PLT files and 309
project files with 0 warnings, and line coverage was 36,574/49,312 = 74.17%
(12,738 missed; 83 covered lines over the exact 74% floor). Focused durable-
runtime validation passed 46/46 EUnit, and focused canonical evaluation-report
parity plus size-boundary validation passed 56 tests. Escript/doctor/checked-
config gates passed. README EUnit passed 30/30 plus 4/4, all three checked
examples compiled with `-Werror`, and ExDoc, local Markdown, root Hex/verifier/
extracted compile, and diff gates passed. Root artifact hashes/freshness stay
out of packaged docs to avoid self-reference. The connector wrapper separately passed
4 packages, 12/12 source EUnit, 12/12 clean-extracted EUnit, and 4 package plus
4 docs archives, including real registry/Agent Config/toolset execution for
every advertised operation. Exact identities, hashes, protocol/deployment
evidence, and not-run boundaries are in
[`VERSION_0_10_0.md`](VERSION_0_10_0.md#development-validation-ledger).

These passing tests do not prove 0.10 is released. The version remains
**IN DEVELOPMENT** until explicit maintainer approval, tagging, and publication.
Do not infer paid-provider, multi-node node-loss, cloud/GKE, promoted-registry,
supply-chain-artifact, connector-publication, or managed-runtime success from
the deterministic candidate gates.

Every current README recipe and sanity command is mapped to its prerequisites
and validation in
[`README_EXAMPLE_COVERAGE.md`](README_EXAMPLE_COVERAGE.md).
The focused suites directly exercise deterministic core, workflow, Live,
plugin, evaluation, retry, memory, and artifact examples. Features that need
dedicated startup state or transport fixtures—such as HITL, Mnesia,
authenticated developer startup, the project-specific HTTP endpoint, and
Gemini wire behavior—are asserted by their owning test modules; a focused
README smoke may check that those modules remain present without replacing
their complete tests.

## CLI and package smoke gate

```bash
./rebar3 xref
./rebar3 escriptize
_build/default/bin/adk doctor
_build/default/bin/adk config validate examples/agent.json
./rebar3 ex_doc
./rebar3 hex build
./scripts/verify_hex_package.sh
```

For v0.9, `adk doctor` must report application version `0.9.0`, OTP 27, the
REST default `gemini-3.1-flash-lite`, required dependencies, and whether a
Gemini, OpenAI, or Anthropic key is configured without exposing any key. The
configuration validator must accept configured binary profiles through their
safe aliases without projecting credential sources or values. The checked
agent configuration must validate with the same REST model. Xref checks
undefined and deprecated calls/functions without treating a library's public
exports as unused errors. ExDoc must be warning-free. The non-publishing Hex
build and artifact verifier must prove required contents, excluded
caches/secrets, and a clean compile from the extracted package.

On the 0.10 development branch, `adk doctor` should report application version
`0.10.0`, while the README must continue to identify v0.9.0 as the current
release and v0.10.0 as **IN DEVELOPMENT**. `adk config validate` must also
report schema version 1, registry generation, `registry_instance_id`,
`registry_snapshot_revision_id`, and a 64-byte hexadecimal fingerprint without
exposing registry descriptors, the internal content seal, or credentials. The
instance ID identifies a lineage and is stable across `replace/2`; the revision
is fresh for every replacement, so equal generation numbers on two branches do
not collide. The initial empty default is the only stable revision. API tests
must also reject a structurally copied registry/snapshot whose trusted entries
do not match its seal.

Historically, on 2026-07-17, xref, escript assembly, `adk doctor` reporting
0.8.0, checked
configuration validation, ExDoc, the 0.8.0 Hex build, and compilation from the
verified extracted package all passed.

No equivalent 0.9 package result was recorded for this release. Run all
commands above before making a later package-evidence claim.

## Paid Gemini REST gate

Export the key and opt-in flag in the shell that starts Common Test:

```bash
export GEMINI_API_KEY="your_api_key_here"
ERLANG_ADK_GEMINI_REST=1 ./rebar3 ct \
  --suite test/readme/readme_live_gemini_SUITE.erl
```

Despite the historical suite filename, this is REST GenerateContent/SSE using
`gemini-3.1-flash-lite`; it is not Gemini Live. It exercises 17 cases and
roughly 39 provider requests, including text, function/tool rounds, Search
grounding, multimodal generation/streaming, explicit context-cache creation,
artifact/memory tools, orchestration, continuation, Mnesia, telemetry,
evaluation, and the HTTP endpoint.

The suite spaces request starts by 4.2 seconds by default. On projects with
sufficient quota, pacing can be disabled explicitly:

```bash
ERLANG_ADK_GEMINI_REST=1 \
ERLANG_ADK_GEMINI_REST_INTERVAL_MS=0 \
./rebar3 ct --suite test/readme/readme_live_gemini_SUITE.erl
```

The test transport caps each wait at 15 seconds and retries one non-streaming
transport timeout. A non-streaming HTTP 429 receives one bounded backoff of at
least 10 seconds; a second 429 fails explicitly. Test agent/direct-turn worker
timeouts are 120 seconds, while production defaults remain 60 seconds. These
settings pace only the paid suite and do not change production concurrency or
retry behavior.

The final 2026-07-15 v0.7 run completed all 17 cases with no skips: 15 passed;
`google_search_grounding` and `context_cache` each failed with HTTP 429 after
one bounded retry. Preserve those results as quota failures, not product
passes or skips. The rubric judge and artifact/memory cases passed.

The 2026-07-17 v0.8 attempt reached Google, but the provider rejected the
configured credential shape with HTTP 401 `UNAUTHENTICATED` and reason
`ACCESS_TOKEN_TYPE_UNSUPPORTED`. The suite therefore did not produce a paid
REST pass. Record this as an external credential failure, not a pass, skip, or
Erlang ADK product regression; deterministic Gemini REST/header evidence
remains separate.

`ERLANG_ADK_LIVE_GEMINI` and
`ERLANG_ADK_LIVE_GEMINI_INTERVAL_MS` remain compatibility aliases for this
historical REST suite. New automation should use the unambiguous REST names.

## Paid Gemini Live gate

```bash
export GEMINI_API_KEY="your_api_key_here"
ERLANG_ADK_GEMINI_LIVE=1 ./rebar3 ct \
  --suite test/models/gemini/gemini_live_SUITE.erl
```

This suite uses `gemini-3.1-flash-live-preview` and covers five cases:
text-to-audio plus transcription, 16 kHz PCM input, PNG input, a synchronous
tool round trip, and owner-bound browser framing/ACK behavior. The complete
2026-07-15 v0.7 recorded suite passed 5/5. It skips unless both the opt-in flag
and key reach the Common Test process.

The paid suite is provider-integration evidence. Deterministic codecs,
transport state, ownership, backpressure, reconnect, tool, observability, and
voice-bridge tests remain the release contract when network access or quota is
unavailable.

No v0.8 paid Gemini Live pass is recorded by the 2026-07-17 validation. The
focused Gemini Live broker/transport evidence remains deterministic and does
not establish remote-provider success. The v0.7 5/5 result above remains
historical and must not be carried forward as v0.8 evidence.

## OpenAI, Anthropic, and compatible provider evidence

The 0.9 repository currently provides deterministic injected-transport and
codec coverage for OpenAI Responses, Anthropic Messages, compatible Chat
Completions, OpenAI Realtime, and Vertex AI GenerateContent/SSE. It does not
currently provide a first-party opt-in paid Common Test suite for those
providers. Therefore:

- `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` being present is not itself a test;
- deterministic fixture success must be reported as deterministic evidence,
  not remote-provider success;
- a manual OpenAI/Anthropic smoke must record the exact profile alias, concrete
  model/version in deployment-owned evidence, date, operation, and structural
  result without recording prompts, outputs, or credentials; and
- every OpenAI-compatible endpoint needs its own evidence because the adapter
  does not certify optional vendor semantics.

If a repository paid suite is added later, it must be opt-in, skip cleanly
without both its explicit flag and credential, use a release-owned account,
and report skips/provider/quota failures separately from passes.

## Phoenix, LiveView, and browser gate

```bash
cd examples/phoenix_adk_ui
mix deps.get
mix assets.setup
mix precommit
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
mix hex.audit
elixir ../../scripts/verify_phoenix_hex_audit.exs
../../scripts/smoke_phoenix_release.sh proxy 4101
../../scripts/smoke_phoenix_release.sh tls 4443
```

For v0.7, `mix precommit` checked formatting, compiled with warnings as errors,
built assets, ran 31 dependency-free Node browser/audio tests, and ran 101
ExUnit tests. Production assets, release assembly, and both loopback smoke
modes passed. Those counts are historical. On 2026-07-17 the v0.8
`mix precommit` gate passed with 103 ExUnit and 40 dependency-free Node tests.
Production assets, release assembly, and both trusted-proxy and direct-TLS
loopback smokes also passed.

The v0.9.0 companion gate passed with the refreshed security locks: 103 ExUnit
tests, 40 dependency-free Node browser/audio tests, warnings-as-errors
compilation, production assets, release assembly, and both trusted-proxy and
verified direct-TLS health smokes. `mix deps --check-locked` reports every
dependency current, including the path dependency as Erlang ADK 0.9.0.

The current locks resolve Bandit 1.12.4, Cowboy 2.18.0, Cowlib 2.19.0, and Gun
2.4.1. `mix hex.audit` is expected to remain non-zero only for the three package
findings covering the two unresolved Cowlib advisories documented in
[`SECURITY.md`](../SECURITY.md): EEF-CVE-2026-43969, EEF-CVE-2026-43966, and
Gun's GHSA-w4f7-4cxr-rv3c alias for the latter. The wrapper enforces that exact
package/advisory set and fails for new or stale findings; it does not make the
underlying audit a pass. The root Rebar3 project has no equivalent `rebar3 hex
audit` command; do not describe this Mix result as a root dependency audit.

For the recorded v0.8 gate, raw `mix hex.audit` was non-zero only for the two
Cowlib advisories then present, and the prior exact-exception verifier passed.

The companion's local-auth mode is for interactive development, but its
authorization, CSRF, session, gateway, socket, LiveView, static-asset, and
audio tests use deterministic fake providers and spend no Gemini quota.

## Result policy

Report each category separately:

- **pass** — the command/case completed its assertions;
- **skip** — an explicit optional prerequisite was absent;
- **provider failure** — the live request ran but the provider, network,
  account, or quota rejected it;
- **environment failure** — the build runner could not provide required local
  sockets, tools, certificates, or dependency access; and
- **product failure** — the implementation or assertion failed under its
  documented prerequisites.

Never turn a skip, HTTP 429, dependency advisory, or sandbox restriction into
a pass. Record command, date, toolchain, model, pass/fail/skip counts, and the
bounded structural reason without copying secrets or model content.
