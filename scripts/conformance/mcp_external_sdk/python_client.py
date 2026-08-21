from __future__ import annotations

import importlib.metadata
import json
from pathlib import Path
import sys
from typing import Any

import anyio
import httpx2
import mcp_types as types
from mcp import Client
from mcp.client.streamable_http import streamable_http_client


EXPECTED_VERSION = "2.0.0"
SDK_VERSION = importlib.metadata.version("mcp")
assert SDK_VERSION == EXPECTED_VERSION


def aliases(value: Any) -> dict[str, Any]:
    return value.model_dump(by_alias=True, exclude_none=True)


def assert_private_no_cache(value: Any) -> None:
    result = aliases(value)
    assert result["ttlMs"] == 0
    assert result["cacheScope"] == "private"


async def run_legacy(endpoint: str) -> dict[str, Any]:
    async with Client(endpoint, mode="auto") as client:
        assert client.protocol_version == "2025-11-25"
        listed = await client.list_tools()
        assert [tool.name for tool in listed.tools] == ["fixture.echo"]
        called = aliases(
            await client.call_tool(
                "fixture.echo", {"value": "python-legacy"}
            )
        )
        assert called["structuredContent"]["echo"] == "python-legacy"
        return {
            "sdk": "python",
            "sdkVersion": SDK_VERSION,
            "mode": "legacy",
            "protocolVersion": client.protocol_version,
            "status": "pass",
        }


async def run_modern(endpoint: str, trigger: Path) -> dict[str, Any]:
    captured: list[dict[str, Any]] = []

    async def capture(request: httpx2.Request) -> None:
        body = None
        if request.method == "POST":
            body = json.loads(request.content)
        captured.append(
            {
                "method": request.method,
                "headers": dict(request.headers),
                "body": body,
            }
        )

    async with httpx2.AsyncClient(
        event_hooks={"request": [capture]}
    ) as http:
        transport = streamable_http_client(endpoint, http_client=http)
        async with Client(
            transport,
            mode="auto",
            client_info=types.Implementation(
                name="erlang-adk-python-conformance", version="1.0.0"
            ),
        ) as client:
            assert client.protocol_version == "2026-07-28"

            before = await client.list_tools()
            assert [tool.name for tool in before.tools] == ["fixture.echo"]
            assert_private_no_cache(before)

            called = aliases(
                await client.call_tool(
                    "fixture.echo", {"value": "python-modern"}
                )
            )
            assert called["structuredContent"]["echo"] == "python-modern"

            resources = await client.list_resources()
            assert [resource.uri for resource in resources.resources] == [
                "fixture://resource"
            ]
            assert_private_no_cache(resources)

            read = await client.read_resource("fixture://resource")
            assert read.contents[0].text == "fixture-resource-body"
            assert_private_no_cache(read)

            prompts = await client.list_prompts()
            assert [prompt.name for prompt in prompts.prompts] == [
                "fixture-prompt"
            ]
            assert_private_no_cache(prompts)

            prompt = await client.get_prompt(
                "fixture-prompt", {"value": "python-prompt"}
            )
            assert prompt.messages[0].content.text == "python-prompt"

            async with client.listen(tools_list_changed=True) as subscription:
                assert subscription.honored.tools_list_changed is True
                with trigger.open("x", encoding="utf-8") as handle:
                    handle.write("replace\n")
                with anyio.fail_after(20):
                    event = await anext(subscription)
                assert type(event).__name__ == "ToolsListChanged"

            after = await client.list_tools()
            assert [tool.name for tool in after.tools] == ["fixture.echo.v2"]
            assert_private_no_cache(after)
            called_after = aliases(
                await client.call_tool(
                    "fixture.echo.v2",
                    {"value": "python-generation-2"},
                )
            )
            assert (
                called_after["structuredContent"]["echo"]
                == "python-generation-2"
            )

            required_methods = {
                "server/discover",
                "subscriptions/listen",
                "tools/list",
                "tools/call",
                "resources/list",
                "resources/read",
                "prompts/list",
                "prompts/get",
            }
            for request in captured:
                if request["method"] != "POST":
                    continue
                method = request["body"]["method"]
                headers = request["headers"]
                assert headers["mcp-protocol-version"] == "2026-07-28"
                assert headers["mcp-method"] == method
                meta = request["body"]["params"]["_meta"]
                assert (
                    meta["io.modelcontextprotocol/protocolVersion"]
                    == "2026-07-28"
                )
                assert (
                    meta["io.modelcontextprotocol/clientInfo"]["name"]
                    == "erlang-adk-python-conformance"
                )
                assert isinstance(
                    meta["io.modelcontextprotocol/clientCapabilities"], dict
                )
                if method in {"tools/call", "resources/read", "prompts/get"}:
                    assert headers["mcp-name"]
                required_methods.discard(method)
            assert not required_methods, sorted(required_methods)

            return {
                "sdk": "python",
                "sdkVersion": SDK_VERSION,
                "mode": "modern",
                "protocolVersion": client.protocol_version,
                "generationBefore": [tool.name for tool in before.tools],
                "generationAfter": [tool.name for tool in after.tools],
                "modernRequestsValidated": sum(
                    request["method"] == "POST" for request in captured
                ),
                "status": "pass",
            }


async def main() -> None:
    if len(sys.argv) < 3 or sys.argv[1] not in {"modern", "legacy"}:
        raise SystemExit(
            "usage: python_client.py <modern|legacy> <endpoint> [trigger]"
        )
    mode = sys.argv[1]
    endpoint = sys.argv[2]
    if mode == "modern":
        if len(sys.argv) != 4:
            raise SystemExit("modern mode requires a generation trigger path")
        result = await run_modern(endpoint, Path(sys.argv[3]))
    else:
        result = await run_legacy(endpoint)
    print(json.dumps(result, sort_keys=True))


anyio.run(main)
