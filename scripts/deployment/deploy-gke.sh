#!/bin/sh
set -eu

usage() {
  printf '%s\n' \
    'usage: deploy-gke.sh --manifest FILE --context CONTEXT --namespace NAMESPACE [--apply]'
}

manifest=''
context=''
namespace=''
apply=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; manifest=$2; shift 2 ;;
    --context) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; context=$2; shift 2 ;;
    --namespace) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; namespace=$2; shift 2 ;;
    --apply) apply=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

[ -r "$manifest" ] || { printf '%s\n' 'rendered manifest is required' >&2; exit 66; }
case "$context" in ''|*[!A-Za-z0-9:._/@-]*) printf '%s\n' 'invalid context' >&2; exit 64 ;; esac
case "$namespace" in ''|*[!a-z0-9-]*) printf '%s\n' 'invalid namespace' >&2; exit 64 ;; esac

if [ "$apply" != true ]; then
  digest=$(cksum "$manifest" | awk '{print $1 ":" $2}')
  printf 'validated render: %s (cksum %s)\n' "$manifest" "$digest"
  printf '%s\n' 'no changes made; pass --apply after review'
  exit 0
fi

command -v kubectl >/dev/null 2>&1 || { printf '%s\n' 'kubectl is required' >&2; exit 69; }
current_context=$(kubectl config current-context)
[ "$current_context" = "$context" ] || {
  printf 'refusing context mismatch: expected %s, current %s\n' "$context" "$current_context" >&2
  exit 65
}

kubectl --context "$context" --namespace "$namespace" apply -f "$manifest"
