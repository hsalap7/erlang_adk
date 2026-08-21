#!/bin/sh
set -eu

usage() {
  printf '%s\n' \
    'usage: build-image.sh --tag REGISTRY/IMAGE:TAG --output IMAGE.oci' \
    '       --build-base IMAGE@sha256:DIGEST --runtime-base IMAGE@sha256:DIGEST' \
    '       [--source-date-epoch SECONDS] [--apply]'
}

tag=''
output=''
build_base=''
runtime_base=''
source_date_epoch=${SOURCE_DATE_EPOCH:-0}
apply=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; tag=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; output=$2; shift 2 ;;
    --build-base) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; build_base=$2; shift 2 ;;
    --runtime-base) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; runtime_base=$2; shift 2 ;;
    --source-date-epoch) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; source_date_epoch=$2; shift 2 ;;
    --apply) apply=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

case "$tag" in ''|*[!A-Za-z0-9._/:+-]*) printf '%s\n' 'invalid image tag' >&2; exit 64 ;; esac
scripts/security/verify-image-ref.sh "$build_base" >/dev/null
scripts/security/verify-image-ref.sh "$runtime_base" >/dev/null
case "$source_date_epoch" in ''|*[!0-9]*) printf '%s\n' 'invalid source date epoch' >&2; exit 64 ;; esac
command -v docker >/dev/null 2>&1 || { printf '%s\n' 'docker with buildx is required' >&2; exit 69; }

set -- docker buildx build . \
  --tag "$tag" \
  --build-arg "ERLANG_BUILD_IMAGE=$build_base" \
  --build-arg "ERLANG_RUNTIME_IMAGE=$runtime_base" \
  --build-arg "SOURCE_DATE_EPOCH=$source_date_epoch" \
  --sbom=true \
  --provenance=mode=max

if [ "$apply" = true ]; then
  "$@" --push
else
  [ -n "$output" ] || { printf '%s\n' '--output is required unless --apply pushes' >&2; exit 64; }
  "$@" --output "type=oci,dest=$output"
fi
