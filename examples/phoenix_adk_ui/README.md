# Phoenix production UI companion (v0.8)

This is a Phoenix 1.8 companion application for Erlang ADK. It runs Phoenix,
`erlang_adk`, the authenticated gateway, and supervised agent runs on the same
BEAM. The dependency in `mix.exs` is deliberately a path dependency on the
repository root; this is a reference integration, not a separately published
package.

The UI provides OIDC login, a server-owned agent catalog, scoped authorization,
text runs, bounded event rendering, credit/ack backpressure, reconnect by
server-side cursor, cancellation, and typed human approval. The `/live`
console adds principal-scoped discovery of server-owned ADK Live sessions,
future-only attach/detach, realtime text input, bounded Live event credit/ack,
an authenticated binary full-duplex voice bridge with v0.8 server-negotiated
16/24 kHz input, read-only observability
snapshots, and pure evaluation report and baseline-comparison panels. Browser
input never selects an ADK user ID,
application name, runner, provider, model, evaluator module, or filesystem
path.

## Locked setup and tests

Use Erlang/OTP 27 and Elixir 1.17 or newer. The checked `.tool-versions`
pins the verified development toolchain to Elixir 1.19.5 on OTP 27 and Node.js
24.3.0 for dependency-free asset tests. Then run:

```bash
cd examples/phoenix_adk_ui
mix deps.get
mix assets.setup
mix assets.build
mix assets.test
mix test
mix precommit
mix hex.audit
```

`mix assets.test` runs dependency-free resampler and browser-hook tests.
`mix test` rebuilds both the JavaScript and CSS assets, runs those Node tests,
and then runs ExUnit; the
suite verifies that `/assets/css/app.css` is served with the expected content
type. `mix precommit` checks formatting, compiles with warnings as errors, and
runs the deterministic suite. The suite uses fake identity, agent, and Live gateway
providers; it does not spend Gemini quota. The final v0.8 2026-07-17 gate
passes all 103 ExUnit tests and 40 browser-audio tests;
production asset compilation and release assembly also pass. The assembled
release boots in both test-only trusted-proxy and direct-TLS configurations,
serves `GET /health` with HTTP 200 on loopback (with the repository test CA for
TLS), and stops cleanly. `mix hex.audit` remains non-zero only for the explicit
Cowlib exception documented below.

Phoenix LiveView is temporarily pinned to the official upstream fix commit
`86165533e311469a1b62093fd182d9d874de8106` for CVE-2026-58228. Replace that Git
pin with a Hex requirement only after LiveView 1.2.7 or newer is available and
the suite passes.

## Local development without an OIDC provider

The explicit local authentication mode is available only in `MIX_ENV=dev` and
binds Phoenix to the exact IPv4 loopback address. It uses one fixed,
server-owned development identity and the normal opaque server-side session;
the browser cannot select its subject, issuer, principal, or scopes. Login is
a CSRF-protected POST rather than a state-changing GET.

```bash
cd examples/phoenix_adk_ui
export GEMINI_API_KEY='...'
export ADK_UI_LOCAL_AUTH=true
mix setup
iex -S mix phx.server
```

Open <http://127.0.0.1:4000/auth/login> and click **Continue as local
developer**. No `OIDC_*` variables are read in this mode. The header displays a
local-authentication badge. `ADK_UI_LOCAL_AUTH=true` is rejected during
production configuration, and malformed values fail startup rather than
falling back silently.

Unset the flag, or set it to the exact value `false`, to exercise real OIDC.

## OIDC development setup

Register this exact development redirect URI with the identity provider:

```text
http://127.0.0.1:4000/auth/callback
```

Set deployment-specific values without committing literal secrets:

```bash
export GEMINI_API_KEY='...'
export OIDC_ISSUER='https://identity.example.com'
export OIDC_CLIENT_ID='...'
export OIDC_CLIENT_SECRET='...'
export OIDC_REDIRECT_URI='http://127.0.0.1:4000/auth/callback'
export OIDC_SCOPES='openid adk.agents.read adk.run.start adk.run.read adk.run.control adk.live.read adk.live.control adk.observability.read adk.evaluation.read'
mix phx.server
```

For a public PKCE client, omit `OIDC_CLIENT_SECRET` and set
`OIDC_PUBLIC_CLIENT=true`. The provider must support authorization code flow
with S256 PKCE and issue an ID token acceptable for the configured issuer,
client audience, and signing algorithm. The default model is fixed server-side
to `gemini-3.1-flash-lite`.

Open <http://127.0.0.1:4000>. With local authentication disabled, the browser
is redirected to the configured identity provider. `/health` is an
unauthenticated liveness endpoint.

Use `/agent` for ordinary Runner jobs and `/live` for server-owned Live
sessions, realtime voice, metadata-only observability, and configured
evaluation reports.

The opaque browser cookie does not contain state, nonce, PKCE verifier, OIDC
tokens, identity claims, ADK user IDs, or run state. Login transactions are
one-time, bounded, expiring entries; callbacks consume them before token
exchange. Authenticated sessions are bounded, expiring entries in an unnamed
private ETS table accessed only by its owning GenServer.

Authorization setup and code exchange execute outside Cowboy/Phoenix request
heaps in monitored workers. Each worker has a 15-second timeout and a
1,000,000-word shared-binary-aware maximum heap by default. Process aliases
suppress late replies, completion timestamps reject queued post-deadline
results, and a bounded watchdog reaps the worker if its request owner dies.
Crashes, timeouts, heap termination, and provider exception details collapse
to secret-safe public errors. Tune
`:auth_provider_call` only through trusted release configuration.

## Production assets and release

Build immutable assets and the release:

```bash
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

At runtime set `PHX_SERVER=true`, `PHX_HOST`, `SECRET_KEY_BASE`, the OIDC values
above with an HTTPS callback, and `GEMINI_API_KEY`. `PORT` is the listener port;
`PHX_URL_PORT` is the external HTTPS port and defaults to 443. Generate the
Phoenix secret with `mix phx.gen.secret`; do not reuse an OIDC or Gemini secret.

Choose exactly one transport boundary:

- Direct TLS: set both `TLS_CERT_PATH` and `TLS_KEY_PATH`.
- Trusted terminating proxy: set `PHX_BEHIND_HTTPS_PROXY=true` and expose the
  Phoenix listener only to that proxy through network policy or a firewall.
  The proxy must overwrite client-supplied `X-Forwarded-Host`,
  `X-Forwarded-Port`, and `X-Forwarded-Proto`; this setting explicitly trusts
  those headers. Never expose this HTTP listener directly to the internet.

Production enforces secure, encrypted, HTTP-only, SameSite=Lax cookies; an
exact connection scheme/host/port origin check; CSRF protection; HSTS/HTTPS
rewriting; bounded parsers; a same-origin Content Security Policy; and a
microphone policy restricted to the same origin. Camera access remains
disabled. Add edge rate limits for login, callback, and voice upgrade routes.

## Runtime boundary

The browser sends only a fixed catalog ID and message. On every mount, browser
action, streamed event, terminal result, reconnect, and replay-gap transition,
the UI obtains current identity/session state from the private store and uses
`adk_web_gateway` for authorization and run ownership. Runs remain independent
supervised Erlang processes, so a dropped LiveView socket does not cancel work.
The browser receives one event at a time and returns credit only after bounded,
safe processing.

The Live console has a separate, explicit boundary in
`ErlangAdkUi.LiveGateway`. Its adapter module is trusted release configuration,
not request input. `ErlangAdkUi.LiveGateway.Local` performs a bounded,
timeout-limited concurrent scan of only the fixed `adk_live_session_sup` during
discovery/attach, then returns a server-only opaque attachment handle. LiveView
keeps that handle out of rendered data and uses it for O(1) routing of text,
acknowledgement, and detach calls. Every direct ADK operation still receives the
exact server-side principal and applies capability-specific scopes:

- `adk.live.read` for discovery, attachment, acknowledgement, detach, and
  opening a voice bridge;
- `adk.live.control` for realtime text and microphone/control frames; voice
  frames re-check both Live scopes;
- `adk.observability.read` for metric/export-delivery snapshots; and
- `adk.evaluation.read` for checked reports and baseline comparisons.

The browser can attach only an identifier returned by its current discovery
result; it can neither see nor submit the opaque attachment handle. Credit is
fixed in trusted configuration as `%{messages: 8, bytes:
262_144}`. Attach is future-only and carries no cursor: no historical Live
event replay is claimed or attempted. Closing the LiveView explicitly detaches,
and the ADK session also monitors the subscriber process as a cleanup backstop.
Detaching the UI does not close the independently supervised Live session.

Raw audio/video media is never assigned to or rendered by the LiveView. The
projection boundary turns audio into format/rate/channel/byte-count metadata,
strips thought signatures, omits generic binary payload fields, bounds text and
collection sizes, then acknowledges only after projection and bounded event
admission.

Voice uses a separate `GET /live/voice/:session_id` WebSocket upgrade. The
controller requires the normal opaque authenticated session and an exact
scheme/host/port `Origin`; absent and cross-origin requests fail before the
upgrade. The WebSocket accepts binary frames only, re-fetches the server-side
session on every inbound, outbound, ping, and pong frame, and also performs a
15-second server-driven revalidation so logout, expiry, or revocation releases
an otherwise idle exclusive lease. It owns one ephemeral core
`adk_live_voice_bridge` process. The bridge keeps the principal and opaque Live
session PID out of browser data and holds each forwarded ADK event's credit
until the browser ACKs that exact sequence. The fixed windows are eight events,
262,144 output bytes, and at most 64,000 bytes per microphone frame. Closing,
logout, expiry, owner death, malformed framing, or backpressure tears down the
bridge without closing the independently supervised Live session.
A monitored core lease permits only one bidirectional browser bridge for a
given Live session, preventing two tabs from interleaving audio while unrelated
sessions remain concurrent. A provider reconnect changes a session-owned
continuity capability and independently notifies the bridge, so an old bridge
cannot write after a fast resume or retain its lease behind exhausted event
credit. An ambiguous timed-out input/ACK terminates the bridge rather than
permitting a duplicate retry. Refresh after the session returns to `active`,
then start a new voice bridge.

Before accepting microphone media, the core bridge sends one exact v1 input
configuration frame: `<<1, 128, Rate:32/big, 1, 1>>`. It derives `Rate` from
trusted Live-session status (16 kHz for Gemini or 24 kHz for OpenAI Realtime),
not from a browser option or model-name heuristic. This frame has no event
sequence, consumes no subscriber credit, and is never acknowledged. The browser
fails closed if it is missing, duplicated, malformed, or outside that allowlist.

The browser captures through an AudioWorklet, applies a streaming anti-alias
filter, resamples tested 16/44.1/48/96 kHz device contexts to the negotiated 16
or 24 kHz mono PCM s16le rate (including safe 16-to-24 kHz interpolation), and
sends exact 20 ms chunks. A 16-chunk worklet-to-main credit window bounds a
stalled browser thread; overflow closes the generation instead of silently
dropping speech. Web Audio plays the native
PCM response at its declared sample rate with a bounded scheduling queue.
The player establishes a short jitter buffer once per response/underrun and
then schedules PCM frames sample-contiguously; WebSocket arrival jitter is not
converted into silence between chunks.
Model audio is split into at most 100 ms Web Audio sources with no more than
two seconds scheduled at once. A FIFO pending window mirrors the bridge's eight
event/262,144-byte credit bound, and an audio event's exact ACK is withheld
until all of its PCM has entered that scheduled window. Source completion
drains the FIFO, so a bursty or long reply applies backpressure instead of
canceling already audible content. Interruption deliberately cancels and
acknowledges older pending audio before its own ACK; terminal/error teardown
discards pending audio without a stale ACK and closes the bridge, releasing its
credit.
Gemini interruption code `4` immediately stops already scheduled sources. The
checked browser pipeline is offered only when trusted discovery reports an
`active` session with automatic activity detection; configure the Live session
with `automatic_activity_detection => true`. Muting disables the media
track and sends only silence so turn detection can finish without exposing
microphone samples. Camera/video capture remains disabled.
Interim transcription updates remain visual; a separate polite live region
announces only finalized user/model utterances to assistive technology.
The v1 browser projection gives transcription frames explicit directional
semantics: input frames contain the complete latest hypothesis and replace the
currently displayed input, while output frames are ordered deltas appended to
the current model utterance. The final flag controls visual/assistive completion
and does not change those replacement-versus-append rules.

### Starting a Live session for the UI

Create sessions from trusted server orchestration, never from browser
parameters. The session ID must be unique on the node, and `Principal` must be
the exact principal derived from the authenticated server-side identity:

```elixir
{:ok, %{principal: principal}} = ErlangAdkUi.Auth.LocalDev.identity()

config = %{
  provider: :adk_live_gemini,
  provider_config: %{
    model: "gemini-3.1-flash-live-preview",
    response_modalities: [:audio],
    input_audio_transcription: true,
    output_audio_transcription: true,
    automatic_activity_detection: true,
    session_resumption: true
  },
  transport: :adk_live_gun_transport,
  transport_opts: %{api_key: System.fetch_env!("GEMINI_API_KEY")},
  max_subscribers: 64,
  max_subscriber_messages: 64,
  max_subscriber_bytes: 8_388_608
}

{:ok, live_pid} =
  :erlang_adk.start_live_session("web-live-01", principal, config)
```

The Phoenix console discovers `web-live-01` only for that exact `Principal`.
`LocalDev.identity/0` is appropriate only for the explicit loopback mode above;
an OIDC deployment passes the principal from its validated server-side
identity through trusted orchestration instead.
The API key is handed to the fixed Google WebSocket transport and is not
returned through status or UI data. The production transport fixes the Google
origin/path and verifies TLS; the model is explicitly the Live preview model,
not the REST default `gemini-3.1-flash-lite`.
Set the core application environment `live_session_limit` before startup when
the default node-wide ceiling of 1024 sessions is not appropriate; accepted
values are 1 through the hard maximum of 16384. Each session independently
defaults to 64 subscribers with a hard maximum of 4096, and the UI attachment
relay and active voice bridge each consume one subscriber slot.

### Testing full-duplex voice

1. Start the development server with `ADK_UI_LOCAL_AUTH=true` using
   `iex -S mix phx.server`, then create `web-live-01` in that same IEx prompt
   with the code above.
2. Open <http://127.0.0.1:4000/auth/login>, continue as the local developer,
   and select **Live and operations**.
3. Click **Refresh sessions** until `web-live-01` reports `active`, then attach
   it. Do not use `localhost` in one place and `127.0.0.1` in another; the
   authenticated voice upgrade enforces the exact browser origin.
4. Prefer headphones, click **Start voice**, and allow microphone access for
   `127.0.0.1`. Speak normally and pause. Input/output transcription appears in
   the voice panel and the model's 24 kHz PCM response plays automatically.
5. Speak while the model is responding to verify interruption; queued playback
   must stop immediately. Exercise **Mute microphone**, **Unmute microphone**,
   and **Stop voice**, then detach the Live session.
6. The UI intentionally does not own or terminate the independently supervised
   Live session. When the manual test is complete, close it explicitly in IEx
   so the paid provider WebSocket is not left running:

   ```elixir
   :ok =
     :erlang_adk.close_live_session(
       live_pid,
       principal,
       :manual_voice_test_complete
     )
   ```

Browser microphone permission is a user/device decision and is not bypassed by
the application. `127.0.0.1` and HTTPS are secure contexts in supported
browsers; production must use the direct-TLS or trusted-proxy boundary described
above. The Live model is `gemini-3.1-flash-live-preview`; the ordinary agent
model remains `gemini-3.1-flash-lite`.

### Observability and evaluation panels

The observability panel reads bounded snapshots from the fixed
`adk_observability_metrics` and optional `adk_observability_bus` processes. It
exposes aggregation/delivery metadata only and declares content attributes
disabled. It is not an arbitrary telemetry query or exporter configuration
surface.

Evaluation reports are immutable checked maps in trusted application
configuration. No route accepts a file path or module name:

```elixir
config :erlang_adk_ui,
  evaluation_reports: %{
    "release-baseline" => %{label: "Release baseline", report: baseline_result_map},
    "release-current" => %{label: "Release current", report: current_result_map}
  }
```

`report` values must be persisted evaluation result maps accepted by
`:adk_eval_dev_view`. Rendering and comparison are pure and output-bounded;
invalid or mismatched reports fail closed. Populate the map at trusted boot
configuration time. Do not add a browser-controlled loader.

Gateway authorization itself uses independent caller-monitored workers with
bounded admission, timeout, heap, input, and normalized results. The defaults
are 64 concurrent checks, one second, and 100,000 heap words. A custom catalog
provider can tighten `max_authorizations`, `authorizer_timeout_ms`, and
`authorizer_max_heap_words` in its trusted `gateway_options/0`; a callback
failure denies that operation without wedging unrelated LiveViews.

Unknown pause types are displayed but never resumed. The UI only emits the
typed payloads required by human approval and tool confirmation. Final output
is escaped by HEEx and truncated on grapheme boundaries.

The bundled catalog contains one Gemini assistant. Replace
`ErlangAdkUi.AgentCatalog.Gemini` through trusted application configuration to
add a larger immutable catalog; do not build runners or providers from request
parameters.

## Current deployment scope

The login, web session, reconnect cursor, gateways, `adk_run`, ADK Live,
observability snapshot, and configured evaluation catalog are node-local. A
single-node release is supported. A multi-node deployment must
use sticky routing for the complete login/session/run lifetime or replace these
stores and run routing with an explicitly distributed design. A node restart
invalidates web sessions and in-flight login transactions, which fails closed.

Logout revokes the local UI session; it does not perform identity-provider
single logout or token revocation. The UI intentionally does not expose the
developer inspector. Keep Erlang ADK's developer tooling on a separate,
authenticated, loopback/private interface as documented in the repository
root.

The operations panel is deliberately not a session creator, media recorder,
tool-response editor, arbitrary trace browser, evaluation runner, or report
loader. Live media remains ephemeral; the browser view is not durable storage.
ADK Live resumption does not imply replay of unacknowledged media, text, or tool
responses.

The locked dependency tree currently resolves Cowlib 2.18.0. `mix hex.audit`
reports [EEF-CVE-2026-43969](https://cna.erlef.org/osv/EEF-CVE-2026-43969.json)
(also GHSA-g2wm-735q-3f56) and
[EEF-CVE-2026-43966](https://cna.erlef.org/osv/EEF-CVE-2026-43966.json). The
companion does not configure Gun's cookie store, and the locked Cowboy 2.17.0
and Gun 2.4.1 enable their invalid-header rejection defaults, but vulnerable
Cowlib routines remain present. Treat a non-zero audit as a visible release
exception, track an official fixed Cowlib release, and rerun the full suite
before upgrading; do not silently waive the advisories. As of 2026-07-15,
[2.18.0 is the latest official Cowlib release](https://hex.pm/packages/cowlib)
and both EEF advisory ranges are still open. The available
[preliminary fork patch](https://github.com/erlef/cowlib/commit/177953dd51540da11090666c1f007214127a1144)
addresses only EEF-CVE-2026-43969, so it is not a safe replacement for an
official release that resolves both findings.
