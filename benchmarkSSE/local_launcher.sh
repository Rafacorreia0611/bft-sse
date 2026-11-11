#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_LOCAL_DIR="$ROOT_DIR/build/local"

SSE_SERVER_COUNT=4
ORAM_SERVER_COUNT=""
CLIENT_COUNT=1
ORAM_CLIENT_SLOTS=1
READY_TIMEOUT_SECONDS=60

ABS_LOG_DIR=""
PID_FILE=""
CLEANUP_DONE=0

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [options]

Options:
  --servers N, --sse N        Number of SSE replicas. Default: 4
  --oram-servers N, --oram N  Number of ORAM replicas. Default: same as SSE replicas
  --clients N                 Number of generated client folders. Default: 1
  --oram-client-slots N        Max concurrent ORAM clients passed to ORAMServer. Default: 1
  --ready-timeout SECONDS     Seconds to wait for all replicas. Default: 60
  -h, --help                  Show this help message.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

ensure_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || die "Required file not found: $path"
}

ensure_dir_exists() {
  local path="$1"
  [[ -d "$path" ]] || die "Required directory not found: $path"
}

validate_positive_integer() {
  local value="$1"
  local label="$2"

  [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]] || die "$label must be a positive integer"
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --servers|--sse)
        [[ "$#" -ge 2 && "$2" != --* ]] || die "Missing value for $1"
        SSE_SERVER_COUNT="$2"
        shift 2
        ;;
      --servers=*|--sse=*)
        SSE_SERVER_COUNT="${1#*=}"
        [[ -n "$SSE_SERVER_COUNT" ]] || die "Missing value for ${1%%=*}"
        shift
        ;;
      --oram-servers|--oram)
        [[ "$#" -ge 2 && "$2" != --* ]] || die "Missing value for $1"
        ORAM_SERVER_COUNT="$2"
        shift 2
        ;;
      --oram-servers=*|--oram=*)
        ORAM_SERVER_COUNT="${1#*=}"
        [[ -n "$ORAM_SERVER_COUNT" ]] || die "Missing value for ${1%%=*}"
        shift
        ;;
      --clients)
        [[ "$#" -ge 2 && "$2" != --* ]] || die "Missing value for --clients"
        CLIENT_COUNT="$2"
        shift 2
        ;;
      --clients=*)
        CLIENT_COUNT="${1#*=}"
        [[ -n "$CLIENT_COUNT" ]] || die "Missing value for --clients"
        shift
        ;;
      --oram-client-slots)
        [[ "$#" -ge 2 && "$2" != --* ]] || die "Missing value for --oram-client-slots"
        ORAM_CLIENT_SLOTS="$2"
        shift 2
        ;;
      --oram-client-slots=*)
        ORAM_CLIENT_SLOTS="${1#*=}"
        [[ -n "$ORAM_CLIENT_SLOTS" ]] || die "Missing value for --oram-client-slots"
        shift
        ;;
      --ready-timeout)
        [[ "$#" -ge 2 && "$2" != --* ]] || die "Missing value for --ready-timeout"
        READY_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --ready-timeout=*)
        READY_TIMEOUT_SECONDS="${1#*=}"
        [[ -n "$READY_TIMEOUT_SECONDS" ]] || die "Missing value for --ready-timeout"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage
        die "Unknown argument: $1"
        ;;
    esac
  done

  if [[ -z "$ORAM_SERVER_COUNT" ]]; then
    ORAM_SERVER_COUNT="$SSE_SERVER_COUNT"
  fi
}

validate_args() {
  validate_positive_integer "$SSE_SERVER_COUNT" "SSE replica count"
  validate_positive_integer "$ORAM_SERVER_COUNT" "ORAM replica count"
  validate_positive_integer "$CLIENT_COUNT" "Client count"
  validate_positive_integer "$ORAM_CLIENT_SLOTS" "ORAM client slots"
  validate_positive_integer "$READY_TIMEOUT_SECONDS" "Ready timeout"

  (( SSE_SERVER_COUNT >= 4 )) || die "SSE replica count must be at least 4"
  (( ORAM_SERVER_COUNT >= 4 )) || die "ORAM replica count must be at least 4"
}

prepare_log_dir() {
  local run_date run_name

  run_date="$(date +%Y_%m_%d)"
  run_name="$(date +%H_%M_%S)_local_launcher_s${SSE_SERVER_COUNT}_o${ORAM_SERVER_COUNT}_c${CLIENT_COUNT}"
  ABS_LOG_DIR="$ROOT_DIR/benchmarkSSE/results/logs/$run_date/$run_name"
  PID_FILE="$ABS_LOG_DIR/pids.tmp"

  mkdir -p "$ABS_LOG_DIR"
}

run_local_deploy() {
  echo "Preparing clean local deployment..."
  (
    cd "$ROOT_DIR"
    ./gradlew clean localDeploy \
      -Pservers="$SSE_SERVER_COUNT" \
      -PoramServers="$ORAM_SERVER_COUNT" \
      -Pclients="$CLIENT_COUNT"
  )
}

initial_view() {
  local replica_count="$1"
  local replica_id
  local view=""

  for (( replica_id = 0; replica_id < replica_count; replica_id++ )); do
    [[ -z "$view" ]] || view+=","
    view+="$replica_id"
  done

  printf '%s\n' "$view"
}

fault_count_for() {
  local replica_count="$1"
  printf '%s\n' $(((replica_count - 1) / 3))
}

write_system_config() {
  local path="$1"
  local replica_count="$2"
  local fault_count="$3"
  local view="$4"
  local tmp_path="${path}.tmp"

  awk \
    -v replica_count="$replica_count" \
    -v fault_count="$fault_count" \
    -v initial_view="$view" \
    '
      /^system\.servers\.num[[:space:]]*=/ {
        print "system.servers.num = " replica_count
        next
      }
      /^system\.servers\.f[[:space:]]*=/ {
        print "system.servers.f = " fault_count
        next
      }
      /^system\.initial\.view[[:space:]]*=/ {
        print "system.initial.view = " initial_view
        next
      }
      { print }
    ' "$path" > "$tmp_path"
  mv "$tmp_path" "$path"
}

write_hosts_config() {
  local path="$1"
  local replica_count="$2"
  local base_port="$3"
  local ttp_port="$4"
  local tmp_path="${path}.tmp"
  local replica_id client_port server_port

  {
    printf '# This hosts.config was generated by %s for the local launcher.\n' "$(basename "$0")"
    printf '#server id, address and port (the ids from 0 to n-1 are the service replicas)\n'
    for (( replica_id = 0; replica_id < replica_count; replica_id++ )); do
      client_port=$((base_port + replica_id * 10))
      server_port=$((client_port + 1))
      printf '%s 127.0.0.1 %s %s\n' "$replica_id" "$client_port" "$server_port"
    done
    printf '\n'
    printf '7001 127.0.0.1 %s\n' "$ttp_port"
  } > "$tmp_path"
  mv "$tmp_path" "$path"
}

configure_service_dir() {
  local config_dir="$1"
  local replica_count="$2"
  local base_port="$3"
  local ttp_port="$4"
  local view fault_count

  ensure_file_exists "$config_dir/system.config"
  ensure_file_exists "$config_dir/hosts.config"

  view="$(initial_view "$replica_count")"
  fault_count="$(fault_count_for "$replica_count")"

  write_system_config "$config_dir/system.config" "$replica_count" "$fault_count" "$view"
  write_hosts_config "$config_dir/hosts.config" "$replica_count" "$base_port" "$ttp_port"
}

configure_local_deploy() {
  local index

  echo "Configuring SSE deployment for $SSE_SERVER_COUNT replicas..."
  for (( index = 0; index < SSE_SERVER_COUNT; index++ )); do
    configure_service_dir "$BUILD_LOCAL_DIR/rep${index}/config" "$SSE_SERVER_COUNT" 11000 11100
  done

  echo "Configuring ORAM deployment for $ORAM_SERVER_COUNT replicas..."
  for (( index = 0; index < ORAM_SERVER_COUNT; index++ )); do
    configure_service_dir "$BUILD_LOCAL_DIR/oramRep${index}/config" "$ORAM_SERVER_COUNT" 12000 12100
  done

  echo "Configuring $CLIENT_COUNT client deployment(s)..."
  for (( index = 0; index < CLIENT_COUNT; index++ )); do
    configure_service_dir "$BUILD_LOCAL_DIR/cli${index}/sse_config" "$SSE_SERVER_COUNT" 11000 11100
    configure_service_dir "$BUILD_LOCAL_DIR/cli${index}/config" "$ORAM_SERVER_COUNT" 12000 12100
  done
}

track_pid() {
  local name="$1"
  local pid="$2"

  printf '%s %s\n' "$name" "$pid" >> "$PID_FILE"
}

start_oram_replicas() {
  local replica_id pid

  echo "Starting ORAM replicas..."
  for (( replica_id = 0; replica_id < ORAM_SERVER_COUNT; replica_id++ )); do
    ensure_dir_exists "$BUILD_LOCAL_DIR/oramRep${replica_id}"
    (
      cd "$BUILD_LOCAL_DIR/oramRep${replica_id}"
      bash smartrun.sh oram.server.ORAMServer "$ORAM_CLIENT_SLOTS" "$replica_id"
    ) > "$ABS_LOG_DIR/oramRep${replica_id}.log" 2>&1 &
    pid="$!"
    track_pid "oramRep${replica_id}" "$pid"
  done
}

start_sse_replicas() {
  local replica_id pid

  echo "Starting SSE replicas..."
  for (( replica_id = 0; replica_id < SSE_SERVER_COUNT; replica_id++ )); do
    ensure_dir_exists "$BUILD_LOCAL_DIR/rep${replica_id}"
    (
      cd "$BUILD_LOCAL_DIR/rep${replica_id}"
      bash smartrun.sh sse.demo.server.Server "$replica_id"
    ) > "$ABS_LOG_DIR/rep${replica_id}.log" 2>&1 &
    pid="$!"
    track_pid "rep${replica_id}" "$pid"
  done
}

process_is_alive() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null
}

all_processes_alive() {
  local name pid

  while read -r name pid; do
    [[ -n "${name:-}" && -n "${pid:-}" ]] || continue
    if ! process_is_alive "$pid"; then
      echo "$name exited before the local launcher became ready." >&2
      return 1
    fi
  done < "$PID_FILE"

  return 0
}

all_replicas_ready() {
  local replica_id

  for (( replica_id = 0; replica_id < ORAM_SERVER_COUNT; replica_id++ )); do
    grep -q "Ready to process operations" "$ABS_LOG_DIR/oramRep${replica_id}.log" 2>/dev/null || return 1
  done

  for (( replica_id = 0; replica_id < SSE_SERVER_COUNT; replica_id++ )); do
    grep -q "Ready to process operations" "$ABS_LOG_DIR/rep${replica_id}.log" 2>/dev/null || return 1
  done

  return 0
}

print_log_tails() {
  local log_path

  for log_path in "$ABS_LOG_DIR"/*.log; do
    [[ -f "$log_path" ]] || continue
    echo "--- $(basename "$log_path") (tail) ---" >&2
    tail -n 20 "$log_path" >&2 || true
  done
}

wait_for_ready() {
  local deadline=$((SECONDS + READY_TIMEOUT_SECONDS))

  echo "Waiting up to ${READY_TIMEOUT_SECONDS}s for all replicas to become ready..."
  while (( SECONDS < deadline )); do
    all_processes_alive || {
      print_log_tails
      exit 1
    }

    if all_replicas_ready; then
      echo "Local launcher ready."
      echo "Logs: $ABS_LOG_DIR"
      echo "SSE replicas: $SSE_SERVER_COUNT"
      echo "ORAM replicas: $ORAM_SERVER_COUNT"
      echo "Clients deployed: $CLIENT_COUNT"
      return
    fi

    sleep 1
  done

  echo "Timed out while waiting for replicas to become ready." >&2
  print_log_tails
  exit 1
}

terminate_process_tree() {
  local pid="$1"
  local signal="$2"
  local child

  while read -r child; do
    [[ -n "$child" ]] || continue
    terminate_process_tree "$child" "$signal"
  done < <(pgrep -P "$pid" 2>/dev/null || true)

  kill "-$signal" "$pid" 2>/dev/null || true
}

cleanup() {
  local exit_status=$?
  local name pid

  trap - EXIT INT TERM
  if [[ "$CLEANUP_DONE" -eq 1 ]]; then
    exit "$exit_status"
  fi
  CLEANUP_DONE=1

  if [[ -n "${PID_FILE:-}" && -f "$PID_FILE" ]]; then
    echo "Stopping local launcher processes..."
    while read -r name pid; do
      [[ -n "${name:-}" && -n "${pid:-}" ]] || continue
      terminate_process_tree "$pid" TERM
    done < "$PID_FILE"

    sleep 1

    while read -r name pid; do
      [[ -n "${name:-}" && -n "${pid:-}" ]] || continue
      if process_is_alive "$pid"; then
        terminate_process_tree "$pid" KILL
      fi
      wait "$pid" 2>/dev/null || true
    done < "$PID_FILE"

    rm -f "$PID_FILE"
  fi

  exit "$exit_status"
}

wait_for_processes() {
  local name pid

  echo "Local launcher is running. Press Ctrl-C to stop replicas."
  while true; do
    while read -r name pid; do
      [[ -n "${name:-}" && -n "${pid:-}" ]] || continue
      if ! process_is_alive "$pid"; then
        echo "$name exited. See logs in $ABS_LOG_DIR" >&2
        exit 1
      fi
    done < "$PID_FILE"
    sleep 2
  done
}

main() {
  parse_args "$@"
  validate_args
  prepare_log_dir
  trap cleanup EXIT INT TERM

  run_local_deploy
  configure_local_deploy
  start_oram_replicas
  start_sse_replicas
  wait_for_ready
  wait_for_processes
}

main "$@"
