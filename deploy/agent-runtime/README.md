# Agent Runtime feasibility boundary

Status: **feasibility only**. Erlang ADK does not claim support for any managed
Agent Runtime from this spike. Nothing in this directory creates, updates, or
deletes cloud resources.

The spike deliberately stops at a portable boundary that a future
vendor-specific adapter could consume:

- the promoted OCI artifact is addressed by an immutable digest and runs as
  uid/gid `10001`;
- `/livez` and `/readyz` expose content-minimal process/admission health;
- `/.well-known/agent-card.json` exposes the public A2A 1.0 Agent Card;
- `/extendedAgentCard` exposes the authenticated, non-cacheable extended card;
- `/a2a/v1` is the A2A 1.0 JSON-RPC endpoint; and
- the feasibility probe invokes only `ListTasks`, so it cannot create, cancel,
  or otherwise mutate an agent task.

The machine-readable contract is
[`boundary-contract.json`](./boundary-contract.json). Validate that it still
matches the repository implementation from the repository root:

```sh
scripts/deployment/verify-agent-runtime-contract.sh
```

## Read-only deployed-boundary probe

The optional probe requires an exact HTTPS origin, expected SHA-256 hashes for
both cards, and the *name* of an environment variable containing a bearer
token. It does not accept a credential on the command line, follow redirects,
or call a cloud CLI. Plain HTTP is rejected except for an explicit loopback
test.

```sh
export ADK_AGENT_RUNTIME_PROBE_TOKEN='obtained-by-the-deployment-operator'

scripts/deployment/probe-agent-runtime.sh \
  --base-url 'https://agent.example.invalid' \
  --token-env ADK_AGENT_RUNTIME_PROBE_TOKEN \
  --expected-card-sha256 '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
  --expected-extended-card-sha256 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
```

Card hashes must come from reviewed deployment metadata or a separately
attested discovery step. Treat a hash mismatch as a changed boundary, not as a
reason to weaken the pin. The probe checks health, both pinned cards, the A2A
1.0 JSON-RPC binding, and a read-only `ListTasks` response. It never prints the
token.

## What remains unproven

All five blockers in the contract remain open and prevent a support claim:

- **Vendor lifecycle:** managed startup, drain, shutdown, upgrades, rollback,
  resource limits, and failure handling have no target-runtime adapter or
  staging evidence.
- **Identity:** workload identity, token audience/rotation, A2A authorization,
  tenant scoping, and least privilege have not been validated end to end.
- **Network:** TLS/ingress, DNS/egress, proxy behavior, streaming, private
  connectivity, request limits, and timeouts have not been certified.
- **State:** managed restart/migration behavior and external durable stores for
  sessions, tasks, artifacts, memory, evaluation, and traces are not proven.
- **Conformance:** the target vendor OCI contract, external A2A 1.0 suite,
  interoperability matrix, and managed-runtime fault injection remain to run.

Only target-environment evidence satisfying each `exitEvidence` item should
allow a later release to make a scoped support statement.
