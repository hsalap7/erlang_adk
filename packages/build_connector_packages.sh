#!/usr/bin/env bash

set -euo pipefail

connector_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
connector_repo_root=$(cd -- "$connector_script_dir/.." && pwd)
connector_rebar="$connector_repo_root/rebar3"
connector_normalizer="$connector_script_dir/normalize_connector_hex.escript"
connector_hex_offline=${HEX_OFFLINE:-1}
connector_packages=(
  erlang_adk_google
  erlang_adk_github
  erlang_adk_slack
  erlang_adk_postgres
)
connector_created_locks=()
connector_created_checkouts=()
connector_gate_tmp=""

connector_cleanup() {
  local connector_status=$?
  trap - EXIT
  if [[ -n "$connector_gate_tmp" && -d "$connector_gate_tmp" ]]; then
    rm -rf -- "$connector_gate_tmp"
  fi
  local connector_path
  for connector_path in "${connector_created_locks[@]-}"; do
    [[ -n "$connector_path" ]] || continue
    rm -f -- "$connector_path"
  done
  for connector_path in "${connector_created_checkouts[@]-}"; do
    [[ -n "$connector_path" ]] || continue
    rm -f -- "$connector_path"
    rmdir -- "$(dirname -- "$connector_path")" 2>/dev/null || true
  done
  exit "$connector_status"
}
trap connector_cleanup EXIT

connector_fail() {
  printf 'connector package gate failed: %s\n' "$*" >&2
  exit 1
}

connector_eunit_count() {
  local connector_log=$1
  local connector_summary
  connector_summary=$(rg -o '[0-9]+ tests?, 0 failures' "$connector_log" |
    tail -n 1) || true
  [[ -n "$connector_summary" ]] ||
    connector_fail "missing successful EUnit summary in $connector_log"
  printf '%s\n' "${connector_summary%% *}"
}

[[ -x "$connector_rebar" ]] || connector_fail "missing executable $connector_rebar"
[[ -f "$connector_normalizer" ]] || connector_fail "missing $connector_normalizer"
command -v escript >/dev/null || connector_fail "escript is not available"
command -v rg >/dev/null || connector_fail "rg is not available"
command -v shasum >/dev/null || connector_fail "shasum is not available"

connector_gate_tmp=$(mktemp -d "$connector_repo_root/.connector-package-gate.XXXXXX")
connector_source_total=0
connector_extracted_total=0

for connector_package in "${connector_packages[@]}"; do
  connector_package_dir="$connector_script_dir/$connector_package"
  connector_checkout="$connector_package_dir/_checkouts/erlang_adk"
  connector_lock="$connector_package_dir/rebar.lock"
  connector_archive="$connector_package_dir/_build/default/lib/$connector_package/hex/$connector_package-0.10.0.tar"
  connector_docs="$connector_package_dir/_build/default/lib/$connector_package/hex/$connector_package-0.10.0-docs.tar"
  connector_source_log="$connector_gate_tmp/$connector_package-source.log"
  connector_extracted_log="$connector_gate_tmp/$connector_package-extracted.log"
  connector_extract_dir="$connector_gate_tmp/$connector_package"

  [[ -d "$connector_package_dir" ]] ||
    connector_fail "missing package directory $connector_package_dir"

  if [[ ! -e "$connector_checkout" ]]; then
    mkdir -p -- "$(dirname -- "$connector_checkout")"
    ln -s -- "$connector_repo_root" "$connector_checkout"
    connector_created_checkouts+=("$connector_checkout")
  fi
  connector_checkout_target=$(cd -P -- "$connector_checkout" && pwd)
  [[ "$connector_checkout_target" == "$connector_repo_root" ]] ||
    connector_fail "$connector_checkout does not resolve to $connector_repo_root"

  if [[ ! -e "$connector_lock" ]]; then
    connector_created_locks+=("$connector_lock")
  fi

  printf '\n==> source gate: %s\n' "$connector_package"
  if ! (
    cd -- "$connector_package_dir"
    HEX_OFFLINE="$connector_hex_offline" "$connector_rebar" do clean, compile, eunit
  ) 2>&1 | tee "$connector_source_log"; then
    connector_fail "$connector_package source compile/EUnit"
  fi
  connector_source_count=$(connector_eunit_count "$connector_source_log")
  connector_source_total=$((connector_source_total + connector_source_count))

  printf '\n==> Hex build and normalization: %s\n' "$connector_package"
  (
    cd -- "$connector_package_dir"
    HEX_OFFLINE="$connector_hex_offline" "$connector_rebar" hex build
    escript "$connector_normalizer" "$connector_archive"
  )
  [[ -f "$connector_archive" ]] || connector_fail "missing $connector_archive"
  [[ -f "$connector_docs" ]] || connector_fail "missing $connector_docs"

  connector_package_hash=$(shasum -a 256 "$connector_archive" | awk '{print $1}')
  connector_docs_hash=$(shasum -a 256 "$connector_docs" | awk '{print $1}')
  printf 'package sha256 %s  %s\n' "$connector_package_hash" "$(basename -- "$connector_archive")"
  printf 'docs sha256    %s  %s\n' "$connector_docs_hash" "$(basename -- "$connector_docs")"

  mkdir -p -- "$connector_extract_dir"
  tar -xOf "$connector_archive" contents.tar.gz |
    tar -xzf - -C "$connector_extract_dir"
  if find "$connector_extract_dir" -type d -name _checkouts -print -quit |
      rg -q .; then
    connector_fail "$connector_package archive leaked a _checkouts directory"
  fi
  mkdir -p -- "$connector_extract_dir/_checkouts"
  ln -s -- "$connector_repo_root" "$connector_extract_dir/_checkouts/erlang_adk"

  printf '\n==> clean extracted gate: %s\n' "$connector_package"
  if ! (
    cd -- "$connector_extract_dir"
    HEX_OFFLINE="$connector_hex_offline" "$connector_rebar" do clean, compile, eunit
  ) 2>&1 | tee "$connector_extracted_log"; then
    connector_fail "$connector_package extracted compile/EUnit"
  fi
  connector_extracted_count=$(connector_eunit_count "$connector_extracted_log")
  connector_extracted_total=$((connector_extracted_total + connector_extracted_count))
done

printf '\nconnector package gate PASS: packages=%d source_eunit=%d extracted_eunit=%d hex_archives=%d docs_archives=%d\n' \
  "${#connector_packages[@]}" \
  "$connector_source_total" \
  "$connector_extracted_total" \
  "${#connector_packages[@]}" \
  "${#connector_packages[@]}"
printf '%s\n' \
  'offline inspection only: connector publication remains blocked until erlang_adk 0.10.0 is available in the target Hex repository'
