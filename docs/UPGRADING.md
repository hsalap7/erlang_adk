# Upgrading Erlang ADK

Version 0.8.0 is cumulative. This guide highlights behavior and deployment
changes introduced by the 0.3-0.8 delivery milestones; it is not a substitute
for the exact contracts in the version documents.

## Before upgrading

1. Read [`FEATURE_PARITY.md`](FEATURE_PARITY.md) and the contracts for every
   milestone being crossed. “Partial” and adapter-owned behavior is not made
   complete by a version bump.
2. Back up deployment-owned Mnesia/session, artifact, memory, evaluation, and
   credential stores. Test restoration and erasure policy in staging.
3. Preserve `rebar.lock` and, for the Phoenix companion, `mix.lock`. Review the
   dependency exceptions in [`SECURITY.md`](../SECURITY.md).
4. Run the complete deterministic and packaging gates before and after the
   upgrade. Run paid provider gates if provider behavior is in scope.
5. Test cancellation, reconnect, continuation, auth expiry, restart, and
   cross-principal isolation with the deployment's adapters and topology.

There is no general automatic schema-migration promise for arbitrary
application session tables or custom adapters. Node-local web sessions, run
lookup, A2A tasks, and Live discovery also do not gain transparent horizontal
failover in 0.8. Model profiles are also node-local application configuration,
not a distributed registry. Stage any persistent-data, profile rollout, or
multi-node change explicitly.

## Moving to 0.3.0: supervised runtime foundation

- Treat an agent process as an immutable reusable specification and admission
  point. Invocation work runs in separately supervised processes with stable
  IDs, deadlines, budgets, cancellation, events, and one terminal result.
- Enable listeners and persistent services explicitly. The developer API,
  A2A/MCP listeners, Mnesia, and other services are not ambient production
  defaults.
- Consume versioned JSON-safe events rather than internal Erlang records or
  process state.
- Scope continuations and temporary state to an invocation. Do not use browser
  or caller process lifetime as run ownership.
- Configure bounded admission and decide whether overload rejects or enters a
  bounded FIFO queue.

## 0.3.0 to 0.4.0: agents, tools, and workflows

- Distinguish legacy direct turns from fresh invocations. `prompt` and legacy
  `delegate` retain one stateful FIFO compatibility history; Runner and
  explicit invocation/delegated execution use fresh invocation history and
  exact-session lanes.
- Ensure model-visible agent names match `[A-Za-z_][A-Za-z0-9_]*`, avoid the
  reserved `user` name, and construct a true bounded tree: no duplicate
  names, cycles, multiple parents, or unavailable children.
- Compile and validate tool catalogs before provider calls. New dynamic tools
  are invisible until an explicit catalog refresh, and a running agent does
  not automatically swap its catalog.
- Treat model tool arguments as untrusted. Schema, policy, confirmation, and
  credential checks occur before callbacks or side effects.
- Review workflow pause/resume shapes. Top-level sequential/graph/fork paths
  have checkpoint behavior, but nested pauses in parallel branches, loop
  bodies, and transfer members remain limited.

## 0.4.0 to 0.5.0: artifacts, memory, and context

- Supply exact app/user/session or app/user scopes to artifact, memory, and
  context operations. Cross-scope results fail closed rather than being
  silently filtered into a caller's view.
- Move large artifact bytes through deployment-owned bounded adapters. Do not
  put raw multi-megabyte blobs into session history, state, events, or a
  global coordinator mailbox.
- Choose durable adapters and ownership policy explicitly. ETS reference
  implementations are volatile; local Mnesia/filesystem behavior does not
  imply a managed object/vector store, encryption at rest, or distributed
  failover.
- Expect mandatory model-boundary sanitation and complete-request budgeting.
  Tool exchanges remain paired and the current input is not discarded to fit
  a budget.
- Treat context caching as provider prefix/resource reuse, not response
  caching. Cache identities include provider/model/policy/scope information
  and must not expose private provider resource names.
- If enabling exact-scope sharded adapters, size shard admission and storage
  limits for the deployment. Limits are per shard; no global quota is implied.

## 0.5.0 to 0.6.0: authentication, protocols, and Phoenix

- Separate authentication from authorization. A valid token produces an
  issuer-bound identity; a default-deny authorizer must grant each exact
  operation/resource.
- Replace caller-selected provider modules/context with immutable, trusted
  provider profiles and opaque credential references. Use production secret
  storage rather than treating ETS as encrypted durable credential storage.
- For interactive authorization, use the supervised authorization-code flow
  with exact redirects, S256 PKCE, nonce/state, bounded expiry, atomic replay
  claim, and subject binding.
- Update MCP integrations to the supported 2025-11-25 Streamable HTTP
  contract and bind protocol sessions to the authenticated principal.
- Update A2A integrations to the A2A 1.0 JSON-RPC endpoint and send
  `A2A-Version: 1.0`. The legacy `/a2a/prompt` endpoint is not wire-compatible
  and should not be exposed as a production A2A API.
- Keep `/dev` loopback/private and single-operator. Its bearer token is not an
  end-user identity or tool/model credential.
- The Phoenix companion is a same-BEAM BFF. Configure exact OIDC issuer,
  client, callback, scopes, cookie/TLS secrets, and an immutable agent
  catalog; the browser must not select modules, providers, app/user scopes,
  paths, or service PIDs.
- Plan for node locality or sticky routing across the complete login,
  web-session, run, and Live lifetime.

## 0.6.0 to 0.7.0: Live, plugins, evaluation, and observability

### Gemini model separation

Ordinary agents and REST GenerateContent/SSE use:

```erlang
#{provider => adk_llm_gemini,
  model => <<"gemini-3.1-flash-lite">>}
```

Gemini Live is a different WebSocket protocol and uses:

```erlang
#{model => <<"gemini-3.1-flash-live-preview">>}
```

A REST model is rejected by the Live provider. Update automation to use
`ERLANG_ADK_GEMINI_REST=1` for the historical REST suite and
`ERLANG_ADK_GEMINI_LIVE=1` for the Live suite. Historical
`ERLANG_ADK_LIVE_GEMINI` names remain REST-suite compatibility aliases.

### Live sessions and browser voice

- Create and close Live sessions explicitly. Subscribe before waiting for
  readiness, grant bounded credit, and acknowledge each delivered event.
- Subscribers receive future events only. Reconnect may resume provider
  context but does not replay arbitrary media, input, output, or tool side
  effects.
- Use 16 kHz mono PCM s16le for microphone input and expect 24 kHz mono PCM
  s16le model output. Image input is bounded JPEG or PNG.
- Automatic Live tool execution remains off unless trusted application code
  configures an executor, declaration allowlist, scheduling policy, deadline,
  heap bound, and response bound.
- The core supplies an owner-bound voice bridge, not microphone capture or
  playback. The Phoenix reference uses AudioWorklet/Web Audio, exact binary
  acknowledgement, interruption purge, and a same-origin authenticated
  socket.

### Plugins

- Prefer explicit `amend` to continue with a modified value and explicit
  `return` for early completion. The compatibility `{replace, Value}` form is
  an early return, not an amendment.
- Stateful plugin callbacks serialize per instance. Use independent instances
  for plugin-level concurrency; a crashed instance is unavailable rather than
  silently restarted with empty state under a stale PID.
- Revalidate schema, policy, and confirmation after tool-argument amendments.
  Dynamic catalog tools are therefore not amendable in 0.7.

### Evaluation

- Move CI work to versioned eval sets/results and `adk eval run` where useful.
  Exit 0 means pass, exit 2 means a completed evaluation that failed its
  thresholds, and exit 1 means configuration/runtime failure.
- Deterministic criteria remain the reproducible default. The Gemini rubric
  judge is explicit, billable, bounded, and defaults to
  `gemini-3.1-flash-lite`; judge errors count as errors, never passing scores.
- Protect reports as evaluated content. They can contain bounded rationale
  even though provider credentials and raw provider errors are removed.

### Observability

- Adopt v2 operation spans and strict W3C `traceparent`/`tracestate` helpers.
  Automatic propagation through every older MCP, A2A, workflow, task, or
  Phoenix boundary is not claimed.
- Keep content capture off by default. GenAI attributes, metrics, and the
  native OTLP/HTTP JSON exporter exclude prompts, responses, media,
  transcripts, tool arguments/results, credentials, and provider handles.
- The asynchronous bus is bounded best effort, not a durable WAL. Retries can
  duplicate delivery; exhausted work is dropped and counted.

### A2A and Phoenix corrections

- Agent Card `version` now defaults to the loaded `erlang_adk` application
  version instead of a hard-coded 0.6 value. An explicitly configured card
  version still takes precedence. Do not confuse it with the A2A
  `protocolVersion`, which remains `1.0`.
- The explicit Phoenix local identity now works without any `OIDC_*`
  variables, but only in development on exact IPv4 loopback. Login remains a
  CSRF-protected POST and the server owns its principal and scopes.
- Update Phoenix assets and hooks together. The 0.7 browser voice path depends
  on the checked AudioWorklet/resampler, continuous bounded playback, exact
  ACK timing, interruption cleanup, styles, and packaged favicon.

## 0.7.0 to 0.8.0: model profiles, vendors, and Realtime

### Move public model selection to binary profiles

Direct module configuration remains compatible for trusted Erlang code:

```erlang
#{provider => adk_llm_gemini,
  model => <<"gemini-3.1-flash-lite">>}
```

For browser-, tenant-, file-, or API-selected configuration, define an
operator-owned `provider_profiles` entry and expose only aliases:

```erlang
ok = application:set_env(
    erlang_adk, provider_profiles,
    #{<<"openai-prod">> =>
          #{request_adapter => adk_llm_openai,
            endpoint => openai,
            models => #{<<"fast">> => <<"gpt-5-mini">>},
            credential => {env, "OPENAI_API_KEY"},
            request_options => #{store => false}}}),

PublicConfig = #{provider => <<"openai-prod">>,
                 model => <<"fast">>,
                 temperature => 0.2}.
```

Do not translate a public provider string to an atom. Do not merge public maps
over profiles. Profile callers cannot replace concrete model IDs, endpoints,
credentials, arbitrary headers, API versions, auth/storage/billing settings,
transports, or Live audio rates. Review the full schema in
[`PROVIDER_PROFILES.md`](PROVIDER_PROFILES.md).

Validate the complete registry at startup:

```erlang
{ok, _CheckedProfiles} = adk_provider_registry:profiles().
```

Profile selection and credential lookup are generation-consistent. If a
profile changes between those operations, the request fails with
`provider_profile_changed`. Deploy profile authority and its credential source
as one change rather than relying on a partially updated in-memory map.

### Choose the protocol-specific request adapter

- Use `adk_llm_openai` for the native OpenAI Responses API, not Chat
  Completions.
- Use `adk_llm_anthropic` for the native Anthropic Messages API and keep
  `anthropic_version` operator-owned. `max_tokens` must be at least one.
- Use `adk_llm_compatible` only for the documented Chat Completions subset at
  a trusted structured HTTPS endpoint. Lock `auth_scheme` to `bearer`,
  `x_api_key`, or `none`, and set `response_format => unsupported` in trusted
  configuration when the endpoint does not implement structured output.
- Continue using `adk_llm_gemini` for Gemini REST GenerateContent/SSE.

OpenAI and Anthropic direct legacy adapters read their conventional ambient
key only at the exact official base URL. Custom origins require an explicit
profile credential. The compatible adapter never guesses that a process-wide
key belongs to a custom origin. If an older compatible integration relied on
`OPENAI_COMPATIBLE_API_KEY` without an explicit key/profile, move it to
`credential => {env, "OPENAI_COMPATIBLE_API_KEY"}` in a trusted profile.

Both synchronous and streaming model Gun paths now reject any aggregate
response-header or trailer block above 64 KiB. Custom transports should apply
an equivalent bound before admitting provider metadata.

Provider-specific tool, content, finish-reason, structured-output, and stream
semantics remain distinct. Test the exact configured model/endpoint; a working
OpenAI profile is not evidence for Anthropic or an arbitrary compatible
vendor, and deterministic codec fixtures are not paid-provider evidence.

### Add OpenAI Realtime without changing Live ownership

OpenAI Realtime uses the existing explicit server-owned Live lifecycle:

```erlang
#{provider => <<"openai-live">>,
  provider_config =>
      #{model => <<"voice">>,
        response_modalities => [audio],
        automatic_activity_detection => true}}
```

The matching trusted profile supplies `live_adapter => adk_live_openai`, the
`openai` endpoint preset, concrete Realtime model ID, and credential. Profile
callers cannot inject a WebSocket transport or origin. The bundled transport
is fixed to verified TLS at the official OpenAI origin.

One logical action may now produce multiple ordered provider frames. Admission
is atomic for that frame batch, so concurrent callers cannot interleave the
item-creation and response-request halves. Once transmission begins, even a
later priority action waits until that in-flight frame batch is complete. If a
custom Live provider is updated to use this contract, return `{ok, Frame}` or
`{ok, [Frame, ...]}`; return `ignored` only for a deliberate provider no-op.
Existing single-frame providers remain compatible.

OpenAI manual turn detection commits on `activity_end`. `audio_stream_end` is
a no-op because the Phoenix/browser lifecycle emits it after capture stops;
committing there as well would request a duplicate empty response. In server
VAD mode the provider owns commits.

### Negotiate voice input rate

Do not hard-code 16 kHz in a generic browser/voice adapter. Live status now
reports a trusted `input_audio_sample_rate`:

- Gemini Live: 16 kHz PCM s16le mono input;
- OpenAI Realtime: 24 kHz PCM s16le mono input; and
- both bundled paths currently expose native 24 kHz PCM audio output events.

The owner-bound bridge sends an unsequenced server configuration frame before
accepting client audio. Update custom socket clients to wait for that frame,
initialize their resampler with its rate, and never ACK it. Sequence/credit
ACKs still apply only to subsequent sequenced provider events. The rate is
derived from trusted provider capabilities inside the Live session; remove any
caller-supplied sample-rate override.

## Post-upgrade validation

Run every gate in [`TESTING.md`](TESTING.md) that applies to the deployment.
Specifically verify:

- no cross-user/session/run/Live visibility;
- exact OIDC callbacks, audiences, algorithms, scopes, and session rotation;
- binary profile/model selection, generation changes, missing credentials,
  and caller authority-override rejection;
- provider-native content, tools, structured output, streaming, and sanitized
  failure behavior for every configured endpoint;
- Anthropic `max_tokens >= 1` and 64 KiB synchronous/streaming Gun
  header/trailer rejection;
- OpenAI Realtime 24 kHz and Gemini Live 16 kHz input negotiation, manual/VAD
  turn completion, contiguous multi-frame priority ordering, and interruption
  cleanup;
- provider model/config selection and explicit paid-test flags;
- continuation and Live reconnect behavior under process/network loss;
- browser microphone permission cancellation, audio backpressure, and
  interruption cleanup;
- persistent adapter compatibility and restore/erasure behavior; and
- the still-visible Cowlib audit exception before exposing Phoenix.
