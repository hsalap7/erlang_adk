# Contributing to Erlang ADK

Thank you for improving Erlang ADK. Contributions should preserve the
project's observable ADK behavior while using Erlang/OTP supervision,
lightweight processes, monitors, message passing, and explicit bounds rather
than copying another SDK's class structure.

## Toolchains

Core development uses Erlang/OTP 27. The checked root `.tool-versions` pins
OTP 27.3.4.14, the minimum supported production patch level, and the repository
includes `./rebar3`.

The optional Phoenix companion requires:

- Erlang/OTP 27;
- Elixir 1.17 or newer (verified with Elixir 1.19.5 on OTP 27); and
- Node.js (verified with 24.3.0) for the dependency-free browser tests.

Its checked `.tool-versions` records the verified Erlang, Elixir, and Node
versions.

## Source organization

Production modules use one recursive `src` root. Keep public Erlang module
names globally unique and place new implementations according to the ownership
map in [`src/README.md`](src/README.md). Do not add overlapping nested
`src_dirs`; Rebar3 must discover each source file exactly once. Tests mirror
the same ownership hierarchy under the test-profile-only recursive root
documented in [`docs/TEST_LAYOUT.md`](docs/TEST_LAYOUT.md); do not add
overlapping test source roots.

Moving a source file between feature directories must not rename its module or
silently change its API. Use application include paths such as
`-include("adk_event.hrl")` instead of a path relative to the current source
depth, and update the Hex package verifier when a new required subsystem is
introduced.

## Set up the core project

```bash
./rebar3 compile
./rebar3 eunit
./rebar3 ct
./rebar3 dialyzer
```

The canonical clean gate is:

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
```

Run the aggregate Erlang coverage gate before submitting behavior changes:

```bash
./scripts/coverage.sh
```

It resets stale exports, combines EUnit and Common Test coverage, and enforces
the repository's deterministic 74% floor.

Without provider opt-in flags, the billable Gemini Common Test cases are
expected to skip. A skip is not a pass and does not replace deterministic
adapter, codec, lifecycle, concurrency, or security coverage.

See [`docs/TESTING.md`](docs/TESTING.md) for focused suites, provider gates,
packaging, and the current expected evidence.

## Set up the Phoenix companion

```bash
cd examples/phoenix_adk_ui
mix setup
mix precommit
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
mix hex.audit
```

`mix precommit` checks formatting, warnings-as-errors compilation, browser
assets/tests, and ExUnit. `mix hex.audit` currently exits non-zero for the two
documented Cowlib 2.18.0 advisories. Preserve and report that result; do not
disable the audit or call it passing. See [`SECURITY.md`](SECURITY.md).

For local UI work without an external identity provider, use
`ADK_UI_LOCAL_AUTH=true` only with `MIX_ENV=dev` and the exact loopback URL
documented in the companion README. Do not weaken the production OIDC, CSRF,
origin, cookie, or TLS path to simplify a local test.

## Design requirements

Public runtime changes should follow these rules:

1. Keep reusable agent definitions separate from invocation state. Blocking
   provider/tool work belongs in supervised workers, not the agent mailbox.
2. Make ownership and lifetime explicit. Monitor callers/owners, use absolute
   deadlines, and clean up workers, queue entries, leases, and credentials on
   cancellation, timeout, or process death.
3. Bound queues, messages, bytes, counts, recursion, retries, replay, heap,
   and concurrency. Overload and unsupported behavior must fail structurally.
4. Preserve deterministic ordering where the API promises it while allowing
   independent agents, sessions, scopes, workflow branches, and plugin
   instances to overlap.
5. Validate model/provider/protocol output before callbacks, credential
   lookup, confirmation, state mutation, or external side effects.
6. Keep credentials and sensitive content out of state, events, telemetry,
   logs, browser assigns, errors, crash terms, reports, and test output.
7. Avoid dynamic atoms and caller-selected modules, PIDs, paths, providers,
   transports, credential references, or evaluator implementations.
8. Do not silently simulate an unavailable provider feature. Capability
   discovery and errors must distinguish implemented, partial, adapter-owned,
   and unsupported behavior.

## Tests and documentation

Every public behavior change needs proportionate evidence:

- success and structural failure cases;
- timeout, cancellation, caller/owner death, and worker-crash cleanup;
- scope/principal isolation and secret-redaction cases;
- concurrency ordering, overlap, overload, and bounded-mailbox behavior;
- protocol fixtures or exact provider-wire assertions when applicable; and
- Dialyzer-compatible contracts.

Update the root README and the relevant guide in the same change. Every new
README code fence must be classified and mapped to exact validation in
[`docs/README_EXAMPLE_COVERAGE.md`](docs/README_EXAMPLE_COVERAGE.md). Use the
status vocabulary in [`docs/FEATURE_PARITY.md`](docs/FEATURE_PARITY.md): an API
is not “implemented” until its documented behavior and failure contract pass.

Provider tests use separate, explicit models:

- REST GenerateContent/SSE: `gemini-3.1-flash-lite`;
- Gemini Live WebSocket: `gemini-3.1-flash-live-preview`.

Do not substitute the REST model into Live or describe REST SSE as Live.

## Pull-request checklist

- [ ] The change is scoped and its public compatibility impact is explained.
- [ ] New work uses OTP supervision/process isolation and explicit bounds.
- [ ] Failure terms, authorization, cancellation, and cleanup are tested.
- [ ] No secret or real user/model content is present in code, fixtures, logs,
      generated artifacts, or the diff.
- [ ] `./rebar3 do clean, compile, eunit, ct, dialyzer` passes.
- [ ] `./scripts/coverage.sh` passes without lowering the coverage floor.
- [ ] README examples and focused tests pass.
- [ ] Phoenix `mix precommit` and production assets/release pass when the
      companion is affected.
- [ ] Relevant dependency audits were run and non-zero findings are recorded.
- [ ] Paid provider suites were run when provider behavior changed, or the
      reason they were not run is explicit. Provider failures are not
      rewritten as skips or deterministic passes.
- [ ] Documentation, the feature-parity inventory, example ledger, and
      changelog agree with the code.

Do not commit `_build`, `Mnesia.*`, generated `doc`, crash dumps, provider
responses, secrets, local certificates/keys, or Phoenix build output.
