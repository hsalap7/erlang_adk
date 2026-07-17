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

Run the complete deterministic gate from the repository root:

```bash
./rebar3 do clean, compile, eunit, ct, dialyzer
```
