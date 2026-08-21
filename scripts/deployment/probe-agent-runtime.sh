#!/bin/sh
set -eu

usage() {
  printf '%s\n' \
    'usage: probe-agent-runtime.sh --base-url HTTPS_ORIGIN --token-env ENV_NAME' \
    '       --expected-card-sha256 HEX --expected-extended-card-sha256 HEX' \
    '       [--connect-timeout SECONDS] [--max-time SECONDS]' \
    '       [--allow-loopback-http]'
}

fail() {
  printf 'agent-runtime probe: %s\n' "$1" >&2
  exit 64
}

base_url=''
token_env=''
expected_card=''
expected_extended=''
connect_timeout=5
max_time=20
allow_loopback_http=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-url)
      [ "$#" -ge 2 ] || fail '--base-url requires a value'
      base_url=$2
      shift 2
      ;;
    --token-env)
      [ "$#" -ge 2 ] || fail '--token-env requires a value'
      token_env=$2
      shift 2
      ;;
    --expected-card-sha256)
      [ "$#" -ge 2 ] || fail '--expected-card-sha256 requires a value'
      expected_card=$2
      shift 2
      ;;
    --expected-extended-card-sha256)
      [ "$#" -ge 2 ] || fail '--expected-extended-card-sha256 requires a value'
      expected_extended=$2
      shift 2
      ;;
    --connect-timeout)
      [ "$#" -ge 2 ] || fail '--connect-timeout requires a value'
      connect_timeout=$2
      shift 2
      ;;
    --max-time)
      [ "$#" -ge 2 ] || fail '--max-time requires a value'
      max_time=$2
      shift 2
      ;;
    --allow-loopback-http)
      allow_loopback_http=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown option: $1"
      ;;
  esac
done

[ -n "$base_url" ] || fail '--base-url is required'
[ -n "$token_env" ] || fail '--token-env is required'
[ -n "$expected_card" ] || fail '--expected-card-sha256 is required'
[ -n "$expected_extended" ] || fail '--expected-extended-card-sha256 is required'

case "$base_url" in
  https://*) curl_protocol='=https' ;;
  http://127.0.0.1|http://127.0.0.1:*|http://localhost|http://localhost:*)
    [ "$allow_loopback_http" = true ] ||
      fail 'plain HTTP requires --allow-loopback-http and a loopback origin'
    curl_protocol='=http'
    ;;
  http://*) fail 'plain HTTP is allowed only for an explicit loopback probe' ;;
  *) fail '--base-url must be an absolute HTTPS origin' ;;
esac

authority=${base_url#*://}
case "$authority" in
  ''|*/*|*'?'*|*'#'*|*@*) fail '--base-url must be an exact origin without path, credentials, query, or fragment' ;;
esac
if ! printf '%s\n' "$authority" |
     LC_ALL=C grep -Eq '^[A-Za-z0-9.-]+(:[0-9]+)?$'; then
  fail '--base-url authority contains unsupported characters'
fi

if ! printf '%s\n' "$token_env" |
     LC_ALL=C grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; then
  fail '--token-env must be a shell environment variable name'
fi

is_sha256() {
  [ "${#1}" -eq 64 ] &&
    printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$'
}
is_sha256 "$expected_card" || fail 'public Agent Card SHA-256 must be 64 lowercase hex characters'
is_sha256 "$expected_extended" || fail 'extended Agent Card SHA-256 must be 64 lowercase hex characters'

case "$connect_timeout" in ''|*[!0-9]*) fail '--connect-timeout must be a positive integer' ;; esac
case "$max_time" in ''|*[!0-9]*) fail '--max-time must be a positive integer' ;; esac
[ "$connect_timeout" -ge 1 ] && [ "$connect_timeout" -le 60 ] ||
  fail '--connect-timeout must be between 1 and 60 seconds'
[ "$max_time" -ge 1 ] && [ "$max_time" -le 120 ] ||
  fail '--max-time must be between 1 and 120 seconds'

command -v curl >/dev/null 2>&1 || fail 'curl is required'
if command -v sha256sum >/dev/null 2>&1; then
  sha256_file() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  fail 'sha256sum or shasum is required'
fi

if ! token_and_marker=$(
       printenv "$token_env"
       status=$?
       printf '.erlang-adk-token-marker'
       exit "$status"
     ); then
  fail "environment variable $token_env is not set"
fi
token_marker='
.erlang-adk-token-marker'
case "$token_and_marker" in
  *"$token_marker") token=${token_and_marker%"$token_marker"} ;;
  *) fail 'could not read the bearer token exactly' ;;
esac
[ -n "$token" ] || fail "environment variable $token_env is empty"
[ "${#token}" -le 8192 ] || fail 'bearer token exceeds 8192 bytes'
token_without_newlines=$(printf '%s' "$token" | tr -d '\r\n')
[ "$token" = "$token_without_newlines" ] ||
  fail 'bearer token must not contain CR or LF characters'
if ! printf '%s\n' "$token" |
     LC_ALL=C grep -Eq '^[A-Za-z0-9._~+/=-]+$'; then
  fail 'bearer token contains characters outside the RFC 6750 b64token set'
fi

temporary=$(mktemp -d "${TMPDIR:-/tmp}/erlang-adk-agent-runtime.XXXXXX")
live_body=$temporary/livez.json
ready_body=$temporary/readyz.json
card_body=$temporary/card.json
extended_body=$temporary/extended-card.json
rpc_body=$temporary/rpc.json
rpc_request=$temporary/rpc-request.json
trap 'rm -f "$live_body" "$ready_body" "$card_body" "$extended_body" "$rpc_body" "$rpc_request"; rmdir "$temporary" 2>/dev/null || true' EXIT HUP INT TERM
printf '%s\n' '{"jsonrpc":"2.0","id":"agent-runtime-probe","method":"ListTasks","params":{"pageSize":1,"includeArtifacts":false}}' >"$rpc_request"

curl_common() {
  curl --silent --show-error --fail-with-body \
    --connect-timeout "$connect_timeout" --max-time "$max_time" \
    --max-filesize 1048576 --max-redirs 0 --proto "$curl_protocol" "$@"
}

expect_get() {
  url=$1
  output=$2
  status=$(curl_common --request GET --output "$output" \
             --write-out '%{http_code}' "$url") ||
    fail "GET $url failed"
  [ "$status" = 200 ] || fail "GET $url returned HTTP $status"
}

expect_authenticated_get() {
  url=$1
  output=$2
  status=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
             curl_common --config - --request GET \
               --header 'A2A-Version: 1.0' --output "$output" \
               --write-out '%{http_code}' "$url") ||
    fail "authenticated GET $url failed"
  [ "$status" = 200 ] || fail "authenticated GET $url returned HTTP $status"
}

expect_get "$base_url/livez" "$live_body"
grep -Eq '"status"[[:space:]]*:[[:space:]]*"live"' "$live_body" ||
  fail '/livez response did not report live'

expect_get "$base_url/readyz" "$ready_body"
grep -Eq '"status"[[:space:]]*:[[:space:]]*"ready"' "$ready_body" ||
  fail '/readyz response did not report ready'

expect_get "$base_url/.well-known/agent-card.json" "$card_body"
[ "$(sha256_file "$card_body")" = "$expected_card" ] ||
  fail 'public Agent Card SHA-256 mismatch'
grep -Eq '"protocolBinding"[[:space:]]*:[[:space:]]*"JSONRPC"' "$card_body" ||
  fail 'public Agent Card does not advertise JSONRPC'
grep -Eq '"protocolVersion"[[:space:]]*:[[:space:]]*"1\.0"' "$card_body" ||
  fail 'public Agent Card does not advertise A2A 1.0'

expect_authenticated_get "$base_url/extendedAgentCard" "$extended_body"
[ "$(sha256_file "$extended_body")" = "$expected_extended" ] ||
  fail 'extended Agent Card SHA-256 mismatch'

rpc_status=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
  curl_common --config - --request POST \
    --header 'A2A-Version: 1.0' \
    --header 'Content-Type: application/json' \
    --data-binary "@$rpc_request" --output "$rpc_body" \
    --write-out '%{http_code}' "$base_url/a2a/v1") ||
  fail 'read-only A2A ListTasks probe failed'
[ "$rpc_status" = 200 ] || fail "A2A RPC returned HTTP $rpc_status"
grep -Eq '"jsonrpc"[[:space:]]*:[[:space:]]*"2\.0"' "$rpc_body" ||
  fail 'A2A RPC response is not JSON-RPC 2.0'
grep -Eq '"id"[[:space:]]*:[[:space:]]*"agent-runtime-probe"' "$rpc_body" ||
  fail 'A2A RPC response id does not match the probe'
grep -Eq '"result"[[:space:]]*:' "$rpc_body" ||
  fail 'A2A ListTasks response did not contain a result'

printf '%s\n' 'Agent Runtime feasibility boundary passed (read-only; no managed-service support claim)'
