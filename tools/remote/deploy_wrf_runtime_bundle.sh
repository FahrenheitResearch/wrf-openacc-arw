#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/remote/common.sh
source "$script_dir/common.sh"

usage() {
  echo "usage: $0 [--allow-running] [--force] <bundle-path(.tar.gz|dir)> <host> <port> <remote-dir> [user] [identity-file]" >&2
  echo "optional env: WRF_REMOTE_R2_BUCKET WRF_REMOTE_R2_PREFIX WRF_REMOTE_R2_PROFILE WRF_REMOTE_R2_ENDPOINT" >&2
  exit 2
}

ensure_remote_idle() {
  local host=$1
  local port=$2
  local user=$3
  local identity_file=$4
  local remote_dir=$5

  ssh_run "$host" "$port" "$user" "$identity_file" "
    if [[ -f '$remote_dir/.worker/active.pid' ]]; then
      active_pid=\$(cat '$remote_dir/.worker/active.pid' 2>/dev/null || true)
      if [[ -n \"\${active_pid:-}\" ]] && kill -0 \"\$active_pid\" 2>/dev/null; then
        echo \"worker active pid=\$active_pid\" >&2
        exit 12
      fi
    fi
  "
}

deploy_dir_bundle() {
  local bundle_dir=$1
  local host=$2
  local port=$3
  local user=$4
  local identity_file=$5
  local remote_dir=$6

  ssh_run "$host" "$port" "$user" "$identity_file" "mkdir -p '$remote_dir'"
  # Preserve remote worker state and run history when refreshing a live bundle.
  rsync_copy "$bundle_dir/" "$host" "$port" "$user" "$identity_file" "$remote_dir/" \
    --exclude=.worker/ --exclude=.worker
  ssh_run "$host" "$port" "$user" "$identity_file" "test -f '$remote_dir/.bundle/bundle_id' && cat '$remote_dir/.bundle/bundle_id'" | tail -n 1
}

deploy_tar_bundle() {
  local bundle_tar=$1
  local host=$2
  local port=$3
  local user=$4
  local identity_file=$5
  local remote_dir=$6
  local force_mode=$7
  local bundle_name local_tar_sha remote_tar_sha remote_parent remote_tmp remote_tar

  bundle_name=$(bundle_name_from_source "$bundle_tar")
  local_tar_sha=$(calc_sha256 "$bundle_tar")
  remote_parent=$(dirname "$remote_dir")
  remote_tar="$remote_parent/.${bundle_name}.tar.gz"
  remote_tmp="$remote_parent/.${bundle_name}.incoming.$$"

  if [[ "$force_mode" != 1 ]]; then
    remote_tar_sha=$(ssh_run "$host" "$port" "$user" "$identity_file" "cat '$remote_dir/.bundle/tar_sha256' 2>/dev/null || true" | tail -n 1)
    if [[ "$remote_tar_sha" == "$local_tar_sha" ]]; then
      log "remote bundle already matches $bundle_name on $host:$remote_dir"
      ssh_run "$host" "$port" "$user" "$identity_file" "cat '$remote_dir/.bundle/bundle_id' 2>/dev/null || true" | tail -n 1
      return 0
    fi
  fi

  ssh_run "$host" "$port" "$user" "$identity_file" "mkdir -p '$remote_parent' && rm -rf '$remote_tmp'"
  scp_copy "$bundle_tar" "$host" "$port" "$user" "$identity_file" "$remote_tar"
  ssh_run "$host" "$port" "$user" "$identity_file" "
    rm -rf '$remote_tmp'
    mkdir -p '$remote_tmp'
    tar -C '$remote_tmp' -xzf '$remote_tar'
    rm -rf '$remote_dir'
    mv '$remote_tmp/$bundle_name' '$remote_dir'
    rmdir '$remote_tmp'
    printf '%s\n' '$local_tar_sha' > '$remote_dir/.bundle/tar_sha256'
    rm -f '$remote_tar'
    cat '$remote_dir/.bundle/bundle_id'
  " | tail -n 1
}

bundle_tar_from_path() {
  local bundle_path=$1
  local bundle_name=$2
  local out_tar=$3

  if [[ -d "$bundle_path" ]]; then
    tar -C "$(dirname "$bundle_path")" -czf "$out_tar" "$bundle_name"
  else
    cp -f "$bundle_path" "$out_tar"
  fi
}

deploy_r2_bundle() {
  local bundle_path=$1
  local host=$2
  local port=$3
  local user=$4
  local identity_file=$5
  local remote_dir=$6
  local force_mode=$7
  local r2_bucket=$8
  local r2_prefix=$9
  local r2_profile=${10}
  local r2_endpoint=${11}
  local bundle_name tmp_tar local_tar_sha remote_tar_sha object_key head_url put_url get_url remote_parent remote_tmp remote_tar bundle_id_value
  local -a endpoint_args=()

  require_cmd curl python3 tar
  remote_has_cmd "$host" "$port" "$user" "$identity_file" curl || die "remote host missing curl: $host"

  bundle_name=$(bundle_name_from_source "$bundle_path")
  tmp_tar=$(mktemp "${TMPDIR:-/tmp}/${bundle_name}.XXXXXX.tar.gz")
  bundle_tar_from_path "$bundle_path" "$bundle_name" "$tmp_tar"
  if [[ -n "$r2_endpoint" ]]; then
    endpoint_args+=(--endpoint "$r2_endpoint")
  fi

  local_tar_sha=$(calc_sha256 "$tmp_tar")
  if [[ "$force_mode" != 1 ]]; then
    remote_tar_sha=$(ssh_run "$host" "$port" "$user" "$identity_file" "cat '$remote_dir/.bundle/tar_sha256' 2>/dev/null || true" | tail -n 1)
    if [[ "$remote_tar_sha" == "$local_tar_sha" ]]; then
      log "remote bundle already matches $bundle_name on $host:$remote_dir"
      bundle_id_value=$(ssh_run "$host" "$port" "$user" "$identity_file" "cat '$remote_dir/.bundle/bundle_id' 2>/dev/null || true" | tail -n 1)
      rm -f "$tmp_tar"
      printf '%s\n' "$bundle_id_value"
      return 0
    fi
  fi

  object_key="${r2_prefix%/}/${bundle_name}/${local_tar_sha}.tar.gz"
  head_url=$(python3 "$script_dir/presign_r2_url.py" --profile "$r2_profile" --bucket "$r2_bucket" --key "$object_key" --method HEAD --expires 300 "${endpoint_args[@]}")
  if ! curl --fail --silent --show-error -X HEAD -o /dev/null "$head_url"; then
    put_url=$(python3 "$script_dir/presign_r2_url.py" --profile "$r2_profile" --bucket "$r2_bucket" --key "$object_key" --method PUT --expires 3600 "${endpoint_args[@]}")
    log "uploading $bundle_name to R2 object $object_key"
    curl --fail --silent --show-error -T "$tmp_tar" "$put_url" >/dev/null
  else
    log "reusing existing R2 object $object_key"
  fi

  get_url=$(python3 "$script_dir/presign_r2_url.py" --profile "$r2_profile" --bucket "$r2_bucket" --key "$object_key" --method GET --expires 86400 "${endpoint_args[@]}")
  remote_parent=$(dirname "$remote_dir")
  remote_tar="$remote_parent/.${bundle_name}.${local_tar_sha}.tar.gz"
  remote_tmp="$remote_parent/.${bundle_name}.incoming.$$"

  bundle_id_value=$(ssh_run "$host" "$port" "$user" "$identity_file" "
    mkdir -p '$remote_parent'
    rm -rf '$remote_tmp'
    mkdir -p '$remote_tmp'
    curl --fail --silent --show-error --location '$get_url' -o '$remote_tar'
    tar -C '$remote_tmp' -xzf '$remote_tar'
    rm -rf '$remote_dir'
    mv '$remote_tmp/$bundle_name' '$remote_dir'
    rmdir '$remote_tmp'
    printf '%s\n' '$local_tar_sha' > '$remote_dir/.bundle/tar_sha256'
    rm -f '$remote_tar'
    cat '$remote_dir/.bundle/bundle_id'
  " | tail -n 1)
  rm -f "$tmp_tar"
  printf '%s\n' "$bundle_id_value"
}

allow_running=0
force_mode=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-running)
      allow_running=1
      shift
      ;;
    --force)
      force_mode=1
      shift
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

if [[ $# -lt 4 || $# -gt 6 ]]; then
  usage
fi

require_cmd rsync scp sha256sum ssh

bundle_path=$1
host=$2
port=$3
remote_dir=$4
user=${5:-$remote_default_user}
identity_file=${6:-$remote_default_identity}

if [[ ! -e "$bundle_path" ]]; then
  die "bundle path not found: $bundle_path"
fi

if [[ $allow_running -ne 1 ]]; then
  ensure_remote_idle "$host" "$port" "$user" "$identity_file" "$remote_dir"
fi

r2_bucket=${WRF_REMOTE_R2_BUCKET:-}
r2_prefix=${WRF_REMOTE_R2_PREFIX:-wrf-bundles}
r2_profile=${WRF_REMOTE_R2_PROFILE:-r2}
r2_endpoint=${WRF_REMOTE_R2_ENDPOINT:-}

if [[ -n "$r2_bucket" ]]; then
  bundle_id=$(deploy_r2_bundle "$bundle_path" "$host" "$port" "$user" "$identity_file" "$remote_dir" "$force_mode" "$r2_bucket" "$r2_prefix" "$r2_profile" "$r2_endpoint")
elif [[ -d "$bundle_path" ]]; then
  bundle_id=$(deploy_dir_bundle "$bundle_path" "$host" "$port" "$user" "$identity_file" "$remote_dir")
else
  bundle_id=$(deploy_tar_bundle "$bundle_path" "$host" "$port" "$user" "$identity_file" "$remote_dir" "$force_mode")
fi

printf '%s bundle_id=%s\n' "${user}@${host}:$remote_dir" "${bundle_id:-unknown}"
