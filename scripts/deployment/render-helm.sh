#!/bin/sh
set -eu

usage() {
  printf '%s\n' \
    'usage: render-helm.sh --image IMAGE@sha256:DIGEST --release NAME' \
    '       --namespace NAMESPACE --output FILE [--values FILE]'
}

image=''
release=''
namespace=''
output=''
values=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; image=$2; shift 2 ;;
    --release) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; release=$2; shift 2 ;;
    --namespace) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; namespace=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; output=$2; shift 2 ;;
    --values) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; values=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

scripts/security/verify-image-ref.sh "$image" >/dev/null
case "$release" in ''|*[!a-z0-9-]*) printf '%s\n' 'invalid release name' >&2; exit 64 ;; esac
case "$namespace" in ''|*[!a-z0-9-]*) printf '%s\n' 'invalid namespace' >&2; exit 64 ;; esac
[ -n "$output" ] || { printf '%s\n' '--output is required' >&2; exit 64; }
[ -z "$values" ] || [ -r "$values" ] || { printf '%s\n' 'values file is not readable' >&2; exit 66; }

command -v helm >/dev/null 2>&1 || { printf '%s\n' 'helm is required to render the chart' >&2; exit 69; }

repository=${image%@sha256:*}
digest=sha256:${image##*@sha256:}
chart=deploy/helm/erlang-adk
[ -r "$chart/Chart.yaml" ] || { printf '%s\n' 'run from the repository root' >&2; exit 66; }

temporary=$(mktemp "${output}.XXXXXX")
trap 'rm -f "$temporary"' EXIT HUP INT TERM

set -- helm template "$release" "$chart" \
  --namespace "$namespace" \
  --set-string "image.repository=$repository" \
  --set-string "image.digest=$digest"
if [ -n "$values" ]; then
  set -- "$@" --values "$values"
fi
"$@" >"$temporary"

mv "$temporary" "$output"
trap - EXIT HUP INT TERM
printf '%s\n' "$output"
