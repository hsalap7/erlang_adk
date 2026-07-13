# Erlang ADK v0.2.4

Erlang ADK is an experimental, Erlang-native toolkit for building Gemini-backed agents with OTP processes, supervision, tools, sessions, event streams, and concurrent multi-agent workflows.

The project follows the behavior of Google ADK where that behavior maps cleanly to Erlang. It is not a drop-in port and does not claim complete Google ADK feature parity. In particular, one agent is one `gen_server`: turns for that agent are serialized, while independent agents and orchestration branches can run concurrently in lightweight Erlang processes.

## Current scope

| Area | Status in v0.2.4 |
| --- | --- |
| Gemini text, function calling, thought signatures, call IDs, and SSE text streaming | Implemented |
| Erlang tools and agents exposed as model tools | Implemented |
| Sequential, parallel, worker/reviewer, and bounded graph workflows | Implemented |
| ETS/Mnesia sessions with session, user, app, and invocation-temp state | Implemented |
| Event Runner and human approval pause/resume | Implemented |
| Agent/model/tool callbacks and telemetry | Implemented; see callback notes below |
| Evaluation | Lightweight dataset plus metric runner, not Google ADK's full evaluation service |
| MCP | Initialized stdio client; SSE transport and a production MCP server are not implemented |
| HTTP agent endpoint | Simple project-specific JSON endpoint, not the Google A2A protocol |
| Artifacts and Runner-integrated long-term memory | Not implemented; the ETS memory service is standalone |

## Installation

Add the package to `rebar.config`:

```erlang
{deps, [
    {erlang_adk, "~> 0.2.4"}
]}.
```

Start the application before spawning agents:

```erlang
{ok, _StartedApps} = application:ensure_all_started(erlang_adk).
```

Gemini calls read `GEMINI_API_KEY`, or you can put `api_key` in the provider config. The environment variable avoids keeping a secret in source code:

```bash
export GEMINI_API_KEY="your_api_key_here"
```

The default model is the stable [Gemini 3.1 Flash-Lite](https://ai.google.dev/gemini-api/docs/models/gemini-3.1-flash-lite), `gemini-3.1-flash-lite`.

## Quickstart

The repository includes the tool used below. From `./rebar3 shell`:

```erlang
{ok, readme_weather_tool} = c("examples/readme_weather_tool.erl"),

LLMConfig = #{
    provider => adk_llm_gemini,
    instructions => <<"You are a concise weather assistant.">>,
    model => <<"gemini-3.1-flash-lite">>
},

{ok, WeatherPid} = erlang_adk:spawn_agent(
    <<"WeatherAgent">>, LLMConfig, [readme_weather_tool]),
{ok, WeatherResponse} = erlang_adk:prompt(
    WeatherPid, <<"What is the weather in Tokyo?">>),
io:format("~ts~n", [WeatherResponse]),
ok = erlang_adk:stop_agent(WeatherPid).
```

Provider-reported failures use `{error, Reason}`. A missing key, for example, returns `{error, missing_api_key}` rather than a successful error string.

Gemini provider configs may set `request_timeout` to a non-negative number of
milliseconds (or `infinity`). It bounds the complete non-streaming HTTP
request and each streaming connection/response/data wait. Omitting it keeps
the underlying `httpc` and Gun defaults. When calling Gemini through an agent,
keep this below the separate `agent_call_timeout` application setting (60
seconds by default). `request_timeout => infinity` removes only the transport
limit; direct `adk_llm` calls do not have the outer agent deadline.

Text returned by `prompt/2`, correlated delegation, orchestration helpers,
Runner, agent-as-tool, and the HTTP client is a UTF-8 binary. Use `~ts` to
print it as Unicode text; unlike a legacy Erlang charlist, it will not appear
as a list of integer code points in the shell or logs.

## Tools

A tool module implements `adk_tool` and returns `{ok, Value}` or `{error, Reason}` from `execute/2`:

```erlang
-module(readme_weather_tool).
-behaviour(adk_tool).

-export([schema/0, execute/2]).

schema() ->
    #{<<"name">> => <<"get_weather">>,
      <<"description">> => <<"Get the weather for a city">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"city">> => #{<<"type">> => <<"string">>}},
            <<"required">> => [<<"city">>]}}.

execute(#{<<"city">> := City}, Context) ->
    _ = Context,
    {ok, #{<<"city">> => City, <<"forecast">> => <<"sunny">>}}.
```

For agent-driven calls, `Context` contains `app_name`, `session_id`, `user_id`, `invocation_id`, `call_id`, and `state_ref` when available. Tool exceptions and `{error, Reason}` results are returned to the model as failed function responses instead of terminating the agent.

## Asynchronous delegation

Use a reference when several delegated requests may be in flight:

```erlang
AsyncConfig = #{provider => adk_llm_gemini,
                model => <<"gemini-3.1-flash-lite">>},
{ok, AsyncPid} = erlang_adk:spawn_agent(
    <<"AsyncAgent">>, AsyncConfig, []),
Ref = make_ref(),
ok = erlang_adk:delegate(
    AsyncPid, <<"Summarize OTP in one sentence.">>, self(), Ref),
receive
    {agent_response, Ref, AsyncPid, {ok, AsyncResponse}} ->
        io:format("~ts~n", [AsyncResponse]);
    {agent_response, Ref, AsyncPid, {error, AsyncReason}} ->
        io:format("delegation failed: ~p~n", [AsyncReason])
after 60000 ->
    exit(delegate_timeout)
end,
ok = erlang_adk:stop_agent(AsyncPid).
```

`delegate/2` is fire-and-forget. The older `delegate/3` message format remains supported, but `delegate/4` is the safe choice for correlation.

## Concurrent multi-agent workflows

Sequential execution feeds each response into the next agent. Parallel execution creates monitored Erlang workers, preserves input order, and applies one overall timeout:

```erlang
{ok, TranslatorPid} = erlang_adk:spawn_agent(
    <<"Translator">>,
    #{provider => adk_llm_gemini,
      instructions => <<"Translate the input to French.">>}, []),
{ok, SummarizerPid} = erlang_adk:spawn_agent(
    <<"Summarizer">>,
    #{provider => adk_llm_gemini,
      instructions => <<"Summarize the input in one sentence.">>}, []),

{ok, PipelineResult} = erlang_adk:sequential(
    [TranslatorPid, SummarizerPid], <<"Erlang processes are lightweight.">>),
ParallelResults = erlang_adk:parallel(
    [TranslatorPid, SummarizerPid], <<"Explain OTP.">>, 60000),
io:format("pipeline=~ts parallel=~p~n",
          [PipelineResult, ParallelResults]),

ok = erlang_adk:stop_agent(TranslatorPid),
ok = erlang_adk:stop_agent(SummarizerPid).
```

Each parallel result is `{AgentPid, Response}` or `{AgentPid, {error, Reason}}`. Requests to the same agent PID still serialize in that agent's mailbox; concurrency comes from using independent agents.

The bounded worker/reviewer loop treats a response as approval only when, after trimming and case normalization, it is exactly `APPROVED`. It also stops at the iteration bound and then returns the latest draft, even if the reviewer has not approved it:

```erlang
{ok, WriterPid} = erlang_adk:spawn_agent(
    <<"Writer">>,
    #{provider => adk_llm_gemini,
      instructions => <<"Write and revise the requested draft.">>}, []),
{ok, ReviewerPid} = erlang_adk:spawn_agent(
    <<"Reviewer">>,
    #{provider => adk_llm_gemini,
      instructions => <<"Reply exactly APPROVED when the draft is ready; otherwise critique it.">>}, []),
{ok, FinalDraft} = erlang_adk:loop(
    WriterPid, ReviewerPid, <<"Write a short poem about Erlang.">>, 3),
io:format("~ts~n", [FinalDraft]),
ok = erlang_adk:stop_agent(WriterPid),
ok = erlang_adk:stop_agent(ReviewerPid).
```

## Sub-agents and agent-as-tool

Sub-agents are advertised to the model as function declarations. A description helps the coordinator route well:

```erlang
{ok, SearchPid} = erlang_adk:spawn_agent(
    <<"SearchSpecialist">>,
    #{provider => adk_llm_gemini,
      instructions => <<"Research the requested Erlang topic.">>}, []),
CoordinatorConfig = #{
    provider => adk_llm_gemini,
    instructions => <<"Delegate research tasks to SearchSpecialist.">>,
    sub_agents => #{
        <<"SearchSpecialist">> =>
            #{pid => SearchPid,
              description => <<"Researches Erlang and OTP topics">>}
    }
},
{ok, CoordinatorPid} = erlang_adk:spawn_agent(
    <<"Coordinator">>, CoordinatorConfig, []),
{ok, CoordinatedResponse} = erlang_adk:prompt(
    CoordinatorPid, <<"Research supervision trees.">>),
io:format("~ts~n", [CoordinatedResponse]),

AgentToolSchema = adk_agent_tool:schema(
    #{name => <<"SearchSpecialist">>,
      description => <<"Researches Erlang and OTP topics">>}),
{ok, DirectSpecialistResponse} = adk_agent_tool:execute(
    SearchPid, #{<<"prompt">> => <<"Explain rest_for_one.">>}, #{}),
io:format("schema=~p response=~ts~n",
          [AgentToolSchema, DirectSpecialistResponse]),

ok = erlang_adk:stop_agent(CoordinatorPid),
ok = erlang_adk:stop_agent(SearchPid).
```

The coordinator resolves a restarted sub-agent by its registered binary name, so a stale child PID does not have to crash the parent agent.

## Graph workflows

Graphs are deterministic Erlang workflows. Compilation validates the entry point and deterministic edges; execution has a cycle bound:

```erlang
Graph0 = adk_graph:new(),
Increment = fun(State) ->
    #{<<"count">> => maps:get(<<"count">>, State, 0) + 1}
end,
Graph1 = adk_graph:add_node(Graph0, counter, Increment),
Next = fun(State) ->
    case maps:get(<<"count">>, State) < 3 of
        true -> counter;
        false -> end_node
    end
end,
Graph2 = adk_graph:add_conditional_edge(Graph1, counter, Next),
Graph3 = adk_graph:set_entry_point(Graph2, counter),
{ok, CompiledGraph} = adk_graph:compile(Graph3),
{ok, FinalState} = adk_graph:run(
    CompiledGraph, #{<<"count">> => 0}, #{max_steps => 10}),
3 = maps:get(<<"count">>, FinalState).
```

`adk_graph_node:agent_node/3`, `function_node/1`, and `tool_node/1` are helpers for event-based graphs. Agent nodes include configured instructions and model callbacks.

## Event Runner

The Runner stores user, model, and tool events in one session and clears `temp:` state only at a final or error boundary:

```erlang
RunnerConfig = #{provider => adk_llm_gemini,
                 instructions => <<"Be concise.">>},
{ok, RunnerAgentPid} = erlang_adk:spawn_agent(
    <<"RunnerAgent">>, RunnerConfig, []),
Runner = adk_runner:new(
    RunnerAgentPid, <<"readme_app">>, erlang_adk_session,
    #{run_timeout => 120000}),
{ok, RunnerResponse} = adk_runner:run(
    Runner, <<"user-1">>, <<"session-1">>, <<"Hello">>),
io:format("~ts~n", [RunnerResponse]).
```

`run_timeout` is the overall synchronous Runner deadline. Each model round invoked through `adk_agent:run_with_events/3` has a separate 60-second `gen_server` call limit by default, so a larger Runner deadline can cover several model/tool rounds but does not itself extend one model round. Applications that need a different outer limit can set the `erlang_adk` application environment key `agent_call_timeout` to a non-negative number of milliseconds (or `infinity`); `adk_agent:prompt/2` and `run_with_events/3` both use it.

Use one active Runner invocation per session. Independent agents and sessions can run concurrently, but sharing one session between simultaneous invocations can interleave event history and invocation-temp state.

For asynchronous runs, drain messages until exactly one terminal message arrives:

```erlang
Drain = fun Loop(StreamPid) ->
    receive
        {adk_event, StreamPid, Event} ->
            io:format("event: ~p~n", [adk_event:to_map(Event)]),
            Loop(StreamPid);
        {adk_done, StreamPid} -> ok;
        {adk_paused, StreamPid, PauseEvent} -> {paused, PauseEvent};
        {adk_error, StreamPid, Reason} -> {error, Reason}
    after 120000 ->
        {error, timeout}
    end
end,
{ok, StreamPid} = adk_runner:run_async(
    Runner, <<"user-1">>, <<"session-2">>, <<"Explain supervisors.">>),
ok = Drain(StreamPid),
ok = erlang_adk:stop_agent(RunnerAgentPid).
```

## Human approval pause/resume

Add `adk_long_running_tool` to let the model request approval. A pause is a distinct terminal result, not an error. Resume records a matching function response with the original invocation ID, thought signature, and Gemini function-call ID:

```erlang
ApprovalConfig = #{
    provider => adk_llm_gemini,
    instructions =>
        <<"Before any destructive action, call request_human_approval.">>
},
{ok, ApprovalPid} = erlang_adk:spawn_agent(
    <<"ApprovalAgent">>, ApprovalConfig, [adk_long_running_tool]),
ApprovalRunner = adk_runner:new(
    ApprovalPid, <<"readme_app">>, erlang_adk_session),
ApprovalDrain = fun Loop(ApprovalStreamPid) ->
    receive
        {adk_event, ApprovalStreamPid, ApprovalEvent} ->
            io:format("event: ~p~n", [adk_event:to_map(ApprovalEvent)]),
            Loop(ApprovalStreamPid);
        {adk_done, ApprovalStreamPid} -> ok;
        {adk_paused, ApprovalStreamPid, NextPause} -> {paused, NextPause};
        {adk_error, ApprovalStreamPid, ResumeReason} -> {error, ResumeReason}
    after 120000 ->
        {error, timeout}
    end
end,
ApprovalResult = adk_runner:run(
    ApprovalRunner, <<"user-1">>, <<"approval-session">>,
    <<"Delete the obsolete deployment.">>),
case ApprovalResult of
    {paused, PauseEvent} ->
        io:format("approval requested: ~p~n", [adk_event:to_map(PauseEvent)]),
        {ok, ResumePid} = adk_runner:resume(
            ApprovalRunner, <<"user-1">>, <<"approval-session">>,
            #{approved => true, approver => <<"operator@example.com">>}),
        ok = ApprovalDrain(ResumePid);
    {ok, UnexpectedFinal} ->
        io:format("model completed without pausing: ~ts~n", [UnexpectedFinal]);
    {error, ApprovalReason} ->
        io:format("approval workflow failed: ~p~n", [ApprovalReason])
end,
ok = erlang_adk:stop_agent(ApprovalPid).
```

Only one concurrent caller can claim a paused continuation. A second resume returns `{error, no_paused_invocation}`. Temp state is retained while paused and removed after the resumed invocation completes or fails.

## Session state

State prefixes have these lifetimes:

- no prefix: one session;
- `user:`: future and existing sessions for the same app/user;
- `app:`: future and existing sessions for the same app;
- `temp:`: one Runner invocation, retained across a pause but cleared at final/error.

Create a session before updating it:

```erlang
ok = erlang_adk_session:init(),
AppName = <<"state_demo">>,
UserId = <<"user-1">>,
SessionId = <<"state-session-1">>,
{ok, _CreatedSession} = erlang_adk_session:create_session(
    AppName, UserId, #{session_id => SessionId}),
ok = erlang_adk_session:update_state(
    AppName, UserId, SessionId,
    #{<<"theme">> => <<"local">>,
      <<"user:preferences">> => <<"dark">>,
      <<"app:release">> => <<"0.2.4">>,
      <<"temp:lookup">> => <<"in-flight">>}),
{ok, StoredSession} = erlang_adk_session:get_session(
    AppName, UserId, SessionId),
StoredState = maps:get(state, StoredSession),
<<"dark">> = maps:get(<<"user:preferences">>, StoredState),

{ok, FutureSession} = erlang_adk_session:create_session(
    AppName, UserId, #{session_id => <<"state-session-2">>}),
FutureState = maps:get(state, FutureSession),
<<"dark">> = maps:get(<<"user:preferences">>, FutureState),
<<"0.2.4">> = maps:get(<<"app:release">>, FutureState),
error = maps:find(<<"theme">>, FutureState),

ok = erlang_adk_session:clear_temp_state(AppName, UserId, SessionId),
ok = erlang_adk_session:delete_session(AppName, UserId, SessionId),
ok = erlang_adk_session:delete_session(
    AppName, UserId, <<"state-session-2">>).
```

`update_state/4` and `add_event/4` return `{error, not_found}` for a missing session. Creation is idempotent and does not overwrite an existing session during concurrent first use.

For a local disk-backed Mnesia session backend, initialize Mnesia and pass it to the Runner:

```erlang
ok = erlang_adk_session_mnesia:init(),
{ok, PersistentAgentPid} = erlang_adk:spawn_agent(
    <<"PersistentAgent">>, #{provider => adk_llm_gemini}, []),
MnesiaRunner = adk_runner:new(
    PersistentAgentPid, <<"persistent_app">>, erlang_adk_session_mnesia),
{ok, PersistentResponse} = adk_runner:run(
    MnesiaRunner, <<"user-1">>, <<"persistent-session">>, <<"Hello">>),
io:format("~ts~n", [PersistentResponse]),
ok = erlang_adk:stop_agent(PersistentAgentPid).
```

`init/0` creates `disc_copies` on the current node only. A distributed deployment must separately configure the Mnesia cluster and add table replicas on the other nodes.

The older agent `session_id` option persists that agent's conversation history through the backend's legacy `save/2` and `load/1` API. Runner sessions are the recommended event/state API.

## Callbacks and telemetry

The repository callback example uses the actual provider-result contract:

```erlang
-module(readme_audit_callback).
-behaviour(adk_callbacks).

-export([before_model/3, after_model/2, before_tool/3, after_tool/4]).

before_model(Config, _Memory, Tools) ->
    notify(Config, {before_model, length(Tools)}),
    ok.

after_model(Config, ProviderResult) ->
    notify(Config, {after_model, ProviderResult}),
    ok.

before_tool(_ToolName, _Args, _Context) -> ok.
after_tool(_ToolName, _Args, _Context, _ToolResult) -> ok.

notify(Config, Message) ->
    case maps:get(callback_pid, Config, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.
```

Attach it to an agent:

```erlang
{ok, readme_audit_callback} = c("examples/readme_audit_callback.erl"),
CallbackConfig = #{provider => adk_llm_gemini,
                   callbacks => [readme_audit_callback],
                   callback_pid => self()},
{ok, CallbackPid} = erlang_adk:spawn_agent(
    <<"CallbackAgent">>, CallbackConfig, []),
{ok, _CallbackResponse} = erlang_adk:prompt(
    CallbackPid, <<"Say hello.">>),
receive {before_model, ToolCount} -> io:format("~p tools~n", [ToolCount]) end,
receive {after_model, ProviderResult} -> io:format("~p~n", [ProviderResult]) end,
ok = erlang_adk:stop_agent(CallbackPid).
```

Before-hooks return `ok`/`continue`, `{halt, ProviderResult}` to skip the operation, or `{replace, Value}`. After-hooks can return `{replace, Value}`. Callback modules are loaded on demand; callback exceptions are logged and do not crash the agent.

Prompt, delegation, and event-model calls emit telemetry. This example observes completed prompts:

```erlang
TelemetryHandler = fun(_Event, Measurements, Metadata, _Config) ->
    io:format("agent=~p duration_ms=~p~n",
              [maps:get(agent, Metadata), maps:get(duration, Measurements)])
end,
_ = telemetry:detach(<<"readme-prompt-handler">>),
ok = telemetry:attach(
    <<"readme-prompt-handler">>,
    [erlang_adk, agent, prompt, stop], TelemetryHandler, #{}),
{ok, TelemetryPid} = erlang_adk:spawn_agent(
    <<"TelemetryAgent">>, #{provider => adk_llm_gemini}, []),
{ok, _TelemetryResponse} = erlang_adk:prompt(
    TelemetryPid, <<"Say hello.">>),
ok = telemetry:detach(<<"readme-prompt-handler">>),
ok = erlang_adk:stop_agent(TelemetryPid).
```

## Gemini streaming

Streaming invokes the callback once per decoded text delta rather than once with a buffered raw SSE body:

```erlang
StreamConfig = #{provider => adk_llm_gemini,
                 model => <<"gemini-3.1-flash-lite">>},
StreamHistory = [
    #{role => system, content => <<"Be concise.">>},
    #{role => user, content => <<"Explain OTP in two sentences.">>}
],
ChunkCallback = fun(Chunk) -> io:format("~ts", [Chunk]) end,
StreamResult = adk_llm:stream(
    StreamConfig, StreamHistory, [], ChunkCallback),
case StreamResult of
    ok -> io:format("~n");
    {tool_calls, StreamCalls} -> io:format("tool calls: ~p~n", [StreamCalls]);
    {error, StreamReason} -> io:format("stream failed: ~p~n", [StreamReason])
end.
```

Both regular and streaming Gemini requests validate HTTP status codes, use `x-goog-api-key`, verify TLS certificates/hostnames, send `parts` as arrays, and preserve thought signatures plus function-call IDs.

## MCP stdio client

`connect/2` performs the MCP initialize handshake before returning. This repository-verifiable example uses the included line-delimited JSON-RPC fixture; replace the command with your own stdio MCP server in production:

```erlang
FixtureCommand = unicode:characters_to_binary(
    filename:absname("test/mcp_stdio_fixture.sh")),
{ok, McpClient} = adk_mcp_client:connect(
    <<"stdio">>, FixtureCommand),
{ok, [McpTool]} = adk_mcp_client:list_tools(McpClient),
<<"search">> = maps:get(<<"name">>, McpTool),
{ok, McpResult} = adk_mcp_client:execute_tool(
    McpClient, <<"search">>, #{<<"query">> => <<"erlang">>}),
false = maps:get(<<"isError">>, McpResult),
ok = adk_mcp_client:close(McpClient).
```

Only the client-side stdio transport is supported. `connect(<<"sse">>, Url)` returns `{error, {unsupported_transport, sse}}`. `adk_mcp_server:start/2` returns an explicit `{error, {not_implemented, ...}}`; no production MCP server is included.

## Evaluation

`adk_eval` runs rows against an existing agent and applies a metric function:

```erlang
{ok, EvalPid} = erlang_adk:spawn_agent(
    <<"EvalAgent">>,
    #{provider => adk_llm_gemini,
      instructions => <<"Follow the requested output format exactly.">>}, []),
Dataset = [
    #{input => <<"Reply with exactly: ERLANG">>,
      expected => <<"ERLANG">>, metadata => #{case_id => 1}}
],
ExactMetric = fun(Expected, Actual) ->
    case unicode:characters_to_binary(Actual) =:= Expected of
        true -> 1.0;
        false -> 0.0
    end
end,
{ok, EvalReport} = adk_eval:run(
    EvalPid, Dataset, ExactMetric,
    #{concurrency => 1, timeout => 60000}),
io:format("~p~n", [EvalReport]),
ok = erlang_adk:stop_agent(EvalPid).
```

Rows share the supplied stateful agent and therefore share its conversation history. Evaluator worker concurrency does not make one `gen_server` process concurrent; use separate agents/sessions when cases must be isolated. The timeout is enforced by monitored evaluator workers for both sequential and parallel batches.

## Retry and standalone memory

A deterministic retry example:

```erlang
AttemptCounter = atomics:new(1, []),
Flaky = fun() ->
    case atomics:add_get(AttemptCounter, 1, 1) of
        Attempt when Attempt < 3 -> {error, temporary};
        _ -> {ok, recovered}
    end
end,
{ok, recovered} = adk_retry:execute(
    Flaky,
    #{max_attempts => 5, initial_delay => 1,
      max_delay => 10, backoff_factor => 2.0}).
```

The ETS memory service performs simple case-insensitive substring search with exact metadata filtering; it is not a vector database and is not automatically wired into Runner:

```erlang
{ok, MemoryPid} = adk_memory_ets:init(#{}),
{ok, MemoryId} = adk_memory_ets:add(
    MemoryPid, <<"OTP supervision trees restart children">>,
    #{<<"topic">> => <<"otp">>}),
{ok, [MemoryHit]} = adk_memory_ets:search(
    MemoryPid, <<"supervision">>, #{<<"topic">> => <<"otp">>}, 5),
MemoryId = maps:get(id, MemoryHit),
ok = adk_memory_ets:delete(MemoryPid, MemoryId),
ok = adk_memory_ets:stop(MemoryPid).
```

## Simple HTTP endpoint

The application can expose `POST /a2a/prompt` for this project's small JSON protocol. Listener settings are read only when the application starts. Because this repository's `rebar3 shell` starts `erlang_adk` automatically, stop the application before changing those settings (the default listener already uses port 8080):

```erlang
_ = application:stop(erlang_adk),
ok = application:set_env(erlang_adk, a2a_enabled, true),
ok = application:set_env(erlang_adk, a2a_port, 8080),
{ok, _} = application:ensure_all_started(erlang_adk),
{ok, HttpAgentPid} = erlang_adk:spawn_agent(
    <<"HttpAgent">>, #{provider => adk_llm_gemini}, []),
{ok, HttpResponse} = erlang_adk_a2a_client:prompt(
    "http://localhost:8080/a2a/prompt",
    <<"HttpAgent">>, <<"Hello from HTTP">>),
io:format("~ts~n", [HttpResponse]),
ok = erlang_adk:stop_agent(HttpAgentPid).
```

This endpoint is not wire-compatible with the Google A2A protocol.

## Verification

Run the complete local suite with the repository's bundled Rebar3:

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
```

Run the focused deterministic README smoke suite with:

```bash
./rebar3 eunit --module=readme_examples_test
```

Run the opt-in live Gemini suite after exporting `GEMINI_API_KEY` with:

```bash
ERLANG_ADK_LIVE_GEMINI=1 ./rebar3 ct \
  --suite test/readme_live_gemini_SUITE.erl
```

The live suite uses `gemini-3.1-flash-lite` and exercises text generation, function calling, SSE streaming, correlated delegation, concurrent orchestration, sub-agents, Runner sync/async, human approval, Mnesia Runner storage, callbacks, telemetry, evaluation, and the HTTP endpoint. It is skipped unless explicitly enabled because it uses network access, quota, and billable API calls.

Some scenarios require multiple model turns, so the complete live suite makes roughly 23 Gemini requests. By default, its test-only provider wrapper spaces request starts by 4.2 seconds, caps each transport wait at 15 seconds, and retries one non-streaming transport timeout. The suite raises only its own agent call timeout to 120 seconds; the production default remains 60 seconds. HTTP 429 responses are returned promptly rather than sleeping inside an agent and risking a caller timeout. The pacing accommodates a 15-requests-per-minute project limit without changing production request scheduling or the Erlang concurrency model. API limits are project-specific; accounts with a higher limit can shorten or disable the test pacing, for example:

```bash
ERLANG_ADK_LIVE_GEMINI=1 \
ERLANG_ADK_LIVE_GEMINI_INTERVAL_MS=0 \
./rebar3 ct --suite test/readme_live_gemini_SUITE.erl
```

Keep the default interval on free-tier projects. Exhausted daily quota, project traffic outside this suite, or persistent account-level limits still fail explicitly instead of looping indefinitely.

The focused suite compiles the example modules and directly exercises deterministic versions of the core agent, delegation, orchestration, graph, Runner, session, callback, stream, MCP, evaluation, retry, and memory examples. HITL, Mnesia, the project-specific HTTP endpoint, and Gemini HTTP/SSE wire behavior are covered by their dedicated EUnit modules in the complete suite above; the focused suite only checks that those dedicated modules are present. A live Gemini quickstart still requires your own `GEMINI_API_KEY`, network access, quota, and may produce nondeterministic natural-language text.
