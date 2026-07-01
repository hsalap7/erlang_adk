# Erlang ADK

An Erlang-native Agent Development Kit (ADK) inspired by Google ADK. It leverages Erlang's robust OTP framework (processes, `gen_server`, and supervisors) to provide a scalable and observable multi-agent system.

It features native integration with Google Gemini, allowing your agents to interact with real LLMs.

## Features

- **OTP-Native**: Agents are highly concurrent, fault-tolerant `gen_server` processes.
- **Supervision**: Managed by dynamically scaling `simple_one_for_one` supervisors.
- **Pluggable LLMs**: A clean `adk_llm` behaviour for swapping LLM providers. Currently includes native support for Google Gemini.
- **Memory Management**: Agents maintain state and conversational history automatically.
- **Agent Orchestrators**: Compose agents together with native `Sequential`, `Parallel`, and `Loop` topologies.
- **Session Persistence**: Built-in ETS-backed (in-memory) and Mnesia-backed (disk-distributed) memory storage allows agents to crash and recover their conversational memory seamlessly.
- **Agent-to-Agent (A2A) Communication**: Remote collaboration between agents via HTTP.
- **Observability**: Built-in Telemetry hooks for monitoring agent latency and LLM generation times.

## Quickstart

Add `erlang_adk` as a dependency in your `rebar.config`:

```erlang
{deps, [
    erlang_adk
]}.
```

Ensure the application is started in your code:

```erlang
application:ensure_all_started(erlang_adk).
```

### Usage

Before spawning an agent that uses Gemini, make sure your API key is available in your system environment variables:

```bash
export GEMINI_API_KEY="your_api_key_here"
```

Alternatively, you can pass the API key explicitly in the agent's configuration map.

#### Sample Configuration

To spawn an agent, you define an `LLMConfig` map. This allows you to configure "all the bells and whistles" for the underlying model.

```erlang
LLMConfig = #{
    %% Required: The provider module
    provider => adk_llm_gemini,
    
    %% Required: The system instructions for the agent
    instructions => "You are a senior Erlang engineer. Be concise and helpful.",
    
    %% Optional: LLM Generation parameters
    temperature => 0.7,
    max_tokens => 1024,
    top_p => 0.9,
    top_k => 40,
    
    %% Optional: Specific model version (Defaults to gemini-1.5-flash)
    model => <<"gemini-1.5-pro">>,
    
    %% Optional: Pass API key directly instead of using GEMINI_API_KEY env var
    api_key => <<"AIzaSyYourKeyHere...">>,
    
    %% Optional: Session ID for memory persistence (ETS by default)
    session_id => my_persistent_session_id,
    
    %% Optional: Session store backend (defaults to erlang_adk_session for ETS)
    %% To use Mnesia for disk-distributed persistence, set it here:
    session_store => erlang_adk_session_mnesia
}.
```

#### Spawning and Prompting an Agent

Use the `erlang_adk` module to interact with the framework:

```erlang
%% 1. Spawn the agent
%% Note: The 3rd argument is a list of tools (e.g., custom Erlang modules implementing adk_tool)
{ok, Pid} = erlang_adk:spawn_agent("ErlangExpert", LLMConfig, []).

%% 2. Synchronously prompt the agent (waits for a response)
{ok, Response} = erlang_adk:prompt(Pid, "Explain OTP Supervisors in one sentence.").
io:format("~ts~n", [Response]).

%% 3. Asynchronously delegate a task (fire and forget)
erlang_adk:delegate(Pid, "Read through the logs and cache the errors in the DB.").

%% 4. Asynchronously delegate and get notified via message passing when done
erlang_adk:delegate(Pid, "Write a long report...", self()),

%% ... later in your application code ...
receive
    {agent_response, Pid, AsyncResponse} ->
        io:format("Background agent finished!~n~ts~n", [AsyncResponse])
after 10000 ->
    io:format("Still waiting...~n")
end.
```

#### Tools / Function Calling

Agents can be equipped with custom Erlang modules that act as tools (functions the LLM can call). To create a tool, create a module that exports `schema/0` and `execute/1`:

```erlang
-module(my_weather_tool).
-export([schema/0, execute/1]).

schema() ->
    #{<<"name">> => <<"get_weather">>,
      <<"description">> => <<"Get the current weather for a location">>,
      <<"parameters">> => 
          #{<<"type">> => <<"OBJECT">>,
            <<"properties">> => 
                #{<<"location">> => #{<<"type">> => <<"STRING">>}},
            <<"required">> => [<<"location">>]}
     }.

execute(#{<<"location">> := Location}) ->
    %% Call a weather API here...
    #{<<"temperature">> => <<"72F">>, <<"condition">> => <<"Sunny">>}.
```

Pass the tool module when spawning the agent:
```erlang
{ok, WeatherBot} = erlang_adk:spawn_agent("WeatherBot", LLMConfig, [my_weather_tool]).

%% The agent will automatically call your Erlang code under the hood!
erlang_adk:prompt(WeatherBot, "What's the weather like in Tokyo?").
```

#### Agent Orchestrators

You can compose multiple agents into complex workflows:

```erlang
%% Sequential Pipeline: Pass output from Agent 1 to Agent 2
{ok, FinalResult} = erlang_adk:sequential([Agent1Pid, Agent2Pid], "Initial Prompt").

%% Parallel Execution: Fan out requests concurrently
Results = erlang_adk:parallel([Agent1Pid, Agent2Pid], "Research topic X").
%% Results is [{Agent1Pid, Response1}, {Agent2Pid, Response2}]

%% Loop / Refiner: Worker writes, Reviewer critiques. Repeats up to MaxIterations.
{ok, ApprovedDraft} = erlang_adk:loop(WorkerPid, ReviewerPid, "Write an essay", 3).
```

## Observability (Telemetry)

The Erlang ADK uses the `telemetry` library to emit events, allowing you to monitor agent latencies and interactions easily.

For example, `adk_agent.erl` emits the following events when processing prompts:
- `[erlang_adk, agent, prompt, start]`
- `[erlang_adk, agent, prompt, stop]` (includes duration measurements)

To monitor these events, you can attach a telemetry handler in your application. Here is a quick Erlang snippet demonstrating how to attach a `telemetry:attach/4` handler:

```erlang
%% Define your handler function
handle_event([erlang_adk, agent, prompt, stop], Measurements, _Metadata, _Config) ->
    Duration = maps:get(duration, Measurements),
    %% You can log the duration or send it to a metrics backend
    io:format("Agent prompt finished in ~p native time units~n", [Duration]).

%% Attach the handler (e.g., during your application startup)
telemetry:attach(
    <<"my-adk-telemetry-handler">>,
    [erlang_adk, agent, prompt, stop],
    fun ?MODULE:handle_event/4,
    #{}
).
```

## Agent-to-Agent (A2A) Communication

The Erlang ADK supports remote Agent-to-Agent communication over HTTP, allowing agents distributed across different nodes or microservices to collaborate. The ADK spins up a Cowboy HTTP listener on port `8080` to accept remote prompts.

### Calling a Remote Agent

If an agent named `"Alice"` is running on a server at `http://agent-node:8080`, you can prompt it remotely from another node using the `erlang_adk_a2a_client`:

```erlang
Url = "http://agent-node:8080/a2a/prompt",
case erlang_adk_a2a_client:prompt(Url, "Alice", "Hello from a remote node!") of
    {ok, Response} -> io:format("Alice says: ~ts~n", [Response]);
    {error, Reason} -> io:format("A2A Error: ~p~n", [Reason])
end.
```

## Running the Demo

This project includes a multi-agent demo (`examples/demo.erl`) where an "Alice" Writer agent and a "Bob" Reviewer agent collaborate.

To run it, start the rebar3 shell:
```bash
$ export GEMINI_API_KEY="your_actual_key"
$ rebar3 shell
```

Then compile and run the demo from inside the shell:
```erlang
1> c("examples/demo.erl").
{ok,demo}
2> demo:run().
```
