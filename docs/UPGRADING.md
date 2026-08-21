# Upgrading Erlang ADK

Version 0.9.0 is the current cumulative release. This guide highlights behavior
and deployment changes introduced by the 0.3-0.9 milestones and the optional
expanded 0.10 scope now **IN DEVELOPMENT**; it is not a substitute for the exact
contracts in the version documents. Do not deploy or publish 0.10 as a released
upgrade until its candidate gate and approval are complete.

## Before upgrading

1. Read [`FEATURE_PARITY.md`](FEATURE_PARITY.md) and the contracts for every
   milestone being crossed. “Partial” and adapter-owned behavior is not made
   complete by a version bump.
2. Back up deployment-owned Mnesia/session, artifact, memory, evaluation, and
   credential stores. Test restoration and erasure policy in staging.
3. Preserve `rebar.lock` and, for the Phoenix companion, `mix.lock`. Review the
   dependency exceptions in [`SECURITY.md`](../SECURITY.md).
4. Run the complete deterministic and packaging gates before and after the
   upgrade. Run paid provider gates if provider behavior is in scope.
5. Test cancellation, reconnect, continuation, auth expiry, restart, and
   cross-principal isolation with the deployment's adapters and topology.

There is no general automatic schema-migration promise for arbitrary
application session tables or custom adapters. Node-local web sessions, run
lookup, A2A tasks, and Live discovery also do not gain transparent horizontal
failover in 0.9. Model profiles are also node-local application configuration,
not a distributed registry. Stage any persistent-data, profile rollout, or
multi-node change explicitly. The in-development 0.10 registry snapshots,
evaluation Mnesia store, runtime service bundle, and trace store do not change
those topology limits.

## Moving to 0.3.0: supervised runtime foundation

- Treat an agent process as an immutable reusable specification and admission
  point. Invocation work runs in separately supervised processes with stable
  IDs, deadlines, budgets, cancellation, events, and one terminal result.
- Enable listeners and persistent services explicitly. The developer API,
  A2A/MCP listeners, Mnesia, and other services are not ambient production
  defaults.
- Consume versioned JSON-safe events rather than internal Erlang records or
  process state.
- Scope continuations and temporary state to an invocation. Do not use browser
  or caller process lifetime as run ownership.
- Configure bounded admission and decide whether overload rejects or enters a
  bounded FIFO queue.

## 0.3.0 to 0.4.0: agents, tools, and workflows

- Distinguish legacy direct turns from fresh invocations. `prompt` and legacy
  `delegate` retain one stateful FIFO compatibility history; Runner and
  explicit invocation/delegated execution use fresh invocation history and
  exact-session lanes.
- Ensure model-visible agent names match `[A-Za-z_][A-Za-z0-9_]*`, avoid the
  reserved `user` name, and construct a true bounded tree: no duplicate
  names, cycles, multiple parents, or unavailable children.
- Compile and validate tool catalogs before provider calls. New dynamic tools
  are invisible until an explicit catalog refresh, and a running agent does
  not automatically swap its catalog.
- Treat model tool arguments as untrusted. Schema, policy, confirmation, and
  credential checks occur before callbacks or side effects.
- Review workflow pause/resume shapes. Top-level sequential/graph/fork paths
  have checkpoint behavior, but nested pauses in parallel branches, loop
  bodies, and transfer members remain limited.

## 0.4.0 to 0.5.0: artifacts, memory, and context

- Supply exact app/user/session or app/user scopes to artifact, memory, and
  context operations. Cross-scope results fail closed rather than being
  silently filtered into a caller's view.
- Move large artifact bytes through deployment-owned bounded adapters. Do not
  put raw multi-megabyte blobs into session history, state, events, or a
  global coordinator mailbox.
- Choose durable adapters and ownership policy explicitly. ETS reference
  implementations are volatile; local Mnesia/filesystem behavior does not
  imply a managed object/vector store, encryption at rest, or distributed
  failover.
- Expect mandatory model-boundary sanitation and complete-request budgeting.
  Tool exchanges remain paired and the current input is not discarded to fit
  a budget.
- Treat context caching as provider prefix/resource reuse, not response
  caching. Cache identities include provider/model/policy/scope information
  and must not expose private provider resource names.
- If enabling exact-scope sharded adapters, size shard admission and storage
  limits for the deployment. Limits are per shard; no global quota is implied.

## 0.5.0 to 0.6.0: authentication, protocols, and Phoenix

- Separate authentication from authorization. A valid token produces an
  issuer-bound identity; a default-deny authorizer must grant each exact
  operation/resource.
- Replace caller-selected provider modules/context with immutable, trusted
  provider profiles and opaque credential references. Use production secret
  storage rather than treating ETS as encrypted durable credential storage.
- For interactive authorization, use the supervised authorization-code flow
  with exact redirects, S256 PKCE, nonce/state, bounded expiry, atomic replay
  claim, and subject binding.
- Update MCP integrations to the supported 2025-11-25 Streamable HTTP
  contract and bind protocol sessions to the authenticated principal.
- Update A2A integrations to the A2A 1.0 JSON-RPC endpoint and send
  `A2A-Version: 1.0`. The legacy `/a2a/prompt` endpoint is not wire-compatible
  and should not be exposed as a production A2A API.
- Keep `/dev` loopback/private and single-operator. Its bearer token is not an
  end-user identity or tool/model credential.
- The Phoenix companion is a same-BEAM BFF. Configure exact OIDC issuer,
  client, callback, scopes, cookie/TLS secrets, and an immutable agent
  catalog; the browser must not select modules, providers, app/user scopes,
  paths, or service PIDs.
- Plan for node locality or sticky routing across the complete login,
  web-session, run, and Live lifetime.

## 0.6.0 to 0.7.0: Live, plugins, evaluation, and observability

### Gemini model separation

Ordinary agents and REST GenerateContent/SSE use:

```erlang
#{provider => adk_llm_gemini,
  model => <<"gemini-3.1-flash-lite">>}
```

Gemini Live is a different WebSocket protocol and uses:

```erlang
#{model => <<"gemini-3.1-flash-live-preview">>}
```

A REST model is rejected by the Live provider. Update automation to use
`ERLANG_ADK_GEMINI_REST=1` for the historical REST suite and
`ERLANG_ADK_GEMINI_LIVE=1` for the Live suite. Historical
`ERLANG_ADK_LIVE_GEMINI` names remain REST-suite compatibility aliases.

### Live sessions and browser voice

- Create and close Live sessions explicitly. Subscribe before waiting for
  readiness, grant bounded credit, and acknowledge each delivered event.
- Subscribers receive future events only. Reconnect may resume provider
  context but does not replay arbitrary media, input, output, or tool side
  effects.
- Use 16 kHz mono PCM s16le for microphone input and expect 24 kHz mono PCM
  s16le model output. Image input is bounded JPEG or PNG.
- Automatic Live tool execution remains off unless trusted application code
  configures an executor, declaration allowlist, scheduling policy, deadline,
  heap bound, and response bound.
- The core supplies an owner-bound voice bridge, not microphone capture or
  playback. The Phoenix reference uses AudioWorklet/Web Audio, exact binary
  acknowledgement, interruption purge, and a same-origin authenticated
  socket.

### Plugins

- Prefer explicit `amend` to continue with a modified value and explicit
  `return` for early completion. The compatibility `{replace, Value}` form is
  an early return, not an amendment.
- Stateful plugin callbacks serialize per instance. Use independent instances
  for plugin-level concurrency; a crashed instance is unavailable rather than
  silently restarted with empty state under a stale PID.
- Revalidate schema, policy, and confirmation after tool-argument amendments.
  Dynamic catalog tools are therefore not amendable in 0.7.

### Evaluation

- Move CI work to versioned eval sets/results and `adk eval run` where useful.
  Exit 0 means pass, exit 2 means a completed evaluation that failed its
  thresholds, and exit 1 means configuration/runtime failure.
- Deterministic criteria remain the reproducible default. The Gemini rubric
  judge is explicit, billable, bounded, and defaults to
  `gemini-3.1-flash-lite`; judge errors count as errors, never passing scores.
- Protect reports as evaluated content. They can contain bounded rationale
  even though provider credentials and raw provider errors are removed.

### Observability

- Adopt v2 operation spans and strict W3C `traceparent`/`tracestate` helpers.
  Automatic propagation through every older MCP, A2A, workflow, task, or
  Phoenix boundary is not claimed.
- Keep content capture off by default. GenAI attributes, metrics, and the
  native OTLP/HTTP JSON exporter exclude prompts, responses, media,
  transcripts, tool arguments/results, credentials, and provider handles.
- The asynchronous bus is bounded best effort, not a durable WAL. Retries can
  duplicate delivery; exhausted work is dropped and counted.

### A2A and Phoenix corrections

- Agent Card `version` now defaults to the loaded `erlang_adk` application
  version instead of a hard-coded 0.6 value. An explicitly configured card
  version still takes precedence. Do not confuse it with the A2A
  `protocolVersion`, which remains `1.0`.
- The explicit Phoenix local identity now works without any `OIDC_*`
  variables, but only in development on exact IPv4 loopback. Login remains a
  CSRF-protected POST and the server owns its principal and scopes.
- Update Phoenix assets and hooks together. The 0.7 browser voice path depends
  on the checked AudioWorklet/resampler, continuous bounded playback, exact
  ACK timing, interruption cleanup, styles, and packaged favicon.

## 0.7.0 to 0.8.0: model profiles, vendors, and Realtime

### Move public model selection to binary profiles

Direct module configuration remains compatible for trusted Erlang code:

```erlang
#{provider => adk_llm_gemini,
  model => <<"gemini-3.1-flash-lite">>}
```

For browser-, tenant-, file-, or API-selected configuration, define an
operator-owned `provider_profiles` entry and expose only aliases:

```erlang
ok = application:set_env(
    erlang_adk, provider_profiles,
    #{<<"openai-prod">> =>
          #{request_adapter => adk_llm_openai,
            endpoint => openai,
            models => #{<<"fast">> => <<"gpt-5-mini">>},
            credential => {env, "OPENAI_API_KEY"},
            request_options => #{store => false}}}),

PublicConfig = #{provider => <<"openai-prod">>,
                 model => <<"fast">>,
                 temperature => 0.2}.
```

Do not translate a public provider string to an atom. Do not merge public maps
over profiles. Profile callers cannot replace concrete model IDs, endpoints,
credentials, arbitrary headers, API versions, auth/storage/billing settings,
transports, or Live audio rates. Review the full schema in
[`PROVIDER_PROFILES.md`](PROVIDER_PROFILES.md).

Validate the complete registry at startup:

```erlang
{ok, _CheckedProfiles} = adk_provider_registry:profiles().
```

Profile selection and credential lookup are generation-consistent. If a
profile changes between those operations, the request fails with
`provider_profile_changed`. Deploy profile authority and its credential source
as one change rather than relying on a partially updated in-memory map.

### Choose the protocol-specific request adapter

- Use `adk_llm_openai` for the native OpenAI Responses API, not Chat
  Completions.
- Use `adk_llm_anthropic` for the native Anthropic Messages API and keep
  `anthropic_version` operator-owned. `max_tokens` must be at least one.
- Use `adk_llm_compatible` only for the documented Chat Completions subset at
  a trusted structured HTTPS endpoint. Lock `auth_scheme` to `bearer`,
  `x_api_key`, or `none`, and set `response_format => unsupported` in trusted
  configuration when the endpoint does not implement structured output.
- Continue using `adk_llm_gemini` for Gemini REST GenerateContent/SSE.

OpenAI and Anthropic direct legacy adapters read their conventional ambient
key only at the exact official base URL. Custom origins require an explicit
profile credential. The compatible adapter never guesses that a process-wide
key belongs to a custom origin. If an older compatible integration relied on
`OPENAI_COMPATIBLE_API_KEY` without an explicit key/profile, move it to
`credential => {env, "OPENAI_COMPATIBLE_API_KEY"}` in a trusted profile.

Both synchronous and streaming model Gun paths now reject any aggregate
response-header or trailer block above 64 KiB. Custom transports should apply
an equivalent bound before admitting provider metadata.

Provider-specific tool, content, finish-reason, structured-output, and stream
semantics remain distinct. Test the exact configured model/endpoint; a working
OpenAI profile is not evidence for Anthropic or an arbitrary compatible
vendor, and deterministic codec fixtures are not paid-provider evidence.

### Add OpenAI Realtime without changing Live ownership

OpenAI Realtime uses the existing explicit server-owned Live lifecycle:

```erlang
#{provider => <<"openai-live">>,
  provider_config =>
      #{model => <<"voice">>,
        response_modalities => [audio],
        automatic_activity_detection => true}}
```

The matching trusted profile supplies `live_adapter => adk_live_openai`, the
`openai` endpoint preset, concrete Realtime model ID, and credential. Profile
callers cannot inject a WebSocket transport or origin. The bundled transport
is fixed to verified TLS at the official OpenAI origin.

One logical action may now produce multiple ordered provider frames. Admission
is atomic for that frame batch, so concurrent callers cannot interleave the
item-creation and response-request halves. Once transmission begins, even a
later priority action waits until that in-flight frame batch is complete. If a
custom Live provider is updated to use this contract, return `{ok, Frame}` or
`{ok, [Frame, ...]}`; return `ignored` only for a deliberate provider no-op.
Existing single-frame providers remain compatible.

OpenAI manual turn detection commits on `activity_end`. `audio_stream_end` is
a no-op because the Phoenix/browser lifecycle emits it after capture stops;
committing there as well would request a duplicate empty response. In server
VAD mode the provider owns commits.

### Negotiate voice input rate

Do not hard-code 16 kHz in a generic browser/voice adapter. Live status now
reports a trusted `input_audio_sample_rate`:

- Gemini Live: 16 kHz PCM s16le mono input;
- OpenAI Realtime: 24 kHz PCM s16le mono input; and
- both bundled paths currently expose native 24 kHz PCM audio output events.

The owner-bound bridge sends an unsequenced server configuration frame before
accepting client audio. Update custom socket clients to wait for that frame,
initialize their resampler with its rate, and never ACK it. Sequence/credit
ACKs still apply only to subsequent sequenced provider events. The rate is
derived from trusted provider capabilities inside the Live session; remove any
caller-supplied sample-rate override.

## 0.8.0 to 0.9.0: definition-bound workflows and model endpoints

### Plan the checkpoint-v2 migration

Workflow checkpoint schema v2 binds saved state to the compiled
`definition_fingerprint`, not only workflow ID/version/kind. The 0.9 runtime
accepts a valid v1 checkpoint once and writes v2 at the next checkpoint
boundary. That rewrite is one-way for the invocation; do not roll it back to a
0.8 runtime afterward.

For every durable workflow that contains an Erlang callback and may resume
after a code deployment, add a root `definition_revision`:

```erlang
#{version => 1,
  id => <<"checkout">>,
  definition_revision => <<"checkout-2026-08-v1">>,
  kind => graph,
  %% ...
 }.
```

Treat the revision as application schema: keep it unchanged only while all
callback semantics and captures are resume-compatible, and bump it deliberately
when they are not. Without a revision, definitions containing anonymous funs
are marked non-portable and should be recovered only against the exact
compatible build. Test a staged v1 resume, observe a v2 commit, and then test a
definition mismatch before upgrading production records.

Retry attempts now survive checkpoints. An ambiguous in-flight attempt repeats
at the same attempt number instead of receiving a fresh budget. The call can
still happen more than once; preserve stable external idempotency keys based on
invocation and step/cursor identity.

### Review nested pauses and confirmations

Nested child pauses now bubble and resume through top-level parallel, loop,
and transfer workflows as well as sequential and graph shapes. To make a
parallel pause durable, the runtime cancels uncommitted siblings; those
siblings may run again after resume. Audit external effects for idempotency.

Protected typed-workflow tool nodes now pause with structured
`tool_confirmation` details instead of failing closed solely because they are
outside the Runner. Update workflow clients to present the opaque action ID and
resume with a correlated boolean decision. Do not treat arbitrary JSON or a
model-generated value as approval.

If operational code consumes workflow progress, opt into
`lifecycle_receiver`. It is separate from `event_receiver` and emits ordered
schema-v1 messages for workflow/node/route/fork/join/attempt/checkpoint/pause
events. It is best-effort observation, not a replacement for the durable
checkpoint or invocation ledger.

### Adopt graph contracts deliberately

Existing forks keep `join_policy => all`. Before selecting `any`,
`first_success`, or `{quorum, N}`, account for cancellation of remaining
branches and the possibility that an uncommitted branch effect already
happened. The join input contains only successful committed results selected by
the policy. `all`, `any`, and quorum fail fast on a branch failure;
`first_success` is the failure-tolerant choice.

Per-node `input_schema` and `output_schema` are optional and compile before
execution. Add them at trust boundaries first. State keys remain overwrite by
default; opt into `append`, `sum`, or `reject_conflict` through root
`state_reducers` only after checking existing stored state types.

Use `erlang_adk:inspect_graph/1`, `erlang_adk:render_graph/2`, or the local
`adk graph` commands in CI to review topology and warnings. These are read-only
descriptor/rendering tools, not a visual editor or an arbitrary graph
scheduler.

### Configure local servers and Vertex explicitly

The local keyless exception applies only to `adk_llm_compatible` at numeric
`127.0.0.1` or `::1`, with auth `none` and no Live adapter. It does not allow a
hostname, private LAN address, container bridge address, or arbitrary cleartext
endpoint. Put non-loopback deployments behind an operator-controlled HTTPS
gateway and retain normal certificate/DNS/private-address policy.

Vertex uses `adk_llm_vertex`, a complete Google publisher-model resource, the
`vertex` endpoint preset, and OAuth. A trusted profile may resolve
`google_adc`; direct trusted code may also pass an already-minted access token.
Profile-selected `google_adc` uses only the fixed bounded `gcloud auth
application-default print-access-token --quiet` command. Direct trusted code
may instead inject an `adc_token_provider` handle; profile callers cannot.
Public callers cannot choose an origin, token provider, executable, arguments,
headers, or credential material.

A model recipe is not remote compatibility evidence. Re-run deterministic
tests and an explicitly authorized paid/staging smoke for each exact Vertex or
compatible deployment you rely on.

## 0.9.0 to 0.10.0: merged platform foundations (in development)

This section describes opt-in development APIs, not a released upgrade.
Version 0.9 already provides artifacts, Runner-integrated memory, evaluation
v2, stdio and Streamable HTTP MCP, Developer UI/Phoenix, A2A 1.0, and partial
Agent Config. The unreleased 0.10 branch folds the formerly proposed 0.11 and
0.12 work into reusable configuration/composition, supervised services,
bounded object/vector/evaluation/protocol foundations, local debugging, and
render-first deployment assets. None of those development APIs is a release
or external interoperability/deployment claim.

### Adopt a runtime-service bundle deliberately

Existing direct session, artifact, and memory service references remain valid.
To adopt one local built-in profile, add
`adk_runtime_service_bundle:child_spec/1` to an application supervisor or call
`start_link/2`, then obtain the native references through `services/1` or the
session/Runner split through `runner_spec/1`.

The bundled application supervisor registers an app-env-enabled instance as
`adk_runtime_service_bundle`; call
`adk_runtime_service_bundle:runner_spec(adk_runtime_service_bundle)`. For a
custom registered name, pass `name` to `child_spec/1` or use `start_link/3`.
Application code can use `erlang_adk:runtime_runner_spec/0` to obtain the
configured split without knowing the bundle name. With profiles disabled it
returns the released `erlang_adk_session` default and no artifact/memory
options; with a profile enabled, an unavailable or mismatched bundle is an
error rather than a silent fallback.

- `ephemeral_local` chooses `erlang_adk_session`, `adk_artifact_ets`, and
  `adk_memory_ets`. Its routers deliberately use one shared adapter instance
  per component, preserving every scope and enforcing one global adapter
  quota.
- `durable_local` chooses `erlang_adk_session_mnesia`, `adk_artifact_fs`, and
  `adk_memory_mnesia` behind exact-scope workers; supply an absolute,
  deployment-owned `artifact_root` and stage its permissions, backup, restore,
  and capacity policy. It also atomically owns a private Mnesia memory outbox,
  validates its health and adapter identity, exposes redacted status/services,
  and injects durable ingestion into standard Runner options. Pending jobs
  survive a bundle process restart; stale or unhealthy references fail closed.
  Registry hydration gates claims by exact adapter identity; an ordered index
  and rotating bounded cursor own due/lease/epoch/terminal maintenance.

Profile configuration can set only `artifact` and `memory` component maps with
`adapter_config`, `max_active_scopes`, `max_router_queue`, and
`idle_scope_timeout_ms` (default 60000; range 1 through 86400000). Do not
attempt to put a module name in a profile config. Treat a bundle restart as a
new service generation and reconstruct Runners that held the old references.
Legacy module-named APIs and `memory_outbox_enabled` compatibility settings
route to the one bundle-owned durable supervisor, so no duplicate processor is
started. Disabled and `ephemeral_local` profiles continue to support the
released standalone path when explicitly configured.

Before migration, stage all four jobs/usage/schedule/erasure-epoch tables.
Health uses constant point operations and one row-count-neutral sentinel
transaction. If selecting `mnesia_majority`, configure at least two nodes
shared by every table or health/admission/claim/renewal fails closed. Active
jobs reserve terminal slots under `max_terminal_records`; an inherited store
above the new cap starts only to permit bounded indexed prune/delete and rejects
new work until below the reservation ceiling. Epoch-bound IDs keep retries
idempotent within one erasure epoch but deliberately allow the same logical
submission after erasure. Review all nested outbox/registry/processor limits;
unknown keys, invalid capability types, or missing v2 idempotent/incremental/
erasure-fencing support now fail before the profile becomes available.

The shared ephemeral routers report one active scope, require no idle
reclamation, and expose `global_quota => true`. Durable routers report
`routing => exact_scope` and per-shard quotas (`global_quota => false`). When a
durable router reaches its default 1024-worker ceiling, it can reclaim the
least-recently-used worker only after that worker has no operation lease and
has exceeded the idle timeout. Filesystem/Mnesia data survives this worker
reclamation. Route operations use owner-bound exactly-once leases and carry an
absolute deadline through admission, resolution, and handoff, so a killed or
timed-out caller cannot pin capacity or install a stale shard. If no worker is
eligible, a new cold scope returns
`{error, max_active_scopes_reached}`. Size the per-shard limits and this
concurrent/cold-worker capacity independently; the bundle does not aggregate
durable quotas across scopes.

Standard CLI run/console, the evaluation agent adapter, and developer HTTP
setup use the application resolver. Profile-owned Runner service references
win over agent/developer options. Console inspection and evaluation cleanup use
the selected session module, so stage durable Mnesia data and cleanup policy
before enabling `durable_local`.

### Move Agent Config to schema 2 and one sealed registry snapshot

Existing checked CLI JSON without `schema_version` is interpreted as schema 1,
so migration can be incremental. New configuration should declare
`"schema_version": 2` and compile through `adk_agent_config:compile/2` or
`load_file/2`. Schema 2 accepts JSON and Erlang ADK's strict YAML subset; both
normalize to the same IR/fingerprint against the same registry snapshot.
YAML remains data-only: it rejects tabs, anchors, aliases, tags, merge keys,
directives, multiple documents, block scalars, ambiguous scalar forms, and
non-empty flow collections. It does not execute constructors or create atoms
from input.

Record the returned fingerprint, `registry_instance_id`,
`registry_snapshot_revision_id`, and registry generation together as
configuration provenance, not as proof that a remote provider accepted a
request. The fingerprint is repeatable for the same configuration and
immutable registry snapshot. It is intentionally not a global content identity
across independently created registries or replacement branches.

Build trusted descriptors once with `adk_config_registry:new/1`; take one
immutable snapshot per compile. Every independently created non-empty registry
gets a new opaque instance ID. `replace/2` preserves that lineage ID, advances
the generation, and creates a fresh opaque snapshot revision while old
snapshots continue resolving the old catalog. The revision prevents two
branches replaced from the same registry from sharing provenance even if their
generation numbers match. The initial empty default alone has stable IDs.
Neither ID is a descriptor-content digest.

Do not construct or mutate registry tuples directly. Registry and snapshot
terms contain an internal keyed seal over their trusted entries; public APIs
reject a structural copy whose provider or toolset content no longer matches
that seal. The seal is not returned by `describe/1`, included in a compiled
fingerprint, or printed by the CLI.

The default `agent_config_registry` application environment may contain raw
definitions or a compiled registry. Non-empty raw definitions are compiled and
replaced in application environment once under a lock, so subsequent default
compilations use the same snapshot. An explicit raw definition map passed as
the `registry` option constructs a new registry; pass a compiled registry or
snapshot when callers must share provenance.

Put binary provider IDs and MCP, OpenAPI, or tool-pack references in agent
files. Schema 2 also accepts data-only references to `agent_template`,
`credential_profile`, `runtime_policy`, bounded `sub_agents`, and bounded
`workflows`. Trusted registry definition keys are `providers`, `mcp`,
`openapi`, `tool_packs`, `credentials`, `runtime_policies`, `workflows`, and
`agent_templates`. Keep transport URLs, commands, headers, credential values,
and secret material in operator-owned descriptors; the compiler intentionally
rejects those values in the agent document. Agent names must match
`[A-Za-z_][A-Za-z0-9_]*`, must not be `user`, and must be no more than 256
bytes. A config may reference at most 64 toolsets, and duplicate
`{kind, id}` pairs are rejected. The compiler resolves the accepted list in
one authenticated `adk_config_registry:lookup_many/2` operation against the
immutable snapshot. Non-empty direct `tools` module lists are also rejected by
default. Trusted compatibility code may pass
`#{allow_legacy_module_tools => true}` to `compile/2` or `load_file/2`, but new
declarative configs should use registry-backed `toolsets` IDs. Arbitrary
`adk_llm_*` provider module names are separately rejected by default with
`legacy_provider_modules_disabled`; trusted compatibility code can set
`allow_legacy_provider_modules => true`. Fixed provider aliases and
registry-backed provider IDs do not need that opt-in.

Use `adk_agent_composition:resolve/1,2` to validate the complete data-only
template/workflow/policy tree against that exact snapshot before starting
processes. `spawn/1,2` and `spawn_scoped/2,3` materialize children bottom-up;
`root/1`, `runner_options/1`, `workflows/1`, and
`credential_profiles/1` expose the bounded projection. Credential profile IDs
may cross that boundary; credential descriptors do not. This is an
Erlang-owned config dialect, not an upstream-exact YAML contract, visual
builder, or code generator.

`adk config validate` now reports `schema_version`, `registry_generation`,
`registry_instance_id`, `registry_snapshot_revision_id`, and `fingerprint`.
Update consumers that enforce an exact output key set before moving the CLI to
the 0.10 branch.

`adk serve --config` now compiles the agent before application startup and
merges its bounded `runner_options` into developer Runner configuration.
Trusted application `dev_runner_options` win conflicts, and runtime-profile
artifact/memory references remain authoritative. Review both sources together
when migrating an existing developer listener.

### Choose an evaluation store and recovery policy

The existing file/report-oriented evaluation-v2 APIs remain. The new
`adk_eval_service` does not automatically import old result files. Submit new
jobs under an exact `{app, AppBinary}` scope and choose either:

- `{owned, adk_eval_store_ets, Limits}` for bounded volatile development data;
  or
- `{owned, adk_eval_store_mnesia, Config}` for local durable sets, jobs,
  results, and baselines.

Custom `adk_eval_store` implementations must now implement
`ownership_identity/1`. Return one canonical identity for both an unopened
configuration and its opened handle, and make wrapper modules reuse the
underlying backend identity. Use `defer` only when a `start_link/1`
process-backed store cannot identify itself before startup. An init-only
durable store must supply a pre-init identity or startup fails with
`eval_store_preinit_identity_required`. The service permits only one owner for
an identity. Mnesia identity is canonical for the same tables and persistent
capacity/schema settings even when `repair_usage` or `table_wait_ms` differs,
and an owned service takes that lock before initialization or reconciliation.
Stage this callback before switching a custom adapter to the 0.10 service.

For Mnesia, keep the default table atoms or configure fixed operator-owned
`sets_table`, `jobs_table`, `baselines_table`, and `usage_table` values before
startup. Back up and restore those tables with the rest of the deployment's
Mnesia state. The adapter requires ordered tables and a local disk copy,
persists a fingerprint of its storage configuration, rejects mismatched
configuration on restart, and takes the O(1) ready path when its persisted
usage state and table counts match. Missing, mismatched, or explicitly forced
usage state is reconciled in checkpointed batches under a global repair lock;
writes fail closed while repair is active. Set `repair_usage => true` for one
controlled startup after an external restore when counts alone cannot reveal
stale byte/reference accounting. Repair validates quota and reference
integrity and fails closed. Treat changes to table names, record schema, or
capacity/recovery/reconciliation settings as a planned migration, not a live
reinterpretation of existing data.

The final 0.10 development schema stores a `charged_bytes` field in each job
row. A Mnesia table created by an earlier 0.10 development revision without
that attribute is rejected as a schema mismatch; migrate it explicitly or
recreate only disposable development tables. `repair_usage` repairs accounting
rows, not an incompatible primary-table schema.

If the application uses `adk_invocation_ledger_mnesia`, its configured table
is also validated during `init/1`. An existing table must match the invocation
record attributes/name, `set` type, majority setting, and local `disc_copies`
storage. A schema mismatch or `ram_copies` table fails closed; migrate it
explicitly or choose a separate operator-owned table atom rather than relying
on startup to reinterpret or downgrade it.

Both built-in stores default to 16 MiB per record, 256 MiB per exact
application scope, 1 GiB total, and at most 100 deletions per prune call.
Mnesia additionally defaults to scanning at most 1000 rows per prune call and
recovering active jobs in batches of 100; accounting repair defaults to
500-row transactions. ETS recovery also yields internally every 100 rows, with
no configuration option. Size `max_record_bytes`, `max_scope_bytes`,
`max_total_bytes`, `max_prune_limit`, `max_prune_scan`,
`recovery_batch_size`, and `reconciliation_batch_size` before rollout. Queued
jobs reserve 4608 bytes of terminal-record headroom against these byte quotas.

Service submission atomically writes the immutable set revision and job, so a
capacity rejection cannot strand a new set revision. Use
`adk_eval_service:prune/3` with a required `before` epoch-millisecond cutoff
and follow its opaque `next_cursor` while `has_more` is true. Pruning retains
active jobs, jobs named by baselines, and set revisions still referenced by a
job by default. Set `include_baselines => true` only for a deliberate retention
operation that should first delete old baselines and then their newly
unreferenced terminal jobs and sets; the reply includes
`baselines_deleted`. A service restart deterministically marks stored `queued`
and `running` jobs failed with `evaluation_service_restarted`; it never
silently replays model calls. Decide whether application code explicitly
resubmits such work and preserve external idempotency where it does.

Raw submission preparation no longer runs in the service mailbox. At most 64
monitored validation workers run concurrently, each with a one-second timeout
and 1,048,576-word heap ceiling. Capacity/worker failures return the structural
`evaluation_request_validation_busy`,
`evaluation_request_validation_timeout`,
`evaluation_request_validation_failed`, or
`evaluation_request_validation_unavailable` errors, and `capabilities/1`
reports `pending_submissions`. Update callers that previously assumed every
rejected raw request would use only a set-validation error.

### Add trace retention only for metadata

The existing exporters and Developer UI snapshots continue to work without a
trace store. To retain bounded local history, supervise `adk_trace_store` and
either append already-versioned events directly or bind an integration adapter.
Use `adk_trace_store_exporter` in an observability descriptor, and use the
opaque value from `adk_trace_store:lifecycle_receiver/1,2` as a workflow's
`lifecycle_receiver`. Both adapters fix the store and principal outside event
data. Existing PID workflow receivers remain compatible; trace-store failure
on the workflow path is best-effort. Use a stable authenticated principal
binary; the store retains its digest, not the raw value.

Setting `trace_store_enabled` uses `adk_trace_runtime` to start the configured
store and observability bus, reserve/install the trace-store exporter, and add
asynchronous metadata-only observability to
`erlang_adk:runtime_runner_spec/0`. It does so even when
`observability_bus_enabled` is false. The standard CLI, evaluation-agent, and
developer HTTP paths consume that Runner spec. The
`erlang_adk:start_workflow/2,3` and `run_workflow/2,3` facades also mint a
lifecycle receiver unless the caller already supplied one. Direct
`adk_runner:new`, `adk_workflow:*`, resume, and durable-invocation callers are
not rewritten; pass the resolved Runner options or an explicit receiver for
those paths.

Configure `trace_store_principal` as a non-empty UTF-8 binary of at most 256
bytes (default `<<"local-runtime">>`). The names selected by
`trace_store_options` and `observability_bus_options` must be registered atoms.
Review any existing exporter with the reserved
`<<"erlang-adk-trace-store">>` ID before enabling the integration.

Keep `content_policy => reject` unless a trusted local owner explicitly wants
disallowed fields pruned. Size global and per-principal event/byte limits,
retention, `lifecycle_receiver_ttl_ms`, `max_lifecycle_pending`,
`max_prune_batch`, prune interval, and query limits together. Receiver TTL must
be at least event retention. Standard workflow delivery binds the capability
to the monitored local coordinator. An expired receiver is renewed while any
bound owner remains alive, so quiet work can still deliver its terminal event;
after all owners exit, normal TTL pruning resumes. Delivery beyond the pending
ceiling is dropped and counted; follow `lifecycle_pending`,
`lifecycle_active_owners`, `lifecycle_delivery_dropped`, and `more_pending`
during rollout. Consumers must handle `replay_gap` and
`cursor_ahead` rather than treating a partial history as complete. This
volatile node-local cache is not an audit log and should not be used for
billing, compliance retention, or cross-node tracing.

### Adopt object artifacts and vector/governed memory explicitly

The existing ETS/filesystem artifact and lexical ETS/Mnesia memory adapters
remain compatible. `adk_artifact_gcs` is a separate, exactly scoped,
GCS-compatible immutable adapter. Configure its bucket, project, opaque
credential callback, trusted transport, prefix, and byte/page/concurrency
limits outside agent data. Its first-party transport uses a fixed Google
Storage HTTPS origin; no request may select an endpoint or header.

Use `adk_artifact_stream` only when both adapters advertise the transfer
capability. Uploads use owner-bound chunk ACKs; downloads require explicit
message/byte credit and one ACK per chunk. The current worker bounds mailbox
flow but still materializes the complete bounded artifact, so do not describe
it as resumable/multipart or zero-copy GCS transfer.

Enable `artifact_effect_journal` when a least-authority artifact mutation must
survive an ambiguous event commit. The Mnesia journal stores intent, receipt,
digests, and lease state rather than content or credentials. Schedule bounded
`adk_artifact_orphan_reconciler:run/3` passes yourself and provide a trusted
backend handler that can observe and idempotently return committed,
compensated, or not-applied. The bundle does not infer backend outcomes or run
a universal continuous reconciler.

`adk_memory_embedding_provider`, `adk_memory_vector_ets`, and
`adk_memory_policy` are standalone foundations; creating them does not replace
the configured Runner memory service. The vector adapter is a bounded local
volatile cosine/hybrid reference, not a managed/distributed index. The policy
hook and static consent/TTL/retention/legal-hold implementation are opt-in;
callers must invoke them and enforce returned obligations. For durable
ingestion, stage the Mnesia erasure-epoch table with the outbox so stale work
cannot recreate erased data. Retention is an explicit bounded
`prune_terminal` operation over the terminal-time index, not a background
timer. The hard cap reserves terminal headroom for active jobs. Back up/restore
and multi-node topology remain operator work; majority readiness requires two
shared nodes but no node-loss Common Test has run.

### Select one MCP era and migrate A2A persistence/push deliberately

Keep existing stdio and session-bound Streamable HTTP integrations on a legacy
MCP era. Select modern `2026-07-28` only for stateless HTTP peers. Modern MCP
does not use GET/SSE replay; `legacy_sse_compat` is an explicit legacy-only
bridge. Review pool size/waiter limits, SSE credit, catalog generation/cursor
handling, and OAuth discovery/PKCE policy before enabling them. OAuth follows
RFC 9728 then RFC 8414, uses OIDC fallback only after 404, requires S256, and
does not follow redirects; a caller-provided fetch callback still owns TLS and
address trust. A disconnect never replays a possibly delivered mutation.

The pinned external matrix passed official Python `mcp` 2.0.0 at
`6f69a3758ebf2ee55ce050f58b470ce11af71133` and official TypeScript client
2.0.0 at `cc4b41617ce3601b1290d67216ea0b194a3cd9ac` in both modern
2026-07-28 and legacy-auto-fallback 2025-11-25 modes, without waivers. Preserve
that exact evidence in `scripts/conformance/mcp_external_sdk/RESULTS.json`, but
still run an application-owned HTTPS smoke against each peer you actually
deploy; two pinned SDKs do not certify the MCP ecosystem.

For A2A, adopt `adk_a2a_v1_agent_executor` to run registered agents through
Runner and use callback-driven stream APIs when incremental backpressure is
required. Configure no task store for the existing volatile behavior, or an
explicit bounded ETS/Mnesia store for validated public snapshots. A restored
submitted/working task becomes failed and is never replayed. Mnesia durability
and topology are deployment-owned, not transparent cluster failover.

Push configuration CRUD separates public configuration from authentication
secrets. Both halves live only in the server process, all registrations vanish
on restart, and the bounded single-worker queue drops the new delivery when it
is full. There is no durable delivery ledger or webhook-delivery guarantee.
The official A2A 1.0 TCK at
`5996b79f9cefa6fc390980e383e358a66fb9e49e` passed 100 cases with 165
expected transport/capability skips and no failures, errors, or expected
failures. Of the selected JSON-RPC surface, 94 passed and seven were
inapplicable skips. Re-run an application-owned authenticated HTTPS peer and
push test: the TCK used a loopback fixture and did not prove those deployment
boundaries, other transports, durable push, or multi-node node-loss recovery.

### Enable advanced evaluation, connectors, and developer inspection by need

The supervised store is the persistence/scheduling base. Add deterministic
operational/safety/cost/semantic metrics, user/environment simulators,
persisted-vote ensembles and calibration, human review, confidence/regression
statistics, and reporting only through their bounded modules.
`adk_eval_export:render/3` canonically renders JSON, Markdown, JUnit, SARIF,
and annotations for direct callers, stored-result `adk_eval_dev_api:report/5`,
the authenticated HTTP report route, existing eval-run output, and
`adk eval report`; avoid maintaining a separate renderer because these paths
are byte-parity checked. The common default/hard report ceiling is 16 MiB.
Lower only the HTTP report route with `dev_evaluation_report_max_bytes`;
unrelated CLI responses remain at 1 MiB and Developer request bodies at
64 KiB. The report CLI applies its dedicated limit equally to stdout and files.
Optional RPC workers accept only trusted allowlisted Erlang nodes and
rely on deployment-owned distribution security; they do not provide replay or
transparent failover. These are library/dev foundations, not hosted datasets,
automatic prompt optimization, or a managed evaluation control plane.

Curated Google, GitHub, Slack, and Postgres packages expose registry-only
connector descriptors/manifests. Treat package permission labels,
side-effect classifications, confirmation rules, and `parallel_safe` as
validated policy metadata. They do not authorize an identity, resolve a
credential, or isolate a trusted backend callback. Review the application
authorization and transport boundary, and do not infer that these development
packages are published or cover an arbitrary connector ecosystem. The sole
offline wrapper exercises every advertised operation through the real
registry, Agent Config, and `adk_toolset` path and verifies that policy metadata
survives projection; it still is not live-service or publication evidence.

The local UI graph catalog, trace overlay, and evaluation authoring endpoints
remain loopback/developer surfaces. Provider payload inspection is a separate
explicit `dev_provider_payload_inspection` opt-in, disabled by default. It is
redacted, JSON-normalized, bounded, volatile, failure-open, and protected by
the local developer bearer; it is not raw-wire capture, production telemetry,
general PII detection, or an audit log. Phoenix exposes only authorized
server-owned graph/metadata-trace projections; browser-selected modules,
stores, principals, and payload inspection remain forbidden.

### Treat deployment files as render-first assets

The relx release, non-root container, read-only-root mount contract,
health/drain endpoints, Cloud Run and Helm/GKE render/apply helpers, and
SBOM/scan/sign/provenance scripts are opt-in deployment assets. Both deploy
APIs default to validate-only; marker checks are not semantic Kubernetes
validation, and explicit apply does not wait for rollout, roll back, create
IAM, or create secrets.

Choose explicitly among three modes: the closed base release with no HTTP
listener, the packaged health-only relx template, or an application-owned
runtime config. Cloud Run selects the health-only target at
`/opt/erlang_adk/etc/health-http.sys.config` and relies on the
platform-injected `PORT`; Helm selects it when `service.enabled=true` and no
custom runtime ConfigMap is used. It exposes only `/livez` and `/readyz`, not
an agent/A2A/developer route. Cloud Run renders both Service- and
revision-scope `maxScale: "1"`, but this is not a hard singleton lease or a
guarantee that rollout revisions cannot overlap; its writable storage is
ephemeral. Helm still defaults to one replica, `Recreate`, no Service/Ingress,
existing Secret references, and default-deny networking.

If `runtimeConfig.existingConfigMap` is set, the ConfigMap must contain the
exact `sys.config` key. The chart mounts it at
`/opt/erlang_adk/etc/runtime/sys.config`, points `RELX_CONFIG_PATH` there, and
does not merge it with the health profile. Explicitly enable the listener(s)
you need, keep their port aligned with `service.targetPort`, and review
authentication, TLS/proxy, ingress, and network policy before exposing an
agent route.

The entrypoint now validates `ERLANG_ADK_NOFILE_CAP` from 1024 through 1048576
(65536 default) and lowers, but never raises, the inherited soft/hard open-file
limit before ERTS starts. Carry that default forward unless target-specific
memory/load evidence supports a different cap. PID 1 also owns one
readiness/drain/SIGTERM/reap sequence. Do not retain an older Helm `preStop`
drain: the generic/Helm drain budget is 30000 ms within a 60-second grace
period, while Cloud Run uses 3000 ms for its shorter shutdown window.

Deployment OTLP export is activated only by `ERLANG_ADK_OTLP_ENDPOINT`.
`OTEL_EXPORTER_OTLP_HEADERS` alone is ignored. Startup validates bounded
endpoint/header syntax and count using W3C-Baggage-style comma-separated
`key=value` entries, trims optional whitespace, lowercases names without
decoding, and percent-decodes values exactly once. It rejects raw semicolons,
metadata, malformed escapes, invalid decoded UTF-8, case-insensitive duplicate
names, and reserved-exporter conflicts without exposing endpoint/header values.
The endpoint is origin-only; paths, userinfo, queries, and fragments are not
accepted. The OTLP HTTP timeout is 3000 ms and its exporter guard is 4000 ms.
The bridge forces bus batch size one, and the effective bus batch timeout must
exceed the sum of all final exporter descriptor timeouts plus 250 ms. Review
that formula when combining deployment OTLP with trace retention or another
exporter. The bridge installs the configured trace-store exporter before
validation. If no timeout is set it chooses the greater of 5000 ms and the
final sum plus 251 ms, bounded by 300000 ms; an explicit undersized value fails
rather than being raised. Startup enables the bounded asynchronous bus and
wires metadata-only standard Runner observations even without local trace
retention. Helm obtains optional headers from an existing Secret; configure
collector egress explicitly.

Do not promote a target based on deterministic render tests. The final local
candidate did pass a constrained non-root/read-only-root OCI run and disposable
Kind rollouts for the closed/headless and packaged health-only Helm modes,
including nondefault `PORT`, health/404/drain behavior, memory observations,
and graceful recovery. Treat that as the exact local evidence in
`VERSION_0_10_0.md`, not as proof of the application-owned config mode, a
promoted registry, GKE/Cloud Run, or release. Generated SBOM, Grype scan,
Cosign sign/attest, and provenance verification remain not run. The Agent
Runtime files are feasibility evidence only. Their read-only probe reads the
bounded RFC 6750 bearer exactly from a named environment variable and passes
the Authorization header through curl standard-input config, not a process
argument. This credential handling does not prove target identity,
authorization, lifecycle, state, network, or conformance.

`adk_runtime_policy` is likewise an opt-in Runner/composition allow/deny and
byte-budget hook, not an organization role/permission system. If using the
durable invocation ledger, migrate an existing Mnesia table before startup
unless its record name/attributes, `set` type, majority setting, and local
`disc_copies` durability match exactly; initialization now fails closed rather
than reinterpreting or downgrading an incompatible table.

## Post-upgrade validation

Run every gate in [`TESTING.md`](TESTING.md) that applies to the deployment.
Specifically verify:

- no cross-user/session/run/Live visibility;
- exact OIDC callbacks, audiences, algorithms, scopes, and session rotation;
- binary profile/model selection, generation changes, missing credentials,
  and caller authority-override rejection;
- v1-to-v2 workflow checkpoint rewrite, definition mismatch rejection,
  durable attempt numbers, and at-least-once external idempotency;
- parallel/loop/transfer/graph nested pause recovery and typed workflow tool
  confirmation approve/reject/mismatch paths;
- graph topology warnings, join-policy cancellation, per-node schemas, state
  reducer type/conflict failures, and secret-free graph inspection;
- numeric-loopback local endpoint rejection/acceptance boundaries and Vertex
  resource/ADC/OAuth origin isolation;
- provider-native content, tools, structured output, streaming, and sanitized
  failure behavior for every configured endpoint;
- Anthropic `max_tokens >= 1` and 64 KiB synchronous/streaming Gun
  header/trailer rejection;
- OpenAI Realtime 24 kHz and Gemini Live 16 kHz input negotiation, manual/VAD
  turn completion, contiguous multi-frame priority ordering, and interruption
  cleanup;
- provider model/config selection and explicit paid-test flags;
- continuation and Live reconnect behavior under process/network loss;
- browser microphone permission cancellation, audio backpressure, and
  interruption cleanup;
- persistent adapter compatibility and restore/erasure behavior; and
- 0.10 runtime profile rejection, bundle-generation restart behavior, Agent
  Config v2 JSON/YAML normalization and registry/composition isolation,
  artifact range/credit/journal reconciliation, memory vector/policy/erasure/
  prune behavior, modern/legacy MCP separation, connector policy projection,
  evaluation queue/simulator/export/RPC bounds and restart recovery, trace
  principal/cursor/content boundaries, Developer UI payload opt-in, A2A stream/
  task-store/push restart behavior, and render-only deployment defaults when
  adopting the development APIs;
- explicit recording of the pinned MCP SDK and A2A TCK results, plus exact
  pass/fail/not-run status for multi-node node-loss, Docker/Cloud/Helm/Kind/GKE,
  and supply-chain execution rather than inferring one gate from another; and
- the still-visible Cowlib audit exception before exposing Phoenix.
