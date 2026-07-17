#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
minimum_coverage="${ERLANG_ADK_MIN_COVERAGE:-73}"

if [[ ! "${minimum_coverage}" =~ ^[0-9]+$ ]] ||
   (( minimum_coverage < 0 || minimum_coverage > 100 )); then
  echo "ERLANG_ADK_MIN_COVERAGE must be an integer from 0 to 100" >&2
  exit 2
fi

cd "${repo_root}"

# Rebar3 clean does not remove exported coverdata. Reset first so an old
# partial run can never be combined with the current source tree.
./rebar3 cover --reset
./rebar3 clean
./rebar3 eunit --cover --cover_export_name=eunit
./rebar3 ct --cover --cover_export_name=ct
./rebar3 cover --verbose --precision=2 \
  --min_coverage="${minimum_coverage}"
