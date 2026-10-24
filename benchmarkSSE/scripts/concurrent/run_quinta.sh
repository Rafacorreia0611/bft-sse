#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEFAULT_CLUSTER_CONFIG="$ROOT_DIR/benchmarkSSE/config/quinta.env"
DEPLOY_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/quinta_deploy.sh"
COMMON_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/common/quinta_benchmark_common.sh"
SYNTHETIC_DATASET_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/datasets/synthetic_dataset.py"

CONFIG_PATH=""
CLUSTER_CONFIG="$DEFAULT_CLUSTER_CONFIG"

DEPLOY_CLIENT_COUNT=2
POPULATE_CLIENT_DIR=cli0
BENCHMARK_CLIENT_DIR=cli1

CLEANUP_DONE=0
CURRENT_RUN_ACTIVE=0
BENCHMARK_COMPLETED=0
REPLICA_LOGS_FETCHED=0
NODE_HEALTH_MONITOR_PID=""
LOG_CAPTURE_STARTED=0

# shellcheck source=../common/quinta_benchmark_common.sh
source "$COMMON_SCRIPT"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --config PATH [--cluster-config PATH]
EOF
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --config)
        [[ "$#" -ge 2 ]] || die "Missing value for --config"
        CONFIG_PATH="$2"
        shift 2
        ;;
      --config=*)
        CONFIG_PATH="${1#--config=}"
        [[ -n "$CONFIG_PATH" ]] || die "Missing value for --config"
        shift
        ;;
      --cluster-config)
        [[ "$#" -ge 2 ]] || die "Missing value for --cluster-config"
        CLUSTER_CONFIG="$2"
        shift 2
        ;;
      --cluster-config=*)
        CLUSTER_CONFIG="${1#--cluster-config=}"
        [[ -n "$CLUSTER_CONFIG" ]] || die "Missing value for --cluster-config"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$CONFIG_PATH" ]] || die "--config is required"
  [[ "$CONFIG_PATH" = /* ]] || CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH"
  [[ "$CLUSTER_CONFIG" = /* ]] || CLUSTER_CONFIG="$ROOT_DIR/$CLUSTER_CONFIG"
  CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

validate_positive_number() {
  local value="$1"
  local label="$2"

  [[ "$value" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$ ]] \
    || die "$label must be a positive number"
  awk -v value="$value" 'BEGIN { exit !(value > 0) }' \
    || die "$label must be greater than 0"
}

load_config() {
  ensure_file_exists "$CONFIG_PATH"
  ensure_file_exists "$CLUSTER_CONFIG"
  ensure_executable_exists "$DEPLOY_SCRIPT"
  ensure_file_exists "$SYNTHETIC_DATASET_SCRIPT"

  # shellcheck source=/dev/null
  source "$CLUSTER_CONFIG"

  VOCABULARY_PATH="$(get_property vocabularyPath)"
  SYNTHETIC_OUTPUT_PATH="$(get_property syntheticOutputPath)"
  SYNTHETIC_KEYWORD_COUNT="$(get_property syntheticKeywordCount)"
  SYNTHETIC_DOCUMENTS_PER_KEYWORD="$(get_property syntheticDocumentsPerKeyword)"
  CONFIGURED_SEED="$(get_property seed)"

  REPLICA_COUNT="$(get_property sseReplicas)"
  ORAM_REPLICA_COUNT="$(get_property oramReplicas)"
  POPULATE_CLIENT_ID="$(get_property populateClientId)"
  POPULATE_BATCH_SIZE="$(get_property populateBatchSize)"
  CLIENT_ID="$(get_property clientId)"
  CLIENT_COUNT="$(get_property clientCount)"

  SCENARIO="$(get_property scenario)"
  WARMUP_SECONDS="$(get_property warmupSeconds)"
  MEASUREMENT_SECONDS="$(get_property measurementSeconds)"
  WARMUP_KEYWORD_COUNT="$(get_property warmupKeywordCount)"

  TIMESTAMP_OUTPUTS="$(get_property timestampOutputs)"
  OUTPUT_PATH="$(get_property outputPath)"

  ABS_VOCABULARY_PATH="$(resolve_config_path "$VOCABULARY_PATH")"
  ABS_SYNTHETIC_OUTPUT_PATH="$(resolve_config_path "$SYNTHETIC_OUTPUT_PATH")"
  BASE_OUTPUT_PATH="$(resolve_config_path "$OUTPUT_PATH")"

  load_scenario_config
  validate_config
  prepare_paths
}

load_scenario_config() {
  case "$SCENARIO" in
    concurrent-workload)
      SEARCH_PERCENTAGE="$(get_property searchPercentage)"
      KEYWORD_SELECTION_DISTRIBUTION="$(lowercase "$(get_property keywordSelectionDistribution)")"
      ZIPFIAN_EXPONENT=""
      if [[ "$KEYWORD_SELECTION_DISTRIBUTION" == "zipfian" ]]; then
        ZIPFIAN_EXPONENT="$(get_property zipfianExponent)"
      fi
      ;;
    lock-contention)
      CONTENTION_LEVEL="$(lowercase "$(get_property contentionLevel)")"
      SHARED_KEYWORD_COUNT=""
      if [[ "$CONTENTION_LEVEL" == "moderate" ]]; then
        SHARED_KEYWORD_COUNT="$(get_property sharedKeywordCount)"
      fi
      ;;
    *)
      die "scenario must be concurrent-workload or lock-contention"
      ;;
  esac
}

validate_config() {
  validate_seed "$CONFIGURED_SEED" "seed"
  EFFECTIVE_SEED="$(resolve_seed "$CONFIGURED_SEED")"

  validate_positive_integer "$SYNTHETIC_KEYWORD_COUNT" "syntheticKeywordCount"
  validate_positive_integer "$SYNTHETIC_DOCUMENTS_PER_KEYWORD" "syntheticDocumentsPerKeyword"
  validate_positive_integer "$REPLICA_COUNT" "sseReplicas"
  (( REPLICA_COUNT >= 4 )) || die "sseReplicas must be at least 4"

  validate_integer "$ORAM_REPLICA_COUNT" "oramReplicas"
  if [[ "$ORAM_REPLICA_COUNT" == "-1" ]]; then
    ORAM_REPLICA_COUNT="$REPLICA_COUNT"
  else
    (( ORAM_REPLICA_COUNT >= 4 )) || die "oramReplicas must be -1 or at least 4"
  fi

  validate_positive_integer "$POPULATE_CLIENT_ID" "populateClientId"
  validate_positive_integer "$POPULATE_BATCH_SIZE" "populateBatchSize"
  validate_positive_integer "$CLIENT_ID" "clientId"
  validate_positive_integer "$CLIENT_COUNT" "clientCount"
  validate_positive_integer "$WARMUP_SECONDS" "warmupSeconds"
  validate_positive_integer "$MEASUREMENT_SECONDS" "measurementSeconds"
  validate_positive_integer "$WARMUP_KEYWORD_COUNT" "warmupKeywordCount"
  validate_boolean "$TIMESTAMP_OUTPUTS" "timestampOutputs"

  (( SYNTHETIC_KEYWORD_COUNT > WARMUP_KEYWORD_COUNT )) \
    || die "syntheticKeywordCount must be greater than warmupKeywordCount"

  HIGHEST_CLIENT_ID=$((CLIENT_ID + CLIENT_COUNT - 1))
  (( HIGHEST_CLIENT_ID <= 2147482647 )) \
    || die "Configured client IDs exceed the supported ORAM client ID range"
  if (( POPULATE_CLIENT_ID >= CLIENT_ID && POPULATE_CLIENT_ID <= HIGHEST_CLIENT_ID )); then
    die "populateClientId overlaps the benchmark client ID range"
  fi

  ORAM_MAX_CONCURRENT_CLIENTS="$CLIENT_COUNT"
  client_node >/dev/null

  [[ -s "$ABS_VOCABULARY_PATH" ]] \
    || die "Vocabulary file is missing or empty: $ABS_VOCABULARY_PATH"
  [[ -s "$ROOT_DIR/datasets/vocabulary/vocabulary.txt" ]] \
    || die "Deployed vocabulary is missing or empty"
  cmp -s "$ABS_VOCABULARY_PATH" "$ROOT_DIR/datasets/vocabulary/vocabulary.txt" \
    || die "Quinta benchmarks must use the vocabulary deployed from datasets/vocabulary/vocabulary.txt"

  validate_scenario_config
}

validate_scenario_config() {
  if [[ "$SCENARIO" == "concurrent-workload" ]]; then
    validate_integer "$SEARCH_PERCENTAGE" "searchPercentage"
    (( SEARCH_PERCENTAGE >= 0 && SEARCH_PERCENTAGE <= 100 )) \
      || die "searchPercentage must be between 0 and 100"
    [[ "$KEYWORD_SELECTION_DISTRIBUTION" == "uniform" \
        || "$KEYWORD_SELECTION_DISTRIBUTION" == "zipfian" ]] \
      || die "keywordSelectionDistribution must be uniform or zipfian"
    if [[ "$KEYWORD_SELECTION_DISTRIBUTION" == "zipfian" ]]; then
      validate_positive_number "$ZIPFIAN_EXPONENT" "zipfianExponent"
    fi
    return
  fi

  [[ "$CONTENTION_LEVEL" == "none" \
      || "$CONTENTION_LEVEL" == "moderate" \
      || "$CONTENTION_LEVEL" == "high" ]] \
    || die "contentionLevel must be none, moderate or high"
  if [[ "$CONTENTION_LEVEL" == "moderate" ]]; then
    validate_positive_integer "$SHARED_KEYWORD_COUNT" "sharedKeywordCount"
  fi
}

prepare_paths() {
  RUN_DATE="$(date +%d_%m_%Y)"
  if [[ "$TIMESTAMP_OUTPUTS" == "true" ]]; then
    RUN_NAME="$(date +%H_%M_%S)_quinta_concurrency_r${REPLICA_COUNT}_o${ORAM_REPLICA_COUNT}_c${CLIENT_COUNT}"
  else
    RUN_NAME="latest_quinta_concurrency_r${REPLICA_COUNT}_o${ORAM_REPLICA_COUNT}_c${CLIENT_COUNT}"
  fi

  ABS_OUTPUT_PATH="$(place_path_in_run_dir "$BASE_OUTPUT_PATH" "$RUN_DATE/$RUN_NAME")"
  ABS_LOG_DIR="$ROOT_DIR/benchmarkSSE/results/logs/$RUN_DATE/$RUN_NAME"
  LOCAL_RUNTIME_CONFIG_PATH="$ABS_LOG_DIR/runtime_concurrency.properties"
  RUN_LOG_PATH="$ABS_LOG_DIR/run_concurrency_quinta.log"
  EXPECTED_ASSOCIATION_COUNT=$((SYNTHETIC_KEYWORD_COUNT * SYNTHETIC_DOCUMENTS_PER_KEYWORD))

  mkdir -p "$(dirname "$ABS_OUTPUT_PATH")" "$ABS_LOG_DIR"
}

start_log_capture() {
  [[ "$LOG_CAPTURE_STARTED" -eq 0 ]] || return
  LOG_CAPTURE_STARTED=1
  exec > >(tee -a "$RUN_LOG_PATH") 2>&1

  echo "Quinta concurrency run: $RUN_NAME"
  echo "Config: $CONFIG_PATH"
  echo "Cluster config: $CLUSTER_CONFIG"
  echo "Scenario: $SCENARIO"
  echo "SSE replicas: $REPLICA_COUNT"
  echo "ORAM replicas: $ORAM_REPLICA_COUNT"
  echo "Clients: $CLIENT_COUNT"
  echo "Configured seed: $CONFIGURED_SEED"
  echo "Effective seed: $EFFECTIVE_SEED"
}

generate_dataset() {
  echo "Generating constant-size synthetic dataset..."
  python3 "$SYNTHETIC_DATASET_SCRIPT" \
    --output "$ABS_SYNTHETIC_OUTPUT_PATH" \
    --vocabulary "$ABS_VOCABULARY_PATH" \
    --keywords-per-doc-count "$SYNTHETIC_KEYWORD_COUNT" \
    --doc-counts "$SYNTHETIC_DOCUMENTS_PER_KEYWORD" \
    --seed "$EFFECTIVE_SEED"

  [[ -s "$ABS_SYNTHETIC_OUTPUT_PATH" ]] || die "Generated synthetic dataset is empty"
  [[ "$(wc -l < "$ABS_SYNTHETIC_OUTPUT_PATH")" -eq "$SYNTHETIC_KEYWORD_COUNT" ]] \
    || die "Generated synthetic dataset line count did not match syntheticKeywordCount"
}

write_local_runtime_config() {
  {
    printf '# Runtime benchmark config generated by %s\n' "$(basename "$0")"
    printf 'runtimeSseReplicas=%s\n' "$REPLICA_COUNT"
    printf 'runtimeOramReplicas=%s\n' "$ORAM_REPLICA_COUNT"
    printf 'runtimeOramMaxConcurrentClients=%s\n' "$ORAM_MAX_CONCURRENT_CLIENTS"
    printf 'runtimeConfiguredSeed=%s\n' "$CONFIGURED_SEED"
    printf 'runtimeEffectiveSeed=%s\n' "$EFFECTIVE_SEED"
    printf 'scenario=%s\n' "$SCENARIO"
    printf 'clientId=%s\n' "$CLIENT_ID"
    printf 'clientCount=%s\n' "$CLIENT_COUNT"
    printf 'warmupSeconds=%s\n' "$WARMUP_SECONDS"
    printf 'measurementSeconds=%s\n' "$MEASUREMENT_SECONDS"
    printf 'warmupKeywordCount=%s\n' "$WARMUP_KEYWORD_COUNT"
    printf 'seed=%s\n' "$EFFECTIVE_SEED"
    printf 'vocabularyPath=%s\n' "$BENCHMARK_REMOTE_VOCABULARY_PATH"
    printf 'inputPath=%s\n' "$REMOTE_DATASET_PATH"
    printf 'outputPath=%s\n' "$REMOTE_OUTPUT_PATH"

    if [[ "$SCENARIO" == "concurrent-workload" ]]; then
      printf 'searchPercentage=%s\n' "$SEARCH_PERCENTAGE"
      printf 'keywordSelectionDistribution=%s\n' "$KEYWORD_SELECTION_DISTRIBUTION"
      if [[ "$KEYWORD_SELECTION_DISTRIBUTION" == "zipfian" ]]; then
        printf 'zipfianExponent=%s\n' "$ZIPFIAN_EXPONENT"
      fi
    else
      printf 'contentionLevel=%s\n' "$CONTENTION_LEVEL"
      if [[ "$CONTENTION_LEVEL" == "moderate" ]]; then
        printf 'sharedKeywordCount=%s\n' "$SHARED_KEYWORD_COUNT"
      fi
    fi
  } > "$LOCAL_RUNTIME_CONFIG_PATH"
}

copy_benchmark_inputs() {
  local host remote_base
  host="$(client_node)"
  remote_base="$(remote_run_dir)/benchmark"

  REMOTE_DATASET_PATH="$remote_base/input/$(basename "$ABS_SYNTHETIC_OUTPUT_PATH")"
  REMOTE_RUNTIME_CONFIG_PATH="$remote_base/runtime_concurrency.properties"
  REMOTE_OUTPUT_PATH="$remote_base/results/$(basename "$ABS_OUTPUT_PATH")"
  POPULATE_REMOTE_VOCABULARY_PATH="$(remote_run_dir)/$POPULATE_CLIENT_DIR/datasets/vocabulary/vocabulary.txt"
  BENCHMARK_REMOTE_VOCABULARY_PATH="$(remote_run_dir)/$BENCHMARK_CLIENT_DIR/datasets/vocabulary/vocabulary.txt"

  write_local_runtime_config

  ssh_remote "$host" "mkdir -p '$remote_base/input' '$remote_base/results'"
  scp_remote "$ABS_SYNTHETIC_OUTPUT_PATH" "$host:$REMOTE_DATASET_PATH"
  scp_remote "$LOCAL_RUNTIME_CONFIG_PATH" "$host:$REMOTE_RUNTIME_CONFIG_PATH"
}

run_populate_remote() {
  local host processed_doc_ids processed_keywords remote_command
  host="$(client_node)"
  printf -v remote_command \
    'cd %q && env JAVA_OPTS=%q bash smartrun.sh %q --client-id %q --input %q --batch-size %q --vocabulary %q' \
    "$(remote_run_dir)/$POPULATE_CLIENT_DIR" \
    "$QUINTA_CLIENT_JAVA_OPTS" \
    "sse.populatedb.PopulateDB" \
    "$POPULATE_CLIENT_ID" \
    "$REMOTE_DATASET_PATH" \
    "$POPULATE_BATCH_SIZE" \
    "$POPULATE_REMOTE_VOCABULARY_PATH"

  echo "Running PopulateDB on $host..."
  run_remote_job "$host" "populate" "$remote_command" "$ABS_LOG_DIR/populate.log"
  grep -q "PopulateDB finished." "$ABS_LOG_DIR/populate.log" || {
    tail -n 40 "$ABS_LOG_DIR/populate.log" >&2 || true
    die "PopulateDB did not finish successfully"
  }

  processed_keywords="$(sed -n 's/^Processed keywords: //p' "$ABS_LOG_DIR/populate.log" | tail -n 1)"
  processed_doc_ids="$(sed -n 's/^Processed doc IDs: //p' "$ABS_LOG_DIR/populate.log" | tail -n 1)"
  [[ "$processed_keywords" == "$SYNTHETIC_KEYWORD_COUNT" ]] \
    || die "PopulateDB processed $processed_keywords keywords, expected $SYNTHETIC_KEYWORD_COUNT"
  [[ "$processed_doc_ids" == "$EXPECTED_ASSOCIATION_COUNT" ]] \
    || die "PopulateDB processed $processed_doc_ids document IDs, expected $EXPECTED_ASSOCIATION_COUNT"
  echo "PopulateDB finished and validated successfully."
}

run_benchmark_remote() {
  local host remote_command
  host="$(client_node)"
  printf -v remote_command \
    'cd %q && env JAVA_OPTS=%q bash smartrun.sh %q %q' \
    "$(remote_run_dir)/$BENCHMARK_CLIENT_DIR" \
    "$QUINTA_CLIENT_JAVA_OPTS" \
    "sse.benchmark.BenchmarkClient" \
    "$REMOTE_RUNTIME_CONFIG_PATH"

  echo "Running BenchmarkClient on $host..."
  run_remote_job "$host" "benchmark" "$remote_command" "$ABS_LOG_DIR/benchmark.log"
  echo "BenchmarkClient finished successfully."
}

add_monitored_node() {
  local candidate="$1"
  local existing

  if (( ${#MONITORED_NODES[@]} > 0 )); then
    for existing in "${MONITORED_NODES[@]}"; do
      [[ "$existing" == "$candidate" ]] && return
    done
  fi
  MONITORED_NODES+=("$candidate")
}

prepare_monitored_nodes() {
  local node replica_id
  MONITORED_NODES=()
  add_monitored_node "$(client_node)"

  for (( replica_id = 0; replica_id < REPLICA_COUNT; replica_id++ )); do
    node="${QUINTA_NODES[$((replica_id % ${#QUINTA_NODES[@]}))]}"
    add_monitored_node "${QUINTA_SSH_PREFIX}${node}"
  done
  for (( replica_id = 0; replica_id < ORAM_REPLICA_COUNT; replica_id++ )); do
    node="${QUINTA_NODES[$((replica_id % ${#QUINTA_NODES[@]}))]}"
    add_monitored_node "${QUINTA_SSH_PREFIX}${node}"
  done
}

start_node_health_monitor() {
  local interval_seconds="${QUINTA_HEALTH_MONITOR_INTERVAL_SECONDS:-10}"
  local health_dir="$ABS_LOG_DIR/node_health"

  [[ -z "$NODE_HEALTH_MONITOR_PID" ]] || return
  mkdir -p "$health_dir"
  echo "Starting Quinta node health monitor (${interval_seconds}s) -> $health_dir"

  (
    set +e
    while true; do
      for host in "${MONITORED_NODES[@]}"; do
        {
          printf '\n===== %s run=%s =====\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$RUN_NAME"
          ssh_remote "$host" "uptime; free -m | awk 'NR <= 3'; ps -eo pid,ppid,pcpu,pmem,rss,etime,args --sort=-pcpu | grep -E 'sse\\.demo\\.server\\.Server|oram\\.server\\.ORAMServer|sse\\.benchmark\\.BenchmarkClient|sse\\.populatedb\\.PopulateDB|[s]martrun\\.sh' | head -20 || true" 2>&1
          printf 'ssh_exit=%s\n' "$?"
        } >> "$health_dir/$host.log"
      done
      sleep "$interval_seconds"
    done
  ) &
  NODE_HEALTH_MONITOR_PID="$!"
}

stop_node_health_monitor() {
  if [[ -n "$NODE_HEALTH_MONITOR_PID" ]]; then
    kill "$NODE_HEALTH_MONITOR_PID" 2>/dev/null || true
    wait "$NODE_HEALTH_MONITOR_PID" 2>/dev/null || true
    NODE_HEALTH_MONITOR_PID=""
  fi
}

fetch_replica_logs() {
  local node replica_id remote_log
  local copy_failed=0

  [[ "$CURRENT_RUN_ACTIVE" -eq 1 ]] || return
  [[ "$REPLICA_LOGS_FETCHED" -eq 0 ]] || return
  echo "Fetching replica logs..."

  for (( replica_id = 0; replica_id < ORAM_REPLICA_COUNT; replica_id++ )); do
    node="${QUINTA_NODES[$((replica_id % ${#QUINTA_NODES[@]}))]}"
    remote_log="$(remote_run_dir)/oramRep${replica_id}/server.log"
    scp_remote "${QUINTA_SSH_PREFIX}${node}:$remote_log" "$ABS_LOG_DIR/oramRep${replica_id}.log" \
      || copy_failed=1
  done

  for (( replica_id = 0; replica_id < REPLICA_COUNT; replica_id++ )); do
    node="${QUINTA_NODES[$((replica_id % ${#QUINTA_NODES[@]}))]}"
    remote_log="$(remote_run_dir)/rep${replica_id}/server.log"
    scp_remote "${QUINTA_SSH_PREFIX}${node}:$remote_log" "$ABS_LOG_DIR/rep${replica_id}.log" \
      || copy_failed=1
  done

  [[ "$copy_failed" -eq 0 ]] || return 1
  REPLICA_LOGS_FETCHED=1
}

verify_replica_logs() {
  local replica_id log_path

  for (( replica_id = 0; replica_id < ORAM_REPLICA_COUNT; replica_id++ )); do
    log_path="$ABS_LOG_DIR/oramRep${replica_id}.log"
    [[ -s "$log_path" ]] || die "ORAM replica log is missing or empty: $log_path"
  done
  for (( replica_id = 0; replica_id < REPLICA_COUNT; replica_id++ )); do
    log_path="$ABS_LOG_DIR/rep${replica_id}.log"
    [[ -s "$log_path" ]] || die "SSE replica log is missing or empty: $log_path"
  done
}

fetch_results() {
  copy_remote_file_with_retry "$(client_node)" "$REMOTE_OUTPUT_PATH" "$ABS_OUTPUT_PATH"
}

verify_results() {
  local actual_rows

  [[ -s "$ABS_OUTPUT_PATH" ]] || die "Benchmark CSV is missing or empty: $ABS_OUTPUT_PATH"
  actual_rows=$(( $(wc -l < "$ABS_OUTPUT_PATH") - 1 ))
  (( actual_rows > 0 )) || die "Benchmark CSV contains no measurements"
}

print_result_counts() {
  awk -F',' '
    NR > 1 {
      total++
      if ($2 == "SEARCH") searches++
      if ($2 == "UPDATE") updates++
    }
    END {
      printf "Measured rows: %d (%d searches, %d updates)\n", total, searches, updates
    }
  ' "$ABS_OUTPUT_PATH"
}

clean_successful_run() {
  stop_node_health_monitor
  echo "Cleaning successful remote benchmark run..."
  deploy_arg clean
  CURRENT_RUN_ACTIVE=0
  BENCHMARK_COMPLETED=0
}

cleanup() {
  local exit_status=$?
  trap - EXIT INT TERM

  if [[ "$CLEANUP_DONE" -eq 0 ]]; then
    CLEANUP_DONE=1
    stop_node_health_monitor
    if [[ "$CURRENT_RUN_ACTIVE" -eq 1 ]]; then
      fetch_replica_logs || true
      if [[ "$BENCHMARK_COMPLETED" -eq 1 ]]; then
        deploy_arg clean || true
      else
        deploy_arg stop || true
        echo "Remote run directory preserved for debugging: $(remote_run_dir)" >&2
      fi
    fi
  fi

  exit "$exit_status"
}

main() {
  parse_args "$@"
  ensure_command_exists python3
  load_config
  trap cleanup EXIT INT TERM

  start_log_capture
  generate_dataset

  deploy_arg preclean
  deploy_arg preflight
  deploy_arg deploy
  CURRENT_RUN_ACTIVE=1
  deploy_arg start
  deploy_arg wait

  prepare_monitored_nodes
  start_node_health_monitor
  copy_benchmark_inputs
  run_populate_remote
  run_benchmark_remote
  fetch_replica_logs
  verify_replica_logs
  fetch_results
  verify_results
  print_result_counts

  BENCHMARK_COMPLETED=1
  clean_successful_run

  echo "Benchmark CSV: $ABS_OUTPUT_PATH"
  echo "Benchmark logs: $ABS_LOG_DIR"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
