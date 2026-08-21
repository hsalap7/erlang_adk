#!/bin/sh
set -eu

usage() {
  printf '%s\n' \
    'usage: render-cloud-run.sh --image IMAGE@sha256:DIGEST --service NAME' \
    '       --service-account EMAIL --output FILE [--port N] [--max-instances N]'
}

image=''
service=''
service_account=''
output=''
port=8080
max_instances=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; image=$2; shift 2 ;;
    --service) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; service=$2; shift 2 ;;
    --service-account) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; service_account=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; output=$2; shift 2 ;;
    --port) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; port=$2; shift 2 ;;
    --max-instances) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; max_instances=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

scripts/security/verify-image-ref.sh "$image" >/dev/null
case "$service" in
  ''|[!a-z]*|*-|*[!a-z0-9-]*)
    printf '%s\n' 'invalid Cloud Run service name' >&2
    exit 64
    ;;
esac
case "$service_account" in
  ?*@?*.iam.gserviceaccount.com) ;;
  *) printf '%s\n' 'invalid runtime service account email' >&2; exit 64 ;;
esac
case "$service_account" in *[!A-Za-z0-9.@_-]*) printf '%s\n' 'invalid runtime service account email' >&2; exit 64 ;; esac
case "$port" in ''|*[!0-9]*) printf '%s\n' 'port must be an integer' >&2; exit 64 ;; esac
case "$max_instances" in ''|*[!0-9]*) printf '%s\n' 'max instances must be an integer' >&2; exit 64 ;; esac
[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { printf '%s\n' 'port is out of range' >&2; exit 64; }
[ "$max_instances" -eq 1 ] || { printf '%s\n' 'foundation release is limited to one instance' >&2; exit 64; }
[ -n "$output" ] || { printf '%s\n' '--output is required' >&2; exit 64; }

template=deploy/cloud-run/service.yaml.tpl
[ -r "$template" ] || { printf '%s\n' 'run from the repository root' >&2; exit 66; }

if [ "$output" = '-' ]; then
  destination=/dev/stdout
  temporary=''
else
  temporary=$(mktemp "${output}.XXXXXX")
  destination=$temporary
  trap 'rm -f "$temporary"' EXIT HUP INT TERM
fi

sed -e "s|@@IMAGE@@|$image|g" \
    -e "s|@@SERVICE@@|$service|g" \
    -e "s|@@SERVICE_ACCOUNT@@|$service_account|g" \
    -e "s|@@PORT@@|$port|g" \
    -e "s|@@MAX_INSTANCES@@|$max_instances|g" \
    "$template" >"$destination"

if [ -n "$temporary" ]; then
  mv "$temporary" "$output"
  trap - EXIT HUP INT TERM
  printf '%s\n' "$output"
fi
