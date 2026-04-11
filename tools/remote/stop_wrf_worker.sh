#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/remote/common.sh
source "$script_dir/common.sh"

usage() {
  echo "usage: $0 <host> <port> <remote-bundle-dir> [user] [identity-file]" >&2
  exit 2
}

if [[ $# -lt 3 || $# -gt 5 ]]; then
  usage
fi

require_cmd ssh

host=$1
port=$2
remote_bundle_dir=$3
user=${4:-$remote_default_user}
identity_file=${5:-$remote_default_identity}

remote_cmd=$(cat <<EOF
set -euo pipefail
worker_dir='$remote_bundle_dir/.worker'

if [[ ! -f "\$worker_dir/active.pid" ]]; then
  echo "worker not running"
  exit 0
fi

active_pid=\$(cat "\$worker_dir/active.pid" 2>/dev/null || true)
if [[ -z "\${active_pid:-}" ]]; then
  rm -f "\$worker_dir/active.pid"
  echo "worker pid file cleared"
  exit 0
fi

if kill -0 "\$active_pid" 2>/dev/null; then
  kill "\$active_pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "\$active_pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  if kill -0 "\$active_pid" 2>/dev/null; then
    kill -9 "\$active_pid" 2>/dev/null || true
  fi
fi

rm -f "\$worker_dir/active.pid"
echo "stopped pid=\$active_pid"
EOF
)

ssh_run "$host" "$port" "$user" "$identity_file" "$remote_cmd"
