# Erlang ADK v0.2.0

An Erlang-native Agent Development Kit (ADK) designed to bring the capabilities of Google ADK 2.0 to the Erlang/OTP ecosystem. It leverages Erlang's robust OTP framework (processes, `gen_server`, and supervisors) to provide a scalable, observable, and highly concurrent multi-agent system.

It features native integration with Google Gemini, allowing your agents to interact with real LLMs.

---

## Features (ADK 2.0 Feature Parity)

- **Graph-Based Workflows**: Decouple execution from LLMs using `adk_graph`. Build workflows with nodes, deterministic edges, and conditional branching.
- **Multi-Agent Systems**: Create teams of specialized agents that collaborate. An agent can act as a tool for another agent using `adk_agent_tool`.
- **Model Context Protocol (MCP)**: Connect agents to external data sources. Includes both an MCP Client (`adk_mcp_client`) and Server (`adk_mcp_server`).
- **Human-in-the-Loop (HITL)**: Built-in primitives to pause workflows mid-run (`adk_long_running_tool`), ask for human approval, and resume later.
- **Session Management**: Full state scoping (`user:`, `app:`, `temp:`) and session persistence via ETS or Mnesia (`adk_session_service`).
- **Long-term Semantic Memory**: Dedicated `adk_memory_service` for storing and searching past interactions across sessions.
- **Callbacks**: Hook into the execution lifecycle with `before_agent`, `after_tool`, etc., using `adk_callbacks`.
- **Streaming**: Stream Gemini responses directly via `gun` integration for low latency.
- **Evaluation Framework**: Evaluate agent performance against datasets using `adk_eval`.
- **Resiliency**: Built-in exponential backoff via `adk_retry`.
- **Agent Orchestrators**: Backward-compatible orchestrators (`sequential`, `parallel`, `loop`).
- **Agent-to-Agent (A2A)**: HTTP-based communication between agents.
- **Observability**: Built-in `telemetry` integration.

---

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

Before spawning an agent, make sure your API key is available:

```bash
export GEMINI_API_KEY="your_api_key_here"
```

### Basic LLM Agent

Spawn an agent and prompt it:

```erlang
%% Define agent configuration
Config = #{
    name => <<"WeatherAgent">>,
    description => <<"An agent that checks the weather.">>,
    model => <<"gemini-1.5-flash">>
},

%% Spawn the agent
{ok, Pid} = erlang_adk:spawn_agent(Config, [], [my_weather_tool]),

%% Prompt the agent
{ok, Response} = erlang_adk:prompt(Pid, <<"What is the weather in Tokyo?">>).
io:format("Response: ~s~n", [Response]).
```

---

## Graph-Based Workflows

Agents and functions can be orchestrated using Graph Workflows (`adk_graph`), which decouple logic from LLM reasoning. This allows complex control flow (loops, branches, retries).

```erlang
%% 1. Create a new graph
G0 = adk_graph:new(<<"MyWorkflow">>, []),

%% 2. Define a simple function node
NodeFn = fun(State) -> #{<<"count">> => maps:get(<<"count">>, State, 0) + 1} end,
G1 = adk_graph:add_node(G0, adk_graph_node:function_node(<<"increment">>, NodeFn)),

%% 3. Add a conditional edge
CondFn = fun(State) ->
    if maps:get(<<"count">>, State) < 3 -> <<"increment">>;
       true -> <<"end_node">>
    end
end,
G2 = adk_graph:add_edge(G1, <<"increment">>, cond_target, CondFn),

%% 4. Execute the workflow
{ok, Compiled} = adk_graph:compile(G2),
{ok, FinalState} = adk_graph:execute(Compiled, #{<<"count">> => 0}).
```

---

## Multi-Agent Systems & Agent-as-Tool

An entire agent can act as a tool for another agent using `adk_agent_tool`. This allows a master agent to delegate complex tasks to sub-agents.

```erlang
%% 1. Spawn a sub-agent
SubConfig = #{name => <<"ResearchAgent">>, description => <<"Finds info">>},
{ok, SubPid} = erlang_adk:spawn_agent(SubConfig, [], [search_tool]),

%% 2. Wrap it as a tool
AgentTool = adk_agent_tool:new(SubPid, #{skip_summarization => false}),

%% 3. Spawn a master agent equipped with the sub-agent
MasterConfig = #{name => <<"Master">>, description => <<"Coordinates research">>},
{ok, MasterPid} = erlang_adk:spawn_agent(MasterConfig, [], [AgentTool]),

%% 4. Prompt the master agent
{ok, Result} = erlang_adk:prompt(MasterPid, <<"Research quantum computing.">>).
```

---

## Human-in-the-Loop (HITL)

Suspend execution and wait for human input using the built-in pause mechanism (`adk_long_running_tool`). 

```erlang
%% 1. Wrap a dangerous tool to require human approval
SafeTool = adk_long_running_tool:new(format_hard_drive_tool),

%% 2. The agent executes it and pauses
Result = adk_tool:execute(SafeTool, #{<<"disk">> => <<"C:">>}),
%% -> returns {pending, PauseToken} and hibernates the agent

%% 3. The UI or a human reviews the action and resumes the agent
adk_runner:resume(Runner, UserId, SessionId, PauseToken, <<"Approved">>).
```

---

## Session Management

ADK 2.0 introduces Scoped State prefixes for advanced state management across turns:

- Keys without a prefix are **session-scoped** (cleared when the session ends).
- Keys starting with `<<"user:">>` are **user-scoped** (shared across all sessions for a user).
- Keys starting with `<<"app:">>` are **app-scoped** (shared globally across all users).
- Keys starting with `<<"temp:">>` are **temporary** (discarded after a single interaction turn).

```erlang
StateDelta = #{
    <<"user:preferences">> => <<"dark_mode">>,
    <<"temp:cache">> => <<"transient_data">>
},
adk_session_service:update_state(<<"MyApp">>, <<"User1">>, <<"SessionX">>, StateDelta).
```

---

## Long-term Memory

Automatically extract facts from sessions and index them into long-term memory for future retrieval.

```erlang
%% Add a completed session to long-term memory
adk_memory_service:add_session_to_memory(Session),

%% Later, search memory for context
{ok, Memories} = adk_memory_service:search(Pid, <<"user prefers dark mode">>, #{}, 5).
```

---

## MCP Integration

### MCP Client (Connecting to External Servers)

Connect to any external Model Context Protocol (MCP) server (e.g. running on Node.js or Python) and use its tools in Erlang.

```erlang
%% Connect via stdio
{ok, Client} = adk_mcp_client:connect(<<"stdio">>, <<"node server.js">>),

%% Wrap all external tools as Erlang ADK tools
McpTools = adk_mcp_client:as_adk_tools(Client),

%% Pass them to your agent
erlang_adk:spawn_agent(Config, [], McpTools).
```

### MCP Server (Exposing Agents as Tools)

Start an MCP server in Erlang to expose your agents and functions to MCP clients like Claude Desktop.

```erlang
%% Start an SSE MCP server exposing specific tools/agents
{ok, Server} = adk_mcp_server:start(<<"sse">>, [my_erlang_tool, AgentTool]),
```

---

## Callbacks

Hook into the lifecycle of agents and tools. Callbacks can even override tool results or skip execution entirely.

```erlang
-module(my_audit_callback).
-behaviour(adk_callbacks).

before_tool(ToolName, Args, _Context) ->
    io:format("Executing ~s with ~p~n", [ToolName, Args]),
    ok. %% Return {skip, Reason} to prevent execution
```

Attach callbacks via agent config:
```erlang
Config = #{callbacks => [my_audit_callback]},
```

---

## Evaluation Framework

Test your agents against deterministic JSON datasets.

```erlang
%% Define test configuration
EvalConfig = #{
    criteria => #{tool_trajectory_avg_score => 0.8},
    match_type => <<"in_order">>
},

%% Run the evaluation suite
{ok, Results} = adk_eval:evaluate(AgentConfig, "test_data.json", EvalConfig),
io:format("Score: ~p~n", [Results]).
```

---

## Streaming

Stream responses directly from the LLM (useful for chat UIs).

```erlang
Callback = fun(Chunk) -> io:format("~s", [Chunk]) end,
{ok, StreamPid} = adk_llm_gemini:stream(LLMConfig, History, Tools, Callback).
```

---

## Retry Configuration

Wrap tools or API calls with robust exponential backoff.

```erlang
%% Configure max 5 attempts, 1000ms base delay, 2.0x multiplier
RetryConf = adk_retry:new(#{max_attempts => 5, backoff_ms => 1000, backoff_mult => 2.0}),

%% Execute a flaky function
adk_retry:with_retry(fun() -> flaky_network_call() end, RetryConf).
```

---

## Observability (Telemetry)

The Erlang ADK uses the `telemetry` library. You can monitor latency and attach handlers to these events:

- `[erlang_adk, agent, prompt, start]`
- `[erlang_adk, agent, prompt, stop]` (includes duration)

```erlang
telemetry:attach(
    <<"my-agent-handler">>,
    [erlang_adk, agent, prompt, stop],
    fun(EventName, Measurements, Metadata, _Config) ->
        io:format("Agent took ~p microseconds~n", [maps:get(duration, Measurements)])
    end,
    []
).
```

---

## Testing

Run the full test suite using rebar3:

```bash
rebar3 do clean, compile, ct, dialyzer, ex_doc, edoc
```
