#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEFAULT_CONFIG="$ROOT_DIR/benchmarkSSE/config/search/search_latency_by_docs.properties"
DEFAULT_CLUSTER_CONFIG="$ROOT_DIR/benchmarkSSE/config/quinta.env"
DEPLOY_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/quinta_deploy.sh"
COMMON_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/common/quinta_benchmark_common.sh"
# Matches METRICS in summarize_search_latency.py.
N_METRICS=8

CONFIG_PATH="$DEFAULT_CONFIG"
CLUSTER_CONFIG="$DEFAULT_CLUSTER_CONFIG"
SSE_REPLICA_COUNT_OVERRIDE=""
ORAM_REPLICA_COUNT_OVERRIDE=""
REPLICA_COUNT_SOURCE="config"
CLEANUP_DONE=0
SERVERS_MAY_BE_RUNNING=0
REPLICA_LOGS_FETCHED=0
BENCHMARK_COMPLETED=0

# shellcheck source=../common/quinta_benchmark_common.sh
source "$COMMON_SCRIPT"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--config PATH] [--cluster-config PATH] [--sseReplicas N] [--oramReplicas N]
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

doc_counts_to_buckets() {
  local raw_doc_counts="$1"
  local compact_doc_counts doc_count buckets=""

  compact_doc_counts="$(normalize_csv_list "$raw_doc_counts")"
  [[ -n "$compact_doc_counts" ]] || die "syntheticDocCounts cannot be empty"

  IFS=',' read -r -a DOC_COUNT_BUCKET_VALUES <<< "$compact_doc_counts"
  for doc_count in "${DOC_COUNT_BUCKET_VALUES[@]}"; do
    validate_positive_integer "$doc_count" "syntheticDocCounts"
    [[ -z "$buckets" ]] || buckets+=","
    buckets+="${doc_count}:${doc_count}"
  done

  printf '%s\n' "$buckets"
}

load_config() {
  [[ -f "$CONFIG_PATH" ]] || die "Config file not found: $CONFIG_PATH"
  [[ -f "$CLUSTER_CONFIG" ]] || die "Cluster config not found: $CLUSTER_CONFIG"
  [[ -x "$DEPLOY_SCRIPT" ]] || die "Deploy script is not executable: $DEPLOY_SCRIPT"
  # shellcheck source=/dev/null
  source "$CLUSTER_CONFIG"

  DATASET_TYPE="$(get_property datasetType)"
  REPLICA_COUNT="$(get_property sseReplicas)"
  if [[ -n "$SSE_REPLICA_COUNT_OVERRIDE" ]]; then
    REPLICA_COUNT="$SSE_REPLICA_COUNT_OVERRIDE"
    REPLICA_COUNT_SOURCE="CLI override"
  fi
  ORAM_REPLICA_COUNT="$(get_property oramReplicas)"
  if [[ -n "$ORAM_REPLICA_COUNT_OVERRIDE" ]]; then
    ORAM_REPLICA_COUNT="$ORAM_REPLICA_COUNT_OVERRIDE"
  fi
  if [[ "$ORAM_REPLICA_COUNT" == "-1" ]]; then
    ORAM_REPLICA_COUNT="$REPLICA_COUNT"
  fi
  ORAM_MAX_CONCURRENT_CLIENTS="$(get_property oramMaxConcurrentClients)"
  DEPLOY_CLIENT_COUNT="$(get_property deployClientCount)"
  POPULATE_CLIENT_DIR="$(get_property populateClientDir)"
  POPULATE_CLIENT_ID="$(get_property populateClientId)"
  POPULATE_BATCH_SIZE="$(get_property populateBatchSize)"
  BENCHMARK_CLIENT_DIR="$(get_property benchmarkClientDir)"
  SCENARIO="$(get_property scenario)"
  CLIENT_ID="$(get_property clientId)"
  VOCABULARY_PATH="$(get_property vocabularyPath)"
  WARMUP_PER_BUCKET="$(get_property warmupPerBucket)"
  MEASUREMENTS_PER_BUCKET="$(get_property measurementsPerBucket)"
  TIMESTAMP_OUTPUTS="$(get_property timestampOutputs)"
  INPUT_PATH="$(get_property inputPath)"
  OUTPUT_PATH="$(get_property outputPath)"
  SUMMARY_OUTPUT_PATH="$(get_property summaryOutputPath)"
  MEAN_PLOT_OUTPUT_PATH="$(get_property meanPlotOutputPath)"
  MEDIAN_PLOT_OUTPUT_PATH="$(get_property medianPlotOutputPath)"
  BUCKETS=""

  validate_positive_integer "$REPLICA_COUNT" "sseReplicas"
  [[ "$REPLICA_COUNT" -ge 4 ]] || die "sseReplicas must be at least 4"
  validate_positive_integer "$ORAM_REPLICA_COUNT" "oramReplicas"
  [[ "$ORAM_REPLICA_COUNT" -ge 4 ]] || die "oramReplicas must be at least 4"
  validate_positive_integer "$ORAM_MAX_CONCURRENT_CLIENTS" "oramMaxConcurrentClients"
  validate_positive_integer "$DEPLOY_CLIENT_COUNT" "deployClientCount"
  validate_positive_integer "$POPULATE_CLIENT_ID" "populateClientId"
  validate_positive_integer "$POPULATE_BATCH_SIZE" "populateBatchSize"
  validate_positive_integer "$CLIENT_ID" "clientId"
  validate_positive_integer "$MEASUREMENTS_PER_BUCKET" "measurementsPerBucket"
  validate_integer "$WARMUP_PER_BUCKET" "warmupPerBucket"
  [[ "$WARMUP_PER_BUCKET" -ge 0 ]] || die "warmupPerBucket must be non-negative"
  validate_boolean "$TIMESTAMP_OUTPUTS" "timestampOutputs"

  POPULATE_CLIENT_INDEX="${POPULATE_CLIENT_DIR#cli}"
  BENCHMARK_CLIENT_INDEX="${BENCHMARK_CLIENT_DIR#cli}"
  [[ "$POPULATE_CLIENT_DIR" =~ ^cli[0-9]+$ ]] || die "populateClientDir must use cliN"
  [[ "$BENCHMARK_CLIENT_DIR" =~ ^cli[0-9]+$ ]] || die "benchmarkClientDir must use cliN"
  (( POPULATE_CLIENT_INDEX < DEPLOY_CLIENT_COUNT )) || die "populateClientDir requires deployClientCount > $POPULATE_CLIENT_INDEX"
  (( BENCHMARK_CLIENT_INDEX < DEPLOY_CLIENT_COUNT )) || die "benchmarkClientDir requires deployClientCount > $BENCHMARK_CLIENT_INDEX"

  EXPECTED_SAMPLES_PER_BUCKET=$((WARMUP_PER_BUCKET + MEASUREMENTS_PER_BUCKET))
  ABS_DATASET_PATH="$(resolve_config_path "$INPUT_PATH")"
  ABS_VOCABULARY_PATH="$(resolve_config_path "$VOCABULARY_PATH")"
  BASE_OUTPUT_PATH="$(resolve_config_path "$OUTPUT_PATH")"
  BASE_SUMMARY_PATH="$(resolve_config_path "$SUMMARY_OUTPUT_PATH")"
  BASE_MEAN_PLOT_PATH="$(resolve_config_path "$MEAN_PLOT_OUTPUT_PATH")"
  BASE_MEDIAN_PLOT_PATH="$(resolve_config_path "$MEDIAN_PLOT_OUTPUT_PATH")"
  [[ -s "$ABS_VOCABULARY_PATH" ]] || die "Vocabulary file is missing or empty: $ABS_VOCABULARY_PATH"
  [[ -s "$ROOT_DIR/datasets/vocabulary/vocabulary.txt" ]] || die "Deployed vocabulary is missing or empty"
  cmp -s "$ABS_VOCABULARY_PATH" "$ROOT_DIR/datasets/vocabulary/vocabulary.txt" \
    || die "Quinta benchmarks must use the vocabulary deployed from datasets/vocabulary/vocabulary.txt"

  if [[ "$TIMESTAMP_OUTPUTS" == "true" ]]; then
    RUN_DATE="$(date +%d_%m_%Y)"
    RUN_NAME="$(date +%H_%M_%S)_quinta_r${REPLICA_COUNT}_o${ORAM_REPLICA_COUNT}"
  else
    RUN_DATE="$(date +%d_%m_%Y)"
    RUN_NAME="latest_quinta_r${REPLICA_COUNT}_o${ORAM_REPLICA_COUNT}"
  fi

  ABS_OUTPUT_PATH="$(place_path_in_run_dir "$BASE_OUTPUT_PATH" "$RUN_DATE/$RUN_NAME")"
  ABS_SUMMARY_PATH="$(place_path_in_run_dir "$BASE_SUMMARY_PATH" "$RUN_DATE/$RUN_NAME")"
  ABS_MEAN_PLOT_PATH="$(place_path_in_run_dir "$BASE_MEAN_PLOT_PATH" "$RUN_DATE/$RUN_NAME")"
  ABS_MEDIAN_PLOT_PATH="$(place_path_in_run_dir "$BASE_MEDIAN_PLOT_PATH" "$RUN_DATE/$RUN_NAME")"
  ABS_LOG_DIR="$ROOT_DIR/benchmarkSSE/results/logs/$RUN_DATE/$RUN_NAME"
  LOCAL_RUNTIME_CONFIG_PATH="$ABS_LOG_DIR/runtime_search_latency_by_docs_quinta.properties"

  validate_dataset_config
}

validate_dataset_config() {
  case "$DATASET_TYPE" in
    enron)
      PROCESSOR_MODE="$(get_property processorMode)"
      PROCESSOR_OUTPUT_PATH="$(get_property processorOutputPath)"
      PROCESSOR_BUCKETS="$(get_property processorBuckets)"
      PROCESSOR_SAMPLES_PER_BUCKET="$(get_property processorSamplesPerBucket)"
      BUCKETS="$PROCESSOR_BUCKETS"
      validate_positive_integer "$PROCESSOR_SAMPLES_PER_BUCKET" "processorSamplesPerBucket"
      [[ "$PROCESSOR_SAMPLES_PER_BUCKET" -eq "$EXPECTED_SAMPLES_PER_BUCKET" ]] || die "processorSamplesPerBucket must equal warmupPerBucket + measurementsPerBucket"
      ABS_PROCESSOR_OUTPUT_PATH="$(resolve_config_path "$PROCESSOR_OUTPUT_PATH")"
      EXPECTED_DATASET_LINES=$((PROCESSOR_SAMPLES_PER_BUCKET * $(csv_item_count "$PROCESSOR_BUCKETS")))
      ;;
    synthetic)
      SYNTHETIC_OUTPUT_PATH="$(get_property syntheticOutputPath)"
      SYNTHETIC_KEYWORDS_PER_DOC_COUNT="$(get_property syntheticKeywordsPerDocCount)"
      SYNTHETIC_DOC_COUNTS="$(get_property syntheticDocCounts)"
      SYNTHETIC_SEED="$(get_property syntheticSeed)"
      BUCKETS="$(doc_counts_to_buckets "$SYNTHETIC_DOC_COUNTS")"
      validate_positive_integer "$SYNTHETIC_KEYWORDS_PER_DOC_COUNT" "syntheticKeywordsPerDocCount"
      validate_integer "$SYNTHETIC_SEED" "syntheticSeed"
      [[ "$SYNTHETIC_KEYWORDS_PER_DOC_COUNT" -eq "$EXPECTED_SAMPLES_PER_BUCKET" ]] || die "syntheticKeywordsPerDocCount must equal warmupPerBucket + measurementsPerBucket"
      ABS_SYNTHETIC_OUTPUT_PATH="$(resolve_config_path "$SYNTHETIC_OUTPUT_PATH")"
      EXPECTED_DATASET_LINES=$((SYNTHETIC_KEYWORDS_PER_DOC_COUNT * $(csv_item_count "$SYNTHETIC_DOC_COUNTS")))
      ;;
    *)
      die "datasetType must be either enron or synthetic"
      ;;
  esac
}

prepare_directories() {
  mkdir -p "$ABS_LOG_DIR" "$(dirname "$ABS_OUTPUT_PATH")" "$(dirname "$ABS_SUMMARY_PATH")" "$(dirname "$ABS_MEAN_PLOT_PATH")" "$(dirname "$ABS_MEDIAN_PLOT_PATH")"
}

validate_existing_dataset() {
  [[ -s "$ABS_DATASET_PATH" ]] || return 1
  [[ "$(wc -l < "$ABS_DATASET_PATH")" -eq "$EXPECTED_DATASET_LINES" ]]
}

generate_dataset() {
  if validate_existing_dataset; then
    echo "Reusing dataset: $ABS_DATASET_PATH"
    return
  fi

  case "$DATASET_TYPE" in
    enron)
      echo "Generating Enron dataset..."
      (
        cd "$ROOT_DIR"
        ./gradlew processEnronDataset \
          -Pmode="$PROCESSOR_MODE" \
          -Poutput="$ABS_PROCESSOR_OUTPUT_PATH" \
          -PbucketSpec="$PROCESSOR_BUCKETS" \
          -PsamplesPerBucket="$PROCESSOR_SAMPLES_PER_BUCKET"
      )
      ;;
    synthetic)
      echo "Generating synthetic dataset..."
      python3 "$ROOT_DIR/benchmarkSSE/scripts/datasets/syntheticDataset.py" \
        --output "$ABS_SYNTHETIC_OUTPUT_PATH" \
        --vocabulary "$ABS_VOCABULARY_PATH" \
        --keywords-per-doc-count "$SYNTHETIC_KEYWORDS_PER_DOC_COUNT" \
        --doc-counts "$SYNTHETIC_DOC_COUNTS" \
        --seed "$SYNTHETIC_SEED"
      ;;
  esac

  validate_existing_dataset || die "Generated dataset line count did not match config"
}

write_local_runtime_config() {
  local remote_dataset_path="$1"
  local remote_output_path="$2"
  local remote_vocabulary_path="$3"
  local wrote_buckets=0

  {
    printf '# Runtime benchmark config generated by %s\n' "$(basename "$0")"
    printf 'runtimeSseReplicas=%s\n' "$REPLICA_COUNT"
    printf 'runtimeOramReplicas=%s\n' "$ORAM_REPLICA_COUNT"
    printf 'runtimeOramMaxConcurrentClients=%s\n' "$ORAM_MAX_CONCURRENT_CLIENTS"
    printf 'runtimeSseReplicasSource=%s\n' "$REPLICA_COUNT_SOURCE"
    while IFS= read -r line; do
      case "$line" in
        inputPath=*) printf 'inputPath=%s\n' "$remote_dataset_path" ;;
        outputPath=*) printf 'outputPath=%s\n' "$remote_output_path" ;;
        vocabularyPath=*) printf 'vocabularyPath=%s\n' "$remote_vocabulary_path" ;;
        sseReplicas=*) printf 'sseReplicas=%s\n' "$REPLICA_COUNT" ;;
        oramReplicas=*) printf 'oramReplicas=%s\n' "$ORAM_REPLICA_COUNT" ;;
        oramMaxConcurrentClients=*) printf 'oramMaxConcurrentClients=%s\n' "$ORAM_MAX_CONCURRENT_CLIENTS" ;;
        buckets=*)
          printf 'buckets=%s\n' "$BUCKETS"
          wrote_buckets=1
          ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$CONFIG_PATH"
    if [[ "$wrote_buckets" -eq 0 ]]; then
      printf 'buckets=%s\n' "$BUCKETS"
    fi
  } > "$LOCAL_RUNTIME_CONFIG_PATH"
}

copy_benchmark_inputs() {
  local populate_host benchmark_host remote_base

  populate_host="$(client_node "$POPULATE_CLIENT_INDEX")"
  benchmark_host="$(client_node "$BENCHMARK_CLIENT_INDEX")"
  remote_base="$(remote_run_dir)/benchmark"
  REMOTE_DATASET_PATH="$remote_base/input/$(basename "$ABS_DATASET_PATH")"
  POPULATE_REMOTE_VOCABULARY_PATH="$(remote_run_dir)/$POPULATE_CLIENT_DIR/datasets/vocabulary/vocabulary.txt"
  BENCHMARK_REMOTE_VOCABULARY_PATH="$(remote_run_dir)/$BENCHMARK_CLIENT_DIR/datasets/vocabulary/vocabulary.txt"
  REMOTE_RUNTIME_CONFIG_PATH="$remote_base/runtime_search_latency_by_docs.properties"
  REMOTE_OUTPUT_PATH="$remote_base/results/search_latency_by_docs.csv"

  write_local_runtime_config "$REMOTE_DATASET_PATH" "$REMOTE_OUTPUT_PATH" "$BENCHMARK_REMOTE_VOCABULARY_PATH"

  for host in "$populate_host" "$benchmark_host"; do
    ssh_remote "$host" "mkdir -p '$remote_base/input' '$remote_base/results' '$remote_base/logs'"
    scp_remote "$ABS_DATASET_PATH" "$host:$REMOTE_DATASET_PATH"
  done
  scp_remote "$LOCAL_RUNTIME_CONFIG_PATH" "$benchmark_host:$REMOTE_RUNTIME_CONFIG_PATH"
}

run_populate_remote() {
  local host
  host="$(client_node "$POPULATE_CLIENT_INDEX")"
  echo "Running PopulateDB on $host..."
  ssh_remote "$host" "cd '$(remote_run_dir)/$POPULATE_CLIENT_DIR' && env JAVA_OPTS='$QUINTA_CLIENT_JAVA_OPTS' bash smartrun.sh sse.populatedb.PopulateDB --client-id '$POPULATE_CLIENT_ID' --input '$REMOTE_DATASET_PATH' --batch-size '$POPULATE_BATCH_SIZE' --vocabulary '$POPULATE_REMOTE_VOCABULARY_PATH'" \
    > "$ABS_LOG_DIR/populate.log" 2>&1
  grep -q "PopulateDB finished." "$ABS_LOG_DIR/populate.log" || {
    tail -n 40 "$ABS_LOG_DIR/populate.log" >&2 || true
    die "PopulateDB did not finish successfully"
  }
}

run_benchmark_remote() {
  local host
  host="$(client_node "$BENCHMARK_CLIENT_INDEX")"
  echo "Running BenchmarkClient on $host..."
  ssh_remote "$host" "cd '$(remote_run_dir)/$BENCHMARK_CLIENT_DIR' && env JAVA_OPTS='$QUINTA_CLIENT_JAVA_OPTS' bash smartrun.sh sse.benchmark.BenchmarkClient '$REMOTE_RUNTIME_CONFIG_PATH'" \
    > "$ABS_LOG_DIR/benchmark.log" 2>&1
}

fetch_replica_logs() {
  local node replica_id remote_log
  local copy_failed=0

  [[ "$REPLICA_LOGS_FETCHED" -eq 0 ]] || return

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

  if [[ "$copy_failed" -ne 0 ]]; then
    echo "Warning: one or more replica logs could not be downloaded." >&2
    return 1
  fi

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
  scp_remote "$benchmark_host:$REMOTE_OUTPUT_PATH" "$ABS_OUTPUT_PATH"
}

verify_results() {
  local bucket_count expected_rows actual_rows

  [[ -s "$ABS_OUTPUT_PATH" ]] || die "Benchmark CSV not found or empty: $ABS_OUTPUT_PATH"
  bucket_count="$(csv_item_count "$BUCKETS")"
  expected_rows=$((bucket_count * MEASUREMENTS_PER_BUCKET))
  actual_rows=$(( $(wc -l < "$ABS_OUTPUT_PATH") - 1 ))
  (( actual_rows == expected_rows )) || die "Expected $expected_rows search measurements, found $actual_rows in $ABS_OUTPUT_PATH"
}

summarize_and_plot() {
  python3 "$ROOT_DIR/benchmarkSSE/scripts/search/summarize_search_latency.py" --input "$ABS_OUTPUT_PATH" --output "$ABS_SUMMARY_PATH"
  gnuplot -e "input_path='$ABS_SUMMARY_PATH'; mean_output_path='$ABS_MEAN_PLOT_PATH'; median_output_path='$ABS_MEDIAN_PLOT_PATH'" \
    "$ROOT_DIR/benchmarkSSE/gnuplot/search/search_latency_by_docs_mean_median.gp"
}

verify_summary_and_plots() {
  local bucket_count expected_rows actual_rows

  [[ -s "$ABS_SUMMARY_PATH" ]] || die "Summary TSV not found or empty: $ABS_SUMMARY_PATH"
  bucket_count="$(csv_item_count "$BUCKETS")"
  expected_rows=$((bucket_count * N_METRICS))
  actual_rows=$(( $(wc -l < "$ABS_SUMMARY_PATH") - 1 ))
  (( actual_rows == expected_rows )) || die "Expected $expected_rows metric summary rows, found $actual_rows in $ABS_SUMMARY_PATH"

  [[ -s "$ABS_MEAN_PLOT_PATH" ]] || die "Mean plot not found or empty: $ABS_MEAN_PLOT_PATH"
  [[ -s "$ABS_MEDIAN_PLOT_PATH" ]] || die "Median plot not found or empty: $ABS_MEDIAN_PLOT_PATH"
}

cleanup() {
  local exit_status=$?
  trap - EXIT INT TERM
  if [[ "$CLEANUP_DONE" -eq 0 && "$SERVERS_MAY_BE_RUNNING" -eq 1 ]]; then
    CLEANUP_DONE=1
    fetch_replica_logs || true

    if [[ "$BENCHMARK_COMPLETED" -eq 1 ]]; then
      echo "Cleaning successful remote benchmark run..."
      if deploy_arg clean; then
        SERVERS_MAY_BE_RUNNING=0
      else
        echo "Warning: failed to clean the successful remote benchmark run." >&2
        [[ "$exit_status" -ne 0 ]] || exit_status=1
      fi
    else
      if ! deploy_arg stop; then
        echo "Warning: Quinta replicas may still be running." >&2
      fi
      echo "Remote run directory preserved for debugging: $(remote_run_dir)" >&2
    fi
  fi
  exit "$exit_status"
}

main() {
  parse_args "$@"
  load_config
  trap cleanup EXIT INT TERM

  prepare_directories
  generate_dataset
  deploy_arg preflight
  deploy_arg deploy
  SERVERS_MAY_BE_RUNNING=1
  deploy_arg start
  deploy_arg wait
  copy_benchmark_inputs
  run_populate_remote
  run_benchmark_remote
  fetch_replica_logs
  verify_replica_logs
  fetch_results
  verify_results
  summarize_and_plot
  verify_summary_and_plots
  BENCHMARK_COMPLETED=1

  echo "Benchmark CSV: $ABS_OUTPUT_PATH"
  echo "Summary TSV: $ABS_SUMMARY_PATH"
  echo "Mean plot: $ABS_MEAN_PLOT_PATH"
  echo "Median plot: $ABS_MEDIAN_PLOT_PATH"
}

main "$@"
