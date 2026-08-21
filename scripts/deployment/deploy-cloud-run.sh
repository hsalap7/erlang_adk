#!/bin/sh
set -eu

usage() {
  printf '%s\n' \
    'usage: deploy-cloud-run.sh --manifest FILE --project PROJECT --region REGION [--apply]'
}

manifest=''
project=''
region=''
apply=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; manifest=$2; shift 2 ;;
    --project) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; project=$2; shift 2 ;;
    --region) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; region=$2; shift 2 ;;
    --apply) apply=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

[ -r "$manifest" ] || { printf '%s\n' 'rendered manifest is required' >&2; exit 66; }
case "$project" in ''|*[!A-Za-z0-9:._-]*) printf '%s\n' 'invalid project' >&2; exit 64 ;; esac
case "$region" in ''|*[!a-z0-9-]*) printf '%s\n' 'invalid region' >&2; exit 64 ;; esac

if [ "$apply" != true ]; then
  digest=$(cksum "$manifest" | awk '{print $1 ":" $2}')
  printf 'validated render: %s (cksum %s)\n' "$manifest" "$digest"
  printf '%s\n' 'no changes made; pass --apply after review'
  exit 0
fi

command -v gcloud >/dev/null 2>&1 || { printf '%s\n' 'gcloud is required' >&2; exit 69; }
gcloud run services replace "$manifest" --project "$project" --region "$region"
