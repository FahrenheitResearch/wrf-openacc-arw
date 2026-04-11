#!/usr/bin/env bash

set -euo pipefail

remote_default_user=root
remote_default_identity=${HOME}/.ssh/id_ed25519

die() {
  echo "$*" >&2
  exit 1
}

log() {
  printf '[remote] %s\n' "$*" >&2
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
  done
}

calc_sha256() {
  sha256sum "$1" | awk '{print $1}'
}

bundle_name_from_source() {
  local source_path=$1
  local base_name

  base_name=$(basename "$source_path")
  case "$base_name" in
    *.tar.gz)
      printf '%s\n' "${base_name%.tar.gz}"
      ;;
    *)
      printf '%s\n' "$base_name"
      ;;
  esac
}

build_ssh_opts() {
  local port=$1
  local identity_file=$2

  printf '%s\0' -i "$identity_file" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$port"
}

build_scp_opts() {
  local port=$1
  local identity_file=$2

  printf '%s\0' -i "$identity_file" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -P "$port"
}

ssh_run() {
  local host=$1
  local port=$2
  local user=$3
  local identity_file=$4
  local remote_cmd=$5
  local -a ssh_opts=()

  while IFS= read -r -d '' token; do
    ssh_opts+=("$token")
  done < <(build_ssh_opts "$port" "$identity_file")

  ssh "${ssh_opts[@]}" "${user}@${host}" "$remote_cmd"
}

scp_copy() {
  local source_path=$1
  local host=$2
  local port=$3
  local user=$4
  local identity_file=$5
  local dest_path=$6
  local -a ssh_opts=()

  while IFS= read -r -d '' token; do
    ssh_opts+=("$token")
  done < <(build_scp_opts "$port" "$identity_file")

  scp "${ssh_opts[@]}" "$source_path" "${user}@${host}:$dest_path"
}

rsync_copy() {
  local source_path=$1
  local host=$2
  local port=$3
  local user=$4
  local identity_file=$5
  local dest_path=$6
  local shell_cmd
  shift 6

  shell_cmd=$(printf 'ssh -i %q -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p %q' "$identity_file" "$port")
  rsync -az --delete --info=stats1 --rsh "$shell_cmd" "$@" "$source_path" "${user}@${host}:$dest_path" 1>&2
}

remote_has_cmd() {
  local host=$1
  local port=$2
  local user=$3
  local identity_file=$4
  local remote_cmd_name=$5

  ssh_run "$host" "$port" "$user" "$identity_file" "command -v '$remote_cmd_name' >/dev/null 2>&1"
}
