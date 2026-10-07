#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$ROOT_DIR/benchmarkSSE/scripts/common/quinta_benchmark_common.sh"

DEFAULT_CONFIG="$ROOT_DIR/benchmarkSSE/config/update/latency_by_docs.properties"
DEFAULT_CLUSTER_CONFIG="$ROOT_DIR/benchmarkSSE/config/quinta.env"
N_METRICS=8

CONFIG_PATH="$DEFAULT_CONFIG"
CLUSTER_CONFIG="$DEFAULT_CLUSTER_CONFIG"
REPLICA_LIST="4,7,10"
ORAM_REPLICAS_OVERRIDE=""

DOCS_RUNNER="$ROOT_DIR/benchmarkSSE/scripts/update/latency_by_docs/run_quinta.sh"
AGGREGATE_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/update/latency_by_docs/aggregate_replicas.py"
GNUPLOT_SCRIPT="$ROOT_DIR/benchmarkSSE/gnuplot/update/latency_by_docs/by_replicas.gp"

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
    (( sse_replicas <= max_replicas )) \
      || die "sseReplicas=$sse_replicas cannot run: one Quinta node must remain reserved for clients (maximum $max_replicas)"
    (( oram_replicas <= max_replicas )) \
      || die "oramReplicas=$oram_replicas cannot run with SSE=$sse_replicas: one Quinta node must remain reserved for clients (maximum $max_replicas)"
  done
}

load_benchmark_config() {
  CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
  DB_SIZE="$(get_property dbSize)"
  MEASUREMENT_DOC_COUNTS="$(normalize_csv_list "$(get_property measurementDocCounts)")"
  CONFIGURED_SEED="$(get_property seed)"

  validate_positive_integer "$DB_SIZE" "dbSize"
  validate_seed "$CONFIGURED_SEED" "seed"
  EFFECTIVE_SEED="$(resolve_seed "$CONFIGURED_SEED")"
  parse_measurement_doc_counts
  load_summary_location
}

parse_measurement_doc_counts() {
  local doc_count existing_doc_count

  [[ -n "$MEASUREMENT_DOC_COUNTS" ]] || die "measurementDocCounts cannot be empty"
  IFS=',' read -r -a MEASUREMENT_DOC_COUNT_VALUES <<< "$MEASUREMENT_DOC_COUNTS"

  for doc_count in "${MEASUREMENT_DOC_COUNT_VALUES[@]}"; do
    validate_positive_integer "$doc_count" "measurementDocCounts"
    for existing_doc_count in "${VALIDATED_DOC_COUNTS[@]:-}"; do
      [[ "$doc_count" != "$existing_doc_count" ]] \
        || die "measurementDocCounts contains duplicate value: $doc_count"
    done
    VALIDATED_DOC_COUNTS+=("$doc_count")
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
  SWEEP_NAME="$(date +%H_%M_%S)_quinta_update_replica_sweep"
  SWEEP_RESULTS_DIR="$ROOT_DIR/benchmarkSSE/results/data/$SWEEP_DATE/$SWEEP_NAME"
  SWEEP_PLOTS_DIR="$ROOT_DIR/benchmarkSSE/plots/$SWEEP_DATE/$SWEEP_NAME"
  SWEEP_LOG_DIR="$ROOT_DIR/benchmarkSSE/results/logs/$SWEEP_DATE/$SWEEP_NAME"
  SWEEP_SUMMARY_PATH="$SWEEP_RESULTS_DIR/update_latency_by_replicas_summary.tsv"
  SWEEP_LOG_PATH="$SWEEP_LOG_DIR/run_update_latency_by_replicas_quinta.log"

  mkdir -p "$SWEEP_RESULTS_DIR" "$SWEEP_PLOTS_DIR" "$SWEEP_LOG_DIR"
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
      -path "*_quinta_update_docs_r${sse_replicas}_o${oram_replicas}_db${DB_SIZE}/${SUMMARY_FILENAME}" \
      -print |
      sort |
      tail -n 1
  )"

  [[ -n "$summary_path" ]] \
    || die "Could not find summary for SSE=$sse_replicas, ORAM=$oram_replicas, dbSize=$DB_SIZE"
  printf '%s\n' "$summary_path"
}

run_one_benchmark() {
  local sse_replicas="$1"
  local oram_replicas marker_path summary_path

  oram_replicas="${ORAM_REPLICAS_OVERRIDE:-$sse_replicas}"
  marker_path="$(mktemp "$SWEEP_LOG_DIR/.summary_marker.XXXXXX")"
  {
    echo
    echo "===== Running Quinta update latency benchmark with SSE=$sse_replicas, ORAM=$oram_replicas ====="
  } | tee -a "$SWEEP_LOG_PATH"

  if ! "$DOCS_RUNNER" \
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

  echo "Summary for SSE=$sse_replicas, ORAM=$oram_replicas: $summary_path" | tee -a "$SWEEP_LOG_PATH"
}

aggregate_results() {
  echo "Aggregating ${#SUMMARY_PATHS[@]} update summary file(s)..." | tee -a "$SWEEP_LOG_PATH"
  python3 "$AGGREGATE_SCRIPT" \
    --output "$SWEEP_SUMMARY_PATH" \
    "${SUMMARY_PATHS[@]}" \
    2>&1 | tee -a "$SWEEP_LOG_PATH"
}

generate_plot() {
  local doc_count_values="${VALIDATED_DOC_COUNTS[*]}"

  echo "Generating Quinta update replica sweep plot..." | tee -a "$SWEEP_LOG_PATH"
  gnuplot \
    -e "input_path='$SWEEP_SUMMARY_PATH'; output_dir='$SWEEP_PLOTS_DIR'; doc_count_values='$doc_count_values'" \
    "$GNUPLOT_SCRIPT" 2>&1 | tee -a "$SWEEP_LOG_PATH"
}

verify_outputs() {
  local expected_rows actual_rows plot_path

  [[ -s "$SWEEP_SUMMARY_PATH" ]] \
    || die "Aggregated update summary is missing or empty: $SWEEP_SUMMARY_PATH"

  expected_rows=$((${#REPLICA_COUNTS[@]} * ${#VALIDATED_DOC_COUNTS[@]} * N_METRICS))
  actual_rows=$(($(wc -l < "$SWEEP_SUMMARY_PATH") - 1))
  (( actual_rows == expected_rows )) \
    || die "Expected $expected_rows aggregate metric rows, found $actual_rows in $SWEEP_SUMMARY_PATH"

  plot_path="$SWEEP_PLOTS_DIR/update_latency_by_replicas.pdf"
  [[ -s "$plot_path" ]] || die "Update replica plot is missing or empty: $plot_path"
}

main() {
  parse_args "$@"
  parse_replica_list
  validate_unique_replica_counts
  validate_oram_replicas
  ensure_executable_exists "$DOCS_RUNNER"
  ensure_file_exists "$AGGREGATE_SCRIPT"
  ensure_file_exists "$GNUPLOT_SCRIPT"
  ensure_file_exists "$CONFIG_PATH"
  ensure_file_exists "$CLUSTER_CONFIG"
  validate_sweep_capacity
  ensure_command_exists python3
  ensure_command_exists gnuplot

  VALIDATED_DOC_COUNTS=()
  SUMMARY_PATHS=()
  load_benchmark_config
  prepare_outputs

  echo "Quinta update replica sweep: ${REPLICA_COUNTS[*]}" | tee -a "$SWEEP_LOG_PATH"
  echo "ORAM replicas: ${ORAM_REPLICAS_OVERRIDE:-follow SSE}" | tee -a "$SWEEP_LOG_PATH"
  echo "Config: $CONFIG_PATH" | tee -a "$SWEEP_LOG_PATH"
  echo "Cluster config: $CLUSTER_CONFIG" | tee -a "$SWEEP_LOG_PATH"
  echo "Target DB size: $DB_SIZE" | tee -a "$SWEEP_LOG_PATH"
  echo "Measurement document counts: $MEASUREMENT_DOC_COUNTS" | tee -a "$SWEEP_LOG_PATH"
  echo "Configured seed: $CONFIGURED_SEED" | tee -a "$SWEEP_LOG_PATH"
  echo "Effective seed: $EFFECTIVE_SEED" | tee -a "$SWEEP_LOG_PATH"

  local sse_replicas
  for sse_replicas in "${REPLICA_COUNTS[@]}"; do
    run_one_benchmark "$sse_replicas"
  done

  aggregate_results
  generate_plot
  verify_outputs

  echo "Quinta update replica sweep summary written to $SWEEP_SUMMARY_PATH"
  echo "Quinta update replica sweep plot written to $SWEEP_PLOTS_DIR/update_latency_by_replicas.pdf"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
