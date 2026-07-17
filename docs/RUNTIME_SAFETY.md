# Runtime safety and admission control

Version 0.3.0 uses Erlang process ownership and monitoring for runtime safety.
The controls in this document are local runtime controls: they do not replace
endpoint authentication, authorization at a network boundary, or the existing
human-confirmation suspension flow.

## Admission control

`adk_admission_control` limits active work globally and per agent. Capacity is
represented by an opaque permit owned by an Erlang process. The controller
monitors that owner and returns capacity if the process exits, so a crashed
request process cannot leak a slot.

The controller supports two overflow policies:

- `reject` returns `{error, concurrency_limit_reached}` immediately.
- `queue` enters a bounded queue and waits until capacity is available or an
  absolute monotonic deadline expires.

Queue order is FIFO per agent. Across agents, the controller selects the oldest
currently eligible request. This prevents an agent already at its own limit
from blocking unrelated agents while retaining deterministic order for each
agent.

Example controller configuration:

```erlang
#{global_limit => 256,
  default_agent_limit => 16,
  agent_limits => #{<<"BatchAgent">> => 4,
                    <<"InteractiveAgent">> => 32},
  overflow => queue,
  max_queue => 1024,
  default_queue_timeout => 30000}
```

For direct use, always release in an `after` block. `acquire/3` associates the
permit with the calling process unless an explicit `owner` pid is supplied.

```erlang
Work = fun() -> <<"admitted work result">> end,
Deadline = erlang:monotonic_time(millisecond) + 5000,
case adk_admission_control:acquire(
       adk_admission_control, <<"InteractiveAgent">>,
       #{overflow => queue, deadline => Deadline}) of
    {ok, Permit} ->
        try
            Work()
        after
            ok = adk_admission_control:release(
                   adk_admission_control, Permit)
        end;
    {error, concurrency_limit_reached} ->
        retry_later;
    {error, queue_deadline_exceeded} ->
        request_timed_out
end.
```

`submit/3` is the non-blocking form. It returns a request reference and either
an immediate permit or a queued deadline. A queued caller can use `await/2` or
cancel the request with `cancel/2`. Cancellation also accepts the request
reference of active work and returns its permit exactly once.

The controller monitors both the queued caller and an explicit queued owner.
Caller death removes an abandoned reply target. Owner death removes the work
and reports `{error, owner_down}` to a surviving caller. Active owner death,
deadline expiry, cancellation, and explicit release all converge on one permit
revocation path.

`status/0` returns aggregate counts and configured limits. It deliberately
contains no pids, monitor references, permit references, queue request
references, arguments, or content.

## Runtime authorization policy

`adk_runtime_policy` compiles an immutable allow/deny and byte-budget policy.
The policy is fail-closed:

- an omitted agent or tool allow selector is an empty list;
- `deny` takes precedence over `allow`;
- malformed policies, subjects, arguments, or content are denied;
- argument and content limits are finite non-negative integers;
- the defaults are 64 KiB of canonical JSON tool arguments and 1 MiB of
  content.

Use `allow => all` only when the runtime boundary is intentionally permissive.

```erlang
{ok, Policy} = adk_runtime_policy:compile(
  #{id => <<"production-v1">>,
    agents => #{allow => [<<"Writer">>, <<"Reviewer">>],
                deny => [<<"LegacyAgent">>]},
    tools => #{allow => [<<"weather">>, <<"search_docs">>],
               deny => [<<"shell">>]},
    max_argument_bytes => 32768,
    max_content_bytes => 262144}),

{allow, AgentAudit} = adk_runtime_policy:check_agent(
                        Policy, <<"Writer">>, UserContent),
{allow, ToolAudit} = adk_runtime_policy:check_tool(
                       Policy, <<"weather">>, ToolArguments).
```

Binary content is measured as its UTF-8 payload size. Structured content and
tool arguments are normalized with `adk_json` and measured as canonical JSON.
Unsupported Erlang runtime values such as pids, references, ports, and funs are
denied rather than stringified.

Every check returns an audit decision with:

- a decision ID and timestamp;
- policy ID and policy fingerprint;
- operation, subject, outcome, and bounded reason tag;
- measured bytes and the applicable limit;
- a digest of the immutable decision value.

Audit decisions never contain runtime arguments, content, credentials,
exception text, pids, references, ports, or functions. Callers can append the
decision to their durable event/audit store. The digest is a corruption check,
not a cryptographic signature; deployments requiring independently verifiable
audit logs should sign or hash-chain stored events at the storage boundary.

## Runner and tool ordering contract

The Runner integration observes these ordering rules:

1. Acquire the per-agent/global admission permit for an invocation.
2. Check the agent allow/deny rule and original input-content budget before
   run lifecycle plugins or model work.
3. Run `on_user_message`/`before_run`, then recheck the effective input-content
   budget before persisting it.
4. Resolve dynamic toolsets using normal Erlang ADK precedence.
5. Check the final resolved tool name and arguments against runtime policy.
6. Run global then local tool callbacks for allowed calls only.
7. If the tool requires human confirmation, suspend through the existing
   confirmation mechanism; a policy denial never becomes an approval request.
8. Execute the tool and check bounded tool-result and final-output content.
9. Release the invocation permit in `after`, including failures and
   cancellation.

Policy enforcement therefore does not replace dynamic toolsets, alter plugin
precedence, or serialize independent Erlang processes. Admission is centralized
only for counters and queue ownership; admitted agent and tool work remains
concurrent.

## Telemetry

Admission decisions emit `[erlang_adk, admission, decision]` with wait time,
active/queued counts, outcome, and agent ID.

Runtime policy decisions emit `[erlang_adk, policy, decision]` with measured
bytes, limit, policy ID, operation, outcome, and reason. Neither event includes
arguments, content, credentials, exception terms, pids, references, request
references, or permit references.

## Phoenix ownership

Phoenix should normally start an `adk_run` and subscribe by stable run ID. The
Runner invocation worker owns the admission permit automatically; neither the
LiveView nor the short-lived HTTP request process should own or link the run.
If an application uses `adk_admission_control` directly for non-Runner work,
set `owner` to the supervised worker that actually performs that work. Process
monitoring then supplies cleanup without polling or a separate lease service.
