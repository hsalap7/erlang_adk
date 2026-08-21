#!/bin/sh
set -eu

contract=deploy/agent-runtime/boundary-contract.json
probe=scripts/deployment/probe-agent-runtime.sh

[ -r "$contract" ] || { printf 'missing contract: %s\n' "$contract" >&2; exit 66; }
[ -x "$probe" ] || { printf 'probe is not executable: %s\n' "$probe" >&2; exit 66; }

sh -n "$probe"

require_text() {
  file=$1
  needle=$2
  grep -Fq -- "$needle" "$file" || {
    printf 'contract drift: %s does not contain %s\n' "$file" "$needle" >&2
    exit 1
  }
}

require_text "$contract" '"classification": "feasibility-only"'
require_text "$contract" '"claimed": false'
require_text "$contract" '"cloudMutations": false'
require_text "$contract" '"agentTaskMutations": false'
require_text "$contract" '"probeRpcMethod": "ListTasks"'
for blocker in vendor-lifecycle identity network state conformance; do
  require_text "$contract" "\"id\": \"$blocker\""
done

require_text Dockerfile 'USER 10001:10001'
require_text Dockerfile 'STOPSIGNAL SIGTERM'
require_text Dockerfile 'ENTRYPOINT ["/opt/erlang_adk/bin/container-entrypoint"]'
require_text Dockerfile '/var/lib/erlang_adk'
require_text Dockerfile '/var/log/erlang_adk'
require_text Dockerfile '/tmp/erlang_adk'

routes=src/protocols/http/erlang_adk_http.erl
require_text "$routes" '{"/livez", adk_health_handler'
require_text "$routes" '{"/readyz", adk_health_handler'
require_text "$routes" '{"/.well-known/agent-card.json", adk_a2a_v1_handler'
require_text "$routes" '{"/extendedAgentCard", adk_a2a_v1_handler'
require_text "$routes" '{"/a2a/v1", adk_a2a_v1_handler'

handler=src/protocols/a2a/v1/adk_a2a_v1_handler.erl
require_text "$handler" 'handle_extended_card(Req0, Config)'
require_text "$handler" '<<"a2a-version">>'
require_text "$handler" '<<"1.0">>'
require_text "$handler" '<<"private, no-store">>'

rpc=src/protocols/a2a/v1/adk_a2a_v1_rpc.erl
require_text "$rpc" 'method_type(<<"ListTasks">>) -> unary'
require_text "$probe" '"method":"ListTasks"'
require_text "$probe" "--max-redirs 0"
require_text "$probe" "--proto \"\$curl_protocol\""

if grep -Eq '(^|[[:space:]])(gcloud|kubectl|terraform|pulumi)([[:space:]]|$)|--apply' "$probe"; then
  printf '%s\n' 'probe must not contain cloud mutation commands' >&2
  exit 1
fi
if grep -Eq '(^|[[:space:]])eval([[:space:]]|$)' "$probe"; then
  printf '%s\n' 'probe must not use eval for environment indirection' >&2
  exit 1
fi

"$probe" --help >/dev/null
if "$probe" \
     --base-url http://example.invalid \
     --token-env ADK_AGENT_RUNTIME_PROBE_TOKEN \
     --expected-card-sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
     --expected-extended-card-sha256 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
     >/dev/null 2>&1; then
  printf '%s\n' 'probe accepted non-loopback plain HTTP' >&2
  exit 1
fi

printf '%s\n' 'Agent Runtime feasibility contract passed (static/read-only; no support claim)'
