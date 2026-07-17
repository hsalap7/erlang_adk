# Erlang ADK v0.7.0

Erlang ADK is an experimental, Erlang-native toolkit for building Gemini-backed agents with OTP processes, supervision, tools, sessions, event streams, and concurrent multi-agent workflows.

Version 0.7.0 is the cumulative Erlang ADK release from the v0.3-v0.7 delivery
branches. It adds multimodal and Gemini Live sessions, Runner-global plugins,
evaluation, expanded observability, and an authenticated production Phoenix
companion on top of the agent, workflow, artifact, memory, context,
authentication, MCP, and A2A foundations. The
[v0.7.0 release contract](docs/VERSION_0_7_0.md) records both completed
behavior and explicit limitations. The final deterministic, packaging,
Phoenix, browser, dependency, and provider evidence is recorded in
[Verification](#verification) and [Testing](docs/TESTING.md); billable REST and
Live Gemini suites remain explicit opt-in gates in a shell that owns
`GEMINI_API_KEY`.

See the [documentation index](docs/README.md), [changelog](CHANGELOG.md),
[upgrade guide](docs/UPGRADING.md), and [security policy](SECURITY.md) before a
production rollout.

The detailed [ADK behavior-parity matrix](docs/FEATURE_PARITY.md) maps the
official ADK capability families to their Erlang/OTP-native implementation
contracts and current branch status.

The project follows the behavior of Google ADK where that behavior maps
cleanly to Erlang. It is not a drop-in port and does not claim complete Google
ADK feature parity. One agent is one `gen_server` admission point and one
immutable runtime specification. Legacy `prompt`/`delegate` turns share a
stateful FIFO; Runner and explicit invocation turns use bounded, fair,
session-scoped lanes whose provider/tool work runs in supervised lightweight
processes. Independent sessions, agents, and workflow branches therefore use
BEAM concurrency without making one conversation nondeterministic.

## Current scope

| Area | v0.7.0 status |
| --- | --- |
| Gemini REST and Live | REST text, versioned multimodal content, function calling, Google Search grounding, thinking levels/summaries, adjustable safety settings, thought signatures, call IDs, SSE text/content streaming, structured-output settings, and provider capability discovery are implemented with `gemini-3.1-flash-lite`. A separately supervised, bidirectional Gemini Live WebSocket runtime is implemented for `gemini-3.1-flash-live-preview`, including text/audio/image input, audio output, transcription, interruption, resumption, bounded backpressure, and explicitly allowlisted tools. Live sessions and media are intentionally not represented as REST SSE runs. |
| Erlang tools and agents exposed as model tools | Compiled schemas, strict arguments, collision checks, isolated AgentTool calls, and Runner boolean confirmation are implemented; direct/workflow confirmation fails closed because those surfaces have no approval continuation |
| Supervised sequential, bounded parallel, loop, transfer, and graph workflows with deadlines, budgets, cancellation, checkpoints, and resume | Output propagation, explicit stop, schemas, action retry/timeout, graph/fork/sequential nested resume, and legacy helpers are implemented; nested pauses in top-level parallel branches, loop bodies, and transfer members are not resumable |
| Provider-neutral explicit planning and Gemini model-native thinking | Versioned JSON-safe plans, trusted planner/executor adapters, bounded replanning, monitored callbacks, owner-bound cancellation, and Gemini thinking levels/summaries are implemented; model-generated source is never executed |
| ETS/Mnesia sessions with scoped state, HMAC snapshot pagination, filters, and non-destructive branch/rewind | The v0.3.0 core is implemented and release-gated; schema-migration and configurable conflict-policy adapters are not claimed |
| Versioned JSON-safe events and human approval pause/resume | Durable single-use Runner/stable-run boolean approve/reject plus long-running/credential pauses are implemented; structured argument modification is not |
| Supervised stable runs with status, await, credit/ack subscribe/replay, cancellation, and retention | Implemented and release-gated on this branch |
| Ambient/background invocation | Supervised local/event and fixed-delay schedule triggers use bounded concurrency, bounded queues, idempotency, deadlines, retry, stable status/await/cancel, and explicit per-event/shared/session-supplied policies; Pub/Sub/Eventarc remain application adapters |
| Bounded supervised tasks and serial/parallel-safe tool execution | Implemented for compiled Erlang/OpenAPI/MCP catalogs in direct agents and Runner; descriptors are immutable snapshots and running agents do not support live catalog swap |
| Admission control and runtime policy | Supervised global/per-agent limits, monitored reject/bounded-FIFO queue policies, fail-closed agent/tool allow-deny rules, byte budgets, and immutable denial audit events are implemented on this branch |
| Agent/model/tool callbacks and Runner-global plugins | Ordered Runner plugins, explicit amend-versus-early-return behavior, phase-specific error notification, bounded stateful plugin actors, built-in global-instruction/context-filter/reflect-retry/metadata plugins, and existing local callbacks are implemented; see lifecycle notes below |
| Observability | Actual model/tool/Live operation spans, strict W3C Trace Context, a pinned metadata-only GenAI semantic mapping, bounded low-cardinality metrics, synchronous or supervised asynchronous delivery, and OTLP/HTTP JSON export are implemented. Prompt, response, media, arguments, and results remain excluded by default. |
| Evaluation | Legacy lightweight evaluation remains. Eval-set/result schema v2 adds full-case response and trajectory criteria, an explicit bounded Gemini rubric judge, repeat sampling, isolated per-case agent lifecycle, strict accounting, baseline comparison, stable JSON/Markdown reports, and `adk eval run` CI exit semantics. |
| OpenAPI | Strict OpenAPI 3.0/3.1 compiler, production Gun transport, per-principal auth broker, and first-class agent/Runner toolsets are implemented; the supported subset is documented below |
| MCP | Supervised stdio and MCP 2025-11-25 Streamable HTTP clients plus a bounded tool/resource/prompt server are implemented and release-gated; optional server GET/SSE and advanced capabilities remain explicit limitations |
| A2A interoperability | A2A 1.0 Agent Card plus bounded JSON-RPC/SSE tasks, artifacts, replay, principal scoping, and outbound client are implemented; the older `/a2a/prompt` endpoint remains explicitly legacy and is startup-enforced loopback-only |
| Versioned artifacts | Partial 0.5 implementation: strict app/user/session scopes, immutable ETS/filesystem versions, quotas, paginated metadata, deadline-aware mutations, least-authority tool helpers, metadata-only event effects, one-request model-selected attachment, filesystem repair, exact-scope developer inspection/delete, and an opt-in bounded exact-scope sharded adapter are implemented; direct adapters serialize per service while sharded workers preserve same-scope ordering and let unrelated scopes overlap; durable lifetime scope/name/version admission fails explicitly before bounded scans can be exhausted; credit-based blob streaming and complete durable orphan recovery remain open |
| Scoped long-term memory | Partial 0.5 implementation: the v2 app/user-scoped contract, bounded lexical ETS and durable local Mnesia adapters, provenance/idempotency, preload and model-selected retrieval, entry/session/user erasure, deadline-aware calls, fail-closed Mnesia-outbox admission, developer search/erase, and an opt-in bounded exact-user sharded adapter are implemented; durable delivery uses bounded resolution and a freshly revalidated ownership lease immediately before an idempotent at-least-once mutation; direct lexical adapters serialize per service while sharded workers overlap unrelated users; managed vector search, pending-job erasure coordination, and policy-driven retention remain adapters or application policy |
| Context selection, compaction, and caching | Partial 0.5 implementation: mandatory model-boundary sanitization, complete-envelope budgets, O(n) exchange-aware selection, owner-bound compression, context fingerprints, opt-in Runner compaction with atomic ETS/Mnesia checkpoint persistence, a provider-prefix-cache lifecycle, and deterministic Gemini create/reuse/bypass/generate/stream wiring are implemented; cache installation synchronously rechecks every absolute waiter deadline and deletes an orphan provider resource when no live waiter remains; caching is request-prefix reuse rather than response caching, and billable Gemini REST cache evidence remains a separate gate |
| Auth and integrated developer tooling | Immutable provider profiles, bounded single-flight OAuth tokens, supervised authorization-code + S256 PKCE, strict OIDC/JWT policy, default-deny operation scopes, issuer-bound run ownership, and loopback-only `/dev` tooling are implemented. v0.7 adds authenticated Live status/text/SSE, evaluation render/compare, and observability snapshots; the CLI adds Live/observability controls and `eval run`. `/dev` remains local single-operator administration, not an end-user API. |
| Phoenix LiveView companion | The checked Phoenix 1.8/LiveView application uses OIDC code+PKCE and opaque server-side state. Its server-owned, exact-scope gateways cover stable runs and v0.7 Live/evaluation/observability views with bounded projections; it is an optional same-BEAM production companion, not a core Erlang dependency. A separate authenticated binary voice socket uses the core owner-bound bridge for bounded 16 kHz microphone input, native audio playback, per-event credit, and interruption; LiveView assigns remain media-free and Live reconnect never claims replay. |

## Source layout

The Erlang module namespace remains flat, but implementation files are grouped
by ownership under one recursive `src` root. The root contains only the public
facade and OTP application shell. Agents, tools, workflows, Live, runtime,
context, artifacts, memory, sessions, protocols, integrations, authentication,
models, plugins, telemetry, and evaluation each have explicit ownership
directories; provider implementations such as Gemini remain below `models/`.
This is a filesystem-only organization: public module atoms and BEAM names do
not change. See [`src/README.md`](src/README.md) for the exact boundaries and
rules for new modules. Test and fixture modules mirror the same ownership
hierarchy under a test-profile-only recursive `test` root; see
[`docs/TEST_LAYOUT.md`](docs/TEST_LAYOUT.md) for placement and discovery rules.

## Installation

The supported release toolchain is Erlang/OTP 27; v0.7.0 was verified with
OTP 27.3.4.14 and the bundled Rebar3 3.27.0. Older OTP 27 patch levels are not
the supported production baseline because 27.3.4.14 contains required TLS
security fixes. The core library does not require
Elixir or Node.js. The optional Phoenix companion has its own
pinned toolchain in `examples/phoenix_adk_ui/.tool-versions`.

After the release owner creates `v0.7.0`, use that immutable tag. Before the
tag exists, pin the reviewed release-candidate commit SHA instead of a mutable
branch. After the package is published to Hex, the equivalent package
requirement is `{erlang_adk, "0.7.0"}`.

```erlang
{deps, [
    {erlang_adk,
     {git, "https://github.com/hsalap7/erlang_adk.git",
      {tag, "v0.7.0"}}}
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
deprecated in favor of `GlobalInstructionPlugin`. Erlang ADK retains the
explicit root field for tree-scoped compatibility and provides
`adk_plugin_global_instruction` for ordered Runner-wide policy. The plugin
amends the checked model request through the normal v0.7 plugin pipeline; it
does not mutate agent configuration or replace the root/delegation contract.

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

Before the provider sees a catalog, Erlang ADK loads every module/toolset
schema, normalizes and compiles its supported JSON Schema, and rejects invalid
schemas or duplicate names across Erlang tools, dynamic toolsets, and
sub-agents. The whole provider call batch is structurally validated before it
is persisted. Each call's arguments are then checked against the compiled
schema before runtime policy, confirmation, callbacks, credentials, or side
effects. Invalid values are never reflected in the model-visible structural
error.

Gemini has two mutually exclusive function-parameter fields. Erlang ADK keeps
the normalized provider-neutral contract for local validation, then emits the
legacy `parameters` field only for a deliberately small positive subset that
Gemini accepts there. Any schema outside that subset—including `oneOf`,
`additionalProperties`, a type union, a boolean subschema, a top-level
`parameters => true | false` schema, or an unknown keyword—is sent unchanged
as `parametersJsonSchema`. The provider boundary does not weaken the tool's
runtime validation contract.

An `adk_toolset` descriptor is an immutable catalog snapshot. `schemas/1` and
resolution reuse its compiled contracts; `refresh/1` deliberately returns a
replacement descriptor for a mutable MCP/OpenAPI backend. A running agent has
no live catalog-swap API, so new remote tools require a refreshed
descriptor and replacement agent. A removed or changed operation fails closed
as `tool_catalog_changed` instead of executing against a stale declaration.
Trusted local Erlang tool contexts carry private bounded agent ancestry so an
AgentTool wrapper cannot reset cycle protection; that metadata is not sent to
remote toolsets or model providers.

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

The coordinator resolves a restarted sub-agent by its registered binary name,
so a stale child PID does not have to crash the parent agent. Agent names use
the portable `[A-Za-z_][A-Za-z0-9_]*` grammar; `user` is reserved. Spawn-time
tree validation rejects alias/name mismatches, duplicate ownership,
self-reference, cycles, more than 256 agents, depth above 64, and an
unresponsive tree after one two-second deadline. Invocation-time ancestry
tracking independently rejects a repeated agent or depth above 64 before its
provider runs, including dynamically resolved replacements.

`prompt/2` and asynchronous `delegate` retain the compatibility conversation
and execute in one FIFO. `erlang_adk:invoke/3`, AgentTool, and Runner use fresh
invocation history. The same `{app_name,user_id,session_id}` lane remains FIFO;
different lanes may overlap up to `max_concurrent_invocations` (32 by default)
with fair admission. A child owns its provider, model, local instructions, and
tool catalog. Only the root global instruction and explicitly scoped safe
context cross a delegation boundary—never compatibility memory or provider
credentials. The safe scope includes the caller's state snapshot and opaque
session-service module (`state_ref`) so an `output_key` commits to the exact
invocation session rather than the reusable agent's configured default;
AgentTool may additionally carry the explicitly configured memory-service
reference.

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
AddOne = fun(State, Context) ->
    null = maps:get(input, Context),
    {output, <<"counted">>,
     #{<<"count">> => maps:get(<<"count">>, State, 0) + 1}}
end,
MarkDone = fun(_State, Context) ->
    <<"counted">> = maps:get(input, Context),
    {output, <<"ready">>, #{<<"done">> => true}}
end,
SequentialSpec = #{
    version => 1,
    id => <<"readme-sequential-v1">>,
    kind => sequential,
    max_steps => 4,
    input_schema =>
        #{<<"type">> => <<"object">>,
          <<"required">> => [<<"count">>]},
    output_schema => #{<<"type">> => <<"string">>},
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
<<"ready">> = maps:get(<<"output">>, SequentialCheckpoint),

ParallelSpec = #{
    version => 1,
    id => <<"readme-parallel-v1">>,
    kind => parallel,
    max_concurrency => 2,
    merge => reject_conflicts,
    branches => [
        #{id => <<"left">>,
          run => fun(_State) ->
              {output, <<"left-output">>, #{<<"left">> => 1}}
          end},
        #{id => <<"right">>,
          run => fun(_State) ->
              {output, <<"right-output">>, #{<<"right">> => 2}}
          end}
    ]
},
{ok, Parallel} = erlang_adk:compile_workflow(ParallelSpec),
{completed, ParallelState, ParallelCheckpoint} =
    erlang_adk:run_workflow(Parallel, #{}),
1 = maps:get(<<"left">>, ParallelState),
2 = maps:get(<<"right">>, ParallelState),
#{<<"left">> := <<"left-output">>,
  <<"right">> := <<"right-output">>} =
    maps:get(<<"output">>, ParallelCheckpoint),

RetryTable = ets:new(readme_workflow_retry, [set, public]),
ets:insert(RetryTable, {attempts, 0}),
RetryAction = fun(_State, Context) ->
    Attempt = ets:update_counter(RetryTable, attempts, 1),
    Attempt = maps:get(attempt, Context),
    case Attempt of
        1 -> {error, transient_failure};
        2 -> {output, <<"recovered">>, #{<<"retried">> => true}}
    end
end,
RetrySpec = #{
    version => 1,
    id => <<"readme-workflow-retry-v1">>,
    kind => sequential,
    max_steps => 1,
    steps => [
        #{id => <<"retryable">>, run => RetryAction,
          timeout => 1000,
          retry => #{max_attempts => 2, backoff_ms => 10}}
    ]
},
{ok, Retrying} = erlang_adk:compile_workflow(RetrySpec),
{completed, #{<<"retried">> := true}, RetryCheckpoint} =
    erlang_adk:run_workflow(Retrying, #{}),
<<"recovered">> = maps:get(<<"output">>, RetryCheckpoint),
true = ets:delete(RetryTable).
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
        Attempt = maps:get(<<"attempt">>, State, 0) + 1,
        {output, Attempt, #{<<"attempt">> => Attempt}}
    end,
    until => fun(State) -> maps:get(<<"attempt">>, State) >= 2 end
},
{ok, Loop} = erlang_adk:compile_workflow(LoopSpec),
{completed, #{<<"attempt">> := 2}, LoopCheckpoint} =
    erlang_adk:run_workflow(Loop, #{}),
2 = maps:get(<<"output">>, LoopCheckpoint),

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
            {stop, <<"resolved">>,
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
        Count = maps:get(<<"count">>, State, 0) + 1,
        {output, Count, #{<<"count">> => Count}}
    end}],
    edges => #{<<"counter">> => {route, fun(_State, Context) ->
        Count = maps:get(input, Context),
        case Count < 3 of
            true -> <<"counter">>;
            false -> end_node
        end
    end}}
},
{ok, Graph} = erlang_adk:compile_workflow(GraphSpec),
{completed, #{<<"count">> := 3}, GraphCheckpoint} =
    erlang_adk:run_workflow(Graph, #{}),
3 = maps:get(<<"output">>, GraphCheckpoint).
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
            {output, <<"left-output">>, #{<<"left">> => 1}}
        end},
        #{id => <<"right">>, run => fun(_) ->
            {output, <<"right-output">>, #{<<"right">> => 2}}
        end},
        #{id => <<"join">>, type => join,
          run => fun(_State, Context) ->
              Outputs = maps:get(input, Context),
              <<"left-output">> = maps:get(<<"left">>, Outputs),
              <<"right-output">> = maps:get(<<"right">>, Outputs),
              {output, Outputs, #{<<"joined">> => true}}
          end}
    ],
    edges => #{<<"left">> => <<"join">>,
               <<"right">> => <<"join">>,
               <<"join">> => end_node}
},
{ok, ForkJoin} = erlang_adk:compile_workflow(ForkJoinSpec),
{completed, #{<<"left">> := 1, <<"right">> := 2,
              <<"joined">> := true}, ForkCheckpoint} =
    erlang_adk:run_workflow(ForkJoin, #{}),
#{<<"left">> := <<"left-output">>,
  <<"right">> := <<"right-output">>} =
    maps:get(<<"output">>, ForkCheckpoint),

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
has at-least-once replay semantics. In particular, if one graph-fork branch
pauses, an in-flight sibling is cancelled and, because it has no committed
result, runs again after resume. Concurrent side-effecting branches must use
the invocation/step context as an external idempotency key; a fork checkpoint
does not make arbitrary external effects transactional.

A transfer is an ownership handoff, unlike a sub-agent tool call which returns
to its caller. Every accepted handoff emits an `adk_event` action named
`<<"transfer_to_agent">>` and consumes the transfer budget. Agent-backed
actions can use `{agent, RegisteredName, Prompt}` or
`{agent, RegisteredName, Prompt, DecisionFun}`; the binary name is resolved at
dispatch time so a supervised replacement is used after an agent restart.
Before invocation, the resolved process must report the same canonical runtime
name through `adk_agent:get_runtime/1`; a registry alias mismatch fails closed
as `agent_identity_mismatch`.

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

The action-result contract is `{ok, Delta}`, normal continuation
`{output, Output, Delta}`, explicit terminal `{stop, Output, Delta}`,
`{route, TargetNode, Delta}`, `{transfer, TargetMember, NextInput, Delta}`, or
`{error, Reason}`. Legacy `{complete, Output, Delta}` remains terminal for
compatibility. Graph actions additionally accept
`{pause, Reason, Summary, Delta}`. A normal output is checkpointed and becomes
the next sequential step, graph successor, or join node's `Context.input`;
parallel/fork outputs are maps keyed by declared branch ID. Workflow-level
`input_schema` and `output_schema` are compiled once. Individual action maps
accept `timeout` and `retry => #{max_attempts, backoff_ms}`; each attempt runs
in a monitored lightweight process under the workflow's absolute deadline.
Retry counts cover one live execution of an uncommitted node and reset if that
node is later reconstructed from a checkpoint, so external effects still need
the documented idempotency key. Runtime options include `timeout` or an
absolute monotonic `deadline`, `max_steps`, `max_transfers`,
`max_concurrency`, and terminal `retention_ms`.

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
                          max_request_bytes => 65536,
                          max_request_tokens => 16384,
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

Runner always canonicalizes and secret-prunes model history. `context_policy`
adds filtering and selected-event budgets before each model call.
`overflow => truncate` keeps the newest complete context exchanges; it never
separates a tool call from its responses. `error` fails explicitly, while
`compress` requires an owner-bound monitored compressor with timeout, heap,
event-count, and output-size bounds. Author, invocation, content type,
time-range, partial, and final-event filters are supported. The current
invocation's user event may not be filtered out.

`max_request_bytes` and `max_request_tokens` are a second fail-closed boundary
over the complete sanitized provider envelope: effective instructions and
generation settings, selected history, retrieved memory, current input,
multimodal parts, tool declarations, and framing. A violation returns
`{request_context_budget_exceeded, Details}` before provider I/O. Context-build
telemetry is emitted as `[erlang_adk, context, build]`; complete-envelope
telemetry uses `[erlang_adk, context, envelope]`. Both expose bounded counts,
estimates, and deterministic context fingerprints without prompt content or
credentials. Exact provider tokenization remains a provider adapter concern.
See [the context guide](docs/CONTEXT.md) for compaction, provider-prefix cache,
and least-authority tool context contracts.

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

A side-effecting `adk_tool` can export `require_confirmation/0` for a static
gate or `require_confirmation/2` for an argument-dependent gate. The latter
takes precedence and returns `false`, `true`, or a bounded map such as
`#{required => true, hint => <<"Publish production">>}`. Runner evaluates it
after schema validation and runtime policy, but before tool/plugin lifecycle
callbacks or execution. A dynamic toolset is materialized after policy so its
validated resolved call can declare confirmation; that resolver may obtain a
scoped credential but must not perform the business side effect. A
confirmation is a serial barrier even when neighboring calls are
parallel-safe.

The repository's release example requires confirmation for a real publication
but lets `dry_run => true` proceed. Use the supervised run API so the approval
survives the original caller:

```erlang
{ok, readme_release_tool} = c("examples/readme_release_tool.erl"),
ReleaseConfig = #{
    provider => adk_llm_gemini,
    model => <<"gemini-3.1-flash-lite">>,
    instructions =>
        <<"Call publish_release once for production with dry_run=false. "
          "After its result, answer without calling it again.">>
},
{ok, ReleasePid} = erlang_adk:spawn_agent(
    <<"ReleaseAgent">>, ReleaseConfig, [readme_release_tool]),
ReleaseRunner = adk_runner:new(
    ReleasePid, <<"readme_app">>, erlang_adk_session),
{ok, ReleaseRun} = adk_run:start(
    ReleaseRunner, <<"user-1">>, <<"release-session">>,
    <<"Publish the prepared production release.">>),
case adk_run:await(ReleaseRun, 120000) of
    {paused, ConfirmationPause} ->
        ConfirmationMap = adk_event:to_map(ConfirmationPause),
        #{<<"pause">> :=
              #{<<"details">> :=
                    #{<<"type">> := <<"tool_confirmation">>,
                      <<"action_id">> := _OpaqueActionId}}} =
            maps:get(<<"actions">>, ConfirmationMap),
        {ok, ApprovedReleaseRun} = adk_run:resume(
            ReleaseRun, #{<<"confirmed">> => true}),
        case adk_run:await(ApprovedReleaseRun, 120000) of
            {completed, ReleaseAnswer} ->
                io:format("~ts~n", [ReleaseAnswer]);
            {paused, NextPause} ->
                io:format("tool requested another pause: ~p~n",
                          [adk_event:to_map(NextPause)])
        end;
    {completed, ReleaseAnswer} ->
        io:format("model completed without using the tool: ~ts~n",
                  [ReleaseAnswer])
end,
ok = erlang_adk:stop_agent(ReleasePid),

%% Long-running work is a separate pause type. This compatibility example
%% lets the model request an explicit human response itself.
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

Resume a generic confirmation with exactly
`#{<<"confirmed">> => true | false}`. Approval re-resolves the tool and
rechecks current policy before executing exactly once. Rejection executes no
tool or tool callback; it records a correlated model-visible rejection and
continues the invocation. An invalid response does not consume the
continuation, while a valid continuation is single-use. The opaque action ID
is a digest and contains no raw arguments. Non-Runner agent execution
(`prompt/2`, fresh `invoke/3`, delegation, and AgentTool-backed child calls)
and typed workflow tool actions have no durable approval channel, so a required
confirmation fails closed as `tool_confirmation_requires_runner`; they never
silently execute. Structured “modify arguments” confirmation responses are
not supported.

`adk_long_running_tool` uses the distinct long-running suspension contract. A
pause is not an error; resume records a matching function response with the
original invocation ID, thought signature, and Gemini function-call ID.

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
resumption, and backpressure) is a separate protocol; use the Live runtime
below rather than treating REST SSE as a bidirectional session.

## Gemini Live

Gemini Live sessions run as independent, server-owned `gen_statem` processes
under `adk_live_session_sup`. The process that starts a session does not own
its lifetime. Every operation must present the exact opaque `Principal` used
at startup; only its SHA-256 digest enters long-lived session state.

Live deliberately uses the explicit preview model
`gemini-3.1-flash-live-preview`. The REST default remains
`gemini-3.1-flash-lite`; a REST model is rejected by the Live provider instead
of silently falling back. The Gemini 3.1 Live model produces native AUDIO, so
the setup requests `[audio]` and `output_audio_transcription => true` supplies
displayable text alongside the audio stream.

The checked Live config also supports bounded system instructions, voice
selection, input transcription, thinking configuration, media resolution,
context-window compression, session resumption, function declarations, and
the provider `google_search` declaration. Usage, grounding, GoAway, and
resumption updates arrive as structural events. Proactive/affective audio,
structured output, REST context caching, and arbitrary older Live options are
rejected rather than silently ignored.

From `./rebar3 shell`, start a future-only subscription before waiting for the
ready event:

```erlang
ApiKeyString = os:getenv("GEMINI_API_KEY"),
true = is_list(ApiKeyString),
ApiKey = unicode:characters_to_binary(ApiKeyString),
LivePrincipal = <<"readme-live-user">>,
LiveSessionId = <<"readme-live-session">>,
LiveConfig =
    #{provider => adk_live_gemini,
      provider_config =>
          #{model => <<"gemini-3.1-flash-live-preview">>,
            response_modalities => [audio],
            output_audio_transcription => true,
            automatic_activity_detection => true,
            session_resumption => true},
      transport => adk_live_gun_transport,
      transport_opts => #{api_key => ApiKey},
      max_ingress_messages => 64,
      max_ingress_bytes => 4194304,
      max_subscribers => 64,
      max_subscriber_messages => 128,
      max_subscriber_bytes => 8388608},
{ok, LiveSession} = erlang_adk:start_live_session(
    LiveSessionId, LivePrincipal, LiveConfig),
{ok, _LiveSubscription} = erlang_adk:live_subscribe(
    LiveSession, LivePrincipal, #{messages => 16, bytes => 4194304}),
ReceiveLive =
    fun Loop(Matches) ->
        receive
            {adk_live_event, LiveSessionId, Sequence, Event} ->
                ok = erlang_adk:live_ack(
                    LiveSession, LivePrincipal, Sequence),
                case Matches(Event) of
                    true -> {ok, Event};
                    false -> Loop(Matches)
                end;
            {adk_live_subscriber_dropped, LiveSessionId, DropReason} ->
                {error, {subscriber_dropped, DropReason}}
        after 30000 ->
            {error, live_event_timeout}
        end
    end,
{ok, _ReadyEvent} = ReceiveLive(
    fun(Event) -> adk_live_event:kind(Event) =:= ready end),
{ok, _InputSequence} = erlang_adk:live_send_text(
    LiveSession, LivePrincipal, <<"Explain OTP in one sentence.">>),
CollectTranscript =
    fun Loop(Acc) ->
        receive
            {adk_live_event, LiveSessionId, Sequence, Event} ->
                ok = erlang_adk:live_ack(
                    LiveSession, LivePrincipal, Sequence),
                case adk_live_event:kind(Event) of
                    output_transcription ->
                        #{text := Chunk} = maps:get(payload, Event),
                        Loop(<<Acc/binary, Chunk/binary>>);
                    turn_complete ->
                        {ok, Acc};
                    error ->
                        {error, {live_error, maps:get(payload, Event)}};
                    terminal ->
                        {error, {live_terminal, maps:get(payload, Event)}};
                    _ ->
                        Loop(Acc)
                end;
            {adk_live_subscriber_dropped, LiveSessionId, DropReason} ->
                {error, {subscriber_dropped, DropReason}}
        after 120000 ->
            {error, live_turn_timeout}
        end
    end,
{ok, Transcript} = CollectTranscript(<<>>),
true = byte_size(string:trim(Transcript)) > 0,
io:format("~ts~n", [Transcript]),
ok = erlang_adk:live_unsubscribe(LiveSession, LivePrincipal),
ok = erlang_adk:close_live_session(
    LiveSession, LivePrincipal, normal).
```

`max_subscribers` defaults to 64 and has a hard implementation maximum of
4096. Admission beyond the configured per-session limit returns
`{error, subscriber_limit}`. Explicit unsubscribe, slow-subscriber removal,
or subscriber-process death releases the slot; each admitted subscriber still
has its own independent message/byte credit window and acknowledgement state.
The supervisor-wide application environment setting `live_session_limit`
defaults to 1024 and accepts values only from 1 through 16384. Concurrent
session creation is serialized around a constant-time supervisor count, so an
over-cap start returns `{error, live_session_limit}` without first enumerating
an unbounded child set. Change this setting before application startup.

The production transport is intentionally fixed to
`wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`;
only the API-key query value is added at runtime. TLS peer and hostname
verification cannot be disabled. If the host runtime cannot discover an OS CA
store, point it at a trusted bundle with
`transport_opts => #{api_key => ApiKey, cacertfile => <<"/path/to/ca-bundle.pem">>}`.
The transport never falls back to `verify_none`.

Live PCM input is signed 16-bit little-endian mono at 16 kHz. Gemini audio
events are signed 16-bit little-endian mono at 24 kHz. Keep those raw binaries
off ordinary session/event persistence; Live audio events are explicitly
ephemeral. JPEG and PNG video frames use the same bounded input queue. The
v1beta codec emits the current `realtimeInput.audio` and
`realtimeInput.video` fields, not the superseded `mediaChunks` shape:

```erlang
{ok, AudioChunk} = adk_live_media:audio_pcm(Pcm16KhzS16le, 16000, 1),
{ok, _} = erlang_adk:live_send_audio(
    LiveSession, LivePrincipal, AudioChunk),
{ok, VideoFrame} = adk_live_media:video_frame(jpeg, JpegBytes),
{ok, _} = erlang_adk:live_send_video_frame(
    LiveSession, LivePrincipal, VideoFrame).
```

With automatic activity detection disabled, bracket audio with
`live_activity_start/2` and `live_activity_end/2`; use
`live_audio_stream_end/2` only when the input stream itself has ended.
Interruption, generation completion, and turn completion are distinct events.
An interruption purges queued output audio from that generation.

The Gemini decoder also accepts the current optional Live response fields:
`interimInputTranscription`, transcription `languageCode`/`finished`,
`turnCompleteReason`, `waitingForInput`, `voiceActivity`, and
`voiceActivityDetectionSignal`. Provider completion reasons remain bounded
enum-shaped binaries rather than dynamically created atoms, so a future reason
can pass through safely. Language and server VAD metadata are validated but are
not exposed as new provider-specific public events; text, finality, completion,
and the existing activity lifecycle remain the provider-neutral contract.

### Owner-bound browser voice bridge

`start_live_voice_bridge/4` provides a transport-neutral Erlang boundary for a
browser or native audio adapter without moving device handling into the Live
session. Each bridge is one lightweight, owner-bound process. It subscribes to
the existing server-owned session with fixed byte/message credit, validates
strict versioned binary input, preserves synchronous ingress backpressure, and
forwards only PCM audio, transcription, and lifecycle projections. Raw provider
payloads, credentials, and the principal never enter its owner mailbox.
The session must already report `active`. A monitored node-local lease admits
exactly one bidirectional bridge per Live session, while bridges for different
sessions remain independent lightweight processes. Reconnect rotates a
session-owned continuity capability and sends a credit-independent invalidation
to the bridge; even a fast resume with exhausted output credit cannot admit
stale audio or retain the old lease. It returns
`live_voice_reconnect_required`; an adapter starts a fresh bridge only after
the server-owned session is active again. If an input or ACK deadline leaves
its outcome ambiguous, the bridge terminates and returns
`live_voice_outcome_unknown` so a transport cannot retry possible side effects.

```erlang
{ok, VoiceBridge} = erlang_adk:start_live_voice_bridge(
    LiveSession,
    LivePrincipal,
    self(),
    #{credit => #{messages => 8, bytes => 262144},
      max_audio_frame_bytes => 64000}),
%% Submit 20 ms of mono PCM s16le at 16 kHz. Client audio sequences start at 1.
Pcm20ms = binary:copy(<<0, 0>>, 320),
{ok, _InputSequence} = erlang_adk:live_voice_frame(
    VoiceBridge,
    <<1, 1, 1:64/unsigned-big, 16000:32/unsigned-big, 1,
      Pcm20ms/binary>>),
{ok, _EndSequence} = erlang_adk:live_voice_frame(VoiceBridge, <<1, 2>>),
ok = erlang_adk:stop_live_voice_bridge(VoiceBridge).
```

The v1 client frame types are audio `1`, stream-end `2`, event ACK `3`,
activity-start `4`, and activity-end `5`. Server types are audio `129`,
transcription `130`, and lifecycle `131`; all header integers are big-endian,
while PCM samples remain signed 16-bit little-endian. Every forwarded server
frame retains ADK subscriber credit until the client returns its exact sequence
in an ACK frame. The Phoenix reference adapter defers an audio ACK until every
byte in that frame has entered its bounded playback schedule: at most two
seconds are scheduled, while a FIFO mirrors the bridge's eight-event/262,144-byte
credit bound. A full scheduling horizon withholds credit and drains on source
completion; it never purges already scheduled PCM merely to admit newer audio.
Interruption is stable lifecycle code `4`, allowing a playback adapter to cancel
already scheduled audio immediately. Lifecycle code `6`
means an actual completed resume; an ordinary provider handle update is
continuity metadata and is acknowledged internally rather than mislabeled as a
resume. Audio input sequences
must be strictly monotonic from one; malformed, oversized, duplicate, and
out-of-order frames fail without entering the Live ingress queue. The bridge
unsubscribes when stopped or when its owner dies. The stream-end frame above is
for automatic activity detection. With manual activity detection, use client
activity-start/end frames instead and do not send stream-end; the provider
configuration deliberately rejects mixing the two modes.

Function calling is opt-in. Declaring a provider tool does not authorize its
execution. To run it automatically, configure a trusted
`adk_live_tool_executor` module, an exact non-empty allowlist, and either a
sequential or bounded concurrent policy. The repository example delegates
only `get_weather` to the already checked weather tool:

```erlang
{ok, readme_weather_tool} =
    c("examples/readme_weather_tool.erl"),
{ok, readme_live_weather_executor} =
    c("examples/readme_live_weather_executor.erl"),
WeatherDeclaration =
    #{type => function,
      name => <<"get_weather">>,
      description => <<"Return weather for one city">>,
      parameters =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"city">> => #{<<"type">> => <<"string">>}},
            <<"required">> => [<<"city">>],
            <<"additionalProperties">> => false}},
LiveToolConfig =
    LiveConfig#{
      provider_config =>
          (maps:get(provider_config, LiveConfig))#{
            tools => [WeatherDeclaration]},
      tool_execution =>
          #{enabled => true,
            executor => readme_live_weather_executor,
            policy => sequential,
            allowed_tools => [<<"get_weather">>],
            options => #{}}}.
```

Without `tool_execution`, the application receives a `tool_call` event and
must explicitly return the correlated result with
`live_send_tool_response/5`. Tool calls are never discovered from an ordinary
agent catalog and are never executed merely because the model named them.

Resumption uses only the newest provider handle. On disconnect, unsent text,
audio, video, and tool responses are dropped and reported; they are never
replayed because the remote side might already have applied them. Subscriber
delivery is also future-only: credit/ack bounds memory while connected, but a
new subscriber or `Last-Event-ID` does not replay prior Live media/events.
GoAway initiates a bounded proactive resume when the provider supplied a
usable handle. Applications must tolerate a terminal session when no safe
resume is available. Deterministic tests cover the codec, session state
machine, transport validation, and endpoint construction, while the paid
suite covers the real verified-TLS Google connection. A separate local,
CA-controlled WebSocket TLS integration harness is not included yet.

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
    <<"streamable_http">>, McpUrl,
    #{auth_fun => AuthFun, allow_http_loopback => true}),
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
default. Each session is bound to the SHA-256 scope of the authenticated
principal; a POST or DELETE using another principal receives the same 404 as
an unknown session. A non-loopback bind requires authentication, the explicit
`allow_non_loopback => true` acknowledgement, and either direct Cowboy TLS via
`tls_options` or `trusted_tls_proxy => true`. Use the proxy acknowledgement only
when the clear listener is network-reachable exclusively from that trusted TLS
terminator; forwarding headers are not accepted as proof of TLS. Loopback may
remain clear for development, but the client must opt in with
`allow_http_loopback => true` as the example does.
Configure `auth_token` (stored only as SHA-256 in listener state) or
an `auth_fun/1` receiving request method/endpoint/origin/peer plus the transient
Authorization header. A successful production hook returns `{ok, PrincipalId}`.
Use `authorization_fun/3` for exact operation/resource policy; it receives the
credential-free authentication context, the MCP method (for example
`<<"tools/call">>`), and a bounded resource descriptor. Also configure exact
`allowed_origins`, `max_body_bytes`,
`max_response_bytes`, `max_concurrency`, `request_timeout`, `max_sessions`,
`session_ttl_ms`, `callback_timeout`, and `callback_max_heap_words` before
exposing it. Authentication and authorization hooks run in separate monitored,
heap-limited workers and fail closed on timeout, crash, or oversize result.
HTTP bearer/OAuth acquisition remains
an application concern; the client accepts a zero-arity `auth_fun` so a token
manager can supply fresh authorization headers without persisting a token in
the MCP worker state. In production that callback must capture only an opaque
token-manager reference, never the credential itself; MCP client/server status
formatting suppresses callback internals and authentication messages.

The HTTP client accepts HTTPS by default, resolves every address before
connecting, pins one validated address while retaining the original Host/SNI,
rejects redirects and private/reserved destinations, and applies one absolute
deadline across authentication, connect, response headers, and body chunks.
Use `allowed_hosts` to constrain public targets and
`allowed_private_hosts` only for exact private HTTPS service names. Static
credential headers, cookies, and `Proxy-Authorization` are rejected;
`auth_fun/0` may return at most one origin `Authorization` header. These rules
prevent a discovered or redirected endpoint from receiving credentials meant
for another origin. Client authentication and custom `resolver_fun/1`
callbacks run in monitored off-heap workers under the operation's absolute
deadline; set `callback_max_heap_words` to cap each worker and
`max_resolved_addresses` to cap the validated DNS set. Server authentication,
authorization, tool, resource, and prompt callbacks use the corresponding
`callback_max_heap_words` boundary, and only normalized responses within
`max_response_bytes` cross back into the long-lived server process. Completion
timestamps reject results that were queued after the deadline, process aliases
suppress late replies, and owner watchdogs reap work when its client, server,
or Cowboy request process dies.

For OAuth-protected MCP, set `oauth_protected_resource` with the exact
`resource`, one or more HTTPS `authorization_servers`, `scopes_supported`,
`required_scopes`, and the externally authoritative HTTPS
`resource_metadata_url`. The server publishes the unauthenticated RFC 9728
document at `metadata_path` and includes `resource_metadata`, scope, and
`insufficient_scope` details in Bearer challenges. This mode deliberately
requires both `auth_fun/1` and `authorization_fun/3`; metadata without actual
authentication and operation authorization is rejected at startup.

This server returns JSON for POST and intentionally returns HTTP 405 for the
optional unsolicited GET/SSE channel. The client accepts JSON and bounded SSE
responses to POST. SSE resumability, resource subscriptions/templates,
notifications, roots, sampling, elicitation, completion, client-side OAuth
authorization-server discovery/PKCE, and a server-side stdio transport remain
explicit limitations. Server-side RFC 9728 protected-resource discovery and
challenges are implemented. Endpoint
URLs containing user info, query strings, or fragments are rejected so bearer
credentials cannot accidentally become request URLs. Deprecated
HTTP+SSE (`<<"sse">>`) fails with
`{error, {unsupported_transport, sse_deprecated_use_streamable_http}}`.
The client and server also accept the finalized 2025-06-18 revision during
version negotiation, while initiating new connections with 2025-11-25. If a
client proposes an unsupported initialization version, the server negotiates
the latest supported version as MCP requires.
If Streamable HTTP reports a lost/expired session, the client reinitializes
and automatically retries only read-only protocol operations (`tools/list`,
`resources/list`, `resources/read`, `prompts/list`, `prompts/get`, and
`ping`). It never automatically replays `tools/call` or an unknown/mutating
method whose first attempt may already have caused an effect; that call returns
`{error, {mcp_session_lost, request_not_replayed}}`, and a later explicit
application call uses the renewed session. Per-client HTTP request
serialization and a separately bounded pending-request queue remain
limitations; use independent supervised MCP clients for concurrency and
failure isolation.

## Runner plugins and observability

Plugins are ordered, Runner-global lifecycle policy. They follow the same
observable ordering as [Google ADK plugins](https://adk.dev/plugins/) while
using a bounded BEAM worker for every hook: global plugin hooks run before the
corresponding agent callback; an amendment flows into it, while an early
return or halt skips it.
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
run/agent/model/tool before/after hooks, `on_event`, `on_model_error`,
`on_tool_error`, `on_agent_error`, and `on_run_error`. The older `on_error`
hook remains a compatibility fallback for phase-specific notifications.

Descriptors are compiled once in list order. An observation plugin may return
only `observe`, `continue`, or `ok`. An intervention plugin has three distinct
control results:

- `{amend, Value}` validates the amended value and continues with later
  plugins and the local callback;
- `{return, Value}` returns immediately, skips later plugins and the local
  callback, and is the behavior of the compatibility alias `{replace, Value}`;
- `{halt, Reason}` stops with a redacted structural failure.

An early return is therefore not an amendment. `on_model_error` and
`on_tool_error` can recover their phase through the normal intervention
results. `on_agent_error`, `on_run_error`, and success-only `after_run` are
best-effort notifications, so their intervention results are ignored.
Duplicate IDs, unavailable modules, invalid limits, and unknown modes are
rejected by `adk_runner:new/4`. Every callback has a
monitored timeout, heap limit, result-byte limit, owner monitor, and late-reply
suppression. `failure_policy => open` records a structural failure and
proceeds; `closed` stops the run. Hook contexts are immutable, secret-pruned
maps. Event amendments cannot alter identity, state/actions, continuations,
finality, or already-validated final content.

A compiled pipeline accepts at most 128 plugins; IDs are non-empty binaries of
at most 256 bytes. Descriptor timeouts are capped at 120 seconds, callback
heaps at 10,000,000 words, and callback results/configuration at 1 MiB each.
These are hard validation bounds, not suggested operational defaults.

The built-in plugins are ordinary descriptors and remain explicit policy:

- `adk_plugin_global_instruction` amends the model request with a bounded
  global instruction;
- `adk_plugin_context_filter` applies deterministic role/message filtering;
- `adk_plugin_reflect_retry` converts a bounded tool failure into model-visible
  retry guidance without exposing the raw failure;
- `adk_plugin_metadata_logger` emits content-free lifecycle metadata.

Use `mode => intervene` for the first three because they can amend or return a
phase value, and `mode => observe` for the metadata logger. For example, a
global-instruction descriptor uses
`#{id => <<"global-policy">>, module => adk_plugin_global_instruction, mode => intervene, failure_policy => closed, config => #{instruction => <<"Answer concisely.">>, position => prepend}}`.

Stateful plugins use one supervised actor per configured instance. Calls are
serialized, queued under a fixed cap, and executed in deadline/heap-bounded
workers against an immutable state snapshot. State commits only when the
owner remains alive and the callback completed before its deadline:

```erlang
{ok, readme_stateful_counter_plugin} =
    c("examples/readme_stateful_counter_plugin.erl"),
{ok, CounterInstance} = adk_plugin_runtime_sup:start_instance(
    #{id => <<"readme-counter">>,
      module => readme_stateful_counter_plugin,
      config => #{notify => self()},
      max_queue => 32,
      max_heap_words => 100000,
      max_state_bytes => 4096}),
StatefulPlugin =
    #{id => <<"stateful-counter">>,
      module => adk_plugin_stateful_adapter,
      mode => observe,
      failure_policy => closed,
      timeout_ms => 1000,
      max_heap_words => 100000,
      config => #{instance => CounterInstance, timeout_ms => 800}},
{ok, StatefulPipeline} = adk_plugin_pipeline:compile([StatefulPlugin]),
{continue, #{}, _StatefulTrace} = adk_plugin_pipeline:run(
    StatefulPipeline, before_run, #{}, #{}),
receive
    {stateful_before_run, 1} -> ok
after 1000 ->
    erlang:error(stateful_plugin_timeout)
end,
ok = adk_plugin_runtime_sup:stop_instance(CounterInstance).
```

The returned PID is the instance identity. Its supervisor child is deliberately
`temporary`: an unexpected crash makes that identity unavailable instead of
silently restarting with empty state behind a stale PID. Initialization itself
runs in a separately monitored timeout/heap-bounded worker. Applications that
need restart or durable state must recreate the instance explicitly or supply a
persistent plugin-state adapter.

Stateful instance IDs/configuration are capped at 256 bytes/1 MiB; queue,
worker-heap, state, initialization-timeout, and invocation-timeout values have
hard maxima of 4096 entries, 10,000,000 words, 64 MiB, 30 seconds, and 120
seconds respectively. A callback completion queued before an owner-monitor
`DOWN` is still discarded when that owner has already died; owner liveness is
part of the state-commit condition, not only a condition for sending a reply.

Runner observability is metadata-only by default. Set `observability =>
disabled` to turn it off. Legacy lifecycle envelopes and `telemetry` events
share trace, span, run, invocation, session, agent, model, tool, and call IDs;
schema-v2 operation spans add Unix-nanosecond timestamps and monotonic
durations at the actual model/tool/Live boundary. The pinned
`adk_genai_semconv:mapping_version/0` identifies the Development GenAI mapping
used by this release.

Prompt, response, media, tool arguments, and tool results are excluded by
default. `capture_content => true` applies only to the legacy envelope path;
the v2 GenAI mapper and low-cardinality metrics never accept content. Opaque
BEAM terms degrade to metadata-only diagnostics instead of breaking an
invocation.

For synchronous delivery, put bounded exporter descriptors in the Runner.
For asynchronous delivery, start the supervised central bus and configure the
Runner with `delivery => async`; per-Runner exporters are rejected in that
mode because retry, queue, and drop policy belong to the bus. This example
sends completed spans and v1 lifecycle logs to an OTLP/HTTP JSON collector:

```erlang
_ = application:stop(erlang_adk),
OtlpExporter =
    #{id => <<"local-otlp">>,
      module => adk_otlp_http_json_exporter,
      failure_policy => open,
      timeout_ms => 5000,
      max_heap_words => 250000,
      config =>
          #{endpoint => <<"http://127.0.0.1:4318">>,
            allow_private_hosts => true,
            timeout_ms => 3000}},
ok = application:set_env(erlang_adk, observability_bus_enabled, true),
ok = application:set_env(
    erlang_adk, observability_bus_options,
    #{exporters => [OtlpExporter],
      max_queue_events => 4096,
      max_queue_bytes => 16777216,
      max_event_bytes => 262144,
      batch_size => 32,
      max_inflight_batches => 2,
      max_attempts => 3,
      drop_policy => reject}),
{ok, _} = application:ensure_all_started(erlang_adk),
AsyncObservability =
    #{delivery => async,
      bus => adk_observability_bus,
      failure_policy => open,
      capture_content => false,
      attributes => #{environment => <<"development">>}}.
```

Pass that map as `#{observability => AsyncObservability}` (alongside any other
Runner options) in `adk_runner:new/4`; do not also put exporter descriptors in
the per-Runner asynchronous configuration.

The exporter never follows redirects and does not retry by itself. It labels
failures transient or permanent; the bus owns bounded delayed retries only for
eligible transient failures. Delivery is bounded best effort, not a durable
queue: a retry may duplicate a batch and exhausted retries are explicitly
dropped and counted. A collector should deduplicate by trace/span/event
identity. HTTP is appropriate only for a loopback collector;
use verified HTTPS for a remote OTLP endpoint. Do not put bearer credentials
in README/config files.

Inbound and outbound HTTP adapters can continue strict W3C `traceparent` and
bounded `tracestate` without adding an OpenTelemetry SDK dependency:

```erlang
{ok, InboundTrace} = adk_observability:from_headers(
    #{<<"traceparent">> =>
          <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>},
    #{agent => <<"WeatherAgent">>}),
{ok, OutboundHeaders} = adk_observability:inject_headers(
    InboundTrace, #{<<"accept">> => <<"application/json">>}).
```

Trace identifiers are correlation, never authorization. The built-in metrics
registry bounds both instruments and label series and folds overflow into an
explicit overflow series. `adk_observability_metrics:snapshot/0` and
`adk_observability_bus:stats/0` are operational snapshots, not billing-grade
durable counters.

See [plugins, observability, and evaluation](docs/PLUGINS_OBSERVABILITY_EVALUATION.md)
for lifecycle precedence, intervention boundaries, and adapter contracts.

## Evaluation

`adk_eval_set` provides versioned, JSON-safe, multi-turn evaluation. Schema v2
evaluates a complete case, supports repeated independent samples, and records
strict success/error/not-evaluated accounting. Cases and samples overlap only
up to their configured bounds; turns inside one sample stay ordered.

The production `adk_eval_agent_adapter` creates a fresh supervised agent,
Runner session, and cleanup guardian for every case/sample, so one evaluation
does not leak conversation state into another. The built-in full-case criteria
are `exact_response`, `trajectory_exact`, `trajectory_in_order`,
`trajectory_any_order`, and `trajectory_subset`; trajectory arguments may be
matched exactly, as a subset, or ignored. Custom per-turn metrics and
full-case metric/judge adapters remain supported.

This paid example uses the REST model and two isolated samples:

```erlang
{ok, EvalSet} = adk_eval_set:validate(
    #{schema_version => 2,
      id => <<"exact-dialogue">>,
      version => <<"1">>,
      cases =>
          [#{id => <<"two-turn-case">>,
             turns =>
                 [#{id => <<"first">>,
                    input => <<"Reply with exactly: ERLANG">>,
                    expected_response => <<"ERLANG">>},
                  #{id => <<"second">>,
                    input => <<"Again reply with exactly: ERLANG">>,
                    expected_response => <<"ERLANG">>}]}]}),
EvalTarget =
    #{name => <<"EvalSetAgent">>,
      config =>
          #{provider => adk_llm_gemini,
            model => <<"gemini-3.1-flash-lite">>,
            instructions =>
                <<"Follow the requested output format exactly.">>},
      tools => [],
      runner_options => #{}},
EvalAdapter = #{module => adk_eval_agent_adapter,
                target => EvalTarget, config => #{}},
EvalMetrics = [#{id => <<"exact-response">>,
                 criterion => exact_response,
                 threshold => 1.0,
                 config => #{normalization => exact}}],
{ok, EvalSetResult} = adk_eval_set:run(
    EvalAdapter, EvalSet, EvalMetrics,
    #{sample_count => 2,
      concurrency => 1,
      sample_concurrency => 2,
      pass_rate_threshold => 1.0,
      sample_pass_rate_threshold => 1.0,
      min_successful_samples => 2,
      capture_events => true,
      capture_tool_content => false}),
true = maps:get(<<"passed">>, EvalSetResult),
{ok, SavedEvalResult} = adk_eval_set:encode_result(EvalSetResult),
SavedEvalResult = jsx:decode(jsx:encode(SavedEvalResult), [return_maps]).
```

An evaluation adapter implements the `run_turn/5` callback in
`adk_eval_adapter`; optional
`init_case/4` and `terminate_case/3` callbacks own per-sample lifecycle. It may
return canonical ADK events, allowing tool-call and tool-response trajectories
to be captured without exposing their content by default. Metrics and
LLM-backed judges share the same checked result accounting; `kind => judge`
records the distinction without coupling the core evaluator to a provider.
`adk_eval_llm_judge` is the explicit first-party rubric adapter. It defaults
to `adk_llm_gemini` and `gemini-3.1-flash-lite`, requires a rubric identity and
version, requests structured JSON, and turns provider, timeout, schema, or
out-of-range-score failures into a failing judge result rather than a pass.
It is never selected implicitly.

This paid continuation uses the `EvalAdapter` and `EvalSet` above:

```erlang
RubricJudge =
    #{id => <<"rubric-quality">>,
      kind => judge,
      module => adk_eval_llm_judge,
      scope => 'case',
      threshold => 0.8,
      config =>
          #{rubric_id => <<"concise-correct-answer">>,
            rubric_version => <<"1">>,
            rubric =>
                <<"Score 1 for a correct, direct answer that follows the "
                  "requested format; score 0 otherwise.">>,
            provider => adk_llm_gemini,
            model => <<"gemini-3.1-flash-lite">>,
            request_timeout_ms => 30000}},
{ok, RubricResult} = adk_eval_set:run(
    EvalAdapter, EvalSet, [RubricJudge],
    #{sample_count => 1, concurrency => 1, sample_concurrency => 1}),
[RubricSummary] = maps:get(<<"metrics">>, RubricResult),
<<"rubric-quality">> = maps:get(<<"metric_id">>, RubricSummary).
```

Each judge request is monitored, deadline- and heap-bounded, and remains
concurrent with other bounded sample workers; there is no global judge
process. Provider-module injection and `provider_config` are trusted Erlang
configuration for applications and deterministic tests, not browser, dataset,
or CLI input. The successful metadata records judge schema, provider, requested
model, rubric ID/version, and a bounded rationale. Provider credentials and
raw provider errors are excluded and secret-bearing input keys are pruned.
The rationale is still evaluation content stored in reports and may summarize
other case data, so protect reports according to the evaluated data's policy.
User/environment simulation and managed evaluation services remain explicit
adapters with their own credentials and cost policy.

Empty criteria fail by default; use `empty_criteria => pass` only when an
intentional execution-only evaluation should pass without scoring. Overall
timeouts, per-case timeouts, heap bounds, input depth/size, sample count,
concurrency, captured data, and final report bytes are all bounded. A timed-out
or killed sample cannot orphan its adapter-owned agent.

Saved v2 results can be compared with per-metric tolerances and a maximum pass
rate drop, then rendered deterministically:

```erlang
{ok, Comparison} = adk_eval_set:compare(
    BaselineEvalResult, EvalSetResult,
    #{max_pass_rate_drop => 0.05,
      metric_tolerances => #{<<"exact-response">> => 0.0}}),
{ok, MarkdownReport} = adk_eval_set:report(Comparison, markdown),
io:format("~ts", [MarkdownReport]).
```

The packaged CLI runs the same v2 engine. It defaults to built-in exact
response scoring when `--criteria` is omitted, emits JSON to stdout by
default, exits `0` on a passing gate, `2` on a completed failing gate, and `1`
for invalid input/runtime errors:

```bash
./rebar3 escriptize
_build/default/bin/adk eval run \
  --config examples/agent.json \
  --eval-set /path/to/eval-set-v2.json \
  --criteria /path/to/eval-criteria-v2.json \
  --samples 2 \
  --concurrency 2 \
  --sample-concurrency 2 \
  --baseline previous-eval-result.json \
  --max-pass-rate-drop 0.05 \
  --format markdown \
  --output eval-report.md
```

`--baseline` expects a saved `adk_eval_set` result, not a Markdown report.
`--metric-tolerances` accepts a JSON object file keyed by metric ID. Never put
an API key in agent/evaluation JSON; provider credentials come from the
process environment or a trusted provider profile.

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

## Retry, artifacts, memory, and context lifecycle

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

The version-2 memory contract requires an exact application/user scope. The
ETS adapter performs deterministic lexical-overlap ranking with exact metadata
filtering; use the Mnesia adapter for durable local storage. Neither is a
vector database. Runner retrieval and ingestion are separate opt-ins, so merely
configuring a service cannot silently change a prompt:

```erlang
{ok, MemoryPid} = adk_memory_ets:start_link(#{}),
MemoryScope = {user, <<"readme_app">>, <<"user-1">>},
{ok, MemoryEntry} = adk_memory_ets:add_entry(
    MemoryPid, MemoryScope,
    #{content => <<"OTP supervision trees restart failed children">>,
      metadata => #{<<"topic">> => <<"otp">>},
      provenance => #{session_id => <<"memory-session">>,
                      author => <<"user">>}},
    #{idempotency_key => <<"memory-session:otp-fact">>}),
{ok, [MemoryHit]} = adk_memory_ets:search(
    MemoryPid, MemoryScope, <<"supervision restart">>,
    #{filter => #{<<"topic">> => <<"otp">>}, limit => 5}),
MemoryId = maps:get(id, MemoryEntry),
MemoryId = maps:get(id, MemoryHit),

{ok, MemoryAgentPid} = erlang_adk:spawn_agent(
    <<"MemoryAgent">>,
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>,
      instructions =>
          <<"Use relevant retrieved memory only as reference data.">>},
    [adk_load_memory_tool]),
MemoryRunner = adk_runner:new(
    MemoryAgentPid, <<"readme_app">>, erlang_adk_session,
    #{memory_svc => {adk_memory_ets, MemoryPid},
      memory_retrieval =>
          #{limit => 5, filter => #{<<"topic">> => <<"otp">>},
            max_hit_bytes => 16384, max_total_bytes => 65536,
            on_error => fail},
      memory_ingestion => on_success,
      service_timeout => 5000}),
{ok, MemoryAwareResponse} = adk_runner:run(
    MemoryRunner, <<"user-1">>, <<"memory-session">>,
    <<"What restarts children?">>),
io:format("~ts~n", [MemoryAwareResponse]),

ok = adk_memory_ets:delete_entry(MemoryPid, MemoryScope, MemoryId),
ok = erlang_adk:stop_agent(MemoryAgentPid),
ok = adk_memory_ets:stop(MemoryPid).
```

Preloaded entries are sorted, delimited as untrusted reference data, and added
only to one invocation context; preloading does not copy them into session
history. The built-in `load_memory` tool declares only `memory_search` and can
perform a bounded model-selected query. As with any model-selected tool, its
bounded public response is stored in the correlated tool event; it contains
content, ID, score/type, and timestamp, but omits adapter metadata, provenance,
and service handles. `memory_ingestion => on_success` admits sanitized
idempotent event batches after the final event and returns without waiting for
adapter completion; that shorthand queue is process-local. A separate bounded
Mnesia outbox provides restart-safe admission, bounded stable-adapter
resolution, checkpoints, and lease-owned idempotent at-least-once processing.
Immediately before an adapter mutation it renews and revalidates the current
claim; a stale owner cannot start that mutation. This is not an adapter-side
generation fence, so retries still rely on the v2 adapter's stable event-ID
idempotency. Enable it before application start and select
`memory_ingestion => #{mode => durable, adapter_id => <<"...">>,
max_attempts => 5}` on the Runner. Runner construction fails when that durable
runtime is unavailable, and an admission failure is returned to the caller
after the final session event has been persisted. See the memory guide for the
exact boundary and operational status API.

Entry, session, and user erasure are exact-scope operations. See
[scoped long-term memory](docs/MEMORY.md) for Mnesia setup, ingestion durability,
deadlines, provenance, and current limits.

The direct ETS/Mnesia adapters serialize ranking and storage within one service
process. Use `adk_memory_sharded` when unrelated user scopes should overlap: it
owns one stable supervised adapter worker per exact `{user, App, User}` scope,
bounds active scopes and router admission, and defaults to ETS or can wrap
`adk_memory_mnesia`. Same-scope calls remain ordered. An independent guard
releases cold-route admission when a caller dies or times out and prevents its
queued stale request from creating an abandoned shard. Capacity reported by
this wrapper is per shard (`global_quota => false`), so deployments needing a
global tenant budget must enforce it in admission or a custom adapter.

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
{ok, #{scope := ArtifactScope,
       items := [<<"reports/result.txt">>], next_cursor := undefined}} =
    adk_artifact_ets:list_names(ArtifactPid, ArtifactScope, #{limit => 100}),
io:format("sha256=~ts~n", [Digest]),
ok = adk_artifact_ets:stop(ArtifactPid).
```

Pass `{adk_artifact_ets, ArtifactPid}` as Runner option `artifact_svc`. A new
local tool declares only the operations it needs through
`context_capabilities/0` and calls `adk_context:save_artifact/4`,
`load_artifact/3`, `list_artifacts/2`, `list_artifact_versions/3`, or
`delete_artifact/3`; it never receives the service PID. Successful mutations
produce metadata-only `context_effects` in the correlated tool event.

Adding `adk_load_artifacts_tool` allows model-selected attachment. Runner
verifies the exact scoped version, MIME type, size, and digest and injects its
bounded `adk_content` parts into only the next model request. Artifact bytes
are not copied into ordinary history, state, events, or developer diagnostics.

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
filesystem adapter admits at most `max_scan_entries div 3` lifetime versions
for one scoped logical name. It also admits at most `max_scan_entries div 2`
lifetime scopes per root and the same number of lifetime names per scope
(`max_scan_entries` must be at least three). Exhaustion returns
`artifact_version_capacity_reached`, `artifact_name_capacity_reached`, or
`artifact_scope_capacity_reached` before bounded listing/repair scans fail.
Durable slots and version reservations are non-reuse tombstones, so deletion
does not restore any lifetime capacity. Rotate to a new name, scope, or root as
appropriate, or configure a larger bound before deployment. The root and
generated directories must be real directories rather than symlinks.
The adapter does not encrypt artifacts; use least-privilege permissions and an
encrypted volume where confidentiality requires it. See
[Artifact services](docs/ARTIFACTS.md).

For artifact workloads with many independent scopes, `adk_artifact_sharded`
provides the same service API with one stable supervised ETS or filesystem
worker per exact scope. Unrelated scopes execute concurrently while one scope
retains adapter ordering. The wrapper bounds active scopes and simultaneous
cold-route admission; resolved scopes bypass the router through a protected
ETS route. A guard monitors each unresolved caller, releases its permit on
death or timeout, and prevents an already queued stale request from creating
an abandoned shard. Filesystem shards use deterministic path-safe subroots.
Its quotas are per shard rather than globally aggregated. See the artifact guide for
setup, status, persistence, and repair limitations.

Context selection, automatic-compaction, and provider-prefix-cache lifecycle
APIs are documented in [Context selection, compaction, and caching](docs/CONTEXT.md).
Runner compaction requires a session backend implementing atomic
`compact_events/5` (both bundled backends do), and the prefix cache stores
provider request prefixes rather than model responses. Both remain explicit
Runner options rather than default behavior.

Provider cache creation is deadline-safe even at a mailbox race: immediately
before installing a successful provider result, the registry synchronously
rechecks every waiter's absolute deadline. Expired callers receive the
configured deadline failure/bypass result; if all waiters have expired, the
new provider resource is deleted through the bounded cleanup path instead of
becoming an unreachable cache entry.

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
      max_subscribers_per_task => 64,
      max_subscriber_queue => 8,
      max_input_bytes => 1048576,
      max_message_bytes => 524288,
      max_task_bytes => 4194304,
      max_event_bytes => 2097152,
      max_artifact_bytes => 2097152,
      max_history_bytes => 2097152,
      max_history_messages => 128,
      max_artifacts => 128,
      max_parts_per_artifact => 256}),
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
    <<"http://127.0.0.1:8080">>,
    #{allow_http_loopback => true}),
A2AMessage = #{
    <<"messageId">> => <<"poem-request-1">>,
    <<"role">> => <<"ROLE_USER">>,
    <<"parts">> => [#{<<"text">> =>
                           <<"Write a short poem about Erlang.">>,
                       <<"mediaType">> => <<"text/plain">>}]
},
{ok, #{<<"task">> := A2ATask}} = adk_a2a_v1_client:send(
    RemoteCard, A2AMessage,
    #{timeout => 65000, allow_http_loopback => true}),
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

For a public or non-loopback deployment, use a dedicated A2A listener, the
OIDC hook, matching Agent Card security declarations, explicit public-bind
opt-in, and either direct TLS or an explicitly trusted TLS proxy. `JwtPolicy`
is an `adk_jwt_policy` value configured with exact HTTPS issuer, audience,
token type, maximum lifetime, asymmetric algorithm allow-list, time bounds,
and required scopes. This direct-TLS example assumes the certificate files are
readable only by the service account:

```erlang
_ = application:stop(erlang_adk),
{ok, PublicA2ACard} = adk_a2a_v1_card:new(
    #{url => <<"https://agent.example.com:8443/a2a/v1">>,
      security_schemes =>
          #{<<"company-oidc">> =>
                #{<<"openIdConnectSecurityScheme">> =>
                      #{<<"openIdConnectUrl">> =>
                            <<"https://identity.example.com/",
                              ".well-known/openid-configuration">>}}},
      security_requirements =>
          [#{<<"schemes">> =>
                 #{<<"company-oidc">> =>
                       #{<<"list">> => [<<"a2a.invoke">>]}}}]}),
ok = application:set_env(erlang_adk, dev_enabled, false),
ok = application:set_env(erlang_adk, a2a_enabled, false),
ok = application:set_env(erlang_adk, a2a_v1_enabled, true),
ok = application:set_env(erlang_adk, a2a_v1_card, PublicA2ACard),
ok = application:set_env(
    erlang_adk, a2a_v1_auth, adk_a2a_v1_oidc_auth),
ok = application:set_env(erlang_adk, a2a_v1_jwt_policy, JwtPolicy),
ok = application:set_env(erlang_adk, a2a_ip, {0, 0, 0, 0}),
ok = application:set_env(erlang_adk, a2a_port, 8443),
ok = application:set_env(erlang_adk, a2a_allow_non_loopback, true),
ok = application:set_env(erlang_adk, a2a_v1_auth_timeout_ms, 5000),
ok = application:set_env(erlang_adk, a2a_v1_auth_max_heap_words, 300000),
ok = application:set_env(
    erlang_adk, a2a_tls_options,
    [{certfile, "/run/secrets/a2a-cert.pem"},
     {keyfile, "/run/secrets/a2a-key.pem"}]),
{ok, _} = application:ensure_all_started(erlang_adk).
```

The authorization hook receives request headers transiently and returns a
safe principal plus a stable principal ID. The store retains only a SHA-256
principal scope; credentials and raw headers are never placed in protocol
tasks or events. Cross-principal lookup, listing, cancellation, and
subscription all return the same not-found result as an unknown task. The
outbound client obtains authorization headers just in time through
`auth_fun/0`, so a token manager can rotate credentials without storing them
in client state. For a secured card, pass the exact declared scheme name as
`auth_scheme` together with `auth_fun`; an undeclared or missing scheme fails
closed. Card discovery has a separate `discovery_auth_fun`, so an RPC bearer is
never sent to the discovery origin by accident. Outbound requests require
HTTPS, resolve and validate every address, pin the validated destination, and
reject redirects and cross-origin interfaces by default. Each public client
call has one absolute deadline, including its monitored, heap-limited
credential callback; when a single RPC call receives a location and performs
discovery itself, that deadline spans discovery and RPC. Calling `discover/2`
first and then passing the returned card to `send/3` creates two separately
bounded operations. Narrow `allowed_hosts`, `allowed_private_hosts`,
`allowed_interface_origins`, `max_extensions`, `max_extension_header_bytes`,
`auth_timeout`, and `auth_max_heap_words` for the deployment. Clear HTTP is
accepted only
when every resolved address is loopback and `allow_http_loopback => true`.
Authentication and DNS workers use aliases, completion timestamps, bounded
normalized results, and owner watchdogs; DNS admission stops at 64 addresses,
and killing the request owner reaps the worker instead of leaving an orphan.
A public listener refuses to share `/dev` or the legacy
`/a2a/prompt` route. If TLS terminates at a proxy instead, set
`a2a_trusted_tls_proxy` only when the listener is reachable exclusively from
that trusted proxy; forwarded headers alone are not a trust boundary.

Current limitations are explicit: this release implements the JSON-RPC 1.0
binding, not gRPC or HTTP+JSON. Push-notification configuration and extended
Agent Cards return their canonical A2A unsupported-operation errors; they and
Agent Card JWS signing/verification are not implemented. Agent Card security
schemes/requirements are structurally validated, but the bundled client only
authenticates a requirement alternative containing one exact declared scheme;
compound AND requirements fail locally as unsupported. The operator must keep
the server hook's actual scheme/scopes aligned with its card—the runtime cannot
infer callback semantics. Bounded required `A2A-Extensions` negotiation is
validated.
Tasks and replay buffers are node-local and bounded rather than distributed
durable storage. `Last-Event-ID` reconnect works only inside the retained event
window. A slow server-side SSE subscriber is detached at its configured mailbox
ceiling and reconnects from that cursor; the bundled outbound client returns a
bounded decoded event list rather than an unbounded live callback. Clear HTTP
is restricted to loopback; a non-loopback startup fails
closed without the explicit authentication, card, and TLS conditions above.
See the official [A2A 1.0
specification](https://a2a-protocol.org/latest/specification/) for the binding
and data-model contract.

## Legacy simple HTTP endpoint

The application can still expose `POST /a2a/prompt` for this project's legacy
small JSON protocol. It is separate from A2A 1.0. The listener is disabled by
default, supervised when enabled, and always restricted to IPv4 127/8 or IPv6
`::1`; startup fails with `legacy_a2a_server_must_bind_loopback` for every
non-loopback or wildcard address. The A2A v1 public-listener opt-ins do not
weaken that legacy boundary. Listener settings are read only when the
application starts. Because this repository's `rebar3 shell` starts
`erlang_adk` automatically, stop the application before changing them:

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

This legacy endpoint is not wire-compatible with A2A and cannot be configured
as a production public API. New integrations should use the authenticated A2A
1.0 endpoint above.

## Integrated developer tooling

The Erlang-hosted developer console uses the same independently supervised run
and Live runtimes as applications. It provides chat, event traces, bounded run
replay, reconnect, cancellation, session inspection, approval/resume, Live
status/text/future-only SSE, evaluation render/compare, and content-free
observability snapshots without adding an Elixir or Node.js dependency. It is
disabled by default and binds to loopback by default.

Set a dedicated local bearer token before starting the VM:

```bash
export ERLANG_ADK_DEV_TOKEN="replace-with-at-least-16-random-characters"
```

Then configure the listener bounds before the application starts. If artifact
or memory routes are needed, do not start the application until the
exact-scope resource provider in the following two fences is also configured:

```erlang
_ = application:stop(erlang_adk),
DevLivePrincipal = <<"readme-live-user">>,
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
ok = application:set_env(
    erlang_adk, dev_live_principal, DevLivePrincipal),
ok = application:set_env(
    erlang_adk, dev_live_credit,
    #{messages => 16, bytes => 4194304}),
ok = application:set_env(erlang_adk, dev_max_resource_results, 100),
ok = application:set_env(erlang_adk, dev_diagnostic_timeout_ms, 5000),
ok = application:set_env(
    erlang_adk, dev_diagnostic_context_policy,
    #{max_bytes => 1048576,
      max_tokens => 262144,
      overflow => truncate}),
ok = application:set_env(erlang_adk, dev_sse_max_events, 128),
ok = application:set_env(erlang_adk, dev_sse_max_bytes, 1048576),
ok = application:set_env(erlang_adk, dev_sse_max_duration_ms, 300000).
```

The authenticated local API is:

| Method | Path | Behavior |
| --- | --- | --- |
| `GET` | `/dev/v1/agents` | Discover live registered agents by stable name |
| `GET` | `/dev/v1/diagnostics` | Inspect context capabilities and configured artifact/memory sources without content or handles |
| `GET` | `/dev/v1/observability` | Inspect bounded metric/export-bus snapshots; content is never returned |
| `POST` | `/dev/v1/evaluation/render` | Validate and render one supplied v1/v2 evaluation result as bounded JSON or Markdown |
| `POST` | `/dev/v1/evaluation/compare` | Compare exact supplied baseline/current results and return a bounded checked comparison |
| `GET` | `/dev/v1/live/sessions` | List bounded status for server-owned Live sessions matching the configured exact principal |
| `POST` | `/dev/v1/live/sessions/:session/text` | Send one bounded text input to that principal's Live session |
| `GET` | `/dev/v1/live/sessions/:session/events` | Attach future-only bounded Live SSE; `Last-Event-ID` is rejected because Live is not replayed |
| `GET` | `/dev/v1/context/:app/:user/:session` | Explain bounded context counts and fingerprint for one exact session; events/state are omitted |
| `GET` | `/dev/v1/context/:app/:user/:session/lifecycle?model=MODEL` | Inspect the latest whitelisted compaction checkpoint fields and content-free cache counts |
| `POST` | `/dev/v1/context/:app/:user/:session/cache/invalidate` | Invalidate one confirmed provider/app/user/model/policy cache scope across sessions |
| `GET` | `/dev/v1/artifacts/:app/:user/:session` | List a bounded page of logical names (`limit`, optional exclusive `cursor`) |
| `GET` | `/dev/v1/artifacts/:app/:user/:session/versions` | List metadata-only versions for required `name` with bounded pagination |
| `POST` | `/dev/v1/artifacts/:app/:user/:session/delete` | Delete one checked selector after an exact matching confirmation object |
| `GET` | `/dev/v1/memory/:app/:user` | Inspect the scoped adapter's public capabilities and limits |
| `POST` | `/dev/v1/memory/:app/:user/search` | Search bounded, redacted reference memory in one exact user scope |
| `POST` | `/dev/v1/memory/:app/:user/erase` | Erase an entry, session, or user after an exact matching confirmation object |
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

Artifact and memory routes need an exact-scope resource provider. This avoids a
global service lookup based only on path text. The callback receives the
requested scope and returns a validated service reference or denies it. Put
the module in the owning application's source tree and compile it before the
startup fence below:

```erlang
-module(my_dev_resource_provider).
-export([resolve/3]).

resolve(#{app_name := App, user_id := User, session_id := Session,
          artifact_svc := ArtifactService},
        artifact, {session, App, User, Session}) ->
    {ok, ArtifactService};
resolve(#{app_name := App, user_id := User,
          memory_svc := MemoryService},
        memory, {user, App, User}) ->
    {ok, MemoryService};
resolve(_Handle, _Kind, _Scope) ->
    {error, forbidden}.
```

For a local development VM, create fresh resource services, configure the
provider, start the application, and then seed the data the commands below
inspect. These processes are deliberately distinct from the short-lived
memory/artifact examples above, which already stopped their services:

```erlang
{ok, DevArtifactPid} = adk_artifact_ets:start_link(#{}),
{ok, DevMemoryPid} = adk_memory_ets:start_link(#{}),
{ok, DevCachePid} = adk_context_cache:start_link(
    #{min_prefix_tokens => 4096,
      default_ttl_ms => 300000,
      failure_mode => bypass}),
{ok, DevRunnerOptions} =
    application:get_env(erlang_adk, dev_runner_options),
ok = application:set_env(
    erlang_adk, dev_runner_options,
    DevRunnerOptions#{context_cache =>
        #{cache => DevCachePid,
          provider => adk_context_cache_gemini,
          ttl_ms => 300000,
          policy => #{purpose => developer_inspection}}}),
DevResources =
    #{app_name => <<"readme_app">>,
      user_id => <<"user-1">>,
      session_id => <<"artifact-session">>,
      artifact_svc => {adk_artifact_ets, DevArtifactPid},
      memory_svc => {adk_memory_ets, DevMemoryPid}},
ok = application:set_env(
    erlang_adk, dev_resource_provider,
    {my_dev_resource_provider, DevResources}),
{ok, _} = application:ensure_all_started(erlang_adk),
DevArtifactScope =
    {session, <<"readme_app">>, <<"user-1">>, <<"artifact-session">>},
{ok, _} = adk_artifact_ets:put(
    DevArtifactPid, DevArtifactScope, <<"reports/result.txt">>, <<"ready">>,
    #{mime_type => <<"text/plain">>}),
{ok, _} = adk_memory_ets:add_entry(
    DevMemoryPid, {user, <<"readme_app">>, <<"user-1">>},
    #{content => <<"OTP supervision restarts failed children">>,
      provenance => #{session_id => <<"memory-session">>}}, #{}),
{ok, _} = erlang_adk_session:create_session(
    <<"readme_app">>, <<"user-1">>,
    #{session_id => <<"artifact-session">>}).
```

Now open `http://127.0.0.1:8080/dev` and enter the token in the connection
panel. The token remains in page memory, is sent only in the `Authorization`
header, and is never accepted in a query string. Cowboy route state keeps only
its SHA-256 digest. Browser requests with an `Origin` header must be
same-origin.

`dev_live_principal` is mandatory for developer Live access and must exactly
match the `Principal` supplied to `start_live_session/3`. It is an ownership
capability, not a display name or wildcard. The developer bearer does not
bypass the Live session's principal check. The console discovers and controls
only sessions already supervised in the same VM; it does not accept a model,
API key, transport, tool executor, or principal from the browser and does not
create a Live session. Start the Live session from trusted application code as
shown in the Gemini Live section and leave it open while testing this panel.
The browser projection omits audio/media bytes and provider signatures.

For a simple single-tenant local server, putting `artifact_svc` and
`memory_svc` in `dev_runner_options` remains a compatibility fallback. A
provider is preferred whenever different paths may resolve to different
tenants. Provider handles and returned service references never appear in
diagnostic output. Context diagnostics work independently through
`dev_session_service`.

The developer boundary also validates every adapter result against the path
scope. An artifact name-page envelope or version record whose embedded session
scope differs from the requested app/user/session, or a memory hit whose
embedded user scope differs from the requested app/user, fails closed as
unavailable; it is never projected under the caller's scope.

The lifecycle endpoint reads cache configuration only from the private
`dev_runner_options.context_cache` map used by that listener. It returns
whitelisted compaction checkpoint identifiers/counts and cache lifecycle
counts; it never returns events, summaries, state, policy values, PIDs, leases,
provider resource names, or credentials. Its session path proves that the
caller can inspect the anchor session, but a prefix cache is deliberately
shared across sessions within the exact configured provider, app, user, model,
and policy scope. Confirmed invalidation removes every entry and in-flight
create in that scope, across TTLs and prefixes. The 64-character
`scope_fingerprint` identifies this breadth without exposing the policy.

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
[`examples/agent.json`](examples/agent.json)
contains:

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

Plain `adk serve` intentionally has no browser/CLI option that invents a Live
principal or creates a Live session. Its agent/run and observability panels
work directly. For the Live commands below, target the OTP VM started after
the trusted `dev_live_principal` configuration above and keep a matching Live
session open.

```bash
export ERLANG_ADK_DEV_TOKEN="replace-with-the-same-local-token"
_build/default/bin/adk inspect agents --url http://127.0.0.1:8080
_build/default/bin/adk inspect diagnostics --url http://127.0.0.1:8080
_build/default/bin/adk inspect observability --url http://127.0.0.1:8080

# These two commands require the trusted dev_live_principal configuration and
# an already-supervised matching Live session; plain `adk serve` supplies neither.
_build/default/bin/adk inspect live --url http://127.0.0.1:8080
_build/default/bin/adk live send readme-live-session \
  --text "Explain supervision" --url http://127.0.0.1:8080
_build/default/bin/adk inspect run RUN_ID
_build/default/bin/adk session create adk-cli local scratch
_build/default/bin/adk inspect sessions adk-cli local
_build/default/bin/adk inspect session adk-cli local scratch
_build/default/bin/adk session state adk-cli local scratch \
  --delta-json '{"developer:mode":"trace"}'
_build/default/bin/adk resume RUN_ID \
  --response-json '{"confirmed":true}'
_build/default/bin/adk session delete adk-cli local scratch

# The remaining resource/context commands require an owning OTP server
# configured by the Erlang startup example above. Plain `adk serve` has no
# artifact or memory service PIDs; replace it with that resource-enabled VM.
_build/default/bin/adk inspect context readme_app user-1 artifact-session
_build/default/bin/adk inspect context-lifecycle \
  readme_app user-1 artifact-session --model gemini-3.1-flash-lite
_build/default/bin/adk inspect artifacts readme_app user-1 artifact-session \
  --limit 100
_build/default/bin/adk inspect artifact readme_app user-1 artifact-session \
  --name reports/result.txt --limit 100
_build/default/bin/adk inspect memory readme_app user-1
_build/default/bin/adk memory search readme_app user-1 \
  --query "supervision restart" --limit 5
```

Against that resource-enabled OTP server, destructive CLI commands require the
exact JSON confirmation printed in their arguments, for example:

```bash
_build/default/bin/adk artifact delete \
  readme_app user-1 artifact-session reports/result.txt latest \
  --confirm-json \
  '{"app_name":"readme_app","user_id":"user-1","session_id":"artifact-session","name":"reports/result.txt","selector":"latest"}'

_build/default/bin/adk memory erase \
  readme_app user-1 session memory-session \
  --confirm-json \
  '{"app_name":"readme_app","user_id":"user-1","target":"session","identifier":"memory-session"}'

# Replace SCOPE_FINGERPRINT with the exact value returned by
# `adk inspect context-lifecycle`; this invalidates the provider/app/user/
# model/policy cache scope across sessions, not only artifact-session.
_build/default/bin/adk context-cache invalidate \
  readme_app user-1 artifact-session --model gemini-3.1-flash-lite \
  --confirm-json \
  '{"app_name":"readme_app","user_id":"user-1","session_id":"artifact-session","model":"gemini-3.1-flash-lite","scope_fingerprint":"SCOPE_FINGERPRINT"}'
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

The resume payload above is the exact contract for a pause whose details type
is `tool_confirmation`; use `{"confirmed":false}` to reject it. The developer
UI detects that type and fills the matching payload automatically. Other pause
types, including application-defined long-running work and credential flows,
retain their own validated response shape—inspect the pause details rather
than sending `confirmed` indiscriminately.

`developer_api_unavailable` with `connection_refused` means no process is
listening at the selected URL; it is not an authentication or Gemini error.
Check that the first terminal is still running and that the port is free. If
8080 is occupied, choose another loopback port for `serve`, pass the matching
`--url` to every inspection command, and open that same port in the browser.
If diagnostics report an artifact or memory source as `"unavailable"`, the
HTTP listener is healthy but no `dev_resource_provider` (or compatibility
service in `dev_runner_options`) was configured for that resource. A normal
`adk serve --config examples/agent.json` cannot manufacture storage PIDs from
JSON; start configured services in the owning OTP application and expose them
through the callback above. `context_cache_unavailable` on lifecycle or
invalidation similarly means that listener did not start with a live private
cache/provider map in `dev_runner_options.context_cache`; it does not indicate
that Gemini text generation or the session backend failed.

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
ok = application:set_env(
    erlang_adk, auth_provider_profiles,
    #{<<"orders-api">> =>
          #{provider_module => adk_auth_provider_oidcc,
            context => #{provider_worker => company_oidc},
            allowed_scopes => [<<"orders.read">>],
            allowed_audiences => [<<"https://orders.example.com">>],
            resource_indicator => true}}),
{ok, _} = application:ensure_all_started(erlang_adk),
{ok, JwtPolicy} = adk_jwt_policy:new(
    #{issuer => <<"https://identity.example.com">>,
      audience => <<"erlang-adk-api">>,
      trusted_audiences => [],
      signing_algs => [<<"RS256">>],
      allowed_token_types => [<<"at+jwt">>],
      token_use => access_token,
      max_token_lifetime_seconds => 3600,
      clock_skew_seconds => 30,
      required_scopes => [<<"agent.run">>],
      verifier_timeout_ms => 5000,
      verifier_max_heap_words => 262144,
      provider => company_oidc}),
{ok, Identity} = adk_jwt_policy:authenticate(
    JwtPolicy, RequestHeaders),
Principal = maps:get(principal, Identity).
```

`RequestHeaders` must come from the HTTP boundary; tokens in query parameters
or request bodies are not accepted. In addition to Oidcc signature/JWKS checks,
the policy independently enforces HTTPS issuer equality, audience containment,
an asymmetric algorithm and token-type allow-list,
maximum token lifetime, expiration/not-before/issued-at, subject, scope,
bounded clock skew, and a safe claim allow-list. The returned principal is
issuer-bound, so identical subjects from different issuers cannot collide.
The verifier callback and its normalized claims execute in a monitored,
deadline- and heap-bounded worker; late, oversized, crashed, or heap-exhausted
verification fails closed without retaining a reply in the caller mailbox.
`token_use => access_token` deliberately does not compare the OIDC `azp`
(client) claim with the API resource audience. Consumers that validate an ID
token directly must select `token_use => id_token`; the Phoenix code exchange
also validates nonce and `azp` against its configured OIDC client before the
identity reaches the gateway.

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
      credential_ref => CredentialRef,
      scopes => [<<"orders.read">>],
      audience => <<"https://orders.example.com">>},
    15000),
<<"Bearer">> = maps:get(token_type, OAuthToken).
```

The provider module, its base context, allowed scopes/audiences, and RFC 8707
resource-indicator policy come only from the immutable operator profile loaded
when `adk_auth_sup` starts. A request cannot replace them. Concurrent requests
for the same principal/provider/scopes/audience join one monitored refresh;
cache size, in-flight refreshes, and waiters per refresh are bounded. On
credential deletion or revocation, call `adk_token_manager:invalidate/2` with
the exact principal, provider, and opaque credential reference before removing
the credential. Refresh-token grants require an expected subject; when a
provider rotates the refresh token, the new value is atomically persisted
before the access token is released. A stale compare-and-swap or storage
failure fails closed. The built-in ETS store is private and node-local;
production secret-manager adapters implement `adk_credential_store`, including
atomic `compare_and_swap/6`, and should be durable and encrypted.

Interactive user OAuth/OIDC uses the supervised authorization-code manager and
the same durable Runner suspension contract as other long-running tools. Put
provider/client/redirect/resource/scope policy behind a zero-arity loader so a
client secret never appears in a supervisor child specification:

```erlang
ok = application:set_env(
    erlang_adk, auth_authorization_profile_loader,
    {my_auth_profiles, load}).
```

`my_auth_profiles:load/0` returns an immutable provider map. A production Oidcc
entry has `adapter_module => adk_oidcc_authorization_code_adapter` and an
`adapter_context` containing the configured `provider_worker`, `client_id`, and
secret-manager-sourced `client_secret`; it also fixes the HTTPS `redirect_uri`,
`allowed_scopes`, `default_scopes`, optional RFC 8707 `resource`, lifetime, and
public prompt. The loader module is trusted operator code and must not use
request or model data.

Authorization-URI construction defaults to a two-second deadline and code
exchange to a 30-second deadline. Both adapter calls run in monitored,
owner-bound workers with a 262,144-word default heap cap and bounded results;
standalone `adk_auth_sup` deployments may tighten these through
`authorization_flow_opts` (`authorization_uri_timeout_ms`,
`exchange_timeout_ms`, and `adapter_max_heap_words`). The profile loader is
trusted boot-time operator code, not a request callback or a hostile-code
sandbox.

Begin the flow only from an authenticated application context. The returned
map is directly usable with `adk_suspension:request_credential/2`:

```erlang
{ok, CredentialRequest} = adk_authorization_flow:begin_flow(
    adk_authorization_flow,
    #{principal => Principal,
      provider => <<"calendar">>,
      scopes => [<<"openid">>, <<"calendar.read">>]}),
AuthorizationUri = maps:get(<<"authorization_uri">>, CredentialRequest),
State = maps:get(<<"correlation_id">>, CredentialRequest),
FlowRef = maps:get(<<"credential_flow_ref">>, CredentialRequest),
#{<<"pkce_method">> := <<"S256">>} = CredentialRequest.
```

The HTTPS callback gives the manager only the one-time state and bounded
authorization code. It performs the exact provider/client/redirect/nonce/PKCE
exchange internally and atomically replaces the pending credential:

```erlang
{ok, ResumeResponse} = adk_authorization_flow:complete(
    adk_authorization_flow, State, AuthorizationCode),
FlowRef = maps:get(<<"credential_ref">>, ResumeResponse),
State = maps:get(<<"correlation_id">>, ResumeResponse).
```

Provider profiles, nonce, verifier, client credentials, and token results
remain in private/bounded processes and owner-private ETS. The high-entropy
state is intentionally returned in the authorization URI and the bounded code
arrives at the callback; both are transient correlation inputs and are never
placed in model/session data or telemetry. State is atomically claimed before
exchange, so replay, provider mix-up, callback races, expiry, timeout, and
cancellation fail closed. The validated provider `sub` becomes
the refresh credential's `expected_subject`; the separate issuer-bound local
`Principal` remains the credential-store owner. Runner resume accepts only the
matching opaque `FlowRef` and `State`, never a raw authorization code or token.
Call `adk_authorization_flow:cancel/2` when the browser abandons a flow.

The `/dev` bearer token is deliberately only local developer authentication.
It must not be reused as end-user identity, a model API key, or a tool
credential.

## Phoenix LiveView companion

Phoenix is compatible with Erlang ADK and remains an optional companion rather
than a core dependency. Version 0.7 checks in a complete Phoenix 1.8/LiveView
application at `examples/phoenix_adk_ui`. It runs in the same BEAM release and
calls `adk_web_gateway` directly; it does not proxy the local `/dev/v1`
administrator API.

The gateway authorizes requests in independent lightweight workers. Defaults
admit 64 concurrent checks with a one-second callback deadline and a
100,000-word heap cap; deployments can tighten `max_authorizations`,
`authorizer_timeout_ms`, and `authorizer_max_heap_words` in their trusted
`gateway_options/0`. Callback crash, timeout, oversized input/result, caller
death, or heap exhaustion fails closed without terminating the gateway.

The ordinary agent-run surface uses `gemini-3.1-flash-lite` and a server-owned
agent catalog. The `/live` operations surface uses the separately configured
`ErlangAdkUi.LiveGateway`; it discovers already-supervised Live sessions and
never accepts a model, provider, transport, API key, principal, module, file
path, or evaluation catalog from browser input.

For a loopback-only development session without an OIDC provider, enable the
explicit local identity. It is accepted only in `MIX_ENV=dev`, forces the HTTP
listener to `127.0.0.1`, uses a fixed server-owned principal and scopes, and
requires a CSRF-protected login POST. Production configuration rejects the
flag:

```bash
cd examples/phoenix_adk_ui
export GEMINI_API_KEY="your_api_key_here"
export ADK_UI_LOCAL_AUTH=true
mix setup
mix phx.server
```

Open `http://127.0.0.1:4000/auth/login` and click **Continue as local
developer**. No `OIDC_*` variables are required or read in this mode.

To exercise the production authentication contract during development, unset
`ADK_UI_LOCAL_AUTH` and configure an OIDC client whose callback exactly matches
the value below:

```bash
cd examples/phoenix_adk_ui
export GEMINI_API_KEY="your_api_key_here"
export OIDC_ISSUER="https://identity.example.com"
export OIDC_CLIENT_ID="erlang-adk-ui"
export OIDC_CLIENT_SECRET="load-this-from-your-secret-manager"
export OIDC_REDIRECT_URI="http://127.0.0.1:4000/auth/callback"
export OIDC_SCOPES="openid adk.agents.read adk.run.start adk.run.read adk.run.control adk.live.read adk.live.control adk.observability.read adk.evaluation.read"
mix setup
mix phx.server
```

Open `http://127.0.0.1:4000/auth/login`. A public OIDC client may set
`OIDC_PUBLIC_CLIENT=true` instead of exporting a client secret; S256 PKCE
remains mandatory. `OIDC_SIGNING_ALGS` defaults to `RS256`. The identity
provider must actually grant the configured ADK scopes—changing a browser form
or cookie cannot add them.

The browser cookie contains only Phoenix's encrypted session and opaque random
handles. The nonce, verifier, provider exchange data, and sanitized identity
remain in bounded, expiring server-side stores. The high-entropy OAuth state is
also sent through the browser/IdP redirect and is atomically consumed before
code exchange; it is not treated as a secret. Browser sessions rotate at login,
logout revokes the
server entry, and callback replay fails closed. The default production boundary
uses external OIDC; the Erlang core deliberately does not store passwords. A
deployment that needs local accounts may replace the auth provider with
Phoenix-generated authentication and a maintained password hasher, while
keeping the same issuer-bound identity and gateway policy contract.

Every connected mount and browser event re-fetches the server session and calls
the default-deny Erlang gateway. Final output and replay-gap handling also
re-check session validity and run ownership before rendering. The gateway:

- derives the ADK user and opaque owner scope from the validated issuer and
  subject;
- resolves agents from an immutable server-owned catalog;
- requires exact scopes for list, start, observe, control, and resume;
- makes cross-owner and unknown runs indistinguishable;
- preserves owner scope when a paused run is resumed.

A LiveView owns only a credit/ack subscription. The stable run is independently
supervised, survives browser disconnects, and reconnects from the last
acknowledged sequence stored in the server-side session. Rendered events,
encoded bytes, prompts, outputs, login flows, sessions, and reconnect state are
bounded. Confirmation and human-approval responses are typed; an unknown pause
type remains paused and displays no action buttons.

The Live operations view uses a different future-only subscription contract.
The Live session remains server-owned, but browser disconnect deliberately
does not store a cursor or request replay. Each mount/action/event re-fetches
the server-side OIDC session and requires exact scopes:

- `adk.live.read` for discovery, attach/detach, credit acknowledgements, and
  opening the owner-bound voice bridge;
- `adk.live.control` for realtime text and voice input; each voice frame is
  authorized again with both Live scopes;
- `adk.observability.read` for the bounded metadata-only metrics/delivery
  snapshot;
- `adk.evaluation.read` for server-configured report rendering/comparison.

Audio/video bytes and thought signatures are removed before an event enters
LiveView assigns; audio is shown there only as format/rate/channel/byte-count
metadata. Full-duplex voice uses a separate same-origin, binary-only WebSocket
and one ephemeral Erlang bridge process per connection. Browser microphone
audio is resampled in an AudioWorklet to mono PCM s16le at 16 kHz; model PCM is
scheduled through Web Audio with a bounded queue. Exact binary event ACKs hold
the ADK credit window, and an interruption immediately purges scheduled audio.
The socket re-fetches the opaque server session on every inbound, outbound,
ping, and pong frame and on a bounded server-driven timer, rejects absent or
cross-origin handshakes, and never exposes its bridge
reference, principal, model, transport, or API key.
Trusted discovery exposes a bounded `voice_mode`; controls appear only for an
`active` automatic-VAD session, and the WebSocket rechecks both conditions to
close the refresh/open race. Device-rate input passes through a streaming
anti-alias resampler, worklet/main-thread, outbound socket, and playback queues
are bounded, and a late microphone permission grant is stopped if its
connection generation was cancelled. Final transcripts use a dedicated polite
announcement region without making interim transcription updates noisy.
Reports come from the trusted `:erlang_adk_ui, :evaluation_reports` release
catalog as already decoded maps. The browser can select only an ID returned by
that catalog; it cannot provide a filesystem path or evaluator module. The
node-local reference gateway is suitable for a same-BEAM release. A clustered
deployment needs an authenticated distributed session router rather than a
client-selected node or PID.

Run the companion's deterministic and release gates from its directory:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix assets.test
mix test
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
mix hex.audit
```

The first six commands must pass. At the current lock, `mix hex.audit`
intentionally exits non-zero for the two Cowlib 2.18.0 advisories documented in
the companion README. That output is a visible release exception to resolve on
an official fixed dependency, not a passing gate and not a reason to disable
TLS verification or the audit. As of 2026-07-15, Cowlib 2.18.0 is still the
latest official release and neither EEF advisory has a fixed-version event, so
there is no safe official dependency bump yet.

The v0.6 companion baseline passed all 46 tests, production asset compilation,
and release assembly. Its packaged release also booted with test-only
trusted-proxy and direct-TLS configurations, returned HTTP 200 from `/health`
on loopback in both modes, and stopped cleanly. The expanded v0.7 companion
gate passes 101 ExUnit tests plus 31 dependency-free browser-audio tests with
format, warnings-as-errors compilation, production assets, and release
assembly. Its packaged release boots in both trusted-proxy
and direct-TLS modes, returns HTTP 200 from `/health` on loopback with
certificate verification enabled, and stops cleanly.

The lock file pins the official Phoenix LiveView fix commit for
CVE-2026-58228 until a fixed Hex release at or above 1.2.7 is available. Do not
replace that pin with an affected range merely to silence an audit. Keep
`mix.lock` in version control.

For a direct-TLS release, export the OIDC values above with an HTTPS callback,
then set `SECRET_KEY_BASE`, `PHX_HOST`, `TLS_CERT_PATH`, and
`TLS_KEY_PATH` before starting the release:

```bash
export PHX_SERVER=true
export PHX_HOST="agents.example.com"
export PORT=8443
export PHX_URL_PORT=8443
export SECRET_KEY_BASE="$(mix phx.gen.secret)"
export OIDC_REDIRECT_URI="https://agents.example.com:8443/auth/callback"
export TLS_CERT_PATH="/run/secrets/tls-cert.pem"
export TLS_KEY_PATH="/run/secrets/tls-key.pem"
_build/prod/rel/erlang_adk_ui/bin/erlang_adk_ui start
```

Alternatively set `PHX_BEHIND_HTTPS_PROXY=true` and omit the certificate
paths only when the HTTP listener is network-reachable exclusively through a
trusted TLS terminator. Phoenix's forwarded-protocol rewrite is an explicit
proxy trust decision: the proxy must overwrite `X-Forwarded-Host`,
`X-Forwarded-Port`, and `X-Forwarded-Proto`, and forwarded headers from
arbitrary clients are not a TLS boundary. Production configuration enforces
secure/HttpOnly/SameSite cookies, connection-exact LiveView scheme/host/port,
CSRF, CSP, HSTS, body limits, and a bounded channel implementation.

The production companion covers authenticated agent execution, typed
decisions, future-only Live text/metadata, authenticated bounded browser voice,
content-free operational snapshots, and read-only evaluation reports. It does
not start/configure Live sessions, capture video, run evaluations from browser
input, or mutate observability configuration. Artifact, memory, context,
approver, operator, or admin panels require separate exact-scope server-side
gateway operations; never give the browser a service PID, credential
reference, filesystem root, cache lease, provider resource name, evaluator
module/path, or caller-selected app/user scope. The Erlang `/dev` console
remains loopback-only single-operator tooling and must not be mounted behind
this public endpoint.

See the [Phoenix companion guide](examples/phoenix_adk_ui/README.md) for
configuration, topology, testing, and release details.

## Verification

Run the complete deterministic test and developer-tooling packaging gates with
the repository's bundled Rebar3:

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
./scripts/coverage.sh
./rebar3 xref
./rebar3 escriptize
_build/default/bin/adk doctor
_build/default/bin/adk config validate examples/agent.json
./rebar3 ex_doc
./rebar3 hex build
./scripts/verify_hex_package.sh
```

For v0.7, `adk doctor` must report version `0.7.0`, OTP 27,
`gemini-3.1-flash-lite` as the REST default, all required dependencies, and a
configured Gemini key without exposing it; checked validation must accept
`examples/agent.json` with the same REST model. Live examples select
`gemini-3.1-flash-live-preview` explicitly and do not change that default.

For historical comparison, the final v0.6 2026-07-14 clean run passed 899
EUnit tests, six deterministic Common Test cases, and warning-free Dialyzer
over 170 project files. The v0.7 results below supersede that baseline.

The final v0.7 2026-07-16 clean Erlang gate completed 1,176 EUnit tests with
no failures, six deterministic Common Test cases, and warning-free Dialyzer
analysis over 210 project files. Aggregate deterministic Erlang line coverage
is 73.88%, above the enforced 73% floor. Escript packaging, `adk doctor`,
checked agent-config validation, and the focused README/runtime gates also
pass.

Run the focused deterministic README smoke suite with:

```bash
./rebar3 eunit --module=readme_examples_test
./rebar3 eunit --module=readme_workflow_examples_test
erlc -Werror -pa _build/default/lib/erlang_adk/ebin -o /tmp \
  examples/readme_weather_tool.erl \
  examples/readme_live_weather_executor.erl \
  examples/readme_stateful_counter_plugin.erl
./rebar3 eunit \
  --module=adk_live_media_test,adk_live_gemini_codec_test,adk_live_gun_transport_test,adk_live_public_api_test,adk_live_session_test,adk_live_tool_execution_test,adk_live_observability_test,adk_live_voice_protocol_test,adk_live_voice_bridge_test,adk_plugin_pipeline_test,adk_plugin_runner_integration_test,adk_plugin_builtin_test,adk_plugin_stateful_test,adk_trace_context_test,adk_observability_v2_test,adk_observability_runner_test,adk_otlp_json_test,adk_otlp_http_json_exporter_test,adk_eval_criteria_test,adk_eval_v2_test,adk_eval_llm_judge_test,adk_eval_dev_view_test,adk_dev_v07_http_test,adk_cli_test
./rebar3 ct --suite test/runtime/invocations/adk_concurrency_stress_SUITE.erl
./rebar3 ct --suite test/integrations/stress/adk_v05_stress_SUITE.erl
```

The concurrency stress suite executes 1,000 stable runs in bounded concurrent batches
across lightweight agent processes. It verifies every response against its
exact session and invocation, unique run IDs, supervisor cleanup, and a stable
test-process mailbox.

The 0.5 stress suite separately executes 1,000 bounded artifact/memory writes
across isolated scopes and 128 concurrent context-cache acquisitions across
four exact scopes; the latter collapse to four provider creates/deletes.
The focused v0.6 run passed all 29 README examples, all four workflow examples,
the 1,000-run concurrency scenario, and both v0.5 resource/context stress
scenarios.
On v0.7, the 29 README tests, four workflow tests, all three new example-module
compile/runtime checks, and 193 focused Live/plugin/observability/evaluation/
developer-tooling tests pass. Both 1,000-run stress suites also pass in the
final clean Common Test gate.

Run the opt-in billable REST provider suite after exporting `GEMINI_API_KEY`
with:

```bash
ERLANG_ADK_GEMINI_REST=1 ./rebar3 ct \
  --suite test/readme/readme_live_gemini_SUITE.erl
```

Despite its historical filename,
`readme_live_gemini_SUITE` uses REST GenerateContent/SSE with
`gemini-3.1-flash-lite`; it is not a Gemini Live WebSocket test. It exercises
text generation,
Google Search grounding metadata, thinking configuration, multimodal
one-shot/content streaming, explicit context-cache creation and reuse,
exact-scope model-selected memory and one-request artifact attachment,
strict JSON Schema function declarations, function calling, SSE text
streaming, correlated delegation, concurrent orchestration,
sub-agents, Runner provider streaming, continuation-specific human approval,
Mnesia Runner storage, callbacks, telemetry, evaluation, and the HTTP
endpoint. It is skipped unless explicitly enabled because it uses network
access, quota, and billable API calls.

The final v0.7 2026-07-15 REST run passed 15 of 17 cases with no skips.
`google_search_grounding` and `context_cache` each received HTTP 429 after the
single bounded ten-second retry. They are recorded as quota/rate-limit
failures, not implementation passes; the exact-scope artifact/memory case and
its strict `parametersJsonSchema` tool projection passed. The first-party
bounded LLM rubric judge also passed against `gemini-3.1-flash-lite`.

Some scenarios require multiple model turns, so the complete REST suite makes
roughly 39 Gemini API requests, including Search grounding, cached-content
creation and reuse, model-selected memory/artifact tool rounds, and one-shot
and SSE multimodal requests. By default, its
test-only provider wrapper spaces request
starts by 4.2 seconds, caps each transport wait at 15 seconds, and retries one
non-streaming transport timeout. A non-streaming HTTP 429 receives one bounded
retry after a test-only backoff of at least 10 seconds; a second 429 fails the
case explicitly. The suite raises its agent call and direct-turn worker
timeouts to 120 seconds; both production defaults remain 60 seconds. This
pacing and retry policy do not change production request scheduling or the
Erlang concurrency model. API limits are project-specific; accounts with a
higher limit can shorten or disable the test pacing, for example:

```bash
ERLANG_ADK_GEMINI_REST=1 \
ERLANG_ADK_GEMINI_REST_INTERVAL_MS=0 \
./rebar3 ct --suite test/readme/readme_live_gemini_SUITE.erl
```

Keep the default interval on free-tier projects. Exhausted daily quota,
project traffic outside this suite, or persistent account-level limits still
fail explicitly instead of looping indefinitely.

`ERLANG_ADK_LIVE_GEMINI=1` and
`ERLANG_ADK_LIVE_GEMINI_INTERVAL_MS` remain accepted as historical aliases;
new scripts should use the unambiguous `ERLANG_ADK_GEMINI_REST` names above.

The actual Gemini Live WebSocket gate is a separate opt-in paid suite using
the explicit Live preview model:

```bash
ERLANG_ADK_GEMINI_LIVE=1 ./rebar3 ct \
  --suite test/models/gemini/gemini_live_SUITE.erl
```

`gemini_live_SUITE` covers text-to-audio plus output transcription, 16 kHz
PCM audio input, PNG image input, a correlated synchronous function-call
round trip, and the owner-bound browser framing/ACK bridge against the real
provider. It requires network/quota access and is skipped unless both the
flag and `GEMINI_API_KEY` reach the Common Test process. Deterministic Live
media/codec/session/transport/tool/observability tests remain the release
contract even when this paid provider gate is skipped; a provider or quota
failure is never counted as an implementation pass.

On 2026-07-15, the complete paid Live suite passed all five cases
against `gemini-3.1-flash-live-preview`. This is provider-integration evidence,
not a substitute for the clean deterministic release gate.

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

## License

Erlang ADK is available under the [Apache License 2.0](LICENSE.md).
