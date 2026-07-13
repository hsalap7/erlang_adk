#!/bin/sh

# Minimal line-delimited JSON-RPC MCP server used by the README/test suite.
# The client must initialize, send the initialized notification, list tools,
# and then call a tool in exactly that protocol order.
IFS= read -r initialize_request
printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}}'

IFS= read -r initialized_notification
IFS= read -r list_request
printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search","description":"Search fixture","inputSchema":{"type":"object"}}]}}'

IFS= read -r call_request
printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"fixture result"}],"isError":false}}'
exit 0
