# Erlang ADK v0.2.4

An Erlang-native Agent Development Kit (ADK) designed to bring the capabilities of Google ADK 2.0 to the Erlang/OTP ecosystem. It leverages Erlang's robust OTP framework (processes, `gen_server`, and supervisors) to provide a scalable, observable, and highly concurrent multi-agent system.

It features native integration with Google Gemini, allowing your agents to interact with real LLMs.

---

## Features (ADK 2.0 Feature Parity)

1. **Agent-to-Agent Delegation**: Expose agents as tools via `adk_agent_tool`.
2. **Graph-based Orchestration**: Compose multiple agents into directed graphs with conditional branching using `adk_graph`.
3. **Tool Execution**: Agents can securely invoke functions or sub-agents defined in a module with `-behaviour(adk_tool)`.
4. **Session Management**: Built-in persistence for sessions across Mnesia, ETS, and state-scoping (`user:`, `app:`, `temp:` prefixes).
5. **Telemetry & Observability**: Standard `telemetry` events emitted for all agent lifecycles, enabling easy integration with Datadog/Prometheus.
6. **Event-Driven Architecture**: High-performance async runner loop emitting SSE-friendly ADK events.
7. **Human-in-the-Loop (HITL)**: First-class support for pausing agents to await human approval using `adk_long_running_tool`.
8. **Evaluation Framework**: Evaluate agent performance against datasets using `adk_eval`.
9. **Resiliency**: Built-in exponential backoff via `adk_retry`.
10. **MCP Integration**: Connect to external MCP servers for tool discovery via `adk_mcp_client`.
11. **Callbacks**: Hook into the execution lifecycle with `before_model`, `after_model`, etc., using `adk_callbacks`.

---

## Installation

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

---

## Quickstart

### Basic LLM Agent

Spawn an agent and prompt it:

```erlang
%% Define agent configuration
LLMConfig = #{
    provider => adk_llm_gemini,
    instructions => <<"You are a helpful weather assistant.">>,
    model => <<"gemini-2.5-flash">>
},

%% Spawn the agent (Name, LLMConfig, Tools)
{ok, Pid} = erlang_adk:spawn_agent("WeatherAgent", LLMConfig, [my_weather_tool]),

%% Prompt the agent synchronously
{ok, Response} = erlang_adk:prompt(Pid, "What is the weather in Tokyo?"),
io:format("Response: ~s~n", [Response]).
```

### Async Delegation

Fire-and-forget or receive results asynchronously:

```erlang
%% Fire and forget
ok = erlang_adk:delegate(Pid, "Do background task").

%% Receive reply when done
erlang_adk:delegate(Pid, "Summarize this", self()),
receive
    {agent_response, Pid, Result} -> io:format("Got: ~s~n", [Result])
end.
```

---

## Tools

Implement the `adk_tool` behaviour to expose functions to your agent. Each tool receives its arguments and a `Context` map containing `session_id`, `user_id`, and `state_ref`:

```erlang
-module(my_weather_tool).
-behaviour(adk_tool).
-export([schema/0, execute/2]).

schema() ->
    #{<<"name">> => <<"get_weather">>,
      <<"description">> => <<"Get current weather for a city">>,
      <<"parameters">> => #{
          <<"type">> => <<"object">>,
          <<"properties">> => #{
              <<"city">> => #{<<"type">> => <<"string">>}
          },
          <<"required">> => [<<"city">>]
      }}.

execute(#{<<"city">> := City}, _Context) ->
    {ok, <<"Sunny in ", City/binary>>}.
```

---

## Multi-Agent Systems

### Sequential & Parallel Orchestration

Manage multiple agents as sequential or parallel pipelines:

```erlang
{ok, Agent1} = erlang_adk:spawn_agent("Translator", #{provider => adk_llm_dummy, instructions => "Translate to French."}, []),
{ok, Agent2} = erlang_adk:spawn_agent("Summarizer", #{provider => adk_llm_dummy, instructions => "Summarize the text."}, []),

%% Run sequentially — output of Agent1 feeds into Agent2
{ok, Result} = erlang_adk:sequential([Agent1, Agent2], "Hello world").

%% Run in parallel — all agents receive the same prompt
Results = erlang_adk:parallel([Agent1, Agent2], "Hello world").
%% Returns [{Pid1, Response1}, {Pid2, Response2}]
```

### Iterative Loop (Worker/Reviewer Pattern)

```erlang
{ok, Worker} = erlang_adk:spawn_agent("Writer", #{provider => adk_llm_gemini}, []),
{ok, Reviewer} = erlang_adk:spawn_agent("Editor", #{provider => adk_llm_gemini}, []),

%% Worker drafts, Reviewer critiques, loop up to 3 times until "APPROVED"
{ok, FinalDraft} = erlang_adk:loop(Worker, Reviewer, "Write a poem about Erlang", 3).
```

### Sub-Agent Routing

Register sub-agents so the LLM can delegate to them as tools:

```erlang
{ok, SubAgent} = erlang_adk:spawn_agent("SearchAgent", #{provider => adk_llm_gemini}, [search_tool]),

%% Pass sub_agents map in config — keys are tool names the LLM will call
MasterConfig = #{
    provider => adk_llm_gemini,
    instructions => "You coordinate research tasks.",
    sub_agents => #{<<"SearchAgent">> => SubAgent}
},
{ok, Master} = erlang_adk:spawn_agent("Master", MasterConfig, []).
```

### Agent-as-Tool

Wrap an agent as a tool for explicit invocation:

```erlang
Config = #{name => <<"ResearchAgent">>, description => <<"Performs deep research">>},
Schema = adk_agent_tool:schema(Config),

%% Execute it
{ok, Result} = adk_agent_tool:execute(SubAgentPid, #{<<"prompt">> => <<"Find info on OTP">>}, #{}).
```

---

## Graph-Based Workflows

Agents and functions can be orchestrated using directed graphs with `adk_graph`, which decouple logic from LLM reasoning. This allows complex control flow (loops, branches, retries).

```erlang
%% 1. Create a new graph
G0 = adk_graph:new(),

%% 2. Define a function node
CounterFn = fun(State) ->
    #{<<"count">> => maps:get(<<"count">>, State, 0) + 1}
end,
G1 = adk_graph:add_node(G0, counter, CounterFn),

%% 3. Add a conditional edge
CondFn = fun(State) ->
    case maps:get(<<"count">>, State) < 3 of
        true -> counter;
        false -> end_node
    end
end,
G2 = adk_graph:add_conditional_edge(G1, counter, CondFn),

%% 4. Set entry point, compile, and run
G3 = adk_graph:set_entry_point(G2, counter),
{ok, Compiled} = adk_graph:compile(G3),
{ok, FinalState} = adk_graph:run(Compiled, #{<<"count">> => 0}).
%% FinalState = #{<<"count">> => 3}
```

---

## Human-in-the-Loop (HITL)

Pause execution mid-workflow to await human approval using `adk_long_running_tool`:

```erlang
%% 1. Include the HITL tool in your agent's tool list
{ok, Pid} = erlang_adk:spawn_agent("SafeAgent", LLMConfig, [adk_long_running_tool, my_tool]),

%% 2. When the LLM calls "request_human_approval", the runner pauses
%%    by throwing {adk_pause, human_in_the_loop, Summary}

%% 3. Resume with the Event-Driven Runner
Runner = adk_runner:new(Pid, <<"my_app">>, erlang_adk_session),
{ok, StreamPid} = adk_runner:resume(Runner, <<"user1">>, <<"sess1">>, <<"Approved">>).
```

---

## Event-Driven Runner (ADK 2.0 Architecture)

The `adk_runner` module provides the event-driven execution model:

```erlang
%% Create a runner
Runner = adk_runner:new(AgentPid, <<"my_app">>, erlang_adk_session),

%% Synchronous execution
{ok, Response} = adk_runner:run(Runner, <<"user1">>, <<"session1">>, <<"Hello">>).

%% Asynchronous execution — receive events as messages
{ok, StreamPid} = adk_runner:run_async(Runner, <<"user1">>, <<"session1">>, <<"Hello">>),
receive
    {adk_event, StreamPid, Event} -> io:format("Event: ~p~n", [Event]);
    {adk_done, StreamPid} -> io:format("Done!~n");
    {adk_error, StreamPid, Reason} -> io:format("Error: ~p~n", [Reason])
end.
```

---

## Session Management

### Scoped State Prefixes

ADK 2.0 introduces scoped state for managing data across sessions:

- **No prefix**: Session-scoped (cleared when the session ends)
- `<<"user:key">>`: User-scoped (shared across all sessions for a user)
- `<<"app:key">>`: App-scoped (shared globally across all users)
- `<<"temp:key">>`: Temporary (stripped after each interaction turn)

```erlang
StateDelta = #{
    <<"user:preferences">> => <<"dark_mode">>,
    <<"app:global_counter">> => 42,
    <<"temp:cache">> => <<"transient_data">>
},
erlang_adk_session:update_state(<<"MyApp">>, <<"User1">>, <<"SessionX">>, StateDelta).
```

### Session Storage Backends

```erlang
%% ETS-backed (default, in-memory)
{ok, Pid} = erlang_adk:spawn_agent("Agent", #{
    provider => adk_llm_dummy,
    session_id => my_session
}, []).

%% Mnesia-backed (persistent, distributed)
{ok, Pid} = erlang_adk:spawn_agent("Agent", #{
    provider => adk_llm_dummy,
    session_id => my_session,
    session_store => erlang_adk_session_mnesia
}, []).
```

---

## Observability (Telemetry)

The Erlang ADK instruments all major operations using the standard `telemetry` library:

**Events emitted:**
- `[erlang_adk, agent, prompt, start | stop]`
- `[erlang_adk, agent, delegate, start | stop]`
- `[erlang_adk, agent, run_with_events, start | stop]`

```erlang
Handler = fun(_Event, Measurements, Metadata, _Config) ->
    Duration = maps:get(duration, Measurements),
    AgentName = maps:get(agent, Metadata),
    io:format("Agent ~p took ~p ms~n", [AgentName, Duration])
end,
telemetry:attach(<<"my_handler">>, [erlang_adk, agent, prompt, stop], Handler, #{}).
```

---

## Callbacks

Hook into the execution lifecycle. Callbacks are fired around every LLM call:

```erlang
-module(my_audit_callback).
-export([before_model/3, after_model/2]).

before_model(Config, Memory, Tools) ->
    io:format("LLM call starting with ~p tools~n", [length(Tools)]),
    ok.

after_model(_Config, {Response, _Memory}) ->
    io:format("LLM responded: ~s~n", [Response]),
    ok.
```

Attach callbacks via agent config:
```erlang
LLMConfig = #{
    provider => adk_llm_gemini,
    callbacks => [my_audit_callback]
}.
```

---

## MCP Integration (Model Context Protocol)

Connect to external MCP servers to discover and use their tools:

```erlang
%% Connect via stdio (e.g., a Node.js MCP server)
{ok, Client} = adk_mcp_client:connect(<<"stdio">>, <<"node my_mcp_server.js">>),

%% List available tools
{ok, Tools} = adk_mcp_client:list_tools(Client),

%% Execute a specific tool
{ok, Result} = adk_mcp_client:execute_tool(Client, <<"search">>, #{<<"query">> => <<"erlang">>}),

%% Close connection
ok = adk_mcp_client:close(Client).
```

---

## Evaluation Framework

Test your agents against deterministic datasets:

```erlang
EvalConfig = #{
    criteria => #{tool_trajectory_avg_score => 0.8},
    match_type => <<"in_order">>
},
{ok, Results} = adk_eval:evaluate(AgentConfig, "test_data.json", EvalConfig).
```

---

## Retry with Exponential Backoff

Wrap flaky functions with robust retry logic:

```erlang
Fun = fun() -> flaky_network_call() end,
Opts = #{max_attempts => 5, initial_delay => 1000, backoff_factor => 2.0},
{ok, Result} = adk_retry:execute(Fun, Opts).
```

---

## Streaming

Stream LLM responses directly (useful for chat UIs):

```erlang
Callback = fun(Chunk) -> io:format("~s", [Chunk]) end,
ok = adk_llm:stream(LLMConfig, History, Tools, Callback).
```

---

## Testing

Run the full test suite:

```bash
rebar3 do clean, compile, eunit, ct, dialyzer
```
