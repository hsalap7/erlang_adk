# Phoenix production UI companion (v0.6)

This is a Phoenix 1.8 companion application for Erlang ADK. It runs Phoenix,
`erlang_adk`, the authenticated gateway, and supervised agent runs on the same
BEAM. The dependency in `mix.exs` is deliberately a path dependency on the
repository root; this is a reference integration, not a separately published
package.

The UI provides OIDC login, a server-owned agent catalog, scoped authorization,
text runs, bounded event rendering, credit/ack backpressure, reconnect by
server-side cursor, cancellation, and typed human approval. Browser input never
selects an ADK user ID, application name, runner, provider, or model.

## Locked setup and tests

Use Erlang/OTP 27 and Elixir 1.17 or newer, then run:

```bash
cd examples/phoenix_adk_ui
mix deps.get
mix assets.setup
mix assets.build
mix test
mix precommit
mix hex.audit
```

`mix precommit` checks formatting, compiles with warnings as errors, and runs
the deterministic suite. The suite uses a fake identity provider and agent; it
does not spend Gemini quota. The final 2026-07-14 gate passes all 46 tests;
production asset compilation and release assembly also pass. The assembled
release boots in both test-only trusted-proxy and direct-TLS configurations,
serves `GET /health` with HTTP 200 on loopback (with the repository test CA for
TLS), and stops cleanly. `mix hex.audit` remains non-zero only for the explicit
Cowlib exception documented below.

Phoenix LiveView is temporarily pinned to the official upstream fix commit
`86165533e311469a1b62093fd182d9d874de8106` for CVE-2026-58228. Replace that Git
pin with a Hex requirement only after LiveView 1.2.7 or newer is available and
the suite passes.

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
export OIDC_SCOPES='openid adk.agents.read adk.run.start adk.run.read adk.run.control'
mix phx.server
```

For a public PKCE client, omit `OIDC_CLIENT_SECRET` and set
`OIDC_PUBLIC_CLIENT=true`. The provider must support authorization code flow
with S256 PKCE and issue an ID token acceptable for the configured issuer,
client audience, and signing algorithm. The default model is fixed server-side
to `gemini-3.1-flash-lite`.

Open <http://127.0.0.1:4000>. There is no development authentication bypass:
the browser is redirected to the configured identity provider. `/health` is an
unauthenticated liveness endpoint.

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
rewriting; bounded parsers; and a same-origin Content Security Policy. Add edge
rate limits for login and callback routes.

## Runtime boundary

The browser sends only a fixed catalog ID and message. On every mount, browser
action, streamed event, terminal result, reconnect, and replay-gap transition,
the UI obtains current identity/session state from the private store and uses
`adk_web_gateway` for authorization and run ownership. Runs remain independent
supervised Erlang processes, so a dropped LiveView socket does not cancel work.
The browser receives one event at a time and returns credit only after bounded,
safe processing.

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

The login, session, reconnect cursor, gateway, and `adk_run` processes are
node-local. A single-node release is supported. A multi-node deployment must
use sticky routing for the complete login/session/run lifetime or replace these
stores and run routing with an explicitly distributed design. A node restart
invalidates web sessions and in-flight login transactions, which fails closed.

Logout revokes the local UI session; it does not perform identity-provider
single logout or token revocation. The UI intentionally does not expose the
developer inspector. Keep Erlang ADK's developer tooling on a separate,
authenticated, loopback/private interface as documented in the repository
root.

The locked dependency tree currently resolves Cowlib 2.18.0. `mix hex.audit`
reports [EEF-CVE-2026-43969](https://cna.erlef.org/osv/EEF-CVE-2026-43969.json)
(also GHSA-g2wm-735q-3f56) and
[EEF-CVE-2026-43966](https://cna.erlef.org/osv/EEF-CVE-2026-43966.json). The
companion does not configure Gun's cookie store, and the locked Cowboy 2.17.0
and Gun 2.4.1 enable their invalid-header rejection defaults, but vulnerable
Cowlib routines remain present. Treat a non-zero audit as a visible release
exception, track an official fixed Cowlib release, and rerun the full suite
before upgrading; do not silently waive the advisories. As of 2026-07-14,
[2.18.0 is the latest official Cowlib release](https://hex.pm/packages/cowlib)
and both EEF advisory ranges are still open. The available
[preliminary fork patch](https://github.com/erlef/cowlib/commit/177953dd51540da11090666c1f007214127a1144)
addresses only EEF-CVE-2026-43969, so it is not a safe replacement for an
official release that resolves both findings.
