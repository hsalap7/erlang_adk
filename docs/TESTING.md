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

The same Common Test discovery skips 22 paid provider cases when their opt-in
flags are absent. Those skips are expected for the deterministic gate and are
not included in the six passing cases.

Some HTTP and protocol fixtures open loopback listeners. A restricted build
environment must allow local sockets; otherwise a permission failure is an
environment failure, not passing test evidence.

## Deterministic line coverage gate

```bash
./scripts/coverage.sh
```

The script resets all previously exported Cover data, performs a clean build,
instruments the complete EUnit and Common Test suites, aggregates both exports,
and fails below 73% executable-line coverage. The HTML summary and per-module
reports are written under `_build/test/cover/`. Do not run `rebar3 cover`
against exports from an earlier source tree: `rebar3 clean` does not remove
stale Cover data.

`./rebar3 cover --verbose` only aggregates previously exported `.coverdata`;
it does not execute or instrument tests. Therefore `No coverdata found` is the
expected result on a clean tree or immediately after `cover --reset`. Use
`./scripts/coverage.sh` to produce both the EUnit and Common Test exports before
rendering the report.

Paid Gemini cases remain explicitly skipped without their opt-in flags, and
Phoenix/ExUnit coverage is a separate project concern. The 73% floor therefore
measures the deterministic Erlang release contract only; it must be raised as
new deterministic behavior becomes covered and must not be weakened to hide a
regression. The final 2026-07-16 aggregate is 73.88% across 210 production
modules.

## README and focused v0.7 gates

```bash
./rebar3 eunit --module=readme_examples_test
./rebar3 eunit --module=readme_workflow_examples_test

erlc -Werror -pa _build/default/lib/erlang_adk/ebin -o /tmp \
  examples/readme_weather_tool.erl \
  examples/readme_live_weather_executor.erl \
  examples/readme_stateful_counter_plugin.erl

./rebar3 eunit \
  --module=adk_live_media_test,adk_live_gemini_codec_test,adk_live_gun_transport_test,adk_live_public_api_test,adk_live_session_test,adk_live_tool_execution_test,adk_live_observability_test,adk_live_voice_protocol_test,adk_live_voice_bridge_test,adk_plugin_pipeline_test,adk_plugin_runner_integration_test,adk_plugin_builtin_test,adk_plugin_stateful_test,adk_trace_context_test,adk_observability_v2_test,adk_observability_runner_test,adk_otlp_json_test,adk_otlp_http_json_exporter_test,adk_eval_criteria_test,adk_eval_v2_test,adk_eval_llm_judge_test,adk_eval_dev_view_test,adk_dev_v07_http_test,adk_cli_test

./rebar3 ct --suite test/runtime/invocations/adk_concurrency_stress_SUITE.erl
./rebar3 ct --suite test/integrations/stress/adk_v05_stress_SUITE.erl
```

The v0.7 evidence is 29 README tests, four workflow tests, warning-as-error
compilation/runtime smoke for all three example modules, and 193 focused
Live/plugin/observability/evaluation/developer tests. The stress suites cover
1,000 correlated stable runs, 1,000 isolated artifact/memory writes, and 128
cache acquisitions collapsing to four exact-scope provider lifecycles.

Every README fence and its exact classification is listed in
[`README_EXAMPLE_COVERAGE.md`](README_EXAMPLE_COVERAGE.md).

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

For v0.7, `adk doctor` must report application version `0.7.0`, OTP 27, the
REST default `gemini-3.1-flash-lite`, required dependencies, and whether a
Gemini key is configured without exposing that key. The checked agent
configuration must validate with the same REST model. Xref checks undefined
and deprecated calls/functions without treating a library's public exports as
unused errors. ExDoc must be warning-free. The non-publishing Hex build and
artifact verifier must prove required contents, excluded caches/secrets, and a
clean compile from the extracted package.

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

The final 2026-07-15 run completed all 17 cases with no skips: 15 passed;
`google_search_grounding` and `context_cache` each failed with HTTP 429 after
one bounded retry. Preserve those results as quota failures, not product
passes or skips. The rubric judge and artifact/memory cases passed.

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
2026-07-15 recorded suite passed 5/5. It skips unless both the opt-in flag and key reach
the Common Test process.

The paid suite is provider-integration evidence. Deterministic codecs,
transport state, ownership, backpressure, reconnect, tool, observability, and
voice-bridge tests remain the release contract when network access or quota is
unavailable.

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

`mix precommit` checks formatting, compiles with warnings as errors, builds
assets, runs 31 dependency-free Node browser/audio tests, and runs 101 ExUnit
tests. Production assets and release assembly also pass. The assembled release
has been smoke-tested on loopback in both trusted-proxy and certificate-
verified direct-TLS configurations, returning HTTP 200 from `/health` before
a clean stop.

`mix hex.audit` is expected to remain non-zero at the current lock only for
the two Cowlib 2.18.0 advisories documented in [`SECURITY.md`](../SECURITY.md).
The wrapper enforces that exact exception and fails for new or stale findings;
it does not make the underlying audit a pass. The root Rebar3 project has
no equivalent `rebar3 hex audit` command; do not describe this Mix result as a
root dependency audit.

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
