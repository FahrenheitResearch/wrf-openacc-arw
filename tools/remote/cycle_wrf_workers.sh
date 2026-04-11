#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/remote/common.sh
source "$script_dir/common.sh"

usage() {
  cat >&2 <<'EOF'
usage: cycle_wrf_workers.sh [--run-tag TAG] [--no-harvest] [--wait] [--poll-seconds N] --job label,bundle,wrf-bin,case-dir,local-bundle-dir,host,port,remote-dir[,user[,identity-file]] [--job ...]

Runs multiple refresh_wrf_worker jobs in parallel, then prints a consolidated status table
and, by default, harvests the exact run ids launched in this cycle.
Use --wait to keep polling those run ids until they complete, then emit the final harvest.
Use a distinct local bundle dir for each job.
EOF
  exit 2
}

jobs=()
run_tag=
harvest_after_cycle=1
wait_for_completion=0
poll_seconds=15

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job)
      [[ $# -ge 2 ]] || usage
      jobs+=("$2")
      shift 2
      ;;
    --run-tag)
      [[ $# -ge 2 ]] || usage
      run_tag=$2
      shift 2
      ;;
    --no-harvest)
      harvest_after_cycle=0
      shift
      ;;
    --wait)
      wait_for_completion=1
      shift
      ;;
    --poll-seconds)
      [[ $# -ge 2 ]] || usage
      poll_seconds=$2
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

(( ${#jobs[@]} > 0 )) || usage
[[ "$poll_seconds" =~ ^[0-9]+$ ]] || die "--poll-seconds must be an integer"
(( poll_seconds > 0 )) || die "--poll-seconds must be greater than zero"

require_cmd date mktemp

if [[ -z "$run_tag" ]]; then
  run_tag=$(date -u +%Y%m%dT%H%M%SZ)
fi

tmp_dir=$(mktemp -d)
keep_logs=0

cleanup() {
  if [[ $keep_logs -eq 0 ]]; then
    rm -rf "$tmp_dir"
  else
    log "kept cycle logs in $tmp_dir"
  fi
}

trap cleanup EXIT

labels=()
worker_specs=()
log_files=()
pids=()
results=()
run_ids=()

for job in "${jobs[@]}"; do
  IFS=, read -r label bundle_name wrf_bin case_dir local_bundle_dir host port remote_dir user identity_file extra <<< "$job"
  [[ -n "${label:-}" && -n "${bundle_name:-}" && -n "${wrf_bin:-}" && -n "${case_dir:-}" && -n "${local_bundle_dir:-}" && -n "${host:-}" && -n "${port:-}" && -n "${remote_dir:-}" ]] || die "bad --job spec: $job"
  [[ -z "${extra:-}" ]] || die "too many fields in --job spec: $job"

  user=${user:-$remote_default_user}
  identity_file=${identity_file:-$remote_default_identity}

  labels+=("$label")
  worker_specs+=("${label},${host},${port},${remote_dir},${user},${identity_file}")
  log_files+=("$tmp_dir/${label}.log")
  results+=("pending")
  run_ids+=("${run_tag}-${label}")

  (
    "$script_dir/refresh_wrf_worker.sh" \
      --run-id "${run_tag}-${label}" \
      "$bundle_name" \
      "$wrf_bin" \
      "$case_dir" \
      "$local_bundle_dir" \
      "$host" \
      "$port" \
      "$remote_dir" \
      "$user" \
      "$identity_file"
  ) > "${tmp_dir}/${label}.log" 2>&1 &
  pids+=("$!")
done

printf '%-14s %-8s %s\n' label result log
printf 'run_tag=%s\n' "$run_tag"

overall_status=0

for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then
    results[$i]=ok
  else
    results[$i]=fail
    overall_status=1
    keep_logs=1
  fi

  printf '%-14s %-8s %s\n' "${labels[$i]}" "${results[$i]}" "${log_files[$i]}"
done

echo
status_args=()
for spec in "${worker_specs[@]}"; do
  status_args+=(--worker "$spec")
done
"$script_dir/status_wrf_workers.sh" "${status_args[@]}"

if [[ $wait_for_completion -eq 1 ]]; then
  echo
  printf 'waiting_for_completion poll_seconds=%s\n' "$poll_seconds"
  while true; do
    sleep "$poll_seconds"

    if ! poll_output=$("$script_dir/status_wrf_workers.sh" "${status_args[@]}"); then
      printf 'poll %s status=unreach\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      continue
    fi

    completed_count=$(awk 'NR > 1 && ($2 == "completed" || $2 == "failed") {count++} END {print count+0}' <<< "$poll_output")
    running_count=$(awk 'NR > 1 && $2 == "running" {count++} END {print count+0}' <<< "$poll_output")
    failed_count=$(awk 'NR > 1 && $2 == "failed" {count++} END {print count+0}' <<< "$poll_output")

    printf 'poll %s completed=%s/%s running=%s failed=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$completed_count" \
      "${#worker_specs[@]}" \
      "$running_count" \
      "$failed_count"

    if (( completed_count == ${#worker_specs[@]} )); then
      break
    fi
  done
  echo
  "$script_dir/status_wrf_workers.sh" "${status_args[@]}"
fi

if [[ $harvest_after_cycle -eq 1 ]]; then
  echo
  harvest_output=$(printf '%-14s %-28s %-10s %6s %7s %-10s %-20s %-20s %s\n' \
    label run_id status exit wrfout elapsed started finished bundle)

  for i in "${!worker_specs[@]}"; do
    if worker_harvest=$("$script_dir/harvest_wrf_runs.sh" --worker "${worker_specs[$i]}" --run-id "${run_ids[$i]}"); then
      worker_body=$(sed '1d' <<< "$worker_harvest")
      if [[ -n "$worker_body" ]]; then
        harvest_output+=$'\n'"$worker_body"
      else
        harvest_output+=$'\n'"$(printf '%-14s %-28s %-10s %6s %7s %-10s %-20s %-20s %s' \
          "${labels[$i]}" "${run_ids[$i]}" "missing" "-" "-" "-" "-" "-" "-")"
      fi
    else
      harvest_output+=$'\n'"$(printf '%-14s %-28s %-10s %6s %7s %-10s %-20s %-20s %s' \
        "${labels[$i]}" "${run_ids[$i]}" "harvest-fail" "-" "-" "-" "-" "-" "-")"
      overall_status=1
      keep_logs=1
    fi
  done

  printf '%s\n' "$harvest_output"

  if [[ $wait_for_completion -eq 1 ]]; then
    if awk 'NR > 1 && $3 != "completed" { bad=1 } END { exit bad+0 }' <<< "$harvest_output"; then
      :
    else
      overall_status=1
    fi
  fi
fi

if [[ $overall_status -ne 0 ]]; then
  echo
  echo "failed job tails:"
  for i in "${!results[@]}"; do
    [[ "${results[$i]}" == "fail" ]] || continue
    echo "--- ${labels[$i]} ---"
    tail -n 20 "${log_files[$i]}" || true
  done
fi

exit "$overall_status"
