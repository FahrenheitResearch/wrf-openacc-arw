#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
forcing_check_script="$repo_root/tools/validate_wrf_forcing_horizon.py"
# shellcheck source=tools/remote/common.sh
source "$script_dir/common.sh"

copy_file_follow_preserve() {
  local src_path=$1
  local dest_path=$2
  cp -L --preserve=mode,timestamps "$src_path" "$dest_path"
}

write_run_script() {
  local run_script=$1

  cat > "$run_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")" && pwd)
bundle_meta_dir="$root_dir/.bundle"
worker_dir="$root_dir/.worker"
case_dir="$root_dir/case"
bundle_id=$(cat "$bundle_meta_dir/bundle_id" 2>/dev/null || echo unknown)
bundle_name=$(cat "$bundle_meta_dir/bundle_name" 2>/dev/null || echo unknown)
mkdir -p "$worker_dir/runs"

run_id=${WRF_REMOTE_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
run_dir="$worker_dir/runs/$run_id"
lock_dir="$worker_dir/lock"
wrf_child_pid=
mkdir -p "$run_dir"

write_state() {
  local status_value=$1
  local pid_value=$2
  local started_at_value=$3
  local finished_at_value=$4
  local elapsed_value=$5
  local exit_value=$6

  cat > "$worker_dir/state.env" <<STATE
status=$status_value
bundle_id=$bundle_id
bundle_name=$bundle_name
run_id=$run_id
pid=$pid_value
started_at=$started_at_value
finished_at=$finished_at_value
elapsed_sec=$elapsed_value
exit_code=$exit_value
run_dir=$run_dir
STATE
}

acquire_lock() {
  if mkdir "$lock_dir" 2>/dev/null; then
    return 0
  fi

  if [[ -f "$worker_dir/active.pid" ]]; then
    old_pid=$(cat "$worker_dir/active.pid" 2>/dev/null || true)
    if [[ -n "${old_pid:-}" ]] && kill -0 "$old_pid" 2>/dev/null; then
      echo "worker already running with pid $old_pid" >&2
      exit 90
    fi
  fi

  rm -rf "$lock_dir"
  mkdir "$lock_dir"
}

finish_run() {
  local exit_value=$1
  local end_epoch end_iso elapsed_value wrfout_count

  end_epoch=$(date -u +%s)
  end_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  elapsed_value=$(( end_epoch - start_epoch ))
  wrfout_count=$(find "$case_dir" -maxdepth 1 -type f -name 'wrfout_d0*' | wc -l | tr -d ' ')

  cat > "$run_dir/exit_code.txt" <<EXITINFO
exit:$exit_value
wrfout_count:$wrfout_count
elapsed_sec:$elapsed_value
started_at:$start_iso
finished_at:$end_iso
bundle_id:$bundle_id
bundle_name:$bundle_name
run_id:$run_id
EXITINFO

  printf 'elapsed_sec=%s\n' "$elapsed_value" > "$run_dir/time.log"

  ln -sfn "../runs/$run_id/wrf_stdout.log" "$case_dir/wrf_stdout.log"
  ln -sfn "../runs/$run_id/wrf_stderr.log" "$case_dir/wrf_stderr.log"
  cp -f "$run_dir/time.log" "$case_dir/time.log"
  cp -f "$run_dir/exit_code.txt" "$case_dir/exit_code.txt"

  if [[ $exit_value -eq 0 ]]; then
    write_state completed "" "$start_iso" "$end_iso" "$elapsed_value" "$exit_value"
  else
    write_state failed "" "$start_iso" "$end_iso" "$elapsed_value" "$exit_value"
  fi

  rm -f "$worker_dir/active.pid"
  rmdir "$lock_dir" 2>/dev/null || true
  ln -sfn "runs/$run_id" "$worker_dir/last_run"
  exit "$exit_value"
}

handle_signal() {
  local signal_name=$1
  if [[ -n "${wrf_child_pid:-}" ]] && kill -0 "$wrf_child_pid" 2>/dev/null; then
    kill "$wrf_child_pid" 2>/dev/null || true
  fi
  echo "received signal: $signal_name" >> "$worker_dir/launcher.log"
  finish_run 128
}

trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

acquire_lock

export LD_LIBRARY_PATH="$root_dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

printf '%s\n' "$$" > "$worker_dir/active.pid"
start_epoch=$(date -u +%s)
start_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
write_state running "$$" "$start_iso" "" "" ""

ln -sfn "runs/$run_id" "$worker_dir/last_run"

find "$case_dir" -maxdepth 1 -type f \
  \( -name 'wrfout_d0*' -o -name 'wrfrst_d0*' -o -name 'wrfdiag_d0*' -o -name 'rsl.out.*' -o -name 'rsl.error.*' \) \
  -delete
rm -f "$case_dir/wrf_stdout.log" "$case_dir/wrf_stderr.log" "$case_dir/time.log" "$case_dir/exit_code.txt" "$run_dir/wrf_stdout.log" "$run_dir/wrf_stderr.log"

ulimit -s unlimited

set +e
(
  cd "$case_dir"
  "$root_dir/bin/wrf" > "$run_dir/wrf_stdout.log" 2> "$run_dir/wrf_stderr.log"
) &
wrf_child_pid=$!
wait "$wrf_child_pid"
status=$?
wrf_child_pid=
set -e

finish_run "$status"
EOF

  chmod +x "$run_script"
}

write_manifest() {
  local bundle_dir=$1
  local manifest_path=$2

  (
    cd "$bundle_dir"
    find . -type f \
      ! -path './.bundle/manifest.sha256' \
      ! -path './.bundle/bundle_id' \
      ! -path './.bundle/tar_sha256' \
      | LC_ALL=C sort | while IFS= read -r rel_path; do
      sha256sum "$rel_path"
    done
  ) > "$manifest_path"
}

compute_bundle_id() {
  local manifest_path=$1
  sha256sum "$manifest_path" | awk '{print $1}'
}

finalize_directory_output() {
  local src_dir=$1
  local out_dir=$2
  local parent_dir temp_dir

  parent_dir=$(dirname "$out_dir")
  mkdir -p "$parent_dir"
  temp_dir=$(mktemp -d "$parent_dir/.bundle-tmp.XXXXXX")
  rm -rf "$temp_dir"
  cp -a "$src_dir" "$temp_dir"
  rm -rf "$out_dir"
  mv "$temp_dir" "$out_dir"
}

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <bundle-name> <wrf-binary> <case-dir> <output-path(.tar.gz|dir)>" >&2
  exit 2
fi

require_cmd awk cp find mktemp python3 sha256sum sort tar

bundle_name=$1
wrf_bin=$2
case_dir=$3
out_path=$4

if [[ ! -x "$wrf_bin" ]]; then
  die "wrf binary not executable: $wrf_bin"
fi

if [[ ! -d "$case_dir" ]]; then
  die "case directory not found: $case_dir"
fi

stage_dir=$(mktemp -d)
trap 'rm -rf "$stage_dir"' EXIT

bundle_dir="$stage_dir/$bundle_name"
mkdir -p "$bundle_dir/bin" "$bundle_dir/lib" "$bundle_dir/case" "$bundle_dir/.bundle"

copy_file_follow_preserve "$wrf_bin" "$bundle_dir/bin/wrf"

while IFS= read -r lib_path; do
  [[ -n "$lib_path" ]] || continue
  copy_file_follow_preserve "$lib_path" "$bundle_dir/lib/$(basename "$lib_path")"
done < <(ldd "$wrf_bin" | awk '/=> \/(home|opt)\// {print $3}' | sort -u)

while IFS= read -r src_path; do
  base_name=$(basename "$src_path")
  case "$base_name" in
    wrfout_*|wrfrst_*|wrfdiag_*|wrf_stdout.log|wrf_stderr.log|time.log|namelist.output|rsl.*|core*|exit_code.txt|launcher.log|runner.pid)
      continue
      ;;
  esac

  if [[ -d "$src_path" && ! -L "$src_path" ]]; then
    cp -aL "$src_path" "$bundle_dir/case/$base_name"
  else
    copy_file_follow_preserve "$src_path" "$bundle_dir/case/$base_name"
  fi
done < <(find "$case_dir" -mindepth 1 -maxdepth 1 | sort)

if [[ -f "$bundle_dir/case/namelist.input" ]]; then
  python3 "$forcing_check_script" --source wrfbdy "$bundle_dir/case/namelist.input" "$bundle_dir/case"
fi

printf '%s\n' "$bundle_name" > "$bundle_dir/.bundle/bundle_name"
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$bundle_dir/.bundle/created_at_utc"
write_run_script "$bundle_dir/run.sh"
manifest_tmp="$stage_dir/manifest.sha256"
write_manifest "$bundle_dir" "$manifest_tmp"
bundle_id=$(compute_bundle_id "$manifest_tmp")
mv "$manifest_tmp" "$bundle_dir/.bundle/manifest.sha256"
printf '%s\n' "$bundle_id" > "$bundle_dir/.bundle/bundle_id"

case "$out_path" in
  *.tar.gz)
    mkdir -p "$(dirname "$out_path")"
    tar -C "$stage_dir" -czf "$out_path" "$bundle_name"
    ;;
  *)
    finalize_directory_output "$bundle_dir" "$out_path"
    ;;
esac

echo "$out_path"
