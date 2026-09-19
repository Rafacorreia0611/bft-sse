#!/usr/bin/env bash

die() {
  echo "Error: $*" >&2
  exit 1
}

ensure_file_exists() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Required file not found: $path" >&2
    exit 1
  fi
}

ensure_executable_exists() {
  local path="$1"
  if [[ ! -x "$path" ]]; then
    echo "Required executable not found: $path" >&2
    exit 1
  fi
}

ensure_command_exists() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found on PATH: $command_name" >&2
    exit 1
  fi
}

ssh_remote() {
  ssh -n \
    -o BatchMode=yes \
    -o ConnectTimeout="${QUINTA_SSH_CONNECT_TIMEOUT_SECONDS:-10}" \
    -o ServerAliveInterval="${QUINTA_SSH_SERVER_ALIVE_INTERVAL_SECONDS:-5}" \
    -o ServerAliveCountMax="${QUINTA_SSH_SERVER_ALIVE_COUNT_MAX:-2}" \
    "$@"
}

scp_remote() {
  scp -q \
    -o BatchMode=yes \
    -o ConnectTimeout="${QUINTA_SSH_CONNECT_TIMEOUT_SECONDS:-10}" \
    -o ServerAliveInterval="${QUINTA_SSH_SERVER_ALIVE_INTERVAL_SECONDS:-5}" \
    -o ServerAliveCountMax="${QUINTA_SSH_SERVER_ALIVE_COUNT_MAX:-2}" \
    "$@"
}

get_property() {
  local key="$1"
  local value
  value="$(sed -n "s/^${key}=//p" "$CONFIG_PATH" | tail -n 1)"
  [[ -n "$value" ]] || die "Missing property '$key' in $CONFIG_PATH"
  printf '%s\n' "$value"
}

resolve_config_path() {
  local raw_path="$1"

  python3 -c 'import os, sys; print(os.path.abspath(os.path.join(sys.argv[1], sys.argv[2])))' \
    "$CONFIG_DIR" "$raw_path"
}

place_path_in_run_dir() {
  local path="$1"
  local run_dir="$2"
  printf '%s/%s/%s\n' "$(dirname "$path")" "$run_dir" "$(basename "$path")"
}

validate_positive_integer() {
  local value="$1"
  local label="$2"
  [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]] || die "$label must be a positive integer"
}

validate_integer() {
  local value="$1"
  local label="$2"
  [[ "$value" =~ ^-?[0-9]+$ ]] || die "$label must be an integer"
}

validate_boolean() {
  local value="$1"
  local label="$2"
  [[ "$value" == "true" || "$value" == "false" ]] || die "$label must be true or false"
}

validate_client_dir() {
  local dir_name="$1"
  local label="$2"
  local client_index

  [[ "$dir_name" =~ ^cli[0-9]+$ ]] || die "$label must use cliN"
  client_index="${dir_name#cli}"
  (( client_index < DEPLOY_CLIENT_COUNT )) || die "$label requires deployClientCount > $client_index"
}

normalize_csv_list() {
  printf '%s' "$1" | tr -d '[:space:]'
}

parse_replica_list() {
  local compact_list replica_count

  compact_list="${REPLICA_LIST//[[:space:]]/}"
  if [[ -z "$compact_list" ]]; then
    echo "Replica list cannot be empty." >&2
    exit 1
  fi

  IFS=',' read -r -a REPLICA_COUNTS <<< "$compact_list"
  for replica_count in "${REPLICA_COUNTS[@]}"; do
    if ! [[ "$replica_count" =~ ^[0-9]+$ ]] || [[ "$replica_count" -lt 4 ]]; then
      echo "Replica counts must be integers greater than or equal to 4: $replica_count" >&2
      exit 1
    fi
  done
}

csv_item_count() {
  local list
  list="$(normalize_csv_list "$1")"
  [[ -n "$list" ]] || {
    printf '0\n'
    return
  }
  printf '%s\n' "$list" | awk -F',' '{print NF}'
}

sum_csv_list() {
  local list="$1"
  local value
  local total=0

  list="$(normalize_csv_list "$list")"
  [[ -n "$list" ]] || die "CSV list cannot be empty"

  IFS=',' read -r -a CSV_SUM_VALUES <<< "$list"
  for value in "${CSV_SUM_VALUES[@]}"; do
    validate_positive_integer "$value" "CSV list value"
    total=$((total + value))
  done

  printf '%s\n' "$total"
}

calculate_fault_count() {
  FAULT_COUNT=$(((REPLICA_COUNT - 1) / 3))
}

fault_count_for() {
  local replica_count="$1"
  printf '%s\n' $(((replica_count - 1) / 3))
}

client_node() {
  local node_index="$REPLICA_COUNT"
  (( ORAM_REPLICA_COUNT <= node_index )) || node_index="$ORAM_REPLICA_COUNT"
  (( node_index < ${#QUINTA_NODES[@]} )) \
    || die "one Quinta node must remain reserved for clients"
  printf '%s%s\n' "$QUINTA_SSH_PREFIX" "${QUINTA_NODES[$node_index]}"
}

remote_run_dir() {
  printf '%s/%s\n' "$QUINTA_REMOTE_ROOT" "$RUN_NAME"
}

deploy_arg() {
  "$DEPLOY_SCRIPT" "$1" \
    --cluster-config "$CLUSTER_CONFIG" \
    --sseReplicas "$REPLICA_COUNT" \
    --oramReplicas "${ORAM_REPLICA_COUNT:--1}" \
    --oramMaxConcurrentClients "${ORAM_MAX_CONCURRENT_CLIENTS:-1}" \
    --clients "$DEPLOY_CLIENT_COUNT" \
    --run-name "$RUN_NAME"
}
