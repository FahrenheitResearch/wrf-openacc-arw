#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/remote/common.sh
source "$script_dir/common.sh"

usage() {
  cat >&2 <<'EOF'
usage: status_wrf_workers.sh --worker label,host,port,remote-dir[,user[,identity-file]] [--worker ...]

example:
  status_wrf_workers.sh \
    --worker default,116.122.206.233,21586,/root/wrf-workers/wrf-nvhpc-default \
    --worker hostfences,72.92.7.6,10069,/root/wrf-workers/wrf-nvhpc-hostfences
EOF
  exit 2
}

extract_field() {
  local key=$1
  local text=$2

  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' <<< "$text"
}

workers=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker)
      [[ $# -ge 2 ]] || usage
      workers+=("$2")
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

(( ${#workers[@]} > 0 )) || usage

require_cmd awk printf

printf '%-14s %-10s %-10s %7s %-10s %-10s %-24s %s\n' \
  label status pid wrfout elapsed age run_id bundle

for spec in "${workers[@]}"; do
  IFS=, read -r label host port remote_dir user identity_file extra <<< "$spec"
  [[ -n "${label:-}" && -n "${host:-}" && -n "${port:-}" && -n "${remote_dir:-}" ]] || die "bad --worker spec: $spec"
  [[ -z "${extra:-}" ]] || die "too many fields in --worker spec: $spec"

  user=${user:-$remote_default_user}
  identity_file=${identity_file:-$remote_default_identity}

  if ! output=$("$script_dir/check_wrf_worker.sh" --tail 0 "$host" "$port" "$remote_dir" "$user" "$identity_file" 2>/dev/null); then
    printf '%-14s %-10s %-10s %7s %-10s %-10s %-24s %s\n' \
      "$label" "unreach" "-" "-" "-" "-" "-" "${host}:${port}"
    continue
  fi

  status=$(extract_field status "$output")
  pid_status=$(extract_field pid_status "$output")
  wrfout_count=$(extract_field wrfout_count "$output")
  elapsed_hms=$(extract_field elapsed_hms "$output")
  latest_age_hms=$(extract_field latest_wrfout_age_hms "$output")
  run_id=$(extract_field run_id "$output")
  bundle_name=$(extract_field bundle_name "$output")

  printf '%-14s %-10s %-10s %7s %-10s %-10s %-24s %s\n' \
    "${label}" \
    "${status:-unknown}" \
    "${pid_status:-unknown}" \
    "${wrfout_count:-0}" \
    "${elapsed_hms:--}" \
    "${latest_age_hms:--}" \
    "${run_id:--}" \
    "${bundle_name:--}"
done
