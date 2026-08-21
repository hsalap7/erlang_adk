#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'usage: sign-image.sh --image IMAGE@sha256:DIGEST [--apply]'
}

image=''
apply=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --image) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; image=$2; shift 2 ;;
    --apply) apply=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

scripts/security/verify-image-ref.sh "$image" >/dev/null
if [ "$apply" != true ]; then
  printf 'validated immutable image: %s\n' "$image"
  printf '%s\n' 'no signature written; pass --apply in an OIDC-enabled release job'
  exit 0
fi
command -v cosign >/dev/null 2>&1 || { printf '%s\n' 'cosign is required' >&2; exit 69; }
cosign sign --yes "$image"
