#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
port="${2:-}"

if [[ "${mode}" != "proxy" && "${mode}" != "tls" ]]; then
  echo "usage: $0 proxy|tls PORT" >&2
  exit 2
fi

if [[ ! "${port}" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
  echo "PORT must be an integer between 1 and 65535" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
phoenix_root="${repo_root}/examples/phoenix_adk_ui"
release_bin="${phoenix_root}/_build/prod/rel/erlang_adk_ui/bin/erlang_adk_ui"

if [[ ! -x "${release_bin}" ]]; then
  echo "Phoenix release is missing; run MIX_ENV=prod mix release first" >&2
  exit 1
fi

unset ADK_UI_LOCAL_AUTH TLS_CERT_PATH TLS_KEY_PATH PHX_BEHIND_HTTPS_PROXY
export PHX_SERVER=true
export PHX_HOST=localhost
export PHX_URL_PORT="${port}"
export PORT="${port}"
export OIDC_ISSUER=https://issuer.example.invalid
export OIDC_CLIENT_ID=erlang-adk-ui-release-smoke
export OIDC_REDIRECT_URI="https://localhost:${port}/auth/callback"
export OIDC_PUBLIC_CLIENT=true
export SECRET_KEY_BASE=release-smoke-only-0123456789abcdef0123456789abcdef0123456789abcdef

if [[ "${mode}" == "proxy" ]]; then
  export PHX_BEHIND_HTTPS_PROXY=true
  health_url="http://127.0.0.1:${port}/health"
  curl_args=(-fsS --max-time 2 "${health_url}")
else
  export PHX_BEHIND_HTTPS_PROXY=false
  export TLS_CERT_PATH="${repo_root}/test/fixtures/mcp_test_cert.pem"
  export TLS_KEY_PATH="${repo_root}/test/fixtures/mcp_test_key.pem"
  health_url="https://localhost:${port}/health"
  curl_args=(
    -fsS
    --max-time 2
    --cacert "${repo_root}/test/fixtures/mcp_test_ca.pem"
    "${health_url}"
  )
fi

log_file="$(mktemp "${TMPDIR:-/tmp}/erlang-adk-phoenix-${mode}.XXXXXX")"
release_pid=""
cleanup() {
  if [[ -n "${release_pid}" ]] && kill -0 "${release_pid}" 2>/dev/null; then
    kill -TERM "${release_pid}" 2>/dev/null || true
    wait "${release_pid}" 2>/dev/null || true
  fi
  rm -f -- "${log_file}"
}
trap cleanup EXIT

"${release_bin}" start >"${log_file}" 2>&1 &
release_pid=$!

ready=false
for _attempt in $(seq 1 80); do
  if ! kill -0 "${release_pid}" 2>/dev/null; then
    echo "Phoenix ${mode} release exited before becoming healthy" >&2
    sed -n '1,200p' "${log_file}" >&2
    exit 1
  fi
  if curl "${curl_args[@]}" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 0.25
done

if [[ "${ready}" != "true" ]]; then
  echo "Phoenix ${mode} release did not return HTTP 200 from ${health_url}" >&2
  sed -n '1,200p' "${log_file}" >&2
  exit 1
fi

kill -TERM "${release_pid}"
wait "${release_pid}" 2>/dev/null || true
release_pid=""

echo "Phoenix ${mode} release smoke passed at ${health_url}"
