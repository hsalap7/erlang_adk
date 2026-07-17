# Erlang ADK 0.8.0 release contract

> **Status:** release candidate validated on 2026-07-17. The complete
> deterministic Erlang, coverage, documentation/package, and Phoenix gates
> passed. The opt-in Gemini REST attempt reached Google but the configured
> credential shape was rejected; no paid Gemini Live pass is recorded. This is
> external provider evidence, not a pass, skip, or product regression. This
> does not claim that `v0.8.0`
> or a Hex package has been published.

Version 0.8 focuses on **operator-owned model provider profiles, native
OpenAI and Anthropic request adapters, an explicit OpenAI-compatible adapter,
and OpenAI Realtime bidirectional sessions**. It extends the 0.7 Live runtime
without replacing its Erlang-native ownership, supervision, concurrency, and
backpressure contracts.

Primary wire references are the
[OpenAI Responses API](https://platform.openai.com/docs/api-reference/responses),
[OpenAI Realtime WebSocket guide](https://developers.openai.com/api/docs/guides/realtime-websocket),
[Anthropic Messages API](https://platform.claude.com/docs/en/api/messages/create),
[Anthropic streaming guide](https://platform.claude.com/docs/en/build-with-claude/streaming),
and each explicitly configured vendor's documented OpenAI-compatible Chat
Completions contract.

## Architectural decisions

1. **Binary aliases select trusted profiles.** Public configuration selects a
   bounded binary profile ID and binary model alias. Only operator
   configuration contains adapter atoms, concrete model IDs, endpoints,
   credentials, API versions, authentication schemes, or storage/billing
   headers.
2. **Adapters are native where semantics differ.** OpenAI uses Responses,
   Anthropic uses Messages, and compatible vendors use a separate narrow Chat
   Completions adapter. The implementation does not pretend these protocols
   have identical content, tool, streaming, or error semantics.
3. **Capabilities can narrow implementation, not invent it.** Provider/model
   profile metadata is secret-free and bounded. Adapter behavior is the
   implementation ceiling; a profile is not evidence that a remote model or
   compatible deployment supports a feature.
4. **Credential and authority selection are generation-consistent.** A
   keyed snapshot binds the selected adapter/endpoint/model profile to the
   credential lookup. Concurrent profile replacement fails closed rather than
   mixing generations.
5. **Model HTTP is bounded and origin-locked.** Adapter-owned operation paths,
   exact scheme/host policy, verified TLS, bounded DNS resolution, no
   redirects, response/request/deadline limits, and streaming flow control are
   shared across new request providers.
6. **Bidirectional remains one lightweight process per session.** OpenAI
   Realtime uses the same supervised Live session, principal checks, bounded
   ingress, multi-subscriber credit, tool execution boundary, and voice bridge
   as Gemini Live; its wire codec and fixed transport remain provider-owned.
7. **Audio format is negotiated from trusted status.** Gemini accepts 16 kHz
   PCM s16le mono input and OpenAI Realtime accepts 24 kHz. The voice bridge
   announces the trusted provider rate before accepting audio; a caller cannot
   override it.

## Implemented release-candidate scope

### A. Profiles, credentials, and capabilities

- [x] Add a bounded `provider_profiles` application registry with binary
  profile/model aliases and no untrusted atom creation.
- [x] Validate known request/Live adapters, endpoint presets, structured HTTPS
  endpoints, model maps, secret-free capability metadata, and adapter-specific
  operator request options.
- [x] Resolve credentials from strict environment names, application
  environment, trusted literals, or `none`, while redacting public profile
  projections and errors.
- [x] Bind profile authority to credential lookup with an opaque per-runtime
  keyed snapshot and fail on a changed generation.
- [x] Preserve direct atom-module provider configuration as an explicit
  trusted-code compatibility path.
- [x] Reject caller attempts to replace model IDs, endpoints, credentials,
  transports, headers, API versions, auth schemes, storage/billing settings,
  or Live audio rates. Allow only adapter-specific inference/runtime settings.

The complete schema and examples are in
[`PROVIDER_PROFILES.md`](PROVIDER_PROFILES.md).

### B. Shared bounded request transport

- [x] Add provider-neutral JSON request construction with adapter-owned fixed
  paths, exact host/scheme policy, redirects disabled, bounded bodies and
  headers, and injectable deterministic transports.
- [x] Add a Gun request/stream implementation with TLS peer and hostname
  verification, private-address rejection by default, deadline-bounded DNS,
  direct connection to the checked address, explicit flow control, and a
  64 KiB aggregate cap for each header or trailer block in synchronous and
  streaming paths.
- [x] Add an incremental bounded SSE decoder that handles arbitrary chunk
  boundaries, CR/LF variants, explicit empty data, event IDs, and completion
  without building an unbounded global line list.
- [x] Prevent ambient native-vendor keys from reaching custom origins. OpenAI
  and Anthropic environment keys are bound to their exact official base URLs;
  custom origins and all authenticated compatible endpoints require an
  explicitly materialized profile credential.

### C. Native OpenAI Responses

- [x] Add `adk_llm_openai` with one-shot Responses requests and incremental
  SSE streaming.
- [x] Translate canonical bounded history for text and inline/referenced image
  content, function calls, and function results without exposing raw
  configuration as a wire-map escape hatch.
- [x] Preserve function call IDs and parallel calls; expose canonical
  text/function outcomes and provider metadata.
- [x] Support checked structured JSON output and operator-locked organization,
  project, and `store` settings.
- [x] Sanitize provider/API/transport failures so credentials, request content,
  and unbounded response bodies do not enter public error terms.

This adapter does not implement Chat Completions or OpenAI Realtime; those are
separate contracts below.

### D. Native Anthropic Messages

- [x] Add `adk_llm_anthropic` with one-shot Messages requests and incremental
  Anthropic SSE lifecycle decoding.
- [x] Translate bounded canonical text and inline/referenced image content,
  tool-use blocks, tool results, parallel blocks, and role/history semantics.
- [x] Lock `anthropic-version` in operator configuration and use the native
  `x-api-key` header.
- [x] Support structured JSON output through the GA
  `output_config.format` shape derived from the existing ADK output schema.
- [x] Reject invalid event ordering/content blocks and reduce remote error
  values to bounded structural reasons.
- [x] Validate Anthropic `max_tokens` with a minimum of one in direct and
  profile-selected requests.

PDF/document blocks, prompt caching, citations, extended thinking, computer
use, and provider-specific beta headers are not claimed by this adapter.

### E. OpenAI-compatible Chat Completions

- [x] Add `adk_llm_compatible` for an operator-selected structured HTTPS base
  URL and the adapter-owned `/chat/completions` path.
- [x] Support `bearer`, `x_api_key`, or `none` authentication, with the scheme
  locked by the profile and no caller-injected headers.
- [x] Add bounded one-shot and incremental SSE text/tool handling, canonical
  content translation, optional usage, tool choices, and explicitly gated
  response formats.
- [x] Allow a profile to disable structured output for deployments that do not
  implement it.

“OpenAI-compatible” is deliberately partial: vendors differ on multimodal
parts, tool-call streaming, finish reasons, usage, token fields, structured
output, and error envelopes. The adapter accepts only its documented subset;
each target endpoint still needs provider-specific integration evidence.

### F. OpenAI Realtime and bidirectional Live

- [x] Add `adk_live_openai` and a strict GA Realtime event codec for session
  setup, text/audio/image input, text/audio output, transcription, function
  calls/results, interruption, completion, usage, rate limits, and safe errors.
- [x] Add a fixed `api.openai.com` verified-TLS Gun WebSocket transport with
  credential-broker handoff, bounded frames, deadlines, no redirects, and
  socket-credit replenishment only after decode/admission.
- [x] Allow one client action to emit multiple ordered provider frames and
  atomically admit that frame batch without interleaving with another caller;
  once sending begins, a later priority action cannot splice into the batch.
- [x] Treat browser audio-stream closure as a no-op for OpenAI. Server VAD owns
  automatic commits; manual `activity_end` performs exactly one commit and
  response request.
- [x] Publish trusted `input_audio_sample_rate` in Live status and negotiate
  16/24 kHz browser capture through the owner-bound voice bridge and Phoenix
  companion.
- [x] Keep credential, module, endpoint, model ID, transport, billing headers,
  and sample rate out of public Live profile overrides.

OpenAI Realtime session resumption is not claimed. Browser WebRTC negotiation,
ephemeral client tokens, direct browser-to-provider credentials, and durable
or multi-node Live routing remain application/provider adapters. Live
subscribers still receive future events only; media and side effects are not
replayed.

### G. Developer, documentation, and packaging integration

- [x] Extend `adk doctor` with native OpenAI/Anthropic/compatible availability
  and key-presence checks; extend configuration validation to recognize those
  adapters and binary profiles without exposing keys.
- [x] Keep new source/test modules under provider, transport, profile, and
  credential ownership directories rather than returning to a flat `src` or
  `test` layout.
- [x] Update the Phoenix voice path to wait for the server format frame and
  resample browser capture to the negotiated 16 or 24 kHz input rate.
- [x] Add deterministic request, content, stream, HTTP/SSE, profile,
  credential, Realtime codec/transport, multi-frame session, and voice
  negotiation tests.
- [x] Record the final complete deterministic Erlang gate and updated line
  coverage.
- [x] Record the final Phoenix/Node/assets/release gate.
- [x] Record the ExDoc/Hex package verification gate.
- [x] Record optional paid-provider evidence separately from deterministic
  evidence. The repository currently has opt-in Gemini REST and Gemini Live
  suites; no OpenAI/Anthropic paid result is implied by codec fixtures.

## Release limitations

- There is no automatic provider routing, fallback, retry across vendors,
  cost/latency policy, or model discovery. Applications select one trusted
  profile alias per request/session.
- A compatible profile is not a blanket compatibility certification. Vendor
  deviations must be represented by bounded configuration or a dedicated
  adapter; arbitrary request/header transforms are intentionally absent.
- Model profile configuration is node-local application environment. Dynamic
  distributed rollout, persistent registry storage, KMS/HSM integration, and
  fleet-wide generation coordination are deployment concerns.
- Literal credentials are trusted configuration input, not encrypted secret
  storage. Prefer environment/application secrets populated by the deployment.
- New native request adapters do not add provider-side context caching,
  managed file upload, batch APIs, fine-tuning, assistants/threads, computer
  use, or vendor-specific search/retrieval tools.
- The existing node-local run/session/Live and Phoenix routing limitations,
  future-only Live delivery, Cowlib audit exception, and v0.7 security
  boundaries remain in force unless explicitly changed by this contract.

## Release evidence ledger

These results were recorded on 2026-07-17. Historical v0.7 counts are not used
as v0.8 evidence; command details and result interpretation are in
[`TESTING.md`](TESTING.md) and [`RELEASING.md`](RELEASING.md).

| Gate | v0.8 candidate result |
| --- | --- |
| Clean compile, EUnit, Common Test, Dialyzer | Passed: 1,414 EUnit; six deterministic Common Test cases; 22 paid cases intentionally skipped; Dialyzer analyzed 235 source modules with no warnings |
| Deterministic line coverage | Passed at 74.17% against the 74% floor; the instrumented run repeated 1,414 EUnit and six deterministic Common Test passes |
| Focused provider/profile/Realtime tests | Passed 244/244; the seven-module post-audit repair set passed 67/67; focused Gemini REST header tests passed 29/29 and Live broker/transport tests passed 19/19 |
| README and example gates | Passed 30 README plus four workflow tests (34/34); all three example modules compiled with warnings as errors |
| Xref, escript, doctor, config validation | Passed; doctor reported 0.8.0 and checked configuration validated |
| ExDoc, Hex build, extracted-package compile | Passed for the 0.8.0 artifacts and package verifier |
| Phoenix ExUnit/Node/assets/release/smoke | Passed: `mix precommit`, 103 ExUnit, 40 Node, production assets/release, and proxy/direct-TLS smokes |
| Phoenix dependency audit | Raw audit non-zero only for the two documented Cowlib advisories; exact-exception verifier passed |
| Gemini REST paid suite | Attempt reached Google but failed HTTP 401 `UNAUTHENTICATED` / `ACCESS_TOKEN_TYPE_UNSUPPORTED` because the configured credential shape was rejected; external credential failure, not a pass or product regression |
| Gemini Live paid suite | No v0.8 paid Live pass recorded; deterministic Live evidence is tracked separately |
| OpenAI Responses/Realtime paid smoke | No repository paid-suite result recorded; deterministic evidence only |
| Anthropic Messages paid smoke | No repository paid-suite result recorded; deterministic evidence only |
| Compatible vendor smoke | No endpoint-specific remote result recorded; no blanket compatibility claim |
