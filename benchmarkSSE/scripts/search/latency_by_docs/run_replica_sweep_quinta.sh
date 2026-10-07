#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$ROOT_DIR/benchmarkSSE/scripts/common/quinta_benchmark_common.sh"

DEFAULT_CONFIG="$ROOT_DIR/benchmarkSSE/config/search/latency_by_docs.properties"
DEFAULT_CLUSTER_CONFIG="$ROOT_DIR/benchmarkSSE/config/quinta.env"
# Matches METRICS in summarize.py.
N_METRICS=8
CONFIG_PATH="$DEFAULT_CONFIG"
CLUSTER_CONFIG="$DEFAULT_CLUSTER_CONFIG"
REPLICA_LIST="4,7,10"
ORAM_REPLICAS_OVERRIDE=""

DOCS_RUNNER="$ROOT_DIR/benchmarkSSE/scripts/search/latency_by_docs/run_quinta.sh"
AGGREGATE_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/search/latency_by_docs/aggregate_replicas.py"
GNUPLOT_SCRIPT="$ROOT_DIR/benchmarkSSE/gnuplot/search/latency_by_docs/by_replicas.gp"

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
        if [[ "$#" -lt 2 || "$2" == --* ]]; then
          echo "Missing value for --config." >&2
          usage
          exit 1
        fi
        CONFIG_PATH="$2"
        shift 2
        ;;
      --config=*)
        CONFIG_PATH="${1#--config=}"
        if [[ -z "$CONFIG_PATH" ]]; then
          echo "Missing value for --config." >&2
          usage
          exit 1
        fi
        shift
        ;;
      --cluster-config)
        if [[ "$#" -lt 2 || "$2" == --* ]]; then
          echo "Missing value for --cluster-config." >&2
          usage
          exit 1
        fi
        CLUSTER_CONFIG="$2"
        shift 2
        ;;
      --cluster-config=*)
        CLUSTER_CONFIG="${1#--cluster-config=}"
        if [[ -z "$CLUSTER_CONFIG" ]]; then
          echo "Missing value for --cluster-config." >&2
          usage
          exit 1
        fi
        shift
        ;;
      --sseReplicas)
        if [[ "$#" -lt 2 || "$2" == --* ]]; then
          echo "Missing value for --sseReplicas." >&2
          usage
          exit 1
        fi
        REPLICA_LIST="$2"
        shift 2
        ;;
      --sseReplicas=*)
        REPLICA_LIST="${1#--sseReplicas=}"
        if [[ -z "$REPLICA_LIST" ]]; then
          echo "Missing value for --sseReplicas." >&2
          usage
          exit 1
        fi
        shift
        ;;
      --oramReplicas)
        if [[ "$#" -lt 2 || -z "$2" || "$2" == --* ]]; then
          echo "Missing value for --oramReplicas." >&2
          usage
          exit 1
        fi
        ORAM_REPLICAS_OVERRIDE="$2"
        shift 2
        ;;
      --oramReplicas=*)
        ORAM_REPLICAS_OVERRIDE="${1#--oramReplicas=}"
        if [[ -z "$ORAM_REPLICAS_OVERRIDE" ]]; then
          echo "Missing value for --oramReplicas." >&2
          usage
          exit 1
        fi
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  [[ "$CONFIG_PATH" = /* ]] || CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH"
  [[ "$CLUSTER_CONFIG" = /* ]] || CLUSTER_CONFIG="$ROOT_DIR/$CLUSTER_CONFIG"
  CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
}

validate_oram_replicas() {
  [[ -n "$ORAM_REPLICAS_OVERRIDE" ]] || return 0

  if ! [[ "$ORAM_REPLICAS_OVERRIDE" =~ ^[0-9]+$ ]] || (( 10#$ORAM_REPLICAS_OVERRIDE < 4 )); then
    echo "--oramReplicas must be an integer greater than or equal to 4." >&2
    exit 1
  fi
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

get_property() {
  local key="$1"
  local value
  value="$(sed -n "s/^${key}=//p" "$CONFIG_PATH" | tail -n 1)"
  if [[ -z "$value" ]]; then
    echo "Missing property '$key' in $CONFIG_PATH" >&2
    exit 1
  fi
  printf '%s\n' "$value"
}

doc_counts_to_buckets() {
  local raw_doc_counts="$1"
  local compact_doc_counts doc_count buckets=""

  compact_doc_counts="$(normalize_csv_list "$raw_doc_counts")"
  if [[ -z "$compact_doc_counts" ]]; then
    echo "syntheticDocCounts cannot be empty." >&2
    exit 1
  fi

  IFS=',' read -r -a DOC_COUNT_BUCKET_VALUES <<< "$compact_doc_counts"
  for doc_count in "${DOC_COUNT_BUCKET_VALUES[@]}"; do
    if ! [[ "$doc_count" =~ ^[0-9]+$ ]] || [[ "$doc_count" -lt 1 ]]; then
      echo "syntheticDocCounts values must be positive integers: $doc_count" >&2
      exit 1
    fi
    [[ -z "$buckets" ]] || buckets+=","
    buckets+="${doc_count}:${doc_count}"
  done

  printf '%s\n' "$buckets"
}

load_bucket_config() {
  local bucket

  DATASET_TYPE="$(get_property datasetType)"
  case "$DATASET_TYPE" in
    enron)
      BUCKET_LIST="$(get_property processorBuckets)"
      ;;
    synthetic)
      BUCKET_LIST="$(doc_counts_to_buckets "$(get_property syntheticDocCounts)")"
      ;;
    *)
      echo "datasetType must be either 'enron' or 'synthetic'." >&2
      exit 1
      ;;
  esac
  BUCKET_SPECS="${BUCKET_LIST//,/ }"
  BUCKET_LABELS=""
  BUCKET_COUNT=0

  for bucket in $BUCKET_SPECS; do
    [[ -z "$BUCKET_LABELS" ]] || BUCKET_LABELS+=" "
    BUCKET_LABELS+="${bucket/:/-}"
    BUCKET_COUNT=$((BUCKET_COUNT + 1))
  done

  if [[ "$DATASET_TYPE" == "synthetic" ]]; then
    CONFIGURED_SEED="$(get_property seed)"
    validate_seed "$CONFIGURED_SEED" "seed"
    EFFECTIVE_SEED="$(resolve_seed "$CONFIGURED_SEED")"
  fi
}

load_summary_location() {
  local summary_path

  summary_path="$(resolve_config_path "$(get_property summaryOutputPath)")"
  SUMMARY_SEARCH_DIR="$(dirname "$summary_path")"
  SUMMARY_FILENAME="$(basename "$summary_path")"
}

prepare_outputs() {
  SWEEP_DATE="$(date +%d_%m_%Y)"
  SWEEP_NAME="$(date +%H_%M_%S)_quinta_replica_sweep"
  SWEEP_RESULTS_DIR="$ROOT_DIR/benchmarkSSE/results/data/$SWEEP_DATE/$SWEEP_NAME"
  SWEEP_PLOTS_DIR="$ROOT_DIR/benchmarkSSE/plots/$SWEEP_DATE/$SWEEP_NAME"
  SWEEP_LOG_DIR="$ROOT_DIR/benchmarkSSE/results/logs/$SWEEP_DATE/$SWEEP_NAME"
  SWEEP_SUMMARY_PATH="$SWEEP_RESULTS_DIR/search_latency_by_replicas_summary.tsv"
  SWEEP_LOG_PATH="$SWEEP_LOG_DIR/run_search_latency_by_replicas_quinta.log"

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
      -path "*_r${sse_replicas}_o${oram_replicas}/${SUMMARY_FILENAME}" \
      -print |
      sort |
      tail -n 1
  )"

  if [[ -z "$summary_path" ]]; then
    echo "Could not find summary for SSE=$sse_replicas, ORAM=$oram_replicas." >&2
    exit 1
  fi

  printf '%s\n' "$summary_path"
}

run_one_benchmark() {
  local sse_replicas="$1"
  local oram_replicas marker_path summary_path
  local seed_args=()

  oram_replicas="${ORAM_REPLICAS_OVERRIDE:-$sse_replicas}"
  marker_path="$(mktemp "$SWEEP_LOG_DIR/.summary_marker.XXXXXX")"
  if [[ "$DATASET_TYPE" == "synthetic" ]]; then
    seed_args=(--seed "$EFFECTIVE_SEED")
  fi
  {
    echo
    echo "===== Running Quinta search latency benchmark with SSE=$sse_replicas, ORAM=$oram_replicas ====="
  } | tee -a "$SWEEP_LOG_PATH"

  if ! "$DOCS_RUNNER" \
      --config "$CONFIG_PATH" \
      --cluster-config "$CLUSTER_CONFIG" \
      --sseReplicas "$sse_replicas" \
      --oramReplicas "$oram_replicas" \
      "${seed_args[@]}" \
      2>&1 | tee -a "$SWEEP_LOG_PATH"; then
    rm -f "$marker_path"
    echo "Benchmark failed for SSE=$sse_replicas, ORAM=$oram_replicas." >&2
    exit 1
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
  echo "Aggregating ${#SUMMARY_PATHS[@]} summary file(s)..." | tee -a "$SWEEP_LOG_PATH"
  python3 "$AGGREGATE_SCRIPT" --output "$SWEEP_SUMMARY_PATH" "${SUMMARY_PATHS[@]}" 2>&1 | tee -a "$SWEEP_LOG_PATH"
}

generate_plots() {
  echo "Generating Quinta replica sweep plots..." | tee -a "$SWEEP_LOG_PATH"
  gnuplot \
    -e "input_path='$SWEEP_SUMMARY_PATH'; output_dir='$SWEEP_PLOTS_DIR'; bucket_specs='$BUCKET_SPECS'; bucket_labels='$BUCKET_LABELS'" \
    "$GNUPLOT_SCRIPT" 2>&1 | tee -a "$SWEEP_LOG_PATH"
}

verify_outputs() {
  local expected_rows actual_rows

  if [[ ! -s "$SWEEP_SUMMARY_PATH" ]]; then
    echo "Aggregated summary is missing or empty: $SWEEP_SUMMARY_PATH" >&2
    exit 1
  fi

  expected_rows=$(( ${#REPLICA_COUNTS[@]} * BUCKET_COUNT * N_METRICS ))
  actual_rows=$(( $(wc -l < "$SWEEP_SUMMARY_PATH") - 1 ))
  if (( actual_rows != expected_rows )); then
    echo "Expected $expected_rows aggregate metric rows, found $actual_rows in $SWEEP_SUMMARY_PATH." >&2
    exit 1
  fi

  if [[ ! -s "$SWEEP_PLOTS_DIR/search_latency_by_replicas.pdf" ]]; then
    echo "Plot is missing or empty: $SWEEP_PLOTS_DIR/search_latency_by_replicas.pdf" >&2
    exit 1
  fi
}

main() {
  parse_args "$@"
  parse_replica_list
  validate_oram_replicas
  ensure_executable_exists "$DOCS_RUNNER"
  ensure_file_exists "$AGGREGATE_SCRIPT"
  ensure_file_exists "$GNUPLOT_SCRIPT"
  ensure_file_exists "$CONFIG_PATH"
  ensure_file_exists "$CLUSTER_CONFIG"
  validate_sweep_capacity
  ensure_command_exists python3
  ensure_command_exists gnuplot
  load_bucket_config
  load_summary_location

  SUMMARY_PATHS=()

  prepare_outputs
  echo "Quinta replica sweep: ${REPLICA_COUNTS[*]}" | tee -a "$SWEEP_LOG_PATH"
  echo "ORAM replicas: ${ORAM_REPLICAS_OVERRIDE:-follow SSE}" | tee -a "$SWEEP_LOG_PATH"
  echo "Config: $CONFIG_PATH" | tee -a "$SWEEP_LOG_PATH"
  echo "Cluster config: $CLUSTER_CONFIG" | tee -a "$SWEEP_LOG_PATH"
  echo "Buckets: $BUCKET_LIST" | tee -a "$SWEEP_LOG_PATH"
  if [[ "$DATASET_TYPE" == "synthetic" ]]; then
    echo "Configured seed: $CONFIGURED_SEED" | tee -a "$SWEEP_LOG_PATH"
    echo "Effective seed: $EFFECTIVE_SEED" | tee -a "$SWEEP_LOG_PATH"
  fi

  local sse_replicas
  for sse_replicas in "${REPLICA_COUNTS[@]}"; do
    run_one_benchmark "$sse_replicas"
  done

  aggregate_results
  generate_plots
  verify_outputs

  echo "Quinta replica sweep summary written to $SWEEP_SUMMARY_PATH"
  echo "Quinta replica sweep plot written to $SWEEP_PLOTS_DIR/search_latency_by_replicas.pdf"
}

main "$@"
