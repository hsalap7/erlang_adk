#!/bin/sh
set -eu

release_root=${ERLANG_ADK_RELEASE_ROOT:-/opt/erlang_adk}
data_dir=${ERLANG_ADK_DATA_DIR:-/var/lib/erlang_adk}
log_dir=${ERLANG_ADK_LOG_DIR:-/var/log/erlang_adk}
tmp_dir=${ERLANG_ADK_TMP_DIR:-/tmp/erlang_adk}
startup_grace=${ERLANG_ADK_STARTUP_GRACE_SECONDS:-2}
nofile_cap=${ERLANG_ADK_NOFILE_CAP:-65536}
run_dir=$data_dir/run
ready_file=$run_dir/ready
draining_file=$run_dir/draining
pid_file=$run_dir/release.pid

case "$startup_grace" in
  ''|*[!0-9]*)
    printf '%s\n' 'ERLANG_ADK_STARTUP_GRACE_SECONDS must be an integer' >&2
    exit 64
    ;;
esac

case "$nofile_cap" in
  ''|*[!0-9]*|????????*)
    printf '%s\n' 'ERLANG_ADK_NOFILE_CAP must be an integer from 1024 to 1048576' >&2
    exit 64
    ;;
esac
if [ "$nofile_cap" -lt 1024 ] || [ "$nofile_cap" -gt 1048576 ]; then
  printf '%s\n' 'ERLANG_ADK_NOFILE_CAP must be an integer from 1024 to 1048576' >&2
  exit 64
fi

# Some container runtimes inherit a near-billion soft descriptor limit. ERTS
# sizes its descriptor tables from that limit before the application boots,
# which can exhaust a bounded pod even though the release itself is small.
# Lower only oversized limits; never attempt to raise an operator's limit.
nofile_target=$nofile_cap
for current_nofile in "$(ulimit -Sn)" "$(ulimit -Hn)"; do
  case "$current_nofile" in
    unlimited)
      ;;
    ''|*[!0-9]*)
      printf '%s\n' 'could not determine the process open-file limit' >&2
      exit 71
      ;;
    *)
      if [ "$current_nofile" -lt "$nofile_target" ]; then
        nofile_target=$current_nofile
      fi
      ;;
  esac
done
if ! ulimit -n "$nofile_target"; then
  printf '%s\n' 'could not apply the bounded process open-file limit' >&2
  exit 71
fi

for writable_dir in "$data_dir" "$log_dir" "$tmp_dir"; do
  mkdir -p "$writable_dir"
  if [ ! -w "$writable_dir" ]; then
    printf 'required writable mount is not writable: %s\n' "$writable_dir" >&2
    exit 73
  fi
done
mkdir -p "$run_dir"

export HOME=$tmp_dir
export ERL_CRASH_DUMP=$log_dir/erl_crash.dump
export RUNNER_LOG_DIR=$log_dir
export TMPDIR=$tmp_dir

# Relx requires a node name for release control. Keep its loopback-only
# distribution cookie private and ephemeral unless an orchestrator mounts one.
cookie_file=$HOME/.erlang.cookie
if [ ! -f "$cookie_file" ]; then
  cookie_tmp=$cookie_file.tmp
  umask 077
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n' >"$cookie_tmp"
  mv "$cookie_tmp" "$cookie_file"
fi
chmod 0600 "$cookie_file"

rm -f "$ready_file" "$draining_file" "$pid_file"

child_pid=''
drain_started=false
begin_drain() {
  [ "$drain_started" = false ] || return 0
  drain_started=true
  : >"$draining_file"
  rm -f "$ready_file"
  if [ -n "$child_pid" ]; then
    "$release_root/bin/deployment-health" drain || true
    kill -TERM "$child_pid" 2>/dev/null || true
  fi
}
trap begin_drain TERM INT HUP

case "${1:-foreground}" in
  foreground)
    shift || true
    "$release_root/bin/erlang_adk" foreground "$@" &
    ;;
  *)
    "$@" &
    ;;
esac
child_pid=$!
printf '%s\n' "$child_pid" >"$pid_file"

elapsed=0
while [ "$elapsed" -lt "$startup_grace" ]; do
  if ! kill -0 "$child_pid" 2>/dev/null; then
    wait "$child_pid"
    exit $?
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

if [ ! -f "$draining_file" ]; then
  : >"$ready_file"
fi

status=0
while :; do
  set +e
  wait "$child_pid"
  status=$?
  set -e
  kill -0 "$child_pid" 2>/dev/null || break
done
rm -f "$ready_file" "$pid_file"
exit "$status"
