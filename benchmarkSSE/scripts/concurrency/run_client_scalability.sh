#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEFAULT_CONFIG="$ROOT_DIR/benchmarkSSE/config/concurrency/client_scalability.properties"
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

validate_positive_number() {
  local value="$1"
  local label="$2"

  [[ "$value" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$ ]] \
    || die "$label must be a positive number"
  awk -v value="$value" 'BEGIN { exit !(value > 0) }' \
    || die "$label must be greater than 0"
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

parse_search_percentages() {
  local value
  local compact

  compact="$(normalize_csv_list "$SEARCH_PERCENTAGE_LIST")"
  [[ -n "$compact" ]] || die "searchPercentages cannot be empty"
  IFS=',' read -r -a SEARCH_PERCENTAGES <<< "$compact"
  validate_unique_values "searchPercentages" "${SEARCH_PERCENTAGES[@]}"

  HAS_UPDATES=0
  for value in "${SEARCH_PERCENTAGES[@]}"; do
    [[ "$value" == "0" || "$value" == "100" ]] \
      || die "client scalability searchPercentages values must be 0 or 100"
    if [[ "$value" == "0" ]]; then
      HAS_UPDATES=1
    fi
  done
}

parse_access_profiles() {
  local distribution exponent
  local compact_distributions compact_exponents

  compact_distributions="$(normalize_csv_list "$ACCESS_DISTRIBUTION_LIST")"
  compact_exponents="$(normalize_csv_list "$ZIPFIAN_EXPONENT_LIST")"
  [[ -n "$compact_distributions" ]] || die "accessDistributions cannot be empty"

  IFS=',' read -r -a ACCESS_DISTRIBUTIONS <<< "$compact_distributions"
  validate_unique_values "accessDistributions" "${ACCESS_DISTRIBUTIONS[@]}"

  ZIPFIAN_EXPONENTS=()
  if [[ -n "$compact_exponents" ]]; then
    IFS=',' read -r -a ZIPFIAN_EXPONENTS <<< "$compact_exponents"
    validate_unique_values "zipfianExponents" "${ZIPFIAN_EXPONENTS[@]}"
    for exponent in "${ZIPFIAN_EXPONENTS[@]}"; do
      validate_positive_number "$exponent" "zipfianExponents value"
    done
  fi

  ACCESS_PROFILE_COUNT=0
  for distribution in "${ACCESS_DISTRIBUTIONS[@]}"; do
    case "$distribution" in
      uniform)
        ACCESS_PROFILE_COUNT=$((ACCESS_PROFILE_COUNT + 1))
        ;;
      zipfian)
        (( ${#ZIPFIAN_EXPONENTS[@]} > 0 )) \
          || die "zipfianExponents cannot be empty when Zipfian access is enabled"
        ACCESS_PROFILE_COUNT=$((ACCESS_PROFILE_COUNT + ${#ZIPFIAN_EXPONENTS[@]}))
        ;;
      *)
        die "accessDistributions values must be uniform or zipfian"
        ;;
    esac
  done
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
  SEARCH_PERCENTAGE_LIST="$(get_property searchPercentages)"
  ACCESS_DISTRIBUTION_LIST="$(get_property accessDistributions)"
  ZIPFIAN_EXPONENT_LIST="$(get_property zipfianExponents)"
  REPETITIONS="$(get_property repetitions)"

  SSE_REPLICAS="$(get_property sseReplicas)"
  CONFIGURED_ORAM_REPLICAS="$(get_property oramReplicas)"
  POPULATE_CLIENT_ID="$(get_property populateClientId)"
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
  validate_positive_integer "$SSE_REPLICAS" "sseReplicas"
  (( SSE_REPLICAS >= 4 )) || die "sseReplicas must be at least 4"

  validate_integer "$CONFIGURED_ORAM_REPLICAS" "oramReplicas"
  if [[ "$CONFIGURED_ORAM_REPLICAS" == "-1" ]]; then
    EFFECTIVE_ORAM_REPLICAS="$SSE_REPLICAS"
  else
    (( CONFIGURED_ORAM_REPLICAS >= 4 )) || die "oramReplicas must be -1 or at least 4"
    EFFECTIVE_ORAM_REPLICAS="$CONFIGURED_ORAM_REPLICAS"
  fi

  validate_positive_integer "$POPULATE_CLIENT_ID" "populateClientId"
  validate_positive_integer "$POPULATE_BATCH_SIZE" "populateBatchSize"
  validate_positive_integer "$CLIENT_ID" "clientId"
  validate_positive_integer "$WARMUP_SECONDS" "warmupSeconds"
  validate_positive_integer "$MEASUREMENT_SECONDS" "measurementSeconds"
  validate_positive_integer "$WARMUP_KEYWORD_COUNT" "warmupKeywordCount"

  (( SYNTHETIC_KEYWORD_COUNT > WARMUP_KEYWORD_COUNT )) \
    || die "syntheticKeywordCount must be greater than warmupKeywordCount"

  [[ -s "$ABS_VOCABULARY_PATH" ]] \
    || die "Vocabulary file is missing or empty: $ABS_VOCABULARY_PATH"

  parse_client_counts
  parse_search_percentages
  parse_access_profiles

  HIGHEST_CLIENT_ID=$((CLIENT_ID + MAX_CLIENT_COUNT - 1))
  (( HIGHEST_CLIENT_ID <= 2147482647 )) \
    || die "Configured client IDs exceed the supported ORAM client ID range"
  if (( POPULATE_CLIENT_ID >= CLIENT_ID && POPULATE_CLIENT_ID <= HIGHEST_CLIENT_ID )); then
    die "populateClientId overlaps the benchmark client ID range"
  fi

  # shellcheck source=/dev/null
  source "$CLUSTER_CONFIG"
  REPLICA_COUNT="$SSE_REPLICAS"
  ORAM_REPLICA_COUNT="$EFFECTIVE_ORAM_REPLICAS"
  client_node >/dev/null

  TOTAL_RUNS=$((
    ${#CLIENT_COUNTS[@]}
    * ${#SEARCH_PERCENTAGES[@]}
    * ACCESS_PROFILE_COUNT
    * REPETITIONS
  ))
}

prepare_outputs() {
  SWEEP_DATE="$(date +%d_%m_%Y)"
  SWEEP_NAME="$(date +%H_%M_%S)_quinta_client_scalability"
  SWEEP_RESULTS_DIR="$ROOT_DIR/benchmarkSSE/results/data/$SWEEP_DATE/$SWEEP_NAME"
  SWEEP_RAW_DIR="$SWEEP_RESULTS_DIR/raw"
  SWEEP_SUMMARY_DIR="$SWEEP_RESULTS_DIR/summaries"
  SWEEP_LOG_DIR="$ROOT_DIR/benchmarkSSE/results/logs/$SWEEP_DATE/$SWEEP_NAME"
  SWEEP_RUN_LOG_DIR="$SWEEP_LOG_DIR/runs"
  SWEEP_LOG_PATH="$SWEEP_LOG_DIR/run_client_scalability_quinta.log"
  MANIFEST_PATH="$SWEEP_RESULTS_DIR/runs.tsv"

  mkdir -p "$SWEEP_RAW_DIR" "$SWEEP_SUMMARY_DIR" "$SWEEP_RUN_LOG_DIR"

  TEMP_DIR="$(mktemp -d /tmp/bft-sse-client-scalability.XXXXXX)"
  RESOLVED_CONFIG_PATH="$TEMP_DIR/resolved.properties"
  TEMP_DATASET_PATH="$TEMP_DIR/synthetic_dataset.ndjson"
}

write_manifest_header() {
  printf '%s\n' \
    $'run_id\trepetition\tsample_csv\tmeasurement_seconds\tsse_replicas\toram_replicas\tclient_count\tsynthetic_keyword_count\tsynthetic_documents_per_keyword\tdataset_seed\tworkload_seed\tsearch_percentage\taccess_distribution\tzipfian_exponent' \
    > "$MANIFEST_PATH"
}

workload_seed_for_repetition() {
  local repetition="$1"
  printf '%s\n' "$((EFFECTIVE_SEED + (repetition - 1) * MAX_CLIENT_COUNT))"
}

write_resolved_config() {
  local client_count="$1"
  local search_percentage="$2"
  local distribution="$3"
  local exponent="$4"
  local workload_seed="$5"

  {
    printf 'vocabularyPath=%s\n' "$ABS_VOCABULARY_PATH"
    printf 'syntheticOutputPath=%s\n' "$TEMP_DATASET_PATH"
    printf 'syntheticKeywordCount=%s\n' "$SYNTHETIC_KEYWORD_COUNT"
    printf 'syntheticDocumentsPerKeyword=%s\n' "$SYNTHETIC_DOCUMENTS_PER_KEYWORD"
    printf 'datasetSeed=%s\n' "$EFFECTIVE_SEED"
    printf 'workloadSeed=%s\n' "$workload_seed"
    printf 'sseReplicas=%s\n' "$SSE_REPLICAS"
    printf 'oramReplicas=%s\n' "$CONFIGURED_ORAM_REPLICAS"
    printf 'populateClientId=%s\n' "$POPULATE_CLIENT_ID"
    printf 'populateBatchSize=%s\n' "$POPULATE_BATCH_SIZE"
    printf 'clientId=%s\n' "$CLIENT_ID"
    printf 'clientCount=%s\n' "$client_count"
    printf 'scenario=concurrent-workload\n'
    printf 'warmupSeconds=%s\n' "$WARMUP_SECONDS"
    printf 'measurementSeconds=%s\n' "$MEASUREMENT_SECONDS"
    printf 'warmupKeywordCount=%s\n' "$WARMUP_KEYWORD_COUNT"
    printf 'searchPercentage=%s\n' "$search_percentage"
    printf 'keywordSelectionDistribution=%s\n' "$distribution"
    if [[ "$distribution" == "zipfian" ]]; then
      printf 'zipfianExponent=%s\n' "$exponent"
    fi
    printf 'timestampOutputs=true\n'
    printf 'outputPath=%s\n' "$SWEEP_RAW_DIR/concurrent_samples.csv"
    printf 'logOutputDirectory=%s\n' "$SWEEP_RUN_LOG_DIR"
  } > "$RESOLVED_CONFIG_PATH"
}

run_id_for() {
  local client_count="$1"
  local search_percentage="$2"
  local distribution="$3"
  local exponent="$4"
  local repetition="$5"
  local access_label="$distribution"

  if [[ "$distribution" == "zipfian" ]]; then
    access_label="zipfian_${exponent//./_}"
  fi
  printf 'c%s_s%s_%s_rep%s\n' \
    "$client_count" "$search_percentage" "$access_label" "$repetition"
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
      -path "*_quinta_concurrency_r${SSE_REPLICAS}_o${EFFECTIVE_ORAM_REPLICAS}_c${client_count}/concurrent_samples.csv" \
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
  local search_percentage="$6"
  local distribution="$7"
  local exponent="$8"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_id" \
    "$repetition" \
    "$sample_path" \
    "$MEASUREMENT_SECONDS" \
    "$SSE_REPLICAS" \
    "$EFFECTIVE_ORAM_REPLICAS" \
    "$client_count" \
    "$SYNTHETIC_KEYWORD_COUNT" \
    "$SYNTHETIC_DOCUMENTS_PER_KEYWORD" \
    "$EFFECTIVE_SEED" \
    "$workload_seed" \
    "$search_percentage" \
    "$distribution" \
    "$exponent" \
    >> "$MANIFEST_PATH"
}

run_one_benchmark() {
  local client_count="$1"
  local search_percentage="$2"
  local distribution="$3"
  local exponent="$4"
  local repetition="$5"
  local workload_seed run_id sample_path

  workload_seed="$(workload_seed_for_repetition "$repetition")"
  run_id="$(run_id_for \
    "$client_count" "$search_percentage" "$distribution" "$exponent" "$repetition")"
  write_resolved_config \
    "$client_count" "$search_percentage" "$distribution" "$exponent" "$workload_seed"

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
    "$search_percentage" "$distribution" "$exponent"
  COMPLETED_RUNS=$((COMPLETED_RUNS + 1))
}

run_access_profile() {
  local distribution="$1"
  local exponent="$2"
  local search_percentage client_count repetition

  for search_percentage in "${SEARCH_PERCENTAGES[@]}"; do
    for client_count in "${CLIENT_COUNTS[@]}"; do
      for (( repetition = 1; repetition <= REPETITIONS; repetition++ )); do
        run_one_benchmark \
          "$client_count" "$search_percentage" "$distribution" "$exponent" "$repetition"
      done
    done
  done
}

run_all_benchmarks() {
  local distribution exponent

  COMPLETED_RUNS=0
  for distribution in "${ACCESS_DISTRIBUTIONS[@]}"; do
    if [[ "$distribution" == "uniform" ]]; then
      run_access_profile "uniform" ""
    else
      for exponent in "${ZIPFIAN_EXPONENTS[@]}"; do
        run_access_profile "zipfian" "$exponent"
      done
    fi
  done
}

summarize_results() {
  python3 "$SUMMARIZER" \
    --benchmark client-scalability \
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

  if (( HAS_UPDATES == 1 )); then
    required_files+=(chain_length_over_time.tsv lock_retry_summary.tsv)
  fi

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
  echo "Quinta client scalability benchmark" | tee -a "$SWEEP_LOG_PATH"
  echo "Clients: ${CLIENT_COUNTS[*]}" | tee -a "$SWEEP_LOG_PATH"
  echo "Search percentages: ${SEARCH_PERCENTAGES[*]}" | tee -a "$SWEEP_LOG_PATH"
  echo "Access distributions: ${ACCESS_DISTRIBUTIONS[*]}" | tee -a "$SWEEP_LOG_PATH"
  echo "Zipfian exponents: ${ZIPFIAN_EXPONENTS[*]:-none}" | tee -a "$SWEEP_LOG_PATH"
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

  echo "Client scalability benchmark completed." | tee -a "$SWEEP_LOG_PATH"
  echo "Manifest: $MANIFEST_PATH" | tee -a "$SWEEP_LOG_PATH"
  echo "Summaries: $SWEEP_SUMMARY_DIR" | tee -a "$SWEEP_LOG_PATH"
  echo "Sweep log: $SWEEP_LOG_PATH" | tee -a "$SWEEP_LOG_PATH"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
