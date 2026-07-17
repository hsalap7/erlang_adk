#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_path="${1:-${repo_root}/_build/default/lib/erlang_adk/hex/erlang_adk-0.8.0.tar}"

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
  "LICENSE.md"
  "README.md"
  "CHANGELOG.md"
  "SECURITY.md"
  "docs/PROVIDER_PROFILES.md"
  "docs/RELEASING.md"
  "docs/TEST_LAYOUT.md"
  "docs/VERSION_0_8_0.md"
  "examples/readme_weather_tool.erl"
  "examples/phoenix_adk_ui/README.md"
  "examples/phoenix_adk_ui/assets/js/live_voice.js"
  "examples/phoenix_adk_ui/lib/erlang_adk_ui_web/voice_socket.ex"
  "examples/phoenix_adk_ui/priv/static/favicon.svg"
  "include/adk_event.hrl"
  "src/README.md"
  "src/auth/core/adk_authorizer.erl"
  "src/auth/credentials/adk_token_manager.erl"
  "src/auth/credentials/adk_provider_credential.erl"
  "src/auth/integrations/a2a/adk_a2a_v1_oidc_auth.erl"
  "src/auth/integrations/openapi/adk_openapi_auth_manager.erl"
  "src/auth/oauth/adk_authorization_flow.erl"
  "src/auth/oidc/adk_jwt_policy.erl"
  "src/agents/adk_agent.erl"
  "src/artifacts/adk_artifact_service.erl"
  "src/callbacks/adk_callbacks.erl"
  "src/context/adk_context.erl"
  "src/core/adk_event.erl"
  "src/developer/adk_cli.erl"
  "src/evaluation/adk_eval_set.erl"
  "src/integrations/openapi/adk_openapi_toolset.erl"
  "src/integrations/web/adk_web_gateway.erl"
  "src/live/core/adk_live_session.erl"
  "src/live/voice/adk_live_voice_bridge.erl"
  "src/live/voice/adk_live_voice_protocol.erl"
  "src/live/voice/adk_live_voice_registry.erl"
  "src/memory/adk_memory_service.erl"
  "src/memory/ingest/adk_memory_ingest_worker.erl"
  "src/memory/outbox/adk_memory_outbox_processor.erl"
  "src/models/adk_llm.erl"
  "src/models/adk_safety_settings.erl"
  "src/models/anthropic/adk_llm_anthropic.erl"
  "src/models/compatible/adk_llm_compatible.erl"
  "src/models/gemini/adk_live_gemini.erl"
  "src/models/gemini/adk_live_gun_transport.erl"
  "src/models/gemini/adk_llm_gemini.erl"
  "src/models/openai/adk_llm_openai.erl"
  "src/models/openai/realtime/adk_live_openai.erl"
  "src/models/profiles/adk_provider_profile.erl"
  "src/models/profiles/adk_provider_registry.erl"
  "src/models/transport/adk_model_http_client.erl"
  "src/models/transport/adk_model_http_headers.erl"
  "src/models/transport/adk_model_sse_decoder.erl"
  "src/plugins/adk_plugin.erl"
  "src/protocols/a2a/v1/adk_a2a_v1_card.erl"
  "src/protocols/a2a/legacy/erlang_adk_a2a_client.erl"
  "src/protocols/http/erlang_adk_http.erl"
  "src/protocols/mcp/adk_mcp_server.erl"
  "src/runtime/admission/adk_admission_control.erl"
  "src/runtime/ambient/adk_ambient.erl"
  "src/runtime/invocations/adk_invocation.erl"
  "src/runtime/runner/adk_runner.erl"
  "src/runtime/tasks/adk_task.erl"
  "src/sessions/erlang_adk_session.erl"
  "src/storage/adk_scope_shard_router.erl"
  "src/telemetry/adk_observability.erl"
  "src/telemetry/adk_otlp_json.erl"
  "src/tools/builtin/adk_load_memory_tool.erl"
  "src/tools/code/adk_code_executor.erl"
  "src/tools/core/adk_tool.erl"
  "src/workflows/core/adk_workflow.erl"
  "src/workflows/durability/adk_invocation_ledger.erl"
  "src/workflows/graph/adk_graph.erl"
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

if ! grep -Fq '{<<"version">>,<<"0.8.0">>}.' "${outer_dir}/metadata.config"; then
  echo "Hex metadata does not declare version 0.8.0" >&2
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

echo "Verified erlang_adk 0.8.0 package contents and clean extracted compile"
