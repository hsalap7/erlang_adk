# Deployment assets (v0.10 development)

These assets package the root `erlang_adk` OTP application without changing
its fail-closed agent-network defaults. They are intended to be rendered,
reviewed, and then applied explicitly. Static repository coverage and a narrow
local candidate OCI/Kind gate are recorded below, but neither is release,
promoted-registry, GKE, or cloud evidence. No Cloud Run staging, registry
push/sign/attestation, or managed Agent Runtime success is claimed.

The release assets expose three deliberate runtime modes:

1. **Closed base release.** With no deployment config selected, all HTTP
   listeners remain disabled. This is also the Helm default while
   `service.enabled=false`.
2. **Built-in health-only release.** Select the packaged relx template through
   the base `RELX_CONFIG_PATH` described below. Cloud Run always selects this
   mode; Helm selects it when its Service is enabled and no custom runtime
   ConfigMap is supplied.
3. **Application-owned runtime config.** Supply a reviewed `sys.config` that
   explicitly enables the intended listeners and their security boundary.
   The Helm ConfigMap mode below replaces the built-in profile rather than
   merging with it.

Only the second mode is provided as a ready-to-render HTTP deployment profile,
and it is not a callable agent endpoint.

## Recorded local candidate gate

The final local candidate image `erlang-adk:0.10.0-final` built from fresh
locked dependencies with OCI/index digest
`sha256:d74eb0a349d45692b5bb59e5ac7f1bbbe3710a59cd2e0be5301a179ce28f92d7`.
A constrained direct run used 1 GiB/1 CPU, uid/gid 10001, a read-only root,
dropped capabilities, and no-new-privileges. `/livez` and `/readyz` returned
200, an agent route returned 404, PID 1 and BEAM both had `nofile` 65536,
current memory was about 103.9 MiB with no OOM/restart, and SIGTERM completed
with exit 0 in 1.218 seconds.

A disposable Kind cluster then passed both Helm modes exercised by the
candidate:

- closed/headless: rollout completed with no Service, read-only/non-root 1 GiB
  pod, 119,377,920 bytes current and 397,217,792 bytes peak memory;
- packaged health-only: the Service rendered nondefault `PORT=18081`, both
  health routes returned 200, the agent route returned 404, current/peak
  memory was 110,538,752/388,038,656 bytes, and restart count remained zero.

During drain, readiness became false and `/readyz` returned 503 while `/livez`
remained 200. Pod deletion exercised graceful termination/recovery in 1.822
seconds. The disposable cluster was deleted after the gate. The
application-owned third mode was not runtime-tested by these two Helm runs and
still requires review against its exact `sys.config`.

## Container and release

`Dockerfile` builds the release defined in `rel/relx.config`, includes ERTS,
and runs as uid/gid 10001. The image writes only below these explicit mounts:

- `/var/lib/erlang_adk` for durable/runtime state;
- `/var/log/erlang_adk` for crash and release logs; and
- `/tmp/erlang_adk` for temporary files and `HOME`.

Use a read-only root filesystem and mount all three paths. Override the exact
base-image tags with registry-approved digest references for a promoted build:

```sh
docker buildx build \
  --build-arg ERLANG_BUILD_IMAGE='erlang:27.3.4.14-alpine@sha256:…' \
  --build-arg ERLANG_RUNTIME_IMAGE='alpine:3.24.1@sha256:…' \
  --build-arg SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" \
  --provenance=mode=max --sbom=true .
```

The ordinary release starts with all HTTP disabled. The bundled
`etc/health-http.sys.config.src` template is a separate deployment profile.
When selected through
`RELX_CONFIG_PATH=/opt/erlang_adk/etc/health-http.sys.config`, the release
probes the paired `.src` template and renders the evaluated config through
`RELX_OUT_FILE_PATH=/tmp/erlang_adk`; the base path deliberately omits
`.src`. The listener uses `${PORT:-8080}` at `0.0.0.0`. It enables only
content-minimal `GET`/`HEAD` `/livez` and `/readyz`;
agent, A2A v1, developer, and legacy prompt routes remain disabled and other
paths return 404. This profile is a probe endpoint, not an agent API or a TLS/
authentication replacement. Do not enable the legacy unauthenticated prompt
route on a public address. Public A2A requires deployment-owned authentication
and TLS or a trusted TLS proxy, as enforced by the runtime.

The container entrypoint validates `ERLANG_ADK_NOFILE_CAP` in the range 1024
through 1048576 and defaults it to 65536. Before ERTS starts, PID 1 lowers the
process soft/hard open-file limit to the smallest of that cap and the inherited
soft/hard limits; it never raises an operator limit. This prevents ERTS from
sizing descriptor tables from container runtimes that inherit an extremely
large soft limit. Raise the cap only after measuring startup and steady-state
memory under the target runtime.

`deployment-health live` checks the supervised release process and calls the
structured relx RPC `adk_deployment_lifecycle:liveness_code/0`. `ready` calls
`readiness_code/0` after checking startup/drain markers and, when configured,
an executable dependency hook under `/opt/erlang_adk/hooks/`. Release control
uses the bundled `erl_call` over loopback distribution on port 9100. Set
`ERLANG_ADK_DIST_PORT` only when a reviewed `rel/vm.args` uses the same
loopback port; the value must be an integer from 1 through 65535.

PID 1 owns one shutdown sequence. On the first termination signal it removes
readiness, calls `drain_code/1`, forwards SIGTERM to BEAM, and remains alive to
reap the release after its shutdown completes. Do not add a second Helm
`preStop` drain. `ERLANG_ADK_DRAIN_TIMEOUT_MS` accepts 0 through 600000 and
defaults to 30000 ms; keep it below the platform termination window so BEAM
still receives time to stop. The Cloud Run template uses 3000 ms within that
platform's shorter shutdown window. The Helm default uses 30000 ms within its
60-second `terminationGracePeriodSeconds`. Kubernetes or the platform still
owns the final timeout and forced termination.

## Deployment OTLP bridge

`ERLANG_ADK_OTLP_ENDPOINT` is the sole activation switch for deployment-owned
OTLP/HTTP JSON export. When present, application startup validates that
endpoint (at most 2048 bytes) and parses
`OTEL_EXPORTER_OTLP_HEADERS` using the standard W3C-Baggage-style
comma-separated `key=value` encoding. The raw header environment is capped at
32768 bytes and 32 entries. Optional whitespace around each entry/name/value
is trimmed, header names are lowercased without percent decoding, and values
are strict percent-decoded exactly once. Raw semicolons, malformed escapes,
invalid decoded UTF-8, and case-insensitive duplicate names fail closed. The
endpoint is an HTTP(S) origin only: userinfo, query, fragment, and non-root path
components are rejected because the exporter supplies its fixed signal paths.
Startup installs the reserved bounded deployment exporter and enables the
observability bus. Invalid settings or a conflicting reserved exporter ID fail
without reflecting endpoint/header values. `OTEL_EXPORTER_OTLP_HEADERS` by
itself is ignored, so ambient platform credentials cannot silently enable
export.

Standard configured Runner paths then submit metadata-only observations to the
asynchronous bus even when the local trace store is disabled. Delivery remains
bounded best effort rather than a durable audit/WAL. The bridge forces
`batch_size => 1`, the exporter HTTP request timeout is 3000 ms, and its
monitored exporter guard is 4000 ms. The effective bus
`batch_timeout_ms` must be greater than the sum of every final exporter
descriptor timeout plus 250 ms; an incompatible timeout is rejected at
startup. Validation first installs any configured trace-store exporter, so the
formula covers the final ordered exporter list. When no bus timeout is set,
the bridge selects the greater of 5000 ms and `sum + 251 ms` (within the bus's
300000 ms maximum); an explicit undersized timeout is never silently raised.
In the Helm chart,
`otlp.enabled=true` requires `otlp.endpoint`; optional headers come from
`credentials.existingSecret` using `otlp.headersSecretKey`. Configure the
matching NetworkPolicy egress explicitly. Never put collector credentials in
values, an Agent Config file, or a ConfigMap.

## Cloud Run

Render an immutable manifest first:

```sh
scripts/deployment/render-cloud-run.sh \
  --image 'REGISTRY/IMAGE@sha256:DIGEST' \
  --service erlang-adk \
  --service-account 'RUNTIME_SA@PROJECT.iam.gserviceaccount.com' \
  --output /tmp/erlang-adk-cloud-run.yaml
```

The Cloud Run renderer accepts only `--max-instances 1`, and the rendered
manifest places `maxScale: "1"` at both the Service and revision-template
annotation scopes. Those autoscaling settings express the intended
single-replica operating envelope; they are not a hard distributed singleton
lease and must not be used to prove that revisions can never overlap during a
rollout. The template selects the built-in health-only profile at the exact
runtime path
`/opt/erlang_adk/etc/health-http.sys.config`. Cloud Run injects its reserved
`PORT`; the manifest does not set or override it. The resulting container
serves only `/livez` and `/readyz`, not an agent route. Deploying a callable
agent therefore still requires a separately reviewed application listener,
authentication, and routing configuration. Review the rendered file, then
apply it explicitly:

```sh
scripts/deployment/deploy-cloud-run.sh \
  --manifest /tmp/erlang-adk-cloud-run.yaml \
  --project PROJECT --region REGION --apply
```

The script never changes IAM and therefore never makes the service public.
Cloud Run's v1 Container schema does not accept a Kubernetes
`securityContext`, so non-root execution comes from the image's `USER` and the
platform cannot enforce the chart's `readOnlyRootFilesystem` setting. The
template mounts bounded in-memory data, log, and temporary paths, but those
paths are ephemeral and are not durable application storage. No successful
Cloud Run staging deployment is recorded by this guide.

## Helm / GKE

The chart defaults to one replica, `Recreate`, no Service or Ingress, a
read-only root filesystem, exec probes, and a default-deny NetworkPolicy with
DNS egress only. With `service.enabled=false` it does not select the health
HTTP profile. With `service.enabled=true`, it sets `PORT` to
`service.targetPort` and, unless a custom runtime config is selected, uses the
built-in health-only config at
`/opt/erlang_adk/etc/health-http.sys.config`. The Service therefore exposes
only probe routes by default, not an agent API. Render with an immutable image:

```sh
scripts/deployment/render-helm.sh \
  --image 'REGISTRY/IMAGE@sha256:DIGEST' \
  --release erlang-adk --namespace agents \
  --output /tmp/erlang-adk-gke.yaml
```

Review it, configure provider/OTLP egress explicitly, and apply only with:

```sh
scripts/deployment/deploy-gke.sh \
  --manifest /tmp/erlang-adk-gke.yaml \
  --context EXPECTED_CONTEXT --namespace agents --apply
```

More than one replica is rejected while `topology.singleReplicaOnly` is true.
Disable that guard only after configuring distributed session, task, artifact,
memory, evaluation, and trace stores appropriate for the selected features.
Credentials are accepted only through an existing Secret reference; the chart
does not generate or accept literal credential values.

`runtimeConfig.existingConfigMap` replaces the built-in profile with a
deployment-owned relx config. That ConfigMap must contain the exact key
`sys.config`; the chart mounts it read-only at
`/opt/erlang_adk/etc/runtime/sys.config` and points `RELX_CONFIG_PATH` there.
The file must explicitly enable every intended listener and keep its port in
sync with `service.targetPort`. It may enable the health-only listener with
`http_health_enabled`, but enabling an agent/A2A/developer route changes the
security contract and requires its own authentication, TLS/proxy, ingress, and
network-policy review. Do not place credentials in `sys.config`.

## Managed Agent Runtime feasibility probe

The files under `deploy/agent-runtime/` describe a read-only feasibility
boundary, not support for or deployment to a managed Agent Runtime. The
optional probe accepts only an exact HTTPS origin (or explicitly allowed
loopback HTTP), pinned public/extended Agent Card hashes, and the name of an
environment variable containing a bearer token. It calls only `ListTasks`.

The probe reads the token exactly from that environment variable, bounds it to
8192 bytes, rejects CR/LF and characters outside the RFC 6750 `b64token` set,
and feeds the Authorization header to curl through standard-input config. The
token is neither a command-line argument nor printed. These protections do not
prove workload identity, audience/rotation, tenant authorization, or any other
managed-runtime support boundary; no target-environment result is claimed.

## Supply chain

The helpers in `scripts/security/` support BuildKit SBOM/provenance output,
Syft SBOM generation, Grype scanning, and explicit Cosign sign/attest steps.
Signing and attestation require both an immutable image reference and
`--apply`; no key, token, or cloud credential is stored in this repository.
The static helper contracts passed for this candidate, but Syft SBOM
generation, Grype scanning, Cosign signing/attestation, provenance verification,
and registry push did not run: the tools were not installed and no registry
identity was authorized.
