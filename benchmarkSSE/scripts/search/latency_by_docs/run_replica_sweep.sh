#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DEFAULT_CONFIG="$ROOT_DIR/benchmarkSSE/config/search/latency_by_docs.properties"
# Matches METRICS in summarize.py.
N_METRICS=8
CONFIG_PATH="$DEFAULT_CONFIG"
REPLICA_LIST="4,7,10,13"
ORAM_REPLICAS_OVERRIDE=""

DOCS_RUNNER="$ROOT_DIR/benchmarkSSE/scripts/search/latency_by_docs/run_local.sh"
AGGREGATE_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/search/latency_by_docs/aggregate_replicas.py"
GNUPLOT_SCRIPT="$ROOT_DIR/benchmarkSSE/gnuplot/search/latency_by_docs/by_replicas.gp"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--config PATH] [--sseReplicas N[,N...]] [--oramReplicas N]
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

  if [[ "$CONFIG_PATH" != /* ]]; then
    CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH"
  fi
}

ensure_file_exists() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Required file not found: $path" >&2
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

normalize_csv_list() {
  printf '%s' "$1" | tr -d '[:space:]'
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

validate_oram_replicas() {
  [[ -n "$ORAM_REPLICAS_OVERRIDE" ]] || return 0

  if ! [[ "$ORAM_REPLICAS_OVERRIDE" =~ ^[0-9]+$ ]] || (( 10#$ORAM_REPLICAS_OVERRIDE < 4 )); then
    echo "--oramReplicas must be an integer greater than or equal to 4." >&2
    exit 1
  fi
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
    validate_seed "$CONFIGURED_SEED"
    EFFECTIVE_SEED="$(resolve_seed "$CONFIGURED_SEED")"
  fi
}

validate_seed() {
  local value="$1"
  if [[ "$value" != "random" && ! "$value" =~ ^-?[0-9]+$ ]]; then
    echo "Property seed must be an integer or random." >&2
    exit 1
  fi
}

resolve_seed() {
  local configured_seed="$1"
  if [[ "$configured_seed" == "random" ]]; then
    python3 -c 'import secrets; print(secrets.randbits(63))'
  else
    printf '%s\n' "$configured_seed"
  fi
}

load_summary_location() {
  local summary_path

  summary_path="$(get_property summaryOutputPath)"
  summary_path="$(python3 -c 'import os, sys; print(os.path.abspath(os.path.join(sys.argv[1], sys.argv[2])))' \
    "$(dirname "$CONFIG_PATH")" "$summary_path")"
  SUMMARY_SEARCH_DIR="$(dirname "$summary_path")"
  SUMMARY_FILENAME="$(basename "$summary_path")"
}

prepare_outputs() {
  SWEEP_DATE="$(date +%d_%m_%Y)"
  SWEEP_NAME="$(date +%H_%M_%S)_replica_sweep"
  SWEEP_RESULTS_DIR="$ROOT_DIR/benchmarkSSE/results/data/$SWEEP_DATE/$SWEEP_NAME"
  SWEEP_PLOTS_DIR="$ROOT_DIR/benchmarkSSE/plots/$SWEEP_DATE/$SWEEP_NAME"
  SWEEP_LOG_DIR="$ROOT_DIR/benchmarkSSE/results/logs/$SWEEP_DATE/$SWEEP_NAME"
  SWEEP_SUMMARY_PATH="$SWEEP_RESULTS_DIR/search_latency_by_replicas_summary.tsv"
  SWEEP_LOG_PATH="$SWEEP_LOG_DIR/run_search_latency_by_replicas.log"

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
    echo "===== Running search latency benchmark with SSE=$sse_replicas, ORAM=$oram_replicas ====="
  } | tee -a "$SWEEP_LOG_PATH"

  if ! "$DOCS_RUNNER" --config "$CONFIG_PATH" --sseReplicas "$sse_replicas" --oramReplicas "$oram_replicas" "${seed_args[@]}" 2>&1 | tee -a "$SWEEP_LOG_PATH"; then
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
  echo "Generating replica sweep plots..." | tee -a "$SWEEP_LOG_PATH"
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
  ensure_file_exists "$DOCS_RUNNER"
  ensure_file_exists "$AGGREGATE_SCRIPT"
  ensure_file_exists "$GNUPLOT_SCRIPT"
  ensure_file_exists "$CONFIG_PATH"
  ensure_command_exists python3
  ensure_command_exists gnuplot
  load_bucket_config
  load_summary_location

  SUMMARY_PATHS=()

  prepare_outputs
  echo "Replica sweep: ${REPLICA_COUNTS[*]}" | tee -a "$SWEEP_LOG_PATH"
  echo "ORAM replicas: ${ORAM_REPLICAS_OVERRIDE:-follow SSE}" | tee -a "$SWEEP_LOG_PATH"
  echo "Config: $CONFIG_PATH" | tee -a "$SWEEP_LOG_PATH"
  echo "Buckets: $BUCKET_LIST" | tee -a "$SWEEP_LOG_PATH"
  if [[ "$DATASET_TYPE" == "synthetic" ]]; then
    echo "Configured seed: $CONFIGURED_SEED" | tee -a "$SWEEP_LOG_PATH"
    echo "Effective seed: $EFFECTIVE_SEED" | tee -a "$SWEEP_LOG_PATH"
  fi

  local replica_count
  for replica_count in "${REPLICA_COUNTS[@]}"; do
    run_one_benchmark "$replica_count"
  done

  aggregate_results
  generate_plots
  verify_outputs

  echo "Replica sweep summary written to $SWEEP_SUMMARY_PATH"
  echo "Replica sweep plot written to $SWEEP_PLOTS_DIR/search_latency_by_replicas.pdf"
}

main "$@"
