#!/usr/bin/env bash
set -uo pipefail

run_dir=${1:?run directory required}
exe=${2:?wrf executable required}

cd "$run_dir"

if [[ -f runner.pid ]]; then
  old_pid=$(<runner.pid)
  if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
    printf 'runner already active: %s\n' "${old_pid}" > launcher.log
    exit 1
  fi
fi

rm -f exit_code.txt
printf '%s\n' "$$" > runner.pid
printf 'start %s\n' "$(date '+%F %T %Z')" > launcher.log

ulimit -s unlimited
"$exe" > wrf_stdout.log 2>&1
rc=$?

printf '%s\n' "$rc" > exit_code.txt
printf 'exit %s %s\n' "$rc" "$(date '+%F %T %Z')" >> launcher.log
exit "$rc"
