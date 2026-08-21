#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_path="${1:-${repo_root}/_build/default/lib/erlang_adk/hex/erlang_adk-0.10.0.tar}"

if [[ ! -f "${package_path}" ]]; then
  echo "Hex package not found: ${package_path}" >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/erlang-adk-package.XXXXXX")"
cleanup() {
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT

outer_dir="${work_dir}/outer"
contents_dir="${work_dir}/contents"
mkdir -p "${outer_dir}" "${contents_dir}"
tar -xf "${package_path}" -C "${outer_dir}"
tar -xzf "${outer_dir}/contents.tar.gz" -C "${contents_dir}"

required_files=(
  "Dockerfile"
  "LICENSE.md"
  "README.md"
  "CHANGELOG.md"
  "SECURITY.md"
  "CONTRIBUTING.md"
  "deploy/README.md"
  "deploy/agent-runtime/README.md"
  "deploy/agent-runtime/boundary-contract.json"
  "deploy/cloud-run/service.yaml.tpl"
  "deploy/helm/erlang-adk/Chart.yaml"
  "deploy/helm/erlang-adk/templates/NOTES.txt"
  "deploy/helm/erlang-adk/templates/_helpers.tpl"
  "deploy/helm/erlang-adk/templates/deployment.yaml"
  "deploy/helm/erlang-adk/templates/ingress.yaml"
  "deploy/helm/erlang-adk/templates/networkpolicy.yaml"
  "deploy/helm/erlang-adk/templates/service.yaml"
  "deploy/helm/erlang-adk/templates/serviceaccount.yaml"
  "deploy/helm/erlang-adk/values.schema.json"
  "deploy/helm/erlang-adk/values.yaml"
  "docs/AMBIENT_RUNTIME.md"
  "docs/ARTIFACTS.md"
  "docs/CODE_EXECUTION.md"
  "docs/CONTEXT.md"
  "docs/DURABLE_INVOCATIONS.md"
  "docs/FEATURE_PARITY.md"
  "docs/GEMINI_GROUNDING.md"
  "docs/GRAPH_WORKFLOWS.md"
  "docs/MEMORY.md"
  "docs/MODEL_SUPPORT.md"
  "docs/PLANNING_RUNTIME.md"
  "docs/PLUGINS_OBSERVABILITY_EVALUATION.md"
  "docs/PROVIDER_PROFILES.md"
  "docs/README.md"
  "docs/README_EXAMPLE_COVERAGE.md"
  "docs/RELEASING.md"
  "docs/RUNTIME_SAFETY.md"
  "docs/TESTING.md"
  "docs/TEST_LAYOUT.md"
  "docs/UPGRADING.md"
  "docs/VERSION_0_3_0.md"
  "docs/VERSION_0_4_0.md"
  "docs/VERSION_0_5_0.md"
  "docs/VERSION_0_6_0.md"
  "docs/VERSION_0_7_0.md"
  "docs/VERSION_0_8_0.md"
  "docs/VERSION_0_9_0.md"
  "docs/VERSION_0_10_0.md"
  "examples/readme_weather_tool.erl"
  "examples/phoenix_adk_ui/README.md"
  "examples/phoenix_adk_ui/assets/js/live_voice.js"
  "examples/phoenix_adk_ui/lib/erlang_adk_ui_web/voice_socket.ex"
  "examples/phoenix_adk_ui/priv/static/favicon.svg"
  "include/adk_event.hrl"
  "rel/build-release.sh"
  "rel/health-http.sys.config.src"
  "rel/relx.config"
  "rel/sys.config"
  "rel/vm.args"
  "scripts/deployment/container-entrypoint.sh"
  "scripts/deployment/deploy-cloud-run.sh"
  "scripts/deployment/deploy-gke.sh"
  "scripts/deployment/probe-agent-runtime.sh"
  "scripts/deployment/release-health.sh"
  "scripts/deployment/render-cloud-run.sh"
  "scripts/deployment/render-helm.sh"
  "scripts/deployment/verify-agent-runtime-contract.sh"
  "scripts/deployment/verify-manifests.sh"
  "scripts/security/README.md"
  "scripts/security/attest-provenance.sh"
  "scripts/security/build-image.sh"
  "scripts/security/generate-sbom.sh"
  "scripts/security/scan-sbom.sh"
  "scripts/security/sign-image.sh"
  "scripts/security/verify-image-ref.sh"
  "src/README.md"
  "src/auth/core/adk_authorizer.erl"
  "src/auth/credentials/adk_token_manager.erl"
  "src/auth/credentials/adk_provider_credential.erl"
  "src/auth/credentials/adk_google_adc.erl"
  "src/auth/integrations/a2a/adk_a2a_v1_oidc_auth.erl"
  "src/auth/integrations/openapi/adk_openapi_auth_manager.erl"
  "src/auth/oauth/adk_authorization_flow.erl"
  "src/auth/oidc/adk_jwt_policy.erl"
  "src/agents/adk_agent.erl"
  "src/agents/adk_agent_composition.erl"
  "src/agents/adk_agent_config.erl"
  "src/agents/adk_agent_yaml.erl"
  "src/agents/adk_config_registry.erl"
  "src/artifacts/adk_artifact_service.erl"
  "src/artifacts/adk_artifact_gcs.erl"
  "src/artifacts/journal/adk_artifact_effect_journal.erl"
  "src/artifacts/stream/adk_artifact_stream.erl"
  "src/callbacks/adk_callbacks.erl"
  "src/context/adk_context.erl"
  "src/core/adk_event.erl"
  "src/core/adk_bounded_file.erl"
  "src/developer/adk_cli.erl"
  "src/developer/adk_dev_graph_catalog.erl"
  "src/developer/adk_dev_payload_store.erl"
  "src/developer/adk_dev_trace_view.erl"
  "src/evaluation/adk_eval_set.erl"
  "src/evaluation/adk_eval_service.erl"
  "src/evaluation/adk_eval_simulation.erl"
  "src/evaluation/adk_eval_statistics.erl"
  "src/evaluation/adk_eval_store.erl"
  "src/integrations/openapi/adk_openapi_toolset.erl"
  "src/integrations/web/adk_web_gateway.erl"
  "src/live/core/adk_live_session.erl"
  "src/live/voice/adk_live_voice_bridge.erl"
  "src/live/voice/adk_live_voice_protocol.erl"
  "src/live/voice/adk_live_voice_registry.erl"
  "src/memory/adk_memory_service.erl"
  "src/memory/adk_memory_erasure_epoch.erl"
  "src/memory/embedding/adk_memory_embedding_provider.erl"
  "src/memory/ingest/adk_memory_ingest_worker.erl"
  "src/memory/outbox/adk_memory_outbox_processor.erl"
  "src/memory/policy/adk_memory_policy.erl"
  "src/memory/vector/adk_memory_vector_adapter.erl"
  "src/models/adk_llm.erl"
  "src/models/adk_safety_settings.erl"
  "src/models/anthropic/adk_llm_anthropic.erl"
  "src/models/compatible/adk_llm_compatible.erl"
  "src/models/gemini/adk_live_gemini.erl"
  "src/models/gemini/adk_live_gun_transport.erl"
  "src/models/gemini/adk_llm_gemini.erl"
  "src/models/openai/adk_llm_openai.erl"
  "src/models/openai/realtime/adk_live_openai.erl"
  "src/models/profiles/adk_local_model_endpoint.erl"
  "src/models/profiles/adk_provider_profile.erl"
  "src/models/profiles/adk_provider_registry.erl"
  "src/models/transport/adk_model_http_client.erl"
  "src/models/transport/adk_model_http_headers.erl"
  "src/models/transport/adk_model_sse_decoder.erl"
  "src/models/vertex/adk_llm_vertex.erl"
  "src/models/vertex/adk_vertex_model_resource.erl"
  "src/plugins/adk_plugin.erl"
  "src/protocols/a2a/v1/adk_a2a_v1_card.erl"
  "src/protocols/a2a/v1/adk_a2a_v1_push.erl"
  "src/protocols/a2a/v1/adk_a2a_v1_task_store.erl"
  "src/protocols/a2a/legacy/erlang_adk_a2a_client.erl"
  "src/protocols/http/adk_health_handler.erl"
  "src/protocols/http/erlang_adk_http.erl"
  "src/protocols/mcp/adk_mcp_catalog.erl"
  "src/protocols/mcp/adk_mcp_oauth.erl"
  "src/protocols/mcp/adk_mcp_pool.erl"
  "src/protocols/mcp/adk_mcp_protocol_modern.erl"
  "src/protocols/mcp/adk_mcp_server.erl"
  "src/protocols/mcp/adk_mcp_sse_stream.erl"
  "src/runtime/admission/adk_admission_control.erl"
  "src/runtime/ambient/adk_ambient.erl"
  "src/runtime/deployment/adk_deploy.erl"
  "src/runtime/deployment/adk_deployment_env.erl"
  "src/runtime/deployment/adk_deployment_lifecycle.erl"
  "src/runtime/invocations/adk_invocation.erl"
  "src/runtime/runner/adk_runner.erl"
  "src/runtime/services/adk_runtime_service_bundle.erl"
  "src/runtime/services/adk_runtime_service_profile.erl"
  "src/runtime/tasks/adk_task.erl"
  "src/sessions/erlang_adk_session.erl"
  "src/storage/adk_scope_shard_router.erl"
  "src/telemetry/adk_observability.erl"
  "src/telemetry/adk_otlp_json.erl"
  "src/telemetry/adk_trace_runtime.erl"
  "src/telemetry/adk_trace_store.erl"
  "src/tools/builtin/adk_load_memory_tool.erl"
  "src/tools/code/adk_code_executor.erl"
  "src/tools/connectors/adk_connector_manifest.erl"
  "src/tools/connectors/adk_connector_toolset.erl"
  "src/tools/core/adk_tool.erl"
  "src/workflows/core/adk_workflow.erl"
  "src/workflows/durability/adk_invocation_ledger.erl"
  "src/workflows/graph/adk_graph.erl"
  "src/workflows/graph/adk_graph_inspect.erl"
  "src/workflows/graph/adk_graph_ir.erl"
  "src/workflows/graph/adk_graph_validate.erl"
  "src/workflows/planning/adk_plan.erl"
  "src/erlang_adk.erl"
  "src/erlang_adk_app.erl"
  "src/erlang_adk_sup.erl"
  "src/erlang_adk.app.src"
)

for relative_path in "${required_files[@]}"; do
  if [[ ! -f "${contents_dir}/${relative_path}" ]]; then
    echo "Required package file is missing: ${relative_path}" >&2
    exit 1
  fi
done

legacy_flat_sources=(
  "src/adk_authorizer.erl"
  "src/adk_a2a_v1_oidc_auth.erl"
  "src/adk_eval_set.erl"
  "src/adk_llm.erl"
  "src/adk_llm_gemini.erl"
  "src/adk_observability.erl"
  "src/adk_agent.erl"
  "src/adk_artifact_service.erl"
  "src/adk_callbacks.erl"
  "src/adk_context.erl"
  "src/adk_event.erl"
  "src/adk_cli.erl"
  "src/adk_openapi_toolset.erl"
  "src/adk_web_gateway.erl"
  "src/adk_live_session.erl"
  "src/adk_live_voice_bridge.erl"
  "src/adk_memory_service.erl"
  "src/adk_plugin.erl"
  "src/adk_a2a_v1_card.erl"
  "src/erlang_adk_a2a_client.erl"
  "src/erlang_adk_http.erl"
  "src/adk_mcp_server.erl"
  "src/adk_admission_control.erl"
  "src/adk_ambient.erl"
  "src/adk_invocation.erl"
  "src/adk_runner.erl"
  "src/adk_task.erl"
  "src/erlang_adk_session.erl"
  "src/adk_scope_shard_router.erl"
  "src/adk_load_memory_tool.erl"
  "src/adk_code_executor.erl"
  "src/adk_tool.erl"
  "src/adk_workflow.erl"
  "src/adk_invocation_ledger.erl"
  "src/adk_graph.erl"
  "src/adk_plan.erl"
)

for relative_path in "${legacy_flat_sources[@]}"; do
  if [[ -e "${contents_dir}/${relative_path}" ]]; then
    echo "Legacy flat source path is still packaged: ${relative_path}" >&2
    exit 1
  fi
done

unexpected_root_source="$({
  find "${contents_dir}/src" -maxdepth 1 -type f -name '*.erl' \
    ! -name 'erlang_adk.erl' \
    ! -name 'erlang_adk_app.erl' \
    ! -name 'erlang_adk_sup.erl' \
    -print -quit
} || true)"
if [[ -n "${unexpected_root_source}" ]]; then
  echo "Unexpected Erlang source remains at src root: ${unexpected_root_source#"${contents_dir}/"}" >&2
  exit 1
fi

if ! grep -Fq '{<<"version">>,<<"0.10.0">>}.' "${outer_dir}/metadata.config"; then
  echo "Hex metadata does not declare version 0.10.0" >&2
  exit 1
fi

if ! grep -E -q '\{minimum_otp_vsn,[[:space:]]*"27\.3\.4\.14"\}' \
    "${contents_dir}/src/erlang_adk.app.src"; then
  echo "Package does not declare the OTP 27.3.4.14 security baseline" >&2
  exit 1
fi

for forbidden_path in \
  "_build" \
  "deps" \
  ".git" \
  "packages" \
  "test" \
  "Mnesia.nonode@nohost" \
  "doc" \
  "examples/phoenix_adk_ui/priv/static/assets" \
  "examples/phoenix_adk_ui/priv/static/cache_manifest.json"; do
  if [[ -e "${contents_dir}/${forbidden_path}" ]]; then
    echo "Forbidden package path is present: ${forbidden_path}" >&2
    exit 1
  fi
done

if find "${contents_dir}" -type f \
    \( -name '*.dump' -o -name '*.crashdump' -o -name 'erl_crash.dump' \) \
    -print -quit | grep -q .; then
  echo "A crash dump is present in the Hex package" >&2
  exit 1
fi

if grep -E -r -q -- \
    '(-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|AIza[0-9A-Za-z_-]{30,})' \
    "${contents_dir}"; then
  echo "A credential-shaped value is present in the Hex package" >&2
  exit 1
else
  credential_scan_status=$?
  if [[ "${credential_scan_status}" -ne 1 ]]; then
    echo "Credential scan failed with grep status ${credential_scan_status}" >&2
    exit 1
  fi
fi

original_dir="${PWD}"
cd "${contents_dir}"
"${repo_root}/rebar3" compile
cd "${original_dir}"

echo "Verified erlang_adk 0.10.0 package contents and clean extracted compile"
