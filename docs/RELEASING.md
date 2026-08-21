# Releasing Erlang ADK

This is the maintainer checklist for preparing, approving, tagging, and
publishing a release. The commands below describe actions to take only after
their prerequisites and approvals are satisfied. The v0.9.0 release status and
evidence are recorded in [`VERSION_0_9_0.md`](VERSION_0_9_0.md) and the
[`CHANGELOG`](../CHANGELOG.md); running this checklist does not publish a later
release by itself. Version 0.10.0 is currently **IN DEVELOPMENT**; its scope
and candidate ledger are in
[`VERSION_0_10_0.md`](VERSION_0_10_0.md).

## 1. Establish the release candidate

- [ ] Work from the intended release branch and record the candidate commit.
- [ ] Confirm the worktree contains only reviewed release changes.
- [ ] Confirm `src/erlang_adk.app.src`, the CLI/doctor output, the README, and
      `examples/phoenix_adk_ui/mix.exs` all use the intended version.
- [ ] Confirm `CHANGELOG.md`, the current version contract,
      `FEATURE_PARITY.md`, `PROVIDER_PROFILES.md`,
      `README_EXAMPLE_COVERAGE.md`, `TESTING.md`, and `UPGRADING.md` agree
      with the implementation.
- [ ] For 0.10, confirm the release contract no longer says **IN DEVELOPMENT**
      only after every required result has been recorded from this exact
      candidate. Focused tests alone are insufficient.
- [ ] Preserve both lock files and the Apache-2.0 license.
- [ ] Validate the release's model `provider_profiles` with
      `adk_provider_registry:profiles/0`; review binary aliases, concrete
      models, endpoint presets/HTTPS hosts, locked options, and credential
      source descriptors. Do not place a literal production credential in
      version-controlled configuration.
- [ ] Validate `agent_config_registry` definitions and record the compiled
      registry's opaque instance ID, snapshot revision ID, and generation.
      Confirm structural copies with changed trusted entries fail the internal
      seal check and that diagnostics/fingerprints do not expose the seal.
      Confirm direct Agent Config `tools` modules remain disabled unless a
      reviewed trusted caller explicitly needs the legacy opt-in; review the
      separate legacy-provider-module opt-in the same way. Also validate the
      opt-in
      `runtime_service_profile`, evaluation-service/store, and trace-store
      application environment. Review fixed Mnesia table atoms, the absolute
      durable artifact root, capacity/retention limits, trace principal and
      store/bus names, the reserved trace exporter ID, evaluation
      baseline-prune/accounting-repair policy, canonical single-service eval
      store ownership, bounded raw-submission behavior, workflow-owner-bound
      trace receiver TTL/status, and ownership of any persistent directories.
- [ ] Run `adk serve --config` with conflicting agent and operator Runner
      options. Confirm trusted `dev_runner_options` win and an enabled runtime
      profile remains authoritative for artifact/memory service references.
- [ ] Review any GCS artifact credential/transport boundary, range/credit
      limits, effect-journal retention, and the operator/backend-specific
      orphan-reconciliation policy. Confirm the runtime does not claim to
      infer remote outcomes or supervise a universal reconciler.
- [ ] Review memory embedding/vector bounds, opt-in policy enforcement,
      erasure-epoch/outbox four-table topology, deterministic registry hydration,
      identity-filtered rotating claim bounds, and explicit indexed terminal-
      prune policy. Verify active jobs reserve terminal capacity, over-cap
      migration is admission-closed, epoch-bound IDs permit post-erasure
      resubmission, legacy named APIs select the one bundle owner, nested
      options/capabilities fail closed, and status is redacted. Majority mode
      requires at least two shared nodes; do not infer managed/distributed
      vector search or node-loss recovery.
- [ ] Verify every evaluation report surface uses the canonical renderer and
      one maximum of 16 MiB. Check `dev_evaluation_report_max_bytes` can only
      lower the report route, unrelated CLI responses remain 1 MiB, request
      bodies remain 64 KiB, and stdout/file deliveries enforce the same bytes.
- [ ] Pin each MCP peer to an intended legacy or modern era and review OAuth,
      pool, SSE-credit, and catalog limits. Record the external SDK matrix only
      if it ran. Likewise review A2A task-store topology and process-local push
      secrets/drop-new queue behavior; record the external TCK only if it ran.
- [ ] Keep provider payload inspection disabled unless the release owner has
      explicitly accepted the loopback-only, redacted, bounded, volatile,
      failure-open development contract. It is not production telemetry or an
      audit log.
- [ ] Review deployment manifests/scripts as render-first inputs. Record
      Docker runtime, Cloud Run staging, Helm/Kind/GKE, scan/sign/provenance,
      and managed Agent Runtime separately; deterministic rendering is not a
      successful infrastructure gate.
- [ ] Verify the packaged `etc/health-http.sys.config.src` is selected through
      the exact relx base path
      `/opt/erlang_adk/etc/health-http.sys.config`, including a nondefault
      platform `PORT`. Confirm the default listener serves only `/livez` and
      `/readyz`, with agent/A2A/developer/legacy routes absent. For a Helm
      `runtimeConfig.existingConfigMap`, require the exact `sys.config` key at
      `/opt/erlang_adk/etc/runtime/sys.config` and review every listener it
      enables. Record which of the three modes is intended: closed base
      release, packaged health-only profile, or application-owned config.
- [ ] For Cloud Run, verify both the Service and revision template carry the
      rendered one-instance maximum. Treat these as autoscaling settings, not
      a hard singleton lease or proof that rollout revisions cannot overlap.
- [ ] Verify `ERLANG_ADK_NOFILE_CAP` defaults to 65536, rejects values outside
      1024..1048576, and never raises inherited limits. Exercise the single
      PID1-owned drain/forward/reap path without a second Helm `preStop`; check
      the 30000 ms generic/Helm budget within 60 seconds and the 3000 ms Cloud
      Run budget within its platform shutdown window.
- [ ] When deployment OTLP is enabled, confirm only
      `ERLANG_ADK_OTLP_ENDPOINT` activates it; exercise bounded
      W3C-Baggage-style header parsing, optional-whitespace trimming, strict
      one-pass value percent decoding, raw-semicolon/invalid-UTF-8/duplicate/
      malformed rejection, origin-only endpoint, and redacted startup
      failures. Confirm batch size is one and preserve the 3000 ms HTTP/4000 ms
      exporter bounds under a bus timeout greater than the sum of every final
      exporter timeout plus 250 ms. Confirm trace-store export is included
      before validation, an absent timeout is safely auto-sized, and an
      explicit undersized timeout fails. Source headers from an existing
      Secret and review collector egress.
- [ ] If the managed Agent Runtime feasibility probe is reviewed, confirm it
      calls only `ListTasks`, reads a bounded RFC 6750 bearer exactly from the
      named environment variable, rejects CR/LF, and sends the Authorization
      header through curl standard-input config rather than a process
      argument. Keep every target-runtime support blocker unresolved until its
      external exit evidence exists.
- [ ] Do not include `_build`, `Mnesia.*`, generated `doc`, crash dumps,
      Phoenix `_build`/`deps`, local certificates/keys, provider responses, or
      secrets.

Useful read-only checks:

```bash
git status --short
git diff --check
git diff --stat
git ls-files | grep -E '(^|/)(_build|deps|Mnesia\.|doc/|rebar3\.crashdump)'
find . -type f \
  ! -path './.git/*' \
  ! -path './test/fixtures/mcp_test_key.pem' \
  -exec grep -E -l \
  '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AIza[0-9A-Za-z_-]{20,})' {} +
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
./scripts/coverage.sh
./rebar3 xref
./rebar3 eunit --module=readme_examples_test
./rebar3 eunit --module=readme_workflow_examples_test
# Run every grouped v0.10 EUnit/CT command in docs/TESTING.md.
./rebar3 ct --suite test/runtime/invocations/adk_concurrency_stress_SUITE.erl
./rebar3 ct --suite test/integrations/stress/adk_v05_stress_SUITE.erl
./rebar3 escriptize
_build/default/bin/adk doctor
_build/default/bin/adk config validate examples/agent.json
./rebar3 ex_doc
./rebar3 hex build
./scripts/verify_hex_package.sh
packages/build_connector_packages.sh
```

`packages/build_connector_packages.sh` is the sole supported offline release
gate for all four curated connectors. It validates each independent package,
warning-strict compiles/tests its source, internally normalizes the generated
Hex inspection archive, checks for checkout leakage and the non-optional
`erlang_adk ~> 0.10.0` requirement, then warning-strict compiles/tests a clean
extraction. Its package suites must execute every advertised operation through
the real registry, Agent Config, and `adk_toolset` path and verify projected
policy metadata. Do not inspect or retain the intermediate raw `rebar3_hex` tarball:
the package-local `_checkouts/erlang_adk` used for tests is intentionally
omitted from generated requirements. See the
[connector package guide](../packages/README.md) for the normalization
internals.

The wrapper's normalized tarball is an offline inspection/build artifact only.
`rebar3_hex` 7.1.0 rebuilds during `hex publish` and cannot upload that archive.
A future connector publication must wait until core Erlang ADK 0.10.0 exists
in the target Hex repository, remove the local checkout, resolve and lock that
published core afresh, run the ordinary credentialed publish flow, and verify
the remote package's requirement afterward. Until that separate sequence is
recorded, Google, GitHub, Slack, and Postgres connectors remain unpublished.

The 1,176 EUnit, six deterministic Common Test, 73.88% coverage, 210-file
Dialyzer, 29 README, four workflow, and 193 focused totals in
[`TESTING.md`](TESTING.md) are historical v0.7 evidence. The recorded
2026-07-17 v0.8 gate passed 1,414 EUnit tests, six deterministic Common Test
cases, Dialyzer over 235 source modules with no warnings, 74.17% line coverage, 244/244
focused provider/profile/Realtime tests, 30 README plus four workflow tests,
and warning-as-error compilation of all three example modules. Common Test
intentionally skipped 22 paid cases in the deterministic command. Do not
approve a later candidate by copying either release's numbers or by running
only the focused modules.

The released v0.9.0 deterministic validation compiled 242 production and 271
test modules with `-Werror`, passed all 1,495 EUnit tests and all 6 Common Test
cases, and completed with 0 Dialyzer warnings and 0 undefined or deprecated
call/function findings from `./rebar3 xref`. Its Phoenix companion passed
103 ExUnit and 40 browser/audio tests, production assets/release, and both
health smokes. Coverage, package, escript/doctor, and paid-provider evidence
remains separately bounded in [`VERSION_0_9_0.md`](VERSION_0_9_0.md).

Current 0.10 evidence applies to the named `codex/version_0.10.0` working-tree
candidate. HEAD `78f31fd6b72295ebeb37cecbd7c11a6c5a666b34` is the v0.9 baseline;
all v0.10 changes remain uncommitted, so no reproducible commit/tag is claimed.
Both non-coverage and coverage EUnit passed 1,826/1,826; deterministic Common
Test passed 6 with 22 expected paid-provider skips. Compile/xref passed,
Dialyzer reported 0 warnings over 309 project files, and coverage was
36,574/49,312 = 74.17% (83 covered lines over the exact floor). Focused
durable-runtime validation passed 46/46 EUnit, and canonical evaluation-report
parity/boundary validation passed 56 tests. Escript, doctor, and checked config
validation passed. README EUnit passed 30/30 plus 4/4, all three checked
examples compiled with `-Werror`, and ExDoc, local Markdown, root Hex/verifier/
extracted compile, and diff gates passed. Root artifact hashes/freshness are
reported out of band so packaged documentation is not self-referential.
The sole connector wrapper passed 4 packages, 12/12 source EUnit, 12/12 clean-
extracted EUnit, and 4 package plus 4 docs archives. Exact toolchain, hashes,
and scoped not-run gates are in the
[`0.10 development ledger`](VERSION_0_10_0.md#development-validation-ledger).
The grouped focused commands in [`TESTING.md`](TESTING.md) remain subsystem
diagnostics and cannot replace that aggregate.

The seven-module post-audit repair regression set passed 67/67, covering
contiguous in-flight multi-frame priority ordering, Anthropic's minimum
`max_tokens` value of one, and the 64 KiB synchronous/streaming Gun
header/trailer cap.

The same v0.8 record includes passing xref, escript, doctor 0.8.0, checked
configuration validation, ExDoc, Hex 0.8.0 build, and extracted-package
compilation verification.

Inspect generated documentation and the Hex tarball/file list. Confirm the
package contains core source, public headers, license, README, changelog,
the provider-profile/version guides (including `VERSION_0_10_0.md`), root
examples, and the intentionally
packaged Phoenix companion source;
it must exclude the test source tree, build/dependency caches, local data,
generated Phoenix output, credentials, and crash dumps. The verifier enforces
that boundary and also compiles from a clean extracted archive; inspect the
generated docs landing page separately.

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

The 101 ExUnit and 31 browser/audio test totals are historical v0.7 evidence.
The recorded 2026-07-17 v0.8 `mix precommit` gate passed 103 ExUnit and 40 Node
tests, including negotiated 16/24 kHz voice assertions. Production assets and
release assembly passed, and the assembled release passed both the test-only
trusted-proxy and verified direct-TLS loopback smokes. Each smoke required HTTP
200 from `/health` and clean shutdown. Follow the exact deployment setup in
the companion README.

The v0.9.0 companion repeated that complete gate successfully with the patched
dependency locks: 103 ExUnit tests, 40 browser/audio tests, production assets,
release assembly, and both health smokes passed.

The merged v0.10 development candidate passed 107 ExUnit and 40 Node tests,
production assets/release, and both trusted-proxy and CA-verified direct-TLS
health smokes. Live registry access failed with `Unknown CA`, so this records
the cached locked gate and does not claim a fresh registry fetch.

The v0.9.0 dependency refresh moved Bandit to 1.12.4, Cowboy to 2.18.0, and
Cowlib to 2.19.0, removing EEF-CVE-2026-65623, EEF-CVE-2026-65624, and
EEF-CVE-2026-59248 from the audit. `mix hex.audit` remains non-zero for
EEF-CVE-2026-43969 and EEF-CVE-2026-43966 in Cowlib; Gun repeats the latter as
GHSA-w4f7-4cxr-rv3c. This is a known release exception, not a pass. The wrapper
must return zero only after matching those exact three package findings; any
new or missing finding fails so the exception and documentation are reviewed.
Before approval, the release owner must either:

- use an official dependency release that fixes both advisories and rerun the
  complete gate; or
- explicitly accept the documented temporary exception and its reachability
  controls in [`SECURITY.md`](../SECURITY.md).

Do not use the partial fork patch, remove the audit, or weaken TLS/header
validation merely to obtain a zero exit status.

## 5. Run opt-in provider and external-platform gates

Use a release-owned test project and export the key in the same shell. These
commands use network access, quota, and billable API calls.

```bash
export GEMINI_API_KEY="your_api_key_here"
ERLANG_ADK_GEMINI_REST=1 ./rebar3 ct \
  --suite test/readme/readme_live_gemini_SUITE.erl

ERLANG_ADK_GEMINI_LIVE=1 ./rebar3 ct \
  --suite test/models/gemini/gemini_live_SUITE.erl
```

The REST suite must use `gemini-3.1-flash-lite`; the Live suite must use
`gemini-3.1-flash-live-preview`. Record pass/fail/skip counts and structural
provider reasons without model content or secrets.

The final recorded 0.7 evidence is REST 15/17 with Search and context cache
failing on bounded HTTP 429 retries, and Live 5/5. That evidence is historical
and does not replace a fresh provider run for a later candidate. A release
owner may explicitly accept a provider/quota result, but a skipped or rejected
case must never be reported as passing implementation evidence.

The 2026-07-17 v0.8 REST attempt reached Google, but HTTP 401
`UNAUTHENTICATED` / `ACCESS_TOKEN_TYPE_UNSUPPORTED` rejected the configured
credential shape. This is external credential evidence, not a pass, skip, or
product regression. No v0.8 paid Gemini Live pass is recorded; deterministic
Live broker/transport coverage must not be described as remote-provider
success.

There is currently no first-party paid Common Test suite for OpenAI Responses,
OpenAI Realtime, Anthropic Messages, or an arbitrary compatible endpoint. The
release record must describe their deterministic injected-transport/codec
evidence accurately and must not infer paid-provider success from configured
environment variables. If the release owner runs a manual smoke, record it as
separate provider evidence without prompts, outputs, or credentials. Each
compatible endpoint is a distinct target, not a blanket certification.

The following 0.10 boundaries also need distinct external evidence when a
release intends to claim them:

- an MCP SDK/peer matrix for every advertised legacy/modern transport and
  deployed peer beyond the recorded official Python/TypeScript client cells;
- the deployment's authenticated A2A HTTPS peer and push receiver beyond the
  recorded official JSON-RPC TCK;
- multi-node node-loss and restore tests for every claimed Mnesia topology;
- a release-candidate OCI repeat using the promoted image digest and registry;
- Cloud Run staging and Helm on Kind/GKE with the exact rendered image digest;
- actual SBOM generation, scan policy, signature, and provenance verification;
  and
- any managed Agent Runtime target.

The 2026-08-19 candidate record contains the pinned official MCP
Python/TypeScript 2.0.0 modern/legacy matrix and official A2A JSON-RPC TCK. The
latter passed 100 tests with 165 expected transport/capability skips, including
94 JSON-RPC passes and seven inapplicable JSON-RPC skips. Treat those as the
exact loopback scopes recorded in `VERSION_0_10_0.md`, not as substitutes for
the remaining peer, identity, push, transport, or infrastructure gates.

The repository records a final local candidate OCI/Kind gate. The image digest
and constrained direct/Helm resource, health, route, drain, and termination
results are in `VERSION_0_10_0.md`. The disposable cluster covered the
closed/headless and packaged health-only modes, not an application-owned
`sys.config`, GKE, Cloud Run, or registry promotion. Generated SBOM, Grype scan,
Cosign sign/attest, and provenance verification remain not run because those
tools were unavailable and no registry identity was authorized. Keep every
remaining entry `not run` until its owning external command finishes
successfully; local fixtures, manifest marker validation, feasibility probes,
and package-local connector tests cannot be substituted.

## 6. Approve the release record

Before creating a tag, record:

- candidate commit and toolchain versions;
- deterministic core, focused, stress, CLI, docs, and package results;
- Phoenix format/compile/test/browser/assets/release/runtime results;
- paid REST and Live model, date, counts, and non-secret failure reasons;
- root dependency review and the exact `mix hex.audit` output/status;
- accepted known limitations, including node locality and partial adapters;
- for 0.10, runtime bundle generation/fail-stop/lease behavior; Agent Config
  v2 JSON/YAML/composition and registry provenance; connector authorization
  boundaries; artifact GCS/stream/reconciliation policy; memory vector/
  governance/erasure/prune policy; MCP era/OAuth/pool/catalog status; A2A
  stream/task-store/push restart behavior; evaluation quota/simulator/export/
  RPC/recovery policy; trace and developer-payload boundaries; and deployment
  render/apply evidence with all configured limits;
- exact pass/failure/skip scope for the recorded MCP SDK matrix and A2A TCK,
  plus explicit `not run`, pass, or failure status for node-loss, Docker,
  Cloud Run, Helm/Kind/GKE, supply-chain, and managed-runtime gates;
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
git tag -s v0.10.0 -m "Erlang ADK 0.10.0"
# or, when signing is unavailable:
git tag -a v0.10.0 -m "Erlang ADK 0.10.0"
```

Verify the tag points to the approved commit, then push the branch/tag through
the repository's protected release process. Publication is a separate
credentialed action:

```bash
git show --no-patch --decorate v0.10.0
git push origin version_0.10.0
git push origin v0.10.0
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
