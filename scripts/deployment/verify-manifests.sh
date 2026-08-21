#!/bin/sh
set -eu

scripts='scripts/deployment/container-entrypoint.sh
scripts/deployment/release-health.sh
scripts/deployment/render-cloud-run.sh
scripts/deployment/deploy-cloud-run.sh
scripts/deployment/render-helm.sh
scripts/deployment/deploy-gke.sh
scripts/security/build-image.sh
scripts/security/generate-sbom.sh
scripts/security/scan-sbom.sh
scripts/security/sign-image.sh
scripts/security/attest-provenance.sh
scripts/security/verify-image-ref.sh'

for script in $scripts; do
  [ -r "$script" ] || { printf 'missing script: %s\n' "$script" >&2; exit 1; }
  sh -n "$script"
done

image='registry.example.invalid/erlang-adk@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
cloud_output=$(mktemp)
helm_output=''
trap 'rm -f "$cloud_output" "$helm_output"' EXIT HUP INT TERM

scripts/deployment/render-cloud-run.sh \
  --image "$image" \
  --service erlang-adk \
  --service-account runtime@project.iam.gserviceaccount.com \
  --output "$cloud_output" >/dev/null

grep -Fq "image: $image" "$cloud_output"
grep -Fq 'autoscaling.knative.dev/maxScale: "1"' "$cloud_output"
grep -Fq 'run.googleapis.com/maxScale: "1"' "$cloud_output"
if grep -Fq -- '- name: PORT' "$cloud_output"; then
  printf '%s\n' 'Cloud Run must use the platform-injected PORT' >&2
  exit 1
fi
grep -Fq 'sizeLimit: 512Mi' "$cloud_output"

if command -v helm >/dev/null 2>&1; then
  helm_output=$(mktemp)
  scripts/deployment/render-helm.sh \
    --image "$image" --release erlang-adk --namespace agents \
    --output "$helm_output" >/dev/null
  grep -Fq 'replicas: 1' "$helm_output"
  grep -Fq 'kind: NetworkPolicy' "$helm_output"
  grep -Fq 'readOnlyRootFilesystem: true' "$helm_output"
fi

printf '%s\n' 'deployment manifest contracts passed'
