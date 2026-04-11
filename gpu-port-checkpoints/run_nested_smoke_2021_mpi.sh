#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  run_nested_smoke_2021_mpi.sh [run|package|check] [case_dir] [source_case_dir] [build_dir]

Modes:
  run      Package, clean stale outputs, run real, run wrf, then validate.
  package  Refresh the packaged run directory only.
  check    Validate an existing packaged/run directory only.

Defaults:
  mode            = run
  case_dir        = gpu-port-checkpoints/nested-smoke-2021-mpi
  source_case_dir = run_gpu_batch59_nvhpc_fullactive_stack
  build_dir       = build-openacc-nvhpc-mpi

Environment:
  WRF_MPI_NP                MPI ranks for wrf launch (default: 2)
  WRF_MPIRUN               mpirun/mpiexec command (default: first on PATH)
  WRF_CUDA_VISIBLE_DEVICES CUDA_VISIBLE_DEVICES for wrf (default: 0)
  OMP_NUM_THREADS          OpenMP thread count for real/wrf (default: 1)
  WRF_WRF_RUN_MINUTES      override wrf runtime minutes for smoke reruns
  WRF_HISTORY_INTERVAL_MINUTES override wrf history interval minutes
EOF
}

fail() {
  printf 'nested smoke mpi: %s\n' "$*" >&2
  exit 1
}

canonicalize_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
}

require_file() {
  local path=$1
  [[ -s "$path" ]] || fail "missing or empty file: $path"
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
package_script="$script_dir/package_nested_smoke_2021.sh"
forcing_check_script="$repo_root/tools/validate_wrf_forcing_horizon.py"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mode=${1:-run}
case "$mode" in
  run|package|check)
    shift || true
    ;;
  *)
    mode=run
    ;;
esac

case_dir=${1:-"$repo_root/gpu-port-checkpoints/nested-smoke-2021-mpi"}
source_case=${2:-"$repo_root/run_gpu_batch59_nvhpc_fullactive_stack"}
build_dir=${3:-"${WRF_BUILD_DIR:-$repo_root/build-openacc-nvhpc-mpi}"}
case_dir=$(canonicalize_path "$case_dir")
source_case=$(canonicalize_path "$source_case")
build_dir=$(canonicalize_path "$build_dir")
mpirun_bin=${WRF_MPIRUN:-$(command -v mpirun || command -v mpiexec || true)}
mpi_np=${WRF_MPI_NP:-2}
omp_threads=${OMP_NUM_THREADS:-1}
cuda_visible_devices=${WRF_CUDA_VISIBLE_DEVICES:-${CUDA_VISIBLE_DEVICES:-0}}
wrf_run_minutes=${WRF_WRF_RUN_MINUTES:-}
history_interval_minutes=${WRF_HISTORY_INTERVAL_MINUTES:-}

real_log="$case_dir/real.log"
wrf_log="$case_dir/wrf.log"
expected_d01="$case_dir/wrfout_d01_2021-12-30_17:00:00"
expected_d02="$case_dir/wrfout_d02_2021-12-30_17:00:00"

package_case() {
  "$package_script" "$case_dir" "$source_case" "$build_dir"
  if [[ -n "$wrf_run_minutes" || -n "$history_interval_minutes" ]]; then
    WRF_WRF_RUN_MINUTES="$wrf_run_minutes" \
    WRF_HISTORY_INTERVAL_MINUTES="$history_interval_minutes" \
    WRF_CASE_DIR="$case_dir" \
    python3 - <<'PY'
from datetime import datetime, timedelta
from pathlib import Path
import os
import re

case = Path(os.environ["WRF_CASE_DIR"])
start = datetime(2021, 12, 30, 17, 0, 0)
run_minutes = os.environ.get("WRF_WRF_RUN_MINUTES", "").strip()
hist_minutes = os.environ.get("WRF_HISTORY_INTERVAL_MINUTES", "").strip()

def rewrite_runtime(txt: str, end: datetime) -> str:
    dt = end - start
    hours = int(dt.total_seconds() // 3600)
    minutes = int((dt.total_seconds() % 3600) // 60)
    txt = re.sub(r" run_hours\s*=\s*\d+,", f" run_hours               = {hours},", txt, count=1)
    txt = re.sub(r" run_minutes\s*=\s*\d+,", f" run_minutes             = {minutes},", txt, count=1)
    txt = re.sub(r" end_year\s*=\s*\d+,\s*\d+,",  f" end_year                = {end.year}, {end.year},", txt, count=1)
    txt = re.sub(r" end_month\s*=\s*\d+,\s*\d+,", f" end_month               = {end.month:02d},   {end.month:02d},", txt, count=1)
    txt = re.sub(r" end_day\s*=\s*\d+,\s*\d+,",   f" end_day                 = {end.day:02d},   {end.day:02d},", txt, count=1)
    txt = re.sub(r" end_hour\s*=\s*\d+,\s*\d+,",  f" end_hour                = {end.hour:02d},   {end.hour:02d},", txt, count=1)
    txt = re.sub(r" end_minute\s*=\s*\d+,\s*\d+,",f" end_minute              = {end.minute:02d},   {end.minute:02d},", txt, count=1)
    txt = re.sub(r" end_second\s*=\s*\d+,\s*\d+,",f" end_second              = {end.second:02d},   {end.second:02d},", txt, count=1)
    return txt

real_path = case / "namelist.real.input"
wrf_path = case / "namelist.wrf.input"

real_txt = real_path.read_text()
wrf_txt = wrf_path.read_text()

if run_minutes:
    requested_end = start + timedelta(minutes=int(run_minutes))
    interval_match = re.search(r" interval_seconds\s*=\s*(\d+),", real_txt)
    interval_seconds = int(interval_match.group(1)) if interval_match else 3600
    real_min_end = start + timedelta(seconds=interval_seconds)
    real_end = max(requested_end, real_min_end)

    real_txt = rewrite_runtime(real_txt, real_end)
    wrf_txt = rewrite_runtime(wrf_txt, requested_end)

if hist_minutes:
    wrf_txt = re.sub(r" history_interval\s*=\s*\d+,\s*\d+,", f" history_interval        = {int(hist_minutes)}, {int(hist_minutes)},", wrf_txt, count=1)

real_path.write_text(real_txt)
wrf_path.write_text(wrf_txt)
PY
  fi

  python3 "$forcing_check_script" --source met_em "$case_dir/namelist.real.input" "$case_dir"
  python3 "$forcing_check_script" --source met_em "$case_dir/namelist.wrf.input" "$case_dir"
}

clean_case() {
  rm -f \
    "$case_dir/namelist.input" \
    "$case_dir/namelist.output" \
    "$real_log" \
    "$wrf_log" \
    "$case_dir"/rsl.out.* \
    "$case_dir"/rsl.error.* \
    "$case_dir"/wrfinput_d0* \
    "$case_dir"/wrfbdy_d0* \
    "$case_dir"/wrfout_d0* \
    "$case_dir"/wrfrst_d0*
}

run_real() {
  cp -f "$case_dir/namelist.real.input" "$case_dir/namelist.input"
  (
    cd "$case_dir"
    ulimit -s unlimited
    env OMP_NUM_THREADS="$omp_threads" ./real >"$real_log" 2>&1
  )
  require_file "$case_dir/wrfinput_d01"
  require_file "$case_dir/wrfbdy_d01"
}

run_wrf() {
  [[ -n "$mpirun_bin" ]] || fail "mpirun/mpiexec not found"
  cp -f "$case_dir/namelist.wrf.input" "$case_dir/namelist.input"
  (
    cd "$case_dir"
    ulimit -s unlimited
    env CUDA_VISIBLE_DEVICES="$cuda_visible_devices" OMP_NUM_THREADS="$omp_threads" \
      "$mpirun_bin" -np "$mpi_np" ./wrf >"$wrf_log" 2>&1
  )
}

check_logs_for_fatal() {
  if rg -n -i 'fatal|segmentation|sig[a-z]*|forrtl|backtrace|cuda error|mpirun detected|aborting' \
      "$case_dir"/rsl.out.* "$case_dir"/rsl.error.* "$real_log" "$wrf_log" >/dev/null 2>&1; then
    fail "fatal pattern found in logs under $case_dir"
  fi
}

check_case() {
  local header_d01 header_d02

  require_file "$case_dir/real"
  require_file "$case_dir/wrf"
  require_file "$case_dir/namelist.real.input"
  require_file "$case_dir/namelist.wrf.input"
  require_file "$case_dir/wrfinput_d01"
  require_file "$case_dir/wrfbdy_d01"
  require_file "$expected_d01"
  require_file "$expected_d02"
  require_file "$case_dir/rsl.out.0000"
  require_file "$case_dir/rsl.out.0001"

  check_logs_for_fatal

  rg -q 'Timing for main: .* domain +1' "$case_dir"/rsl.out.* || \
    fail "missing domain 1 timing in rsl.out.*"
  rg -q 'Timing for main: .* domain +2' "$case_dir"/rsl.out.* || \
    fail "missing domain 2 timing in rsl.out.*"
  rg -q 'Timing for Writing wrfout_d02_2021-12-30_17:00:00 for domain +2' "$case_dir"/rsl.out.* || \
    fail "missing d02 wrfout write in rsl.out.*"

  header_d01=$(ncdump -h "$expected_d01")
  header_d02=$(ncdump -h "$expected_d02")
  rg -q 'Time = UNLIMITED' <<<"$header_d01" || fail "wrfout_d01 missing Time dimension"
  rg -q 'west_east = 199' <<<"$header_d01" || fail "wrfout_d01 west_east mismatch"
  rg -q 'south_north = 199' <<<"$header_d01" || fail "wrfout_d01 south_north mismatch"
  rg -q 'Time = UNLIMITED' <<<"$header_d02" || fail "wrfout_d02 missing Time dimension"
  rg -q 'west_east = 60' <<<"$header_d02" || fail "wrfout_d02 west_east mismatch"
  rg -q 'south_north = 60' <<<"$header_d02" || fail "wrfout_d02 south_north mismatch"

  printf 'nested smoke mpi OK\n'
  printf '  case_dir: %s\n' "$case_dir"
  printf '  real_log: %s\n' "$real_log"
  printf '  wrf_log:  %s\n' "$wrf_log"
  printf '  d01:      %s bytes\n' "$(stat -c '%s' "$expected_d01")"
  printf '  d02:      %s bytes\n' "$(stat -c '%s' "$expected_d02")"
}

case "$mode" in
  package)
    package_case
    ;;
  check)
    check_case
    ;;
  run)
    package_case
    clean_case
    run_real
    run_wrf
    check_case
    ;;
esac
