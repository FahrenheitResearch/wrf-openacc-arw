#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/remote/common.sh
source "$script_dir/common.sh"

usage() {
  echo "usage: $0 [--restart] [--run-id RUN_ID] <host> <port> <remote-bundle-dir> [user] [identity-file]" >&2
  exit 2
}

restart_mode=0
run_id=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --restart)
      restart_mode=1
      shift
      ;;
    --run-id)
      [[ $# -ge 2 ]] || usage
      run_id=$2
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 3 || $# -gt 5 ]]; then
  usage
fi

require_cmd ssh

host=$1
port=$2
remote_bundle_dir=$3
user=${4:-$remote_default_user}
identity_file=${5:-$remote_default_identity}

remote_export_cmd=
if [[ -n "$run_id" ]]; then
  remote_export_cmd=$(printf 'export WRF_REMOTE_RUN_ID=%q; ' "$run_id")
fi
remote_launch_cmd=$(printf '%q' "${remote_export_cmd}exec ./run.sh >> .worker/launcher.log 2>&1")

remote_cmd=$(cat <<EOF
set -euo pipefail
worker_dir='$remote_bundle_dir/.worker'
mkdir -p "\$worker_dir"

if [[ -f "\$worker_dir/active.pid" ]]; then
  active_pid=\$(cat "\$worker_dir/active.pid" 2>/dev/null || true)
  if [[ -n "\${active_pid:-}" ]] && kill -0 "\$active_pid" 2>/dev/null; then
    if [[ "$restart_mode" -eq 1 ]]; then
      kill "\$active_pid"
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 "\$active_pid" 2>/dev/null; then
          break
        fi
        sleep 1
      done
      if kill -0 "\$active_pid" 2>/dev/null; then
        kill -9 "\$active_pid"
      fi
      rm -f "\$worker_dir/active.pid"
    else
      echo "worker already running pid=\$active_pid"
      exit 3
    fi
  else
    rm -f "\$worker_dir/active.pid"
  fi
fi

launcher_log="\$worker_dir/launcher.log"

cd '$remote_bundle_dir'
nohup bash -lc $remote_launch_cmd >/dev/null 2>&1 < /dev/null &
launcher_pid=\$!
sleep 1

if kill -0 "\$launcher_pid" 2>/dev/null; then
  echo "started launcher_pid=\$launcher_pid log=\$launcher_log"
else
  echo "launcher exited early, inspect \$launcher_log" >&2
  exit 4
fi
EOF
)

ssh_run "$host" "$port" "$user" "$identity_file" "$remote_cmd"
