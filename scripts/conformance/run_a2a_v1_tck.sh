#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
TCK_DIR="${A2A_TCK_DIR:-/private/tmp/erlang-adk-a2a-tck-20260819}"
EXPECTED_COMMIT="5996b79f9cefa6fc390980e383e358a66fb9e49e"
PORT="${A2A_TCK_PORT:-9999}"
BASE_URL="http://127.0.0.1:$PORT"
FIXTURE_LOG="${A2A_TCK_FIXTURE_LOG:-$REPO_ROOT/_build/a2a-v1-tck-fixture.log}"

if [[ ! -x "$TCK_DIR/run_tck.py" ]]; then
    echo "A2A TCK runner not found at $TCK_DIR/run_tck.py" >&2
    exit 2
fi
if [[ ! -x "$TCK_DIR/.venv/bin/python" ]]; then
    echo "A2A TCK virtual environment not found at $TCK_DIR/.venv" >&2
    exit 2
fi

actual_commit="$(git -C "$TCK_DIR" rev-parse HEAD)"
if [[ "$actual_commit" != "$EXPECTED_COMMIT" ]]; then
    echo "A2A TCK commit mismatch: expected $EXPECTED_COMMIT, got $actual_commit" >&2
    exit 2
fi

cd "$REPO_ROOT"
./rebar3 as test compile

beam_paths=()
for path in "$REPO_ROOT"/_build/test/lib/*/ebin; do
    beam_paths+=( -pa "$path" )
done

A2A_TCK_PORT="$PORT" erl -noshell \
    "${beam_paths[@]}" \
    -pa "$REPO_ROOT/_build/test/lib/erlang_adk/test" \
    -s adk_a2a_v1_tck_fixture start \
    >"$FIXTURE_LOG" 2>&1 &
fixture_pid=$!

cleanup() {
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

ready=false
for _ in {1..100}; do
    if curl --fail --silent --show-error \
        "$BASE_URL/.well-known/agent-card.json" >/dev/null 2>&1; then
        ready=true
        break
    fi
    if ! kill -0 "$fixture_pid" 2>/dev/null; then
        break
    fi
    sleep 0.1
done

if [[ "$ready" != true ]]; then
    echo "A2A TCK fixture failed to become ready; log follows" >&2
    sed -n '1,240p' "$FIXTURE_LOG" >&2
    exit 1
fi

cd "$TCK_DIR"
./.venv/bin/python ./run_tck.py \
    --sut-host "$BASE_URL" \
    --transport jsonrpc \
    -- \
    --webhook-host=localhost
