# Erlang ADK v0.3.0 (development)

Erlang ADK is an experimental, Erlang-native toolkit for building Gemini-backed agents with OTP processes, supervision, tools, sessions, event streams, and concurrent multi-agent workflows.

Version 0.3.0 is under active development on the `version_0.3.0` branch. The
[v0.3.0 development contract](docs/VERSION_0_3_0.md) tracks the required core
capabilities and their verification gates. The core checklist, deterministic
test gate, and CLI packaging checks are complete: 573 EUnit tests, four Common
Test scenarios, and Dialyzer over 131 project files passed on 2026-07-13, as
did `escriptize`, `adk doctor`, and checked configuration validation. The
billable live Gemini suite remains a separate opt-in provider gate in a shell
that owns `GEMINI_API_KEY`.

The detailed [ADK behavior-parity matrix](docs/FEATURE_PARITY.md) maps the
official ADK capability families to their Erlang/OTP-native implementation
contracts and current branch status.

The project follows the behavior of Google ADK where that behavior maps cleanly to Erlang. It is not a drop-in port and does not claim complete Google ADK feature parity. In particular, one agent is one `gen_server` for serial admission and state commits, while each accepted direct turn runs provider/tool work in a supervised lightweight process outside that mailbox. Independent agents and orchestration branches therefore run concurrently without making one stateful conversation nondeterministic.

## Current scope

| Area | Status on the v0.3.0 branch |
| --- | --- |
| Gemini text, versioned multimodal content, function calling, Google Search grounding, thinking levels/summaries, adjustable safety settings, thought signatures, call IDs, SSE text/content streaming, structured-output settings, and provider capability discovery | Implemented on this branch; the bidirectional Gemini Live WebSocket API is not implemented |
| Erlang tools and agents exposed as model tools | Implemented |
| Supervised sequential, bounded parallel, loop, transfer, and graph workflows with deadlines, budgets, cancellation, checkpoints, and resume | Implemented on this branch; legacy orchestration helpers remain supported |
| Provider-neutral explicit planning and Gemini model-native thinking | Versioned JSON-safe plans, trusted planner/executor adapters, bounded replanning, monitored callbacks, owner-bound cancellation, and Gemini thinking levels/summaries are implemented; model-generated source is never executed |
| ETS/Mnesia sessions with scoped state, HMAC snapshot pagination, filters, and non-destructive branch/rewind | The v0.3.0 core is implemented and release-gated; schema-migration and configurable conflict-policy adapters are not claimed |
| Versioned JSON-safe events and human approval pause/resume | Implemented |
| Supervised stable runs with status, await, credit/ack subscribe/replay, cancellation, and retention | Implemented and release-gated on this branch |
| Ambient/background invocation | Supervised local/event and fixed-delay schedule triggers use bounded concurrency, bounded queues, idempotency, deadlines, retry, stable status/await/cancel, and explicit per-event/shared/session-supplied policies; Pub/Sub/Eventarc remain application adapters |
| Bounded supervised tasks and serial/parallel-safe tool execution | Implemented for Erlang modules plus dynamically resolved OpenAPI/MCP toolsets in direct agents and Runner |
| Admission control and runtime policy | Supervised global/per-agent limits, monitored reject/bounded-FIFO queue policies, fail-closed agent/tool allow-deny rules, byte budgets, and immutable denial audit events are implemented on this branch |
| Agent/model/tool callbacks and Runner-global plugins | Ordered Runner plugins, bounded failure policy, intervention, and existing local callbacks are implemented on this branch; see lifecycle notes below |
| Observability | Correlated invocation/model/tool telemetry, JSON-safe envelopes, bounded exporters, and opt-in content capture are implemented on this branch |
| Evaluation | Legacy lightweight evaluation plus versioned multi-turn eval sets, captured tool trajectories, metric/judge adapters, thresholds, and saved-result metadata are implemented on this branch |
| OpenAPI | Strict OpenAPI 3.0/3.1 compiler, production Gun transport, per-principal auth broker, and first-class agent/Runner toolsets are implemented; the supported subset is documented below |
| MCP | Supervised stdio and MCP 2025-11-25 Streamable HTTP clients plus a bounded tool/resource/prompt server are implemented and release-gated; optional server GET/SSE and advanced capabilities remain explicit limitations |
| A2A interoperability | A2A 1.0 Agent Card plus bounded JSON-RPC/SSE tasks, artifacts, replay, principal scoping, and outbound client are implemented; the older `/a2a/prompt` endpoint remains explicitly legacy |
| Versioned artifacts and Runner-integrated long-term memory | Immutable ETS and durable filesystem artifacts plus explicit memory retrieval/ingestion policies are implemented; managed adapters remain application integrations |
| Auth and integrated developer tooling | Private scoped credentials, interactive PKCE suspension/completion, Oidcc-backed JWT/OAuth adapters, an authenticated bounded REST/SSE console, and the `adk` CLI are implemented and release-gated on this branch |
| Phoenix LiveView companion | A complete stable-run integration pattern is documented below with authenticated principals, credit/ack replay, reconnect gaps, bounded UI state, and HITL resume; the public Erlang contract is tested here, while companion Elixir syntax is manually reviewed because this repository has no Mix compile gate |

## Installation

While 0.3.0 is being developed, depend on this branch (or use a local path in
the same way):

```erlang
{deps, [
    {erlang_adk,
     {git, "https://github.com/hsalap7/erlang_adk.git",
      {branch, "version_0.3.0"}}}
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

Provider adapters advertise only behavior they actually implement:

```erlang
{ok, GeminiCapabilities} = adk_llm:capabilities(adk_llm_gemini),
true = maps:get(streaming, GeminiCapabilities),
true = maps:get(function_calling, GeminiCapabilities),
true = maps:get(structured_output, GeminiCapabilities),
true = maps:get(multimodal, GeminiCapabilities),
true = maps:get(thinking, GeminiCapabilities),
true = maps:get(safety_settings, GeminiCapabilities),
true = maps:get(google_search_grounding, GeminiCapabilities),
[google_search] = maps:get(builtin_tools, GeminiCapabilities),
1 = maps:get(content_schema_version, GeminiCapabilities),
false = maps:get(live, GeminiCapabilities),
ok = adk_llm:validate_config(
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>,
      response_mime_type => <<"application/json">>,
      response_schema => #{<<"type">> => <<"object">>}}).
```

Custom providers need only `generate/3` and `stream/4`; `capabilities/0` and
`validate_config/1` are optional behavior callbacks.

### Google Search grounding

Gemini 3.1 Flash-Lite can let the model ground an answer with Google Search by
adding the strictly validated built-in tool. This uses the Gemini
`generateContent`/`streamGenerateContent` `googleSearch` tool, not the
Interactions API:

```erlang
GroundingConfig = #{
    provider => adk_llm_gemini,
    model => <<"gemini-3.1-flash-lite">>,
    builtin_tools => [google_search]
},
GroundingHistory = [
    #{role => user,
      content => <<"What changed in the latest stable Erlang/OTP release?">>}
],
case adk_llm:generate(GroundingConfig, GroundingHistory, []) of
    {provider_result, _} = GroundedResult ->
        {ok, {ok, GroundedAnswer}, ProviderMetadata} =
            adk_provider_result:decode(GroundedResult),
        <<"gemini">> = maps:get(<<"provider">>, ProviderMetadata),
        <<"google_search_grounding">> =
            maps:get(<<"type">>, ProviderMetadata),
        GroundingMetadata = maps:get(<<"metadata">>, ProviderMetadata),
        io:format("~ts~nqueries: ~p~n", [
            GroundedAnswer,
            maps:get(<<"webSearchQueries">>, GroundingMetadata, [])
        ]);
    {ok, UngroundedAnswer} ->
        %% Enabling Search lets Gemini decide whether the prompt needs it.
        io:format("~ts~n", [UngroundedAnswer])
end.
```

When both Erlang/custom tools and Google Search are configured, the request
contains one `googleSearch` declaration and one `functionDeclarations`
declaration; the two mechanisms are not conflated. A candidate with no
`groundingMetadata` keeps the existing provider return byte-for-byte
compatible. A grounded candidate uses the reserved
`{provider_result, Envelope}` result. Agents unwrap its model output before
output-schema validation. Runner/event APIs persist this JSON-safe projection:

```erlang
#{<<"provider_metadata">> =>
      #{<<"schema_version">> => 1,
        <<"provider">> => <<"gemini">>,
        <<"type">> => <<"google_search_grounding">>,
        <<"metadata">> => GroundingMetadata}}
```

The projection is attached to the event whose Gemini candidate carried it,
including tool-call events. SSE list fields are accumulated in arrival order,
and the final streamed event receives the combined metadata. Candidate
metadata must be a strict JSON map and is capped at 256 KiB; malformed or
oversized values fail explicitly instead of being dropped. Direct
`prompt/2` intentionally returns only the answer, so use Runner/event APIs or
direct `adk_llm` calls when citations or grounding provenance must be retained.

`searchEntryPoint.renderedContent` can contain provider-supplied HTML. Erlang
ADK preserves it as bounded data but never renders it as HTML. The bundled
developer console uses `textContent`/JSON rendering. A custom UI must sanitize
untrusted markup and satisfy Google's display terms before showing search
suggestions. This release does not add URL Context, Maps grounding, Enterprise
Web Search, Gemini Live grounding, automatic citation insertion, or an
Interactions-API adapter. See [Gemini Google Search grounding](docs/GEMINI_GROUNDING.md),
the official [Google Search grounding guide](https://ai.google.dev/gemini-api/docs/generate-content/google-search),
and the [GenerateContent API](https://ai.google.dev/api/generate-content).

Gemini 3.1 Flash-Lite supports model-native thinking. Direct provider calls
put the validated option at the provider-config level; an agent puts the same
map inside `generation_config`:

```erlang
ThinkingConfig = #{
    provider => adk_llm_gemini,
    model => <<"gemini-3.1-flash-lite">>,
    thinking_config => #{thinking_level => high,
                         include_thoughts => true}
},
{ok, ThinkingResult} = adk_llm:generate(
    ThinkingConfig,
    [#{role => user,
       content => <<"Explain why supervisors isolate failures.">>}], []),
case ThinkingResult of
    Answer when is_binary(Answer) -> io:format("~ts~n", [Answer]);
    ThoughtContent when is_map(ThoughtContent) ->
        {ok, ThoughtContent} = adk_content:validate(ThoughtContent),
        io:format("structured response: ~p~n", [ThoughtContent])
end.
```

Supported levels are `minimal`, `low`, `medium`, and `high`; omission uses the
model default. `minimal` is not a guarantee that thinking is disabled. The
legacy numeric `thinking_budget` is accepted for older Gemini models, but the
adapter rejects a request containing both a level and a budget. When
`include_thoughts` is true and Gemini returns an optional thought summary, the
one-shot result is canonical `adk_content` so the summary marked
`<<"thought">> => true` cannot be concatenated into the visible answer. Text
streaming similarly emits only visible answer deltas; content streaming
preserves both kinds of part. Thought summaries are provider output, not an
executable `adk_plan`.

Gemini safety settings are request-scoped. Direct provider calls put
`safety_settings` at the provider-config level; agents put the same list in
`generation_config`:

```erlang
SafetySettings = [
    #{category => hate_speech, threshold => block_low_and_above},
    #{category => harassment, threshold => block_only_high}
],
ok = adk_llm:validate_config(
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>,
      safety_settings => SafetySettings}).
```

The adjustable categories are `harassment`, `hate_speech`,
`sexually_explicit`, and `dangerous_content`. Thresholds are `off`,
`block_none`, `block_only_high`, `block_medium_and_above`,
`block_low_and_above`, and `unspecified`; they encode to Gemini's documented
`safetySettings` REST enums. Categories must be unique. The deprecated civic
integrity category, unknown keys, and unknown thresholds fail locally before
HTTP. These settings adjust probability filters; they do not disable Gemini's
built-in protection for core harms. Applications remain responsible for
testing and choosing an appropriate policy. See the official
[Gemini safety settings](https://ai.google.dev/gemini-api/docs/safety-settings)
and [GenerateContent request](https://ai.google.dev/api/generate-content)
contracts.

Gemini configuration is strict: a misspelled or unsupported top-level key, or
an unknown key inside `generation_config`, returns an explicit validation
error instead of being silently ignored. Documented agent/runtime fields are
accepted because the immutable agent config is shared with the provider
adapter. Callback-specific application data belongs under `callback_config`;
callbacks receive a least-privilege projection containing only model/generation
metadata and that recursively pruned namespace. API keys, credentials, process
IDs, references, clients, connections, and store handles are never included.
Register observer processes out of band, as in the callback example below.

Gemini provider configs may set `request_timeout` to a non-negative number of
milliseconds (or `infinity`). It bounds the complete non-streaming HTTP
request and each streaming connection/response/data wait. Omitting it keeps
the underlying `httpc` and Gun defaults. When calling Gemini through an agent,
keep this below the separate `agent_call_timeout` and `agent_turn_timeout`
application settings (both 60 seconds by default). `request_timeout =>
infinity` removes only the transport limit; direct `adk_llm` calls do not have
the outer agent deadline.

Text returned by `prompt/2`, correlated delegation, orchestration helpers,
Runner, agent-as-tool, and the HTTP client is a UTF-8 binary. Use `~ts` to
print it as Unicode text; unlike a legacy Erlang charlist, it will not appear
as a list of integer code points in the shell or logs.

## Agent contracts and scoped instructions

An agent validates immutable input/output contracts before and after the model
call. Instructions can read the exact invocation's scoped state, structured
output is requested from a capable provider, and `output_key` is committed in
the same final session event as the response:

```erlang
ContractApp = <<"contract_app">>,
ContractUser = <<"user-1">>,
ContractSession = <<"contract-session">>,
ok = erlang_adk_session:init(),
{ok, _} = erlang_adk_session:create_session(
    ContractApp, ContractUser,
    #{session_id => ContractSession,
      state => #{<<"user:name">> => <<"Ada">>}}),

ContractConfig = #{
    provider => adk_llm_gemini,
    model => <<"gemini-3.1-flash-lite">>,
    instructions =>
        <<"Answer {user:name} concisely using the requested JSON shape.">>,
    input_schema => #{
        type => object,
        properties => #{<<"topic">> => #{type => string, minLength => 1}},
        required => [<<"topic">>],
        additionalProperties => false},
    output_schema => #{
        type => object,
        properties => #{<<"answer">> => #{type => string, minLength => 1}},
        required => [<<"answer">>],
        additionalProperties => false},
    output_key => <<"user:last_answer">>,
    history_policy => exclude,
    generation_config => #{
        max_output_tokens => 128,
        thinking_config => #{thinking_level => low},
        safety_settings =>
            [#{category => harassment,
               threshold => block_medium_and_above}]}
},
{ok, ContractAgent} = erlang_adk:spawn_agent(
    <<"ContractAgent">>, ContractConfig, []),
ContractRunner = adk_runner:new(
    ContractAgent, ContractApp, erlang_adk_session),
ContractInput = jsx:encode(#{<<"topic">> => <<"supervision trees">>}),
{ok, ContractResponse} = adk_runner:run(
    ContractRunner, ContractUser, ContractSession, ContractInput),
#{<<"answer">> := ContractAnswer} =
    jsx:decode(ContractResponse, [return_maps]),
io:format("~ts~n", [ContractAnswer]),
{ok, ContractStored} = erlang_adk_session:get_session(
    ContractApp, ContractUser, ContractSession),
#{<<"user:last_answer">> := #{<<"answer">> := ContractAnswer}} =
    maps:get(state, ContractStored),
ok = erlang_adk:stop_agent(ContractAgent),
ok = erlang_adk_session:delete_session(
    ContractApp, ContractUser, ContractSession).
```

`global_instruction` accepts the same static templates and
`{dynamic, Module, Function}` providers as `instructions`. For a direct or
Runner invocation, that agent is the root: its global instruction is prepended
to its local instruction, and the same root instruction provider is carried
across process boundaries and resolved for each delegated sub-agent against
that invocation's scope. A child's own `global_instruction` is ignored while
it runs below that root, but applies if the child is invoked independently as
the root of a new tree. Resolution remains bounded and secret-scrubbed; agent
configuration is never mutated.

Google's Python ADK currently marks its direct `global_instruction` field as
deprecated in favor of `GlobalInstructionPlugin`. Erlang ADK 0.3.0 keeps the
explicit root field while providing the same tree-wide behavior through
message-passed invocation context; an app-level instruction plugin can be
added later without changing this contract.

`history_policy => exclude` removes earlier turns but always retains the
current input. A schema failure is returned before provider execution or state
mutation. Static placeholders support scoped state keys such as `{user:name}`
and exact-scope artifacts such as `{artifact.reports/summary.txt}`; secret-like
keys are rejected. Dynamic instruction providers use
`{dynamic, Module, Function}` and receive only a bounded, read-only scope map.

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

### External-sandbox code execution

`adk_code_toolset` makes a checked `execute_code` tool available only through
an application-supplied `adk_code_executor`. Erlang ADK deliberately has no
`erl_eval`, shell, local-interpreter, executable-path, port, or NIF fallback:

```erlang
#{external_sandbox_required := true,
  in_process_execution := false,
  shell_fallback := false} = adk_code_toolset:capabilities(),
{ok, CodeTools} = adk_code_toolset:new(
    #{executor => {my_sandbox_adapter, SandboxHandle},
      languages => [<<"erlang">>, <<"python">>],
      timeout => 30000,
      max_code_bytes => 65536,
      max_output_bytes => 1048576,
      parallel_safe => false}),
{ok, CodeAgent} = erlang_adk:spawn_agent(
    <<"SandboxedCoder">>,
    #{provider => adk_llm_gemini,
      instructions =>
          <<"Use execute_code only when calculation requires it.">>},
    [CodeTools]).
```

The configuration fragment above becomes runnable after the application
provides `my_sandbox_adapter` and `SandboxHandle`; they are intentionally not
invented by the library. Before invoking that adapter, the toolset enforces a
language allow-list, UTF-8/input/file/output limits, canonical relative paths,
a minimal redacted context, and the normal supervised tool deadline, plugin,
policy, and cancellation path. The external service must independently enforce
CPU, memory, process, filesystem, network, and cleanup isolation. See
[External sandbox code execution](docs/CODE_EXECUTION.md) for the adapter
behaviour and deployment requirements.

### OpenAPI toolsets

OpenAPI operations use the same tool path as Erlang modules. The compiler
accepts an already-decoded OpenAPI 3.0 or 3.1 document, generates deterministic
model schemas, and resolves each selected operation into a bounded worker.
The repository includes the schema used here:

```erlang
{ok, PetstoreJson} = file:read_file(
    "examples/readme_petstore_openapi.json"),
PetstoreSpec = jsx:decode(PetstoreJson, [return_maps]),
{ok, Petstore} = adk_openapi_toolset:compile(
    PetstoreSpec,
    #{transport => {adk_openapi_gun_transport, default},
      allowed_hosts => [<<"petstore3.swagger.io">>]}),
{ok, PetstoreTools} = adk_toolset:new(
    adk_openapi_toolset, Petstore),
{ok, PetstoreAgent} = erlang_adk:spawn_agent(
    <<"PetstoreAgent">>,
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>,
      instructions => <<"Use the Petstore operation when needed.">>},
    [PetstoreTools]),
{ok, PetstoreAnswer} = erlang_adk:prompt(
    PetstoreAgent, <<"What is the name and status of pet 1?">>),
io:format("~ts~n", [PetstoreAnswer]),
ok = erlang_adk:stop_agent(PetstoreAgent).
```

Production transport defaults to HTTPS, re-resolves and validates the target
against `allowed_hosts`, rejects private addresses and redirects, verifies TLS
hostnames, and enforces request, response, operation, parameter, schema-depth,
and time limits. Set `allow_private_hosts => true` and explicitly allow
`<<"http">>` only for a trusted local service.

The supported request subset is path/query/header parameters plus JSON request
bodies and JSON responses. Local `$ref` values are resolved. API keys in
headers or query parameters, HTTP bearer, and OAuth 2.0 are resolved out of
band through `adk_openapi_auth_broker`; credentials are never model arguments.
Cookie parameters or API keys, Basic/Digest auth, mTLS, OpenID Connect security
schemes, form/multipart bodies, callbacks, and remote references are rejected
explicitly rather than silently weakened.

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

Each parallel result is `{AgentPid, Response}` or `{AgentPid, {error, Reason}}`. Requests to the same agent PID retain FIFO turn semantics; their blocking work is mailbox-isolated but not executed concurrently. Concurrency comes from independent agents.

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
    global_instruction =>
        <<"You are part of the Erlang documentation team.">>,
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

## Supervised declarative workflows

`adk_workflow` executes each accepted workflow under `adk_workflow_sup`.
Potentially blocking actions run in monitored, linked lightweight processes;
one absolute deadline covers the entire workflow. State is JSON-safe and each
action returns a state delta rather than mutating shared state.

Each coordinator child specification contains only an opaque launch reference.
Compiled closures, initial state, options, checkpoints, ledger handles and
owner tokens cross a validated one-shot handoff and are omitted from OTP
diagnostics. Compound action, cancellation, engine and ledger failures become
bounded structural `adk_failure` values before they reach public status or
durable storage; stable atom reasons remain compatible.

Sequential and bounded-parallel workflows use the same compiled public API:

```erlang
AddOne = fun(State) ->
    {ok, #{<<"count">> => maps:get(<<"count">>, State, 0) + 1}}
end,
MarkDone = fun(_State) ->
    {complete, <<"ready">>, #{<<"done">> => true}}
end,
SequentialSpec = #{
    version => 1,
    id => <<"readme-sequential-v1">>,
    kind => sequential,
    max_steps => 4,
    steps => [
        #{id => <<"increment">>, run => AddOne},
        #{id => <<"finish">>, run => MarkDone}
    ]
},
{ok, Sequential} = erlang_adk:compile_workflow(SequentialSpec),
{completed, SequentialState, SequentialCheckpoint} =
    erlang_adk:run_workflow(Sequential, #{<<"count">> => 0}),
1 = maps:get(<<"count">>, SequentialState),
true = maps:get(<<"done">>, SequentialState),
true = maps:get(<<"completed">>, SequentialCheckpoint),

ParallelSpec = #{
    version => 1,
    id => <<"readme-parallel-v1">>,
    kind => parallel,
    max_concurrency => 2,
    merge => reject_conflicts,
    branches => [
        #{id => <<"left">>,
          run => fun(_State) -> {ok, #{<<"left">> => 1}} end},
        #{id => <<"right">>,
          run => fun(_State) -> {ok, #{<<"right">> => 2}} end}
    ]
},
{ok, Parallel} = erlang_adk:compile_workflow(ParallelSpec),
{completed, ParallelState, _ParallelCheckpoint} =
    erlang_adk:run_workflow(Parallel, #{}),
1 = maps:get(<<"left">>, ParallelState),
2 = maps:get(<<"right">>, ParallelState).
```

Parallel branches receive the same immutable input state. The default
`reject_conflicts` merge rejects unequal writes to one key; use
`ordered_last_wins` only when declared branch order should resolve conflicts.
Completion order never changes merge order.

Loop, collaborative transfer, and dynamic graph routing are also first-class
specifications:

```erlang
LoopSpec = #{
    version => 1,
    id => <<"readme-loop-v1">>,
    kind => loop,
    max_iterations => 3,
    body => fun(State) ->
        {ok, #{<<"attempt">> =>
                   maps:get(<<"attempt">>, State, 0) + 1}}
    end,
    until => fun(State) -> maps:get(<<"attempt">>, State) >= 2 end
},
{ok, Loop} = erlang_adk:compile_workflow(LoopSpec),
{completed, #{<<"attempt">> := 2}, _} =
    erlang_adk:run_workflow(Loop, #{}),

TransferSpec = #{
    version => 1,
    id => <<"readme-transfer-v1">>,
    kind => transfer,
    entry => <<"triage">>,
    max_transfers => 1,
    members => #{
        <<"triage">> => #{run => fun(_State, _Context) ->
            {transfer, <<"specialist">>, <<"handoff">>,
             #{<<"triaged">> => true}}
        end},
        <<"specialist">> => #{run => fun(State, Context) ->
            true = maps:get(<<"triaged">>, State),
            <<"handoff">> = maps:get(input, Context),
            {complete, <<"resolved">>,
             #{<<"resolved">> => true}}
        end}
    }
},
{ok, Transfer} = erlang_adk:compile_workflow(TransferSpec),
{completed, #{<<"resolved">> := true}, _} =
    erlang_adk:run_workflow(Transfer, #{}),

GraphSpec = #{
    version => 1,
    id => <<"readme-graph-v1">>,
    kind => graph,
    entry => <<"counter">>,
    max_steps => 5,
    nodes => [#{id => <<"counter">>, run => fun(State) ->
        {ok, #{<<"count">> => maps:get(<<"count">>, State, 0) + 1}}
    end}],
    edges => #{<<"counter">> => {route, fun(State) ->
        case maps:get(<<"count">>, State) < 3 of
            true -> <<"counter">>;
            false -> end_node
        end
    end}}
},
{ok, Graph} = erlang_adk:compile_workflow(GraphSpec),
{completed, #{<<"count">> := 3}, _} =
    erlang_adk:run_workflow(Graph, #{}).
```

Graph-native fork/join executes declared branch node IDs in bounded lightweight
processes and merges their deltas in declared order. A paused graph commits the
node delta first; resuming supplies JSON-safe input to the node's edge router,
so the paused node is not executed twice:

```erlang
ForkJoinSpec = #{
    version => 1, id => <<"readme-fork-join-v1">>, kind => graph,
    entry => <<"fork">>, max_steps => 6,
    nodes => [
        #{id => <<"fork">>, type => fork,
          branches => [<<"left">>, <<"right">>], join => <<"join">>,
          merge => reject_conflicts, max_concurrency => 2},
        #{id => <<"left">>, run => fun(_) ->
            {ok, #{<<"left">> => 1}}
        end},
        #{id => <<"right">>, run => fun(_) ->
            {ok, #{<<"right">> => 2}}
        end},
        #{id => <<"join">>, type => join}
    ],
    edges => #{<<"left">> => <<"join">>,
               <<"right">> => <<"join">>,
               <<"join">> => end_node}
},
{ok, ForkJoin} = erlang_adk:compile_workflow(ForkJoinSpec),
{completed, #{<<"left">> := 1, <<"right">> := 2}, _} =
    erlang_adk:run_workflow(ForkJoin, #{}),

ApprovalSpec = #{
    version => 1, id => <<"readme-graph-approval-v1">>, kind => graph,
    entry => <<"approval">>, max_steps => 3,
    nodes => [
        #{id => <<"approval">>, run => fun(_) ->
            {pause, human_approval, <<"Approve this action">>,
             #{<<"approval_requested">> => true}}
        end},
        #{id => <<"accepted">>, run => fun(_) ->
            {ok, #{<<"accepted">> => true}}
        end}
    ],
    edges => #{
        <<"approval">> => {route, fun(_State, Context) ->
            true = maps:get(<<"approved">>, maps:get(input, Context)),
            <<"accepted">>
        end},
        <<"accepted">> => end_node}
},
{ok, Approval} = erlang_adk:compile_workflow(ApprovalSpec),
{paused, _PauseDetails, ApprovalCheckpoint} =
    erlang_adk:run_workflow(Approval, #{}),
{ok, ApprovalRef} = erlang_adk:resume_workflow(
    Approval, ApprovalCheckpoint,
    #{resume_input => #{<<"approved">> => true}}),
{completed, #{<<"approval_requested">> := true,
              <<"accepted">> := true}, _} =
    erlang_adk:await_workflow(ApprovalRef).
```

For recovery after the workflow coordinator, application, or BEAM restarts,
use a stable invocation ID backed by the Mnesia ledger. The compiled workflow
is application code and must be reconstructed with the same `id`, `version`,
and `kind` before resuming:

```erlang
{ok, LedgerHandle} = adk_invocation_ledger_mnesia:init(#{}),
DurableOptions = #{
    ledger => {adk_invocation_ledger_mnesia, LedgerHandle},
    lease_ms => 30000,
    timeout => 120000
},
{ok, DurableInvocationId, DurableApprovalRef} =
    erlang_adk:start_workflow_invocation(Approval, #{}, DurableOptions),
{paused, _DurablePause, _DurableCheckpoint} =
    erlang_adk:await_workflow(DurableApprovalRef),
{ok, #{phase := paused, owned := false}} =
    erlang_adk:workflow_invocation_status(
      DurableInvocationId, DurableOptions),

%% After reconstructing Approval in a restarted application:
{ok, DurableResumedRef} = erlang_adk:resume_workflow_invocation(
    DurableInvocationId, Approval,
    DurableOptions#{resume_input => #{<<"approved">> => true}}),
{completed, #{<<"approval_requested">> := true,
              <<"accepted">> := true}, _} =
    erlang_adk:await_workflow(DurableResumedRef),
ok = erlang_adk:delete_workflow_invocation(
       DurableInvocationId, DurableOptions).
```

The ledger checkpoints before the engine receives permission to start the
next action and renews a fenced ownership lease while work is active. Renew,
checkpoint and finish require the matching token and `Now < lease_until` in
one Mnesia transaction; equality is expired. Expiry permits one atomic
takeover even if an old local PID is still alive, after which its token is
stale. Recovery is at-least-once only for an action whose external side effect
happened before its result was durably committed; use the stable
invocation/step context as an idempotency key. See
[durable workflow invocations](docs/DURABLE_INVOCATIONS.md) for restart,
replication, retention, and encryption-at-rest guidance.

`branch` and `dynamic` nodes can only select IDs listed in their `targets`;
`loop` nodes require `body`, `done`, and `max_iterations`. Typed `agent`,
`tool`, and nested `workflow` nodes are compiled from application-owned
descriptors. No route may introduce an MFA, source string, or undeclared node
at runtime. Completed fork branches and completed graph nodes are checkpointed
individually; only an in-flight action that has not reached a commit boundary
has at-least-once replay semantics.

A transfer is an ownership handoff, unlike a sub-agent tool call which returns
to its caller. Every accepted handoff emits an `adk_event` action named
`<<"transfer_to_agent">>` and consumes the transfer budget. Agent-backed
actions can use `{agent, RegisteredName, Prompt}` or
`{agent, RegisteredName, Prompt, DecisionFun}`; the binary name is resolved at
dispatch time so a supervised replacement is used after an agent restart.

Checkpoints are committed only at deterministic boundaries and retain the
remaining budgets. Cancellation kills active workflow workers; resuming does
not replay already committed steps or replenish consumed attempts:

```erlang
Parent = self(),
WaitForRelease = fun(_State) ->
    Parent ! {workflow_waiting, self()},
    receive
        continue -> {ok, #{<<"released">> => true}}
    end
end,
ResumeSpec = #{
    version => 1,
    id => <<"readme-resume-v1">>,
    kind => sequential,
    max_steps => 2,
    steps => [#{id => <<"wait">>, run => WaitForRelease}]
},
{ok, ResumeCompiled} = erlang_adk:compile_workflow(ResumeSpec),
{ok, WorkflowRef} = erlang_adk:start_workflow(ResumeCompiled, #{}),
FirstWorker = receive {workflow_waiting, Pid1} -> Pid1 end,
FirstWorkerMonitor = erlang:monitor(process, FirstWorker),
{ok, #{state := running}} = erlang_adk:workflow_status(WorkflowRef),
{ok, Checkpoint} = erlang_adk:workflow_checkpoint(WorkflowRef),
ok = erlang_adk:cancel_workflow(WorkflowRef, revise_later),
{cancelled, revise_later, Checkpoint} =
    erlang_adk:await_workflow(WorkflowRef),
receive
    {'DOWN', FirstWorkerMonitor, process, FirstWorker, _} -> ok
end,

{ok, ResumedRef} =
    erlang_adk:resume_workflow(ResumeCompiled, Checkpoint),
SecondWorker = receive {workflow_waiting, Pid2} -> Pid2 end,
SecondWorker ! continue,
{completed, #{<<"released">> := true}, _} =
    erlang_adk:await_workflow(ResumedRef).
```

The action-result contract is `{ok, Delta}`,
`{complete, Output, Delta}`, `{route, TargetNode, Delta}`,
`{transfer, TargetMember, NextInput, Delta}`, or `{error, Reason}`. Graph
actions additionally accept `{pause, Reason, Summary, Delta}`. Runtime
options include `timeout` or an absolute monotonic `deadline`, `max_steps`,
`max_transfers`, `max_concurrency`, and terminal `retention_ms`.

## Explicit planning and replanning

Model-native thinking and executable plans are deliberately separate. Gemini
thinking configuration controls how that provider produces an answer; it does
not expose private reasoning as an executable plan. For an application-owned
plan, use a trusted `adk_planner` and `adk_plan_executor`. The executor maps a
small declared JSON action vocabulary to application operations, while the
runtime supplies monitored lightweight processes, one absolute deadline,
step/replan/heap/byte budgets, cancellation, and secret-pruned results.

The repository examples are deterministic and executable from `./rebar3 shell`:

```erlang
{ok, readme_planner} = c("examples/readme_planner.erl"),
{ok, readme_plan_executor} = c("examples/readme_plan_executor.erl"),

Planner = #{module => readme_planner,
            target => undefined,
            config => #{}},
Executor = #{module => readme_plan_executor,
             target => undefined,
             config => #{}},
Goal = #{<<"task">> => <<"prepare release">>},
Context = #{<<"invocation_id">> => <<"planning-readme">>},

{ok, PlanningResult} = erlang_adk:run_planning(
    Planner, Executor, Goal, Context,
    #{max_steps => 4,
      max_replans => 1,
      timeout_ms => 5000}),
<<"completed">> = maps:get(<<"status">>, PlanningResult),
1 = maps:get(<<"steps_executed">>, PlanningResult),
#{<<"goal">> := Goal,
  <<"invocation_id">> := <<"planning-readme">>} =
    maps:get(<<"result">>, PlanningResult).
```

For caller-controlled cancellation, use `start_planning/5`,
`cancel_planning/2`, and `await_planning/2`. The returned opaque reference is
owned by the starting process: another process cannot await or cancel it, and
owner death stops the runtime and its active callback. Planner and executor
module atoms always come from trusted application configuration; values in a
plan can never select a module or evaluate Erlang/source/shell code. See the
[planning runtime contract](docs/PLANNING_RUNTIME.md) for the canonical plan
schema, adapter behaviours, failure values, and all limits.

## Legacy graph helpers

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
    #{run_timeout => 120000,
      max_llm_calls => 32,
      max_tool_rounds => 16,
      streaming_mode => text,
      max_stream_output_bytes => 16777216,
      admission_control => #{overflow => queue,
                             queue_timeout => 5000},
      runtime_policy =>
          #{id => <<"readme-runner-policy">>,
            agents => #{allow => [<<"RunnerAgent">>]},
            tools => #{allow => []},
            max_argument_bytes => 32768,
            max_content_bytes => 262144},
      context_policy => #{max_bytes => 32768,
                          max_tokens => 8192,
                          overflow => truncate}}),
{ok, RunnerResponse} = adk_runner:run(
    Runner, <<"user-1">>, <<"session-1">>, <<"Hello">>),
io:format("~ts~n", [RunnerResponse]).
```

`streaming_mode => text` makes the Runner use the provider's UTF-8 delta
stream. `content` selects canonical `adk_content` deltas, and the default
`none` uses one-shot generation. Provider I/O executes in the independently
supervised invocation worker rather than the agent `gen_server` mailbox, so
the agent remains responsive to runtime inspection and cancellation routing.
The short preparation/finalization calls are still serialized by that agent.

`max_stream_output_bytes` bounds one model round's accumulated callback
payload (16 MiB by default, with a 64 MiB hard ceiling). Canonical content is
also subject to its part, text, inline-data, URI, and function-payload limits.
An unsupported provider content stream, invalid UTF-8/content delta, empty
stream, or exceeded bound fails the invocation explicitly.

`run_timeout` is the overall synchronous Runner deadline. A non-streaming model
round invoked through `adk_agent:run_with_events/3` has a separate 60-second
`gen_server` call limit by default, so a larger Runner deadline can cover
several model/tool rounds but does not itself extend one non-streaming model
round. Applications that need a different agent call limit can set the
`erlang_adk` application environment key `agent_call_timeout` to a non-negative
number of milliseconds (or `infinity`); `adk_agent:prompt/2` and
`run_with_events/3,4` use it. Blocking direct-turn workers have the separate
`agent_turn_timeout` setting, also 60 seconds by default, so work is cancelled
and cleaned up even when a caller process survives its `gen_server` call
timeout. Set both values when intentionally allowing longer turns; explicit
`infinity` is an opt-in for either boundary.

Use one active Runner invocation per session. Independent agents and sessions can run concurrently, but sharing one session between simultaneous invocations can interleave event history and invocation-temp state.

`max_llm_calls` and `max_tool_rounds` are independent invocation budgets. They
default to 32 and 16 respectively and prevent an otherwise valid model/tool
conversation from looping forever.

`context_policy` filters and measures canonical, credential-scrubbed session
events before each model call. `overflow => truncate` keeps the newest suffix;
`error` fails explicitly, while `compress` requires a monitored compressor with
timeout, heap, event-count, and output-size bounds. Author, invocation, content
type, time-range, partial, and final-event filters are supported. The current
invocation's user event may not be filtered out. Context-build telemetry is
emitted as `[erlang_adk, context, build]` with byte/token estimates, dropped
event count, and a secret-free cache key. The estimate covers selected events
and retrieved memory; agent instruction bytes have their own
`max_instruction_bytes` bound, and exact provider tokenization remains an
adapter concern.

### Admission control and runtime policy

The application always supervises one `adk_admission_control` process. A
Runner opts into it with `admission_control => #{...}`. `reject` returns a busy
error immediately; `queue` uses a bounded queue and an absolute monotonic
deadline derived from `queue_timeout`. Limits are global and per agent. The
invocation worker owns its permit, so normal completion releases it explicitly
and an untrappable cancellation, timeout, or crash releases it through the
controller's process monitor.

Configure node-wide limits before application startup (for example in
`sys.config`):

```erlang
[{erlang_adk,
  [{admission_control,
    #{global_limit => 256,
      default_agent_limit => 16,
      agent_limits => #{<<"BatchAgent">> => 4},
      overflow => reject,
      max_queue => 1024,
      default_queue_timeout => 30000}}]}].
```

`runtime_policy` is optional, but once configured it is fail-closed. An omitted
agent/tool allow selector means no names are allowed; use `allow => all`
explicitly when intended, and `deny` always wins. Binary content is measured as
UTF-8 payload bytes, while structured content and final resolved tool arguments
are measured as canonical JSON. Finite defaults are 64 KiB for arguments and
1 MiB for content.

Tool policy runs after Erlang module/OpenAPI/MCP/dynamic-toolset resolution but
before global/local tool callbacks and human approval. A denied tool therefore
cannot execute, invoke policy-bypass callbacks, or become an approval request.
It becomes a bounded structural tool error so the model can continue. Input,
tool-result, and final-output budget failures never persist the rejected value.

Every denial is persisted and streamed as a canonical `system` event whose
`actions` contains `<<"runtime_policy_decision">>`. The immutable decision has
IDs, policy fingerprint, operation, subject, outcome/reason, and byte counts;
it never contains arguments, content, credentials, exception terms, pids, or
references. Audit events deliberately bypass mutable `on_event` plugins. See
[Runtime safety and admission control](docs/RUNTIME_SAFETY.md) for the direct
API, telemetry fields, release semantics, and Phoenix ownership guidance.

For application-facing asynchronous work, prefer the supervised run API. The
run is not owned by the process that starts it or by a browser subscriber, so a
caller disconnect does not terminate useful work:

Each dynamic invocation child specification contains only a fresh opaque
reference. The run ID, Runner handle, request/prompt, and options cross a
validated one-shot handoff after the empty child starts; a rejected handoff or
duplicate-registration loser is cleaned up synchronously. OTP diagnostic
status exposes only bounded lifecycle counters, while the explicit
`adk_run:status/1` API continues to return the caller's run ID and outcome.

```erlang
{ok, RunId} = adk_run:start(
    Runner, <<"user-1">>, <<"session-supervised">>,
    <<"Explain supervisors.">>,
    #{retention_ms => 60000, max_buffered_events => 256}),
ok = adk_run:subscribe(RunId),
ReceiveRun = fun Loop(Id) ->
    receive
        {adk_run_event, Id, Sequence, Event} ->
            io:format("~p ~p~n", [Sequence, adk_event:to_map(Event)]),
            Loop(Id);
        {adk_run_terminal, Id, _Sequence, Outcome} ->
            Outcome
    after 120000 ->
        {error, subscriber_timeout}
    end
end,
{completed, SupervisedText} = ReceiveRun(RunId),
io:format("~ts~n", [SupervisedText]),
{ok, #{state := completed}} = adk_run:status(RunId).
```

Late subscribers receive the bounded replay followed by the same terminal
outcome while the run is retained. `adk_run:await/1,2` waits without subscribing;
`adk_run:cancel/1,2` propagates cancellation to the Runner worker. For a slow
network or broker boundary, use `adk_run:subscribe_credit/2,3` with the last
consumed sequence and return credit through `adk_run:ack/2,3`; this permits at
most one unacknowledged run message per subscriber and reports a `replay_gap`
instead of silently skipping events. The original `subscribe/1,2` push API is
preserved for local Erlang processes that continuously drain their mailbox.

With provider streaming, each delta is persisted as
`#adk_event{partial = true}`. One
`is_final = true` event contains the complete response, and the completed run
outcome contains that same response exactly once. A UI should append/render
partials provisionally, then replace that provisional view with the final
snapshot; it must not append the final snapshot to the partial text. Partial
events remain replayable but are excluded from the next model turn's history.
Exactly one terminal outcome is committed: `{completed, Output}` (a UTF-8
binary or canonical `adk_content`), `{paused, Event}`,
`{cancelled, Reason}`, or `{failed, Reason}`.

Resume a supervised paused run through `adk_run`, not by turning the approval
into a new user prompt:

```erlang
{paused, _PauseEvent} = adk_run:await(PausedRunId, 120000),
{ok, ResumedRunId} = adk_run:resume(
    PausedRunId,
    #{<<"approved">> => true, <<"approver">> => <<"operator@example.com">>},
    #{retention_ms => 60000, max_buffered_events => 256}),
{completed, ResumedText} = adk_run:await(ResumedRunId, 120000).
```

The original paused run stays immutable. Its status exposes `resumed_to`; the
new run exposes `parent_run_id`. A second resume returns
`{error, {already_resumed, ResumedRunId}}`.

### Ambient/background invocation

Register an application-owned Runner once, then synchronously submit each
delivery into a bounded queue. Submission returns immediately with a stable
event reference; the invocation and its retry lifecycle are owned by
supervised lightweight processes rather than by the HTTP/queue consumer:

```erlang
ok = adk_ambient:register_trigger(
    <<"inbox-events">>, Runner,
    #{max_concurrency => 8,
      max_queue => 256,
      event_timeout => 120000,
      retention_ms => 300000,
      max_retained => 1000,
      max_event_bytes => 1048576,
      session_policy => #{mode => per_event,
                          user_id => <<"background-worker">>,
                          prefix => <<"inbox-">>},
      retry => #{max_attempts => 3,
                 initial_delay => 250,
                 max_delay => 5000,
                 backoff_factor => 2.0,
                 attempt_timeout => 30000,
                 max_heap_words => 1000000,
                 jitter => full}}),

Delivery = #{payload => <<"Summarize message 42">>,
             idempotency_key => <<"mailbox:42:v1">>,
             metadata => #{source => <<"local-queue">>}},
{ok, AmbientRef} = adk_ambient:submit(<<"inbox-events">>, Delivery),
{completed, #{run_id := _AmbientRunId,
              output := AmbientOutput}} =
    adk_ambient:await(AmbientRef, 120000),
io:format("~ts~n", [AmbientOutput]),
{ok, #{state := terminal, attempts := _AttemptCount}} =
    adk_ambient:status(AmbientRef).
```

Every event must carry a non-empty `idempotency_key`. A duplicate returns
`{ok, ExistingRef, duplicate}` and cannot start a second invocation while the
original result is retained. Dedupe and trigger registration are node-local
and bounded by `retention_ms`, `max_retained`, and the application-wide
`ambient_runtime.max_events`; a durable broker should redeliver until its
adapter has successfully called `submit/2`. Retried invocations reuse the same
session, so tools called by a retry must also be idempotent.

Session ownership cannot be implicit. `per_event` derives a separate stable
session from the idempotency key; `explicit` requires
`session => #{user_id => ..., session_id => ...}` on every event; `shared`
uses one configured session and should only be selected when interleaved
history is intended. Per-event `timeout_ms` may shorten, but never extend, the
registered event deadline. Queue wait, retry backoff, and run execution consume
that one absolute deadline. `cancel/2` covers both queued and active events and
publishes a terminal result only after the run and admission permit are cleaned
up.

The bundled schedule source owns one fixed-delay timer and also submits through
the same bounded path:

```erlang
{ok, SchedulePid} = adk_trigger_schedule:start(
    <<"inbox-events">>, <<"hourly-inbox-summary">>, 3600000,
    #{payload => <<"Summarize the last hour">>},
    #{initial_delay_ms => 3600000}),
{ok, #{type := schedule, interval_ms := 3600000}} =
    adk_trigger_schedule:status(SchedulePid),
ok = adk_trigger_schedule:stop(SchedulePid),
ok = adk_ambient:unregister_trigger(<<"inbox-events">>).
```

`adk_trigger_source` is the provider-neutral OTP behaviour for additional
sources. Pub/Sub, Eventarc, Kafka, RabbitMQ, cron services, and cloud push
verification remain deployment adapters; the core deliberately has no cloud
SDK dependency. Adapters apply backpressure by calling `submit/2`, acknowledge
only after acceptance, and use the provider delivery ID as the idempotency key.
The bundled scheduler is fixed-delay, not a cron parser.
See the [ambient runtime contract](docs/AMBIENT_RUNTIME.md) for every option,
outcome, cleanup guarantee, and adapter responsibility.

The lower-level Runner stream remains available when a caller deliberately
wants to own and drain the mailbox protocol:

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
        PauseMap = adk_event:to_map(PauseEvent),
        #{<<"pause">> :=
              #{<<"continuation_id">> := ContinuationId}} =
            maps:get(<<"actions">>, PauseMap),
        {ok, ResumePid} = adk_runner:resume(
            ApprovalRunner, <<"user-1">>, <<"approval-session">>,
            ContinuationId,
            #{approved => true, approver => <<"operator@example.com">>}),
        ok = ApprovalDrain(ResumePid);
    {ok, UnexpectedFinal} ->
        io:format("model completed without pausing: ~ts~n", [UnexpectedFinal]);
    {error, ApprovalReason} ->
        io:format("approval workflow failed: ~p~n", [ApprovalReason])
end,
ok = erlang_adk:stop_agent(ApprovalPid).
```

Use `resume/5` with the public continuation/invocation ID whenever concurrent
invocations can share a session. `resume/4` is a compatibility convenience and
returns `{error, {ambiguous_paused_invocation, InvocationIds}}` if more than one
pause exists. A continuation is consumed atomically; replay returns
`{error, no_paused_invocation}`. Temp state is retained while paused and removed
after the resumed invocation completes or fails. Erlang maps returned by tools
are normalized to JSON-safe binary keys, so the atom-keyed approval map above
round-trips through event JSON safely.

### Generic long-running operations

A pause-capable tool can suspend without keeping a worker process blocked:

```erlang
adk_suspension:long_running(
    <<"export-42">>, <<"The external export is running.">>).
```

The application records correlated non-terminal updates while the continuation
remains resumable, then supplies one terminal response:

```erlang
PauseMap = adk_event:to_map(PauseEvent),
InvocationId = maps:get(<<"invocation_id">>, PauseMap),
{ok, _ProgressEvent} = adk_runner:update_long_running(
    Runner, <<"user-1">>, <<"export-session">>, InvocationId,
    <<"export-42">>,
    #{<<"operation_id">> => <<"export-42">>,
      <<"status">> => <<"running">>,
      <<"progress">> => 50}),
{ok, _ResumeStream} = adk_runner:resume(
    Runner, <<"user-1">>, <<"export-session">>, InvocationId,
    #{<<"operation_id">> => <<"export-42">>,
      <<"status">> => <<"completed">>,
      <<"result">> => #{<<"artifact_id">> => <<"export.zip">>}}).
```

Operation ID and terminal status are checked before the continuation is
claimed. ETS and Mnesia sessions atomically order progress against terminal
resume, so a racing update cannot attach to a consumed or different operation.
Custom session backends must implement `add_event_if_state/6` to support
progress updates.

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
      <<"app:release">> => <<"0.3.0">>,
      <<"temp:lookup">> => <<"in-flight">>}),
{ok, StoredSession} = erlang_adk_session:get_session(
    AppName, UserId, SessionId),
StoredState = maps:get(state, StoredSession),
<<"dark">> = maps:get(<<"user:preferences">>, StoredState),

{ok, FutureSession} = erlang_adk_session:create_session(
    AppName, UserId, #{session_id => <<"state-session-2">>}),
FutureState = maps:get(state, FutureSession),
<<"dark">> = maps:get(<<"user:preferences">>, FutureState),
<<"0.3.0">> = maps:get(<<"app:release">>, FutureState),
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

Mnesia is no longer started by the default application path. To make it the
configured backend and fail application startup if it cannot initialize, set
the backend before starting `erlang_adk`:

```erlang
_ = application:stop(erlang_adk),
ok = application:set_env(
    erlang_adk, session_backend, erlang_adk_session_mnesia),
{ok, _} = application:ensure_all_started(erlang_adk).
```

The older agent `session_id` option persists that agent's conversation history through the backend's legacy `save/2` and `load/1` API. Runner sessions are the recommended event/state API.

For authenticated, snapshot-bound pagination and non-destructive rewind, use
`adk_session_query`. Cursor secrets belong in application secret storage and
must be stable across the nodes that serve a cursor:

```erlang
QuerySecret = adk_session_query:new_cursor_secret(),
QueryApp = <<"query_app">>,
QueryUser = <<"user-1">>,
SourceSession = <<"query-a">>,
BranchSession = <<"query-a-before-answer">>,
{ok, _} = erlang_adk_session:create_session(
    QueryApp, QueryUser, #{session_id => SourceSession}),
ok = erlang_adk_session:add_event(
    QueryApp, QueryUser, SourceSession,
    adk_event:with_state_delta(
        adk_event:new(<<"user">>, <<"question">>),
        #{<<"step">> => 1})),
ok = erlang_adk_session:add_event(
    QueryApp, QueryUser, SourceSession,
    adk_event:with_state_delta(
        adk_event:new(<<"agent">>, <<"answer">>, #{is_final => true}),
        #{<<"step">> => 2})),

{ok, SessionPage} = adk_session_query:list(
    erlang_adk_session, QueryApp, QueryUser,
    #{limit => 10, cursor_secret => QuerySecret}),
[_ | _] = maps:get(sessions, SessionPage),
{ok, EventPage} = adk_session_query:get(
    erlang_adk_session, QueryApp, QueryUser, SourceSession,
    #{event_limit => 1, cursor_secret => QuerySecret}),
#{next_cursor := EventCursor} = maps:get(event_page, EventPage),
true = is_binary(EventCursor),

{ok, #{session_id := BranchSession, events_copied := 1}} =
    adk_session_query:rewind(
        erlang_adk_session, QueryApp, QueryUser, SourceSession,
        {index, 1}, #{target_session_id => BranchSession}),
{ok, SourceAfterRewind} = erlang_adk_session:get_session(
    QueryApp, QueryUser, SourceSession),
2 = length(maps:get(events, SourceAfterRewind)),
ok = erlang_adk_session:delete_session(
    QueryApp, QueryUser, SourceSession),
ok = erlang_adk_session:delete_session(
    QueryApp, QueryUser, BranchSession).
```

List and event cursors are HMAC-authenticated and bound to the complete
snapshot, scope, filter, order, and page size. A changed source returns
`stale_cursor`; a forged or cross-scope cursor returns `invalid_cursor`.
Rewind always creates a new session and never edits its source. Replay of
`temp:` deltas is blocked, while `app:`/`user:` deltas require an explicit
shared-state opt-in.

## Callbacks and telemetry

The repository callback example uses the actual provider-result contract:

```erlang
-module(readme_audit_callback).
-behaviour(adk_callbacks).

-export([set_observer/1, clear_observer/0,
         before_model/3, after_model/2, before_tool/3, after_tool/4]).

set_observer(Pid) when is_pid(Pid) ->
    persistent_term:put({?MODULE, observer}, Pid),
    ok.

clear_observer() ->
    persistent_term:erase({?MODULE, observer}),
    ok.

before_model(_Config, _Memory, Tools) ->
    notify({before_model, length(Tools)}),
    ok.

after_model(_Config, ProviderResult) ->
    notify({after_model, ProviderResult}),
    ok.

before_tool(_ToolName, _Args, _Context) -> ok.
after_tool(_ToolName, _Args, _Context, _ToolResult) -> ok.

notify(Message) ->
    case persistent_term:get({?MODULE, observer}, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.
```

Attach it to an agent:

```erlang
{ok, readme_audit_callback} = c("examples/readme_audit_callback.erl"),
ok = readme_audit_callback:set_observer(self()),
CallbackConfig = #{provider => adk_llm_gemini,
                   callbacks => [readme_audit_callback]},
{ok, CallbackPid} = erlang_adk:spawn_agent(
    <<"CallbackAgent">>, CallbackConfig, []),
{ok, _CallbackResponse} = erlang_adk:prompt(
    CallbackPid, <<"Say hello.">>),
receive {before_model, ToolCount} -> io:format("~p tools~n", [ToolCount]) end,
receive {after_model, ProviderResult} -> io:format("~p~n", [ProviderResult]) end,
ok = readme_audit_callback:clear_observer(),
ok = erlang_adk:stop_agent(CallbackPid).
```

Before-hooks return `ok`/`continue`, `{halt, ProviderResult}` to skip the
operation, or `{replace, Value}`. After-hooks can return `{replace, Value}`.
Callback modules are loaded on demand; callback exceptions do not crash the
agent. Failures delivered to error hooks, public outcomes, model-visible tool
responses, and logs contain bounded structural tags only—never a raw exception
reason, stacktrace, provider response body, or agent configuration.

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

## Multimodal content

`adk_content` is the provider-neutral, versioned, JSON-safe content boundary.
It supports text, base64-encoded inline bytes, `https://`/`gs://` file
references, function calls, and function responses. Constructors validate
before returning; raw inline bytes are converted to canonical base64 so a
content value can safely cross process, event, session, and JSON boundaries:

```erlang
TinyPng = base64:decode(
    <<"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=">>),
{ok, PromptPart} = adk_content:text(<<"Describe this image briefly.">>),
{ok, ImagePart} = adk_content:inline_data(<<"image/png">>, TinyPng),
{ok, MultimodalPrompt} = adk_content:new([PromptPart, ImagePart]),

{ok, MultimodalResult} = adk_llm:generate(
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>},
    [#{role => user, content => MultimodalPrompt}], []),
case MultimodalResult of
    Text when is_binary(Text) -> io:format("~ts~n", [Text]);
    Content when is_map(Content) ->
        {ok, Content} = adk_content:validate(Content),
        io:format("multimodal response: ~p~n", [Content])
end.
```

Text-only responses retain the existing `{ok, Utf8Binary}` API. If Gemini
returns inline or referenced media, the successful value is the canonical
`adk_content` map instead of lossy JSON text. The same content value can be
used as a direct-agent or Runner input; final multimodal output is preserved as
structured event content rather than coerced to a printable Erlang term.

Validation defaults are intentionally below transport maxima: 64 parts, 1 MiB
per text part, 10 MiB per inline part, 15 MiB of inline data in total, 4 KiB
per URI, and 1 MiB per function payload. An application may lower limits with
`content_limits`; ceilings prevent configuration from disabling the safety
boundary. MIME types must be lowercase `type/subtype` values without
parameters. File parts reject relative URIs, credentials, fragments, local
`file://`, `http://`, and `data:` URIs. Fetching a permitted remote URI is a
Gemini service operation—the Erlang adapter does not fetch it locally.

The existing `adk_llm:stream/4` remains a UTF-8 text-delta API and fails with
`{error, {unsupported_text_stream_part, Type}}` rather than silently dropping
media. Use the Gemini adapter's content stream when every decoded SSE frame
must remain structured:

```erlang
ContentCallback = fun(ContentDelta) ->
    {ok, ContentDelta} = adk_content:validate(ContentDelta),
    io:format("content delta: ~p~n", [ContentDelta])
end,
ok = adk_llm_gemini:stream_content(
    #{model => <<"gemini-3.1-flash-lite">>},
    [#{role => user, content => MultimodalPrompt}], [], ContentCallback).
```

`stream_content/4` invokes the callback once per decoded provider frame; it
does not append a second buffered final content value. Gemini Live's
bidirectional WebSocket lifecycle (audio/video input, interruption, session
resumption, and backpressure) is a separate protocol and is explicitly
unsupported in v0.3.0 rather than being simulated through REST SSE.

To put that structured stream through sessions, plugins, stable run replay,
and cancellation, select content streaming on the Runner:

```erlang
{ok, ContentRunnerAgentPid} = erlang_adk:spawn_agent(
    <<"ContentRunnerAgent">>,
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>,
      instructions => <<"Describe supplied media concisely.">>}, []),
ContentRunner = adk_runner:new(
    ContentRunnerAgentPid, <<"readme_app">>, erlang_adk_session,
    #{streaming_mode => content,
      max_stream_output_bytes => 16777216,
      run_timeout => 120000}),
{ok, ContentRunId} = adk_run:start(
    ContentRunner, <<"user-1">>, <<"multimodal-session">>,
    MultimodalPrompt),
{completed, FinalContent} = adk_run:await(ContentRunId, 120000),
{ok, FinalContent} = adk_content:validate(FinalContent),
ok = adk_run:subscribe(ContentRunId),
DrainContentReplay = fun Loop(Id, Events) ->
    receive
        {adk_run_event, Id, _Sequence, Event} ->
            Loop(Id, [adk_event:to_map(Event) | Events]);
        {adk_run_terminal, Id, _Sequence, Outcome} ->
            {lists:reverse(Events), Outcome}
    after 120000 ->
        {error, replay_timeout}
    end
end,
{ContentEvents, {completed, FinalContent}} =
    DrainContentReplay(ContentRunId, []),
[_ | _] = ContentEvents,
ok = adk_run:unsubscribe(ContentRunId),
ok = erlang_adk:stop_agent(ContentRunnerAgentPid).
```

`subscribe/1` and `await/2` are independent mailbox protocols. A subscriber
must drain through `adk_run_terminal` and unsubscribe (or terminate and let its
monitor clean up); merely calling `await/2` does not consume replay messages.

Streaming function-call parts remain control data: they do not appear as
provisional display content, and the Runner continues through its ordinary
correlated tool-call/tool-response rounds. A provider-originated
`function_response` part is rejected because function responses belong to the
tool/user side of the conversation.

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

## MCP clients and Streamable HTTP server

`connect/2` performs the MCP initialize handshake before returning. This repository-verifiable example uses the included line-delimited JSON-RPC fixture; replace the command with your own stdio MCP server in production:

The implementation targets the official
[MCP 2025-11-25 lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)
and [Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).

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

The 2025-11-25 Streamable HTTP client and server retain the same lifecycle but
add negotiated protocol/session headers. Each application-managed client is a
temporary child of `adk_mcp_client_sup`; independent MCP sessions therefore do
not share a mailbox or failure domain. This loopback example is also executed
by `readme_examples_test`:

```erlang
Token = <<"replace-with-at-least-16-secret-bytes">>,
Resource = #{uri => <<"memo://otp">>, name => <<"otp-note">>,
             mime_type => <<"text/plain">>,
             read => fun() ->
                 {ok, <<"Supervise every long-lived process.">>}
             end},
Prompt = #{name => <<"explain">>,
           arguments => [#{<<"name">> => <<"topic">>,
                           <<"required">> => true}],
           get => fun(#{<<"topic">> := Topic}) ->
               {ok, #{<<"messages">> =>
                          [#{<<"role">> => <<"user">>,
                             <<"content">> =>
                                 #{<<"type">> => <<"text">>,
                                   <<"text">> => <<"Explain ", Topic/binary>>}}]}}
           end},
{ok, McpServer} = adk_mcp_server:start(
    <<"streamable_http">>,
    #{ip => {127, 0, 0, 1}, port => 0, auth_token => Token,
      tools => [readme_weather_tool],
      resources => [Resource], prompts => [Prompt]}),
{ok, #{url := McpUrl}} = adk_mcp_server:endpoint(McpServer),
AuthFun = fun() ->
    [{<<"authorization">>, <<"Bearer ", Token/binary>>}]
end,
{ok, HttpMcpClient} = adk_mcp_client:connect(
    <<"streamable_http">>, McpUrl, #{auth_fun => AuthFun}),
{ok, McpToolset} = adk_toolset:new(adk_mcp_client, HttpMcpClient),
{ok, [_]} = adk_toolset:expand_tools([McpToolset]),
{ok, [_]} = adk_mcp_client:list_tools(HttpMcpClient),
{ok, WeatherResult} = adk_mcp_client:execute_tool(
    HttpMcpClient, <<"get_weather">>, #{<<"city">> => <<"Pune">>}),
false = maps:get(<<"isError">>, WeatherResult),
{ok, [_]} = adk_mcp_client:list_resources(HttpMcpClient),
{ok, #{<<"contents">> := [_]}} = adk_mcp_client:read_resource(
    HttpMcpClient, <<"memo://otp">>),
{ok, [_]} = adk_mcp_client:list_prompts(HttpMcpClient),
{ok, #{<<"messages">> := [_]}} = adk_mcp_client:get_prompt(
    HttpMcpClient, <<"explain">>, #{<<"topic">> => <<"OTP">>}),
ok = adk_mcp_client:close(HttpMcpClient),
ok = adk_mcp_server:stop(McpServer).
```

Pass `McpToolset` in an agent's tool list to make discovered MCP schemas
model-visible. `adk_mcp_client:resolved_call/4` produces the same bounded call
descriptor used by local and OpenAPI toolsets; invocation context is not sent
to the MCP server.

The server binds to loopback and assigns bounded, expiring sessions by
default. A non-loopback bind requires both authentication and the explicit
`allow_non_loopback => true` acknowledgement. The included listener is clear
HTTP; put it behind trusted TLS termination and network policy before using
that acknowledgement.
Configure `auth_token` (stored only as SHA-256 in listener state) or
an `auth_fun/1` receiving request method/endpoint/origin/peer plus the transient
Authorization header, exact `allowed_origins`, `max_body_bytes`,
`max_response_bytes`, `max_concurrency`, `request_timeout`, `max_sessions`,
and `session_ttl_ms` before exposing it. HTTP bearer/OAuth acquisition remains
an application concern; the client accepts a zero-arity `auth_fun` so a token
manager can supply fresh authorization headers without persisting a token in
the MCP worker state. In production that callback must capture only an opaque
token-manager reference, never the credential itself; MCP client/server status
formatting suppresses callback internals and authentication messages.

This server returns JSON for POST and intentionally returns HTTP 405 for the
optional unsolicited GET/SSE channel. The client accepts JSON and bounded SSE
responses to POST. SSE resumability, resource subscriptions/templates,
notifications, roots, sampling, elicitation, completion, MCP OAuth discovery,
and a server-side stdio transport are explicit 0.3.0 limitations. Endpoint
URLs containing user info, query strings, or fragments are rejected so bearer
credentials cannot accidentally become request URLs. Deprecated
HTTP+SSE (`<<"sse">>`) fails with
`{error, {unsupported_transport, sse_deprecated_use_streamable_http}}`.
The client and server also accept the finalized 2025-06-18 revision during
version negotiation, while initiating new connections with 2025-11-25.

## Runner plugins and observability

Plugins are ordered, Runner-global lifecycle policy. They follow the same
observable ordering as [Google ADK plugins](https://adk.dev/plugins/) while
using a bounded BEAM worker for every hook: global plugin hooks run before the
corresponding agent callback, and an intervention skips that local callback.
Direct `erlang_adk:prompt/2` calls continue to use agent-local callbacks only.

The repository includes the observer and exporter used below. From
`./rebar3 shell`:

```erlang
{ok, readme_policy_plugin} = c("examples/readme_policy_plugin.erl"),
{ok, readme_observability_exporter} =
    c("examples/readme_observability_exporter.erl"),

{ok, ObservedAgent} = erlang_adk:spawn_agent(
    <<"ObservedAgent">>,
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>}, []),
PolicyPlugin =
    #{id => <<"audit-policy">>,
      module => readme_policy_plugin,
      mode => observe,
      failure_policy => closed,
      timeout_ms => 1000,
      max_heap_words => 100000,
      config => #{notify => self()}},
ObservationExporter =
    #{id => <<"console-observer">>,
      module => readme_observability_exporter,
      failure_policy => open,
      timeout_ms => 1000,
      max_heap_words => 100000,
      config => #{target => self()}},
ObservedRunner = adk_runner:new(
    ObservedAgent, <<"observed-app">>, erlang_adk_session,
    #{plugins => [PolicyPlugin],
      observability =>
          #{exporters => [ObservationExporter],
            capture_content => false,
            attributes => #{environment => <<"development">>}}}),
{ok, ObservedReply} = adk_runner:run(
    ObservedRunner, <<"user-1">>, <<"observed-session">>,
    <<"Explain OTP supervision in one sentence.">>),
io:format("~ts~n", [ObservedReply]),
receive
    {adk_plugin, before_run, PluginContext} ->
        true = is_binary(maps:get(<<"run_id">>, PluginContext))
after 1000 ->
    erlang:error(plugin_notification_timeout)
end,
receive
    {adk_observation, ObservationEnvelope} ->
        false = maps:get(<<"content_captured">>, ObservationEnvelope)
after 1000 ->
    erlang:error(observation_timeout)
end,
ok = erlang_adk:stop_agent(ObservedAgent).
```

A plugin implements any subset of `adk_plugin`'s `on_user_message`,
run/agent/model/tool before/after/error, `on_event`, and `on_error` hooks.
`mode => observe` may only return `observe`; `mode => intervene` may return
`{replace, Value}` or `{halt, Reason}`. Descriptors are compiled once in list
order. Duplicate IDs, unavailable modules, invalid limits, and unknown modes
are rejected by `adk_runner:new/4`. Each callback has a monitored timeout and
heap limit; `failure_policy => open` records a structural failure and proceeds,
while `closed` stops the run. Hook contexts are immutable, secret-pruned maps
with binary keys. Event interventions cannot alter identity, state/actions,
continuations, finality, or already-validated final content.

Runner observability is metadata-only by default. Set `observability =>
disabled` to turn it off. Envelopes and `telemetry` events share trace, span,
run, invocation, session, agent, model, tool, and call IDs. Prompt, response,
tool argument, and tool result content is excluded unless
`capture_content => true`; secret-bearing fields are still pruned. Opaque BEAM
terms degrade to a metadata-only `capture_error` diagnostic instead of
breaking the invocation. Exporters implement `adk_observability_exporter` and
receive JSON-safe, schema-versioned maps in bounded workers.

See [plugins, observability, and evaluation](docs/PLUGINS_OBSERVABILITY_EVALUATION.md)
for lifecycle precedence, intervention boundaries, and adapter contracts.

## Evaluation

`adk_eval_set` provides versioned, JSON-safe, multi-turn evaluation with
bounded case concurrency, ordered turns, metric and judge adapters, pass
thresholds, captured events/tool trajectories, and saved result metadata. The
repository includes a direct-agent adapter and exact-match metric for this
executable example:

```erlang
{ok, readme_agent_eval_adapter} =
    c("examples/readme_agent_eval_adapter.erl"),
{ok, readme_exact_metric} = c("examples/readme_exact_metric.erl"),
{ok, EvalSetAgent} = erlang_adk:spawn_agent(
    <<"EvalSetAgent">>,
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>,
      instructions => <<"Follow the requested output format exactly.">>}, []),
{ok, EvalSet} = adk_eval_set:new(
    <<"exact-dialogue">>, <<"1">>,
    [#{id => <<"two-turn-case">>,
       turns =>
           [#{id => <<"first">>,
              input => <<"Reply with exactly: ERLANG">>,
              expected => <<"ERLANG">>},
            #{id => <<"second">>,
              input => <<"Again reply with exactly: ERLANG">>,
              expected => <<"ERLANG">>}]}]),
EvalAdapter = #{module => readme_agent_eval_adapter,
                target => EvalSetAgent, config => #{}},
EvalMetrics = [#{id => <<"exact">>,
                 module => readme_exact_metric,
                 kind => metric, threshold => 1.0, config => #{}}],
{ok, EvalSetResult} = adk_eval_set:run(
    EvalAdapter, EvalSet, EvalMetrics,
    #{concurrency => 1, pass_rate_threshold => 1.0,
      capture_events => true, capture_tool_content => false}),
true = maps:get(<<"passed">>, EvalSetResult),
{ok, SavedEvalResult} = adk_eval_set:encode_result(EvalSetResult),
SavedEvalResult = jsx:decode(jsx:encode(SavedEvalResult), [return_maps]),
ok = erlang_adk:stop_agent(EvalSetAgent).
```

An evaluation adapter implements `adk_eval_adapter:run_turn/5` and may return
canonical ADK events, allowing tool-call and tool-response trajectories to be
captured without exposing their content by default. Metrics and LLM-backed
judges share `adk_eval_metric:score/4`; `kind => judge` records the distinction
without coupling the core evaluator to a provider. Cases run in monitored,
heap-limited workers up to `concurrency`; turns within one case remain ordered
and thread adapter state. Use a target that provides isolated sessions when
cases must not share agent history.

The compatibility API remains available for small, single-turn datasets.

`adk_eval` runs rows against an existing agent and applies a metric function:

```erlang
{ok, EvalPid} = erlang_adk:spawn_agent(
    <<"EvalAgent">>,
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>,
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

## Retry, memory, and artifacts

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

Each attempt runs in a fresh monitored lightweight process. `attempt_timeout`,
one absolute total `timeout`/`deadline`, a callback heap limit, bounded backoff,
and optional `jitter => full` prevent a crashing or blocked attempt from
escaping the retry budget. For caller-detached application work, put the
complete retry operation inside an `adk_task` or supervised run rather than
using retry as a process-lifecycle substitute.

The ETS memory service performs deterministic case-insensitive token-overlap
ranking with exact metadata filtering; it is not a vector database. Runner integration is
explicit so enabling a service cannot silently change a prompt:

```erlang
{ok, MemoryPid} = adk_memory_ets:init(#{}),
{ok, MemoryId} = adk_memory_ets:add(
    MemoryPid, <<"OTP supervision trees restart children">>,
    #{<<"topic">> => <<"otp">>}),
{ok, [MemoryHit]} = adk_memory_ets:search(
    MemoryPid, <<"supervision">>, #{<<"topic">> => <<"otp">>}, 5),
MemoryId = maps:get(id, MemoryHit),

{ok, MemoryAgentPid} = erlang_adk:spawn_agent(
    <<"MemoryAgent">>,
    #{provider => adk_llm_gemini,
      instructions => <<"Use relevant retrieved memory as reference data.">>},
    []),
MemoryRunner = adk_runner:new(
    MemoryAgentPid, <<"readme_app">>, erlang_adk_session,
    #{memory_svc => {adk_memory_ets, MemoryPid},
      memory_retrieval =>
          #{limit => 5, filter => #{<<"topic">> => <<"otp">>},
            on_error => fail},
      memory_ingestion => on_success,
      service_timeout => 5000}),
{ok, _MemoryAwareResponse} = adk_runner:run(
    MemoryRunner, <<"user-1">>, <<"memory-session">>,
    <<"What restarts children?">>),

ok = adk_memory_ets:delete(MemoryPid, MemoryId),
ok = erlang_adk:stop_agent(MemoryAgentPid),
ok = adk_memory_ets:stop(MemoryPid).
```

Retrieved entries are sorted, delimited as untrusted reference data, and added
only to the invocation context; they are not copied into session history.
`memory_ingestion => on_success` indexes the completed session after a final
response. Adapter calls run in monitored workers with `service_timeout`.

Artifacts are immutable binary versions scoped to an application, user, or
session. The ETS adapter is useful for tests and one-node development:

```erlang
{ok, ArtifactPid} = adk_artifact_ets:start_link(#{}),
ArtifactScope =
    {session, <<"readme_app">>, <<"user-1">>, <<"artifact-session">>},
{ok, #{version := 1, digest := Digest}} = adk_artifact_ets:put(
    ArtifactPid, ArtifactScope, <<"reports/result.txt">>, <<"first">>,
    #{mime_type => <<"text/plain">>,
      metadata => #{<<"source">> => <<"readme">>}}),
{ok, #{version := 2}} = adk_artifact_ets:put(
    ArtifactPid, ArtifactScope, <<"reports/result.txt">>, <<"second">>, #{}),
{ok, LatestArtifact} = adk_artifact_ets:get(
    ArtifactPid, ArtifactScope, <<"reports/result.txt">>, latest),
<<"second">> = maps:get(data, LatestArtifact),
io:format("sha256=~ts~n", [Digest]),
ok = adk_artifact_ets:stop(ArtifactPid).
```

Pass `{adk_artifact_ets, ArtifactPid}` as Runner option `artifact_svc`. Tools
then receive the opaque service reference plus their session `artifact_scope`
in `Context`; artifact bytes are not automatically pasted into prompts.

For durable one-node storage, use the filesystem adapter. Logical scope/name
values are SHA-256-addressed rather than used as path components, and every
read verifies stored scope, name, version, byte count, and digest:

```erlang
ArtifactRoot = filename:join(
    os:getenv("TMPDIR", "/tmp"),
    "erlang-adk-readme-artifacts-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic]))),
{ok, FsArtifactPid} = adk_artifact_fs:start_link(
    #{root => ArtifactRoot, max_artifact_bytes => 1048576}),
{ok, #{version := 1}} = adk_artifact_fs:put(
    FsArtifactPid, ArtifactScope, <<"reports/durable.txt">>, <<"ready">>,
    #{mime_type => <<"text/plain">>}),
{ok, #{data := <<"ready">>}} = adk_artifact_fs:get(
    FsArtifactPid, ArtifactScope, <<"reports/durable.txt">>, latest),
ok = adk_artifact_fs:stop(FsArtifactPid),
ok = file:del_dir_r(ArtifactRoot).
```

Exclusive durable reservations ensure deleted or interrupted versions are
never reused, including after restart or concurrent service instances. The
root and generated directories must be real directories rather than symlinks.
The adapter does not encrypt artifacts; use least-privilege permissions and an
encrypted volume where confidentiality requires it. See
[Artifact services](docs/ARTIFACTS.md).

## A2A 1.0 interoperability

The opt-in A2A endpoint implements the released A2A 1.0 JSON-RPC binding. It
publishes `/.well-known/agent-card.json` with `supportedInterfaces`, serves
JSON-RPC at `/a2a/v1`, and requires `A2A-Version: 1.0` on protocol requests.
The supported methods are `SendMessage`, `SendStreamingMessage`, `GetTask`,
`ListTasks`, `CancelTask`, and `SubscribeToTask`. Streams use SSE, always begin
with a current Task snapshot, preserve ordered event IDs, and close on a
terminal task state.

Each protocol task maps to independently supervised, deadline-bounded Erlang
work. The task store has explicit limits for active tasks, retained tasks,
events, subscribers, and retention time. A disconnected request process does
not own or cancel the work. This keeps the A2A lifecycle aligned with OTP's
lightweight-process and supervision model.

Configure the public Agent Card before starting the application. This
loopback example uses the default bridge to a registered Erlang ADK agent:

```erlang
_ = application:stop(erlang_adk),
{ok, A2ACard} = adk_a2a_v1_card:new(
    #{url => <<"http://127.0.0.1:8080/a2a/v1">>,
      name => <<"Erlang poem agent">>,
      description => <<"Writes short poems through A2A 1.0">>,
      skills => [#{<<"id">> => <<"write-poem">>,
                   <<"name">> => <<"Write poem">>,
                   <<"description">> => <<"Writes a short requested poem">>,
                   <<"tags">> => [<<"writing">>, <<"poem">>]}]}),
ok = application:set_env(erlang_adk, a2a_v1_enabled, true),
ok = application:set_env(erlang_adk, a2a_v1_card, A2ACard),
ok = application:set_env(erlang_adk, a2a_v1_agent_name, <<"A2APoet">>),
ok = application:set_env(
    erlang_adk, a2a_v1_server_options,
    #{task_timeout => 60000,
      retention_ms => 300000,
      max_tasks => 1000,
      max_active => 100,
      max_events => 256,
      max_subscribers_per_task => 64}),
ok = application:set_env(erlang_adk, a2a_v1_auth, none),
ok = application:set_env(erlang_adk, a2a_ip, {127, 0, 0, 1}),
ok = application:set_env(erlang_adk, a2a_port, 8080),
{ok, _} = application:ensure_all_started(erlang_adk),
{ok, A2AAgent} = erlang_adk:spawn_agent(
    <<"A2APoet">>,
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>,
      instructions => <<"Write concise poems.">>}, []),

{ok, RemoteCard} = adk_a2a_v1_client:discover(
    <<"http://127.0.0.1:8080">>),
A2AMessage = #{
    <<"messageId">> => <<"poem-request-1">>,
    <<"role">> => <<"ROLE_USER">>,
    <<"parts">> => [#{<<"text">> =>
                           <<"Write a short poem about Erlang.">>,
                       <<"mediaType">> => <<"text/plain">>}]
},
{ok, #{<<"task">> := A2ATask}} = adk_a2a_v1_client:send(
    RemoteCard, A2AMessage, #{timeout => 65000}),
<<"TASK_STATE_COMPLETED">> =
    maps:get(<<"state">>, maps:get(<<"status">>, A2ATask)),
[#{<<"parts">> := [#{<<"text">> := A2APoem}]}] =
    maps:get(<<"artifacts">>, A2ATask),
io:format("~ts~n", [A2APoem]),
ok = erlang_adk:stop_agent(A2AAgent).
```

A2A 1.0 Parts are member-discriminated: use `text`, arbitrary JSON `data`, or
file content through base64 `raw` or an absolute `url`, with optional
`filename`, `mediaType`, and metadata. Do not send the pre-1.0 `kind` field.
Task states use names such as `TASK_STATE_WORKING` and
`TASK_STATE_COMPLETED`, not the lowercase 0.3 values.

For a public or non-loopback deployment, use the OIDC hook and advertise its
OpenID Connect security scheme in the Agent Card. `JwtPolicy` is an
`adk_jwt_policy` value configured with exact HTTPS issuer, audience,
asymmetric algorithm allow-list, time bounds, and required scopes:

```erlang
ok = application:set_env(
    erlang_adk, a2a_v1_auth, adk_a2a_v1_oidc_auth),
ok = application:set_env(erlang_adk, a2a_v1_jwt_policy, JwtPolicy).
```

The authorization hook receives request headers transiently and returns a
safe principal plus a stable principal ID. The store retains only a SHA-256
principal scope; credentials and raw headers are never placed in protocol
tasks or events. Cross-principal lookup, listing, cancellation, and
subscription all return the same not-found result as an unknown task. The
outbound client obtains authorization headers just in time through
`auth_fun/0`, so a token manager can rotate credentials without storing them
in client state.

Current limitations are explicit: this release implements the JSON-RPC 1.0
binding, not gRPC or HTTP+JSON; push-notification configuration, extended
Agent Cards, and Agent Card JWS signing/verification are not implemented.
Tasks and replay buffers are node-local and bounded rather than distributed
durable storage. `Last-Event-ID` reconnect works only inside the retained event
window. Put clear HTTP behind trusted TLS termination and network policy before
using a non-loopback bind. See the official [A2A 1.0
specification](https://a2a-protocol.org/latest/specification/) for the binding
and data-model contract.

## Legacy simple HTTP endpoint

The application can still expose `POST /a2a/prompt` for this project's legacy
small JSON protocol. It is separate from A2A 1.0. The listener is disabled by
default, supervised when enabled, and
binds to loopback unless `a2a_ip` is explicitly changed. Listener settings are
read only when the application starts. Because this repository's `rebar3 shell`
starts `erlang_adk` automatically, stop the application before changing them:

```erlang
_ = application:stop(erlang_adk),
ok = application:set_env(erlang_adk, a2a_enabled, true),
ok = application:set_env(erlang_adk, a2a_ip, {127, 0, 0, 1}),
ok = application:set_env(erlang_adk, a2a_port, 8080),
ok = application:set_env(erlang_adk, a2a_max_body_bytes, 1048576),
{ok, _} = application:ensure_all_started(erlang_adk),
{ok, HttpAgentPid} = erlang_adk:spawn_agent(
    <<"HttpAgent">>, #{provider => adk_llm_gemini}, []),
{ok, HttpResponse} = erlang_adk_a2a_client:prompt(
    "http://localhost:8080/a2a/prompt",
    <<"HttpAgent">>, <<"Hello from HTTP">>),
io:format("~ts~n", [HttpResponse]),
ok = erlang_adk:stop_agent(HttpAgentPid).
```

This legacy endpoint is not wire-compatible with A2A and should not be exposed
as a production public API. New integrations should use the A2A 1.0 endpoint
above.

## Integrated developer tooling

The Erlang-hosted developer console uses the same independently supervised run
runtime as applications. It provides chat, event traces, bounded replay,
reconnect, cancellation, session inspection, and approval/resume without adding
an Elixir or Node.js dependency. It is disabled by default and binds to
loopback by default.

Set a dedicated local bearer token before starting the VM:

```bash
export ERLANG_ADK_DEV_TOKEN="replace-with-at-least-16-random-characters"
```

Then enable the listener before the application starts:

```erlang
_ = application:stop(erlang_adk),
ok = application:set_env(erlang_adk, dev_enabled, true),
ok = application:set_env(erlang_adk, a2a_ip, {127, 0, 0, 1}),
ok = application:set_env(erlang_adk, a2a_port, 8080),
ok = application:set_env(
    erlang_adk, dev_runner_options,
    #{run_timeout => 120000,
      tool_execution =>
          #{mode => parallel, max_concurrency => 4, tool_timeout => 30000}}),
ok = application:set_env(
    erlang_adk, dev_run_options,
    #{retention_ms => 60000, max_buffered_events => 256}),
ok = application:set_env(erlang_adk, dev_max_session_results, 100),
ok = application:set_env(erlang_adk, dev_sse_max_events, 128),
ok = application:set_env(erlang_adk, dev_sse_max_bytes, 1048576),
ok = application:set_env(erlang_adk, dev_sse_max_duration_ms, 300000),
{ok, _} = application:ensure_all_started(erlang_adk).
```

Open `http://127.0.0.1:8080/dev` and enter the token in the connection panel.
The token remains in page memory, is sent only in the `Authorization` header,
and is never accepted in a query string. Cowboy route state keeps only its
SHA-256 digest. Browser requests with an `Origin` header must be same-origin.

The authenticated local API is:

| Method | Path | Behavior |
| --- | --- | --- |
| `GET` | `/dev/v1/agents` | Discover live registered agents by stable name |
| `POST` | `/dev/v1/runs` | Start a stable run for a registered agent |
| `GET` | `/dev/v1/runs/:run_id` | Inspect status and parent/resume links |
| `DELETE` | `/dev/v1/runs/:run_id` | Request cancellation |
| `GET` | `/dev/v1/runs/:run_id/events` | SSE replay/reconnect using `Last-Event-ID` |
| `POST` | `/dev/v1/runs/:run_id/resume` | Resume a paused run with `{"tool_response": ...}` |
| `GET` | `/dev/v1/sessions/:app/:user` | List bounded, newest-first session metadata |
| `POST` | `/dev/v1/sessions/:app/:user` | Create a session with `{"session_id":"..."}` |
| `GET` | `/dev/v1/sessions/:app/:user/:session` | Inspect one exact session scope |
| `DELETE` | `/dev/v1/sessions/:app/:user/:session` | Delete one exact session scope |
| `POST` | `/dev/v1/sessions/:app/:user/:session/state` | Apply one non-secret `{"state_delta":{...}}` |

The developer SSE handler uses `adk_run` credit delivery and has at most one
unacknowledged run message in its mailbox. Each connection also closes cleanly
at the first configured bound: `dev_sse_max_events` (default 128 encoded run
events), `dev_sse_max_bytes` (default 1 MiB of SSE bodies), or
`dev_sse_max_duration_ms` (default five minutes). The console reconnects with
the last received sequence in `Last-Event-ID`; sequences are not silently
skipped. A cursor older than `dev_run_options.max_buffered_events` receives HTTP
409 `run_event_replay_gap` with the oldest and latest retained sequences. A
buffer overrun discovered after streaming starts is an explicit
`event: replay_gap` followed by a clean close.

All three values must be positive; validation also caps them at 10,000 events,
16 MiB, and one hour respectively, so a configuration typo cannot remove the
per-connection bound.

SSE disconnect or a configured connection boundary only unsubscribes the HTTP
process; it never cancels the run. Request bodies, fields, connections,
keepalive, replay, delivery mailboxes, encoded stream bytes, and timeouts are
bounded. Treat this as a local development surface. Do not bind it publicly or
reuse its bearer token as a model key, user identity, or tool credential.

Build the integrated CLI with `./rebar3 escriptize`; the executable is
`_build/default/bin/adk`. Agent configuration is checked JSON. Secrets are
rejected in the file—keep `GEMINI_API_KEY` in the environment. The checked-in
[`examples/agent.json`](examples/agent.json) contains:

```json
{
  "name": "CliAgent",
  "provider": "gemini",
  "model": "gemini-3.1-flash-lite",
  "instructions": "Answer concisely and follow exact-output requests.",
  "global_instruction": "Never expose credentials.",
  "generation_config": {
    "thinking_config": {"thinking_level": "low"},
    "safety_settings": [{
      "category": "HARM_CATEGORY_DANGEROUS_CONTENT",
      "threshold": "BLOCK_MEDIUM_AND_ABOVE"
    }]
  },
  "runner_options": {
    "max_llm_calls": 8,
    "max_tool_rounds": 4
  }
}
```

```bash
./rebar3 escriptize
_build/default/bin/adk doctor
_build/default/bin/adk config validate examples/agent.json
_build/default/bin/adk run --config examples/agent.json \
  --message "Explain rest_for_one" --user local --session cli-demo
_build/default/bin/adk console --config examples/agent.json \
  --user local --session cli-console
_build/default/bin/adk evaluate --config examples/agent.json \
  --dataset examples/eval.json
```

`console` is interactive until `/exit` or terminal EOF. `serve` also blocks so
the supervised developer listener and its retained runs stay alive. Start it
in one terminal:

```bash
export ERLANG_ADK_DEV_TOKEN="replace-with-the-same-local-token"
_build/default/bin/adk serve --config examples/agent.json \
  --ip 127.0.0.1 --port 8080
```

The command must print `"status":"listening"` and then remain running. Open
`http://127.0.0.1:8080/dev` in a browser. While `serve` remains running, use a
second terminal for developer API commands; environment exports are
terminal-local, so export the same bearer token there as well:

```bash
export ERLANG_ADK_DEV_TOKEN="replace-with-the-same-local-token"
_build/default/bin/adk inspect agents --url http://127.0.0.1:8080
_build/default/bin/adk inspect run RUN_ID
_build/default/bin/adk inspect sessions adk-cli local
_build/default/bin/adk inspect session adk-cli local cli-demo
_build/default/bin/adk session create adk-cli local scratch
_build/default/bin/adk session state adk-cli local scratch \
  --delta-json '{"developer:mode":"trace"}'
_build/default/bin/adk session delete adk-cli local scratch
_build/default/bin/adk resume RUN_ID \
  --response-json '{"approved":true}'
```

Plain HTTP inspection is restricted to loopback; remote URLs must use HTTPS.
The CLI emits JSON for automation and redacts operational failures. `serve`
requires `ERLANG_ADK_DEV_TOKEN` and deliberately refuses a non-loopback bind.
The interactive console keeps one supervised agent and Runner alive across
turns. `/inspect`, `/new`, `/session ID`, `/resume JSON`, `/help`, and `/exit`
are local console commands; a terminal EOF also closes it cleanly.

In the second-terminal commands, `RUN_ID` means a retained run created by that
still-running developer server (for example through `/dev`); for `resume` it
must be the ID of the paused parent run. The ID printed by the one-shot `adk
run` command is informational after that command exits—the ephemeral CLI VM is
gone, so a later process cannot inspect or resume that in-memory run.

`developer_api_unavailable` with `connection_refused` means no process is
listening at the selected URL; it is not an authentication or Gemini error.
Check that the first terminal is still running and that the port is free. If
8080 is occupied, choose another loopback port for `serve`, pass the matching
`--url` to every inspection command, and open that same port in the browser.

## Authentication foundation

`adk_auth_sup` is part of the application supervision tree. Its private ETS
credential store returns opaque references scoped by principal and provider;
the token manager performs monitored, timeout-bounded, single-flight refreshes
keyed by principal, provider, scopes, and audience. Expiry skew prevents a
nearly expired token from being reused. Raw credentials and cached access
tokens are kept out of ordinary process state, sessions, events, prompts, and
status output, and known secret fields are recursively redacted.

The selected enterprise identity implementation is OpenID Connect/OAuth 2.0
through `oidcc`. Provider discovery and JWKS refresh are supervised and opt-in.
Configure providers before application startup, using a pre-existing atom for
each worker name:

```erlang
_ = application:stop(erlang_adk),
ok = application:set_env(
    erlang_adk, oidc_providers,
    [#{name => company_oidc,
       issuer => <<"https://identity.example.com">>}]),
{ok, _} = application:ensure_all_started(erlang_adk),
{ok, JwtPolicy} = adk_jwt_policy:new(
    #{issuer => <<"https://identity.example.com">>,
      audience => <<"erlang-adk-api">>,
      trusted_audiences => [],
      signing_algs => [<<"RS256">>],
      clock_skew_seconds => 30,
      required_scopes => [<<"agent.run">>],
      provider => company_oidc}),
{ok, Identity} = adk_jwt_policy:authenticate(
    JwtPolicy, RequestHeaders),
Principal = maps:get(principal, Identity).
```

`RequestHeaders` must come from the HTTP boundary; tokens in query parameters
or request bodies are not accepted. In addition to Oidcc signature/JWKS checks,
the policy independently enforces HTTPS issuer equality, audience containment,
an asymmetric algorithm allow-list, expiration/not-before/issued-at, subject,
scope, bounded clock skew, and a safe claim allow-list. The returned principal
is issuer-bound, so identical subjects from different issuers cannot collide.

Outbound service credentials remain scoped to that opaque principal. Load the
secret outside the repository, store it once, and give tools only the opaque
reference:

```erlang
ClientIdString = os:getenv("ORDERS_OAUTH_CLIENT_ID"),
ClientSecretString = os:getenv("ORDERS_OAUTH_CLIENT_SECRET"),
true = is_list(ClientIdString),
true = is_list(ClientSecretString),
ClientId = unicode:characters_to_binary(ClientIdString),
ClientSecret = unicode:characters_to_binary(ClientSecretString),
{ok, CredentialRef} = adk_credential_store_ets:put(
    adk_credential_store_ets, Principal, <<"orders-api">>,
    #{kind => oauth_client_credentials,
      client_id => ClientId,
      client_secret => ClientSecret}),
{ok, OAuthToken} = adk_token_manager:get_token(
    adk_token_manager,
    #{principal => Principal,
      provider => <<"orders-api">>,
      provider_module => adk_auth_provider_oidcc,
      credential_ref => CredentialRef,
      scopes => [<<"orders.read">>],
      audience => <<"orders-api">>,
      context => #{provider_worker => company_oidc}},
    15000),
<<"Bearer">> = maps:get(token_type, OAuthToken).
```

Concurrent requests for the same principal/provider/scopes/audience join one
monitored refresh. Refresh-token grants require an expected subject; when a
provider rotates the refresh token, the new value is atomically persisted
before the access token is released. A stale compare-and-swap or storage
failure fails closed. The built-in ETS store is private and node-local;
production secret-manager adapters implement `adk_credential_store`, including
atomic `compare_and_swap/6`, and should be durable and encrypted.

Interactive user OAuth/OIDC uses the same durable Runner suspension mechanism
as other long-running tools. The application creates an S256 PKCE flow before
showing the provider authorization URI:

```erlang
CorrelationId = <<"calendar-consent-42">>,
{ok, Pkce} = adk_suspension:prepare_pkce(
    adk_credential_store_ets, adk_credential_store_ets,
    Principal, <<"calendar">>, CorrelationId),
FlowRef = maps:get(<<"credential_flow_ref">>, Pkce),
#{<<"pkce_challenge">> := Challenge,
  <<"pkce_method">> := <<"S256">>} = Pkce.
```

Only `Challenge` and the opaque `FlowRef` cross the browser/event boundary.
The verifier stays in private credential storage. After the HTTPS callback has
validated provider state and exchanged the authorization code, atomically
replace the pending verifier with the issued credential:

```erlang
{ok, FlowRef} = adk_suspension:complete_pkce(
    adk_credential_store_ets, adk_credential_store_ets,
    Principal, <<"calendar">>, FlowRef, CorrelationId,
    #{kind => oauth_refresh_token,
      client_id => CalendarClientId,
      refresh_token => ProviderRefreshToken}).
```

`complete_pkce/7` is compare-and-swap protected: the same callback cannot
complete twice, the correlation and principal/provider scope must match, and
the pending verifier must be no more than ten minutes old, and the verifier is
removed before resume. Runner accepts only the exact completed `FlowRef` from
that pause; another credential for the same principal, provider, and
correlation cannot satisfy it. The tool calls
`adk_suspension:request_credential/2` with the public authorization request;
Runner resume accepts only the same `CorrelationId` and `FlowRef`, never a raw
authorization code or token. Phoenix or another HTTPS boundary remains
responsible for provider `state`, callback CSRF validation, and the code
exchange.

The `/dev` bearer token is deliberately only local developer authentication.
It must not be reused as end-user identity, a model API key, or a tool
credential.

## Phoenix LiveView integration

Phoenix is compatible with this Erlang application and remains an optional
companion, not a core dependency. Put the Phoenix app beside this repository
and let Mix build the Rebar dependency:

```elixir
# phoenix_app/mix.exs
defp deps do
  [
    {:phoenix, "~> 1.8.9"},
    {:phoenix_live_view, "~> 1.2.6"},
    {:oidcc_plug, "~> 0.4.0"},
    {:erlang_adk, path: "../erlang_adk", manager: :rebar3}
  ]
end
```

`oidcc_plug` is needed only when Phoenix owns the browser OIDC boundary. Pin a
patched Phoenix line and keep the companion application's lock file current;
Phoenix 1.8.9 includes the
[per-transport channel bound](https://osv.dev/vulnerability/EEF-CVE-2026-56811)
required to prevent a single socket from spawning an unbounded number of
channel processes.

The important lifecycle rule is that a LiveView subscribes to a stable run; it
does not own the run process. This minimal LiveView starts a run from an
authenticated server-side user ID and consumes correlated messages:

```elixir
defmodule MyAppWeb.AgentLive do
  use MyAppWeb, :live_view

  @app_name <<"phoenix_app">>
  @max_rendered_events 200

  def mount(_params, %{"user_id" => user_id}, socket) do
    session_id = "session-#{System.unique_integer([:positive, :monotonic])}"

    {:ok,
     assign(socket,
       user_id: user_id,
       session_id: session_id,
       run_id: nil,
       last_sequence: 0,
       events: [],
       outcome: nil
     )}
  end

  def handle_event("send", %{"message" => message}, socket) do
    {:ok, agent_pid} = :adk_agent_registry.lookup(<<"PhoenixAgent">>)
    runner =
      :adk_runner.new(
        agent_pid,
        @app_name,
        :erlang_adk_session,
        %{
          admission_control: %{overflow: :queue, queue_timeout: 5_000},
          runtime_policy: %{
            id: <<"phoenix-agent-policy">>,
            agents: %{allow: [<<"PhoenixAgent">>]},
            tools: %{allow: :all, deny: [<<"shell">>]},
            max_argument_bytes: 32_768,
            max_content_bytes: 262_144
          }
        }
      )

    {:ok, run_id} =
      :adk_run.start(
        runner,
        socket.assigns.user_id,
        socket.assigns.session_id,
        message
      )

    {:ok, _subscription} = :adk_run.subscribe_credit(run_id, self(), 0)

    {:noreply,
     assign(socket,
       run_id: run_id,
       last_sequence: 0,
       events: [],
       outcome: nil
     )}
  end

  def handle_info({:adk_run_event, run_id, sequence, event},
                  %{assigns: %{run_id: run_id}} = socket) do
    item = %{sequence: sequence, event: :adk_event.to_map(event)}
    events = Enum.take(socket.assigns.events ++ [item], -@max_rendered_events)
    socket = assign(socket, events: events, last_sequence: sequence)

    # Return credit only after this event has been converted and retained in
    # the bounded UI history. Exactly one next run message may then arrive.
    case :adk_run.ack(run_id, self(), sequence) do
      :ok ->
        {:noreply, socket}

      {:error, {:replay_gap, gap}} ->
        {:noreply, stop_subscription(socket, {:replay_gap, gap})}

      {:error, reason} ->
        {:noreply, stop_subscription(socket, {:ack_failed, reason})}
    end
  end

  def handle_info({:adk_run_terminal, run_id, sequence, outcome},
                  %{assigns: %{run_id: run_id}} = socket) do
    _ = :adk_run.unsubscribe(run_id, self())
    {:noreply, assign(socket, outcome: outcome, last_sequence: sequence)}
  end

  def handle_info({:adk_run_replay_gap, run_id, gap},
                  %{assigns: %{run_id: run_id}} = socket) do
    {:noreply, stop_subscription(socket, {:replay_gap, gap})}
  end

  # A terminal/event from an earlier run may already be in this LiveView's
  # mailbox when a resumed run becomes current. Correlation prevents it from
  # changing the new run's UI state.
  def handle_info({:adk_run_event, stale_run_id, _sequence, _event}, socket) do
    :adk_run.unsubscribe(stale_run_id, self())
    {:noreply, socket}
  end

  def handle_info({:adk_run_terminal, stale_run_id, _sequence, _outcome}, socket) do
    :adk_run.unsubscribe(stale_run_id, self())
    {:noreply, socket}
  end

  def handle_info({:adk_run_replay_gap, stale_run_id, _gap}, socket) do
    :adk_run.unsubscribe(stale_run_id, self())
    {:noreply, socket}
  end

  def handle_event("approve", %{"decision" => decision},
                   %{assigns: %{run_id: paused_run_id}} = socket) do
    tool_response =
      case decision do
        "approve" ->
          %{"approved" => true, "approver" => socket.assigns.user_id}

        "reject" ->
          %{"approved" => false, "approver" => socket.assigns.user_id}
      end

    {:ok, resumed_run_id} = :adk_run.resume(paused_run_id, tool_response)
    {:ok, _subscription} =
      :adk_run.subscribe_credit(resumed_run_id, self(), 0)

    {:noreply,
     assign(socket,
       run_id: resumed_run_id,
       last_sequence: 0,
       events: [],
       outcome: nil
     )}
  end

  defp stop_subscription(socket, reason) do
    # Unsubscribe is idempotent from the UI's perspective: a terminal run or
    # monitor cleanup may already have removed this subscriber.
    _ = :adk_run.unsubscribe(socket.assigns.run_id, self())
    assign(socket, outcome: {:stream_error, reason})
  end

  def terminate(_reason, %{assigns: %{run_id: run_id}}) when is_binary(run_id) do
    # Unsubscribe is optional because the run monitors subscribers. Never
    # cancel here: a browser disconnect must not terminate useful work.
    :adk_run.unsubscribe(run_id, self())
    :ok
  end

  def terminate(_reason, _socket), do: :ok
end
```

Persist the binary `run_id` and last fully handled sequence in the URL or an
authenticated server session. After a LiveView reconnect, call
`:adk_run.subscribe_credit(run_id, self(), last_sequence)`. Handle an initial
`{:error, {:replay_gap, details}}` the same way as the asynchronous gap above;
the client must reload a session/status snapshot rather than pretend a partial
replay is complete. Render event maps, not Erlang records, at the web boundary,
and keep both rendered assigns and any browser DOM history bounded. Derive
`user_id` and authorization from the authenticated Phoenix session rather than
request parameters.

For local username/password accounts, Phoenix's generated auth flow is the
maintained starting point. For enterprise identity, the selected design is
OpenID Connect: use [`oidcc_plug`](https://hex.pm/packages/oidcc_plug) in the
Phoenix boundary and [`oidcc`](https://hex.pm/packages/oidcc) in pure Erlang
services, with issuer, audience, algorithm, expiry, and scope policy configured
explicitly. Model API keys, incoming user identity, and outbound per-user tool
tokens are separate credential classes and must never be copied into LiveView
assigns, prompts, session state, events, or telemetry.

## Verification

Run the complete deterministic test and developer-tooling packaging gates with
the repository's bundled Rebar3:

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
./rebar3 escriptize
_build/default/bin/adk doctor
_build/default/bin/adk config validate examples/agent.json
```

Run the focused deterministic README smoke suite with:

```bash
./rebar3 eunit --module=readme_examples_test
./rebar3 eunit --module=readme_workflow_examples_test
./rebar3 ct --suite test/adk_concurrency_stress_SUITE.erl
```

The stress suite executes 1,000 stable runs in bounded concurrent batches
across lightweight agent processes. It verifies every response against its
exact session and invocation, unique run IDs, supervisor cleanup, and a stable
test-process mailbox.

Run the opt-in live Gemini suite after exporting `GEMINI_API_KEY` with:

```bash
ERLANG_ADK_LIVE_GEMINI=1 ./rebar3 ct \
  --suite test/readme_live_gemini_SUITE.erl
```

The live suite uses `gemini-3.1-flash-lite` and exercises text generation,
Google Search grounding metadata, thinking configuration, multimodal
one-shot/content streaming, function calling, SSE text streaming, correlated
delegation, concurrent orchestration,
sub-agents, Runner provider streaming, continuation-specific human approval,
Mnesia Runner storage, callbacks, telemetry, evaluation, and the HTTP
endpoint. It is skipped unless explicitly enabled because it uses network
access, quota, and billable API calls.

Some scenarios require multiple model turns, so the complete live suite makes
roughly 31 Gemini requests, including Search grounding plus one-shot and SSE
multimodal requests. By default, its test-only provider wrapper spaces request
starts by 4.2 seconds,
caps each transport wait at 15 seconds, and retries one non-streaming transport
timeout. The suite raises its agent call and direct-turn worker timeouts to 120
seconds; both production defaults remain 60 seconds. HTTP 429 responses are returned promptly
rather than sleeping inside an agent and risking a caller timeout. The pacing
accommodates a 15-requests-per-minute project limit without changing production
request scheduling or the Erlang concurrency model. API limits are
project-specific; accounts with a higher limit can shorten or disable the test
pacing, for example:

```bash
ERLANG_ADK_LIVE_GEMINI=1 \
ERLANG_ADK_LIVE_GEMINI_INTERVAL_MS=0 \
./rebar3 ct --suite test/readme_live_gemini_SUITE.erl
```

Keep the default interval on free-tier projects. Exhausted daily quota, project traffic outside this suite, or persistent account-level limits still fail explicitly instead of looping indefinitely.

The focused suites compile the example modules and directly exercise
deterministic versions of the core agent, delegation, legacy orchestration,
supervised sequential/parallel/loop/transfer/graph workflows, explicit bounded
planning, checkpoint resume, Runner provider streaming with exactly one final
snapshot, session, callback, stream, MCP, evaluation, retry, memory, and
artifact examples. HITL, Mnesia, authenticated developer startup, the
project-specific HTTP endpoint, and Gemini HTTP/SSE wire behavior are covered
by their dedicated EUnit modules in the complete suite above; the focused
suites only check that those dedicated modules are present. A live Gemini
quickstart still requires your own `GEMINI_API_KEY`, network access, quota, and
may produce nondeterministic natural-language text.

The exact executable, compile-only, live, adapter-dependent, and conceptual
classification for every README fence is tracked in
[README example coverage](docs/README_EXAMPLE_COVERAGE.md).
