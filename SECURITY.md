# Security policy

Erlang ADK handles model credentials, user identity, tool credentials,
browser sessions, protocol traffic, and potentially sensitive agent content.
Security reports are welcome and should be handled privately.

## Supported versions

| Version | Security support |
| --- | --- |
| 0.8.x | Current supported release line |
| 0.7.x | Previous release line; upgrade to 0.8.x for provider-profile and transport hardening |
| 0.3.x-0.6.x | Historical development milestones; upgrade to 0.8.x |
| Earlier | Unsupported |

The repository may contain development branches for older milestones. A
branch name or historical contract is not a promise of continuing security
updates.

## Reporting a vulnerability

Use the repository's private **Report a vulnerability** flow under
[GitHub Security Advisories](https://github.com/hsalap7/erlang_adk/security/advisories/new).
Do not open a public issue containing an exploit, credential, private endpoint,
personal data, prompt/session content, or an unredacted crash dump.
If private reporting is not enabled, contact a maintainer through their GitHub
profile with only a request for a private channel; do not include vulnerability
details in that public contact.

Include, when possible:

- the affected Erlang ADK version or commit;
- the reachable component and deployment topology;
- a minimal reproduction using fake credentials and synthetic content;
- impact, required privileges, and whether the issue crosses a principal,
  app, user, session, run, or node boundary;
- logs reduced to structural errors, with tokens and content removed; and
- a proposed mitigation or patch, if one is available.

Maintainers will validate the report, coordinate a fix and disclosure, and
credit reporters who want attribution. Response and release timing depends on
severity, reproducibility, upstream dependencies, and maintainer availability;
this project does not promise a fixed public SLA.

## Security model

The release relies on these invariants:

- Provider, OAuth/OIDC, tool, and protocol credentials remain server-side and
  never enter prompts, ordinary state, browser assigns, public events,
  telemetry metadata, evaluation input, or structural errors.
- Public model selection uses bounded binary profile/model aliases. Adapter
  modules, concrete model IDs, endpoints, API-version/auth/storage/billing
  settings, transports, and credential sources are operator-owned; credential
  lookup is bound to the selected profile generation. Custom request origins
  are structured HTTPS,
  redirects are disabled, and ambient native-vendor keys are accepted only at
  their exact official origin.
- Authentication proves an issuer-bound identity. A separate default-deny
  authorizer checks each exact operation and resource. Authentication alone
  does not grant agent, run, Live, observability, or evaluation access.
- One invocation or Live session is one independently supervised process with
  explicit deadlines, admission, byte/count limits, cancellation, and owner
  cleanup. Browser or subscriber lifetime does not implicitly own the run or
  model session.
- Public listeners are opt-in. Public A2A and production Phoenix deployments
  require an authenticated TLS boundary. The Erlang `/dev` service and
  Phoenix local authentication are development facilities, not public
  production identity systems.
- Untrusted JSON, tool arguments, model calls, protocol headers, media, and
  callback results are validated and bounded before a side effect.
- Model Gun transports cap each aggregate response-header or trailer block at
  64 KiB in both synchronous and streaming paths.
- Native Anthropic requests reject `max_tokens` values below one before
  transport admission.
- A Live action's admitted multi-frame provider batch remains contiguous once
  sending starts; a later priority action cannot splice into its side effects.
- Dynamic untrusted names are not converted into atoms. Application modules,
  provider profiles, evaluator modules, filesystem roots, and credential
  resolvers come from trusted server configuration, never browser input.

The detailed runtime rules are in
[`docs/RUNTIME_SAFETY.md`](docs/RUNTIME_SAFETY.md), model selection and
credential authority are documented in
[`docs/PROVIDER_PROFILES.md`](docs/PROVIDER_PROFILES.md), and the production web
boundary is documented in the
[`Phoenix companion guide`](examples/phoenix_adk_ui/README.md).

## Runtime security baseline

Version 0.8 requires Erlang/OTP 27.3.4.14 or a later security-supported OTP
release. In particular, OTP 27.3.4.14 carries SSL 11.2.12.10, which fixes
[CVE-2026-54891](https://cna.erlef.org/cves/CVE-2026-54891.html), a TLS-client
plaintext-injection vulnerability affecting earlier OTP 27 patch levels. This
project is a TLS client for Gemini, OIDC, MCP, OpenAPI, A2A, and OTLP, so the
fix is part of the production baseline rather than an optional tooling update.
The root and Phoenix `.tool-versions`, application metadata, and release CI pin
that exact patch level.

## Known dependency advisories

As of 2026-07-15, both `rebar.lock` and the Phoenix companion's `mix.lock`
resolve Cowlib 2.18.0. Running `mix hex.audit` in the companion reports two
unresolved advisories:

- [EEF-CVE-2026-43969](https://cna.erlef.org/osv/EEF-CVE-2026-43969.json)
  (also GHSA-g2wm-735q-3f56), a low-severity cookie request-header injection
  issue involving unvalidated `cow_cookie:cookie/1` input; and
- [EEF-CVE-2026-43966](https://cna.erlef.org/osv/EEF-CVE-2026-43966.json), a
  medium-severity HTTP response-splitting issue involving non-VCHAR input to
  Cowlib's structured-header escaping helper.

Cowlib 2.18.0 is still the latest official release on that date, and neither
advisory has an official fixed release. A preliminary fork patch addresses
only EEF-CVE-2026-43969 and is therefore not a complete replacement.

The checked companion does not configure Gun's cookie store. Locked Cowboy
2.17.0 and Gun 2.4.1 use their invalid-header rejection defaults, and the
application validates and bounds browser/provider inputs before constructing
responses. These controls reduce known reachability; they do **not** remove
the vulnerable Cowlib routines, make the audit pass, or justify disabling
TLS/header validation.

Until an official release resolves both advisories:

1. keep both lock files committed and run `mix hex.audit` for every release;
2. record the non-zero result as a release exception, not a pass;
3. run `scripts/verify_phoenix_hex_audit.exs`, whose exact two-advisory
   allowlist fails if a new advisory appears or the exception becomes stale;
4. avoid adding an application path that sends untrusted cookie values to
   `cow_cookie:cookie/1` or unvalidated bytes to Cowlib response-header
   builders;
5. limit exposure with authenticated TLS, exact origins, bounded headers and
   bodies, and a trusted reverse proxy when one is used; and
6. upgrade only to an official dependency set that resolves both findings,
   then rerun all Erlang, Phoenix, browser, TLS, and release gates.

The root project uses Rebar3 and the installed `rebar3_hex` has no
`rebar3 hex audit` command. The Mix command does not mechanically scan
`rebar.lock`, but a separate lock review confirms that the root carries the
same Cowlib version and exception. Treat the advisory as core exposure as well
as a Phoenix dependency finding.

Phoenix LiveView is temporarily pinned to upstream commit
`86165533e311469a1b62093fd182d9d874de8106`, the official fix used for
CVE-2026-58228. Keep that pin until a fixed Hex release at or above 1.2.7 is
available and passes the complete companion gate.

## Deployment checklist

Before exposing Erlang ADK or the Phoenix companion:

- load API keys, client secrets, cookie secrets, TLS keys, and credential
  provider configuration from deployment-owned secret storage;
- use external OIDC or another deployment-owned production identity system;
  reject `ADK_UI_LOCAL_AUTH` in production;
- expose neither `/dev` nor its bearer token as an end-user API;
- keep the legacy unauthenticated `/a2a/prompt` endpoint on its enforced
  loopback listener; use authenticated A2A v1 for any public integration;
- use verified direct TLS, or bind the HTTP listener so only a trusted TLS
  terminator can reach it and have that terminator overwrite forwarded
  headers;
- configure exact origins, hosts, callback URIs, audiences, algorithms, and
  scopes; never accept these from browser input;
- preserve secure, HttpOnly, SameSite session cookies, CSRF protection, CSP,
  HSTS, and request/body limits;
- keep model/media/tool/content capture disabled in observability unless a
  documented policy explicitly permits bounded capture;
- use durable encrypted credential and data adapters appropriate to the
  deployment; ETS reference implementations are not encrypted-at-rest
  production stores; and
- account for node-local sessions, runs, A2A tasks, and Live lookup. Use one
  node or sticky affinity for the complete lifetime unless an authenticated
  distributed router/store has been implemented and tested.

## Secret hygiene

Never commit `GEMINI_API_KEY`, OAuth client secrets, access/refresh tokens,
cookie signing/encryption material, TLS private keys, provider cache resource
names, Live resumption handles, or real user/session content. Test fixtures
must use synthetic values. When sharing failures, prefer structural reason
atoms/maps and remove provider bodies, headers, prompts, media, and paths.

If a secret may have entered Git history, logs, a package, a release artifact,
or a browser session, revoke or rotate it first. Removing the visible file is
not sufficient remediation.
