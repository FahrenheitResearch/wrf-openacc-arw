#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/remote/common.sh
source "$script_dir/common.sh"

usage() {
  echo "usage: $0 [--tail N] <host> <port> <remote-bundle-dir> [user] [identity-file]" >&2
  exit 2
}

tail_lines=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tail)
      [[ $# -ge 2 ]] || usage
      tail_lines=$2
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

remote_cmd=$(cat <<EOF
set -euo pipefail
worker_dir='$remote_bundle_dir/.worker'
case_dir='$remote_bundle_dir/case'
state_file="\$worker_dir/state.env"
last_run_link="\$worker_dir/last_run"
active_pid=
pid_status=stopped
now_epoch=\$(date -u +%s)

format_duration() {
  local total=\${1:-}
  local days hours minutes seconds

  if [[ ! "\$total" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  days=\$(( total / 86400 ))
  hours=\$(( (total % 86400) / 3600 ))
  minutes=\$(( (total % 3600) / 60 ))
  seconds=\$(( total % 60 ))

  if (( days > 0 )); then
    printf '%dd %02d:%02d:%02d\n' "\$days" "\$hours" "\$minutes" "\$seconds"
  else
    printf '%02d:%02d:%02d\n' "\$hours" "\$minutes" "\$seconds"
  fi
}

iso_to_epoch() {
  local iso=\${1:-}

  [[ -n "\$iso" ]] || return 1
  date -u -d "\$iso" +%s 2>/dev/null
}

if [[ -f "\$worker_dir/active.pid" ]]; then
  active_pid=\$(cat "\$worker_dir/active.pid" 2>/dev/null || true)
  if [[ -n "\${active_pid:-}" ]] && kill -0 "\$active_pid" 2>/dev/null; then
    pid_status=running
  else
    pid_status=stale_pid
  fi
fi

if [[ -f "\$state_file" ]]; then
  # shellcheck disable=SC1090
  source "\$state_file"
fi

wrfout_count=\$(find "\$case_dir" -maxdepth 1 -type f -name 'wrfout_d0*' | wc -l | tr -d ' ')
latest_wrfout=\$(find "\$case_dir" -maxdepth 1 -type f -name 'wrfout_d0*' | sort | tail -n 1)
elapsed_live=
elapsed_hms=
latest_wrfout_age_sec=
latest_wrfout_age_hms=
latest_wrfout_mtime=

if [[ -n "\${started_at:-}" ]]; then
  started_epoch=\$(iso_to_epoch "\$started_at" || true)
  if [[ "\${started_epoch:-}" =~ ^[0-9]+$ ]]; then
    if [[ "\${status:-}" == "running" ]]; then
      elapsed_live=\$(( now_epoch - started_epoch ))
    elif [[ "\${elapsed_sec:-}" =~ ^[0-9]+$ ]]; then
      elapsed_live=\$elapsed_sec
    elif [[ -n "\${finished_at:-}" ]]; then
      finished_epoch=\$(iso_to_epoch "\$finished_at" || true)
      if [[ "\${finished_epoch:-}" =~ ^[0-9]+$ ]]; then
        elapsed_live=\$(( finished_epoch - started_epoch ))
      fi
    fi
  fi
fi

if [[ "\${elapsed_live:-}" =~ ^[0-9]+$ ]]; then
  elapsed_hms=\$(format_duration "\$elapsed_live" || true)
fi

if [[ -n "\$latest_wrfout" && -f "\$latest_wrfout" ]]; then
  latest_wrfout_epoch=\$(stat -c %Y "\$latest_wrfout" 2>/dev/null || true)
  if [[ "\${latest_wrfout_epoch:-}" =~ ^[0-9]+$ ]]; then
    latest_wrfout_age_sec=\$(( now_epoch - latest_wrfout_epoch ))
    latest_wrfout_mtime=\$(date -u -d "@\$latest_wrfout_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    latest_wrfout_age_hms=\$(format_duration "\$latest_wrfout_age_sec" || true)
  fi
fi

echo "status=\${status:-unknown}"
echo "pid_status=\$pid_status"
echo "pid=\${pid:-\${active_pid:-}}"
echo "bundle_name=\${bundle_name:-unknown}"
echo "bundle_id=\${bundle_id:-unknown}"
echo "run_id=\${run_id:-unknown}"
echo "started_at=\${started_at:-}"
echo "finished_at=\${finished_at:-}"
echo "elapsed_sec=\${elapsed_sec:-}"
echo "elapsed_sec_live=\${elapsed_live:-}"
echo "elapsed_hms=\${elapsed_hms:-}"
echo "exit_code=\${exit_code:-}"
echo "wrfout_count=\$wrfout_count"
echo "latest_wrfout=\${latest_wrfout:-}"
echo "latest_wrfout_mtime=\${latest_wrfout_mtime:-}"
echo "latest_wrfout_age_sec=\${latest_wrfout_age_sec:-}"
echo "latest_wrfout_age_hms=\${latest_wrfout_age_hms:-}"
echo "remote_dir=$remote_bundle_dir"

if [[ -L "\$last_run_link" || -d "\$last_run_link" ]]; then
  last_run_dir=\$(readlink -f "\$last_run_link")
  echo "--- last_run.exit_code.txt ---"
  sed -n '1,40p' "\$last_run_dir/exit_code.txt" 2>/dev/null || true
  echo "--- last_run.wrf_stderr.log tail($tail_lines) ---"
  tail -n $tail_lines "\$last_run_dir/wrf_stderr.log" 2>/dev/null || true
fi

echo "--- launcher.log tail($tail_lines) ---"
tail -n $tail_lines "\$worker_dir/launcher.log" 2>/dev/null || true
EOF
)

ssh_run "$host" "$port" "$user" "$identity_file" "$remote_cmd"
