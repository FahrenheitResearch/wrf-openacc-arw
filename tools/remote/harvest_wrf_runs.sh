#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/remote/common.sh
source "$script_dir/common.sh"

usage() {
  cat >&2 <<'EOF'
usage: harvest_wrf_runs.sh [--last N | --run-id RUN_ID ...] --worker label,host,port,remote-dir[,user[,identity-file]] [--worker ...]

examples:
  harvest_wrf_runs.sh \
    --last 2 \
    --worker default,116.122.206.233,21586,/root/wrf-workers/wrf-nvhpc-default \
    --worker hostfences,72.92.7.6,10069,/root/wrf-workers/wrf-nvhpc-hostfences

  harvest_wrf_runs.sh \
    --run-id 20260410T2007Z-default \
    --run-id 20260410T2007Z-hostfences \
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

build_remote_run_query() {
  local remote_dir=$1
  local last_n=$2
  shift 2
  local requested_ids=("$@")
  local requested_literal="()"
  local quoted=()
  local id

  if (( ${#requested_ids[@]} > 0 )); then
    for id in "${requested_ids[@]}"; do
      quoted+=("$(printf '%q' "$id")")
    done
    requested_literal="( ${quoted[*]} )"
  fi

  cat <<EOF
set -euo pipefail
worker_dir='$remote_dir/.worker'
runs_dir="\$worker_dir/runs"
state_file="\$worker_dir/state.env"
requested_run_ids=$requested_literal
last_n=$last_n
state_status=
state_run_id=
state_bundle_name=

read_state_field() {
  local key=\$1
  awk -F= -v key="\$key" '\$1 == key { print substr(\$0, index(\$0, "=") + 1); exit }' "\$state_file" 2>/dev/null || true
}

read_exit_field() {
  local file_path=\$1
  local key=\$2
  awk -F: -v key="\$key" '\$1 == key { print substr(\$0, index(\$0, ":") + 1); exit }' "\$file_path" 2>/dev/null || true
}

emit_run() {
  local run_id=\$1
  local run_dir="\$runs_dir/\$run_id"
  local exit_file="\$run_dir/exit_code.txt"
  local status=missing
  local exit_code=
  local wrfout_count=
  local elapsed_sec=
  local started_at=
  local finished_at=
  local bundle_name=

  if [[ -d "\$run_dir" ]]; then
    status=unknown
    exit_code=\$(read_exit_field "\$exit_file" exit)
    wrfout_count=\$(read_exit_field "\$exit_file" wrfout_count)
    elapsed_sec=\$(read_exit_field "\$exit_file" elapsed_sec)
    started_at=\$(read_exit_field "\$exit_file" started_at)
    finished_at=\$(read_exit_field "\$exit_file" finished_at)
    bundle_name=\$(read_exit_field "\$exit_file" bundle_name)

    if [[ -n "\$exit_code" ]]; then
      if [[ "\$exit_code" == 0 ]]; then
        status=completed
      else
        status=failed
      fi
    fi
  fi

  if [[ -f "\$state_file" && "\$run_id" == "\$state_run_id" && -n "\$state_status" ]]; then
    status=\$state_status
    if [[ -z "\$bundle_name" && -n "\$state_bundle_name" ]]; then
      bundle_name=\$state_bundle_name
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "\$run_id" "\${status:-unknown}" "\${exit_code:-}" "\${wrfout_count:-}" "\${elapsed_sec:-}" "\${started_at:-}" "\${finished_at:-}" "\${bundle_name:-}"
}

if [[ -f "\$state_file" ]]; then
  state_status=\$(read_state_field status)
  state_run_id=\$(read_state_field run_id)
  state_bundle_name=\$(read_state_field bundle_name)
fi

if [[ ! -d "\$runs_dir" ]]; then
  exit 0
fi

if (( \${#requested_run_ids[@]} > 0 )); then
  for run_id in "\${requested_run_ids[@]}"; do
    emit_run "\$run_id"
  done
else
  find "\$runs_dir" -mindepth 1 -maxdepth 1 -type d -printf '%P\t%T@\n' \
    | sort -k2,2nr \
    | head -n "\$last_n" \
    | cut -f1 \
    | while IFS= read -r run_id; do
        [[ -n "\$run_id" ]] || continue
        emit_run "\$run_id"
      done
fi
EOF
}

workers=()
run_ids=()
last_n=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker)
      [[ $# -ge 2 ]] || usage
      workers+=("$2")
      shift 2
      ;;
    --run-id)
      [[ $# -ge 2 ]] || usage
      run_ids+=("$2")
      shift 2
      ;;
    --last)
      [[ $# -ge 2 ]] || usage
      last_n=$2
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
[[ "$last_n" =~ ^[0-9]+$ ]] || die "--last must be an integer"
(( last_n > 0 )) || die "--last must be greater than zero"

require_cmd awk printf sort

printf '%-14s %-28s %-10s %6s %7s %-10s %-20s %-20s %s\n' \
  label run_id status exit wrfout elapsed started finished bundle

for spec in "${workers[@]}"; do
  IFS=, read -r label host port remote_dir user identity_file extra <<< "$spec"
  [[ -n "${label:-}" && -n "${host:-}" && -n "${port:-}" && -n "${remote_dir:-}" ]] || die "bad --worker spec: $spec"
  [[ -z "${extra:-}" ]] || die "too many fields in --worker spec: $spec"

  user=${user:-$remote_default_user}
  identity_file=${identity_file:-$remote_default_identity}
  remote_cmd=$(build_remote_run_query "$remote_dir" "$last_n" "${run_ids[@]}")

  if ! output=$(ssh_run "$host" "$port" "$user" "$identity_file" "$remote_cmd" 2>/dev/null); then
    printf '%-14s %-28s %-10s %6s %7s %-10s %-20s %-20s %s\n' \
      "$label" "-" "unreach" "-" "-" "-" "-" "-" "${host}:${port}"
    continue
  fi

  if [[ -z "$output" ]]; then
    printf '%-14s %-28s %-10s %6s %7s %-10s %-20s %-20s %s\n' \
      "$label" "-" "no-runs" "-" "-" "-" "-" "-" "-"
    continue
  fi

  while IFS=$'\t' read -r run_id status exit_code wrfout_count elapsed_sec started_at finished_at bundle_name; do
    [[ -n "${run_id:-}" ]] || continue

    if [[ "$elapsed_sec" =~ ^[0-9]+$ ]]; then
      elapsed_value=$(printf '%02d:%02d:%02d' "$(( elapsed_sec / 3600 ))" "$(( (elapsed_sec % 3600) / 60 ))" "$(( elapsed_sec % 60 ))")
    else
      elapsed_value=-
    fi

    printf '%-14s %-28s %-10s %6s %7s %-10s %-20s %-20s %s\n' \
      "$label" \
      "$run_id" \
      "${status:-unknown}" \
      "${exit_code:--}" \
      "${wrfout_count:--}" \
      "$elapsed_value" \
      "${started_at:--}" \
      "${finished_at:--}" \
      "${bundle_name:--}"
  done <<< "$output"
done
