# Context selection, compaction, and caching

Erlang ADK treats model context as a bounded provider request, not as a mutable
bag shared by processes. Session events remain in the configured session
service as source history; restart durability requires a durable backend such
as `erlang_adk_session_mnesia`, while the default ETS backend is volatile.
Each invocation builds an immutable, secret-pruned view for one model call.
Different sessions can do this work concurrently in supervised lightweight
processes.

## Runner context policy

Runner always canonicalizes history and removes known credential-bearing keys
at the model boundary. A `context_policy` additionally enables filtering,
selection, compression, and explicit budgets:

```erlang
Runner = adk_runner:new(
    AgentPid, <<"my_app">>, erlang_adk_session,
    #{context_policy =>
          #{max_bytes => 32768,
            max_tokens => 8192,
            max_request_bytes => 65536,
            max_request_tokens => 16384,
            bytes_per_token => 4,
            overflow => truncate}}).
```

`max_bytes` and `max_tokens` apply to selected canonical events. The
`max_request_*` limits apply later to the complete sanitized provider envelope:
effective instructions and generation settings, selected history, retrieved
memory, the current input, complete multimodal parts, tool declarations, and a
conservative framing allowance. Exceeding that final boundary returns
`{error, {request_context_budget_exceeded, Details}}` before provider I/O.

`overflow => truncate` keeps the newest complete selection units and never
splits a tool call from its responses. The current invocation input cannot be
filtered out. `overflow => error` returns a structural budget error.
`overflow => compress` requires an `adk_context_compressor` callback and runs
it in an owner-bound, timeout/heap/input/output-bounded process.

Supported filters cover author, invocation ID, content type, timestamp range,
partial events, and final events. Unknown policy keys are rejected when the
Runner is created. Selection is chronological, multimodal-aware, and linear in
the event count.

The context-build telemetry event is `[erlang_adk, context, build]`; complete
envelope accounting emits `[erlang_adk, context, envelope]`. Metadata contains
counts, byte/token estimates, and deterministic fingerprints, never event
content or provider credentials. Key-based secret pruning is a safety boundary,
not a promise to detect every kind of PII in arbitrary prose.

## Least-authority tool context

Local tools declare context access through the optional
`context_capabilities/0` callback:

```erlang
context_capabilities() ->
    [state_read, artifact_put, artifact_get, memory_search].
```

The corresponding helpers are:

```erlang
{ok, Identity} = adk_context:identity(Context),
{ok, State} = adk_context:state(Context),
{ok, ArtifactMeta} = adk_context:save_artifact(
    Context, <<"reports/result.txt">>, <<"ready">>,
    #{mime_type => <<"text/plain">>}),
{ok, Artifact} = adk_context:load_artifact(
    Context, <<"reports/result.txt">>, latest),
{ok, Hits} = adk_context:search_memory(
    Context, <<"release preference">>, #{filter => #{}, limit => 5}).
```

The full declaration set is `identity`, `state_read`, `artifact_put`,
`artifact_get`, `artifact_list`, `artifact_list_versions`, `artifact_delete`,
`artifact_attach`, `memory_search`, `memory_add`, and `memory_delete`.
`identity` is always included in a declared projection. The opaque token is
scope-bound, owner-coordinated, deadline-bounded, and revoked when that tool
call's effects are collected. Remote OpenAPI and MCP tools do not receive local
context handles.

Modules without the callback retain the 0.5 compatibility context. This is not
the recommended contract for new tools and may be tightened in a future major
compatibility transition.

## Automatic Runner compaction

`adk_context_compaction` is a provider-neutral lifecycle core. It selects a
trigger, retains recent complete exchanges, runs an application-supplied
compactor, and returns canonical summary events plus a versioned JSON-safe
checkpoint. Runner compiles this policy at construction and invokes it before
context selection:

```erlang
Runner = adk_runner:new(
    AgentPid, <<"my_app">>, erlang_adk_session,
    #{context_compaction =>
          #{compactor => my_context_compactor,
            token_threshold => 16000,
            event_threshold => 500,
            turn_interval => disabled,
            retain_recent_exchanges => 4,
            timeout_ms => 5000,
            max_summary_bytes => 262144}}).
```

The callback implements `adk_context_compactor`:

```erlang
-module(my_context_compactor).
-behaviour(adk_context_compactor).
-export([compact/2]).

compact(Events, _Request) ->
    %% Production implementations normally call a trusted summarization
    %% service here. The core validates and bounds the returned content.
    {ok, iolist_to_binary(
           io_lib:format("Summary of ~B prior events", [length(Events)]))}.
```

Token pressure wins when several triggers fire together. Explicit
cancellation, owner death, a deadline, heap growth, malformed summaries, and
oversized output all stop the isolated worker with a structural error.

On a compaction decision, Runner calls the session service's optional
`compact_events/5`. It replaces only the exact chronological prefix selected
for summarization, keeps concurrent later appends, and adds the checkpoint to
the summary event. A prefix mismatch fails closed as a conflict. The bundled
ETS and Mnesia session services implement this atomic contract; constructing a
Runner with compaction and a backend without `compact_events/5` fails eagerly.
Compaction remains opt-in and never rewrites a session when the option is
absent.

Applications can call `adk_context_compaction:compile/1` and `evaluate/3`
directly, but the lifecycle module itself still does not persist. Direct
callers own the same atomic event/checkpoint commit requirement.

## Provider-request prefix cache

`adk_context_cache` coordinates provider-managed prefix resources. It is not a
model-response cache: every invocation still calls the model. Cache keys cover
the provider, app, user, model, policy, sanitized prefix, and TTL. Concurrent
misses for the same key join one supervised create operation.

```erlang
{ok, CachePid} = adk_context_cache:start_link(
    #{max_entries => 256,
      default_ttl_ms => 300000,
      max_ttl_ms => 3600000,
      min_prefix_tokens => 1024,
      failure_mode => bypass}),

Scope = #{app => <<"my_app">>,
          user => <<"user-42">>,
          model => <<"gemini-3.1-flash-lite">>,
          policy => #{context_version => 1}},
StableHistory =
    [#{<<"role">> => <<"user">>,
       <<"parts">> => [#{<<"text">> => <<"stable prior turn">>}]}],
ToolDeclarations = [],
Prefix = #{<<"system_instruction">> => <<"You are concise.">>,
           <<"model">> => <<"gemini-3.1-flash-lite">>,
           <<"history_prefix">> => StableHistory,
           <<"tools">> => ToolDeclarations},

CacheResult = case adk_context_cache:acquire(
    CachePid, my_cache_provider, Scope, Prefix,
    #{ttl_ms => 300000,
      deadline_ms => erlang:monotonic_time(millisecond) + 5000}) of
    {ok, Lease, PublicMetadata} ->
        {ok, PrivateProviderResource} =
            adk_context_cache:resolve(CachePid, Lease),
        %% Consume PrivateProviderResource immediately in the provider
        %% adapter; never persist, log, or return it from an endpoint.
        {hit, PrivateProviderResource, PublicMetadata};
    {bypass, PublicMetadata} ->
        {bypass, PublicMetadata};
    {error, Reason} ->
        {error, Reason}
end.
```

`my_cache_provider` above denotes an application module implementing
`adk_context_cache_provider`; the following Runner example uses the bundled
Gemini provider.

A cache provider implements `create/2` and `delete/2` from
`adk_context_cache_provider`. Provider resource names remain behind private,
generation-checked leases and must never be written to events, checkpoints,
telemetry, developer responses, or logs. `invalidate/3`, `invalidate/4`, and
TTL expiry delete resources through bounded workers. Registry capacity,
prefix/scope bytes, waiters, creation/deletion deadlines, and callback heap are
all finite.

Absolute waiter deadlines are enforced synchronously at the provider-result
boundary, not only by timer-message order. Immediately before a successful
create is installed, the registry rechecks every waiter against the monotonic
clock. Expired waiters receive the configured deadline failure/bypass result.
If none remain, the provider resource is treated as an orphan and deleted
through the bounded cleanup path; it never becomes an unreachable cache entry.
The provider-neutral lifecycle suite passes ten tests, including the case
where a result message was queued before the deadline but processed after it.

`failure_mode => bypass` safely falls back to an uncached provider request;
`error` fails the invocation path using the cache. A prefix below
`min_prefix_tokens` is bypassed without a provider create call.

The provider-neutral registry is implemented and deterministically tested.
Runner accepts an explicit registry/provider configuration and scopes it from
the active app, user, and agent model:

```erlang
{ok, CachePid} = adk_context_cache:start_link(
    #{min_prefix_tokens => 4096,
      default_ttl_ms => 300000,
      failure_mode => bypass}),
Runner = adk_runner:new(
    AgentPid, <<"my_app">>, erlang_adk_session,
    #{context_cache =>
          #{cache => CachePid,
            provider => adk_context_cache_gemini,
            ttl_ms => 300000,
            policy => #{context_version => 2}}}).
```

That Runner option is intentionally smaller than the provider's runtime-only
configuration. For each model call Runner derives the exact app/user/model
scope and an absolute deadline, then passes this strict shape to Gemini:

```erlang
#{cache => CachePid,
  provider => adk_context_cache_gemini,
  scope => #{app => App,
             user => User,
             model => <<"gemini-3.1-flash-lite">>,
             policy => Policy},
  ttl_ms => 300000,
  deadline_ms => AbsoluteMonotonicMilliseconds}.
```

Applications normally configure the smaller Runner option rather than
constructing this runtime map. Gemini first builds and validates the final wire
payload, then derives a prefix with the binary keys `model`,
`system_instruction`, `history_prefix`, and `tools`. The history prefix is all
chronological content except the final content.

`adk_context_cache_gemini` is restricted to
`gemini-3.1-flash-lite`, uses a conservative local 4,096 estimated-token floor,
and maps create/get/TTL-update/delete to Gemini's
[CachedContent REST API](https://ai.google.dev/api/caching). Google currently
documents [caching support for this model](https://ai.google.dev/gemini-api/docs/models/gemini-3.1-flash-lite),
while the [explicit caching guide](https://ai.google.dev/gemini-api/docs/generate-content/caching)
says the minimum varies by model but does not publish a number for 3.1
Flash-Lite. The service response therefore remains authoritative. The adapter
reads the API key from `GEMINI_API_KEY`. Its
private `gemini_context_cache` application setting is a strict map containing
only optional `base_url`, `api_key`, and `request_timeout_ms` keys; an omitted
`api_key` falls back to the environment:

```erlang
ok = application:set_env(
    erlang_adk, gemini_context_cache,
    #{request_timeout_ms => 5000}).
```

Google's `cachedContents/...` name remains behind the private lease.
`failure_mode => bypass` continues with an uncached request when creation is
unavailable.

On an active request, Gemini receives `cachedContent` plus only the final
chronological content and non-prefix generation/safety fields. On bypass it
receives the original complete request. Content-free provider metadata records
the public cache lifecycle and Gemini's cached-token usage on Runner events;
neither the private lease nor provider resource name is projected. The direct
compatibility prompt API continues to return only the model answer.

The checked-in, historically named
`readme_live_gemini_SUITE:context_cache/1` REST gate uses a real Runner and
verifies cached-content creation, reuse across two exact sessions, the public
`created` then `hit` lifecycle, and absence of the private provider resource
from durable events. In the full 2026-07-14 billable Gemini REST run,
cached-content creation returned HTTP 429 and the one bounded retry after ten
seconds also returned 429. No resource was returned, so generation/reuse could
not run. This case is **rate-limited and failed**, not passed or skipped; the
other 14 REST cases passed and Google Search grounding was the only other 429
failure. The deterministic fake-provider and exact-wire suites remain the
implementation evidence, but do not convert this billable provider result into
a REST pass.

## Developer diagnostics

`GET /dev/v1/context/:app/:user/:session` applies a bounded diagnostic policy
to one exact session and returns only counts, compression status, and
fingerprint metadata. It deliberately omits events, state, retrieved memory,
artifact bytes, cache resource names, and credentials. See the integrated
developer tooling section of the README for authenticated startup and exact
resource-provider wiring.

When `dev_runner_options.context_cache` contains the same private Runner cache
configuration used for execution,
`GET /dev/v1/context/:app/:user/:session/lifecycle?model=MODEL` adds a
content-free lifecycle view. It reconstructs only whitelisted identifiers,
trigger/source fingerprints, and counts from the latest valid compaction
checkpoint, plus cache entry/in-flight/waiter counts and a 64-character scope
fingerprint. It never returns events, summaries, state, policy values, PIDs,
leases, provider resource names, prefixes, or credentials.

`POST /dev/v1/context/:app/:user/:session/cache/invalidate` requires an exact
confirmation containing `app_name`, `user_id`, `session_id`, `model`, and the
current `scope_fingerprint`. The session is an authorization and confirmation
anchor, not part of the cache registry key. Invalidation removes every entry
and in-flight create for the exact configured provider plus
`{app,user,model,policy}` scope across sessions, TTLs, and prefixes. Body,
field, and absolute diagnostic-deadline bounds still apply. The matching CLI
commands are `adk inspect context-lifecycle ... --model MODEL` and
`adk context-cache invalidate ... --model MODEL --confirm-json JSON`.
