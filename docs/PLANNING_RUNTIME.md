# Provider-neutral planning runtime

Erlang ADK 0.3.0 provides two complementary planning capabilities:

1. a provider adapter can add model-native thinking configuration or a
   planning instruction and process the corresponding model response; and
2. the public `erlang_adk` planning API executes an explicit, versioned plan
   through the bounded `adk_planning_runtime`.

This follows the externally visible contracts of Google ADK without copying
its Python class hierarchy. The official ADK
[`BasePlanner`](https://github.com/google/adk-python/blob/main/src/google/adk/planners/base_planner.py)
defines request-instruction and response-processing hooks.
[`BuiltInPlanner`](https://github.com/google/adk-python/blob/main/src/google/adk/planners/built_in_planner.py)
configures model-native thinking, while
[`PlanReActPlanner`](https://github.com/google/adk-python/blob/main/src/google/adk/planners/plan_re_act_planner.py)
uses structured planning, action, reasoning, replanning, and final-answer
sections. The Erlang explicit runtime adds OTP-native execution budgets,
cancellation, monitored callback isolation, and JSON transport boundaries; it
does not expose or attempt to reproduce provider-private reasoning.

## Planning contract

A trusted planner implements `adk_planner`:

```erlang
-behaviour(adk_planner).

plan(Target, Goal, Context, Config) ->
    {ok, Plan} | {complete, Value} | {error, Reason}.

review(Target, Plan, Step, Observation, Context, Config) ->
    continue
    | {replan, ReplacementPlan}
    | {complete, Value}
    | {fail, Reason}
    | {error, Reason}.
```

A trusted executor implements `adk_plan_executor`:

```erlang
-behaviour(adk_plan_executor).

execute(Target, Step, Context, Config) ->
    {ok, ObservationValue} | {error, Reason}.
```

The planner and executor are configured by descriptors. The module must
already be an atom and must export the behaviour callbacks; no module atom is
created from model or network input.

```erlang
Planner = #{module => my_planner,
            target => PlannerHandle,
            config => #{}},
Executor = #{module => my_plan_executor,
             target => ExecutorHandle,
             config => #{}},

{ok, Result} = erlang_adk:run_planning(
                 Planner, Executor,
                 #{<<"task">> => <<"prepare a release report">>},
                 #{<<"invocation_id">> => <<"run-42">>},
                 #{max_steps => 12,
                   max_replans => 2,
                   timeout_ms => 30000}).
```

The synchronous API returns `{ok, Result}` for completed, failed, and
cancelled executions. Configuration errors are returned as `{error, Reason}`
before a runtime is started. Use `start_planning/5`, `await_planning/2`, and
`cancel_planning/2` when the caller needs asynchronous cancellation:

```erlang
{ok, PlanningRef} = erlang_adk:start_planning(
                      Planner, Executor, Goal, Context, Options),
ok = erlang_adk:cancel_planning(PlanningRef, user_requested),
{ok, #{<<"status">> := <<"cancelled">>}} =
    erlang_adk:await_planning(PlanningRef, 5000).
```

The returned planning reference is opaque and owner-bound. Await/cancel from a
different process returns `{error, not_planning_owner}`; malformed or
mismatched references return `{error, invalid_planning_ref}`. If the owner
exits, the runtime kills the active callback worker and stops instead of
leaving orphaned work.

## Plan schema

Use `adk_plan:step/3,4` and `adk_plan:new/4,5` to construct canonical data.
`encode/1` and `decode/1` both validate the same versioned shape.

```erlang
{ok, Step} = adk_plan:step(
               <<"lookup">>,
               <<"Look up the release status">>,
               #{<<"kind">> => <<"tool">>,
                 <<"tool">> => <<"release_status">>,
                 <<"arguments">> => #{<<"release">> => <<"0.3.0">>}}),
{ok, Plan} = adk_plan:new(
               <<"release-plan">>, 0, Goal, [Step],
               #{<<"planner">> => <<"application">>}).
```

Canonical plans contain only binary JSON keys:

```text
plan = {
  schema_version, id, revision, goal, steps, metadata
}
step = {
  id, description, action, metadata
}
```

Plan IDs and step IDs are non-empty UTF-8 binaries. A plan contains at least
one step and step IDs are unique within a revision. Unknown fields,
atom/binary aliases for the same field, invalid UTF-8, unsupported Erlang
terms, and duplicate normalized map keys are rejected. Secret-like map fields
are removed before a plan, context, observation, cancellation reason, or
terminal result crosses the public JSON boundary.

An initial plan must use revision `0` and exactly match the sanitized goal.
A replacement plan must retain the plan ID and goal and increase the current
revision by exactly one. Step and replan budgets are cumulative across every
revision.

## Execution and failure behavior

Each planner and executor callback runs in a separate monitored lightweight
process. The runtime applies all of these limits:

| Option | Default | Meaning |
| --- | ---: | --- |
| `max_steps` | 16 | Total executor calls across every revision |
| `max_replans` | 3 | Accepted replacement plans |
| `timeout_ms` | 60000 | One absolute deadline for the whole run |
| `callback_timeout_ms` | 10000 | Per-callback upper bound, capped by the absolute deadline |
| `max_heap_words` | 500000 | Heap cap for each planner or executor worker |
| `max_plan_bytes` | 1048576 | Maximum canonical JSON size of each accepted plan |
| `result_metadata` | `#{}` | Secret-pruned caller metadata included in the terminal result |

Executor errors, exceptions, invalid return values, timeouts, and worker death
become error observations. The planner receives that observation and may
replan, complete, or fail. Planner callback failures and invalid decisions are
terminal. Absolute deadline expiry, step/replan budget exhaustion, explicit
cancellation, and every terminal failure are versioned JSON-safe result maps,
not uncaught exceptions.

The terminal result contains:

```text
result_schema_version, status, plan, steps_executed, replans,
duration_ms, observations, result, error, metadata
```

`status` is `completed`, `failed`, or `cancelled`. A completed result has a
null error. Failed and cancelled results have a null result and a structured
error with a stable `kind`.

## No model-supplied code execution

Plan actions are opaque JSON maps. The runtime never evaluates Erlang source,
shell fragments, functions, or module names found in a plan. Only the executor
module in the application-supplied trusted descriptor is invoked.

Applications should map a small declared action vocabulary to existing tools,
agents, or workflows. Any future code-execution capability must use a separate
external sandbox or isolated port with its own policy and resource controls;
it is deliberately outside this runtime.

## Agent and Runner integration boundaries

Gemini model-native thinking is configured on the immutable agent spec through
`generation_config.thinking_config`; provider request/response encoding and
thought-summary separation are therefore active for direct Agent and Runner
invocations. Explicit application planning is invoked through the public
`erlang_adk` planning API and is not silently attached to every Agent/Runner
turn.

An application can deliberately call an Agent, Runner, workflow, or declared
tool from its trusted `adk_plan_executor`. That adapter remains responsible for
using the corresponding public API and policy. Keeping that bridge explicit
prevents plan data from bypassing Runner tool policy, approval, auth,
observability, or persistence boundaries, and avoids inventing dynamic module
atoms from model output.

## Verification

`adk_planning_runtime_test` and `erlang_adk_planning_test` deterministically
cover the lower-level runtime and every public planning arity: plan round
trips, secret
pruning, opaque terms, duplicate and unknown fields, normal completion,
replanning, total step and replan budgets, absolute and callback timeouts,
planner/executor crash and invalid output, strict revision identity, plan byte
limits, callback heap isolation, cancellation worker cleanup, atom safety, and
result codec validation.

```bash
./rebar3 eunit --module=adk_planning_runtime_test,erlang_adk_planning_test
```
