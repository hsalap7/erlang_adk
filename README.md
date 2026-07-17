# Erlang ADK

Erlang ADK (Agent Development Kit) helps you build AI agents in Erlang. An
agent can ask a model for a response, call Erlang functions, remember session
data, stream progress, and work with other agents. The project supports
Gemini, OpenAI, Anthropic, and selected OpenAI-compatible APIs.

Agents and workflows use Erlang's lightweight processes, supervision, and
message passing. The project follows useful behavior from Google ADK, but it
is designed for OTP rather than copied from the Python package.

## What you can build

| If you want to... | Use | Start here |
| --- | --- | --- |
| Build an agent that can call Erlang code | Agents and tools | [Your first agent](#your-first-agent), [Add an Erlang tool](#add-an-erlang-tool) |
| Switch between model companies or endpoints | Gemini, OpenAI, Anthropic, compatible APIs, and named provider settings | [Choose a model provider](#choose-a-model-provider) |
| Split work between agents | Delegation, sequential agents, and concurrent agents | [Run multiple agents](#run-multiple-agents) |
| Control a multi-step job in application code | Sequential, parallel, loop, transfer, graph, and resumable workflows | [Run a workflow](#run-a-workflow) |
| Keep a run's events and allow pause, resume, or cancellation | The Runner and supervised runs | [Use the Runner](#use-the-runner) |
| Ask a person before a sensitive action | Human approval and resumable work | [Human approval and long-running work](#human-approval-and-long-running-work) |
| Work with text, images, audio, or image/video frames | Streaming and media input | [Streaming and multimodal input](#streaming-and-multimodal-input) |
| Build a two-way voice experience | Gemini Live, OpenAI Realtime, and one supervised Erlang process per session | [Realtime sessions and browser voice](#realtime-sessions-and-browser-voice) |
| Save conversations, files, memory, or model context | Session, artifact, memory, and context services | [Sessions, artifacts, memory, and context](#sessions-artifacts-memory-and-context) |
| Connect APIs, MCP servers, or other agents | OpenAPI, Model Context Protocol (MCP), and Agent2Agent (A2A) | [Integrations](#integrations) |
| Monitor and test agent behavior | Plugins, OpenTelemetry metrics/traces, and evaluations | [Plugins, observability, and evaluation](#plugins-observability-and-evaluation) |
| Sign users in and authorize tool access | OpenID Connect (OIDC), JSON Web Tokens (JWT), and OAuth | [Authentication](#authentication) |
| Develop and operate agents in a browser | The `adk` command, local developer UI, or Phoenix LiveView companion | [CLI and local developer UI](#cli-and-local-developer-ui), [Phoenix UI](#phoenix-ui) |

## Core concepts

- **Agent**: a supervised Erlang process with a model, instructions, and
  tools.
- **Model provider**: the API that runs the model, such as Gemini, OpenAI, or
  Anthropic.
- **Tool**: an Erlang module or external operation that an agent is allowed to
  call.
- **Runner**: executes an agent for one app, user, and session while recording
  events and handling pause/resume.
- **Workflow**: an explicit set of steps that can run sequentially or in
  parallel without asking a model to choose every transition.
- **Live session**: a two-way text, audio, and image/video-frame connection that runs
  independently of the process that started it.
- **Provider profile**: a named model configuration controlled by your
  application. It keeps endpoints and credentials out of user input.

## Requirements

- Erlang/OTP **27.3.4.14 or newer within OTP 27**.
- The repository's `./rebar3` executable.
- The credentials required by the provider you choose. Most hosted providers
  use an API key.
- Elixir 1.17 or newer and Node.js only when using the optional Phoenix UI.
  The verified companion toolchain is Elixir 1.19.5 and Node.js 24.3.0; see
  the [Phoenix setup guide](examples/phoenix_adk_ui/README.md#locked-setup-and-tests).

The core Erlang library does not require Elixir or Node.js.

## Installation

From this repository:

```bash
./rebar3 compile
./rebar3 shell
```

The shell starts the `erlang_adk` application automatically.

To use the project as a Git dependency before the release tag exists, pin the
reviewed commit rather than a moving branch:

```erlang
{deps, [
    {erlang_adk,
     {git, "https://github.com/hsalap7/erlang_adk.git",
      {ref, "REVIEWED_COMMIT_SHA"}}}
]}.
```

After `v0.8.0` is tagged, the Git reference can be `{tag, "v0.8.0"}`. After
the package is published to Hex, use `{erlang_adk, "0.8.0"}`.

In an application that does not use the repository shell configuration, start
the library before creating agents:

```erlang
{ok, _Started} = application:ensure_all_started(erlang_adk).
```

## Your first agent

**Needs:** a Gemini API key and network access.

Export a Gemini API key in the terminal that will run Erlang:

```bash
export GEMINI_API_KEY="your_google_api_key"
./rebar3 shell
```

Then create an agent, send one prompt, print the UTF-8 reply, and stop it:

```erlang
{ok, Agent} = erlang_adk:spawn_agent(
    <<"Helper">>,
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>,
      instructions => <<"Answer clearly and concisely.">>},
    []),
{ok, Reply} = erlang_adk:prompt(
    Agent, <<"Explain an OTP supervisor in one sentence.">>),
io:format("~ts~n", [Reply]),
ok = erlang_adk:stop_agent(Agent).
```

Responses are UTF-8 binaries. Use `~ts` for user-facing Unicode text; `~p`
shows Erlang term syntax instead.

Provider errors are returned as `{error, Reason}`. A missing key is an error,
not a successful text response.

## Choose a model provider

For a small trusted Erlang application, the direct provider modules are the
shortest setup:

| Provider | Module | Default credential variable |
| --- | --- | --- |
| Gemini | `adk_llm_gemini` | `GEMINI_API_KEY` |
| OpenAI Responses | `adk_llm_openai` | `OPENAI_API_KEY` |
| Anthropic Messages | `adk_llm_anthropic` | `ANTHROPIC_API_KEY` |
| OpenAI-compatible Chat Completions | `adk_llm_compatible` | Configured explicitly |

For production or an application that uses more than one provider, use
provider profiles. A profile gives a simple name to a provider, model,
endpoint, and API-key source. Configure profiles in `sys.config` or application
environment. Agent code then selects the simple profile and model names.

This example configures four request-provider profiles. Replace the
placeholder model IDs with models enabled for your accounts:

```erlang
Profiles = #{
    <<"gemini">> =>
        #{request_adapter => adk_llm_gemini,
          endpoint => gemini,
          models => #{<<"chat">> => <<"gemini-3.1-flash-lite">>},
          credential => {env, "GEMINI_API_KEY"}},
    <<"openai">> =>
        #{request_adapter => adk_llm_openai,
          endpoint => openai,
          models => #{<<"chat">> => <<"YOUR_OPENAI_MODEL_ID">>},
          credential => {env, "OPENAI_API_KEY"},
          request_options => #{store => false}},
    <<"anthropic">> =>
        #{request_adapter => adk_llm_anthropic,
          endpoint => anthropic,
          models => #{<<"chat">> => <<"YOUR_ANTHROPIC_MODEL_ID">>},
          credential => {env, "ANTHROPIC_API_KEY"},
          request_options =>
              #{anthropic_version => <<"2023-06-01">>}},
    <<"compatible">> =>
        #{request_adapter => adk_llm_compatible,
          endpoint => #{scheme => https,
                        host => <<"models.vendor.example">>,
                        port => 443,
                        base_path => <<"/v1">>},
          models => #{<<"chat">> => <<"YOUR_VENDOR_MODEL_ID">>},
          credential => {env, "VENDOR_API_KEY"},
          request_options => #{auth_scheme => bearer}}
},
ok = application:set_env(erlang_adk, provider_profiles, Profiles).
```

Use a configured profile like this:

```erlang
{ok, Agent} = erlang_adk:spawn_agent(
    <<"ProfileAgent">>,
    #{provider => <<"gemini">>,
      model => <<"chat">>,
      instructions => <<"Answer concisely.">>},
    []),
{ok, Reply} = erlang_adk:prompt(Agent, <<"What is a GenServer?">>),
io:format("~ts~n", [Reply]),
ok = erlang_adk:stop_agent(Agent).
```

See [Model provider profiles](docs/PROVIDER_PROFILES.md) for OpenAI
Realtime, compatible endpoints, structured output, provider-specific options,
and production configuration.

## Common tasks

The examples that use `adk_llm_gemini` assume the `erlang_adk` application is
running and `GEMINI_API_KEY` is exported. Tasks that do not call a model say
so explicitly.

### Add an Erlang tool

**Needs:** a Gemini API key for the model call. The tool itself runs locally.

A tool implements `adk_tool`. Its schema tells the model when and how it can
call the function. `execute/2` performs the work.

The repository contains a complete example at
[`examples/readme_weather_tool.erl`](examples/readme_weather_tool.erl). Load it
from the repository shell and pass the module when creating an agent:

```erlang
{ok, readme_weather_tool} = c("examples/readme_weather_tool.erl"),
{ok, WeatherAgent} = erlang_adk:spawn_agent(
    <<"WeatherAgent">>,
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>,
      instructions => <<"Use get_weather when a city is provided.">>},
    [readme_weather_tool]),
{ok, WeatherReply} = erlang_adk:prompt(
    WeatherAgent, <<"What is the weather in Tokyo?">>),
io:format("~ts~n", [WeatherReply]),
ok = erlang_adk:stop_agent(WeatherAgent).
```

Tool arguments are checked against the schema before `execute/2` runs. Tools
can also come from OpenAPI documents, MCP servers, sub-agents, or an external
code sandbox.

### Run multiple agents

**Needs:** a Gemini API key. Each agent can make a model request.

Use different agent processes for work that can happen independently.
`parallel/3` starts monitored workers and returns results in agent order.
`sequential/2` feeds each response to the next agent.

```erlang
{ok, Translator} = erlang_adk:spawn_agent(
    <<"Translator">>,
    #{provider => adk_llm_gemini,
      instructions => <<"Translate the input to French.">>}, []),
{ok, Summarizer} = erlang_adk:spawn_agent(
    <<"Summarizer">>,
    #{provider => adk_llm_gemini,
      instructions => <<"Summarize the input in one sentence.">>}, []),

ParallelResults = erlang_adk:parallel(
    [Translator, Summarizer], <<"Explain OTP supervision.">>, 60000),
io:format("~p~n", [ParallelResults]),

{ok, PipelineReply} = erlang_adk:sequential(
    [Translator, Summarizer],
    <<"Erlang processes are lightweight and isolated.">>),
io:format("~ts~n", [PipelineReply]),

ok = erlang_adk:stop_agent(Translator),
ok = erlang_adk:stop_agent(Summarizer).
```

Also available:

- `delegate/4` for correlated asynchronous delegation;
- `loop/4` for a writer/reviewer loop with a maximum iteration count;
- sub-agents and `adk_agent_tool` for model-selected delegation; and
- planning through `run_planning/4,5` or `start_planning/4,5`.

See [Planning](docs/PLANNING_RUNTIME.md) and
[runtime safety](docs/RUNTIME_SAFETY.md).

### Run a workflow

**Needs:** nothing outside this repository. This example does not call a
model.

Use a workflow when your application should control the steps instead of
leaving every transition to a model.

```erlang
WorkflowSpec = #{
    version => 1,
    id => <<"onboarding-workflow-v1">>,
    kind => sequential,
    max_steps => 2,
    steps => [
        #{id => <<"increment">>,
          run => fun(State, _Context) ->
              Count = maps:get(<<"count">>, State, 0) + 1,
              {output, <<"counted">>, #{<<"count">> => Count}}
          end},
        #{id => <<"finish">>,
          run => fun(_State, Context) ->
              <<"counted">> = maps:get(input, Context),
              {output, <<"ready">>, #{<<"done">> => true}}
          end}
    ]
},
{ok, Workflow} = erlang_adk:compile_workflow(WorkflowSpec),
{completed, FinalState, Checkpoint} =
    erlang_adk:run_workflow(Workflow, #{<<"count">> => 0}),
#{<<"count">> := 1, <<"done">> := true} = FinalState,
<<"ready">> = maps:get(<<"output">>, Checkpoint).
```

Workflow kinds include `sequential`, `parallel`, `loop`, `transfer`, and
`graph`. Workflows support cancellation, saved checkpoints, pause/resume,
retry, and optional Mnesia-backed run history.

See [Graph workflows](docs/GRAPH_WORKFLOWS.md),
[planning](docs/PLANNING_RUNTIME.md), and
[durable invocations](docs/DURABLE_INVOCATIONS.md).

### Use the Runner

**Needs:** a Gemini API key for this example.

The Runner keeps events for one application, user, and session. Use it for
session history, tool rounds, streaming events, cancellation, background work,
and pause/resume.

```erlang
{ok, RunnerAgent} = erlang_adk:spawn_agent(
    <<"RunnerAgent">>,
    #{provider => adk_llm_gemini,
      instructions => <<"Be concise.">>}, []),
Runner = adk_runner:new(
    RunnerAgent, <<"my_app">>, erlang_adk_session,
    #{run_timeout => 120000,
      max_llm_calls => 8,
      max_tool_rounds => 4}),
{ok, RunnerReply} = adk_runner:run(
    Runner, <<"user-1">>, <<"session-1">>, <<"Hello">>),
io:format("~ts~n", [RunnerReply]),
ok = erlang_adk:stop_agent(RunnerAgent).
```

For a run that must outlive the caller, use `adk_run:start/5`, then subscribe,
inspect status, cancel, or resume it through `adk_run`.

See [Durable invocations](docs/DURABLE_INVOCATIONS.md),
[scheduled and background runs](docs/AMBIENT_RUNTIME.md), and
[runtime safety](docs/RUNTIME_SAFETY.md).

### Human approval and long-running work

An agent tool that needs confirmation can pause only when it runs through the
Runner or stable-run API. Direct `prompt`, delegation, and agent-as-tool calls
return `tool_confirmation_requires_runner` instead of bypassing approval.

A workflow action can independently pause with structured details. Runner
runs and workflows can later resume from the returned run ID or checkpoint.
This keeps approval separate from model output.

Use these entry points:

| Need | API |
| --- | --- |
| Confirm a tool call | Tool metadata plus `adk_tool_confirmation` |
| Pause and resume a workflow | `resume_workflow/2,3` |
| Start and resume a durable workflow | `start_workflow_invocation/3`, `resume_workflow_invocation/3` |
| Resume a paused Runner run | `adk_run:resume/3` or the `adk resume` CLI command |
| Request OAuth credentials during a run | `adk_authorization_flow` with `adk_suspension` |

See [Durable invocations](docs/DURABLE_INVOCATIONS.md) for complete examples
and restart behavior.

### Streaming and multimodal input

**Needs:** a Gemini API key and network access.

Text streaming calls your function once per decoded text chunk:

```erlang
History = [
    #{role => system, content => <<"Be concise.">>},
    #{role => user, content => <<"Explain OTP in two sentences.">>}
],
PrintChunk = fun(Chunk) -> io:format("~ts", [Chunk]) end,
ok = adk_llm:stream(
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>},
    History, [], PrintChunk),
io:format("~n").
```

Use `adk_content` to combine text with image data or a supported file URI:

```erlang
TinyPng = base64:decode(
    <<"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0l"
      "EQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=">>),
{ok, TextPart} = adk_content:text(<<"Describe this image.">>),
{ok, ImagePart} = adk_content:inline_data(<<"image/png">>, TinyPng),
{ok, Prompt} = adk_content:new([TextPart, ImagePart]),
{ok, Result} = adk_llm:generate(
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>},
    [#{role => user, content => Prompt}], []).
```

For a successful response with no tool call or extra provider details,
`Result` is a text binary or a validated `adk_content` map. The complete API
can also return tool calls, a wrapped result with provider details, or an
error.

### Realtime sessions and browser voice

**Needs:** a key for the selected realtime provider. Browser voice also needs
the Phoenix companion or an application-owned audio client.

Realtime sessions use a separate API from ordinary REST generation:

| Provider | Request model | Realtime model/input |
| --- | --- | --- |
| Gemini | `gemini-3.1-flash-lite` | `gemini-3.1-flash-live-preview`, 16 kHz PCM input |
| OpenAI | A configured Responses model | A configured Realtime model, 24 kHz PCM input |

The core lifecycle is:

1. configure a Gemini Live or OpenAI Realtime provider profile;
2. call `start_live_session/3` with a session ID and signed-in identity;
3. subscribe with `live_subscribe/3,4`;
4. send text, audio, or image/video frames and acknowledge each delivered
   event so the session can continue sending; and
5. unsubscribe and call `close_live_session/3`.

Use `start_live_voice_bridge/4` when a browser or native audio client needs a
binary voice connection. The Phoenix companion already connects this bridge
to microphone capture, resampling, playback, interruption, and transcripts.

See [Provider profiles](docs/PROVIDER_PROFILES.md) for Live profile setup. For
the simplest end-to-end browser path, follow [Starting a Live session for the
UI](examples/phoenix_adk_ui/README.md#starting-a-live-session-for-the-ui) and
[Testing full-duplex voice](examples/phoenix_adk_ui/README.md#testing-full-duplex-voice).

### Sessions, artifacts, memory, and context

**Needs:** nothing outside this repository for the built-in ETS services.

This local example creates a session, updates its state, reads it, and removes
it:

```erlang
ok = erlang_adk_session:init(),
{ok, _} = erlang_adk_session:create_session(
    <<"my_app">>, <<"user-1">>, #{session_id => <<"session-1">>}),
ok = erlang_adk_session:update_state(
    <<"my_app">>, <<"user-1">>, <<"session-1">>,
    #{<<"theme">> => <<"dark">>}),
{ok, Session} = erlang_adk_session:get_session(
    <<"my_app">>, <<"user-1">>, <<"session-1">>),
#{<<"theme">> := <<"dark">>} = maps:get(state, Session),
ok = erlang_adk_session:delete_session(
    <<"my_app">>, <<"user-1">>, <<"session-1">>).
```

| Data | Built-in choices | Guide |
| --- | --- | --- |
| Session events and state | ETS-backed `erlang_adk_session`, durable local `erlang_adk_session_mnesia` | This section and [feature support](docs/FEATURE_PARITY.md) |
| Versioned artifacts | `adk_artifact_ets`, `adk_artifact_fs`, and optional storage splitting by app/user/session | [Artifacts](docs/ARTIFACTS.md) |
| Long-term memory | `adk_memory_ets`, `adk_memory_mnesia`, optional storage splitting, and reliable background writes | [Memory](docs/MEMORY.md) |
| Context selection and limits | `adk_context`, selection rules, compaction, and reuse of stable prompt prefixes | [Context](docs/CONTEXT.md) |

The Runner accepts the relevant services in its options. Tools can receive
state and data helpers limited to the current app, user, and session without
receiving raw storage internals.

### Integrations

These are integration starting points. A real connection also needs the
remote service address, allowed-host policy, and credentials required by that
service. Keep those values in application configuration, not in model input.

| Integration | How to start | Details |
| --- | --- | --- |
| OpenAPI | Decode an OpenAPI 3.0/3.1 document, call `adk_openapi_toolset:compile/2`, wrap it with `adk_toolset:new/2`, and pass it to an agent | The checked example is [`examples/readme_petstore_openapi.json`](examples/readme_petstore_openapi.json) |
| MCP client | `adk_mcp_client:connect/2,3`, list tools, then wrap the client with `adk_toolset:new/2` | Supports stdio and Streamable HTTP |
| MCP server | `adk_mcp_server:start/2` | Exposes checked tools, resources, and prompts |
| External code execution | Configure `adk_code_toolset` with an application-owned sandbox adapter | [Code execution](docs/CODE_EXECUTION.md) |
| A2A 1.0 server | Configure an Agent Card, agent name, listener, and authentication before application startup | [Feature support](docs/FEATURE_PARITY.md) and [security](SECURITY.md) |
| A2A 1.0 client | `adk_a2a_v1_client:discover/2`, then `send/3` or the task/stream APIs | Unencrypted HTTP can be enabled only for local `127.0.0.1` development |

OpenAPI and MCP tools use the same checked tool-call path as local Erlang
tools. Credentials are supplied by the application, not by model arguments.

### Plugins, observability, and evaluation

- Runner plugins can inspect or change run stages, return early, and
  keep state in supervised plugin processes.
- Telemetry events cover agent, model, tool, Runner, Live, and evaluation
  operations.
- Built-in metrics and the export bus can send data to an OpenTelemetry
  collector through a configured exporter.
- Evaluation supports repeatable datasets, repeated samples, tool-call
  checks, rubric judges, baseline comparison, JSON, and Markdown reports.

Run the checked one-turn evaluation smoke from the CLI:

**Needs:** `GEMINI_API_KEY`, because `examples/agent.json` uses Gemini.

```bash
./rebar3 escriptize
_build/default/bin/adk evaluate \
  --config examples/agent.json \
  --dataset examples/eval.json
```

See [Plugins, observability, and evaluation](docs/PLUGINS_OBSERVABILITY_EVALUATION.md).
That guide also covers the newer `adk eval run` command for multi-turn
evaluation sets, repeated samples, report comparison, and rubric judges.

### Authentication

Erlang ADK uses the `oidcc` Erlang package for OpenID Connect and OAuth. The
authentication modules support:

- JWT validation checks who issued a token, who it is for, its signing
  algorithm and type, its lifetime, the user, and required permissions;
- browser authorization-code flow with Proof Key for Code Exchange (PKCE);
- client-credentials and refresh-token flows;
- private credential references and one shared token refresh for callers that
  request it at the same time; and
- scoped authorization for web, OpenAPI, MCP, and A2A operations.

Configure identity providers and credential sources before application
startup. Use the [Phoenix guide](examples/phoenix_adk_ui/README.md) for a
complete browser login example, and read [Security](SECURITY.md) before a
public deployment.

## CLI and local developer UI

Build the CLI and run the two commands that do not call a model:

```bash
./rebar3 escriptize
_build/default/bin/adk doctor
_build/default/bin/adk config validate examples/agent.json
```

The checked configuration uses Gemini. Export its key before running a model
request, opening the console, running an evaluation, or starting a model run
from the developer UI:

```bash
export GEMINI_API_KEY="your_google_api_key"

_build/default/bin/adk run \
  --config examples/agent.json \
  --message "Explain rest_for_one" \
  --user local --session cli-demo

_build/default/bin/adk console \
  --config examples/agent.json \
  --user local --session cli-console
```

Start the local developer server in one terminal. Binding to `127.0.0.1`
makes it reachable only from this computer:

```bash
export ERLANG_ADK_DEV_TOKEN="replace-with-at-least-16-random-characters"
_build/default/bin/adk serve \
  --config examples/agent.json \
  --ip 127.0.0.1 --port 8080
```

Open <http://127.0.0.1:8080/dev>. Keep that terminal running while using
the CLI from another terminal. Environment variables are terminal-local, so
export the same developer token there before inspecting the server:

```bash
export ERLANG_ADK_DEV_TOKEN="replace-with-at-least-16-random-characters"
_build/default/bin/adk inspect agents --url http://127.0.0.1:8080
```

Enter that same token when the browser UI asks for it. Other commands include
`adk session`, `adk resume`, `adk memory`, and `adk artifact`; run
`_build/default/bin/adk --help` for their arguments.

The simple `adk serve` command provides agents, runs, sessions, and basic
observability. Live, artifact, memory, and context-management panels require
the owning Erlang application to start those services and expose them through
the documented developer configuration.

If a command reports `developer_api_unavailable` with `connection_refused`,
the server is not listening at the selected URL or port.

## Phoenix UI

The optional Phoenix 1.8 companion provides authenticated agent runs, human
approval, Live operations, browser voice, observability, and evaluation views.
It runs in the same Erlang runtime as Erlang ADK.

For local development without an external OIDC provider:

```bash
(
  export MIX_REBAR3="$PWD/rebar3"
  export GEMINI_API_KEY="your_google_api_key"
  export ADK_UI_LOCAL_AUTH=true
  cd examples/phoenix_adk_ui
  MIX_ENV=dev mix setup
  MIX_ENV=dev iex -S mix phx.server
)
```

Open <http://127.0.0.1:4000/auth/login> and choose **Continue as local
developer**. Local authentication is accepted only in `MIX_ENV=dev` and does
not require any `OIDC_*` variables. `iex -S` gives you an Erlang/Elixir shell
in the same runtime, which is useful when creating a Live session for the
voice UI. Stop the server with `Ctrl+C` twice; the surrounding shell block
returns you to the repository root.

For OIDC configuration, realtime voice setup, production TLS/proxy settings,
and release commands, follow the
[Phoenix companion guide](examples/phoenix_adk_ui/README.md).

## Developer checks

Run commands from the repository root unless a section says otherwise.
GitHub Actions runs every non-paid group below on each pull request. For local
work, use this minimum:

| Situation | Run |
| --- | --- |
| While editing | [Quick check](#quick-check-while-developing) |
| Before any pull request | [Core checks](#core-checks-before-opening-a-pull-request) |
| README or example changed | Core checks plus [README example checks](#if-readme-examples-changed) |
| Phoenix changed | Core checks plus [Phoenix checks](#if-the-phoenix-application-changed) |
| Documentation, CLI, or packaging changed | Core checks plus [documentation, CLI, and package checks](#documentation-cli-and-package-checks) |
| Real Gemini behavior changed | Run the non-paid checks first, then the [paid tests](#optional-paid-gemini-checks) only when intended |

### Quick check while developing

Use this for a fast compile and README-example smoke test:

```bash
./rebar3 compile
./rebar3 eunit --module=readme_examples_test
./rebar3 eunit --module=readme_workflow_examples_test
```

This is a convenience check, not the full CI gate.

### Core checks before opening a pull request

This is the standard Erlang sanity gate. First remove the opt-in flags for
paid tests so an earlier shell export cannot turn this into a billable run:

```bash
unset ERLANG_ADK_GEMINI_REST ERLANG_ADK_LIVE_GEMINI \
  ERLANG_ADK_GEMINI_LIVE

./rebar3 do clean, compile, eunit, ct, dialyzer
./scripts/coverage.sh
./rebar3 xref
```

Common Test now skips paid provider suites because their opt-in flags are
absent. Other unexpected skips should be investigated. `coverage.sh` resets
old data, reruns EUnit and Common Test with coverage, and enforces the
repository floor. The repeated test run is intentional: it gathers fresh
coverage data. Running `rebar3 cover --verbose` alone does not execute tests.

### If README examples changed

Run the two focused modules above and compile the checked example modules with
warnings treated as errors:

```bash
erlc -Werror -pa _build/default/lib/erlang_adk/ebin -o /tmp \
  examples/readme_weather_tool.erl \
  examples/readme_live_weather_executor.erl \
  examples/readme_stateful_counter_plugin.erl
```

### If the Phoenix application changed

The first setup needs network access:

```bash
(
  export MIX_REBAR3="$PWD/rebar3"
  unset ADK_UI_LOCAL_AUTH
  cd examples/phoenix_adk_ui
  MIX_ENV=test mix deps.get
  MIX_ENV=test mix deps --check-locked
  MIX_ENV=test mix assets.setup
  MIX_ENV=test mix precommit
  MIX_ENV=test elixir ../../scripts/verify_phoenix_hex_audit.exs
)
```

`mix precommit` checks formatting, compilation warnings, browser/audio
JavaScript, assets, and ExUnit with fake providers. It does not use model
quota. The audit verifier accepts only the exact documented dependency
exception and fails if the set changes.

### Documentation, CLI, and package checks

Run these when changing packaging, documentation, or the CLI. GitHub Actions
also runs them on every pull request because the repository stays
release-ready:

```bash
./rebar3 escriptize
_build/default/bin/adk doctor
_build/default/bin/adk config validate examples/agent.json
./rebar3 ex_doc
./rebar3 hex build
./scripts/verify_hex_package.sh
```

The Hex command builds a package locally; it does not publish it. Treat any
ExDoc warning as a failure, matching CI. GitHub Actions additionally builds a
production Phoenix release and smoke-tests its proxy and direct-TLS modes.
The exact commands and required environment are in
[Releasing](docs/RELEASING.md).

### Optional paid Gemini checks

These commands make real network requests and may use quota or incur cost:

```bash
export GEMINI_API_KEY="your_google_api_key"

ERLANG_ADK_GEMINI_REST=1 ./rebar3 ct \
  --suite test/readme/readme_live_gemini_SUITE.erl

ERLANG_ADK_GEMINI_LIVE=1 ./rebar3 ct \
  --suite test/models/gemini/gemini_live_SUITE.erl
```

The REST suite uses `gemini-3.1-flash-lite`. The separate Live suite uses
`gemini-3.1-flash-live-preview`. A skip, provider rejection, or quota error is
not a passing provider test. OpenAI, Anthropic, and compatible providers are
tested with local fake network connections and response parsing, but this
repository does not include paid live suites for them.

See [Testing](docs/TESTING.md) for focused commands and result
interpretation.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Text prints as integers or Erlang term syntax | Use `io:format("~ts~n", [Reply])` for Unicode text; `~p` is for inspecting Erlang terms. |
| Paid Common Test cases are skipped | Export the key and set the matching REST or Live opt-in flag in the same terminal. |
| `No coverdata found` | Run `./scripts/coverage.sh`; `rebar3 cover` only reads existing coverage data. |
| Google returns HTTP 401 | The environment variable exists, but Google rejected its value. Replace it with an API key authorized for the Gemini API. |
| `developer_api_unavailable` / `connection_refused` | Keep `adk serve` running and use the same local port in every command. |
| Phoenix asks for `OIDC_ISSUER` during local development | Set `ADK_UI_LOCAL_AUTH=true` exactly and run with `MIX_ENV=dev` (the default for `mix phx.server`). |
| Phoenix UI has no styles | Run `mix assets.setup` and `mix assets.build`, then restart the server. |
| No Live sessions appear in Phoenix | The UI discovers existing sessions; start one in the same Erlang runtime with the signed-in user identity first. |

## Documentation

| Topic | Guide |
| --- | --- |
| All documentation | [Documentation index](docs/README.md) |
| Provider profiles and vendor setup | [Provider profiles](docs/PROVIDER_PROFILES.md) |
| Supported and partial features | [Feature support](docs/FEATURE_PARITY.md) |
| Runtime limits, failures, and cancellation | [Runtime safety](docs/RUNTIME_SAFETY.md) |
| Workflows, planning, and durable runs | [Graph workflows](docs/GRAPH_WORKFLOWS.md), [planning](docs/PLANNING_RUNTIME.md), [durable invocations](docs/DURABLE_INVOCATIONS.md) |
| Sessions, artifacts, memory, and context | [Artifacts](docs/ARTIFACTS.md), [memory](docs/MEMORY.md), [context](docs/CONTEXT.md) |
| Scheduled and background runs | [Ambient runtime](docs/AMBIENT_RUNTIME.md) |
| Gemini Search grounding | [Gemini grounding](docs/GEMINI_GROUNDING.md) |
| Plugins, telemetry, and evaluation | [Plugins, observability, and evaluation](docs/PLUGINS_OBSERVABILITY_EVALUATION.md) |
| External code execution | [Code execution](docs/CODE_EXECUTION.md) |
| Phoenix UI | [Phoenix companion](examples/phoenix_adk_ui/README.md) |
| Tests and coverage | [Testing](docs/TESTING.md) |
| Release process | [Releasing](docs/RELEASING.md) |
| Upgrading | [Upgrade guide](docs/UPGRADING.md) |
| Security | [Security policy](SECURITY.md) |
| Source and test layout | [Source layout](src/README.md), [test layout](docs/TEST_LAYOUT.md) |
| Current release scope | [v0.8.0 release details](docs/VERSION_0_8_0.md) |

## Project status and security

Erlang ADK is under active development. Review the
[feature-support matrix](docs/FEATURE_PARITY.md) before depending on a partial
feature or provider-specific capability.

Do not commit API keys or OAuth credentials. Keep provider endpoints,
credentials, authentication policy, and public listener settings in trusted
application configuration. Read the [security policy](SECURITY.md) before
making any HTTP, MCP, A2A, developer, or Phoenix endpoint reachable beyond
`127.0.0.1`.

## License

Erlang ADK is available under the [Apache License 2.0](LICENSE.md).
