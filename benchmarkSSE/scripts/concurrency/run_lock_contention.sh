#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEFAULT_CONFIG="$ROOT_DIR/benchmarkSSE/config/concurrency/lock_contention.properties"
DEFAULT_CLUSTER_CONFIG="$ROOT_DIR/benchmarkSSE/config/quinta.env"
SINGLE_RUNNER="$ROOT_DIR/benchmarkSSE/scripts/concurrency/run_quinta.sh"
SUMMARIZER="$ROOT_DIR/benchmarkSSE/scripts/concurrency/summarize.py"
COMMON_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/common/quinta_benchmark_common.sh"

CONFIG_PATH="$DEFAULT_CONFIG"
CLUSTER_CONFIG="$DEFAULT_CLUSTER_CONFIG"
CURRENT_MARKER_PATH=""
TEMP_DIR=""

# shellcheck source=../common/quinta_benchmark_common.sh
source "$COMMON_SCRIPT"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--config PATH] [--cluster-config PATH]
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

  [[ "$CONFIG_PATH" = /* ]] || CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH"
  [[ "$CLUSTER_CONFIG" = /* ]] || CLUSTER_CONFIG="$ROOT_DIR/$CLUSTER_CONFIG"
  CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
}

validate_unique_values() {
  local label="$1"
  shift
  local current previous
  local index previous_index
  local values=("$@")

  for (( index = 0; index < ${#values[@]}; index++ )); do
    current="${values[$index]}"
    for (( previous_index = 0; previous_index < index; previous_index++ )); do
      previous="${values[$previous_index]}"
      [[ "$current" != "$previous" ]] || die "$label contains duplicate value: $current"
    done
  done
}

parse_client_counts() {
  local value
  local compact

  compact="$(normalize_csv_list "$CLIENT_COUNT_LIST")"
  [[ -n "$compact" ]] || die "clientCounts cannot be empty"
  IFS=',' read -r -a CLIENT_COUNTS <<< "$compact"
  validate_unique_values "clientCounts" "${CLIENT_COUNTS[@]}"

  MAX_CLIENT_COUNT=0
  for value in "${CLIENT_COUNTS[@]}"; do
    validate_positive_integer "$value" "clientCounts value"
    if (( value > MAX_CLIENT_COUNT )); then
      MAX_CLIENT_COUNT="$value"
    fi
  done
}

parse_contention_levels() {
  local value
  local compact

  compact="$(normalize_csv_list "$CONTENTION_LEVEL_LIST")"
  [[ -n "$compact" ]] || die "contentionLevels cannot be empty"
  IFS=',' read -r -a CONTENTION_LEVELS <<< "$compact"
  validate_unique_values "contentionLevels" "${CONTENTION_LEVELS[@]}"

  for value in "${CONTENTION_LEVELS[@]}"; do
    case "$value" in
      none|moderate|high) ;;
      *) die "contentionLevels values must be none, moderate or high" ;;
    esac
  done
}

shared_keyword_count_for() {
  local contention_level="$1"

  case "$contention_level" in
    none) printf '0\n' ;;
    moderate) printf '%s\n' "$MODERATE_SHARED_KEYWORD_COUNT" ;;
    high) printf '1\n' ;;
    *) die "Unsupported contention level: $contention_level" ;;
  esac
}

load_config() {
  ensure_file_exists "$CONFIG_PATH"
  ensure_file_exists "$CLUSTER_CONFIG"
  ensure_executable_exists "$SINGLE_RUNNER"
  ensure_executable_exists "$SUMMARIZER"

  VOCABULARY_PATH="$(get_property vocabularyPath)"
  SYNTHETIC_KEYWORD_COUNT="$(get_property syntheticKeywordCount)"
  SYNTHETIC_DOCUMENTS_PER_KEYWORD="$(get_property syntheticDocumentsPerKeyword)"
  CONFIGURED_SEED="$(get_property seed)"

  CLIENT_COUNT_LIST="$(get_property clientCounts)"
  CONTENTION_LEVEL_LIST="$(get_property contentionLevels)"
  MODERATE_SHARED_KEYWORD_COUNT="$(get_property moderateSharedKeywordCount)"
  REPETITIONS="$(get_property repetitions)"

  REPLICA_COUNT="$(get_property replicaCount)"
  POPULATE_CLIENT_ID="$(get_property populateClientId)"
  POPULATE_CLIENT_COUNT="$(get_property populateClientCount)"
  POPULATE_BATCH_SIZE="$(get_property populateBatchSize)"
  CLIENT_ID="$(get_property clientId)"
  WARMUP_SECONDS="$(get_property warmupSeconds)"
  MEASUREMENT_SECONDS="$(get_property measurementSeconds)"
  WARMUP_KEYWORD_COUNT="$(get_property warmupKeywordCount)"

  ABS_VOCABULARY_PATH="$(resolve_config_path "$VOCABULARY_PATH")"

  validate_config
}

validate_config() {
  validate_positive_integer "$SYNTHETIC_KEYWORD_COUNT" "syntheticKeywordCount"
  validate_positive_integer "$SYNTHETIC_DOCUMENTS_PER_KEYWORD" "syntheticDocumentsPerKeyword"
  validate_seed "$CONFIGURED_SEED" "seed"
  EFFECTIVE_SEED="$(resolve_seed "$CONFIGURED_SEED")"

  validate_positive_integer "$REPETITIONS" "repetitions"
  validate_positive_integer "$REPLICA_COUNT" "replicaCount"
  (( REPLICA_COUNT >= 4 )) || die "replicaCount must be at least 4"
  (( (REPLICA_COUNT - 1) % 3 == 0 )) \
    || die "replicaCount must follow 3f+1"
  validate_positive_integer "$POPULATE_CLIENT_ID" "populateClientId"
  validate_positive_integer "$POPULATE_CLIENT_COUNT" "populateClientCount"
  validate_positive_integer "$POPULATE_BATCH_SIZE" "populateBatchSize"
  validate_positive_integer "$CLIENT_ID" "clientId"
  validate_positive_integer "$WARMUP_SECONDS" "warmupSeconds"
  validate_positive_integer "$MEASUREMENT_SECONDS" "measurementSeconds"
  validate_positive_integer "$WARMUP_KEYWORD_COUNT" "warmupKeywordCount"
  validate_positive_integer \
    "$MODERATE_SHARED_KEYWORD_COUNT" "moderateSharedKeywordCount"

  (( SYNTHETIC_KEYWORD_COUNT > WARMUP_KEYWORD_COUNT )) \
    || die "syntheticKeywordCount must be greater than warmupKeywordCount"

  [[ -s "$ABS_VOCABULARY_PATH" ]] \
    || die "Vocabulary file is missing or empty: $ABS_VOCABULARY_PATH"

  parse_client_counts
  parse_contention_levels

  REQUIRED_CONTENTION_KEYWORD_COUNT=1
  local contention_level
  for contention_level in "${CONTENTION_LEVELS[@]}"; do
    case "$contention_level" in
      none)
        if (( MAX_CLIENT_COUNT > REQUIRED_CONTENTION_KEYWORD_COUNT )); then
          REQUIRED_CONTENTION_KEYWORD_COUNT="$MAX_CLIENT_COUNT"
        fi
        ;;
      moderate)
        if (( MODERATE_SHARED_KEYWORD_COUNT > REQUIRED_CONTENTION_KEYWORD_COUNT )); then
          REQUIRED_CONTENTION_KEYWORD_COUNT="$MODERATE_SHARED_KEYWORD_COUNT"
        fi
        ;;
    esac
  done
  (( WARMUP_KEYWORD_COUNT >= REQUIRED_CONTENTION_KEYWORD_COUNT )) \
    || die "warmupKeywordCount must be at least $REQUIRED_CONTENTION_KEYWORD_COUNT for the configured contention matrix"
  MEASUREMENT_KEYWORD_COUNT=$((SYNTHETIC_KEYWORD_COUNT - WARMUP_KEYWORD_COUNT))
  (( MEASUREMENT_KEYWORD_COUNT >= REQUIRED_CONTENTION_KEYWORD_COUNT )) \
    || die "measurement keyword pool must contain at least $REQUIRED_CONTENTION_KEYWORD_COUNT keywords"

  HIGHEST_POPULATE_CLIENT_ID=$((POPULATE_CLIENT_ID + POPULATE_CLIENT_COUNT - 1))
  (( HIGHEST_POPULATE_CLIENT_ID <= 2147482647 )) \
    || die "Population client IDs exceed the supported ORAM client ID range"

  HIGHEST_CLIENT_ID=$((CLIENT_ID + MAX_CLIENT_COUNT - 1))
  (( HIGHEST_CLIENT_ID <= 2147482647 )) \
    || die "Configured client IDs exceed the supported ORAM client ID range"
  if (( POPULATE_CLIENT_ID <= HIGHEST_CLIENT_ID \
      && CLIENT_ID <= HIGHEST_POPULATE_CLIENT_ID )); then
    die "Population and benchmark client ID ranges overlap"
  fi

  # shellcheck source=/dev/null
  source "$CLUSTER_CONFIG"
  local max_replica_count
  max_replica_count=$((${#QUINTA_NODES[@]} - 1))
  (( REPLICA_COUNT <= max_replica_count )) \
    || die "replicaCount cannot exceed $max_replica_count: one Quinta node must remain reserved for clients"
  ORAM_REPLICA_COUNT="$REPLICA_COUNT"
  client_node >/dev/null

  TOTAL_RUNS=$((
    ${#CLIENT_COUNTS[@]}
    * ${#CONTENTION_LEVELS[@]}
    * REPETITIONS
  ))
}

prepare_outputs() {
  SWEEP_DATE="$(date +%d_%m_%Y)"
  SWEEP_NAME="$(date +%H_%M_%S)_quinta_lock_contention"
  SWEEP_RESULTS_DIR="$ROOT_DIR/benchmarkSSE/results/data/$SWEEP_DATE/$SWEEP_NAME"
  SWEEP_RAW_DIR="$SWEEP_RESULTS_DIR/raw"
  SWEEP_SUMMARY_DIR="$SWEEP_RESULTS_DIR/summaries"
  SWEEP_LOG_DIR="$ROOT_DIR/benchmarkSSE/results/logs/$SWEEP_DATE/$SWEEP_NAME"
  SWEEP_RUN_LOG_DIR="$SWEEP_LOG_DIR/runs"
  SWEEP_LOG_PATH="$SWEEP_LOG_DIR/run_lock_contention_quinta.log"
  MANIFEST_PATH="$SWEEP_RESULTS_DIR/runs.tsv"

  mkdir -p "$SWEEP_RAW_DIR" "$SWEEP_SUMMARY_DIR" "$SWEEP_RUN_LOG_DIR"

  TEMP_DIR="$(mktemp -d /tmp/bft-sse-lock-contention.XXXXXX)"
  RESOLVED_CONFIG_PATH="$TEMP_DIR/resolved.properties"
  TEMP_DATASET_PATH="$TEMP_DIR/synthetic_dataset.ndjson"
}

write_manifest_header() {
  printf '%s\n' \
    $'run_id\trepetition\tsample_csv\tmeasurement_seconds\tsse_replicas\toram_replicas\tclient_count\tsynthetic_keyword_count\tsynthetic_documents_per_keyword\tdataset_seed\tworkload_seed\tcontention_level\tshared_keyword_count' \
    > "$MANIFEST_PATH"
}

workload_seed_for_repetition() {
  local repetition="$1"
  printf '%s\n' "$((EFFECTIVE_SEED + (repetition - 1) * MAX_CLIENT_COUNT))"
}

write_resolved_config() {
  local client_count="$1"
  local contention_level="$2"
  local workload_seed="$3"

  {
    printf 'vocabularyPath=%s\n' "$ABS_VOCABULARY_PATH"
    printf 'syntheticOutputPath=%s\n' "$TEMP_DATASET_PATH"
    printf 'syntheticKeywordCount=%s\n' "$SYNTHETIC_KEYWORD_COUNT"
    printf 'syntheticDocumentsPerKeyword=%s\n' "$SYNTHETIC_DOCUMENTS_PER_KEYWORD"
    printf 'datasetSeed=%s\n' "$EFFECTIVE_SEED"
    printf 'workloadSeed=%s\n' "$workload_seed"
    printf 'sseReplicas=%s\n' "$REPLICA_COUNT"
    printf 'oramReplicas=-1\n'
    printf 'populateClientId=%s\n' "$POPULATE_CLIENT_ID"
    printf 'populateClientCount=%s\n' "$POPULATE_CLIENT_COUNT"
    printf 'populateBatchSize=%s\n' "$POPULATE_BATCH_SIZE"
    printf 'clientId=%s\n' "$CLIENT_ID"
    printf 'clientCount=%s\n' "$client_count"
    printf 'scenario=lock-contention\n'
    printf 'warmupSeconds=%s\n' "$WARMUP_SECONDS"
    printf 'measurementSeconds=%s\n' "$MEASUREMENT_SECONDS"
    printf 'warmupKeywordCount=%s\n' "$WARMUP_KEYWORD_COUNT"
    printf 'contentionLevel=%s\n' "$contention_level"
    if [[ "$contention_level" == "moderate" ]]; then
      printf 'sharedKeywordCount=%s\n' "$MODERATE_SHARED_KEYWORD_COUNT"
    fi
    printf 'timestampOutputs=true\n'
    printf 'outputPath=%s\n' "$SWEEP_RAW_DIR/concurrent_samples.csv"
    printf 'logOutputDirectory=%s\n' "$SWEEP_RUN_LOG_DIR"
  } > "$RESOLVED_CONFIG_PATH"
}

run_id_for() {
  local client_count="$1"
  local contention_level="$2"
  local repetition="$3"
  local contention_label="$contention_level"

  if [[ "$contention_level" == "moderate" ]]; then
    contention_label="moderate_k${MODERATE_SHARED_KEYWORD_COUNT}"
  fi
  printf 'c%s_%s_rep%s\n' "$client_count" "$contention_label" "$repetition"
}

latest_samples_for_run() {
  local marker_path="$1"
  local client_count="$2"
  local sample_path

  sample_path="$(
    find "$SWEEP_RAW_DIR" \
      -maxdepth 4 \
      -type f \
      -name 'concurrent_samples.csv' \
      -newer "$marker_path" \
      -path "*_quinta_concurrency_r${REPLICA_COUNT}_o${REPLICA_COUNT}_c${client_count}/concurrent_samples.csv" \
      -print |
      sort |
      tail -n 1
  )"

  [[ -n "$sample_path" ]] || die "Could not find raw samples for clientCount=$client_count"
  [[ -s "$sample_path" ]] || die "Raw sample CSV is empty: $sample_path"
  printf '%s\n' "$sample_path"
}

append_manifest_row() {
  local run_id="$1"
  local repetition="$2"
  local sample_path="$3"
  local client_count="$4"
  local workload_seed="$5"
  local contention_level="$6"
  local shared_keyword_count="$7"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_id" \
    "$repetition" \
    "$sample_path" \
    "$MEASUREMENT_SECONDS" \
    "$REPLICA_COUNT" \
    "$REPLICA_COUNT" \
    "$client_count" \
    "$SYNTHETIC_KEYWORD_COUNT" \
    "$SYNTHETIC_DOCUMENTS_PER_KEYWORD" \
    "$EFFECTIVE_SEED" \
    "$workload_seed" \
    "$contention_level" \
    "$shared_keyword_count" \
    >> "$MANIFEST_PATH"
}

run_one_benchmark() {
  local client_count="$1"
  local contention_level="$2"
  local repetition="$3"
  local workload_seed run_id sample_path shared_keyword_count

  workload_seed="$(workload_seed_for_repetition "$repetition")"
  shared_keyword_count="$(shared_keyword_count_for "$contention_level")"
  run_id="$(run_id_for "$client_count" "$contention_level" "$repetition")"
  write_resolved_config "$client_count" "$contention_level" "$workload_seed"

  CURRENT_MARKER_PATH="$(mktemp "$SWEEP_LOG_DIR/.sample_marker.XXXXXX")"
  echo | tee -a "$SWEEP_LOG_PATH"
  echo "===== Running $run_id ($((COMPLETED_RUNS + 1))/$TOTAL_RUNS) =====" \
    | tee -a "$SWEEP_LOG_PATH"
  echo "Dataset seed: $EFFECTIVE_SEED; workload seed: $workload_seed" \
    | tee -a "$SWEEP_LOG_PATH"

  if ! "$SINGLE_RUNNER" \
      --config "$RESOLVED_CONFIG_PATH" \
      --cluster-config "$CLUSTER_CONFIG" \
      2>&1 | tee -a "$SWEEP_LOG_PATH"; then
    die "Benchmark failed: $run_id"
  fi

  sample_path="$(latest_samples_for_run "$CURRENT_MARKER_PATH" "$client_count")"
  rm -f "$CURRENT_MARKER_PATH"
  CURRENT_MARKER_PATH=""

  append_manifest_row \
    "$run_id" "$repetition" "$sample_path" "$client_count" "$workload_seed" \
    "$contention_level" "$shared_keyword_count"
  COMPLETED_RUNS=$((COMPLETED_RUNS + 1))
}

run_all_benchmarks() {
  local contention_level client_count repetition

  COMPLETED_RUNS=0
  for contention_level in "${CONTENTION_LEVELS[@]}"; do
    for client_count in "${CLIENT_COUNTS[@]}"; do
      for (( repetition = 1; repetition <= REPETITIONS; repetition++ )); do
        run_one_benchmark "$client_count" "$contention_level" "$repetition"
      done
    done
  done
}

summarize_results() {
  python3 "$SUMMARIZER" \
    --benchmark lock-contention \
    --manifest "$MANIFEST_PATH" \
    --output-dir "$SWEEP_SUMMARY_DIR" \
    --expected-repetitions "$REPETITIONS" \
    2>&1 | tee -a "$SWEEP_LOG_PATH"
}

verify_outputs() {
  local actual_runs required_file
  local required_files=(
    per_run_throughput.tsv
    per_run_latency.tsv
    throughput_summary.tsv
    latency_pooled.tsv
    latency_summary.tsv
  )

  actual_runs=$(( $(wc -l < "$MANIFEST_PATH") - 1 ))
  (( actual_runs == TOTAL_RUNS )) \
    || die "Expected $TOTAL_RUNS manifest rows, found $actual_runs"

  required_files+=(chain_length_over_time.tsv lock_retry_summary.tsv)

  for required_file in "${required_files[@]}"; do
    [[ -s "$SWEEP_SUMMARY_DIR/$required_file" ]] \
      || die "Summary output is missing or empty: $SWEEP_SUMMARY_DIR/$required_file"
  done
}

cleanup() {
  local exit_status=$?
  trap - EXIT INT TERM

  if [[ -n "$CURRENT_MARKER_PATH" ]]; then
    rm -f "$CURRENT_MARKER_PATH"
  fi
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
  exit "$exit_status"
}

print_plan() {
  echo "Quinta lock-contention benchmark" | tee -a "$SWEEP_LOG_PATH"
  echo "Population clients: $POPULATE_CLIENT_COUNT" | tee -a "$SWEEP_LOG_PATH"
  echo "Replicas: $REPLICA_COUNT" | tee -a "$SWEEP_LOG_PATH"
  echo "Clients: ${CLIENT_COUNTS[*]}" | tee -a "$SWEEP_LOG_PATH"
  echo "Contention levels: ${CONTENTION_LEVELS[*]}" | tee -a "$SWEEP_LOG_PATH"
  echo "Moderate shared keywords: $MODERATE_SHARED_KEYWORD_COUNT" | tee -a "$SWEEP_LOG_PATH"
  echo "Repetitions: $REPETITIONS" | tee -a "$SWEEP_LOG_PATH"
  echo "Configured seed: $CONFIGURED_SEED" | tee -a "$SWEEP_LOG_PATH"
  echo "Effective seed: $EFFECTIVE_SEED" | tee -a "$SWEEP_LOG_PATH"
  echo "Total distributed runs: $TOTAL_RUNS" | tee -a "$SWEEP_LOG_PATH"
}

main() {
  parse_args "$@"
  ensure_command_exists python3
  load_config
  prepare_outputs
  trap cleanup EXIT INT TERM

  write_manifest_header
  print_plan
  run_all_benchmarks
  summarize_results
  verify_outputs

  echo "Lock-contention benchmark completed." | tee -a "$SWEEP_LOG_PATH"
  echo "Manifest: $MANIFEST_PATH" | tee -a "$SWEEP_LOG_PATH"
  echo "Summaries: $SWEEP_SUMMARY_DIR" | tee -a "$SWEEP_LOG_PATH"
  echo "Sweep log: $SWEEP_LOG_PATH" | tee -a "$SWEEP_LOG_PATH"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
