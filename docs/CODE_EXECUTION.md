# External sandbox code execution

Erlang ADK does not evaluate model-produced code in the BEAM, invoke a shell,
or bundle an unsandboxed local interpreter. Arbitrary code must run through an
application-supplied `adk_code_executor` adapter backed by a real isolation
boundary such as a locked-down container, microVM, or remote sandbox service.

`adk_code_toolset` supplies the model-facing contract and validates every
request before the adapter is invoked:

```erlang
{ok, CodeTools} = adk_code_toolset:new(
    #{executor => {my_sandbox_adapter, SandboxHandle},
      languages => [<<"erlang">>, <<"python">>],
      timeout => 30000,
      max_code_bytes => 65536,
      max_stdin_bytes => 65536,
      max_files => 16,
      max_file_bytes => 1048576,
      max_total_file_bytes => 4194304,
      max_output_bytes => 1048576,
      parallel_safe => false}),

{ok, AgentPid} = erlang_adk:spawn_agent(
    <<"SandboxedCoder">>,
    #{provider => adk_llm_gemini,
      model => <<"gemini-3.1-flash-lite">>,
      instructions =>
          <<"Use execute_code when calculation or validation requires it.">>},
    [CodeTools]).
```

The adapter implements:

```erlang
-behaviour(adk_code_executor).
-export([execute/3]).

execute(SandboxHandle, Request, Context) ->
    %% Send Request to an already isolated external runtime and return only a
    %% bounded JSON-safe map. Do not execute it with erl_eval, os:cmd, a local
    %% shell, an unsandboxed port, or a NIF.
    my_sandbox_client:execute(SandboxHandle, Request, Context).
```

The request contains `language`, `code`, `stdin`, and a bounded list of text
files. Languages are selected from the configured allowlist. File paths reject
absolute paths, empty segments, `.`, `..`, Windows separators, and drive/URI
colons; logical paths are data for the sandbox adapter and are never opened by
Erlang ADK. Unknown fields and
oversized or invalid UTF-8 values fail before adapter execution.

Only explicitly selected invocation identifiers are copied to the adapter
context. Credentials, provider handles, tool auth references, session state,
and arbitrary Runner context are not forwarded. Adapter results must be
JSON-safe and fit `max_output_bytes`; adapter exceptions and invalid/oversized
outputs fail closed as tool errors without retaining a stacktrace.

## Sandbox requirements

The adapter remains responsible for enforcing the security boundary. At a
minimum, production sandboxes should provide:

- per-execution CPU, wall-clock, memory, process, and output limits;
- an ephemeral read-only base filesystem and a fresh writable working area;
- no host mounts, inherited credentials, cloud metadata access, or container
  control socket;
- network denied by default, with explicit destination policy if enabled;
- a non-root identity, syscall/capability restriction, and cleanup after every
  terminal outcome;
- independent admission control and auditable execution identifiers.

Set `parallel_safe => true` only when the external service itself enforces
bounded concurrent isolation. Erlang ADK then uses its normal supervised tool
tasks, deadlines, cancellation, callbacks, plugins, observability, and runtime
policy around each sandbox call.
