#!/bin/sh
set -eu

usage() {
  printf '%s\n' \
    'usage: rel/build-release.sh [--output DIR] [--source-date-epoch SECONDS]'
}

output='_build/deployment'
source_date_epoch=${SOURCE_DATE_EPOCH:-0}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      output=$2
      shift 2
      ;;
    --source-date-epoch)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      source_date_epoch=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

case "$source_date_epoch" in
  ''|*[!0-9]*)
    printf '%s\n' 'source date epoch must be a non-negative integer' >&2
    exit 64
    ;;
esac

case "$output" in
  /*|_build/*) ;;
  *)
    printf '%s\n' 'output must be absolute or below _build/' >&2
    exit 64
    ;;
esac

SOURCE_DATE_EPOCH=$source_date_epoch
export SOURCE_DATE_EPOCH

./rebar3 as prod compile
./rebar3 as prod release -c rel/relx.config -o "$output"

release_dir=$output/erlang_adk
if [ ! -x "$release_dir/bin/erlang_adk" ]; then
  printf '%s\n' 'release assembly did not produce bin/erlang_adk' >&2
  exit 1
fi

printf '%s\n' "$release_dir"
