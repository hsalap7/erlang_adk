#!/bin/sh
set -eu

usage() {
  printf '%s\n' \
    'usage: attest-provenance.sh --image IMAGE@sha256:DIGEST --predicate PROVENANCE.json [--apply]'
}

image=''
predicate=''
apply=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --image) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; image=$2; shift 2 ;;
    --predicate) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; predicate=$2; shift 2 ;;
    --apply) apply=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

scripts/security/verify-image-ref.sh "$image" >/dev/null
[ -r "$predicate" ] || { printf '%s\n' 'provenance predicate is required' >&2; exit 66; }
if [ "$apply" != true ]; then
  printf 'validated provenance input for %s: %s\n' "$image" "$predicate"
  printf '%s\n' 'no attestation written; pass --apply in an OIDC-enabled release job'
  exit 0
fi
command -v cosign >/dev/null 2>&1 || { printf '%s\n' 'cosign is required' >&2; exit 69; }
cosign attest --yes --type slsaprovenance --predicate "$predicate" "$image"
