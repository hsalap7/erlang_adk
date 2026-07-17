# Testing Erlang ADK

This guide defines the release gates and how to interpret them. Run commands
from the repository root unless a section changes directory.

## Toolchains

- Core: Erlang/OTP 27; the verified and minimum production patch is OTP
  27.3.4.14.
- Phoenix: Elixir 1.17 or newer on OTP 27; verified with Elixir 1.19.5.
- Browser assets/tests: Node.js; verified with Node 24.3.0.
- Use the repository's `./rebar3` for core commands.

## Test source organization

Erlang tests mirror the production ownership hierarchy under `test/`; the
complete map and placement rules are in [`TEST_LAYOUT.md`](TEST_LAYOUT.md).
The recursive test root is enabled only in Rebar3's `test` profile, so EUnit
and Common Test discover nested modules while ordinary builds and packages do
not compile test helpers.  Explicit Common Test commands must use each suite's
full path; EUnit module selection remains path-independent.

## Complete deterministic Erlang gate

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
```

The final 2026-07-16 v0.7 run passed:

- 1,176 EUnit tests;
- six deterministic Common Test cases;
- Dialyzer over 210 project files with no warnings; and
- both 1,000-operation concurrency/resource stress scenarios.

Those are historical v0.7 numbers, not v0.8 evidence.

The final 2026-07-17 v0.8 command exited zero and passed:

- 1,414 EUnit tests;
- six deterministic Common Test cases; and
- Dialyzer analysis over 235 source modules with no warnings.

Common Test intentionally skipped 22 paid-provider cases because their opt-in
flags were absent from this deterministic command. Those skips are expected
and are not included in the six passing deterministic cases.

Some HTTP and protocol fixtures open loopback listeners. A restricted build
environment must allow local sockets; otherwise a permission failure is an
environment failure, not passing test evidence.

## Deterministic line coverage gate

```bash
./scripts/coverage.sh
```

The script resets all previously exported Cover data, performs a clean build,
instruments the complete EUnit and Common Test suites, aggregates both exports,
and fails below 74% executable-line coverage. The HTML summary and per-module
reports are written under `_build/test/cover/`. Do not run `rebar3 cover`
against exports from an earlier source tree: `rebar3 clean` does not remove
stale Cover data.

`./rebar3 cover --verbose` only aggregates previously exported `.coverdata`;
it does not execute or instrument tests. Therefore `No coverdata found` is the
expected result on a clean tree or immediately after `cover --reset`. Use
`./scripts/coverage.sh` to produce both the EUnit and Common Test exports before
rendering the report.

Paid Gemini cases remain explicitly skipped without their opt-in flags, and
Phoenix/ExUnit coverage is a separate project concern. The 74% floor therefore
measures the deterministic Erlang release contract only; it must be raised as
new deterministic behavior becomes covered and must not be weakened to hide a
regression. The final 2026-07-16 aggregate is 73.88% across 210 production
modules. That is historical v0.7 evidence. The final 2026-07-17 v0.8 coverage
script exited zero at 74.17% against the enforced 74% floor, while repeating
1,414 EUnit and six deterministic Common Test passes.

## Path to 100% deterministic coverage

Coverage work must protect behavior, not optimize a number. Add tests for
supported feature and contract branches first: documented public API
preservation, structural failure/cancellation paths, concurrency ownership and
cleanup, persistence/recovery, security boundaries, and provider-neutral wire
behavior. Never remove, deaden, merge away, or make unreachable a supported
feature merely to raise coverage.

Ratchet the merged deterministic Erlang report in reviewed stages:

| Stage | Aggregate floor | Per-module floor for eligible production modules |
| --- | ---: | ---: |
| Current | 74% (74.17% recorded) | No regression from the recorded per-module report |
| Contract breadth | 80% | 60% |
| Failure and concurrency depth | 90% | 75% |
| Boundary completion | 95% | 90% |
| Complete | 100% | 100% |

Each stage merges fresh EUnit and deterministic Common Test line-hit data from
the same source revision; percentages from separate reports must never be
averaged or added. Phoenix ExUnit/Node results and paid-provider evidence stay
separate because they do not instrument the Erlang source report. A module may
be excluded only when it is generated code or a behaviour-only declaration
with no executable product behavior; every exclusion must be narrow,
documented, and release-reviewed. Adapters, error branches, unsupported-input
guards, and concurrency code are not exclusion candidates merely because they
are difficult to exercise.

A release is accepted only when all deterministic gates pass, aggregate and
per-module floors do not regress, the public feature ledger remains intact,
and any exclusion list is unchanged or explicitly approved. Once a stage is
reached on the release branch, raise the enforced floor and do not lower it to
accommodate a later regression. The 100% milestone requires every eligible
production line to be reached by behavior-asserting tests; remote credentials,
quota, or provider availability are never substitutes for deterministic
contract coverage.

## README and focused v0.8 gates

```bash
./rebar3 eunit --module=readme_examples_test
./rebar3 eunit --module=readme_workflow_examples_test

erlc -Werror -pa _build/default/lib/erlang_adk/ebin -o /tmp \
  examples/readme_weather_tool.erl \
  examples/readme_live_weather_executor.erl \
  examples/readme_stateful_counter_plugin.erl

./rebar3 eunit \
  --module=adk_live_media_test,adk_live_gemini_codec_test,adk_live_gun_transport_test,adk_live_public_api_test,adk_live_session_test,adk_live_tool_execution_test,adk_live_observability_test,adk_live_voice_protocol_test,adk_live_voice_bridge_test,adk_plugin_pipeline_test,adk_plugin_runner_integration_test,adk_plugin_builtin_test,adk_plugin_stateful_test,adk_trace_context_test,adk_observability_v2_test,adk_observability_runner_test,adk_otlp_json_test,adk_otlp_http_json_exporter_test,adk_eval_criteria_test,adk_eval_v2_test,adk_eval_llm_judge_test,adk_eval_dev_view_test,adk_dev_v07_http_test,adk_cli_test

./rebar3 eunit \
  --module=adk_provider_credential_test,adk_provider_profile_test,adk_provider_profile_snapshot_test,adk_provider_registry_test,adk_provider_registry_live_test,adk_provider_request_options_test,adk_provider_capabilities_test,adk_model_http_headers_test,adk_model_gun_transport_test,adk_model_sse_decoder_test,adk_llm_openai_test,adk_openai_responses_content_test,adk_openai_responses_codec_test,adk_openai_responses_stream_test,adk_llm_anthropic_test,adk_llm_anthropic_content_test,adk_llm_anthropic_request_test,adk_llm_anthropic_stream_test,adk_llm_compatible_test,adk_llm_compatible_content_test,adk_llm_compatible_request_test,adk_llm_compatible_stream_test,adk_live_openai_codec_test,adk_live_openai_gun_transport_test,adk_live_session_multi_frame_test,adk_live_session_profile_test,adk_live_voice_protocol_test,adk_live_voice_bridge_test,adk_llm_test,adk_cli_test

./rebar3 ct --suite test/runtime/invocations/adk_concurrency_stress_SUITE.erl
./rebar3 ct --suite test/integrations/stress/adk_v05_stress_SUITE.erl
```

The historical v0.7 evidence is 29 README tests, four workflow tests, warning-as-error
compilation/runtime smoke for all three example modules, and 193 focused
Live/plugin/observability/evaluation/developer tests. The stress suites cover
1,000 correlated stable runs, 1,000 isolated artifact/memory writes, and 128
cache acquisitions collapsing to four exact-scope provider lifecycles.
The stable-run stress assertions correlate every response with its exact
session and invocation, require unique run IDs, verify supervisor cleanup, and
leave the test-process mailbox stable after each bounded concurrent batch.

The second focused EUnit command isolates the 0.8 additions. The final
2026-07-17 focused provider/profile/Realtime run passed 244/244. It remains
diagnostic; the clean complete gate is authoritative. A deterministic HTTP
fixture or WebSocket state-machine test does not prove that a paid remote
provider accepted the request.

The final README gates passed 30 README and four workflow tests (34/34), and
all three example modules compiled with warnings as errors. The v0.7 totals in
the preceding paragraph remain historical rather than being silently updated.

After the final audit repairs, the seven-module targeted regression set passed
67/67. It covers multi-frame priority ordering, Anthropic
`max_tokens >= 1` validation, and synchronous/streaming Gun header and trailer
limits.

Every current README recipe and sanity command is mapped to its prerequisites
and validation in
[`README_EXAMPLE_COVERAGE.md`](README_EXAMPLE_COVERAGE.md).
The focused suites directly exercise deterministic core, workflow, Live,
plugin, evaluation, retry, memory, and artifact examples. Features that need
dedicated startup state or transport fixtures—such as HITL, Mnesia,
authenticated developer startup, the project-specific HTTP endpoint, and
Gemini wire behavior—are asserted by their owning test modules; a focused
README smoke may check that those modules remain present without replacing
their complete tests.

## CLI and package smoke gate

```bash
./rebar3 xref
./rebar3 escriptize
_build/default/bin/adk doctor
_build/default/bin/adk config validate examples/agent.json
./rebar3 ex_doc
./rebar3 hex build
./scripts/verify_hex_package.sh
```

For v0.8, `adk doctor` must report application version `0.8.0`, OTP 27, the
REST default `gemini-3.1-flash-lite`, required dependencies, and whether a
Gemini, OpenAI, or Anthropic key is configured without exposing any key. The
configuration validator must accept configured binary profiles through their
safe aliases without projecting credential sources or values. The checked
agent configuration must validate with the same REST model. Xref checks
undefined and deprecated calls/functions without treating a library's public
exports as unused errors. ExDoc must be warning-free. The non-publishing Hex
build and artifact verifier must prove required contents, excluded
caches/secrets, and a clean compile from the extracted package.

On 2026-07-17, xref, escript assembly, `adk doctor` reporting 0.8.0, checked
configuration validation, ExDoc, the 0.8.0 Hex build, and compilation from the
verified extracted package all passed.

## Paid Gemini REST gate

Export the key and opt-in flag in the shell that starts Common Test:

```bash
export GEMINI_API_KEY="your_api_key_here"
ERLANG_ADK_GEMINI_REST=1 ./rebar3 ct \
  --suite test/readme/readme_live_gemini_SUITE.erl
```

Despite the historical suite filename, this is REST GenerateContent/SSE using
`gemini-3.1-flash-lite`; it is not Gemini Live. It exercises 17 cases and
roughly 39 provider requests, including text, function/tool rounds, Search
grounding, multimodal generation/streaming, explicit context-cache creation,
artifact/memory tools, orchestration, continuation, Mnesia, telemetry,
evaluation, and the HTTP endpoint.

The suite spaces request starts by 4.2 seconds by default. On projects with
sufficient quota, pacing can be disabled explicitly:

```bash
ERLANG_ADK_GEMINI_REST=1 \
ERLANG_ADK_GEMINI_REST_INTERVAL_MS=0 \
./rebar3 ct --suite test/readme/readme_live_gemini_SUITE.erl
```

The test transport caps each wait at 15 seconds and retries one non-streaming
transport timeout. A non-streaming HTTP 429 receives one bounded backoff of at
least 10 seconds; a second 429 fails explicitly. Test agent/direct-turn worker
timeouts are 120 seconds, while production defaults remain 60 seconds. These
settings pace only the paid suite and do not change production concurrency or
retry behavior.

The final 2026-07-15 v0.7 run completed all 17 cases with no skips: 15 passed;
`google_search_grounding` and `context_cache` each failed with HTTP 429 after
one bounded retry. Preserve those results as quota failures, not product
passes or skips. The rubric judge and artifact/memory cases passed.

The 2026-07-17 v0.8 attempt reached Google, but the provider rejected the
configured credential shape with HTTP 401 `UNAUTHENTICATED` and reason
`ACCESS_TOKEN_TYPE_UNSUPPORTED`. The suite therefore did not produce a paid
REST pass. Record this as an external credential failure, not a pass, skip, or
Erlang ADK product regression; deterministic Gemini REST/header evidence
remains separate.

`ERLANG_ADK_LIVE_GEMINI` and
`ERLANG_ADK_LIVE_GEMINI_INTERVAL_MS` remain compatibility aliases for this
historical REST suite. New automation should use the unambiguous REST names.

## Paid Gemini Live gate

```bash
export GEMINI_API_KEY="your_api_key_here"
ERLANG_ADK_GEMINI_LIVE=1 ./rebar3 ct \
  --suite test/models/gemini/gemini_live_SUITE.erl
```

This suite uses `gemini-3.1-flash-live-preview` and covers five cases:
text-to-audio plus transcription, 16 kHz PCM input, PNG input, a synchronous
tool round trip, and owner-bound browser framing/ACK behavior. The complete
2026-07-15 v0.7 recorded suite passed 5/5. It skips unless both the opt-in flag
and key reach the Common Test process.

The paid suite is provider-integration evidence. Deterministic codecs,
transport state, ownership, backpressure, reconnect, tool, observability, and
voice-bridge tests remain the release contract when network access or quota is
unavailable.

No v0.8 paid Gemini Live pass is recorded by the 2026-07-17 validation. The
focused Gemini Live broker/transport evidence remains deterministic and does
not establish remote-provider success. The v0.7 5/5 result above remains
historical and must not be carried forward as v0.8 evidence.

## OpenAI, Anthropic, and compatible provider evidence

The 0.8 repository currently provides deterministic injected-transport and
codec coverage for OpenAI Responses, Anthropic Messages, compatible Chat
Completions, and OpenAI Realtime. It does not currently provide a first-party
opt-in paid Common Test suite for those providers. Therefore:

- `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` being present is not itself a test;
- deterministic fixture success must be reported as deterministic evidence,
  not remote-provider success;
- a manual OpenAI/Anthropic smoke must record the exact profile alias, concrete
  model/version in deployment-owned evidence, date, operation, and structural
  result without recording prompts, outputs, or credentials; and
- every OpenAI-compatible endpoint needs its own evidence because the adapter
  does not certify optional vendor semantics.

If a repository paid suite is added later, it must be opt-in, skip cleanly
without both its explicit flag and credential, use a release-owned account,
and report skips/provider/quota failures separately from passes.

## Phoenix, LiveView, and browser gate

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

For v0.7, `mix precommit` checked formatting, compiled with warnings as errors,
built assets, ran 31 dependency-free Node browser/audio tests, and ran 101
ExUnit tests. Production assets, release assembly, and both loopback smoke
modes passed. Those counts are historical. On 2026-07-17 the v0.8
`mix precommit` gate passed with 103 ExUnit and 40 dependency-free Node tests.
Production assets, release assembly, and both trusted-proxy and direct-TLS
loopback smokes also passed.

`mix hex.audit` is expected to remain non-zero at the current lock only for
the two Cowlib 2.18.0 advisories documented in [`SECURITY.md`](../SECURITY.md).
The wrapper enforces that exact exception and fails for new or stale findings;
it does not make the underlying audit a pass. The root Rebar3 project has
no equivalent `rebar3 hex audit` command; do not describe this Mix result as a
root dependency audit.

For the recorded v0.8 gate, raw `mix hex.audit` was non-zero only for those
same two advisories, and the exact-exception verifier passed.

The companion's local-auth mode is for interactive development, but its
authorization, CSRF, session, gateway, socket, LiveView, static-asset, and
audio tests use deterministic fake providers and spend no Gemini quota.

## Result policy

Report each category separately:

- **pass** — the command/case completed its assertions;
- **skip** — an explicit optional prerequisite was absent;
- **provider failure** — the live request ran but the provider, network,
  account, or quota rejected it;
- **environment failure** — the build runner could not provide required local
  sockets, tools, certificates, or dependency access; and
- **product failure** — the implementation or assertion failed under its
  documented prerequisites.

Never turn a skip, HTTP 429, dependency advisory, or sandbox restriction into
a pass. Record command, date, toolchain, model, pass/fail/skip counts, and the
bounded structural reason without copying secrets or model content.
