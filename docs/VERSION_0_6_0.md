# Erlang ADK 0.6.0 development contract

This document is the implementation and release contract for the
`version_0.6.0` branch. Version 0.6 focuses on **authentication, protocols,
and a production-capable UI**. It inherits the v0.5 artifact, memory, context,
runtime, and developer-tooling behavior; it does not reinterpret a shared
local developer bearer token as production user authorization.

The target is observable behavior, not a line-for-line port of another ADK.
Long-running work remains in independently supervised BEAM processes,
unrelated principals and sessions should overlap, and network or browser
lifetimes must not own agent-run lifetimes.

Primary external contracts:

- [ADK tool authentication](https://adk.dev/tools-custom/authentication/):
  per-user credentials, interactive OAuth/OIDC, short-lived tokens, and
  production secret-manager ownership;
- [MCP 2025-11-25 authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization):
  RFC 9728 protected-resource metadata, authorization-server discovery,
  RFC 8707 resource indicators, PKCE S256, scope challenges, and exact token
  audience validation;
- [A2A 1.0](https://a2a-protocol.org/latest/specification/): declared Agent
  Card security, authentication on every JSON-RPC/task request, public Agent
  Card discovery, operation/data
  authorization, TLS, and principal-scoped tasks;
- [Phoenix LiveView security](https://hexdocs.pm/phoenix_live_view/security-model.html):
  authenticate both HTTP and connected mounts and authorize every event.

## Release truth at branch start

The v0.5 baseline already provides:

- strict bearer parsing and Oidcc-backed JWT/JWKS validation with issuer,
  audience, algorithm, time, subject, scope, and claim policy;
- private scoped credential references, CAS refresh-token rotation, bounded
  supervised single-flight refresh, and seeded secret redaction;
- MCP stdio and 2025-11-25 Streamable HTTP plus an authenticated,
  loopback-first bounded server;
- A2A 1.0 Agent Card, JSON-RPC/SSE tasks, principal-scoped visibility, and an
  outbound client;
- an authenticated, bounded `/dev/v1` REST/SSE console and packaged CLI;
- stable supervised runs with bounded credit/ack replay, cancellation, and
  durable pause/resume semantics;
- a documented Phoenix pattern, but no compiled Phoenix application.

The audit found release-blocking gaps:

1. Token callers can select the credential-consuming provider module and
   arbitrary provider context.
2. Token audience is only a cache discriminator and is not sent as an RFC
   8707 resource indicator.
3. Credential deletion/revocation is not coupled to token-cache eviction;
   built-in credential storage is volatile and unbounded.
4. The PKCE helper stores a verifier but does not own state, nonce, redirect,
   code exchange, replay protection, or cleanup as one supervised flow.
5. MCP sessions are not bound to authenticated principals, unsupported
   initialization versions are rejected instead of negotiated, and MCP OAuth
   discovery/challenges are absent.
6. Public A2A can be configured over clear HTTP without authentication; the
   client trust policy does not yet prevent cross-origin token forwarding or
   private-address discovery.
7. A2A optional-operation errors, extensions, catalog/data byte bounds,
   streaming backpressure, and durable distributed task behavior are partial.
8. OpenAPI credential resolution is serialized inside one broker process and
   several transport/version edge cases remain.
9. `/dev` has one local administrator token and accepts caller-selected
   app/user/session paths. It must remain loopback developer tooling.
10. Runs are globally discoverable by ID and are not bound to an authenticated
    owner at registration.
11. The Phoenix example is an uncompiled README excerpt rather than a tested,
    deployable companion.

## Architectural decisions

1. **Authentication and authorization are separate.** Oidcc/JWT policy proves
   identity. A default-deny authorizer decides each exact operation/resource.
2. **Provider configuration is trusted and immutable.** A token request may
   name a configured provider and opaque credential reference; it may not
   choose the module that receives raw credentials or inject provider context.
3. **Credentials never enter model/session/UI data.** Browser sessions contain
   opaque session material. Access/refresh tokens, client secrets, PKCE
   verifiers, and provider callbacks stay outside LiveView assigns, events,
   prompts, telemetry, and public errors.
4. **Protocol sessions inherit identity.** MCP sessions and A2A tasks bind to
   stable issuer/principal scopes at creation. Cross-principal access is
   indistinguishable from an unknown resource.
5. **The Phoenix application is a BFF on the same BEAM.** It calls an Erlang
   gateway directly; there is no required REST hop. Each browser/LiveView is a
   lightweight process, while stable runs outlive browser disconnects.
6. **`/dev` stays local.** It is an operator/developer surface and is never the
   production end-user API. Public protocol and production UI listeners do not
   accidentally expose it.
7. **Credential-bearing and network callback boundaries hardened in v0.6 are
   bounded.** Authentication, authorization, provider, broker, discovery,
   parser, and stream work in that slice has absolute deadlines,
   byte/count/heap limits, caller monitoring, and supervised cleanup. Trusted
   application modules and boot-time configuration loaders are not presented
   as a hostile-code sandbox or as protection from unsafe NIFs/VM-wide side
   effects.
8. **Stable protocol versions are explicit.** v0.6 targets released MCP
   2025-11-25 and A2A 1.0. Draft MCP versions are rejected/negotiated through
   version dispatch rather than silently changing semantics.

## Capability matrix

| Area | Starting status | v0.6 release requirement |
| --- | --- | --- |
| Incoming OIDC/JWT | Implemented release slice | Strict bounded verification plus default-deny operation authorization, access-token `aud`/scope policy, separate OIDC ID-token `azp` rules, and local fixtures are implemented. IdP revocation and back-channel logout remain deployment integration. |
| Outbound credentials | Implemented release slice | Immutable provider profiles, least-authority token requests, RFC 8707 resource targeting, bounded private cache/admission/storage, explicit invalidation, and secret-free failures/status are implemented. A durable encrypted store and provider-specific revocation remain adapters. |
| Interactive OAuth/OIDC | Implemented release slice | Supervised state/nonce/S256 flow ownership, exact redirect/provider/client/scope binding, internal code exchange, one-time completion, bounded expiry cleanup, and opaque HITL correlation are implemented. IdP logout/revocation remains an integration hook. |
| MCP | Hardened partial | Version negotiation, principal-bound sessions, per-operation authorization, RFC 9728 server metadata/challenges, destination/TLS/DNS/token isolation, absolute deadlines, and bounds are implemented. Automatic client-side OAuth discovery/PKCE and fully incremental concurrent SSE delivery are not claimed. |
| A2A 1.0 | Hardened partial | Public bind/TLS policy, strict card/security/extension validation, canonical optional-operation errors, outbound SSRF/token isolation, absolute deadlines, byte/count limits, and slow-subscriber detachment are implemented. The outbound SSE response is bounded but buffered, and tasks remain node-local. |
| OpenAPI | Implemented supported subset | Bounded broker workers, immutable auth profiles, numeric version parsing, safer IPv6/redirect/method behavior, compilation bounds, and regression coverage are implemented for the documented subset. |
| Production web gateway | Implemented agent-run surface | Authenticated identity mapping, server-owned agents, exact operation scopes, immutable run ownership/resume inheritance, bounded HITL input, and redacted decisions are implemented. Artifact/memory/context administration and durable audit/revocation remain separate privileged APIs/adapters. |
| Phoenix companion | Implemented reference companion | The checked Phoenix 1.8 project provides OIDC code+S256 PKCE, private opaque sessions, secure origin/CSRF/header policy, bounded LiveView delivery, typed fail-closed HITL, reconnect/cancel/replay-gap handling, deterministic tests, assets, and release assembly. Multi-node session state, IdP SLO, and privileged resource panels remain explicit limitations. |
| Local developer UI | Implemented local tool | Loopback-only startup, bounded browser/reconnect behavior, fail-closed unknown pause types, and explicit separation from production routes are implemented. It remains a single-operator development surface. |

## Delivery phases

### A. Trusted identity, authorization, and run ownership

- [x] Add a default-deny authorizer with exact issuer, principal, operation,
  and required-scope validation.
- [x] Add a production `adk_web_gateway` which resolves agents from a
  server-owned catalog and derives `user_id` from the OIDC principal.
- [x] Bind a stable run atomically to an opaque owner scope and make resumed
  runs inherit it even if a caller supplies different options.
- [x] Make cross-owner run lookup return the same result as an unknown run.
- [ ] Extend the gateway to exact-scope session/artifact/memory/context
  operations with explicit approver/operator/admin policies.
- [ ] Add bounded durable security-audit adapters and revocation-driven
  disconnect of active browser sessions.

### B. Outbound authentication and credential lifecycle

- [x] Replace caller-selected provider modules/context with immutable trusted
  provider profiles.
- [x] Enforce profile grant, scope, audience/resource, TTL, and concurrency
  limits before credential resolution.
- [x] Add explicit opaque-reference token invalidation for local cache
  eviction.
- [ ] Couple credential deletion/provider revocation to token invalidation in
  deployments that expose those lifecycle operations.
- [ ] Add provider revocation and persistent credential-generation binding.
- [x] Pass RFC 8707 resource indicators through supported OAuth grants and
  validate JWT access-token audience where possible.
- [ ] Add a durable encrypted credential-store adapter whose key resolver can
  be backed by KMS/HSM/secret-manager infrastructure; keep ETS documented as
  a development adapter.
- [x] Add private bounded cache/storage, expiry sweep, worker limits, global
  admission, bounded waiters, and secret-free status/errors.
- [ ] Add durable negative backoff and independently configurable
  per-principal refresh admission.

### C. Interactive OAuth/OIDC

- [x] Add a supervised Oidcc authorization-flow manager owning state, nonce,
  S256 verifier, redirect URI, client/provider/resource/scopes, deadline, and
  one-time callback claim.
- [x] Exchange authorization codes internally and store only a validated
  credential behind the original opaque reference.
- [x] Bind the authenticated subject/issuer/client/scopes to the paused
  invocation and reject replay, mix-up, redirect mismatch, and expiry.
- [x] Add bounded cancellation and expiry cleanup.
- [ ] Add provider logout, token revocation, and back-channel session-disconnect
  hooks.

### D. Protocol hardening

- [x] Correct MCP initialization version negotiation.
- [x] Bind MCP sessions and deletes to authenticated principal scope.
- [x] Serve RFC 9728 protected-resource metadata and Bearer challenges with
  authoritative scopes.
- [ ] Add automatic MCP client authorization-server discovery and a managed
  PKCE S256 flow; applications can currently wire the generic supervised flow.
- [x] Bound MCP HTTP authentication, connection, response, pending work, body,
  caller cleanup, and schema processing under an absolute deadline.
- [ ] Deliver concurrent MCP HTTP SSE responses incrementally to callers; the
  current client deliberately uses one supervised client per independent
  stream and a bounded response buffer.
- [x] Make public A2A require authentication plus TLS or an explicitly trusted
  TLS proxy; never co-expose `/dev` on that listener.
- [x] Add canonical A2A optional-operation errors, bounded extension handling,
  structural card security validation, and fail-closed single-scheme client
  selection.
- [ ] Add a multi-credential client for compound A2A AND requirements; server
  hook-to-card semantic alignment remains an operator policy responsibility.
- [x] Add A2A client SSRF/DNS/redirect/same-origin token policy and bounded
  subscription responses.
- [x] Add A2A task/history/artifact/metadata byte limits, subscriber/admission
  limits, and one absolute operation deadline.
- [ ] Replace buffered outbound A2A SSE decoding with a credit-based
  incremental callback API; server-side subscribers are already bounded and
  detached on overflow.
- [x] Fix OpenAPI broker/transport/version edge cases and add regression tests.

### E. Production Phoenix UI

- [x] Check in a Phoenix 1.8/LiveView companion application with a lock file,
  deterministic provider, tests, assets, runtime configuration, and release.
- [x] Use OIDC Authorization Code plus S256 PKCE for enterprise identity; keep
  generated local auth with a maintained password hasher as an optional
  deployment choice, not a second identity inside the Erlang core.
- [x] Enforce secure/HttpOnly/SameSite cookies, session rotation, CSRF, exact
  WebSocket origin, CSP, HSTS, parser/body bounds, and per-event authorization.
- [ ] Apply route and identity-aware login/callback rate limits at the trusted
  deployment edge; the companion documents this operator requirement.
- [x] Use bounded LiveView streams/assigns, credit/ack ADK subscriptions,
  stable session/run IDs, reconnect/replay-gap recovery, cancellation, and
  graceful detach/drain.
- [x] Implement typed HITL components with attribution,
  double-submit protection, and fail-closed unknown pause types.
- [ ] Add user/approver/operator/admin route groups and exact-scope
  artifact/memory/context panels.

### F. Integrated developer tooling and documentation

- [x] Enforce loopback-only `/dev` for application, CLI, and direct startup.
- [x] Bound transcript/trace DOM and reconnect attempts; preserve cursor on
  manual attach; fail closed for unknown pause types.
- [x] Replace the old Phoenix README excerpt with commands for the checked-in
  companion and keep production/developer topology explicit.
- [x] Add every new README fence to `README_EXAMPLE_COVERAGE.md` and remove
  stale references to nonexistent tests.
- [x] Reconcile `FEATURE_PARITY.md`, protocol guides, security operations,
  proxy/TLS deployment, key rotation, backup/restore, and incident response.

### G. Release evidence

- [x] Focused authentication, gateway, protocol, and Phoenix suites pass with
  no skipped deterministic cases.
- [x] `./rebar3 do clean, compile, eunit, ct, dialyzer` passes from clean: 899
  EUnit tests, six deterministic Common Test cases, and warning-free Dialyzer
  over 170 project files.
- [x] README examples, escript packaging, doctor, and config validation pass.
- [x] Phoenix format/compile/test/assets/release gates pass from its locked
  project: 46 tests pass, production assets/release assembly complete, and the
  packaged release returns HTTP 200 from `/health` on loopback in both
  trusted-proxy and direct-TLS modes before a clean stop.
- [ ] Resolve the two documented Cowlib 2.18.0 advisories reported by
  `mix hex.audit`; the audit was run and remains an explicit non-zero release
  exception until an official complete upstream fix is released.
- [ ] MCP and A2A cross-SDK interoperability jobs pass in both directions.
- [x] Local-CA TLS, malicious discovery/redirect, auth timeout/crash/heap,
  cross-principal, replay, and secret-leak suites pass.
- [x] Concurrency/soak tests record bounded process counts/mailboxes and no
  orphan refresh/request/subscription workers.
- [x] The separate `gemini-3.1-flash-lite` live suite was run with no skips:
  14 cases passed, while Search grounding and context-cache creation each
  failed explicitly on HTTP 429 after one bounded retry. Provider/quota
  failures are reported and are never counted as passes.

## Explicit non-goals unless completed later on this branch

- The local `/dev` bearer is not a production identity system.
- The core does not store end-user passwords. Phoenix-generated local auth or
  an external IdP owns them.
- ETS credentials are not durable or encrypted-at-rest production storage.
- A TLS-terminating proxy assertion is not accepted from arbitrary forwarding
  headers; it is an explicit trusted deployment configuration.
- Node-local A2A tasks and run registry do not imply horizontal failover.
  Sticky affinity/single-node runtime is documented until a distributed
  locator/store/lease contract passes restart and partition tests.
- MCP optional roots, sampling, elicitation, completion, and unsolicited
  server GET/SSE are not claimed merely because authentication is hardened.
- A2A push notifications are not enabled without callback SSRF policy,
  authentication/signing, retry/backoff, dedupe, and durable outbox behavior.
- Gemini Live remains a separate bidirectional session protocol; REST SSE is
  not presented as Live support.
