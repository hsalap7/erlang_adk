# README recipe coverage

This document maps the current root [`README.md`](../README.md) recipes to
their prerequisites and validation. It intentionally follows named README
sections instead of assigning fence numbers, so examples can be simplified or
reordered without breaking an artificial identifier scheme.

Prerequisite labels have the following meanings:

- **Local** — no remote model or service is needed. A writable temporary
  directory, local Mnesia database, or loopback socket may still be used.
- **Provider key** — the literal recipe makes a remote model request and needs
  the matching key, network access, quota, and an enabled model.
- **External service** — the complete integration needs a service such as an
  OIDC issuer, MCP server, OpenAPI endpoint, OTLP collector, or public A2A peer.
- **Application adapter** — the application must provide trusted code or
  configuration, such as a sandbox, credential source, resource resolver, or
  authorization policy.

Deterministic tests use probes, fake transports, loopback fixtures, and local
stores. They validate Erlang ADK behavior without spending provider quota.
Live provider checks supplement these tests; they never replace them.

## User recipes

| Recipe and README section | Prerequisites | Deterministic coverage | Live validation |
| --- | --- | --- | --- |
| Compile, start the application, and add it as a dependency — [Installation](../README.md#installation) | Local; dependency download requires network on a fresh checkout | `erlang_adk_startup_test`; complete compile/package gates below | None |
| Create and prompt a Gemini agent — [Your first agent](../README.md#your-first-agent) | Provider key | `readme_examples_test:direct_agent_and_provider_error/0`; `adk_llm_test`; `adk_llm_gemini_test` | [Gemini REST](#gemini-rest) |
| Configure Gemini, OpenAI, Anthropic, and compatible profiles — [Choose a model provider](../README.md#choose-a-model-provider) | Local for validation; provider key for a remote call; external service for a compatible endpoint | `readme_examples_test:multi_provider_profile_contract/0`; `adk_provider_profile_test`; `adk_provider_registry_test`; `adk_provider_registry_live_test`; `adk_provider_credential_test`; provider request/stream codec tests | Gemini profiles: [Gemini REST](#gemini-rest). OpenAI, Anthropic, and compatible providers have no first-party paid suite |
| Load an Erlang tool and let an agent call it — [Add an Erlang tool](../README.md#add-an-erlang-tool) | Provider key for model selection; Local for schema and execution checks | `readme_examples_test:example_modules_compile_and_load/0`; `adk_json_schema_test`; `adk_tool_call_test`; `adk_runner_tools_test` | `weather_tool_round_trip` in [Gemini REST](#gemini-rest) |
| Run agents sequentially, in parallel, by delegation, or as sub-agents — [Run multiple agents](../README.md#run-multiple-agents) | Provider key for the literal agents | `readme_examples_test:correlated_async_delegation/0`, `sequential_parallel_and_loop/0`, `sub_agent_and_agent_as_tool/0`; `erlang_adk_orchestrator_test`; `adk_agent_tree_test`; `adk_sub_agents_test`; `adk_concurrency_stress_SUITE` | Delegation, orchestration, and sub-agent cases in [Gemini REST](#gemini-rest) |
| Compile and run an application-controlled workflow — [Run a workflow](../README.md#run-a-workflow) | Local | `readme_workflow_examples_test`; `adk_workflow_test`; `adk_workflow_graph_test`; `adk_workflow_public_contract_test`; `adk_workflow_contract_ledger`; `adk_durable_workflow_test` | None; the README workflow is deliberately provider-independent |
| Run an agent with events, sessions, stable run IDs, cancellation, and background triggers — [Use the Runner](../README.md#use-the-runner) | Provider key for the literal run; Local for deterministic probes | `readme_examples_test:sync_and_async_runner/0`, `supervised_run_api/0`, `ambient_background_runtime/0`; `adk_runner_test`; `adk_run_test`; `adk_ambient_test`; `adk_ambient_concurrency_SUITE` | Runner cases in [Gemini REST](#gemini-rest) |
| Pause for confirmation or long-running work and resume it — [Human approval and long-running work](../README.md#human-approval-and-long-running-work) | Local; provider key only for the optional model-driven path | `readme_examples_test:tool_confirmation_contract/0`, `suspension_and_pkce_contract/0`; `adk_tool_confirmation_test`; `adk_direct_confirmation_test`; `adk_hitl_test`; `adk_hitl_mnesia_restart_test`; `adk_suspension_test` | `human_approval` in [Gemini REST](#gemini-rest) |
| Stream UTF-8 text — [Streaming and multimodal input](../README.md#streaming-and-multimodal-input) | Provider key | `readme_examples_test:deterministic_streaming/0`, `runner_provider_streaming/0`; `adk_streaming_test`; provider stream codec tests | `streaming` in [Gemini REST](#gemini-rest) |
| Send canonical text and image content — [Streaming and multimodal input](../README.md#streaming-and-multimodal-input) | Provider key | `readme_examples_test:multimodal_content_contract/0`, `supervised_content_streaming/0`; `adk_content_test`; Gemini, OpenAI, Anthropic, and compatible content/request tests | `multimodal_content` in [Gemini REST](#gemini-rest) |
| Start a Gemini Live session and use audio, image, tools, transcription, and browser framing — [Realtime sessions and browser voice](../README.md#realtime-sessions-and-browser-voice) | Provider key | `adk_live_public_api_test`; `adk_live_session_test`; `adk_live_media_test`; `adk_live_gemini_codec_test`; `adk_live_gun_transport_test`; `adk_live_tool_execution_test`; `adk_live_voice_protocol_test`; `adk_live_voice_bridge_test` | [Gemini Live](#gemini-live) |
| Start an OpenAI Realtime session — [Realtime sessions and browser voice](../README.md#realtime-sessions-and-browser-voice) | Provider key | `adk_live_session_profile_test`; `adk_live_session_multi_frame_test`; `adk_live_openai_codec_test`; `adk_live_openai_gun_transport_test`; voice protocol and bridge tests | No first-party paid suite; run an application-owned smoke against the configured Realtime model |
| Use ETS or Mnesia sessions and query, branch, or rewind history — [Sessions, artifacts, memory, and context](../README.md#sessions-artifacts-memory-and-context) | Local | `readme_examples_test:session_scopes_and_temp_state/0`, `session_query_pagination_and_rewind/0`; `adk_session_service_test`; `adk_state_scoping_test`; `adk_session_query_test`; `erlang_adk_session_mnesia_test` | `mnesia_runner` in [Gemini REST](#gemini-rest) |
| Store immutable artifacts in ETS or the filesystem — [Sessions, artifacts, memory, and context](../README.md#sessions-artifacts-memory-and-context) | Local; writable storage for the filesystem adapter | `readme_examples_test:memory_and_artifacts/0`; `adk_artifact_conformance_test`; `adk_artifact_ets_test`; `adk_artifact_fs_test`; `adk_context_capability_test`; `adk_context_runner_test` | `artifact_and_memory_tools` in [Gemini REST](#gemini-rest) |
| Retrieve and ingest exact-user memory — [Sessions, artifacts, memory, and context](../README.md#sessions-artifacts-memory-and-context) | Local; provider key for model-selected retrieval | `readme_examples_test:memory_and_artifacts/0`; `adk_memory_conformance_test`; `adk_memory_v2_ets_test`; `adk_memory_mnesia_test`; `adk_memory_outbox_test`; `adk_context_runner_test` | `artifact_and_memory_tools` in [Gemini REST](#gemini-rest) |
| Select, compact, and cache provider request context — [Sessions, artifacts, memory, and context](../README.md#sessions-artifacts-memory-and-context) | Local for policy and cache behavior; provider key for a real provider cache | `adk_context_policy_test`; `adk_context_envelope_test`; `adk_context_compaction_test`; `adk_context_cache_test`; `adk_context_cache_gemini_test`; `adk_context_runner_test` | `context_cache` in [Gemini REST](#gemini-rest) |
| Turn an OpenAPI operation into agent tools — [Integrations](../README.md#integrations) | External service; provider key when a model selects the tool; application adapter for protected credentials | `readme_examples_test:openapi_toolset_as_agent_tools/0`; `adk_openapi_schema_test`; `adk_openapi_toolset_test`; `adk_openapi_toolset_boundaries_test`; `adk_openapi_production_adapters_test`; `adk_openapi_gun_transport_security_test` | Run an application-owned smoke against the selected OpenAPI endpoint and provider |
| Connect to or expose MCP tools — [Integrations](../README.md#integrations) | Local for repository fixtures; external service for a real MCP peer | `readme_examples_test:mcp_stdio_fixture/0`, `mcp_streamable_http_fixture/0`; `adk_mcp_test`; `adk_mcp_streamable_http_SUITE` | Run an application-owned stdio or HTTPS MCP interoperability smoke |
| Execute model-requested code through an external sandbox — [Integrations](../README.md#integrations) | Application adapter and external service | `adk_code_toolset_test`; normal tool policy, timeout, and cancellation tests | Run the owning application's sandbox conformance and isolation checks |
| Expose or call agents through A2A 1.0 — [Integrations](../README.md#integrations) | Application adapter for public authentication; external service for a real peer; provider key only when the backing agent calls a model | `adk_a2a_v1_codec_test`; `adk_a2a_v1_server_test`; `adk_a2a_v1_http_test`; `adk_a2a_v1_client_security_test`; `adk_a2a_v1_auth_test`; `adk_a2a_v1_agent_executor_test` | Run an application-owned authenticated HTTPS peer smoke |
| Add plugins, callbacks, metrics, traces, and OTLP export — [Plugins, observability, and evaluation](../README.md#plugins-observability-and-evaluation) | Local for pipelines and telemetry; application adapter and external service for a real exporter/collector | `readme_examples_test:callbacks_and_telemetry/0`, `plugins_observability_and_eval_sets/0`; `adk_plugin_pipeline_test`; `adk_plugin_runner_integration_test`; `adk_plugin_builtin_test`; `adk_plugin_stateful_test`; `adk_observability_v2_test`; `adk_observability_runner_test`; `adk_trace_context_test`; `adk_otlp_json_test`; `adk_otlp_http_json_exporter_test` | Send a smoke trace to the deployment's configured OTLP endpoint |
| Evaluate an agent and render or compare reports — [Plugins, observability, and evaluation](../README.md#plugins-observability-and-evaluation) | Provider key for the checked CLI agent; Local for criteria and report fixtures | `readme_examples_test:plugins_observability_and_eval_sets/0`, `lightweight_evaluation/0`; `adk_eval_set_test`; `adk_eval_criteria_test`; `adk_eval_v2_test`; `adk_eval_dev_view_test`; `adk_eval_llm_judge_test`; `adk_cli_test` | Evaluation and rubric-judge cases in [Gemini REST](#gemini-rest) |
| Validate inbound OIDC/JWT and obtain outbound OAuth credentials — [Authentication](../README.md#authentication) | External service and application adapter | `adk_oidc_security_test`; `adk_oidcc_adapters_test`; `adk_auth_test`; `adk_auth_bounds_test`; `adk_auth_rotation_test`; `adk_authorization_flow_test`; `adk_suspension_test` | Run an application-owned issuer discovery, login, refresh, revocation, and scope smoke |
| Build the CLI, validate configuration, run once, or use the console — [CLI and local developer UI](../README.md#cli-and-local-developer-ui) | Local for `doctor` and validation; provider key for `run`, `console`, and model-backed evaluation | `adk_cli_test`; checked `examples/agent.json` and `examples/eval.json` | Use the literal `adk run`, `console`, or `evaluate` command in the README |
| Start the authenticated loopback developer UI — [CLI and local developer UI](../README.md#cli-and-local-developer-ui) | Local; provider key for model calls; application adapter for artifact, memory, context, or Live panels | `adk_cli_test`; `adk_dev_http_test`; `adk_dev_v05_http_test`; `adk_dev_v07_http_test`; `erlang_adk_startup_test` | Start `adk serve` as shown in the README and exercise the required panel/API from a second process |
| Start the Phoenix companion with local authentication — [Phoenix UI](../README.md#phoenix-ui) | External service for first dependency download; provider key for model/Live calls | `mix precommit`, including Phoenix ExUnit and browser/audio Node tests with fake providers | Start Phoenix as shown in the README; follow its guide to create a Live session and test browser voice |
| Use Phoenix with OIDC or in a production release — [Phoenix UI](../README.md#phoenix-ui) | External service and application adapter | Phoenix auth/controller/gateway/LiveView tests; production asset, release, audit, and smoke gates in `RELEASING.md` | Run an application-owned OIDC login and authenticated agent/Live smoke over the deployed TLS boundary |

## Check mapping

| README check | Prerequisites | What it validates |
| --- | --- | --- |
| [Quick check while developing](../README.md#quick-check-while-developing) | Local | Compilation plus the focused README and workflow EUnit modules |
| [Core checks before opening a pull request](../README.md#core-checks-before-opening-a-pull-request) | Local; loopback sockets must be permitted | Clean compile, complete EUnit and deterministic Common Test, Dialyzer, fresh aggregate coverage, and Xref |
| [If README examples changed](../README.md#if-readme-examples-changed) | Local | Focused recipe behavior plus warning-as-error compilation of checked example modules |
| [If the Phoenix application changed](../README.md#if-the-phoenix-application-changed) | External service for the initial dependency/tool download | Locked dependencies, formatting, warning-free compilation, assets, browser/audio JavaScript, ExUnit, and the exact dependency-audit policy |
| [Documentation, CLI, and package checks](../README.md#documentation-cli-and-package-checks) | Local after dependencies are present | CLI assembly and smoke checks, ExDoc, Hex package assembly, package contents, and clean extracted-package compilation |
| [Optional paid Gemini checks](../README.md#optional-paid-gemini-checks) | Provider key | Real Gemini REST and Gemini Live interoperability; these commands are deliberately outside the deterministic gate |

The complete deterministic command is authoritative for Erlang behavior:

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
./scripts/coverage.sh
./rebar3 xref
```

The focused README commands are useful diagnostics, but they are not a
replacement for the complete gate:

```bash
./rebar3 eunit --module=readme_examples_test
./rebar3 eunit --module=readme_workflow_examples_test
```

## Live provider commands

### Gemini REST

This suite exercises REST generation, streaming, tools, Runner, orchestration,
multimodal content, data services, evaluation, and related README behavior
with `gemini-3.1-flash-lite`:

```bash
export GEMINI_API_KEY="your_google_api_key"
ERLANG_ADK_GEMINI_REST=1 ./rebar3 ct \
  --suite test/readme/readme_live_gemini_SUITE.erl
```

### Gemini Live

This independent suite exercises the bidirectional WebSocket path with
`gemini-3.1-flash-live-preview`:

```bash
export GEMINI_API_KEY="your_google_api_key"
ERLANG_ADK_GEMINI_LIVE=1 ./rebar3 ct \
  --suite test/models/gemini/gemini_live_SUITE.erl
```

Both commands require network access, quota, and explicit permission to make
provider calls. A skip, provider rejection, quota error, or network failure is
not a passing provider result. OpenAI Responses, Anthropic Messages,
compatible Chat Completions, and OpenAI Realtime have deterministic codec and
injected-transport coverage, but this repository does not currently provide
equivalent first-party paid suites for them.

Detailed test selection, coverage rules, provider-result interpretation, and
release acceptance are documented in [`TESTING.md`](TESTING.md) and
[`RELEASING.md`](RELEASING.md).
