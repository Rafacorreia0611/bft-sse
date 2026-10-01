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

validate_seed() {
  local value="$1"
  local label="$2"
  [[ "$value" == "random" || "$value" =~ ^-?[0-9]+$ ]] \
    || die "$label must be an integer or random"
}

resolve_seed() {
  local configured_seed="$1"
  if [[ "$configured_seed" == "random" ]]; then
    python3 -c 'import secrets; print(secrets.randbits(63))'
  else
    printf '%s\n' "$configured_seed"
  fi
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

start_remote_job() {
  local host="$1"
  local job_dir="$2"
  local command="$3"
  local retry_seconds="${QUINTA_REMOTE_JOB_RETRY_SECONDS:-15}"
  local wrapper quoted_wrapper status

  wrapper="
    printf '%s\n' \"\$\$\" > '$job_dir/job.pid.tmp'
    mv '$job_dir/job.pid.tmp' '$job_dir/job.pid'
    set +e
    $command
    status=\$?
    printf '%s\n' \"\$status\" > '$job_dir/job.exit.tmp'
    mv '$job_dir/job.exit.tmp' '$job_dir/job.exit'
    exit \"\$status\"
  "
  printf -v quoted_wrapper '%q' "$wrapper"

  while true; do
    if ssh_remote "$host" "
      mkdir -p '$job_dir'
      if [ -s '$job_dir/job.exit' ] || { [ -s '$job_dir/job.pid' ] && kill -0 \"\$(cat '$job_dir/job.pid')\" 2>/dev/null; }; then
        exit 0
      fi
      [ ! -e '$job_dir/job.pid' ] || exit 2
      nohup bash -lc $quoted_wrapper > '$job_dir/job.log' 2>&1 < /dev/null &
    "; then
      return 0
    else
      status=$?
    fi

    if [[ "$status" -ne 255 ]]; then
      echo "Could not start the remote job on $host." >&2
      return "$status"
    fi

    echo "Could not confirm the remote job launch; retrying in ${retry_seconds}s..." >&2
    sleep "$retry_seconds"
  done
}

copy_remote_file_with_retry() {
  local host="$1"
  local remote_path="$2"
  local local_path="$3"
  local retry_seconds="${QUINTA_REMOTE_JOB_RETRY_SECONDS:-15}"
  local status

  while ! scp_remote "$host:$remote_path" "$local_path"; do
    if ssh_remote "$host" "test -f '$remote_path'" 2>/dev/null; then
      status=0
    else
      status=$?
    fi

    if [[ "$status" -ne 0 && "$status" -ne 255 ]]; then
      echo "Remote file does not exist: $remote_path" >&2
      return 1
    fi

    echo "Cannot retrieve $remote_path; retrying in ${retry_seconds}s..." >&2
    sleep "$retry_seconds"
  done
}

run_remote_job() {
  local host="$1"
  local job_name="$2"
  local command="$3"
  local local_log="$4"
  local poll_seconds="${QUINTA_REMOTE_JOB_POLL_SECONDS:-30}"
  local retry_seconds="${QUINTA_REMOTE_JOB_RETRY_SECONDS:-15}"
  local job_dir="$(remote_run_dir)/benchmark/jobs/$job_name"
  local snapshot state progress exit_code
  local last_progress=""
  local connection_lost=0

  start_remote_job "$host" "$job_dir" "$command"

  while true; do
    if snapshot="$(ssh_remote "$host" "
      if [ -s '$job_dir/job.exit' ]; then
        printf 'FINISHED:%s\n' \"\$(cat '$job_dir/job.exit')\"
      elif [ -s '$job_dir/job.pid' ] && kill -0 \"\$(cat '$job_dir/job.pid')\" 2>/dev/null; then
        printf 'RUNNING\n'
      elif [ -e '$job_dir/job.pid' ]; then
        sleep 1
        if [ -s '$job_dir/job.exit' ]; then
          printf 'FINISHED:%s\n' \"\$(cat '$job_dir/job.exit')\"
        else
          printf 'LOST\n'
        fi
      else
        printf 'STARTING\n'
      fi
      if [ -s '$job_dir/job.log' ]; then
        tr '\r' '\n' < '$job_dir/job.log' | awk 'NF { latest = \$0 } END { if (latest != \"\") print latest }'
      fi
    " 2>/dev/null)"; then
      if [[ "$connection_lost" -eq 1 ]]; then
        echo "Quinta connection restored; continuing to monitor $job_name."
        connection_lost=0
      fi

      state="$(printf '%s\n' "$snapshot" | head -n 1)"
      progress="$(printf '%s\n' "$snapshot" | tail -n +2 | tail -n 1)"
      if [[ -n "$progress" && "$progress" != "$last_progress" ]]; then
        echo "$progress"
        last_progress="$progress"
      fi

      case "$state" in
        RUNNING|STARTING) sleep "$poll_seconds" ;;
        FINISHED:*)
          exit_code="${state#FINISHED:}"
          break
          ;;
        LOST)
          copy_remote_file_with_retry "$host" "$job_dir/job.log" "$local_log" || true
          echo "Remote $job_name job stopped without recording an exit status." >&2
          return 1
          ;;
        *)
          echo "Unexpected remote $job_name status: ${state:-empty}" >&2
          return 1
          ;;
      esac
    else
      if [[ "$connection_lost" -eq 0 ]]; then
        echo "Cannot reach Quinta; $job_name continues remotely. Retrying in ${retry_seconds}s..." >&2
        connection_lost=1
      fi
      sleep "$retry_seconds"
    fi
  done

  copy_remote_file_with_retry "$host" "$job_dir/job.log" "$local_log"
  if ! [[ "$exit_code" =~ ^[0-9]+$ ]] || [[ "$exit_code" -ne 0 ]]; then
    echo "Remote $job_name failed with exit status ${exit_code:-unknown}." >&2
    tail -n 40 "$local_log" >&2 || true
    return 1
  fi
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
