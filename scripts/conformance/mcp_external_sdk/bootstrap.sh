#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_ROOT="${MCP_CONFORMANCE_ENV_ROOT:-/private/tmp/erlang-adk-mcp-external-sdk-2.0.0}"
TS_ROOT="$ENV_ROOT/typescript"
PY_ROOT="$ENV_ROOT/python"

case "$ENV_ROOT" in
    /private/tmp/*|/tmp/*) ;;
    *)
        echo "MCP_CONFORMANCE_ENV_ROOT must be beneath /private/tmp or /tmp" >&2
        exit 2
        ;;
esac

mkdir -p "$TS_ROOT"
cp "$SCRIPT_DIR/package.json" "$SCRIPT_DIR/package-lock.json" "$TS_ROOT/"
npm --prefix "$TS_ROOT" ci --ignore-scripts --no-audit --no-fund

python3 -m venv --clear "$PY_ROOT"
"$PY_ROOT/bin/python" -m pip install \
    --disable-pip-version-check --no-deps \
    --requirement "$SCRIPT_DIR/requirements.lock"
"$PY_ROOT/bin/python" -m pip check

echo "Pinned MCP SDK environment created at $ENV_ROOT"
echo "Run $SCRIPT_DIR/run.sh"
