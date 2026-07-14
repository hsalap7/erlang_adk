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

## Installation and provider examples

| ID | README fence | Language | Classification | Exact validation | Prerequisites and continuation notes |
| --- | --- | --- | --- | --- | --- |
| F01 | Installation: Git dependency declaration | Erlang | Companion syntax | The project itself is compiled by the complete Rebar3 gate; no separate consumer project is created. | Requires Git/network access and the `version_0.3.0` branch. The literal `deps` term belongs in a consumer `rebar.config`. |
| F02 | Installation: start the application | Erlang | Literal deterministic | `readme_examples_test:setup/0`; `erlang_adk_startup_test` | The application must be compiled first. |
| F03 | Installation: export `GEMINI_API_KEY` | Bash | Live | `readme_live_gemini_SUITE:init_per_suite/1` verifies that the opt-in flag and key reach the test process. | Must run in the same shell as F72/F73. The key is never supplied to deterministic tests. |
| F04 | Quickstart: weather tool and direct agent | Erlang | Deterministic equivalent; Live | `readme_examples_test:example_modules_compile_and_load/0`, `direct_agent_and_provider_error/0`; `readme_live_gemini_SUITE:weather_tool_round_trip/1` | Live execution needs F03, network access, and quota. The deterministic path substitutes `adk_llm_probe`. |
| F05 | Quickstart: provider capabilities and config validation | Erlang | Literal deterministic | `readme_examples_test:provider_capability_contract/0`; `adk_llm_test`; `adk_llm_gemini_test:test_strict_config/1` | No API key or network. |
| F06 | Google Search grounding request | Erlang | Deterministic equivalent; Live | `adk_llm_gemini_test:test_google_search_grounding/1`, `test_grounded_tool_call_event/1`; `readme_live_gemini_SUITE:google_search_grounding/1` | Live Search use is model-selected and needs F03. The deterministic fixture proves request shape and metadata decoding. |
| F07 | Grounding provider-metadata event projection | Erlang | Dedicated fixture | `adk_provider_result_test`; `adk_llm_gemini_test:test_grounding_event_persistence/1`, `test_stream_grounding_agent_event/1` | This is a projected map fragment, not a standalone shell expression with locally bound `GroundingMetadata`. |
| F08 | Gemini thinking configuration | Erlang | Deterministic equivalent; Live | `adk_llm_gemini_test:test_thinking_payload/1`, `test_thought_summary_response/1`, `test_stream_thought_summary/1`; `readme_live_gemini_SUITE:thinking_configuration/1` | Live execution needs F03. |
| F09 | Gemini safety settings | Erlang | Literal deterministic; Dedicated fixture | `readme_examples_test:provider_capability_contract/0`; `adk_llm_gemini_test:test_safety_payload/1` | Validation is local; no API key or network. |

## Agents, tools, and orchestration

| ID | README fence | Language | Classification | Exact validation | Prerequisites and continuation notes |
| --- | --- | --- | --- | --- | --- |
| F10 | Agent contracts, scoped instructions, schema, and `output_key` | Erlang | Deterministic equivalent | `readme_examples_test:agent_contracts_and_context_policy/0`; `adk_agent_spec_test`; `adk_agent_runtime_spec_test`; `adk_global_instruction_test` | The deterministic test substitutes `adk_llm_agent_spec_probe` while preserving the public Runner/session API. |
| F11 | `readme_weather_tool` module | Erlang | Literal deterministic | `readme_examples_test:example_modules_compile_and_load/0` compiles `examples/readme_weather_tool.erl`; `adk_runner_tools_test` | The fence is a module body and is compiled as the repository example file, not pasted into the shell. |
| F12 | External-sandbox code toolset | Erlang | Adapter-dependent; Dedicated fixture | `adk_code_toolset_test:compile_and_schema_test/0`, `resolved_call_is_bounded_and_context_is_minimal_test/0`, `request_policy_rejects_unsafe_or_oversized_values_test/0` | `my_sandbox_adapter` and `SandboxHandle` are application-owned placeholders. No in-process executor is provided by Erlang ADK. |
| F13 | OpenAPI Petstore toolset and agent | Erlang | Deterministic equivalent; Adapter-dependent | `readme_examples_test:openapi_toolset_as_agent_tools/0`; `adk_openapi_toolset_test`; `adk_openapi_production_adapters_test` | The literal example contacts Petstore and Gemini. Tests use the same checked schema with local fake/Gun transports and out-of-band auth. |
| F14 | Correlated asynchronous delegation | Erlang | Deterministic equivalent; Live | `readme_examples_test:correlated_async_delegation/0`; `readme_live_gemini_SUITE:async_delegation/1` | Live execution needs F03. |
| F15 | Sequential and parallel multi-agent execution | Erlang | Deterministic equivalent; Live | `readme_examples_test:sequential_parallel_and_loop/0`; `readme_live_gemini_SUITE:concurrent_orchestration/1`; `adk_concurrency_stress_SUITE` | Live execution needs F03. Stress coverage validates isolation and cleanup at larger scale. |
| F16 | Bounded writer/reviewer loop | Erlang | Deterministic equivalent; Live | `readme_examples_test:sequential_parallel_and_loop/0`; `readme_live_gemini_SUITE:concurrent_orchestration/1`; `erlang_adk_orchestrator_test` | Live natural-language review is nondeterministic; the deterministic reviewer returns exact `APPROVED`. |
| F17 | Sub-agent and agent-as-tool | Erlang | Deterministic equivalent; Live | `readme_examples_test:sub_agent_and_agent_as_tool/0`; `readme_live_gemini_SUITE:sub_agent_and_agent_tool/1`; `adk_sub_agents_test` | `adk_sub_agents_test:test_restarted_sub_agent_is_resolved_by_name/0` covers the adjacent restart-by-name claim. |
| F18 | Sequential and bounded-parallel declarative workflows | Erlang | Literal deterministic | `readme_workflow_examples_test:sequential_and_parallel_workflows/0`; `adk_workflow_test` | No provider, key, or network. |
| F19 | Loop, transfer, and dynamically routed graph workflows | Erlang | Literal deterministic | `readme_workflow_examples_test:loop_transfer_and_graph_workflows/0`; `adk_workflow_test`; `adk_workflow_graph_test` | No provider, key, or network. |
| F20 | Graph fork/join and pause/resume | Erlang | Literal deterministic | `readme_workflow_examples_test:graph_fork_join_and_pause_resume/0`; `adk_workflow_graph_test` | Resume input is supplied in the same fence. |
| F21 | Durable Mnesia workflow invocation | Erlang | Literal deterministic; Dedicated fixture | `readme_workflow_examples_test:graph_fork_join_and_pause_resume/0`; `adk_durable_workflow_test` | Uses local Mnesia. Coordinator, application, Mnesia, and worker recovery are covered by the dedicated suite; see `DURABLE_INVOCATIONS.md`. |
| F22 | Workflow checkpoint, cancellation, and resume | Erlang | Literal deterministic | `readme_workflow_examples_test:workflow_cancel_checkpoint_and_resume/0`; `adk_workflow_test` | The example owns its temporary worker processes and checkpoint. |
| F23 | Explicit planning and bounded replanning | Erlang | Literal deterministic | `readme_examples_test:explicit_planning_runtime/0` compiles the two example adapters; `adk_planning_runtime_test`; `erlang_adk_planning_test` | Planner and executor modules are trusted application code. |
| F24 | Legacy graph helper | Erlang | Literal deterministic | `readme_examples_test:bounded_graph_workflow/0`; `erlang_adk_orchestrator_test`; `adk_graph_node_test` for the adjacent event-node helpers | No provider, key, or network. |

## Runner, background work, and suspension

| ID | README fence | Language | Classification | Exact validation | Prerequisites and continuation notes |
| --- | --- | --- | --- | --- | --- |
| F25 | Event Runner configuration and synchronous run | Erlang | Deterministic equivalent; Live | `readme_examples_test:sync_and_async_runner/0`, `runner_provider_streaming/0`; `readme_live_gemini_SUITE:runner_sync_async/1`; `adk_runner_test`; `adk_context_policy_test` | The deterministic path substitutes local providers but retains admission, policy, context, streaming, and session contracts. |
| F26 | Admission-control `sys.config` fragment | Erlang | Companion syntax; Dedicated fixture | `adk_admission_control_test`; `adk_runtime_policy_test`; `adk_runner_safety_test`; `erlang_adk_startup_test` | This is application environment configuration and must be installed before startup. |
| F27 | Stable run subscription and terminal outcome | Erlang | Literal deterministic; Dedicated fixture | `readme_examples_test:supervised_run_api/0`; `adk_run_test:late_subscriber_receives_bounded_replay_case/0`, `terminal_is_emitted_exactly_once_case/0` | The push subscription is for a local process that continuously drains its mailbox. |
| F28 | Resume a stable paused run | Erlang | Conceptual continuation; Dedicated fixture | `adk_run_test:paused_run_resumes_as_new_supervised_run_case/0`; `adk_hitl_test`; `readme_live_gemini_SUITE:human_approval/1` | `PausedRunId` comes from F32 or another retained paused run. |
| F29 | Ambient trigger registration and submission | Erlang | Literal deterministic | `readme_examples_test:ambient_background_runtime/0`; `adk_ambient_test`; `adk_ambient_concurrency_SUITE` | The deterministic test uses a probe Runner; cloud delivery adapters remain application integrations. |
| F30 | Fixed-delay schedule trigger | Erlang | Literal deterministic | `readme_examples_test:ambient_background_runtime/0`; `adk_ambient_test` | The one-hour timer is started and stopped without waiting for a tick. |
| F31 | Lower-level Runner mailbox drain | Erlang | Deterministic equivalent; Live | `readme_examples_test:sync_and_async_runner/0`; `readme_live_gemini_SUITE:runner_sync_async/1`; `adk_runner_test` | `Runner` and `RunnerAgentPid` are established by F25. |
| F32 | Human-approval pause and correlated resume | Erlang | Deterministic equivalent; Live | `adk_hitl_test:test_pause_and_resume_same_invocation/0`, `test_two_paused_invocations_are_independently_resumable/0`, `test_concurrent_resume_is_single_use/0`; `readme_live_gemini_SUITE:human_approval/1` | Live execution needs F03 and may complete without a pause, which the example handles explicitly. |
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
| F46 | MCP stdio client fixture | Erlang | Literal deterministic | `readme_examples_test:mcp_stdio_fixture/0`; `adk_mcp_test` | Requires the repository fixture `test/mcp_stdio_fixture.sh` to be executable. |
| F47 | MCP Streamable HTTP loopback server/client | Erlang | Literal deterministic; Dedicated fixture | `readme_examples_test:mcp_streamable_http_fixture/0`; `adk_mcp_streamable_http_SUITE` | Uses loopback, an ephemeral port, and the placeholder token only inside the fixture. No public bind or TLS is attempted. |
| F48 | Runner plugin and observability exporter | Erlang | Deterministic equivalent | `readme_examples_test:plugins_observability_and_eval_sets/0`; `adk_plugin_pipeline_test`; `adk_plugin_runner_integration_test`; `adk_observability_test` | The example modules are compiled by `readme_examples_test:setup/0`; the deterministic path substitutes a probe provider. |
| F49 | Versioned multi-turn eval set | Erlang | Deterministic equivalent | `readme_examples_test:plugins_observability_and_eval_sets/0`; `adk_eval_set_test` | The literal provider is Gemini; the deterministic test uses the same adapter/metric contract with a probe agent. |
| F50 | Legacy lightweight evaluation | Erlang | Deterministic equivalent; Live | `readme_examples_test:lightweight_evaluation/0`; `adk_eval_test`; `readme_live_gemini_SUITE:callbacks_telemetry_and_eval/1` | Live execution needs F03. Rows share the supplied agent history by design. |
| F51 | Retry with bounded backoff | Erlang | Literal deterministic | `readme_examples_test:deterministic_retry/0`; `adk_retry_test` | No provider, key, or network. |
| F52 | ETS memory with Runner retrieval/ingestion | Erlang | Deterministic equivalent | `readme_examples_test:memory_and_artifacts/0`; `adk_memory_ets_test`; `adk_runner_services_test` | The deterministic path substitutes a probe provider; the literal Gemini call needs F03. |
| F53 | Immutable ETS artifacts | Erlang | Literal deterministic | `readme_examples_test:memory_and_artifacts/0`; `adk_artifact_ets_test`; `adk_runner_services_test` | No provider, key, or network. |
| F54 | Durable filesystem artifacts | Erlang | Literal deterministic | `readme_examples_test:memory_and_artifacts/0`; `adk_artifact_fs_test` | Requires a writable temporary directory; the test removes its isolated root. |
| F55 | A2A 1.0 Agent Card, server, and client | Erlang | Deterministic equivalent; Adapter-dependent | `adk_a2a_v1_codec_test`; `adk_a2a_v1_server_test`; `adk_a2a_v1_http_test`; `erlang_adk_startup_test:supervised_a2a_v1_is_discoverable/0` | The literal fence uses fixed port 8080 and Gemini. Fixtures use loopback/ephemeral ports and deterministic task work. |
| F56 | A2A OIDC authentication hook | Erlang | Conceptual continuation; Dedicated fixture | `adk_a2a_v1_http_test:version_and_auth_are_enforced_case/1`, `cross_principal_http_scope_case/1`; `adk_oidc_security_test` | `JwtPolicy` is produced by F64 or equivalent trusted application configuration. |
| F57 | Legacy `/a2a/prompt` endpoint | Erlang | Deterministic equivalent; Live | `erlang_adk_tests`; `erlang_adk_startup_test:supervised_http_is_bounded/0`; `readme_live_gemini_SUITE:http_endpoint/1` | Live execution needs F03. Tests use loopback and isolated ports. |

## Integrated developer tooling, authentication, and Phoenix

| ID | README fence | Language | Classification | Exact validation | Prerequisites and continuation notes |
| --- | --- | --- | --- | --- | --- |
| F58 | Export the developer bearer token | Bash | Companion syntax | `adk_dev_http_test:auth_case/1`; `adk_cli_test:doctor_redacts_environment_case/0`; `erlang_adk_startup_test:supervised_dev_listener_is_authenticated/0` validate consumption and redaction. | Must be exported before startup or `adk serve`; use a dedicated local token of at least 16 bytes. |
| F59 | Enable and bound the developer listener | Erlang | Dedicated fixture | `adk_dev_http_test:sse_config_validation_case/0`; `erlang_adk_startup_test:supervised_dev_listener_is_authenticated/0`; `adk_runtime_policy_test` | Listener configuration is read at startup. Tests use loopback and an ephemeral port. |
| F60 | Checked CLI agent JSON | JSON | Literal deterministic | `adk_cli_test:checked_repository_examples_case/0`, `checked_config_validation_case/0`, `config_rejects_embedded_secret_case/0` validate the checked-in `examples/agent.json`; the release gate builds the same file into the CLI workflow. | Model execution needs F03; local schema and secret validation do not. `examples/eval.json` supplies the companion evaluation dataset. |
| F61 | Build the `adk` CLI and run local commands | Bash | Deterministic equivalent; Live | `adk_cli_test:checked_repository_examples_case/0`, `doctor_redacts_environment_case/0`, `checked_config_validation_case/0`, `deterministic_run_case/0`, `deterministic_console_case/0`, `deterministic_evaluation_case/0`; `./rebar3 escriptize` in the release gate | `examples/agent.json` and `examples/eval.json` are checked in. Gemini-backed `run`, `console`, and `evaluate` need F03; `console` remains interactive until `/exit` or EOF. |
| F62 | Start the blocking developer server | Bash | Deterministic equivalent; Dedicated fixture | `adk_cli_test:successful_developer_commands_case/0`; `erlang_adk_startup_test:supervised_dev_listener_is_authenticated/0`; packaged-escript loopback smoke test | Requires F58 and a free loopback port. The CLI test explicitly unloads the OTP application first to reproduce packaged cold startup, then asserts both the configured environment and supervised HTTP child. The literal command uses the Gemini agent in F60; the fixture substitutes a deterministic provider. Leave this process running while executing F63. |
| F63 | Inspect, mutate sessions, and resume through the developer server | Bash | Deterministic equivalent; Conceptual continuation | `adk_cli_test:successful_developer_commands_case/0`, `developer_connection_failure_is_structured_case/0`; `adk_dev_http_test`; packaged `adk inspect agents` smoke test | F62 must still be running. A refused connection returns a bounded `developer_api_unavailable` JSON reason rather than raw Erlang transport terms. `RUN_ID` is a retained run created through that server; `resume` requires the paused parent run ID. The one-shot F61 VM cannot supply a later inspectable run. |
| F64 | OIDC provider and inbound JWT policy | Erlang | Adapter-dependent; Dedicated fixture | `adk_oidc_security_test:real_oidcc_verifies_signed_offline_fixture/0`, `valid_token_returns_issuer_bound_principal/0`, `provider_child_is_explicit_and_secret_free/0`; `erlang_adk_startup_test:invalid_oidc_clock_skew_fails_startup/0` | `identity.example.com` and `RequestHeaders` are application placeholders. Production discovery/JWKS requires a real HTTPS issuer. |
| F65 | Outbound OAuth client credentials and token manager | Erlang | Adapter-dependent; Dedicated fixture | `adk_auth_test:concurrent_refresh_is_single_flight/1`, `credentials_are_isolated_by_principal/1`, `secrets_and_tokens_are_not_in_server_state/1`; `adk_oidc_security_test:client_credentials_grant_is_normalized/0`; `adk_auth_rotation_test` | Requires environment credentials, a principal from F64, and a configured provider worker. Tests use offline/fake providers and seeded secrets. |
| F66 | Prepare an S256 PKCE flow | Erlang | Literal deterministic | `readme_examples_test:suspension_and_pkce_contract/0`; `adk_suspension_test:interactive_auth_pkce_and_opaque_resume_case/0` | Uses the private credential store; `Principal` comes from authenticated application context. |
| F67 | Complete a PKCE flow | Erlang | Conceptual continuation; Dedicated fixture | `readme_examples_test:suspension_and_pkce_contract/0`; `adk_suspension_test:interactive_auth_pkce_and_opaque_resume_case/0`, `expired_or_malformed_pkce_flow_fails_closed_case/0`; `adk_auth_rotation_test` | `FlowRef` and `CorrelationId` come from F66; `CalendarClientId` and `ProviderRefreshToken` come from the validated HTTPS callback/code exchange. |
| F68 | Phoenix/Mix dependency declaration | Elixir | Companion syntax | Manually reviewed against `rebar.config` and the public Erlang modules; not compiled by this repository. | Requires a companion Mix project, Elixir, Phoenix, LiveView, and optionally `oidcc_plug`. Keep its lock file current. |
| F69 | Phoenix LiveView stable-run integration | Elixir | Companion syntax; Conceptual continuation | Public API behavior is covered by `adk_run_test`, `adk_agent_behavior_test`, `adk_sub_agents_test`, `adk_event_test`, `adk_admission_control_test`, and `adk_runtime_policy_test`; the Elixir module is not compiled here. | Requires a supervised `PhoenixAgent` and authenticated server-side `user_id`. The documented credit/ack subscription, replay-gap handling, and bounded UI history must stay aligned with `adk_run_test:credit_subscriber_runtime_buffer_overrun_case/0`. |

## Verification commands

| ID | README fence | Language | Classification | Exact validation | Prerequisites and continuation notes |
| --- | --- | --- | --- | --- | --- |
| F70 | Complete deterministic release and packaging gates | Bash | Literal deterministic | `./rebar3 do clean, compile, eunit, ct, dialyzer`; `./rebar3 escriptize`; `adk doctor`; checked agent-config validation. F61 covers the CLI-specific assertions. | Uses the bundled Rebar3. No live provider flag is required. |
| F71 | Focused README and 1,000-run stress gates | Bash | Literal deterministic | `readme_examples_test`; `readme_workflow_examples_test`; `adk_concurrency_stress_SUITE` | Run from the repository root. |
| F72 | Opt-in live Gemini suite | Bash | Live | `readme_live_gemini_SUITE` | Requires F03 and `ERLANG_ADK_LIVE_GEMINI=1` in the same shell, network access, quota, and billable API permission. |
| F73 | Live Gemini suite without request pacing | Bash | Live | `readme_live_gemini_SUITE`; pacing is parsed by `request_interval_ms/0` | Intended only for projects whose quota supports unpaced requests. Keep the default interval on constrained projects. |

## Cross-cutting behavior claims

Some material README claims span several fences. These tests keep those claims
auditable without pretending that one shell snippet proves a concurrency,
security, or restart invariant.

| Behavior claim | Exact validation |
| --- | --- |
| Direct turns retain FIFO state commits while provider/tool work stays outside the agent mailbox; independent agents overlap; stop, caller death, timeout, and worker crash reap work | `adk_agent_mailbox_test`; `adk_agent_behavior_test`; `adk_concurrency_stress_SUITE` |
| Agent supervisor reports and runtime status do not expose explicit provider credentials | `adk_agent_mailbox_test:supervisor_and_status_never_expose_agent_secret/0`; `adk_auth_test`; `adk_oidc_security_test` |
| Invocation and workflow dynamic child specifications contain only opaque launch references; one-shot handoff, diagnostics, failures, checkpoints, and persisted terminal records do not expose seeded request/state/ledger secrets | `adk_invocation_security_test`; `adk_workflow_failure_security_test` |
| Bounded supervised tasks and serial/parallel tool execution | `adk_task_test`; `adk_runner_tools_test`; `adk_toolset_test`; `adk_code_toolset_test` |
| Sub-agent replacement is resolved by stable registered name | `adk_sub_agents_test:test_restarted_sub_agent_is_resolved_by_name/0` |
| Event graph agent/function/tool helpers include instructions and callback lifecycle | `adk_graph_node_test` |
| Context filters, truncation, bounded compression, secret pruning, and stable cache keys | `adk_context_policy_test`; `adk_runner_safety_test`; `readme_examples_test:agent_contracts_and_context_policy/0` |
| ETS/Mnesia scoped state, concurrent create/update, and independent-session locking | `adk_state_scoping_test`; `adk_session_service_test`; `erlang_adk_session_mnesia_test` |
| Public callback/plugin/tool/provider/workflow failures are bounded structural values and seeded secrets do not enter callbacks, model responses, logs, status, checkpoints, task outcomes, or durable failure records | `adk_callbacks_isolation_test`; `adk_llm_test`; `adk_plugin_pipeline_test`; `adk_auth_test`; `adk_agent_mailbox_test`; `adk_task_test`; `adk_failure_security_test`; `adk_workflow_failure_security_test` |
| Stable run credit delivery permits one unacknowledged message and reports a post-subscription buffer overrun | `adk_run_test:credit_subscriber_is_bounded_and_detects_gap_case/0`; `adk_run_test:credit_subscriber_runtime_buffer_overrun_case/0` |
| Developer SSE closes at event, encoded-byte, and duration bounds without cancelling the retained run | `adk_dev_http_test:sse_replay_case/1`; `adk_dev_http_test:sse_byte_limit_closes_without_cancelling_case/1`; `adk_dev_http_test:sse_duration_limit_closes_without_cancelling_case/1`; `adk_dev_http_test:sse_detach_case/1` |
| Developer startup is authenticated, loopback-bound, bounded, and keeps only the bearer-token digest in route state | `erlang_adk_startup_test:supervised_dev_listener_is_authenticated/0`; `adk_dev_http_test:auth_case/1`, `sse_config_validation_case/0` |
| Durable workflow recovery and Mnesia HITL recovery preserve committed boundaries and continuation correlation | `adk_durable_workflow_test`; `adk_hitl_mnesia_restart_test`; `readme_workflow_examples_test:graph_fork_join_and_pause_resume/0` |
| Durable lease expiry is a write fence, a live local PID does not extend it, concurrent takeover has one winner, and the old token is stale after claim/restart | `adk_durable_workflow_test:expired_owner_cannot_write_without_takeover/1`, `expired_live_local_owner_is_claimable/1`, `concurrent_expiry_claim_has_single_winner/1`, `ledger_restart_preserves_expiry_fence/1` |

## Commands

The complete deterministic gate is:

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
```

The focused README and concurrency gates are:

```bash
./rebar3 eunit --module=readme_examples_test
./rebar3 eunit --module=readme_workflow_examples_test
./rebar3 ct --suite test/adk_concurrency_stress_SUITE.erl
```

The real-provider gate is deliberately opt-in and must run in the shell that
contains `GEMINI_API_KEY`:

```bash
ERLANG_ADK_LIVE_GEMINI=1 ./rebar3 ct \
  --suite test/readme_live_gemini_SUITE.erl
```

The live result supplements rather than replaces deterministic HTTP/SSE,
failure, cancellation, correlation, security, and persistence fixtures.
