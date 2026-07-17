# Erlang test layout

Erlang test and fixture module names remain globally flat and unchanged. The
directories below mirror the ownership hierarchy under `src/`; they do not
create namespaces or change EUnit/Common Test module names.

| Test path | Production owner |
| --- | --- |
| `test/agents/` | `src/agents/` |
| `test/artifacts/` | `src/artifacts/` |
| `test/auth/` | `src/auth/` |
| `test/callbacks/` | `src/callbacks/` |
| `test/context/` | `src/context/` |
| `test/core/` | `src/core/` |
| `test/developer/` | `src/developer/` |
| `test/evaluation/` | `src/evaluation/` |
| `test/integrations/` | `src/integrations/`, plus explicit cross-feature integration and stress suites |
| `test/live/` | `src/live/` |
| `test/memory/` | `src/memory/` |
| `test/models/` | `src/models/` |
| `test/plugins/` | `src/plugins/` |
| `test/protocols/` | `src/protocols/` |
| `test/runtime/` | `src/runtime/` |
| `test/sessions/` | `src/sessions/` |
| `test/storage/` | `src/storage/` |
| `test/telemetry/` | `src/telemetry/` |
| `test/tools/` | `src/tools/` |
| `test/workflows/` | `src/workflows/` |
| `test/readme/` | README examples and opt-in provider integration evidence |

The 0.8 model-provider slice mirrors its deeper production ownership:

| Test path | Production owner |
| --- | --- |
| `test/auth/credentials/` | Provider credential/profile-generation resolution and the existing credential lifecycle |
| `test/models/profiles/` | Binary model profiles, aliases, capability ceilings, locked request options, and Live resolution |
| `test/models/transport/` | Shared HTTP headers, synchronous/streaming 64 KiB header/trailer bounds, Gun request/SSE transport, incremental SSE, and injected transport fixtures |
| `test/models/openai/` | Native OpenAI Responses request/content/provider behavior |
| `test/models/openai/request/` | Pure Responses content, request, response, and SSE event codecs |
| `test/models/openai/realtime/` | OpenAI Realtime provider codec and fixed-origin WebSocket transport |
| `test/models/anthropic/` | Native Anthropic Messages provider behavior |
| `test/models/anthropic/request/` | Pure Messages content, request, response, and SSE lifecycle codecs |
| `test/models/compatible/` | Compatible Chat Completions provider behavior |
| `test/models/compatible/request/` | Pure compatible content, request/response, and SSE codecs |
| `test/live/core/` | Provider-neutral contiguous multi-frame/no-op admission, priority ordering, profile resolution, ownership, and flow control |
| `test/live/voice/` | Negotiated format framing, 16/24 kHz input, bridge ownership, and acknowledgement behavior |

Keep remote provider calls out of ordinary `*_test.erl` modules. Deterministic
provider tests inject `adk_model_fixture_transport`, fake Live transports, or
pure wire frames. A billable/network suite belongs in the owning provider
directory, must use an explicit opt-in environment flag, and must report a
missing credential as a skip rather than silently falling back to fixtures.

Only tests for the public facade and OTP application shell remain directly in
`test/`, matching the root production modules. Shared helpers belong beside
the subsystem that owns their behavior. Repository-level shell and TLS
fixtures remain at `test/` and `test/fixtures/` because README and Phoenix
release checks consume those stable paths.

Rebar3 enables one recursive `test` source root only in the `test` profile.
Do not configure overlapping nested roots: ordinary EUnit/Common Test
discovery must have one source entry per module, while default builds,
releases, and Hex packages must not contain test helpers. Rebar3 may create
temporary suite-directory copies internally when an explicit `ct --suite`
path is selected; those are build artifacts, not additional source roots.

Use application include paths such as `-include("adk_event.hrl").`; never make
an include depend on a test module's directory depth. Add new test modules and
their dedicated fixtures to the directory that owns the tested lifecycle.
Shared fixtures should still have one clear owner: for example, the injected
model HTTP fixture belongs under `test/models/transport/`, while a provider-
specific event fixture belongs under that provider's `request/` or `realtime/`
directory. Test helper modules must never enter default builds or Hex packages.

Run the complete deterministic gate from the repository root:

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
```
