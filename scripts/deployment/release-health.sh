#!/bin/sh
set -eu

mode=${1:-ready}
release_root=${ERLANG_ADK_RELEASE_ROOT:-/opt/erlang_adk}
data_dir=${ERLANG_ADK_DATA_DIR:-/var/lib/erlang_adk}
tmp_dir=${ERLANG_ADK_TMP_DIR:-/tmp/erlang_adk}
drain_timeout_ms=${ERLANG_ADK_DRAIN_TIMEOUT_MS:-30000}
dist_port=${ERLANG_ADK_DIST_PORT:-9100}
rpc_timeout_seconds=${ERLANG_ADK_HEALTH_RPC_TIMEOUT_SECONDS:-1}
run_dir=$data_dir/run
pid_file=$run_dir/release.pid
ready_file=$run_dir/ready
draining_file=$run_dir/draining
cookie_file=$tmp_dir/.erlang.cookie

case "$dist_port" in
  ''|*[!0-9]*)
    printf '%s\n' 'ERLANG_ADK_DIST_PORT must be an integer from 1 to 65535' >&2
    exit 64
    ;;
esac
if [ "${#dist_port}" -gt 5 ] || [ "$dist_port" -lt 1 ] ||
   [ "$dist_port" -gt 65535 ]; then
  printf '%s\n' 'ERLANG_ADK_DIST_PORT must be an integer from 1 to 65535' >&2
  exit 64
fi

case "$rpc_timeout_seconds" in
  ''|*[!0-9]*)
    printf '%s\n' \
      'ERLANG_ADK_HEALTH_RPC_TIMEOUT_SECONDS must be from 1 to 30' >&2
    exit 64
    ;;
esac
if [ "${#rpc_timeout_seconds}" -gt 2 ] ||
   [ "$rpc_timeout_seconds" -lt 1 ] ||
   [ "$rpc_timeout_seconds" -gt 30 ]; then
  printf '%s\n' \
    'ERLANG_ADK_HEALTH_RPC_TIMEOUT_SECONDS must be from 1 to 30' >&2
  exit 64
fi

erl_call_path=''
for candidate in "$release_root"/erts-*/bin/erl_call; do
  [ -x "$candidate" ] || continue
  if [ -n "$erl_call_path" ]; then
    printf '%s\n' 'release contains multiple erl_call executables' >&2
    exit 70
  fi
  erl_call_path=$candidate
done
[ -n "$erl_call_path" ] || {
  printf '%s\n' 'release erl_call executable is unavailable' >&2
  exit 70
}

mark_draining() {
  mkdir -p "$run_dir"
  : >"$draining_file"
  rm -f "$ready_file"
}

live() {
  [ -r "$pid_file" ] || return 1
  pid=$(sed -n '1p' "$pid_file")
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

runtime_zero() {
  [ -r "$cookie_file" ] || return 1
  cookie=$(sed -n '1p' "$cookie_file")
  [ -n "$cookie" ] || return 1
  command="$1 $2 $3"
  call_timeout_seconds=${4:-$rpc_timeout_seconds}
  output=$("$erl_call_path" -R -c "$cookie" \
    -address "127.0.0.1:$dist_port" \
    -timeout "$call_timeout_seconds" -a "$command" 2>/dev/null) || return 1
  [ "$output" = '0' ]
}

runtime_live() {
  runtime_zero adk_deployment_lifecycle liveness_code '[]'
}

runtime_ready() {
  runtime_zero adk_deployment_lifecycle readiness_code '[]'
}

runtime_drain() {
  case "$drain_timeout_ms" in
    ''|*[!0-9]*|???????*)
      printf '%s\n' \
        'ERLANG_ADK_DRAIN_TIMEOUT_MS must be from 0 to 600000' >&2
      return 1
      ;;
  esac
  if [ "$drain_timeout_ms" -gt 600000 ]; then
    printf '%s\n' \
      'ERLANG_ADK_DRAIN_TIMEOUT_MS must be from 0 to 600000' >&2
    return 1
  fi
  drain_rpc_timeout_seconds=$(((drain_timeout_ms + 999) / 1000 + 2))
  runtime_zero adk_deployment_lifecycle drain_code "[$drain_timeout_ms]" \
    "$drain_rpc_timeout_seconds"
}

dependency_ready() {
  hook=${ERLANG_ADK_READINESS_HOOK:-}
  [ -n "$hook" ] || return 0
  case "$hook" in
    /opt/erlang_adk/hooks/*) ;;
    *)
      printf '%s\n' 'readiness hook must be under /opt/erlang_adk/hooks/' >&2
      return 1
      ;;
  esac
  [ -x "$hook" ] && "$hook"
}

case "$mode" in
  live)
    live && runtime_live
    ;;
  ready)
    live && [ -f "$ready_file" ] && [ ! -f "$draining_file" ] &&
      runtime_ready && dependency_ready
    ;;
  drain)
    mark_draining
    runtime_drain
    ;;
  *)
    printf '%s\n' 'usage: deployment-health live|ready|drain' >&2
    exit 64
    ;;
esac
