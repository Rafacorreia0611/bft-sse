#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
COMMON_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/common/quinta_benchmark_common.sh"
DEFAULT_CONFIG="$ROOT_DIR/benchmarkSSE/config/update/latency_by_db_size.properties"
DEFAULT_CLUSTER_CONFIG="$ROOT_DIR/benchmarkSSE/config/quinta.env"
SINGLE_RUNNER="$ROOT_DIR/benchmarkSSE/scripts/update/latency_by_db_size/run_quinta.sh"
AGGREGATE_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/update/latency_by_db_size/aggregate.py"
# Matches METRICS in aggregate.py.
N_METRICS=8

CONFIG_PATH="$DEFAULT_CONFIG"
CLUSTER_CONFIG="$DEFAULT_CLUSTER_CONFIG"
REPLICA_LIST="4,7,10"
ORAM_REPLICAS_OVERRIDE=""

# shellcheck source=../../common/quinta_benchmark_common.sh
source "$COMMON_SCRIPT"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--config PATH] [--cluster-config PATH] [--sseReplicas N[,N...]] [--oramReplicas N]
Without --oramReplicas, ORAM follows each SSE count; otherwise it stays fixed at N.
EOF
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --config)
        [[ "$#" -ge 2 && "$2" != --* ]] || die "Missing value for --config"
        CONFIG_PATH="$2"
        shift 2
        ;;
      --config=*)
        CONFIG_PATH="${1#--config=}"
        [[ -n "$CONFIG_PATH" ]] || die "Missing value for --config"
        shift
        ;;
      --cluster-config)
        [[ "$#" -ge 2 && "$2" != --* ]] || die "Missing value for --cluster-config"
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
        REPLICA_LIST="$2"
        shift 2
        ;;
      --sseReplicas=*)
        REPLICA_LIST="${1#--sseReplicas=}"
        [[ -n "$REPLICA_LIST" ]] || die "Missing value for --sseReplicas"
        shift
        ;;
      --oramReplicas)
        [[ "$#" -ge 2 && "$2" != --* ]] || die "Missing value for --oramReplicas"
        ORAM_REPLICAS_OVERRIDE="$2"
        shift 2
        ;;
      --oramReplicas=*)
        ORAM_REPLICAS_OVERRIDE="${1#--oramReplicas=}"
        [[ -n "$ORAM_REPLICAS_OVERRIDE" ]] || die "Missing value for --oramReplicas"
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

validate_unique_replica_counts() {
  local index previous_index

  for ((index = 0; index < ${#REPLICA_COUNTS[@]}; index++)); do
    for ((previous_index = 0; previous_index < index; previous_index++)); do
      [[ "${REPLICA_COUNTS[$index]}" != "${REPLICA_COUNTS[$previous_index]}" ]] \
        || die "SSE replica list contains duplicate value: ${REPLICA_COUNTS[$index]}"
    done
  done
}

validate_oram_replicas() {
  [[ -z "$ORAM_REPLICAS_OVERRIDE" ]] && return

  validate_positive_integer "$ORAM_REPLICAS_OVERRIDE" "--oramReplicas"
  [[ "$ORAM_REPLICAS_OVERRIDE" -ge 4 ]] \
    || die "--oramReplicas must be at least 4"
}

validate_sweep_capacity() {
  local max_replicas sse_replicas oram_replicas

  # shellcheck source=/dev/null
  source "$CLUSTER_CONFIG"
  [[ "${#QUINTA_NODES[@]}" -gt 0 ]] || die "QUINTA_NODES cannot be empty"
  max_replicas=$((${#QUINTA_NODES[@]} - 1))

  for sse_replicas in "${REPLICA_COUNTS[@]}"; do
    oram_replicas="${ORAM_REPLICAS_OVERRIDE:-$sse_replicas}"
    ((sse_replicas <= max_replicas)) \
      || die "sseReplicas=$sse_replicas cannot run: one Quinta node must remain reserved for clients (maximum $max_replicas)"
    ((oram_replicas <= max_replicas)) \
      || die "oramReplicas=$oram_replicas cannot run with SSE=$sse_replicas: one Quinta node must remain reserved for clients (maximum $max_replicas)"
  done
}

load_benchmark_config() {
  SCENARIO="$(get_property scenario)"
  DB_SIZES="$(normalize_csv_list "$(get_property dbSizes)")"
  UPDATE_DOC_COUNT="$(get_property updateDocCount)"
  WARMUP_COUNT="$(get_property warmupCount)"
  MEASUREMENT_COUNT="$(get_property measurementCount)"
  CONFIGURED_SEED="$(get_property seed)"

  [[ "$SCENARIO" == "update-latency-by-docs" ]] \
    || die "scenario must be update-latency-by-docs"
  validate_positive_integer "$UPDATE_DOC_COUNT" "updateDocCount"
  validate_integer "$WARMUP_COUNT" "warmupCount"
  [[ "$WARMUP_COUNT" -ge 0 ]] || die "warmupCount must be non-negative"
  validate_positive_integer "$MEASUREMENT_COUNT" "measurementCount"
  ((MEASUREMENT_COUNT % 2 == 1)) || die "measurementCount must be odd"
  validate_seed "$CONFIGURED_SEED" "seed"

  MEASUREMENTS_BEFORE_MIDDLE=$((MEASUREMENT_COUNT / 2))
  UPDATES_BEFORE_MIDDLE=$((WARMUP_COUNT + MEASUREMENTS_BEFORE_MIDDLE))
  EFFECTIVE_SEED="$(resolve_seed "$CONFIGURED_SEED")"

  parse_db_sizes
  load_summary_location
}

parse_db_sizes() {
  local db_size initial_db_size previous_db_size=""

  [[ -n "$DB_SIZES" ]] || die "dbSizes cannot be empty"
  IFS=',' read -r -a DB_SIZE_VALUES <<< "$DB_SIZES"
  for db_size in "${DB_SIZE_VALUES[@]}"; do
    validate_positive_integer "$db_size" "dbSizes"
    initial_db_size=$((db_size - UPDATES_BEFORE_MIDDLE * UPDATE_DOC_COUNT))
    ((initial_db_size > 0)) \
      || die "dbSize $db_size is too small for the configured warm-ups and measurements"
    if [[ -n "$previous_db_size" ]]; then
      ((db_size > previous_db_size)) || die "dbSizes must be strictly increasing"
    fi
    previous_db_size="$db_size"
  done
}

load_summary_location() {
  local summary_path

  summary_path="$(resolve_config_path "$(get_property summaryOutputPath)")"
  SUMMARY_SEARCH_DIR="$(dirname "$summary_path")"
  SUMMARY_FILENAME="$(basename "$summary_path")"
}

prepare_outputs() {
  SWEEP_DATE="$(date +%d_%m_%Y)"
  SWEEP_NAME="$(date +%H_%M_%S)_quinta_update_db_size_replica_sweep"
  SWEEP_RESULTS_DIR="$ROOT_DIR/benchmarkSSE/results/data/$SWEEP_DATE/$SWEEP_NAME"
  SWEEP_LOG_DIR="$ROOT_DIR/benchmarkSSE/results/logs/$SWEEP_DATE/$SWEEP_NAME"
  SWEEP_SUMMARY_PATH="$SWEEP_RESULTS_DIR/update_latency_by_db_size_replicas_summary.tsv"
  SWEEP_LOG_PATH="$SWEEP_LOG_DIR/run_update_latency_by_db_size_replica_sweep_quinta.log"

  mkdir -p "$SWEEP_RESULTS_DIR" "$SWEEP_LOG_DIR"
}

log_sweep_configuration() {
  {
    echo "Quinta update latency by DB-size replica sweep: ${REPLICA_COUNTS[*]}"
    echo "ORAM replicas: ${ORAM_REPLICAS_OVERRIDE:-follow SSE}"
    echo "Config: $CONFIG_PATH"
    echo "Cluster config: $CLUSTER_CONFIG"
    echo "Database sizes: $DB_SIZES"
    echo "Documents per update: $UPDATE_DOC_COUNT"
    echo "Warm-up updates per database: $WARMUP_COUNT"
    echo "Measured updates per database: $MEASUREMENT_COUNT"
    echo "Configured seed: $CONFIGURED_SEED"
    echo "Effective seed: $EFFECTIVE_SEED"
  } | tee -a "$SWEEP_LOG_PATH"
}

latest_summary_for_run() {
  local marker_path="$1"
  local sse_replicas="$2"
  local oram_replicas="$3"
  local summary_path

  summary_path="$(
    find "$SUMMARY_SEARCH_DIR" \
      -maxdepth 3 \
      -type f \
      -name "$SUMMARY_FILENAME" \
      -newer "$marker_path" \
      -path "*_quinta_update_db_size_r${sse_replicas}_o${oram_replicas}/${SUMMARY_FILENAME}" \
      -print |
      sort |
      tail -n 1
  )"

  [[ -n "$summary_path" ]] \
    || die "Could not find summary for SSE=$sse_replicas, ORAM=$oram_replicas"
  printf '%s\n' "$summary_path"
}

run_one_benchmark() {
  local sse_replicas="$1"
  local oram_replicas marker_path summary_path

  oram_replicas="${ORAM_REPLICAS_OVERRIDE:-$sse_replicas}"
  marker_path="$(mktemp "$SWEEP_LOG_DIR/.summary_marker.XXXXXX")"

  {
    echo
    echo "===== Update latency by DB size: SSE=$sse_replicas, ORAM=$oram_replicas ====="
  } | tee -a "$SWEEP_LOG_PATH"

  if ! "$SINGLE_RUNNER" \
      --config "$CONFIG_PATH" \
      --cluster-config "$CLUSTER_CONFIG" \
      --sseReplicas "$sse_replicas" \
      --oramReplicas "$oram_replicas" \
      --seed "$EFFECTIVE_SEED" \
      2>&1 | tee -a "$SWEEP_LOG_PATH"; then
    rm -f "$marker_path"
    die "Benchmark failed for SSE=$sse_replicas, ORAM=$oram_replicas"
  fi

  if ! summary_path="$(latest_summary_for_run "$marker_path" "$sse_replicas" "$oram_replicas")"; then
    rm -f "$marker_path"
    exit 1
  fi
  rm -f "$marker_path"
  SUMMARY_PATHS+=("$summary_path")

  echo "Summary for SSE=$sse_replicas, ORAM=$oram_replicas: $summary_path" \
    | tee -a "$SWEEP_LOG_PATH"
}

aggregate_results() {
  echo "Aggregating ${#SUMMARY_PATHS[@]} topology summary file(s)..." \
    | tee -a "$SWEEP_LOG_PATH"
  python3 "$AGGREGATE_SCRIPT" \
    --output "$SWEEP_SUMMARY_PATH" \
    "${SUMMARY_PATHS[@]}" \
    2>&1 | tee -a "$SWEEP_LOG_PATH"
}

verify_outputs() {
  local expected_rows actual_rows

  [[ "${#SUMMARY_PATHS[@]}" -eq "${#REPLICA_COUNTS[@]}" ]] \
    || die "Not all replica topologies produced a summary"
  [[ -s "$SWEEP_SUMMARY_PATH" ]] \
    || die "Aggregated summary is missing or empty: $SWEEP_SUMMARY_PATH"

  expected_rows=$((${#REPLICA_COUNTS[@]} * ${#DB_SIZE_VALUES[@]} * N_METRICS))
  actual_rows=$(($(wc -l < "$SWEEP_SUMMARY_PATH") - 1))
  ((actual_rows == expected_rows)) \
    || die "Expected $expected_rows aggregate metric rows, found $actual_rows in $SWEEP_SUMMARY_PATH"
}

main() {
  parse_args "$@"
  parse_replica_list
  validate_unique_replica_counts
  validate_oram_replicas

  ensure_executable_exists "$SINGLE_RUNNER"
  ensure_file_exists "$AGGREGATE_SCRIPT"
  ensure_file_exists "$CONFIG_PATH"
  ensure_file_exists "$CLUSTER_CONFIG"
  ensure_command_exists python3

  validate_sweep_capacity
  load_benchmark_config
  prepare_outputs

  SUMMARY_PATHS=()
  log_sweep_configuration

  local sse_replicas
  for sse_replicas in "${REPLICA_COUNTS[@]}"; do
    run_one_benchmark "$sse_replicas"
  done

  aggregate_results
  verify_outputs

  echo "Replica-sweep summary: $SWEEP_SUMMARY_PATH"
  echo "Sweep log: $SWEEP_LOG_PATH"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
