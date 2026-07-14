# README example coverage

This ledger maps every fenced example in `README.md` to its validation layer.
Fence IDs are assigned in document order and are part of the documentation
review contract: when a fence is inserted, removed, or materially changed,
update this ledger in the same change.

Classifications:

- **Literal deterministic**: the literal example, apart from generated names,
  ports, timeouts, or a deterministic test provider, runs in the Rebar3 gate.
- **Deterministic equivalent**: the same public API and behavior run with a
  local probe, fake transport, or offline protocol fixture.
- **Dedicated fixture**: focused EUnit or Common Test covers protocol,
  persistence, failure, security, or lifecycle behavior that is unsuitable for
  the README smoke suite.
- **Live**: the opt-in Gemini suite sends real requests using
  `gemini-3.1-flash-lite`.
- **Companion syntax**: configuration belongs to a consumer or another
  toolchain and is reviewed, but is not compiled by this repository.
- **Adapter-dependent**: application credentials, infrastructure, or an
  application-owned adapter are required before the literal example can run.
- **Conceptual continuation**: the fence intentionally starts with a value
  produced by a preceding flow, such as a run ID, pause event, policy, or
  provider callback result.

`Live` and `adapter-dependent` examples must still have deterministic wire or
contract coverage. A live pass supplements rather than replaces those tests.
This ledger names the evidence for each fence. The completed 0.4 clean gate
passed 654 EUnit tests, four deterministic Common Test scenarios, and Dialyzer
over 134 project files; that is inherited baseline evidence, not a 0.5 release
result. On the 0.5 branch, the focused README suite passes 29 tests, the
developer HTTP suite passes nine, the cache lifecycle core passes ten, and the
exact-scope artifact/memory sharding suite passes 12.
An earlier combined 14-module artifact/memory/context snapshot passed 90
before subsequent Runner/lifecycle tests landed. The final clean deterministic
gate supersedes that snapshot: 765 EUnit tests and six Common Test scenarios
passed with no failures, and Dialyzer reported no warnings across 160 project
files. The separate escript packaging, doctor, and checked-config gate also
passes. The clean command did not enable paid provider tests, so all 16 live
cases were skipped and are not counted as passes. The checked-in
live suite includes real Runner explicit-cache create/reuse and model-selected
exact-scope memory/artifact cases. The full 2026-07-14 run against
`gemini-3.1-flash-lite` passed 14 cases and failed two, with no skips. The data
case passed. Google Search grounding and context-cache creation each received
HTTP 429 after the one bounded ten-second retry; those are explicit quota/rate-
limit failures, not implementation passes. Live evidence supplements rather
than replaces deterministic contracts in this ledger.

## Installation and provider examples

| ID | README fence | Language | Classification | Exact validation | Prerequisites and continuation notes |
| --- | --- | --- | --- | --- | --- |
| F01 | Installation: Git dependency declaration | Erlang | Companion syntax | The project itself is compiled by the complete Rebar3 gate; no separate consumer project is created. | Requires Git/network access and the `version_0.5.0` branch. The literal `deps` term belongs in a consumer `rebar.config`. |
| F02 | Installation: start the application | Erlang | Literal deterministic | `readme_examples_test:setup/0`; `erlang_adk_startup_test` | The application must be compiled first. |
| F03 | Installation: export `GEMINI_API_KEY` | Bash | Live | `readme_live_gemini_SUITE:init_per_suite/1` verifies that the opt-in flag and key reach the test process. | Must run in the same shell as F78/F79. The key is never supplied to deterministic tests. |
| F04 | Quickstart: weather tool and direct agent | Erlang | Deterministic equivalent; Live | `readme_examples_test:example_modules_compile_and_load/0`, `direct_agent_and_provider_error/0`; `readme_live_gemini_SUITE:weather_tool_round_trip/1` | Live execution needs F03, network access, and quota. The deterministic path substitutes `adk_llm_probe`. |
| F05 | Quickstart: provider capabilities and config validation | Erlang | Literal deterministic | `readme_examples_test:provider_capability_contract/0`; `adk_llm_test`; `adk_llm_gemini_test:test_strict_config/1` | No API key or network. |
| F06 | Google Search grounding request | Erlang | Deterministic equivalent; Live | `adk_llm_gemini_test:test_google_search_grounding/1`, `test_grounded_tool_call_event/1`; `readme_live_gemini_SUITE:google_search_grounding/1` | Live Search use is model-selected and needs F03. The deterministic fixture proves request shape and metadata decoding. The 2026-07-14 live case received HTTP 429 after one bounded retry, so it failed as rate-limited and is not counted as passed. |
| F07 | Grounding provider-metadata event projection | Erlang | Dedicated fixture | `adk_provider_result_test`; `adk_llm_gemini_test:test_grounding_event_persistence/1`, `test_stream_grounding_agent_event/1` | This is a projected map fragment, not a standalone shell expression with locally bound `GroundingMetadata`. |
| F08 | Gemini thinking configuration | Erlang | Deterministic equivalent; Live | `adk_llm_gemini_test:test_thinking_payload/1`, `test_thought_summary_response/1`, `test_stream_thought_summary/1`; `readme_live_gemini_SUITE:thinking_configuration/1` | Live execution needs F03. |
| F09 | Gemini safety settings | Erlang | Literal deterministic; Dedicated fixture | `readme_examples_test:provider_capability_contract/0`; `adk_llm_gemini_test:test_safety_payload/1` | Validation is local; no API key or network. |

## Agents, tools, and orchestration

| ID | README fence | Language | Classification | Exact validation | Prerequisites and continuation notes |
| --- | --- | --- | --- | --- | --- |
| F10 | Agent contracts, scoped instructions, schema, and `output_key` | Erlang | Deterministic equivalent | `readme_examples_test:agent_contracts_and_context_policy/0`; `adk_agent_spec_test`; `adk_agent_runtime_spec_test:invocation_output_key_uses_caller_session_scope/0`; `adk_global_instruction_test` | The deterministic test substitutes `adk_llm_agent_spec_probe` while preserving the public Runner/session API. Invocation-scoped writes are checked against the caller session rather than the reusable agent's configured default. |
| F11 | `readme_weather_tool` module | Erlang | Literal deterministic | `readme_examples_test:example_modules_compile_and_load/0` compiles `examples/readme_weather_tool.erl`; `adk_runner_tools_test` | The fence is a module body and is compiled as the repository example file, not pasted into the shell. |
| F12 | External-sandbox code toolset | Erlang | Adapter-dependent; Dedicated fixture | `adk_code_toolset_test:compile_and_schema_test/0`, `resolved_call_is_bounded_and_context_is_minimal_test/0`, `request_policy_rejects_unsafe_or_oversized_values_test/0` | `my_sandbox_adapter` and `SandboxHandle` are application-owned placeholders. No in-process executor is provided by Erlang ADK. |
| F13 | OpenAPI Petstore toolset and agent | Erlang | Deterministic equivalent; Adapter-dependent | `readme_examples_test:openapi_toolset_as_agent_tools/0`; `adk_openapi_toolset_test`; `adk_openapi_production_adapters_test` | The literal example contacts Petstore and Gemini. Tests use the same checked schema with local fake/Gun transports and out-of-band auth. |
| F14 | Correlated asynchronous delegation | Erlang | Deterministic equivalent; Live | `readme_examples_test:correlated_async_delegation/0`; `readme_live_gemini_SUITE:async_delegation/1` | Live execution needs F03. |
| F15 | Sequential and parallel multi-agent execution | Erlang | Deterministic equivalent; Live | `readme_examples_test:sequential_parallel_and_loop/0`; `readme_live_gemini_SUITE:concurrent_orchestration/1`; `adk_concurrency_stress_SUITE` | Live execution needs F03. Stress coverage validates isolation and cleanup at larger scale. |
| F16 | Bounded writer/reviewer loop | Erlang | Deterministic equivalent; Live | `readme_examples_test:sequential_parallel_and_loop/0`; `readme_live_gemini_SUITE:concurrent_orchestration/1`; `erlang_adk_orchestrator_test` | Live natural-language review is nondeterministic; the deterministic reviewer returns exact `APPROVED`. |
| F17 | Sub-agent and agent-as-tool | Erlang | Deterministic equivalent; Live | `readme_examples_test:sub_agent_and_agent_as_tool/0`; `readme_live_gemini_SUITE:sub_agent_and_agent_tool/1`; `adk_sub_agents_test`; `adk_agent_tree_test`; `adk_agent_mailbox_test`; `adk_global_instruction_test` | Focused tests cover strict tree identity/ownership/cycle/depth bounds, fresh delegated history, the private runtime path through direct and dynamically resolved local modules, allowlisted child scope, root global-instruction propagation, and restart-by-name. |
| F18 | Sequential and bounded-parallel declarative workflows | Erlang | Literal deterministic | `readme_workflow_examples_test:sequential_and_parallel_workflows/0`; `adk_workflow_test` | Covers output-to-successor propagation, deterministic parallel output maps, root schemas, per-action timeout/retry, and sequential nested-child resume. Retry attempts are not a durable checkpoint ledger; top-level parallel nested-child pause remains unsupported. |
| F19 | Loop, transfer, and dynamically routed graph workflows | Erlang | Literal deterministic | `readme_workflow_examples_test:loop_transfer_and_graph_workflows/0`; `adk_workflow_test`; `adk_workflow_graph_test`, including `workflow_agent_registry_alias_mismatch_fails_closed/0` | Loop exhaustion is normal bounded completion with the last output. A typed agent resolves a supervised replacement but verifies its canonical runtime identity before dispatch. Nested-child pause remains unsupported in top-level loop bodies and transfer members. |
| F20 | Graph fork/join and pause/resume | Erlang | Literal deterministic | `readme_workflow_examples_test:graph_fork_join_and_pause_resume/0`; `adk_workflow_graph_test` | Tests cover versioned branch output/delta records, deterministic join input, ordinary paused-branch output, and nested workflow resume without replaying the paused child. A concurrent sibling cancelled before commit is deliberately tested as at-least-once and reruns after resume. Resume input is supplied in the same fence. |
| F21 | Durable Mnesia workflow invocation | Erlang | Literal deterministic; Dedicated fixture | `readme_workflow_examples_test:graph_fork_join_and_pause_resume/0`; `adk_durable_workflow_test` | Uses local Mnesia. Coordinator, application, Mnesia, and worker recovery are covered by the dedicated suite; see `DURABLE_INVOCATIONS.md`. |
| F22 | Workflow checkpoint, cancellation, and resume | Erlang | Literal deterministic | `readme_workflow_examples_test:workflow_cancel_checkpoint_and_resume/0`; `adk_workflow_test` | The example owns its temporary worker processes and checkpoint. |
| F23 | Explicit planning and bounded replanning | Erlang | Literal deterministic | `readme_examples_test:explicit_planning_runtime/0` compiles the two example adapters; `adk_planning_runtime_test`; `erlang_adk_planning_test` | Planner and executor modules are trusted application code. |
| F24 | Legacy graph helper | Erlang | Literal deterministic | `readme_examples_test:bounded_graph_workflow/0`; `erlang_adk_orchestrator_test`; `adk_graph_node_test` for the adjacent event-node helpers | No provider, key, or network. |

## Runner, background work, and suspension

| ID | README fence | Language | Classification | Exact validation | Prerequisites and continuation notes |
| --- | --- | --- | --- | --- | --- |
| F25 | Event Runner configuration and synchronous run | Erlang | Deterministic equivalent; Live | `readme_examples_test:sync_and_async_runner/0`, `runner_provider_streaming/0`; `readme_live_gemini_SUITE:runner_sync_async/1`; `adk_runner_test`; `adk_context_policy_test`; `adk_context_envelope_test`; `adk_context_runner_test` | The deterministic path substitutes local providers but retains admission, complete-envelope budgeting, policy, context, streaming, and session contracts. |
| F26 | Admission-control `sys.config` fragment | Erlang | Companion syntax; Dedicated fixture | `adk_admission_control_test`; `adk_runtime_policy_test`; `adk_runner_safety_test`; `erlang_adk_startup_test` | This is application environment configuration and must be installed before startup. |
| F27 | Stable run subscription and terminal outcome | Erlang | Literal deterministic; Dedicated fixture | `readme_examples_test:supervised_run_api/0`; `adk_run_test:late_subscriber_receives_bounded_replay_case/0`, `terminal_is_emitted_exactly_once_case/0` | The push subscription is for a local process that continuously drains its mailbox. |
| F28 | Resume a stable paused run | Erlang | Conceptual continuation; Dedicated fixture | `adk_run_test:paused_run_resumes_as_new_supervised_run_case/0`; `adk_hitl_test`; `readme_live_gemini_SUITE:human_approval/1` | `PausedRunId` comes from F32 or another retained paused run. |
| F29 | Ambient trigger registration and submission | Erlang | Literal deterministic | `readme_examples_test:ambient_background_runtime/0`; `adk_ambient_test`; `adk_ambient_concurrency_SUITE` | The deterministic test uses a probe Runner; cloud delivery adapters remain application integrations. |
| F30 | Fixed-delay schedule trigger | Erlang | Literal deterministic | `readme_examples_test:ambient_background_runtime/0`; `adk_ambient_test` | The one-hour timer is started and stopped without waiting for a tick. |
| F31 | Lower-level Runner mailbox drain | Erlang | Deterministic equivalent; Live | `readme_examples_test:sync_and_async_runner/0`; `readme_live_gemini_SUITE:runner_sync_async/1`; `adk_runner_test` | `Runner` and `RunnerAgentPid` are established by F25. |
| F32 | Generic tool confirmation plus human-approval pause and correlated resume | Erlang | Literal deterministic; Live | `readme_examples_test:tool_confirmation_contract/0`; `adk_tool_confirmation_test`; `adk_direct_confirmation_test`; `adk_hitl_test:test_pause_and_resume_same_invocation/0`, `test_two_paused_invocations_are_independently_resumable/0`, `test_concurrent_resume_is_single_use/0`; `readme_live_gemini_SUITE:human_approval/1` | The checked `readme_release_tool` requires the exact `confirmed` boolean contract for production and bypasses it for dry runs. The older long-running approval tool has a distinct application response. Live execution needs F03 and may complete without a pause, which the example handles explicitly. |
| F33 | Generic long-running suspension constructor | Erlang | Literal deterministic | `readme_examples_test:suspension_and_pkce_contract/0`; `adk_suspension_test:long_running_progress_and_terminal_resume_case/0` | The constructor throws the documented suspension signal for Runner/tool handling. |
| F34 | Long-running progress update and terminal resume | Erlang | Conceptual continuation; Dedicated fixture | `adk_suspension_test:long_running_progress_and_terminal_resume_case/0`, `stable_run_rejects_invalid_completion_before_linking_case/0` | `PauseEvent` and `Runner` come from a prior paused operation; `export-42` must match that continuation. |

## Sessions, callbacks, content, and streaming

| ID | README fence | Language | Classification | Exact validation | Prerequisites and continuation notes |
| --- | --- | --- | --- | --- | --- |
| F35 | ETS session scopes and temp-state lifecycle | Erlang | Literal deterministic | `readme_examples_test:session_scopes_and_temp_state/0`; `adk_session_service_test`; `adk_state_scoping_test` | No provider, key, or network. Concurrent create/update behavior is covered by `adk_state_scoping_test`. |
| F36 | Mnesia-backed Runner | Erlang | Deterministic equivalent; Live | `erlang_adk_session_mnesia_test:test_runner_integration/0`; `readme_live_gemini_SUITE:mnesia_runner/1` | Requires writable local Mnesia storage; live execution also needs F03. |
| F37 | Configure Mnesia as the startup backend | Erlang | Dedicated fixture | `erlang_adk_startup_test:configured_mnesia_startup/1`; `erlang_adk_session_mnesia_test` | Must be set before application startup; the fixture supplies an isolated Mnesia directory. |
| F38 | Session query, HMAC cursor, pagination, and rewind | Erlang | Literal deterministic | `readme_examples_test:session_query_pagination_and_rewind/0`; `adk_session_query_test` | `QuerySecret` is generated for the example; production nodes need a shared secret from application secret storage. |
| F39 | `readme_audit_callback` module | Erlang | Literal deterministic | `readme_examples_test:example_modules_compile_and_load/0` compiles `examples/readme_audit_callback.erl`; `adk_callbacks_isolation_test` | The `persistent_term` observer is an example/test notification hook and must be cleared. Callback arguments are credential-free projections. |
| F40 | Attach callbacks to an agent | Erlang | Deterministic equivalent; Live | `readme_examples_test:callbacks_and_telemetry/0`; `readme_live_gemini_SUITE:callbacks_telemetry_and_eval/1`; `adk_callbacks_isolation_test` | Live execution needs F03. F39 must be compiled and its observer cleared after use. |
| F41 | Prompt telemetry handler | Erlang | Deterministic equivalent; Live | `readme_examples_test:callbacks_and_telemetry/0`; `readme_live_gemini_SUITE:callbacks_telemetry_and_eval/1`; `adk_observability_test` | Live execution needs F03. The handler ID is detached before and after use. |
| F42 | Multimodal one-shot content | Erlang | Deterministic equivalent; Live | `readme_examples_test:multimodal_content_contract/0`; `adk_content_test`; `adk_llm_gemini_test:test_multimodal_request/1`, `test_multimodal_response/1`; `readme_live_gemini_SUITE:multimodal_content/1` | Live execution needs F03. The deterministic fixture validates canonical encoding/decoding and limits. |
| F43 | Gemini canonical content stream | Erlang | Deterministic equivalent; Live | `adk_llm_gemini_test:test_stream_content/1`; `adk_streaming_test`; `readme_live_gemini_SUITE:multimodal_content/1` | `MultimodalPrompt` comes from F42. Live execution needs F03. |
| F44 | Runner content streaming and retained replay | Erlang | Deterministic equivalent; Live | `readme_examples_test:supervised_content_streaming/0`; `adk_streaming_test`; `readme_live_gemini_SUITE:multimodal_content/1` | `MultimodalPrompt` comes from F42. The deterministic provider emits canonical content frames. |
| F45 | Gemini UTF-8 text streaming | Erlang | Deterministic equivalent; Live | `readme_examples_test:deterministic_streaming/0`; `adk_llm_gemini_test:test_stream_text/1`, `test_stream_tool_call/1`; `readme_live_gemini_SUITE:streaming/1` | Live execution needs F03. |

## MCP, plugins, evaluation, storage, and HTTP protocols

| ID | README fence | Language | Classification | Exact validation | Prerequisites and continuation notes |
| --- | --- | --- | --- | --- | --- |
| F46 | MCP stdio client fixture | Erlang | Literal deterministic | `readme_examples_test:mcp_stdio_fixture/0`; `adk_mcp_test` | Requires the repository fixture `test/mcp_stdio_fixture.sh` to be executable. The HTTP session-loss retry rule does not apply to stdio transport. |
| F47 | MCP Streamable HTTP loopback server/client | Erlang | Literal deterministic; Dedicated fixture | `readme_examples_test:mcp_streamable_http_fixture/0`; `adk_mcp_test:streamable_http_does_not_replay_tool_after_session_loss_test_/0`; `adk_mcp_streamable_http_SUITE` | Uses loopback, an ephemeral port, and the placeholder token only inside the fixture. Read-like operations may retry after session replacement; `tools/call` and unknown/mutating requests return `{mcp_session_lost, request_not_replayed}` instead of being replayed. No public bind or TLS is attempted. |
| F48 | Runner plugin and observability exporter | Erlang | Deterministic equivalent | `readme_examples_test:plugins_observability_and_eval_sets/0`; `adk_plugin_pipeline_test`; `adk_plugin_runner_integration_test`; `adk_observability_test` | The example modules are compiled by `readme_examples_test:setup/0`; the deterministic path substitutes a probe provider. |
| F49 | Versioned multi-turn eval set | Erlang | Deterministic equivalent | `readme_examples_test:plugins_observability_and_eval_sets/0`; `adk_eval_set_test` | The literal provider is Gemini; the deterministic test uses the same adapter/metric contract with a probe agent. |
| F50 | Legacy lightweight evaluation | Erlang | Deterministic equivalent; Live | `readme_examples_test:lightweight_evaluation/0`; `adk_eval_test`; `readme_live_gemini_SUITE:callbacks_telemetry_and_eval/1` | Live execution needs F03. Rows share the supplied agent history by design. |
| F51 | Retry with bounded backoff | Erlang | Literal deterministic | `readme_examples_test:deterministic_retry/0`; `adk_retry_test` | No provider, key, or network. |
| F52 | Scoped ETS memory with Runner preload, ingestion, and model-selected search | Erlang | Deterministic equivalent; Live | `readme_examples_test:memory_and_artifacts/0`; `adk_memory_conformance_test`; `adk_memory_v2_ets_test`; `adk_context_runner_test:memory_v2_preload_is_exactly_scoped/0`, `model_selected_memory_load_is_exactly_scoped/0`; `adk_context_capability_test`; `adk_llm_gemini_test:test_json_schema_tool_payload/1`; `readme_live_gemini_SUITE:artifact_and_memory_tools/1` | The deterministic path substitutes a probe provider and proves the exact `{user, App, User}` scope for both preload and the built-in `adk_load_memory_tool`, including rejection of cross-user data. Its strict declaration uses Gemini `parametersJsonSchema`. The targeted live case passed on 2026-07-14 and needs F03; the full live suite remains separate. |
| F53 | Immutable paginated ETS artifacts | Erlang | Literal deterministic; Live | `readme_examples_test:memory_and_artifacts/0`; `adk_artifact_conformance_test`; `adk_artifact_ets_test`; `adk_context_capability_test`; `adk_context_runner_test:artifact_attachment_is_ephemeral_and_effect_is_durable/0`; `adk_llm_gemini_test:test_json_schema_tool_payload/1`; `readme_live_gemini_SUITE:artifact_and_memory_tools/1` | Conformance tests cover bounded `list_names` with exact scope provenance; hostile capability coverage rejects a valid-name page carrying a foreign scope. Runner coverage proves one-request model attachment, metadata-only effects, and absence of bytes from durable events. Its strict declaration uses Gemini `parametersJsonSchema`. The literal storage example needs no provider; the targeted live model-selection supplement passed on 2026-07-14 and needs F03. |
| F54 | Durable filesystem artifacts | Erlang | Literal deterministic | `readme_examples_test:memory_and_artifacts/0`; `adk_artifact_conformance_test`; `adk_artifact_fs_test:lifetime_version_capacity_fails_before_scan_exhaustion_test/0`, `lifetime_scope_and_name_capacity_preserve_bounded_listing_test/0` and the full module | Requires a writable temporary directory; the 15 focused tests remove isolated roots and cover publication, repair, corruption, deadline, pagination, multi-instance-safe scope/name/version lifetime admission before scan exhaustion, and the fact that deletion/restart does not restore allocation capacity. |
| F55 | A2A 1.0 Agent Card, server, and client | Erlang | Deterministic equivalent; Adapter-dependent | `adk_a2a_v1_codec_test`; `adk_a2a_v1_server_test`; `adk_a2a_v1_http_test`; `erlang_adk_startup_test:supervised_a2a_v1_is_discoverable/0` | The literal fence uses fixed port 8080 and Gemini. Fixtures use loopback/ephemeral ports and deterministic task work. |
| F56 | A2A OIDC authentication hook | Erlang | Conceptual continuation; Dedicated fixture | `adk_a2a_v1_http_test:version_and_auth_are_enforced_case/1`, `cross_principal_http_scope_case/1`; `adk_oidc_security_test` | `JwtPolicy` is produced by F67 or equivalent trusted application configuration. |
| F57 | Legacy `/a2a/prompt` endpoint | Erlang | Deterministic equivalent; Live | `erlang_adk_tests`; `erlang_adk_startup_test:supervised_http_is_bounded/0`; `readme_live_gemini_SUITE:http_endpoint/1` | Live execution needs F03. Tests use loopback and isolated ports. |

## Integrated developer tooling, authentication, and Phoenix

| ID | README fence | Language | Classification | Exact validation | Prerequisites and continuation notes |
| --- | --- | --- | --- | --- | --- |
| F58 | Export the developer bearer token | Bash | Companion syntax | `adk_dev_http_test:auth_case/1`; `adk_cli_test:doctor_redacts_environment_case/0`; `erlang_adk_startup_test:supervised_dev_listener_is_authenticated/0` validate consumption and redaction. | Must be exported before startup or `adk serve`; use a dedicated local token of at least 16 bytes. |
| F59 | Configure and bound the developer listener | Erlang | Dedicated fixture | `adk_dev_http_test:sse_config_validation_case/0`; `adk_dev_v05_http_test:provider_config_case/0`; `erlang_adk_startup_test:supervised_dev_listener_is_authenticated/0`; `adk_runtime_policy_test` | Listener and diagnostic/resource configuration is read at startup. This fence intentionally does not start the application; resource-enabled startup occurs only after F60/F61. The startup fixture proves the final environment reaches the supervised loopback listener. |
| F60 | Exact-scope developer resource-provider module | Erlang | Deterministic equivalent; Adapter-dependent | `adk_dev_v05_resource_provider`; `adk_dev_v05_http_test:provider_config_case/0`, `artifact_case/1`, `memory_case/1`, `resource_scope_mismatch_fails_closed/1`; `erlang_adk_startup_test:supervised_dev_listener_is_authenticated/0` | `my_dev_resource_provider` is an application-owned module; the checked fixture implements the same `resolve/3` contract. The HTTP projection rejects artifact name pages, artifact versions, or memory hits whose embedded scope differs from the requested path. |
| F61 | Start fresh developer resources/cache, configure exact scopes, then start the application | Erlang | Deterministic equivalent; Dedicated fixture; Adapter-dependent | `adk_dev_v05_http_test:context_lifecycle_case/1`; `adk_context_cache_test`; `erlang_adk_startup_test:supervised_dev_listener_is_authenticated/0` | Requires the application-owned F60 module. The fence deliberately creates new local services because F52/F53 stopped theirs, adds private Runner cache configuration, then seeds data/session only after startup. Production services should be supervised by the owning application. Configuration precedes listener startup; handles never enter HTTP diagnostics. |
| F62 | Checked CLI agent JSON | JSON | Literal deterministic | `adk_cli_test:checked_repository_examples_case/0`, `checked_config_validation_case/0`, `config_rejects_embedded_secret_case/0` validate the checked-in `examples/agent.json`; the release gate builds the same file into the CLI workflow. | Model execution needs F03; local schema and secret validation do not. `examples/eval.json` supplies the companion evaluation dataset. |
| F63 | Build the `adk` CLI and run local commands | Bash | Deterministic equivalent; Live | `adk_cli_test:checked_repository_examples_case/0`, `doctor_redacts_environment_case/0`, `checked_config_validation_case/0`, `deterministic_run_case/0`, `deterministic_console_case/0`, `deterministic_evaluation_case/0`; `./rebar3 escriptize` in the release gate | `examples/agent.json` and `examples/eval.json` are checked in. Gemini-backed `run`, `console`, and `evaluate` need F03; `console` remains interactive until `/exit` or EOF. |
| F64 | Start the blocking developer server | Bash | Deterministic equivalent; Dedicated fixture | `adk_cli_test:successful_developer_commands_case/0`; `erlang_adk_startup_test:supervised_dev_listener_is_authenticated/0`; packaged-escript loopback smoke test | Requires F58 and a free loopback port. The literal command uses the Gemini agent in F62; the fixture substitutes a deterministic provider. Leave this process running for the agent/run/session subset of F65. |
| F65 | Inspect runs, sessions, context/lifecycle, artifacts, and memory through a developer server | Bash | Deterministic equivalent; Conceptual continuation | `adk_cli_test:successful_developer_commands_case/0`, `developer_connection_failure_is_structured_case/0`; `adk_dev_http_test`; `adk_dev_v05_http_test:diagnostics_and_context_case/1`, `context_lifecycle_case/1`, `artifact_case/1`, `memory_case/1`, `cli_case/1`; packaged `adk inspect agents` smoke test | Agent/run/session commands can target F64. Commands after the in-fence comment target the resource/cache-enabled F59-F61 VM; plain `adk serve` cannot manufacture storage/cache PIDs. Lifecycle output is content-free. A refused connection returns bounded `developer_api_unavailable` JSON. `RUN_ID` must belong to the retained server being queried. |
| F66 | Confirmed artifact deletion, scoped memory erasure, and cache-scope invalidation | Bash | Deterministic equivalent; Conceptual continuation | `adk_dev_v05_http_test:artifact_case/1`, `memory_case/1`, `context_lifecycle_case/1`, `cli_case/1`; `adk_context_cache_test` | Target the resource/cache-enabled F59-F61 VM, not plain F64. Tests reject non-exact confirmations and omit content/metadata/handles. The session anchors cache authorization/confirmation, while invalidation deliberately removes the exact configured provider/app/user/model/policy scope across sessions, prefixes, and TTLs. |
| F67 | OIDC provider and inbound JWT policy | Erlang | Adapter-dependent; Dedicated fixture | `adk_oidc_security_test:real_oidcc_verifies_signed_offline_fixture/0`, `valid_token_returns_issuer_bound_principal/0`, `provider_child_is_explicit_and_secret_free/0`; `erlang_adk_startup_test:invalid_oidc_clock_skew_fails_startup/0` | `identity.example.com` and `RequestHeaders` are application placeholders. Production discovery/JWKS requires a real HTTPS issuer. |
| F68 | Outbound OAuth client credentials and token manager | Erlang | Adapter-dependent; Dedicated fixture | `adk_auth_test:concurrent_refresh_is_single_flight/1`, `credentials_are_isolated_by_principal/1`, `secrets_and_tokens_are_not_in_server_state/1`; `adk_oidc_security_test:client_credentials_grant_is_normalized/0`; `adk_auth_rotation_test` | Requires environment credentials, a principal from F67, and a configured provider worker. Tests use offline/fake providers and seeded secrets. |
| F69 | Prepare an S256 PKCE flow | Erlang | Literal deterministic | `readme_examples_test:suspension_and_pkce_contract/0`; `adk_suspension_test:interactive_auth_pkce_and_opaque_resume_case/0` | Uses the private credential store; `Principal` comes from authenticated application context. |
| F70 | Complete a PKCE flow | Erlang | Conceptual continuation; Dedicated fixture | `readme_examples_test:suspension_and_pkce_contract/0`; `adk_suspension_test:interactive_auth_pkce_and_opaque_resume_case/0`, `expired_or_malformed_pkce_flow_fails_closed_case/0`; `adk_auth_rotation_test` | `FlowRef` and `CorrelationId` come from F69; `CalendarClientId` and `ProviderRefreshToken` come from the validated HTTPS callback/code exchange. |
| F71 | Scaffold a Phoenix LiveView companion | Bash | Companion syntax | Manually reviewed; this repository has no Mix/Elixir compile gate. | Requires Elixir, Mix, and network access to create the sibling application. Do not create it inside this Erlang library. |
| F72 | Phoenix/Mix dependency declaration | Elixir | Companion syntax | Manually reviewed against `rebar.config` and the public Erlang modules; not compiled by this repository. | Requires the F71 companion, Phoenix, LiveView, and optionally `oidcc_plug`. Keep its lock file current. |
| F73 | Fetch, compile, and start the Phoenix companion | Bash | Companion syntax | Must be run in the companion project; the Erlang repository cannot validate this toolchain. | `mix compile --warnings-as-errors` is the companion syntax gate. `iex -S mix phx.server` stays running for F74/F75. |
| F74 | Register `PhoenixAgent` in the companion IEx shell | Elixir | Companion syntax; Live | Public spawn/config validation is covered by `adk_agent_behavior_test` and `adk_llm_gemini_test`; the Elixir syntax is manually reviewed. | Requires F03, F72/F73, and Gemini quota for real model calls. Start only one registered agent with this name. |
| F75 | Phoenix LiveView stable-run integration | Elixir | Companion syntax; Conceptual continuation | Public API behavior is covered by `adk_run_test`, `adk_agent_behavior_test`, `adk_sub_agents_test`, `adk_event_test`, `adk_admission_control_test`, `adk_runtime_policy_test`, and `adk_dev_http_test:ui_uses_typed_confirmation_payload_case/1`; the Elixir module is not compiled here. | Requires F74 and an authenticated server-side UTF-8 binary `user_id`. Credit/ack, replay gaps, bounded UI history, run correlation, and pause-specific resume must stay aligned with those tests. Unknown pause types fail closed. |

## Verification commands

| ID | README fence | Language | Classification | Exact validation | Prerequisites and continuation notes |
| --- | --- | --- | --- | --- | --- |
| F76 | Complete deterministic release and packaging gates | Bash | Literal deterministic | `./rebar3 do clean, compile, eunit, ct, dialyzer`; `./rebar3 escriptize`; `adk doctor`; checked agent-config validation. F63 covers the CLI-specific assertions. | Passed on 2026-07-14 with the final totals recorded above. No live provider flag is required. |
| F77 | Focused README and 1,000-run stress gates | Bash | Literal deterministic | `readme_examples_test`; `readme_workflow_examples_test`; `adk_concurrency_stress_SUITE` | Run from the repository root. The current focused README result is 29 tests, 0 failures; workflow/stress remain part of the final gate. |
| F78 | Opt-in live Gemini suite | Bash | Live | `readme_live_gemini_SUITE`, including `context_cache/1` and `artifact_and_memory_tools/1` | Requires F03 and `ERLANG_ADK_LIVE_GEMINI=1` in the same shell, network access, quota, and billable API permission. On 2026-07-14, 14 cases passed and two failed with no skips. The exact-scope data/schema case passed; Search grounding and context-cache create each failed with HTTP 429 after one retry and are not counted as passes. |
| F79 | Live Gemini suite without request pacing | Bash | Live | `readme_live_gemini_SUITE`; pacing is parsed by `request_interval_ms/0` | Intended only for projects whose quota supports unpaced requests. Keep the default interval on constrained projects. |

## Cross-cutting behavior claims

Some material README claims span several fences. These tests keep those claims
auditable without pretending that one shell snippet proves a concurrency,
security, or restart invariant.

| Behavior claim | Exact validation |
| --- | --- |
| Direct turns retain a stateful FIFO while fresh invocations serialize only within an exact app/user/session lane; different ready lanes are admitted fairly up to the configured bound; stop, caller death, timeout, and worker crash reap work | `adk_agent_mailbox_test`; `adk_agent_behavior_test`; `adk_concurrency_stress_SUITE` |
| Agent trees have strict model-visible names, one owner per child, tree-wide uniqueness, cycle/node/depth/walk bounds, and a private delegation path through configured or dynamically resolved local module tools; delegated calls use fresh history, caller-scoped state service, and allowlisted child scope | `adk_agent_tree_test`; `adk_sub_agents_test`; `adk_agent_mailbox_test`; `adk_agent_runtime_spec_test:invocation_output_key_uses_caller_session_scope/0`; `adk_global_instruction_test` |
| Agent supervisor reports and runtime status do not expose explicit provider credentials | `adk_agent_mailbox_test:supervisor_and_status_never_expose_agent_secret/0`; `adk_auth_test`; `adk_oidc_security_test` |
| Invocation and workflow dynamic child specifications contain only opaque launch references; one-shot handoff, diagnostics, failures, checkpoints, and persisted terminal records do not expose seeded request/state/ledger secrets | `adk_invocation_security_test`; `adk_workflow_failure_security_test` |
| Compiled immutable tool catalogs reject malformed/duplicate schemas with source diagnostics, validate complete model calls and arguments before resolution side effects, fail closed on dynamic removal, and require replacement rather than live mutation after refresh; Gemini keeps only a positive legacy subset in `parameters` and uses `parametersJsonSchema` for `oneOf`, `additionalProperties`, type unions, nested or top-level boolean schemas, and unknown keywords | `adk_toolset_test`; `adk_tool_call_test`; `adk_runner_tools_test`; `adk_code_toolset_test`; `adk_llm_gemini_test:test_json_schema_tool_payload/1` |
| Bounded supervised tasks and serial/parallel tool execution | `adk_task_test`; `adk_runner_tools_test`; `adk_toolset_test`; `adk_code_toolset_test` |
| Generic Runner/stable-run confirmation is evaluated after schema/policy and before lifecycle callbacks/execution, acts as a parallel barrier, preserves invalid continuations, freshly re-resolves on approval, executes once, and rejects without side effects; resolved local modules cannot weaken it, restoration failures are surfaced, developer UI payloads are pause-type aware, and non-Runner `prompt`/fresh `invoke`/delegation/AgentTool plus typed-workflow calls fail closed | `adk_tool_confirmation_test`; `adk_direct_confirmation_test`; `adk_runner_continuation_restore_test`; `adk_workflow_graph_test:confirmation_required_workflow_tool_fails_closed/0`; `adk_dev_http_test:ui_uses_typed_confirmation_payload_case/1`; `adk_toolset_test:resolved_confirmation_metadata_is_internal_and_validated/0` |
| Sub-agent replacement is resolved by stable registered name | `adk_sub_agents_test:test_restarted_sub_agent_is_resolved_by_name/0` |
| Event graph agent/function/tool helpers include instructions and callback lifecycle | `adk_graph_node_test` |
| Declared local tools receive only owner/scope/deadline-bound state, artifact, and memory capabilities; effects are drained into correlated event metadata; remote tools receive no local handle | `adk_context_capability_test`; `adk_context_runner_test`; `adk_toolset_test`; `adk_context_capability_tool` fixture |
| Artifact scopes, immutable versions, scope-provenance name pages, pagination, quotas, deadline fencing, filesystem publication/repair, multi-instance-safe scope/name/version lifetime admission before scan exhaustion, exact-scope sharded overlap with same-scope ordering, killed-caller cold-route cleanup, ephemeral model attachment, and metadata-only effects remain bounded and isolated | `adk_artifact_conformance_test`; `adk_artifact_ets_test`; `adk_artifact_fs_test:lifetime_version_capacity_fails_before_scan_exhaustion_test/0`, `lifetime_scope_and_name_capacity_preserve_bounded_listing_test/0` and the full module; `adk_scope_sharded_test:killed_cold_route_caller_releases_admission_test/0` and the full module; `adk_context_capability_test`; `adk_context_runner_test:artifact_attachment_is_ephemeral_and_effect_is_durable/0`; targeted live gate `readme_live_gemini_SUITE:artifact_and_memory_tools/1` passed on 2026-07-14 |
| Memory v2 requires exact app/user authority, deterministic idempotent ingestion, bounded preload and model-selected retrieval, durable local Mnesia, exact-user sharded overlap with same-scope ordering and killed-caller cold-route cleanup, scoped erase, and fail-closed durable-outbox admission with bounded resolution plus pre-mutation ownership renewal/revalidation; delivery is lease-owned idempotent at-least-once, not adapter-generation fenced | `adk_memory_conformance_test`; `adk_memory_v2_ets_test`; `adk_memory_mnesia_test`; `adk_scope_sharded_test:killed_cold_route_caller_releases_admission_test/0` and the full module; `adk_memory_outbox_test:processor_bounds_and_cancels_resolver/1`, `ownership_loss_prevents_adapter_mutation/1` and the full module; `adk_context_runner_test:memory_v2_preload_is_exactly_scoped/0`, `model_selected_memory_load_is_exactly_scoped/0`; targeted live gate `readme_live_gemini_SUITE:artifact_and_memory_tools/1` passed on 2026-07-14 |
| Context filtering preserves complete exchanges; canonicalization and secret pruning are mandatory; event and complete-envelope byte/token budgets fail before provider I/O; compression and automatic compaction are owner/deadline bounded and commit only an expected session prefix | `adk_context_policy_test`; `adk_context_envelope_test`; `adk_context_compaction_test`; `adk_context_runner_test`; `adk_runner_safety_test`; `adk_session_service_test`; `erlang_adk_session_mnesia_test`; `readme_examples_test:agent_contracts_and_context_policy/0` |
| Provider-prefix caching is not response caching: keys include app/user/model/policy/prefix/TTL, misses are single-flight, leases/resource names stay private, every waiter deadline is rechecked before installation, an all-expired result is deleted as an orphan, Gemini sends `cachedContent` plus only final content on hit, and bypass sends the original request | `adk_context_cache_test:queued_provider_result_cannot_beat_caller_deadline/0` and the full module; `adk_context_cache_gemini_test`; `adk_llm_gemini_test`; live `readme_live_gemini_SUITE:context_cache/1` failed with HTTP 429 after one bounded retry on 2026-07-14 and is not counted as passed. |
| ETS/Mnesia scoped state, concurrent create/update, and independent-session locking | `adk_state_scoping_test`; `adk_session_service_test`; `erlang_adk_session_mnesia_test` |
| Public callback/plugin/tool/provider/workflow failures are bounded structural values and seeded secrets do not enter callbacks, model responses, logs, status, checkpoints, task outcomes, or durable failure records | `adk_callbacks_isolation_test`; `adk_llm_test`; `adk_plugin_pipeline_test`; `adk_auth_test`; `adk_agent_mailbox_test`; `adk_task_test`; `adk_failure_security_test`; `adk_workflow_failure_security_test` |
| Stable run credit delivery permits one unacknowledged message and reports a post-subscription buffer overrun | `adk_run_test:credit_subscriber_is_bounded_and_detects_gap_case/0`; `adk_run_test:credit_subscriber_runtime_buffer_overrun_case/0` |
| Developer SSE closes at event, encoded-byte, and duration bounds without cancelling the retained run | `adk_dev_http_test:sse_replay_case/1`; `adk_dev_http_test:sse_byte_limit_closes_without_cancelling_case/1`; `adk_dev_http_test:sse_duration_limit_closes_without_cancelling_case/1`; `adk_dev_http_test:sse_detach_case/1` |
| Developer startup is authenticated, loopback-bound, bounded, and keeps only the bearer-token digest in route state; exact-scope resource resolution and context lifecycle expose only whitelisted metadata/counts without handles, artifact bytes, private metadata, events, summaries, policies, cache leases/resources, session content, or state; artifact name pages, artifact versions, and memory hits with a mismatched embedded scope fail closed; destructive cache invalidation requires the exact current scope fingerprint | `erlang_adk_startup_test:supervised_dev_listener_is_authenticated/0`; `adk_dev_http_test:auth_case/1`, `sse_config_validation_case/0`; `adk_dev_v05_http_test:context_lifecycle_case/1`, `resource_scope_mismatch_fails_closed/1`, `cli_case/1`; `adk_context_cache_test` |
| Durable workflow recovery and Mnesia HITL recovery preserve committed boundaries and continuation correlation | `adk_durable_workflow_test`; `adk_hitl_mnesia_restart_test`; `readme_workflow_examples_test:graph_fork_join_and_pause_resume/0` |
| Workflow output continues through successor input, explicit stop and legacy complete terminate, fork/parallel outputs are deterministic maps, loop bounds complete normally, and nested child resume avoids replay in sequential/graph/fork paths | `adk_workflow_test`; `adk_workflow_graph_test`; `readme_workflow_examples_test` |
| Typed workflow agent dispatch resolves the current supervised process by registered name and fails closed if its runtime canonical identity does not match the compiled name | `adk_workflow_graph_test:workflow_agent_registry_alias_mismatch_fails_closed/0` |
| Durable lease expiry is a write fence, a live local PID does not extend it, concurrent takeover has one winner, and the old token is stale after claim/restart | `adk_durable_workflow_test:expired_owner_cannot_write_without_takeover/1`, `expired_live_local_owner_is_claimable/1`, `concurrent_expiry_claim_has_single_winner/1`, `ledger_restart_preserves_expiry_fence/1` |

## Commands

The complete deterministic gate is:

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
```

The packaging gate is:

```bash
./rebar3 escriptize
_build/default/bin/adk doctor
_build/default/bin/adk config validate examples/agent.json
```

The focused README and concurrency gates are:

```bash
./rebar3 eunit --module=readme_examples_test
./rebar3 eunit --module=readme_workflow_examples_test
./rebar3 ct --suite test/adk_concurrency_stress_SUITE.erl
./rebar3 ct --suite test/adk_v05_stress_SUITE.erl
```

The focused 0.5 resource and data/context gates used for the evidence above
are:

```bash
./rebar3 eunit --module=adk_dev_v05_http_test
./rebar3 eunit --module=adk_scope_sharded_test
./rebar3 eunit \
  --module=adk_artifact_conformance_test,adk_artifact_ets_test,adk_artifact_fs_test,adk_scope_sharded_test,adk_memory_conformance_test,adk_memory_v2_ets_test,adk_memory_mnesia_test,adk_memory_outbox_test,adk_context_policy_test,adk_context_envelope_test,adk_context_capability_test,adk_context_compaction_test,adk_context_runner_test,adk_context_cache_test,adk_context_cache_gemini_test
```

The real-provider gate is deliberately opt-in and must run in the shell that
contains `GEMINI_API_KEY`:

```bash
ERLANG_ADK_LIVE_GEMINI=1 ./rebar3 ct \
  --suite test/readme_live_gemini_SUITE.erl
```

The live result supplements rather than replaces deterministic HTTP/SSE,
failure, cancellation, correlation, security, and persistence fixtures.
