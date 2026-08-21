#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'usage: generate-sbom.sh --image IMAGE@sha256:DIGEST --output SBOM.cdx.json'
}

image=''
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --image) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; image=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; output=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

scripts/security/verify-image-ref.sh "$image" >/dev/null
[ -n "$output" ] || { printf '%s\n' '--output is required' >&2; exit 64; }
command -v syft >/dev/null 2>&1 || { printf '%s\n' 'syft is required' >&2; exit 69; }

temporary=$(mktemp "${output}.XXXXXX")
trap 'rm -f "$temporary"' EXIT HUP INT TERM
syft "$image" --output "cyclonedx-json=$temporary"
mv "$temporary" "$output"
trap - EXIT HUP INT TERM
printf '%s\n' "$output"
