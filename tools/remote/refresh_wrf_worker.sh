#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  echo "usage: $0 [--run-id RUN_ID] <bundle-name> <wrf-binary> <case-dir> <local-bundle-dir> <host> <port> <remote-bundle-dir> [user] [identity-file]" >&2
  exit 2
}

run_id=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)
      [[ $# -ge 2 ]] || usage
      run_id=$2
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    --*)
      echo "unknown option: $1" >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 7 || $# -gt 9 ]]; then
  usage
fi

bundle_name=$1
wrf_bin=$2
case_dir=$3
local_bundle_dir=$4
host=$5
port=$6
remote_bundle_dir=$7
user=${8:-root}
identity_file=${9:-$HOME/.ssh/id_ed25519}

"$script_dir/package_wrf_runtime_bundle.sh" "$bundle_name" "$wrf_bin" "$case_dir" "$local_bundle_dir"
"$script_dir/stop_wrf_worker.sh" "$host" "$port" "$remote_bundle_dir" "$user" "$identity_file"
"$script_dir/deploy_wrf_runtime_bundle.sh" "$local_bundle_dir" "$host" "$port" "$remote_bundle_dir" "$user" "$identity_file"

if [[ -n "$run_id" ]]; then
  "$script_dir/start_wrf_worker.sh" --restart --run-id "$run_id" "$host" "$port" "$remote_bundle_dir" "$user" "$identity_file"
else
  "$script_dir/start_wrf_worker.sh" --restart "$host" "$port" "$remote_bundle_dir" "$user" "$identity_file"
fi

"$script_dir/check_wrf_worker.sh" "$host" "$port" "$remote_bundle_dir" "$user" "$identity_file"
