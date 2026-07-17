# Ambient/background runtime

The 0.3.0 ambient runtime accepts event, queue, and schedule deliveries without
turning transport consumers into invocation owners. A registered trigger holds
an immutable `adk_runner` value. Each accepted event gets a stable binary
reference and one temporary child under `adk_ambient_job_sup`; the child owns
admission, retry, the current `adk_run`, deadline cleanup, and exactly one
ambient terminal outcome.

## Public API

```erlang
ok | {error, Reason} =
    adk_ambient:register_trigger(Name, Runner, TriggerOptions),

{ok, EventRef} | {ok, EventRef, duplicate} | {error, Reason} =
    adk_ambient:submit(Name, Event),

{ok, Status} = adk_ambient:status(EventRef),
Outcome = adk_ambient:await(EventRef, Timeout),
ok = adk_ambient:cancel(EventRef, Reason),
{ok, TriggerStatus} = adk_ambient:trigger_status(Name),
ok = adk_ambient:unregister_trigger(Name).
```

`run/2,3` is the submit-then-await convenience. `unregister_trigger/1` rejects
a busy trigger rather than orphaning its queued or active events.

Every event is a map with these keys:

- `payload` (required): non-empty UTF-8 text or a validated versioned
  `adk_content` value accepted by Runner;
- `idempotency_key` (required): non-empty UTF-8 binary used for node-local
  dedupe;
- `session`: required only by the `explicit` session policy;
- `timeout_ms`: optional shorter deadline than the trigger maximum;
- `metadata`: optional application metadata returned by status.

Unknown event and trigger option keys, non-JSON metadata/content, and any
secret-bearing key or token-bearing URL fail before admission. Canonical
binary-key metadata and content are bounded by `max_event_bytes` before they
are retained. Registration also validates that its opaque value is an actual
`adk_runner`; malformed routes do not survive until delivery time.

## Outcomes and status

Ambient outcomes are:

```erlang
{completed, #{run_id := RunId, output := Output}}
{paused, #{run_id := RunId, event := PauseEvent}}
{failed, Reason}
{timed_out, deadline_exceeded}
{cancelled, Reason}
```

A pause is terminal for the ambient delivery and exposes the underlying run ID
for the application's normal `adk_run:resume/2,3` policy. Status never exposes
worker pids, monitor references, Runner records, or admission permits.

## Session policies

Registration must select exactly one policy:

```erlang
#{mode => per_event, user_id => <<"worker">>, prefix => <<"event-">>}
#{mode => explicit}
#{mode => shared, user_id => <<"worker">>, session_id => <<"batch">>}
```

`per_event` hashes the idempotency key into a stable distinct session ID.
Retries therefore see the same event session while different deliveries cannot
cross conversation histories. `explicit` lets a verified transport adapter
supply user/session identity. `shared` is intentional shared history and must
not be selected merely as a convenience default.

## Bounds and failure semantics

The registry reads application-wide `max_triggers` and `max_events` ceilings
from `application:get_env(erlang_adk, ambient_runtime, #{})` when its
supervision tree starts.
Each trigger separately bounds concurrency, queued events, retained terminal
events, event bytes, and waiters. Queue intake is a `gen_server:call`, so a
source learns whether the delivery was accepted before acknowledging it. The
runtime owns one timer for the earliest queued deadline rather than one timer
per delivery.

One admission permit covers the complete event, including retry backoff. It is
released synchronously before the ambient terminal notification is published.
`admission_id` defaults to the trigger name; deployments should align that
identity's admission-controller limit with the trigger's `max_concurrency`.
If node-wide admission rejects a job after local acceptance, the event fails
explicitly and a durable source may redeliver with the same idempotency key.
Each retry attempt starts a new independently supervised `adk_run`; an attempt
guard cancels that run if a hard retry timeout or job cancellation kills its
awaiter. Queue wait, backoff, and every attempt consume one monotonic absolute
deadline. Retry jitter supports `none` and full jitter through `adk_retry`.

Idempotency entries live exactly as long as retained terminal status. The core
does not claim distributed or restart-durable dedupe. A durable broker remains
the delivery source of truth and should redeliver using its stable delivery ID.
Tools with external effects must independently enforce idempotency because an
entire failed invocation can be retried.

## Trigger sources

`adk_trigger_source` defines the supervised adapter contract. The bundled
`adk_trigger_schedule` adapter uses a single fixed-delay timer, derives a key
from schedule ID plus wall-clock interval slot, and submits through the same
bounded API. It deliberately does not parse cron expressions.

Provider adapters for Pub/Sub, Eventarc, Kafka, RabbitMQ, SQS, or cron services
belong in the deployment application. They verify/authenticate provider input,
normalize it to the event map, call `adk_ambient:submit/2` with backpressure,
and acknowledge only an accepted or duplicate delivery. No cloud client SDK is
a dependency of `erlang_adk`.

## Verification

- `adk_ambient_test` covers queue bounds/deadlines, dedupe, retries,
  cancellation cleanup, explicit and per-event sessions, and schedule sources.
- `adk_ambient_concurrency_SUITE` submits 100 events, observes an exact
  concurrency ceiling of eight, and verifies empty runtime/admission state.
- Dialyzer checks the public/status terms and cleanup paths.
