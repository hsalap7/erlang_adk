# Erlang ADK 0.7.0 release contract

> **Status:** completed and frozen for the v0.7.0 release on 2026-07-15.
> Checked items are release evidence; unchecked items remain explicit
> limitations and were not silently promoted to completed behavior.

Version 0.7 focuses on **multimodal and Gemini Live sessions, Runner-global
plugins, evaluation, and expanded observability**. It builds on the v0.6
authentication and production-boundary work without weakening owner,
principal, deadline, or secret-isolation guarantees.

The target is observable behavior, not a Python object-model port. Live
connections are supervised Erlang processes, independent sessions overlap,
media and subscriber flow is explicitly bounded, and a browser connection is
never allowed to own the lifetime of a model session implicitly.

Primary external contracts:

- [ADK Gemini Live toolkit](https://adk.dev/streaming/) and the
  [Gemini Live WebSocket API](https://ai.google.dev/api/live): bidirectional
  text/audio/video, tool calls, interruption, transcription, usage, GoAway,
  context compression, and session resumption;
- [ADK plugins](https://adk.dev/plugins/): ordered Runner-global lifecycle
  hooks that observe, amend, or short-circuit agent/model/tool execution before
  corresponding object-local callbacks;
- [ADK evaluation](https://adk.dev/evaluate/): versioned multi-turn datasets,
  response and trajectory/tool-use criteria, repeatable reports, and CI use;
- [ADK observability](https://adk.dev/observability/) and
  [OpenTelemetry GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/):
  correlated traces, metrics, structured events, and opt-in content capture.

## Starting point

The v0.6 release provides canonical bounded text/inline/file/function content,
REST one-shot and SSE content streaming, ordered isolated Runner plugins,
versioned concurrent evaluation sets, correlated `telemetry` envelopes, and
bounded exporters. It deliberately does not call REST SSE “Live”.

Known v0.7 gaps at branch start:

1. No Gemini Live WebSocket protocol, supervised session, interruption,
   resumption, GoAway, realtime media, transcription, or Live tool-call API.
2. Plugin callbacks are isolated but do not expose an explicit amend versus
   early-return distinction, a supervised stateful instance contract, or
   reusable core plugins.
3. Evaluation lacks built-in trajectory match policies, repeated sampling,
   baseline regression comparison, portable reports, and a v2 CLI path.
4. Observability has correlation envelopes but no W3C propagation,
   OpenTelemetry GenAI mapping, asynchronous bounded export bus, Live-session
   telemetry, or bounded metric aggregation.

## Architectural decisions

1. **Live is a separate protocol.** `gemini-3.1-flash-lite` remains the normal
   REST default; Live examples use `gemini-3.1-flash-live-preview` explicitly.
2. **One Live session is one supervised process.** The process owns exactly one
   active WebSocket, protocol state, bounded input admission, resumption token,
   and subscriber registry. Reconnect replaces the connection, not the stable
   session identity.
3. **Media flow is credit based.** Subscriber credit and byte/event limits
   prevent slow UI or audio consumers from turning BEAM mailboxes into media
   buffers. Input chunks, queues, decoded frames, tool calls, and transcripts
   have explicit limits.
4. **Credentials remain server-side.** API keys and resumption/ephemeral tokens
   never enter public events, logs, plugin contexts, evaluation data, or
   browser state. Direct browser-to-Gemini ephemeral-token provisioning is an
   application adapter, not a default core path.
5. **Plugin ordering stays deterministic.** Plugins run in registration order
   before corresponding local callbacks. Amend continues with a new value;
   early return skips remaining plugins, the local callback, and the guarded
   operation. Each callback remains deadline/heap/owner bounded.
6. **Evaluation separates facts from judges.** Deterministic response and
   trajectory criteria remain reproducible. LLM/managed judges use explicit
   adapters, model/version metadata, sample counts, deadlines, and error
   accounting; judge errors never become passing scores.
7. **Observability is metadata-first.** GenAI semantic attributes, W3C trace
   context, metrics, and events exclude content by default. Content capture is
   opt-in, bounded, recursively secret-pruned, and marked in every envelope.
8. **Export cannot create unbounded backpressure.** Synchronous fail-closed
   exporters remain available for policy gates; production telemetry can use
   a supervised bounded asynchronous bus with explicit drop accounting.

## Delivery phases

### A. Gemini Live protocol and multimodal sessions

- [x] Add a strict versioned Live client/server-message codec with text,
  PCM audio, image/video frames, activity signals, tool responses,
  transcriptions, usage, interruption, cancellation, GoAway, and resumption.
- [x] Track the current Gemini Live response schema, including interim input
  transcription, optional transcription metadata, completion reason/wait
  metadata, and server voice/VAD signals, with strict bounds and no dynamic
  provider atoms.
- [x] Add a production Gun WebSocket transport with peer verification,
  connection/setup deadlines, secret-safe failures, and response bounds.
- [x] Add independently supervised Live sessions with stable opaque refs,
  owner-aware control, bounded input admission, status, close, reconnect, and
  a race-safe supervisor-wide admission ceiling.
- [x] Add capped credit/ack subscriber admission, capacity recovery on detach
  or process death, slow-subscriber detachment, and exact byte/event
  accounting for bounded per-subscriber in-flight and queued events.
- [x] Add opt-in trusted Live tool execution with correlated IDs, explicit
  sequential versus bounded-concurrent local scheduling, cancellation, and
  bounded tool responses while preserving synchronous provider semantics.
- [x] Add deterministic fake-transport coverage and an opt-in real
  `gemini-3.1-flash-live-preview` gate.
- [ ] Add a separate local CA-controlled TLS WebSocket lifecycle harness.

Live limitations: subscribers receive events produced after subscription;
there is no historical structural-event replay yet. Deterministic fake
transport coverage is complete and the paid real-Live gate passes all five
text/transcription, PCM, image, synchronous-tool, and browser-bridge cases;
the separate local CA-controlled TLS WebSocket lifecycle harness remains open.
Automatic tool execution requires an explicit
trusted executor module, declared-tool allowlist, scheduling policy, worker
deadline, heap bound, and response bound; it is never inferred from an ambient
tool catalogue. A reconnect cancels in-flight/queued tool work and never
replays media, input, tool responses, or side effects. Caller-supplied
`session_id` values are correlation labels rather than unique registry keys;
the stable runtime identity is the supervised session reference/PID, and
developer lookup fails closed when labels are ambiguous. Opt-in Live v2 spans
and bounded metrics are metadata-only: media/text/transcripts, tool
arguments/results, credentials, and resumption handles cannot be captured by
the Live observability configuration.
Per-session subscriber admission defaults to 64 (hard maximum 4096). The
application-wide `live_session_limit` defaults to 1024 (hard maximum 16384);
capacity failures are explicit and admission does not enumerate children.

### B. Plugin lifecycle and reusable capabilities

- [x] Add explicit `amend` and `return` outcomes while preserving the v0.6
  compatibility result forms.
- [x] Stop remaining plugins and local callbacks after an explicit early
  return; preserve registration order for observation/amendment.
- [x] Harden callback workers with absolute deadlines, aliases, completion
  timestamps, caller monitoring, off-heap mailboxes, and shared-binary-aware
  heap limits.
- [x] Add an optional supervised stateful plugin-instance contract with hard
  ID/config/queue/deadline/heap/state bounds, owner-liveness commit semantics,
  bounded status, and deterministic shutdown.
- [x] Add reusable global-instruction, context-filter, logging, and tool-retry
  plugins where the existing Runner boundary can enforce their behavior.

Plugin limitations: tool-argument amendments are accepted only where the
runtime can repeat schema, policy, and confirmation checks; dynamically
resolved catalogue tools are therefore not amendable. Stateful callbacks are
serialized per plugin instance, so independent instances are the supported
way to obtain plugin-level concurrency. Reflect/retry emits bounded retry
guidance but does not automatically replay potentially non-idempotent tools.
A stateful instance PID is deliberately a temporary supervisor child: a crash
makes it unavailable rather than silently restarting with empty state behind a
stale identity. Initialization is isolated, but persistent/restarted plugin
state remains an application adapter.

### C. Evaluation expansion

- [x] Add deterministic built-in exact-response and tool-trajectory criteria
  with exact/in-order/any-order/subset matching and exact/subset/ignored
  argument policies.
- [x] Add a first-party bounded rubric/LLM judge adapter with explicit
  judge-schema, requested-model, rubric-ID, and rubric-version metadata. It
  defaults to `adk_llm_gemini`/`gemini-3.1-flash-lite` and is never selected
  or invoked implicitly.
- [x] Add repeated samples, deterministic sample IDs, aggregate distributions,
  pass thresholds, and explicit partial/judge-error accounting.
- [x] Add baseline comparison with configurable regression tolerances and
  stable JSON/Markdown reports suitable for CI artifacts.
- [x] Add a versioned `adk eval run` CLI path while preserving the legacy
  `adk evaluate` command and its output contract. Completed-but-failing gates
  use exit code 2; configuration/runtime failures use exit code 1.
- [x] Add bounded dataset/report size, case/sample concurrency, owner cleanup,
  and deadline-late-result tests.

Evaluation limitations: built-in criteria are deterministic and local. The
versioned CLI criteria file intentionally accepts only those checked built-ins;
trusted applications can register custom `score/4` or full-case
`score_case/2` modules through the Erlang API. The first-party rubric judge is
also an explicit Erlang-API module, not a hidden CLI or browser-selected call.
It stores a bounded rationale as evaluation content, while excluding provider
credentials and raw provider errors. Managed Vertex evaluation remains an
explicit future adapter, and every judge transport/schema/timeout error is
accounted as an error rather than a passing score.

The production CLI adapter creates one fresh supervised agent and Runner
session per case/sample. A lightweight guardian monitors the bounded sample
worker and owns the active stream, agent, and session, including timeout,
max-heap, and caller-death cleanup. Custom adapters which allocate external
resources must provide the equivalent owner monitor: `terminate_case/3` is
best-effort teardown and cannot run after an untrappable worker kill.

JSON eval-set and saved-result inputs and rendered reports are capped at 16 MiB
in the CLI; criteria and agent configuration files retain the stricter 1 MiB
configuration boundary. Report files are replaced atomically. Stdout and file
delivery contain the same newline-terminated bytes. With a baseline, the CI
gate requires both the current absolute thresholds and the configured
regression tolerances to pass.

### D. Expanded observability

- [x] Add strict W3C `traceparent`/`tracestate` parse, format, child-span, and
  explicit HTTP extraction/injection helpers; Runner model/tool and Live spans
  carry the checked context. Automatic propagation through every pre-existing
  MCP, A2A, workflow, task, and Phoenix call is not claimed.
- [x] Map lifecycle envelopes to stable OpenTelemetry GenAI operation,
  provider, model, tool, usage, output-type, error, and duration attributes.
- [x] Add a supervised asynchronous export bus with bounded queue/batches,
  exporter concurrency, retry policy, drain, and dropped-event counters.
- [x] Add a bounded low-cardinality metric registry plus operation
  count/duration/error and Live lifecycle/media/tool instruments; plugin and
  evaluation-specific product metrics remain application-defined records.
- [x] Add an opt-in, SDK-independent OTLP/HTTP JSON exporter while preserving
  the no-exporter path for applications that use only core `telemetry` events.

Observability limitations: the v0.7 native exporter implements OTLP/HTTP JSON,
not OTLP Protobuf, OTLP/gRPC, or an OpenTelemetry SDK bridge. It sends one
completed v2 span (or one metadata-only v1 log envelope) per request; v2 start
signals are local notifications and are not exported. It does not yet batch,
gzip, or pool collector connections inside the exporter--batch admission,
bounded parallel workers, transient retry, and drain remain responsibilities
of `adk_observability_bus`. Explicitly captured content is rejected at the
OTLP boundary, and prompt/response/media/tool-payload and credential-shaped
attributes are never mapped. Collector endpoints are configured as a strict
HTTP(S) origin plus bounded trace/log paths; plain HTTP is intended only for a
trusted local or private collector. Redirects are never followed, HTTPS uses
peer and hostname verification, request/response/header sizes are bounded,
and endpoint, header, and response-body values never enter failure terms.
OTLP retryable status codes (429, 502, 503, 504) and transport failures are
marked transient; other status codes and partial success rejections are
marked permanent, so the bus does not replay them. A numeric `Retry-After` is
present in the exporter's direct structural error, but the shared v0.7 bus
does not yet retain that hint or provide OTLP-specific jitter; it uses capped
exponential delayed retries within the same event/byte capacity as its ready
queue. Delivery is bounded best effort rather than a durable WAL: retries may
duplicate a batch and exhausted work is dropped and counted. The GenAI
semantic mapping remains explicitly pinned while the upstream convention is
Development.

### E. Integrated developer and Phoenix tooling

- [x] Add bounded Live status/text/future-only SSE and content-free
  observability snapshots without exposing media, credentials, resumption
  handles, thought signatures, or unrestricted content. A trace archive is not
  claimed.
- [x] Add a Phoenix LiveView reference path for server-owned Live sessions,
  future-only credit/ack event delivery, realtime text, and teardown, using a
  server-only opaque attachment handle after bounded discovery.
- [x] Add an authenticated same-origin binary voice socket backed by one
  owner-bound lightweight Erlang bridge, automatic-VAD/active-state admission,
  exclusive per-session leases, reconnect continuity capabilities, timed
  authorization revalidation, bounded AudioWorklet capture/resampling and
  cross-thread credit, native playback, exact ACK credit, interruption, and
  fail-closed ambiguous-outcome/reconnect teardown.
- [x] Add evaluation report/comparison and observability views with exact
  authorization and bounded rendering; keep `/dev` loopback-only.

### F. Documentation and release evidence

- [x] Update README examples and the F-ledger as each public API lands.
- [x] Reconcile `FEATURE_PARITY.md` and this contract with proven behavior and
  explicit limitations.
- [x] Complete clean compile/EUnit/Common Test/Dialyzer, README, CLI,
  concurrency, Phoenix, and packaging gates.
- [x] Raise the verified production runtime to OTP 27.3.4.14 / SSL 11.2.12.10
  and rerun deterministic, Phoenix, package, direct-TLS, REST, and Live gates
  on that security patch level.
- [x] Enforce loopback-only startup for the unauthenticated legacy
  `/a2a/prompt` route, including IPv4/IPv6 wildcard rejection independent of
  A2A v1 public-listener flags.
- [x] Run opt-in REST Gemini and Live Gemini suites with no skipped cases;
  provider/quota failures are reported and never counted as passes. Live is
  5/5; REST is 15/17 with two explicit HTTP 429 failures, while the new
  first-party rubric-judge case passes.
- [x] Run the Phoenix dependency audit and keep the two unresolved upstream
  Cowlib advisories explicit rather than treating the non-zero audit as pass.

## Explicit non-goals unless completed later on this branch

- The core does not capture microphones/cameras, resample PCM, render video, or
  play audio. It now supplies an owner-bound, bounded binary voice bridge; the
  checked Phoenix companion demonstrates the application-owned AudioWorklet
  capture/resampling and Web Audio playback pipeline.
- A Live WebSocket is not a durable queue. Resumption uses provider handles and
  bounded local state; it does not promise replay of arbitrary lost media.
- Browser-direct Gemini connections require a deployment-owned ephemeral-token
  endpoint, origin policy, rate limits, and abuse controls.
- Managed Vertex evaluation services and hosted observability backends remain
  adapters; deterministic local criteria and vendor-neutral telemetry are core.
- Reasoning traces, prompts, tool arguments/results, media, and transcripts are
  not captured merely because observability is enabled.
