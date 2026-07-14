#!/bin/sh

IFS= read -r initialize_request
printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"timeout-fixture","version":"1"}}}'
IFS= read -r initialized_notification
IFS= read -r list_request
sleep 1
exit 0
