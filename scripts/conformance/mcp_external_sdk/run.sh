#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
ENV_ROOT="${MCP_CONFORMANCE_ENV_ROOT:-/private/tmp/erlang-adk-mcp-external-sdk-2.0.0}"
NODE_BIN="${MCP_CONFORMANCE_NODE:-$(command -v node)}"
NODE_MODULES="${MCP_CONFORMANCE_NODE_MODULES:-$ENV_ROOT/typescript/node_modules}"
PYTHON_BIN="${MCP_CONFORMANCE_PYTHON:-$ENV_ROOT/python/bin/python}"

if [[ ! -x "$NODE_BIN" ]]; then
    echo "Node.js executable not found; run bootstrap.sh first" >&2
    exit 2
fi
if [[ ! -f "$NODE_MODULES/@modelcontextprotocol/client/package.json" ]]; then
    echo "Pinned TypeScript SDK not found; run bootstrap.sh first" >&2
    exit 2
fi
if [[ ! -x "$PYTHON_BIN" ]]; then
    echo "Pinned Python SDK environment not found; run bootstrap.sh first" >&2
    exit 2
fi

ts_version="$($NODE_BIN -p \
    "require('$NODE_MODULES/@modelcontextprotocol/client/package.json').version")"
py_version="$($PYTHON_BIN -c \
    'import importlib.metadata; print(importlib.metadata.version("mcp"))')"
if [[ "$ts_version" != "2.0.0" || "$py_version" != "2.0.0" ]]; then
    echo "MCP SDK version mismatch: TypeScript=$ts_version Python=$py_version" >&2
    exit 2
fi

export ADK_MCP_EXTERNAL_CONFORMANCE=1
export MCP_CONFORMANCE_HARNESS_DIR="$SCRIPT_DIR"
export MCP_CONFORMANCE_NODE="$NODE_BIN"
export MCP_CONFORMANCE_NODE_MODULES="$NODE_MODULES"
export MCP_CONFORMANCE_PYTHON="$PYTHON_BIN"

cd "$REPO_ROOT"
./rebar3 eunit --module=adk_mcp_external_sdk_conformance_test
