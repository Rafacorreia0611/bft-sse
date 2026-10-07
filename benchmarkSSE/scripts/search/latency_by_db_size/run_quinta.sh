#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DEFAULT_CONFIG="$ROOT_DIR/benchmarkSSE/config/search/latency_by_db_size.properties"
DEFAULT_CLUSTER_CONFIG="$ROOT_DIR/benchmarkSSE/config/quinta.env"
DEPLOY_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/quinta_deploy.sh"
COMMON_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/common/quinta_benchmark_common.sh"
DATASET_GENERATOR="$ROOT_DIR/benchmarkSSE/scripts/search/latency_by_db_size/generate_datasets.py"
SUMMARIZE_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/search/latency_by_db_size/summarize.py"
# Matches METRICS in summarize.py.
N_METRICS=8

CONFIG_PATH="$DEFAULT_CONFIG"
CLUSTER_CONFIG="$DEFAULT_CLUSTER_CONFIG"
SSE_REPLICA_COUNT_OVERRIDE=""
ORAM_REPLICA_COUNT_OVERRIDE=""
SEED_OVERRIDE=""
SSE_REPLICA_COUNT_SOURCE="config"
ORAM_REPLICA_COUNT_SOURCE="config"

CLEANUP_DONE=0
CURRENT_RUN_ACTIVE=0
BENCHMARK_COMPLETED=0
REPLICA_LOGS_FETCHED=0
NODE_HEALTH_MONITOR_PID=""
LOG_CAPTURE_STARTED=0

# shellcheck source=../../common/quinta_benchmark_common.sh
source "$COMMON_SCRIPT"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--config PATH] [--cluster-config PATH] [--sseReplicas N] [--oramReplicas N] [--seed N]
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
      --sseReplicas)
        [[ "$#" -ge 2 && "$2" != --* ]] || die "Missing value for --sseReplicas"
        SSE_REPLICA_COUNT_OVERRIDE="$2"
        shift 2
        ;;
      --sseReplicas=*)
        SSE_REPLICA_COUNT_OVERRIDE="${1#--sseReplicas=}"
        [[ -n "$SSE_REPLICA_COUNT_OVERRIDE" ]] || die "Missing value for --sseReplicas"
        shift
        ;;
      --oramReplicas)
        [[ "$#" -ge 2 && "$2" != --* ]] || die "Missing value for --oramReplicas"
        ORAM_REPLICA_COUNT_OVERRIDE="$2"
        shift 2
        ;;
      --oramReplicas=*)
        ORAM_REPLICA_COUNT_OVERRIDE="${1#--oramReplicas=}"
        [[ -n "$ORAM_REPLICA_COUNT_OVERRIDE" ]] || die "Missing value for --oramReplicas"
        shift
        ;;
      --seed)
        [[ "$#" -ge 2 && "$2" != --* ]] || die "Missing value for --seed"
        SEED_OVERRIDE="$2"
        shift 2
        ;;
      --seed=*)
        SEED_OVERRIDE="${1#--seed=}"
        [[ -n "$SEED_OVERRIDE" ]] || die "Missing value for --seed"
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

  [[ "$CONFIG_PATH" = /* ]] || CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH"
  [[ "$CLUSTER_CONFIG" = /* ]] || CLUSTER_CONFIG="$ROOT_DIR/$CLUSTER_CONFIG"
  CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
}

load_config() {
  ensure_file_exists "$CONFIG_PATH"
  ensure_file_exists "$CLUSTER_CONFIG"
  ensure_executable_exists "$DEPLOY_SCRIPT"
  ensure_file_exists "$DATASET_GENERATOR"
  ensure_file_exists "$SUMMARIZE_SCRIPT"

  # shellcheck source=/dev/null
  source "$CLUSTER_CONFIG"

  VOCABULARY_PATH="$(get_property vocabularyPath)"
  DATASET_OUTPUT_DIR="$(get_property datasetOutputDir)"
  CONFIGURED_SEED="$(get_property seed)"
  DB_SIZES="$(normalize_csv_list "$(get_property dbSizes)")"
  SEARCH_RESULT_SIZE="$(get_property searchResultSize)"
  FILLER_DOCS_PER_KEYWORD="$(get_property fillerDocsPerKeyword)"

  REPLICA_COUNT="$(get_property sseReplicas)"
  if [[ -n "$SSE_REPLICA_COUNT_OVERRIDE" ]]; then
    REPLICA_COUNT="$SSE_REPLICA_COUNT_OVERRIDE"
    SSE_REPLICA_COUNT_SOURCE="CLI override"
  fi

  ORAM_REPLICA_COUNT="$(get_property oramReplicas)"
  if [[ -n "$ORAM_REPLICA_COUNT_OVERRIDE" ]]; then
    ORAM_REPLICA_COUNT="$ORAM_REPLICA_COUNT_OVERRIDE"
    ORAM_REPLICA_COUNT_SOURCE="CLI override"
  fi
  if [[ "$ORAM_REPLICA_COUNT" == "-1" ]]; then
    ORAM_REPLICA_COUNT="$REPLICA_COUNT"
    ORAM_REPLICA_COUNT_SOURCE="follow SSE"
  fi

  ORAM_MAX_CONCURRENT_CLIENTS="$(get_property oramMaxConcurrentClients)"
  DEPLOY_CLIENT_COUNT="$(get_property deployClientCount)"
  POPULATE_CLIENT_DIR="$(get_property populateClientDir)"
  POPULATE_CLIENT_ID="$(get_property populateClientId)"
  POPULATE_BATCH_SIZE="$(get_property populateBatchSize)"
  BENCHMARK_CLIENT_DIR="$(get_property benchmarkClientDir)"
  CLIENT_ID="$(get_property clientId)"
  SCENARIO="$(get_property scenario)"
  WARMUP_PER_BUCKET="$(get_property warmupPerBucket)"
  MEASUREMENTS_PER_BUCKET="$(get_property measurementsPerBucket)"
  TIMESTAMP_OUTPUTS="$(get_property timestampOutputs)"
  OUTPUT_PATH="$(get_property outputPath)"
  SUMMARY_OUTPUT_PATH="$(get_property summaryOutputPath)"

  ABS_VOCABULARY_PATH="$(resolve_config_path "$VOCABULARY_PATH")"
  ABS_DATASET_OUTPUT_DIR="$(resolve_config_path "$DATASET_OUTPUT_DIR")"
  BASE_OUTPUT_PATH="$(resolve_config_path "$OUTPUT_PATH")"
  BASE_SUMMARY_PATH="$(resolve_config_path "$SUMMARY_OUTPUT_PATH")"

  validate_config
  prepare_group_paths
}

validate_config() {
  [[ "$SCENARIO" == "search-latency-by-docs" ]] \
    || die "scenario must be search-latency-by-docs"

  validate_seed "$CONFIGURED_SEED" "seed"
  if [[ -n "$SEED_OVERRIDE" ]]; then
    validate_integer "$SEED_OVERRIDE" "--seed"
    EFFECTIVE_SEED="$SEED_OVERRIDE"
  else
    EFFECTIVE_SEED="$(resolve_seed "$CONFIGURED_SEED")"
  fi

  validate_positive_integer "$SEARCH_RESULT_SIZE" "searchResultSize"
  validate_positive_integer "$FILLER_DOCS_PER_KEYWORD" "fillerDocsPerKeyword"
  validate_integer "$WARMUP_PER_BUCKET" "warmupPerBucket"
  [[ "$WARMUP_PER_BUCKET" -ge 0 ]] || die "warmupPerBucket must be non-negative"
  validate_positive_integer "$MEASUREMENTS_PER_BUCKET" "measurementsPerBucket"
  TARGET_KEYWORD_COUNT=$((WARMUP_PER_BUCKET + MEASUREMENTS_PER_BUCKET))
  TARGET_ASSOCIATION_COUNT=$((TARGET_KEYWORD_COUNT * SEARCH_RESULT_SIZE))
  BUCKETS="${SEARCH_RESULT_SIZE}:${SEARCH_RESULT_SIZE}"
  parse_db_sizes

  validate_positive_integer "$REPLICA_COUNT" "sseReplicas"
  [[ "$REPLICA_COUNT" -ge 4 ]] || die "sseReplicas must be at least 4"
  validate_positive_integer "$ORAM_REPLICA_COUNT" "oramReplicas"
  [[ "$ORAM_REPLICA_COUNT" -ge 4 ]] || die "oramReplicas must be at least 4"
  validate_positive_integer "$ORAM_MAX_CONCURRENT_CLIENTS" "oramMaxConcurrentClients"
  validate_positive_integer "$DEPLOY_CLIENT_COUNT" "deployClientCount"
  validate_positive_integer "$POPULATE_CLIENT_ID" "populateClientId"
  validate_positive_integer "$POPULATE_BATCH_SIZE" "populateBatchSize"
  validate_positive_integer "$CLIENT_ID" "clientId"
  validate_boolean "$TIMESTAMP_OUTPUTS" "timestampOutputs"
  validate_client_dir "$POPULATE_CLIENT_DIR" "populateClientDir"
  validate_client_dir "$BENCHMARK_CLIENT_DIR" "benchmarkClientDir"

  POPULATE_CLIENT_INDEX="${POPULATE_CLIENT_DIR#cli}"
  BENCHMARK_CLIENT_INDEX="${BENCHMARK_CLIENT_DIR#cli}"
  client_node "$POPULATE_CLIENT_INDEX" >/dev/null
  client_node "$BENCHMARK_CLIENT_INDEX" >/dev/null

  [[ "$(dirname "$BASE_OUTPUT_PATH")" == "$(dirname "$BASE_SUMMARY_PATH")" ]] \
    || die "outputPath and summaryOutputPath must use the same directory"
  [[ -s "$ABS_VOCABULARY_PATH" ]] \
    || die "Vocabulary file is missing or empty: $ABS_VOCABULARY_PATH"
  [[ -s "$ROOT_DIR/datasets/vocabulary/vocabulary.txt" ]] \
    || die "Deployed vocabulary is missing or empty"
  cmp -s "$ABS_VOCABULARY_PATH" "$ROOT_DIR/datasets/vocabulary/vocabulary.txt" \
    || die "Quinta benchmarks must use the vocabulary deployed from datasets/vocabulary/vocabulary.txt"
}

parse_db_sizes() {
  local db_size previous_db_size=""

  [[ -n "$DB_SIZES" ]] || die "dbSizes cannot be empty"
  IFS=',' read -r -a DB_SIZE_VALUES <<< "$DB_SIZES"
  for db_size in "${DB_SIZE_VALUES[@]}"; do
    validate_positive_integer "$db_size" "dbSizes"
    (( db_size >= TARGET_ASSOCIATION_COUNT )) \
      || die "dbSize $db_size is smaller than the $TARGET_ASSOCIATION_COUNT target associations"
    if [[ -n "$previous_db_size" ]]; then
      (( db_size > previous_db_size )) || die "dbSizes must be strictly increasing"
    fi
    previous_db_size="$db_size"
  done
}

prepare_group_paths() {
  GROUP_DATE="$(date +%d_%m_%Y)"
  if [[ "$TIMESTAMP_OUTPUTS" == "true" ]]; then
    GROUP_NAME="$(date +%H_%M_%S)_quinta_search_db_size_r${REPLICA_COUNT}_o${ORAM_REPLICA_COUNT}"
  else
    GROUP_NAME="latest_quinta_search_db_size_r${REPLICA_COUNT}_o${ORAM_REPLICA_COUNT}"
  fi

  GROUP_RESULTS_DIR="$(dirname "$BASE_OUTPUT_PATH")/$GROUP_DATE/$GROUP_NAME"
  GROUP_LOG_DIR="$ROOT_DIR/benchmarkSSE/results/logs/$GROUP_DATE/$GROUP_NAME"
  ABS_SUMMARY_PATH="$GROUP_RESULTS_DIR/$(basename "$BASE_SUMMARY_PATH")"
  GROUP_LOG_PATH="$GROUP_LOG_DIR/run_search_latency_by_db_size_quinta.log"
  ABS_BENCHMARK_INPUT_PATH="$ABS_DATASET_OUTPUT_DIR/benchmark_queries_docs_${SEARCH_RESULT_SIZE}.ndjson"

  mkdir -p "$GROUP_RESULTS_DIR" "$GROUP_LOG_DIR"
}

start_group_log_capture() {
  [[ "$LOG_CAPTURE_STARTED" -eq 0 ]] || return
  LOG_CAPTURE_STARTED=1
  exec > >(tee -a "$GROUP_LOG_PATH") 2>&1

  echo "Quinta search latency by database size group: $GROUP_NAME"
  echo "Config: $CONFIG_PATH"
  echo "Cluster config: $CLUSTER_CONFIG"
  echo "SSE replicas: $REPLICA_COUNT ($SSE_REPLICA_COUNT_SOURCE)"
  echo "ORAM replicas: $ORAM_REPLICA_COUNT ($ORAM_REPLICA_COUNT_SOURCE)"
  echo "Database sizes: $DB_SIZES"
  echo "Search result size: $SEARCH_RESULT_SIZE"
  echo "Warm-up searches per database: $WARMUP_PER_BUCKET"
  echo "Measured searches per database: $MEASUREMENTS_PER_BUCKET"
  echo "Configured seed: $CONFIGURED_SEED"
  echo "Effective seed: $EFFECTIVE_SEED"
}

generate_datasets() {
  echo "Generating all population and benchmark datasets..."
  python3 "$DATASET_GENERATOR" \
    --output-dir "$ABS_DATASET_OUTPUT_DIR" \
    --vocabulary "$ABS_VOCABULARY_PATH" \
    --db-sizes "$DB_SIZES" \
    --search-result-size "$SEARCH_RESULT_SIZE" \
    --warmup-count "$WARMUP_PER_BUCKET" \
    --measurement-count "$MEASUREMENTS_PER_BUCKET" \
    --filler-doc-count "$FILLER_DOCS_PER_KEYWORD" \
    --seed "$EFFECTIVE_SEED"

  [[ -s "$ABS_BENCHMARK_INPUT_PATH" ]] || die "Generated benchmark input is empty"
  [[ "$(wc -l < "$ABS_BENCHMARK_INPUT_PATH")" -eq "$TARGET_KEYWORD_COUNT" ]] \
    || die "Generated benchmark input line count did not match warm-up + measurement count"

  local db_size population_path
  for db_size in "${DB_SIZE_VALUES[@]}"; do
    population_path="$ABS_DATASET_OUTPUT_DIR/population_db_${db_size}.ndjson"
    [[ -s "$population_path" ]] || die "Generated population dataset is empty: $population_path"
  done
}

prepare_run() {
  DB_SIZE="$1"
  local filler_associations=$((DB_SIZE - TARGET_ASSOCIATION_COUNT))
  EXPECTED_POPULATION_KEYWORDS=$((TARGET_KEYWORD_COUNT + filler_associations / FILLER_DOCS_PER_KEYWORD))
  if (( filler_associations % FILLER_DOCS_PER_KEYWORD != 0 )); then
    EXPECTED_POPULATION_KEYWORDS=$((EXPECTED_POPULATION_KEYWORDS + 1))
  fi

  ABS_POPULATION_PATH="$ABS_DATASET_OUTPUT_DIR/population_db_${DB_SIZE}.ndjson"
  RUN_NAME="${GROUP_NAME}_db${DB_SIZE}"
  RUN_RESULTS_DIR="$GROUP_RESULTS_DIR/db${DB_SIZE}"
  ABS_OUTPUT_PATH="$RUN_RESULTS_DIR/$(basename "$BASE_OUTPUT_PATH")"
  ABS_LOG_DIR="$GROUP_LOG_DIR/db${DB_SIZE}"
  LOCAL_RUNTIME_CONFIG_PATH="$ABS_LOG_DIR/runtime_search_latency_by_db_size.properties"

  mkdir -p "$RUN_RESULTS_DIR" "$ABS_LOG_DIR"
}

validate_population_file() {
  [[ -s "$ABS_POPULATION_PATH" ]] || die "Population dataset is missing or empty: $ABS_POPULATION_PATH"
  [[ "$(wc -l < "$ABS_POPULATION_PATH")" -eq "$EXPECTED_POPULATION_KEYWORDS" ]] \
    || die "Population dataset for DB size $DB_SIZE has an unexpected keyword count"
}

write_local_runtime_config() {
  local remote_benchmark_input_path="$1"
  local remote_output_path="$2"
  local remote_vocabulary_path="$3"
  local wrote_input_path=0
  local wrote_output_path=0
  local wrote_buckets=0

  {
    printf '# Runtime benchmark config generated by %s\n' "$(basename "$0")"
    printf 'runtimeSseReplicas=%s\n' "$REPLICA_COUNT"
    printf 'runtimeOramReplicas=%s\n' "$ORAM_REPLICA_COUNT"
    printf 'runtimeOramMaxConcurrentClients=%s\n' "$ORAM_MAX_CONCURRENT_CLIENTS"
    printf 'runtimeSseReplicasSource=%s\n' "$SSE_REPLICA_COUNT_SOURCE"
    printf 'runtimeOramReplicasSource=%s\n' "$ORAM_REPLICA_COUNT_SOURCE"
    printf 'runtimeConfiguredSeed=%s\n' "$CONFIGURED_SEED"
    printf 'runtimeEffectiveSeed=%s\n' "$EFFECTIVE_SEED"
    printf 'runtimeDbSize=%s\n' "$DB_SIZE"
    printf 'runtimeSearchResultSize=%s\n' "$SEARCH_RESULT_SIZE"
    printf 'runtimeTargetKeywordCount=%s\n' "$TARGET_KEYWORD_COUNT"
    printf 'runtimeTargetAssociationCount=%s\n' "$TARGET_ASSOCIATION_COUNT"
    while IFS= read -r line; do
      case "$line" in
        vocabularyPath=*) printf 'vocabularyPath=%s\n' "$remote_vocabulary_path" ;;
        seed=*) printf 'seed=%s\n' "$EFFECTIVE_SEED" ;;
        sseReplicas=*) printf 'sseReplicas=%s\n' "$REPLICA_COUNT" ;;
        oramReplicas=*) printf 'oramReplicas=%s\n' "$ORAM_REPLICA_COUNT" ;;
        oramMaxConcurrentClients=*) printf 'oramMaxConcurrentClients=%s\n' "$ORAM_MAX_CONCURRENT_CLIENTS" ;;
        inputPath=*)
          printf 'inputPath=%s\n' "$remote_benchmark_input_path"
          wrote_input_path=1
          ;;
        outputPath=*)
          printf 'outputPath=%s\n' "$remote_output_path"
          wrote_output_path=1
          ;;
        buckets=*)
          printf 'buckets=%s\n' "$BUCKETS"
          wrote_buckets=1
          ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$CONFIG_PATH"
    [[ "$wrote_input_path" -eq 1 ]] || printf 'inputPath=%s\n' "$remote_benchmark_input_path"
    [[ "$wrote_output_path" -eq 1 ]] || printf 'outputPath=%s\n' "$remote_output_path"
    [[ "$wrote_buckets" -eq 1 ]] || printf 'buckets=%s\n' "$BUCKETS"
  } > "$LOCAL_RUNTIME_CONFIG_PATH"
}

copy_benchmark_inputs() {
  local populate_host benchmark_host remote_base

  populate_host="$(client_node "$POPULATE_CLIENT_INDEX")"
  benchmark_host="$(client_node "$BENCHMARK_CLIENT_INDEX")"
  remote_base="$(remote_run_dir)/benchmark"

  REMOTE_POPULATION_PATH="$remote_base/input/$(basename "$ABS_POPULATION_PATH")"
  REMOTE_BENCHMARK_INPUT_PATH="$remote_base/input/$(basename "$ABS_BENCHMARK_INPUT_PATH")"
  REMOTE_RUNTIME_CONFIG_PATH="$remote_base/runtime_search_latency_by_db_size.properties"
  REMOTE_OUTPUT_PATH="$remote_base/results/search_latency_by_db_size.csv"
  POPULATE_REMOTE_VOCABULARY_PATH="$(remote_run_dir)/$POPULATE_CLIENT_DIR/datasets/vocabulary/vocabulary.txt"
  BENCHMARK_REMOTE_VOCABULARY_PATH="$(remote_run_dir)/$BENCHMARK_CLIENT_DIR/datasets/vocabulary/vocabulary.txt"

  write_local_runtime_config \
    "$REMOTE_BENCHMARK_INPUT_PATH" \
    "$REMOTE_OUTPUT_PATH" \
    "$BENCHMARK_REMOTE_VOCABULARY_PATH"

  ssh_remote "$populate_host" "mkdir -p '$remote_base/input'"
  scp_remote "$ABS_POPULATION_PATH" "$populate_host:$REMOTE_POPULATION_PATH"

  ssh_remote "$benchmark_host" "mkdir -p '$remote_base/input' '$remote_base/results'"
  scp_remote "$ABS_BENCHMARK_INPUT_PATH" "$benchmark_host:$REMOTE_BENCHMARK_INPUT_PATH"
  scp_remote "$LOCAL_RUNTIME_CONFIG_PATH" "$benchmark_host:$REMOTE_RUNTIME_CONFIG_PATH"
}

run_populate_remote() {
  local host processed_doc_ids processed_keywords remote_command
  host="$(client_node "$POPULATE_CLIENT_INDEX")"
  printf -v remote_command \
    'cd %q && env JAVA_OPTS=%q bash smartrun.sh %q --client-id %q --input %q --batch-size %q --vocabulary %q' \
    "$(remote_run_dir)/$POPULATE_CLIENT_DIR" \
    "$QUINTA_CLIENT_JAVA_OPTS" \
    "sse.populatedb.PopulateDB" \
    "$POPULATE_CLIENT_ID" \
    "$REMOTE_POPULATION_PATH" \
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
  [[ "$processed_keywords" == "$EXPECTED_POPULATION_KEYWORDS" ]] \
    || die "PopulateDB processed $processed_keywords keywords, expected $EXPECTED_POPULATION_KEYWORDS"
  [[ "$processed_doc_ids" == "$DB_SIZE" ]] \
    || die "PopulateDB processed $processed_doc_ids document IDs, expected $DB_SIZE"
  echo "PopulateDB finished and validated successfully."
}

run_benchmark_remote() {
  local host remote_command
  host="$(client_node "$BENCHMARK_CLIENT_INDEX")"
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

start_node_health_monitor() {
  local interval_seconds="${QUINTA_HEALTH_MONITOR_INTERVAL_SECONDS:-30}"
  local health_dir="$ABS_LOG_DIR/node_health"

  [[ -z "$NODE_HEALTH_MONITOR_PID" ]] || return
  mkdir -p "$health_dir"
  echo "Starting Quinta node health monitor (${interval_seconds}s) -> $health_dir"

  (
    set +e
    while true; do
      for node_index in "${!QUINTA_NODES[@]}"; do
        node="${QUINTA_NODES[$node_index]}"
        host="${QUINTA_SSH_PREFIX}${node}"
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
  local benchmark_host
  benchmark_host="$(client_node "$BENCHMARK_CLIENT_INDEX")"
  copy_remote_file_with_retry "$benchmark_host" "$REMOTE_OUTPUT_PATH" "$ABS_OUTPUT_PATH"
}

verify_results() {
  [[ -s "$ABS_OUTPUT_PATH" ]] || die "Benchmark CSV is missing or empty: $ABS_OUTPUT_PATH"
  [[ "$(( $(wc -l < "$ABS_OUTPUT_PATH") - 1 ))" -eq "$MEASUREMENTS_PER_BUCKET" ]] \
    || die "Expected $MEASUREMENTS_PER_BUCKET search measurements for DB size $DB_SIZE"
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

run_one_db_size() {
  local db_size="$1"

  prepare_run "$db_size"
  validate_population_file
  REPLICA_LOGS_FETCHED=0
  BENCHMARK_COMPLETED=0

  echo
  echo "===== Search latency: DB=$DB_SIZE, result size=$SEARCH_RESULT_SIZE ====="
  deploy_arg preclean
  deploy_arg preflight
  deploy_arg deploy
  CURRENT_RUN_ACTIVE=1
  deploy_arg start
  deploy_arg wait
  start_node_health_monitor

  copy_benchmark_inputs
  run_populate_remote
  run_benchmark_remote
  fetch_replica_logs
  verify_replica_logs
  fetch_results
  verify_results

  BENCHMARK_COMPLETED=1
  SEARCH_CSV_PATHS+=("$ABS_OUTPUT_PATH")
  clean_successful_run
  echo "Benchmark CSV: $ABS_OUTPUT_PATH"
}

summarize_results() {
  local expected_rows actual_rows

  [[ "${#SEARCH_CSV_PATHS[@]}" -eq "${#DB_SIZE_VALUES[@]}" ]] \
    || die "Not all configured database sizes produced a CSV"

  echo "Summarizing ${#SEARCH_CSV_PATHS[@]} search latency CSV file(s)..."
  python3 "$SUMMARIZE_SCRIPT" \
    --output "$ABS_SUMMARY_PATH" \
    --search-result-size "$SEARCH_RESULT_SIZE" \
    --measurement-count "$MEASUREMENTS_PER_BUCKET" \
    "${SEARCH_CSV_PATHS[@]}"

  [[ -s "$ABS_SUMMARY_PATH" ]] || die "Summary TSV is missing or empty: $ABS_SUMMARY_PATH"
  expected_rows=$((${#DB_SIZE_VALUES[@]} * N_METRICS))
  actual_rows=$(( $(wc -l < "$ABS_SUMMARY_PATH") - 1 ))
  (( actual_rows == expected_rows )) \
    || die "Expected $expected_rows summary rows, found $actual_rows"
}

main() {
  parse_args "$@"
  ensure_command_exists python3
  load_config
  trap cleanup EXIT INT TERM

  SEARCH_CSV_PATHS=()
  start_group_log_capture
  generate_datasets

  local db_size
  for db_size in "${DB_SIZE_VALUES[@]}"; do
    run_one_db_size "$db_size"
  done

  summarize_results
  echo "Summary TSV: $ABS_SUMMARY_PATH"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
