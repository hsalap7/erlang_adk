import assert from "node:assert/strict";
import {readFile, writeFile} from "node:fs/promises";
import path from "node:path";
import {pathToFileURL} from "node:url";

const [mode, endpoint, trigger] = process.argv.slice(2);
const modulesRoot = process.env.MCP_CONFORMANCE_NODE_MODULES;
assert.ok(modulesRoot, "MCP_CONFORMANCE_NODE_MODULES is required");

const packagePath = path.join(
  modulesRoot,
  "@modelcontextprotocol/client/package.json",
);
const packageMetadata = JSON.parse(await readFile(packagePath, "utf8"));
assert.equal(packageMetadata.version, "2.0.0");

const sdkUrl = pathToFileURL(
  path.join(modulesRoot, "@modelcontextprotocol/client/dist/index.mjs"),
);
const {Client, StreamableHTTPClientTransport} = await import(sdkUrl.href);

function names(items) {
  return items.map((item) => item.name);
}

function assertPrivateNoCache(result) {
  assert.equal(result.ttlMs, 0);
  assert.equal(result.cacheScope, "private");
}

async function runLegacy() {
  const client = new Client(
    {name: "erlang-adk-ts-conformance", version: "1.0.0"},
    {versionNegotiation: {mode: "auto"}},
  );
  try {
    await client.connect(
      new StreamableHTTPClientTransport(new URL(endpoint)),
    );
    assert.equal(client.getProtocolEra(), "legacy");
    assert.equal(client.getNegotiatedProtocolVersion(), "2025-11-25");
    const listed = await client.listTools();
    assert.deepEqual(names(listed.tools), ["fixture.echo"]);
    const called = await client.callTool({
      name: "fixture.echo",
      arguments: {value: "typescript-legacy"},
    });
    assert.equal(called.structuredContent.echo, "typescript-legacy");
    return {
      sdk: "typescript",
      sdkVersion: packageMetadata.version,
      mode,
      protocolEra: client.getProtocolEra(),
      protocolVersion: client.getNegotiatedProtocolVersion(),
      status: "pass",
    };
  } finally {
    await client.close();
  }
}

async function runModern() {
  assert.ok(trigger, "modern mode requires a generation trigger path");
  const captured = [];
  const recordingFetch = async (input, init) => {
    const request = new Request(input, init);
    let body = null;
    if (request.method === "POST") {
      body = await request.clone().json();
    }
    captured.push({
      method: request.method,
      headers: Object.fromEntries(request.headers.entries()),
      body,
    });
    return fetch(input, init);
  };

  let resolveChanged;
  let rejectChanged;
  const changed = new Promise((resolve, reject) => {
    resolveChanged = resolve;
    rejectChanged = reject;
  });
  const changeTimeout = setTimeout(
    () => rejectChanged(new Error("tools listChanged timeout")),
    20000,
  );

  const client = new Client(
    {name: "erlang-adk-ts-conformance", version: "1.0.0"},
    {
      versionNegotiation: {mode: {pin: "2026-07-28"}},
      listChanged: {
        tools: {
          autoRefresh: true,
          debounceMs: 0,
          onChanged(error, tools) {
            if (error) rejectChanged(error);
            else resolveChanged(tools);
          },
        },
      },
    },
  );

  try {
    await client.connect(
      new StreamableHTTPClientTransport(new URL(endpoint), {
        fetch: recordingFetch,
      }),
    );
    assert.equal(client.getProtocolEra(), "modern");
    assert.equal(client.getNegotiatedProtocolVersion(), "2026-07-28");

    const before = await client.listTools();
    assert.deepEqual(names(before.tools), ["fixture.echo"]);
    assertPrivateNoCache(before);

    const called = await client.callTool({
      name: "fixture.echo",
      arguments: {value: "typescript-modern"},
    });
    assert.equal(called.structuredContent.echo, "typescript-modern");

    const resources = await client.listResources();
    assert.deepEqual(
      resources.resources.map((resource) => resource.uri),
      ["fixture://resource"],
    );
    assertPrivateNoCache(resources);

    const read = await client.readResource({uri: "fixture://resource"});
    assert.equal(read.contents[0].text, "fixture-resource-body");
    assertPrivateNoCache(read);

    const prompts = await client.listPrompts();
    assert.deepEqual(names(prompts.prompts), ["fixture-prompt"]);
    assertPrivateNoCache(prompts);

    const prompt = await client.getPrompt({
      name: "fixture-prompt",
      arguments: {value: "typescript-prompt"},
    });
    assert.equal(prompt.messages[0].content.text, "typescript-prompt");

    await writeFile(trigger, "replace\n", {flag: "wx"});
    const refreshed = await changed;
    assert.deepEqual(names(refreshed), ["fixture.echo.v2"]);

    const after = await client.listTools();
    assert.deepEqual(names(after.tools), ["fixture.echo.v2"]);
    assertPrivateNoCache(after);
    const calledAfter = await client.callTool({
      name: "fixture.echo.v2",
      arguments: {value: "typescript-generation-2"},
    });
    assert.equal(
      calledAfter.structuredContent.echo,
      "typescript-generation-2",
    );

    const requiredMethods = new Set([
      "server/discover",
      "subscriptions/listen",
      "tools/list",
      "tools/call",
      "resources/list",
      "resources/read",
      "prompts/list",
      "prompts/get",
    ]);
    for (const request of captured.filter((item) => item.method === "POST")) {
      const method = request.body?.method;
      assert.equal(request.headers["mcp-protocol-version"], "2026-07-28");
      assert.equal(request.headers["mcp-method"], method);
      const meta = request.body?.params?._meta;
      assert.equal(
        meta?.["io.modelcontextprotocol/protocolVersion"],
        "2026-07-28",
      );
      assert.equal(
        meta?.["io.modelcontextprotocol/clientInfo"]?.name,
        "erlang-adk-ts-conformance",
      );
      assert.equal(
        typeof meta?.["io.modelcontextprotocol/clientCapabilities"],
        "object",
      );
      if (["tools/call", "resources/read", "prompts/get"].includes(method)) {
        assert.ok(request.headers["mcp-name"]);
      }
      requiredMethods.delete(method);
    }
    assert.deepEqual([...requiredMethods], []);

    return {
      sdk: "typescript",
      sdkVersion: packageMetadata.version,
      mode,
      protocolEra: client.getProtocolEra(),
      protocolVersion: client.getNegotiatedProtocolVersion(),
      generationBefore: names(before.tools),
      generationAfter: names(after.tools),
      modernRequestsValidated: captured.filter(
        (item) => item.method === "POST",
      ).length,
      status: "pass",
    };
  } finally {
    clearTimeout(changeTimeout);
    // The official SDK exposes the auto-opened long-lived listen handle so
    // consumers can perform the protocol's request-scoped teardown before
    // closing the shared transport.
    await client.autoOpenedSubscription?.close();
    await client.close();
  }
}

if (!endpoint || !["modern", "legacy"].includes(mode)) {
  throw new Error(
    "usage: typescript_client.mjs <modern|legacy> <endpoint> [trigger]",
  );
}

const result = mode === "modern" ? await runModern() : await runLegacy();
await new Promise((resolve, reject) => {
  process.stdout.write(`${JSON.stringify(result)}\n`, (error) => {
    if (error) reject(error);
    else resolve();
  });
});
