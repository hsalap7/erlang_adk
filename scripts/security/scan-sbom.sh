#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'usage: scan-sbom.sh --sbom SBOM.cdx.json --output RESULTS.sarif [--fail-on SEVERITY]'
}

sbom=''
output=''
fail_on=high
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sbom) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; sbom=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; output=$2; shift 2 ;;
    --fail-on) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; fail_on=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

[ -r "$sbom" ] || { printf '%s\n' 'SBOM is required' >&2; exit 66; }
[ -n "$output" ] || { printf '%s\n' '--output is required' >&2; exit 64; }
case "$fail_on" in negligible|low|medium|high|critical) ;; *) printf '%s\n' 'invalid severity' >&2; exit 64 ;; esac
command -v grype >/dev/null 2>&1 || { printf '%s\n' 'grype is required' >&2; exit 69; }

temporary=$(mktemp "${output}.XXXXXX")
trap 'rm -f "$temporary"' EXIT HUP INT TERM
set +e
grype "sbom:$sbom" --fail-on "$fail_on" --output sarif --file "$temporary"
status=$?
set -e
if [ -s "$temporary" ]; then
  mv "$temporary" "$output"
  trap - EXIT HUP INT TERM
fi
exit "$status"
