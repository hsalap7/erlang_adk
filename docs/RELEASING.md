# Releasing Erlang ADK

This is the maintainer checklist for preparing, approving, tagging, and
publishing a release. The commands below describe actions to take only after
their prerequisites and approvals are satisfied. This document does not claim
that `v0.7.0` has been tagged, pushed, or published.

## 1. Establish the release candidate

- [ ] Work from the intended release branch and record the candidate commit.
- [ ] Confirm the worktree contains only reviewed release changes.
- [ ] Confirm `src/erlang_adk.app.src`, the CLI/doctor output, the README, and
      `examples/phoenix_adk_ui/mix.exs` all use the intended version.
- [ ] Confirm `CHANGELOG.md`, the current version contract,
      `FEATURE_PARITY.md`, `README_EXAMPLE_COVERAGE.md`, `TESTING.md`, and
      `UPGRADING.md` agree with the implementation.
- [ ] Preserve both lock files and the Apache-2.0 license.
- [ ] Do not include `_build`, `Mnesia.*`, generated `doc`, crash dumps,
      Phoenix `_build`/`deps`, local certificates/keys, provider responses, or
      secrets.

Useful read-only checks:

```bash
git status --short
git diff --check
git diff --stat
git ls-files | rg '(^|/)(_build|deps|Mnesia\.|doc/|rebar3\.crashdump)'
rg -l --hidden \
  -g '!.git/**' \
  -g '!test/fixtures/mcp_test_key.pem' \
  '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AIza[0-9A-Za-z_-]{20,})' .
```

The last two commands should produce no release artifact or credential
matches. The excluded PEM is the documented public localhost MCP test key in
`test/fixtures`; it is not a deployment credential. Review filenames only and
use a dedicated secret scanner if the project's release process provides one.
Test placeholders are allowed; real credentials are not.

## 2. Use the verified toolchains

- Erlang/OTP 27.3.4.14 (minimum production patch and root pin).
- Elixir 1.17 or newer on OTP 27 (verified: 1.19.5).
- Node.js for Phoenix browser tests (verified: 24.3.0).
- The repository's `./rebar3`.

Record exact `erl`, `elixir`, `mix`, and `node` versions with the release
evidence.

## 3. Run the core deterministic and package gates

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
./rebar3 xref
./rebar3 eunit --module=readme_examples_test
./rebar3 eunit --module=readme_workflow_examples_test
./rebar3 ct --suite test/adk_concurrency_stress_SUITE.erl
./rebar3 ct --suite test/adk_v05_stress_SUITE.erl
./rebar3 escriptize
_build/default/bin/adk doctor
_build/default/bin/adk config validate examples/agent.json
./rebar3 ex_doc
./rebar3 hex build
./scripts/verify_hex_package.sh
```

For 0.7.0, compare against the evidence in [`TESTING.md`](TESTING.md): 1,077
EUnit tests, six deterministic Common Test cases, warning-free Dialyzer over
210 files, 29 README tests, four workflow tests, 193 focused v0.7 tests, and
both 1,000-operation stress suites.

Inspect generated documentation and the Hex tarball/file list. Confirm the
package contains core source, public headers, license, README, changelog,
guides, root examples, and the intentionally packaged Phoenix companion source;
it must exclude build/dependency caches, local data, generated Phoenix output,
credentials, and crash dumps. The verifier also compiles from a clean extracted
archive; inspect the generated docs landing page separately.

The root Rebar3 project currently has no `rebar3 hex audit` gate. Review
`rebar.lock` and upstream security advisories independently; do not claim that
the Phoenix Mix audit covers it.

## 4. Run the Phoenix release gate

```bash
cd examples/phoenix_adk_ui
mix deps.get
mix assets.setup
mix precommit
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
mix hex.audit
elixir ../../scripts/verify_phoenix_hex_audit.exs
../../scripts/smoke_phoenix_release.sh proxy 4101
../../scripts/smoke_phoenix_release.sh tls 4443
```

Expected deterministic evidence is 101 ExUnit tests, 31 browser/audio tests,
format and warning checks, production assets, and release assembly. Also boot
the assembled release on loopback in the test-only trusted-proxy and verified
direct-TLS configurations, require HTTP 200 from `/health`, and stop it
cleanly. Follow the exact deployment setup in the companion README.

`mix hex.audit` currently returns non-zero for EEF-CVE-2026-43969 and
EEF-CVE-2026-43966 in Cowlib 2.18.0. This is a known release exception, not a
pass. The wrapper must return zero only after matching that exact known set;
any new or missing finding fails so the exception and documentation are
reviewed. Before approval, the release owner must either:

- use an official dependency release that fixes both advisories and rerun the
  complete gate; or
- explicitly accept the documented temporary exception and its reachability
  controls in [`SECURITY.md`](../SECURITY.md).

Do not use the partial fork patch, remove the audit, or weaken TLS/header
validation merely to obtain a zero exit status.

## 5. Run opt-in provider gates

Use a release-owned test project and export the key in the same shell. These
commands use network access, quota, and billable API calls.

```bash
export GEMINI_API_KEY="your_api_key_here"
ERLANG_ADK_GEMINI_REST=1 ./rebar3 ct \
  --suite test/readme_live_gemini_SUITE.erl

ERLANG_ADK_GEMINI_LIVE=1 ./rebar3 ct \
  --suite test/gemini_live_SUITE.erl
```

The REST suite must use `gemini-3.1-flash-lite`; the Live suite must use
`gemini-3.1-flash-live-preview`. Record pass/fail/skip counts and structural
provider reasons without model content or secrets.

The final recorded 0.7 evidence is REST 15/17 with Search and context cache
failing on bounded HTTP 429 retries, and Live 5/5. A release owner may rerun
REST with sufficient quota to seek 17/17 or explicitly accept the two quota
results. A case that was skipped or rejected by the provider must never be
reported as passing implementation evidence.

## 6. Approve the release record

Before creating a tag, record:

- candidate commit and toolchain versions;
- deterministic core, focused, stress, CLI, docs, and package results;
- Phoenix format/compile/test/browser/assets/release/runtime results;
- paid REST and Live model, date, counts, and non-secret failure reasons;
- root dependency review and the exact `mix hex.audit` output/status;
- accepted known limitations, including node locality and partial adapters;
- secret-scan/package-content review; and
- the person or process accepting each security/provider exception.

Do not mark the release approved while version metadata or documentation is
stale, a deterministic gate fails, an unexplained test skips, or an advisory
has been hidden.

## 7. Commit, tag, and publish only after approval

Review and commit the release candidate using the repository's normal review
process. Verify the commit before tagging:

```bash
git status --short
git show --stat --oneline HEAD
```

Create the immutable tag only when the candidate commit is approved. Prefer a
signed tag where maintainer signing is configured; otherwise use an annotated
tag and preserve the external approval record:

```bash
git tag -s v0.7.0 -m "Erlang ADK 0.7.0"
# or, when signing is unavailable:
git tag -a v0.7.0 -m "Erlang ADK 0.7.0"
```

Verify the tag points to the approved commit, then push the branch/tag through
the repository's protected release process. Publication is a separate
credentialed action:

```bash
git show --no-patch --decorate v0.7.0
git push origin version_0.7.0
git push origin v0.7.0
./rebar3 hex publish
```

Do not run these commands from an unreviewed or dirty worktree. Never place a
Hex API key, Gemini key, OAuth secret, signing key, or package credential in a
command that will be logged.

## 8. Post-publication verification

- [ ] Verify the Git tag and release notes resolve to the approved commit.
- [ ] Download the published package in a clean environment and compile it on
      OTP 27.
- [ ] Verify generated API documentation and README/changelog links.
- [ ] Run a minimal deterministic agent/config smoke test from the package.
- [ ] Confirm advisories and accepted limitations are visible in the release
      notes.
- [ ] Retain the complete release evidence without credentials or model/user
      content.

If a package or tag is wrong, do not move an existing public tag or silently
replace an immutable package. Publish a corrective version and document the
superseded artifact. If credentials or sensitive data escaped, rotate/revoke
them immediately and follow the private security process.
