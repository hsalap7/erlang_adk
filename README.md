# Erlang ADK v0.2.0

An Erlang-native Agent Development Kit (ADK) inspired by Google ADK 2.0. It leverages Erlang's robust OTP framework (processes, `gen_server`, and supervisors) to provide a scalable and observable multi-agent system.

It features native integration with Google Gemini, allowing your agents to interact with real LLMs.

## Features (ADK 2.0 Feature Parity)

- **Graph-Based Workflows**: Decouple execution from LLMs using `adk_graph`. Build workflows with nodes, deterministic edges, and conditional branching.
- **Multi-Agent Systems**: Create teams of specialized agents that collaborate. An agent can act as a tool for another agent using `adk_agent_tool`.
- **Model Context Protocol (MCP)**: Connect agents to external data sources. Includes `adk_mcp_client` and `adk_mcp_server`.
- **Human-in-the-Loop (HITL)**: Built-in primitives to pause workflows (`adk_long_running_tool`), ask for human approval, and resume later.
- **Streaming & Evaluation**: Stream Gemini responses directly via `gun` integration. Evaluate agent performance using `adk_eval`.
- **Long-term Semantic Memory**: Dedicated `adk_memory_service` for storing and searching past interactions.
- **Resiliency**: Built-in exponential backoff via `adk_retry`.
- **OTP-Native**: Agents are highly concurrent, fault-tolerant `gen_server` processes, backed by ETS/Mnesia persistence.

## Quickstart

Add `erlang_adk` as a dependency in your `rebar.config`:

```erlang
{deps, [
    erlang_adk,
    {gun, "2.1.0"} %% Required for streaming capabilities
]}.
```

Ensure the application is started:

```erlang
application:ensure_all_started(erlang_adk).
```

### Usage

Before spawning an agent, make sure your API key is available:

```bash
export GEMINI_API_KEY="your_api_key_here"
```

#### Graph Workflows (New in v0.2.0)

Agents are now orchestrated using Graph Workflows (`adk_graph`). This allows complex control flow (loops, branches).

```erlang
G0 = adk_graph:new(),
NodeFn = fun(State) -> #{<<"count">> => maps:get(<<"count">>, State, 0) + 1} end,
G1 = adk_graph:add_node(G0, increment, NodeFn),

%% Conditional edge
CondFn = fun(State) ->
    if maps:get(<<"count">>, State) < 3 -> increment;
       true -> end_node
    end
end,
G2 = adk_graph:add_conditional_edge(G1, increment, CondFn),
G3 = adk_graph:set_entry_point(G2, increment),

{ok, Compiled} = adk_graph:compile(G3),
{ok, FinalState} = adk_graph:run(Compiled, #{<<"count">> => 0}).
```

The unified orchestrator (`erlang_adk_orchestrator`) provides backward-compatible `sequential/2`, `parallel/2`, and `loop/4` operations that compile down into these underlying graphs.

#### Streaming Support

Stream responses directly from Gemini:

```erlang
Callback = fun(Chunk) -> io:format("~s", [Chunk]) end,
adk_llm:stream(LLMConfig, History, Tools, Callback).
```

#### Multi-Agent Delegation

Agents can use other agents as tools via `adk_agent_tool`.

```erlang
Config = #{name => <<"ResearchAgent">>, description => <<"Finds info">>},
Schema = adk_agent_tool:schema(Config),
%% Now you can pass this Schema/Tool to another agent!
```

#### MCP Integration

Expose Erlang tools to Claude Desktop, or consume external MCP servers:

```erlang
%% Connect to an external server
{ok, Client} = adk_mcp_client:connect(<<"stdio">>, <<"node server.js">>),
{ok, Tools} = adk_mcp_client:list_tools(Client),

%% Start an MCP server in Erlang
{ok, Server} = adk_mcp_server:start(<<"sse">>, [my_erlang_tool]),
```

#### Human-in-the-Loop (HITL)

Suspend execution and wait for human input using the built-in pause mechanism:

```erlang
adk_long_running_tool:execute(#{<<"action_summary">> => <<"Format Hard Drive">>}).
%% -> throws {adk_pause, human_in_the_loop, Summary}
```

## Observability (Telemetry)

The Erlang ADK uses the `telemetry` library. You can monitor latency via `[erlang_adk, agent, prompt, stop]` events. You can also use `adk_callbacks` for specific execution hooks (`on_agent_start`, `on_tool_start`, etc).

## Running the Demo

Compile and run the demo from inside the rebar3 shell:
```bash
$ export GEMINI_API_KEY="your_actual_key"
$ rebar3 shell
```
```erlang
1> c("examples/demo.erl").
2> demo:run().
```
