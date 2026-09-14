#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEFAULT_CONFIG="$ROOT_DIR/benchmarkSSE/config/search/search_latency_by_docs.properties"
# Matches METRICS in summarize_search_latency.py.
N_METRICS=8
CONFIG_PATH="$DEFAULT_CONFIG"
CONFIG_DIR=""
REPLICA_COUNT_OVERRIDE=""
REPLICA_COUNT_SOURCE="config"

REPLICA_PIDS=()
ACTIVE_CLIENT_PID=""
CLEANUP_DONE=0

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [configPath] [--config PATH] [--sseReplicas N]
EOF
}

parse_args() {
  local positional_config=""

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --config)
        if [[ "$#" -lt 2 || "$2" == --* ]]; then
          echo "Missing value for --config." >&2
          usage
          exit 1
        fi
        if [[ -n "$positional_config" ]]; then
          echo "Config path provided more than once." >&2
          usage
          exit 1
        fi
        positional_config="$2"
        shift 2
        ;;
      --config=*)
        if [[ -n "$positional_config" ]]; then
          echo "Config path provided more than once." >&2
          usage
          exit 1
        fi
        positional_config="${1#--config=}"
        if [[ -z "$positional_config" ]]; then
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
        REPLICA_COUNT_OVERRIDE="$2"
        shift 2
        ;;
      --sseReplicas=*)
        REPLICA_COUNT_OVERRIDE="${1#--sseReplicas=}"
        if [[ -z "$REPLICA_COUNT_OVERRIDE" ]]; then
          echo "Missing value for --sseReplicas." >&2
          usage
          exit 1
        fi
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --*)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
      *)
        if [[ -n "$positional_config" ]]; then
          echo "Unexpected positional argument: $1" >&2
          usage
          exit 1
        fi
        positional_config="$1"
        shift
        ;;
    esac
  done

  if [[ -n "$positional_config" ]]; then
    CONFIG_PATH="$positional_config"
  fi

  if [[ "${CONFIG_PATH}" != /* ]]; then
    CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH"
  fi
  CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
}

get_property() {
  local key="$1"
  local value

  value="$(sed -n "s/^${key}=//p" "$CONFIG_PATH" | tail -n 1)"
  if [[ -z "${value}" ]]; then
    echo "Missing property '${key}' in $CONFIG_PATH" >&2
    exit 1
  fi

  printf '%s\n' "$value"
}

ensure_file_exists() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Required file not found: $path" >&2
    exit 1
  fi
}

ensure_non_empty_file() {
  local path="$1"
  ensure_file_exists "$path"
  if [[ ! -s "$path" ]]; then
    echo "File exists but is empty: $path" >&2
    exit 1
  fi
}

resolve_config_path() {
  local raw_path="$1"

  if [[ "$raw_path" = /* ]]; then
    printf '%s\n' "$raw_path"
  else
    printf '%s\n' "$CONFIG_DIR/$raw_path"
  fi
}

ensure_command_exists() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found on PATH: $command_name" >&2
    exit 1
  fi
}

place_path_in_run_dir() {
  local path="$1"
  local run_dir="$2"
  local filename directory

  directory="$(dirname "$path")"
  filename="$(basename "$path")"

  printf '%s/%s/%s\n' "$directory" "$run_dir" "$filename"
}

terminate_tracked_replicas() {
  local pid

  [[ "${#REPLICA_PIDS[@]}" -gt 0 ]] || return

  for pid in "${REPLICA_PIDS[@]:-}"; do
    [[ -n "$pid" ]] || continue
    terminate_process_tree "$pid" TERM
  done

  sleep 1

  for pid in "${REPLICA_PIDS[@]:-}"; do
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      terminate_process_tree "$pid" KILL
    fi
    wait "$pid" 2>/dev/null || true
  done
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

  trap - EXIT INT TERM
  if [[ "$CLEANUP_DONE" -eq 1 ]]; then
    exit "$exit_status"
  fi

  CLEANUP_DONE=1
  if [[ "${ABS_LOG_DIR:-}" != "" ]]; then
    echo "Cleaning up local benchmark processes..."
  fi

  if [[ -n "$ACTIVE_CLIENT_PID" ]]; then
    terminate_process_tree "$ACTIVE_CLIENT_PID" TERM 2>/dev/null
  fi
  terminate_tracked_replicas 2>/dev/null
  if [[ -n "$ACTIVE_CLIENT_PID" ]]; then
    terminate_process_tree "$ACTIVE_CLIENT_PID" KILL 2>/dev/null
    wait "$ACTIVE_CLIENT_PID" 2>/dev/null || true
  fi

  exit "$exit_status"
}

trap cleanup EXIT INT TERM

load_config() {
  ensure_file_exists "$CONFIG_PATH"

  DATASET_TYPE="$(get_property datasetType)"

  REPLICA_COUNT="$(get_property sseReplicas)"
  if [[ -n "$REPLICA_COUNT_OVERRIDE" ]]; then
    REPLICA_COUNT="$REPLICA_COUNT_OVERRIDE"
    REPLICA_COUNT_SOURCE="CLI override"
  else
    REPLICA_COUNT_SOURCE="config"
  fi
  ORAM_REPLICA_COUNT="$(get_property oramReplicas)"
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

  EXPECTED_SAMPLES_PER_BUCKET=$((WARMUP_PER_BUCKET + MEASUREMENTS_PER_BUCKET))

  ABS_DATASET_PATH="$(resolve_config_path "$INPUT_PATH")"
  ABS_VOCABULARY_PATH="$(resolve_config_path "$VOCABULARY_PATH")"
  BASE_OUTPUT_PATH="$(resolve_config_path "$OUTPUT_PATH")"
  BASE_SUMMARY_PATH="$(resolve_config_path "$SUMMARY_OUTPUT_PATH")"
  BASE_MEAN_PLOT_PATH="$(resolve_config_path "$MEAN_PLOT_OUTPUT_PATH")"
  BASE_MEDIAN_PLOT_PATH="$(resolve_config_path "$MEDIAN_PLOT_OUTPUT_PATH")"
  ABS_GNUPLOT_SCRIPT="$ROOT_DIR/benchmarkSSE/gnuplot/search/search_latency_by_docs_mean_median.gp"
  ABS_SUMMARIZE_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/search/summarize_search_latency.py"
  ABS_SYNTHETIC_DATASET_SCRIPT="$ROOT_DIR/benchmarkSSE/scripts/datasets/syntheticDataset.py"

  validate_dataset_config
  validate_positive_integer "$REPLICA_COUNT" "sseReplicas"
  validate_minimum_replica_count "$REPLICA_COUNT" "sseReplicas"
  if [[ "$ORAM_REPLICA_COUNT" == "-1" ]]; then
    ORAM_REPLICA_COUNT="$REPLICA_COUNT"
  fi
  validate_positive_integer "$ORAM_REPLICA_COUNT" "oramReplicas"
  validate_minimum_replica_count "$ORAM_REPLICA_COUNT" "oramReplicas"
  validate_positive_integer "$ORAM_MAX_CONCURRENT_CLIENTS" "oramMaxConcurrentClients"
  SSE_TTP_PORT=$((11000 + REPLICA_COUNT * 10))
  ORAM_TTP_PORT=$((12000 + ORAM_REPLICA_COUNT * 10))
  if (( SSE_TTP_PORT >= 12000 || ORAM_TTP_PORT > 65535 )); then
    echo "Replica counts exceed the available local SSE/ORAM port ranges." >&2
    exit 1
  fi
  calculate_fault_count
  validate_positive_integer "$DEPLOY_CLIENT_COUNT" "deployClientCount"
  validate_positive_integer "$POPULATE_CLIENT_ID" "populateClientId"
  validate_positive_integer "$POPULATE_BATCH_SIZE" "populateBatchSize"
  validate_client_dir "$POPULATE_CLIENT_DIR" "populateClientDir"
  validate_client_dir "$BENCHMARK_CLIENT_DIR" "benchmarkClientDir"
  validate_boolean "$TIMESTAMP_OUTPUTS" "timestampOutputs"
  ensure_non_empty_file "$ABS_VOCABULARY_PATH"

  if [[ "$TIMESTAMP_OUTPUTS" == "true" ]]; then
    RUN_DATE="$(date +%d_%m_%Y)"
    RUN_NAME="$(date +%H_%M_%S)_r${REPLICA_COUNT}_o${ORAM_REPLICA_COUNT}"
  else
    RUN_DATE="$(date +%d_%m_%Y)"
    RUN_NAME="latest_r${REPLICA_COUNT}_o${ORAM_REPLICA_COUNT}"
  fi

  ABS_OUTPUT_PATH="$(place_path_in_run_dir "$BASE_OUTPUT_PATH" "$RUN_DATE/$RUN_NAME")"
  ABS_SUMMARY_PATH="$(place_path_in_run_dir "$BASE_SUMMARY_PATH" "$RUN_DATE/$RUN_NAME")"
  ABS_MEAN_PLOT_PATH="$(place_path_in_run_dir "$BASE_MEAN_PLOT_PATH" "$RUN_DATE/$RUN_NAME")"
  ABS_MEDIAN_PLOT_PATH="$(place_path_in_run_dir "$BASE_MEDIAN_PLOT_PATH" "$RUN_DATE/$RUN_NAME")"

  ABS_LOG_DIR="$ROOT_DIR/benchmarkSSE/results/logs/$RUN_DATE/$RUN_NAME"
  RUNTIME_CONFIG_PATH="$ABS_LOG_DIR/runtime_search_latency_by_docs.properties"
}

validate_dataset_config() {
  case "$DATASET_TYPE" in
    enron)
      load_enron_dataset_config
      ;;
    synthetic)
      load_synthetic_dataset_config
      ;;
    *)
      echo "datasetType must be either 'enron' or 'synthetic'." >&2
      exit 1
      ;;
  esac
}

load_enron_dataset_config() {
  PROCESSOR_MODE="$(get_property processorMode)"
  PROCESSOR_OUTPUT_PATH="$(get_property processorOutputPath)"
  PROCESSOR_BUCKETS="$(get_property processorBuckets)"
  PROCESSOR_SAMPLES_PER_BUCKET="$(get_property processorSamplesPerBucket)"
  BUCKETS="$PROCESSOR_BUCKETS"

  validate_positive_integer "$PROCESSOR_SAMPLES_PER_BUCKET" "processorSamplesPerBucket"
  if [[ "$PROCESSOR_SAMPLES_PER_BUCKET" -ne "$EXPECTED_SAMPLES_PER_BUCKET" ]]; then
    echo "processorSamplesPerBucket ($PROCESSOR_SAMPLES_PER_BUCKET) must equal warmupPerBucket + measurementsPerBucket ($EXPECTED_SAMPLES_PER_BUCKET)" >&2
    exit 1
  fi

  if [[ "$PROCESSOR_OUTPUT_PATH" != "$INPUT_PATH" ]]; then
    echo "processorOutputPath ($PROCESSOR_OUTPUT_PATH) must match inputPath ($INPUT_PATH)" >&2
    exit 1
  fi

  if [[ "$PROCESSOR_BUCKETS" != "$BUCKETS" ]]; then
    echo "processorBuckets ($PROCESSOR_BUCKETS) must match buckets ($BUCKETS)" >&2
    exit 1
  fi

  ABS_PROCESSOR_OUTPUT_PATH="$(resolve_config_path "$PROCESSOR_OUTPUT_PATH")"
  EXPECTED_DATASET_LINES=$((PROCESSOR_SAMPLES_PER_BUCKET * $(csv_item_count "$PROCESSOR_BUCKETS")))
}

load_synthetic_dataset_config() {
  SYNTHETIC_OUTPUT_PATH="$(get_property syntheticOutputPath)"
  SYNTHETIC_KEYWORDS_PER_DOC_COUNT="$(get_property syntheticKeywordsPerDocCount)"
  SYNTHETIC_DOC_COUNTS="$(get_property syntheticDocCounts)"
  SYNTHETIC_SEED="$(get_property syntheticSeed)"
  BUCKETS="$(doc_counts_to_buckets "$SYNTHETIC_DOC_COUNTS")"

  validate_positive_integer "$SYNTHETIC_KEYWORDS_PER_DOC_COUNT" "syntheticKeywordsPerDocCount"
  validate_integer "$SYNTHETIC_SEED" "syntheticSeed"
  validate_synthetic_doc_counts

  if [[ "$SYNTHETIC_KEYWORDS_PER_DOC_COUNT" -ne "$EXPECTED_SAMPLES_PER_BUCKET" ]]; then
    echo "syntheticKeywordsPerDocCount ($SYNTHETIC_KEYWORDS_PER_DOC_COUNT) must equal warmupPerBucket + measurementsPerBucket ($EXPECTED_SAMPLES_PER_BUCKET)" >&2
    exit 1
  fi

  if [[ "$SYNTHETIC_OUTPUT_PATH" != "$INPUT_PATH" ]]; then
    echo "syntheticOutputPath ($SYNTHETIC_OUTPUT_PATH) must match inputPath ($INPUT_PATH)" >&2
    exit 1
  fi

  ABS_SYNTHETIC_OUTPUT_PATH="$(resolve_config_path "$SYNTHETIC_OUTPUT_PATH")"
  EXPECTED_DATASET_LINES=$((SYNTHETIC_KEYWORDS_PER_DOC_COUNT * $(csv_item_count "$SYNTHETIC_DOC_COUNTS")))
}

validate_positive_integer() {
  local value="$1"
  local label="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
    echo "Property $label must be a positive integer." >&2
    exit 1
  fi
}

validate_integer() {
  local value="$1"
  local label="$2"

  if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
    echo "Property $label must be an integer." >&2
    exit 1
  fi
}

csv_item_count() {
  local raw_list="$1"
  local compact_list

  compact_list="$(normalize_csv_list "$raw_list")"
  if [[ -z "$compact_list" ]]; then
    printf '0\n'
    return
  fi

  printf '%s\n' "$compact_list" | awk -F',' '{print NF}'
}

normalize_csv_list() {
  local raw_list="$1"
  printf '%s' "$raw_list" | tr -d '[:space:]'
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
    validate_positive_integer "$doc_count" "syntheticDocCounts"
    [[ -z "$buckets" ]] || buckets+=","
    buckets+="${doc_count}:${doc_count}"
  done

  printf '%s\n' "$buckets"
}

validate_synthetic_doc_counts() {
  local compact_doc_counts compact_buckets doc_count bucket bucket_min bucket_max
  local matching_bucket found_doc_count

  compact_doc_counts="$(normalize_csv_list "$SYNTHETIC_DOC_COUNTS")"
  compact_buckets="$(normalize_csv_list "$BUCKETS")"

  if [[ -z "$compact_doc_counts" ]]; then
    echo "syntheticDocCounts cannot be empty." >&2
    exit 1
  fi
  if [[ -z "$compact_buckets" ]]; then
    echo "buckets cannot be empty." >&2
    exit 1
  fi

  IFS=',' read -r -a SYNTHETIC_DOC_COUNT_VALUES <<< "$compact_doc_counts"
  IFS=',' read -r -a BUCKET_VALUES <<< "$compact_buckets"

  for doc_count in "${SYNTHETIC_DOC_COUNT_VALUES[@]}"; do
    validate_positive_integer "$doc_count" "syntheticDocCounts"
    matching_bucket=0
    for bucket in "${BUCKET_VALUES[@]}"; do
      parse_bucket "$bucket"
      if (( doc_count >= bucket_min && doc_count <= bucket_max )); then
        matching_bucket=1
        break
      fi
    done

    if [[ "$matching_bucket" -eq 0 ]]; then
      echo "syntheticDocCounts value $doc_count does not fit any configured bucket ($BUCKETS)." >&2
      exit 1
    fi
  done

  for bucket in "${BUCKET_VALUES[@]}"; do
    parse_bucket "$bucket"
    found_doc_count=0
    for doc_count in "${SYNTHETIC_DOC_COUNT_VALUES[@]}"; do
      if (( doc_count >= bucket_min && doc_count <= bucket_max )); then
        found_doc_count=1
        break
      fi
    done

    if [[ "$found_doc_count" -eq 0 ]]; then
      echo "Bucket $bucket has no matching syntheticDocCounts value." >&2
      exit 1
    fi
  done

  SYNTHETIC_DOC_COUNTS="$compact_doc_counts"
}

parse_bucket() {
  local bucket="$1"
  local parts

  if [[ "$bucket" != *:* || "$bucket" == *:*:* ]]; then
    echo "Invalid bucket definition: $bucket" >&2
    exit 1
  fi

  IFS=':' read -r -a parts <<< "$bucket"
  bucket_min="${parts[0]}"
  bucket_max="${parts[1]}"
  validate_positive_integer "$bucket_min" "bucket min"
  validate_positive_integer "$bucket_max" "bucket max"

  if (( bucket_min > bucket_max )); then
    echo "Invalid bucket definition with min greater than max: $bucket" >&2
    exit 1
  fi
}

validate_minimum_replica_count() {
  local replica_count="$1"
  local label="$2"

  if [[ "$replica_count" -lt 4 ]]; then
    echo "$label must be at least 4 for this BFT benchmark." >&2
    exit 1
  fi
}

calculate_fault_count() {
  FAULT_COUNT=$(((REPLICA_COUNT - 1) / 3))
}

validate_boolean() {
  local value="$1"
  local label="$2"

  if [[ "$value" != "true" && "$value" != "false" ]]; then
    echo "Property $label must be either true or false." >&2
    exit 1
  fi
}

validate_client_dir() {
  local dir_name="$1"
  local label="$2"
  local client_index

  if [[ ! "$dir_name" =~ ^cli([0-9]+)$ ]]; then
    echo "Property $label must use the format cliN." >&2
    exit 1
  fi

  client_index="${BASH_REMATCH[1]}"
  if (( client_index >= DEPLOY_CLIENT_COUNT )); then
    echo "Property $label ($dir_name) requires deployClientCount greater than $client_index." >&2
    exit 1
  fi
}

prepare_directories() {
  mkdir -p "$ABS_LOG_DIR"
  mkdir -p "$(dirname "$ABS_OUTPUT_PATH")"
  mkdir -p "$(dirname "$ABS_SUMMARY_PATH")"
  mkdir -p "$(dirname "$ABS_MEAN_PLOT_PATH")"
  mkdir -p "$(dirname "$ABS_MEDIAN_PLOT_PATH")"
}

write_runtime_config() {
  local wrote_buckets=0

  echo "Writing runtime benchmark config..."
  {
    printf '# Runtime benchmark metadata generated by %s\n' "$(basename "$0")"
    printf 'runtimeSseReplicas=%s\n' "$REPLICA_COUNT"
    printf 'runtimeOramReplicas=%s\n' "$ORAM_REPLICA_COUNT"
    printf 'runtimeOramMaxConcurrentClients=%s\n' "$ORAM_MAX_CONCURRENT_CLIENTS"
    printf 'runtimeFaultCount=%s\n' "$FAULT_COUNT"
    printf 'runtimeSseReplicasSource=%s\n' "$REPLICA_COUNT_SOURCE"
    while IFS= read -r line; do
      case "$line" in
        sseReplicas=*)
          printf 'sseReplicas=%s\n' "$REPLICA_COUNT"
          ;;
        inputPath=*)
          printf 'inputPath=%s\n' "$ABS_DATASET_PATH"
          ;;
        outputPath=*)
          printf 'outputPath=%s\n' "$ABS_OUTPUT_PATH"
          ;;
        vocabularyPath=*)
          printf 'vocabularyPath=%s\n' "$ABS_VOCABULARY_PATH"
          ;;
        summaryOutputPath=*)
          printf 'summaryOutputPath=%s\n' "$ABS_SUMMARY_PATH"
          ;;
        meanPlotOutputPath=*)
          printf 'meanPlotOutputPath=%s\n' "$ABS_MEAN_PLOT_PATH"
          ;;
        medianPlotOutputPath=*)
          printf 'medianPlotOutputPath=%s\n' "$ABS_MEDIAN_PLOT_PATH"
          ;;
        buckets=*)
          printf 'buckets=%s\n' "$BUCKETS"
          wrote_buckets=1
          ;;
        *)
          printf '%s\n' "$line"
          ;;
      esac
    done < "$CONFIG_PATH"
    if [[ "$wrote_buckets" -eq 0 ]]; then
      printf 'buckets=%s\n' "$BUCKETS"
    fi
  } > "$RUNTIME_CONFIG_PATH"

  ensure_non_empty_file "$RUNTIME_CONFIG_PATH"
}

validate_existing_dataset() {
  ensure_non_empty_file "$ABS_DATASET_PATH"

  if [[ "$(wc -l < "$ABS_DATASET_PATH")" -ne "$EXPECTED_DATASET_LINES" ]]; then
    echo "Existing dataset line count does not match expected total entries." >&2
    return 1
  fi

  return 0
}

generate_dataset() {
  if [[ -f "$ABS_DATASET_PATH" ]] && validate_existing_dataset; then
    echo "Reusing existing benchmark dataset at $ABS_DATASET_PATH."
    return
  fi

  case "$DATASET_TYPE" in
    enron)
      generate_enron_dataset
      ;;
    synthetic)
      generate_synthetic_dataset
      ;;
    *)
      echo "datasetType must be either 'enron' or 'synthetic'." >&2
      exit 1
      ;;
  esac

  if ! validate_existing_dataset; then
    echo "Generated dataset does not match the configured benchmark buckets." >&2
    exit 1
  fi
}

generate_enron_dataset() {
  echo "Generating Enron benchmark dataset..."
  (
    cd "$ROOT_DIR"
    ./gradlew processEnronDataset \
      -Pmode="$PROCESSOR_MODE" \
      -Poutput="$ABS_PROCESSOR_OUTPUT_PATH" \
      -PbucketSpec="$PROCESSOR_BUCKETS" \
      -PsamplesPerBucket="$PROCESSOR_SAMPLES_PER_BUCKET"
  )
}

generate_synthetic_dataset() {
  ensure_command_exists python3
  ensure_file_exists "$ABS_SYNTHETIC_DATASET_SCRIPT"

  echo "Generating synthetic benchmark dataset..."
  (
    cd "$ROOT_DIR"
    python3 "$ABS_SYNTHETIC_DATASET_SCRIPT" \
      --output "$ABS_SYNTHETIC_OUTPUT_PATH" \
      --vocabulary "$ABS_VOCABULARY_PATH" \
      --keywords-per-doc-count "$SYNTHETIC_KEYWORDS_PER_DOC_COUNT" \
      --doc-counts "$SYNTHETIC_DOC_COUNTS" \
      --seed "$SYNTHETIC_SEED"
  )
}

check_local_ports() {
  local replica_id port

  ensure_command_exists lsof
  for (( replica_id = 0; replica_id < REPLICA_COUNT; replica_id++ )); do
    for port in $((11000 + replica_id * 10)) $((11001 + replica_id * 10)); do
      if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "Local SSE port $port is already in use. Stop the existing service before running this benchmark." >&2
        exit 1
      fi
    done
  done
  for (( replica_id = 0; replica_id < ORAM_REPLICA_COUNT; replica_id++ )); do
    for port in $((12000 + replica_id * 10)) $((12001 + replica_id * 10)); do
      if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "Local ORAM port $port is already in use. Stop the existing service before running this benchmark." >&2
        exit 1
      fi
    done
  done
  for port in "$SSE_TTP_PORT" "$ORAM_TTP_PORT"; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "Local TTP port $port is already in use. Stop the existing service before running this benchmark." >&2
      exit 1
    fi
  done
}

prepare_local_deploy() {
  echo "Preparing clean local deployment..."
  (
    cd "$ROOT_DIR"
    ./gradlew clean localDeploy -Pservers="$REPLICA_COUNT" -PoramServers="$ORAM_REPLICA_COUNT" -Pclients="$DEPLOY_CLIENT_COUNT"
  )
}

initial_view() {
  local replica_count="$1"
  local replica_id
  local view=""

  for (( replica_id = 0; replica_id < replica_count; replica_id++ )); do
    if [[ -n "$view" ]]; then
      view+=","
    fi
    view+="$replica_id"
  done

  printf '%s\n' "$view"
}

write_local_system_config() {
  local path="$1"
  local replica_count="$2"
  local view="$3"
  local tmp_path="${path}.tmp"

  awk \
    -v replica_count="$replica_count" \
    -v fault_count="$(((replica_count - 1) / 3))" \
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

write_local_hosts_config() {
  local path="$1"
  local replica_count="$2"
  local base_port="$3"
  local ttp_port="$4"
  local tmp_path="${path}.tmp"
  local replica_id client_port server_port

  {
    printf '# This hosts.config was generated by %s for the local benchmark deploy.\n' "$(basename "$0")"
    printf '#server id, address and port (the ids from 0 to n-1 are the service replicas)\n'
    for (( replica_id = 0; replica_id < replica_count; replica_id++ )); do
      client_port=$((base_port + replica_id * 10))
      server_port=$((client_port + 1))
      printf '%s 127.0.0.1 %s %s\n' "$replica_id" "$client_port" "$server_port"
    done
    printf '\n'
    printf '7002 127.0.0.1 %s\n' "$ttp_port"
  } > "$tmp_path"
  mv "$tmp_path" "$path"
}

configure_local_deploy() {
  local sse_view oram_view
  local deploy_dir
  local deploy_index

  echo "Configuring local deployment for $REPLICA_COUNT SSE and $ORAM_REPLICA_COUNT ORAM replicas..."
  sse_view="$(initial_view "$REPLICA_COUNT")"
  oram_view="$(initial_view "$ORAM_REPLICA_COUNT")"

  for (( deploy_index = 0; deploy_index < REPLICA_COUNT; deploy_index++ )); do
    deploy_dir="$ROOT_DIR/build/local/rep${deploy_index}"
    ensure_file_exists "$deploy_dir/config/system.config"
    ensure_file_exists "$deploy_dir/config/hosts.config"
    write_local_system_config "$deploy_dir/config/system.config" "$REPLICA_COUNT" "$sse_view"
    write_local_hosts_config "$deploy_dir/config/hosts.config" "$REPLICA_COUNT" 11000 "$SSE_TTP_PORT"
  done

  for (( deploy_index = 0; deploy_index < ORAM_REPLICA_COUNT; deploy_index++ )); do
    deploy_dir="$ROOT_DIR/build/local/oramRep${deploy_index}"
    ensure_file_exists "$deploy_dir/config/system.config"
    ensure_file_exists "$deploy_dir/config/hosts.config"
    write_local_system_config "$deploy_dir/config/system.config" "$ORAM_REPLICA_COUNT" "$oram_view"
    write_local_hosts_config "$deploy_dir/config/hosts.config" "$ORAM_REPLICA_COUNT" 12000 "$ORAM_TTP_PORT"
  done

  for (( deploy_index = 0; deploy_index < DEPLOY_CLIENT_COUNT; deploy_index++ )); do
    deploy_dir="$ROOT_DIR/build/local/cli${deploy_index}"
    ensure_file_exists "$deploy_dir/config/system.config"
    ensure_file_exists "$deploy_dir/config/hosts.config"
    ensure_file_exists "$deploy_dir/sse_config/system.config"
    ensure_file_exists "$deploy_dir/sse_config/hosts.config"
    write_local_system_config "$deploy_dir/sse_config/system.config" "$REPLICA_COUNT" "$sse_view"
    write_local_hosts_config "$deploy_dir/sse_config/hosts.config" "$REPLICA_COUNT" 11000 "$SSE_TTP_PORT"
    write_local_system_config "$deploy_dir/config/system.config" "$ORAM_REPLICA_COUNT" "$oram_view"
    write_local_hosts_config "$deploy_dir/config/hosts.config" "$ORAM_REPLICA_COUNT" 12000 "$ORAM_TTP_PORT"
  done
}

start_replicas() {
  local replica_id

  echo "Starting ORAM replicas..."
  REPLICA_PIDS=()
  for (( replica_id = 0; replica_id < ORAM_REPLICA_COUNT; replica_id++ )); do
    (
      cd "$ROOT_DIR/build/local/oramRep${replica_id}"
      exec bash smartrun.sh oram.server.ORAMServer "$ORAM_MAX_CONCURRENT_CLIENTS" "$replica_id"
    ) >"$ABS_LOG_DIR/oramRep${replica_id}.log" 2>&1 &
    REPLICA_PIDS+=("$!")
  done

  echo "Starting SSE replicas..."
  for (( replica_id = 0; replica_id < REPLICA_COUNT; replica_id++ )); do
    (
      cd "$ROOT_DIR/build/local/rep${replica_id}"
      exec bash smartrun.sh sse.demo.server.Server "$replica_id"
    ) >"$ABS_LOG_DIR/rep${replica_id}.log" 2>&1 &
    REPLICA_PIDS+=("$!")
  done
}

wait_for_replicas_ready() {
  local timeout_seconds=60
  local deadline=$((SECONDS + timeout_seconds))
  local replica_id pid
  local ready

  echo "Waiting for replicas to become ready..."
  while (( SECONDS < deadline )); do
    ready=1
    for pid in "${REPLICA_PIDS[@]}"; do
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "A replica exited before becoming ready; inspect logs in $ABS_LOG_DIR." >&2
        exit 1
      fi
    done
    for (( replica_id = 0; replica_id < ORAM_REPLICA_COUNT; replica_id++ )); do
      if ! grep -q "Ready to process operations" "$ABS_LOG_DIR/oramRep${replica_id}.log" 2>/dev/null; then
        ready=0
        break
      fi
    done
    for (( replica_id = 0; replica_id < REPLICA_COUNT; replica_id++ )); do
      if ! grep -q "Ready to process operations" "$ABS_LOG_DIR/rep${replica_id}.log" 2>/dev/null; then
        ready=0
        break
      fi
    done

    if [[ "$ready" -eq 1 ]]; then
      echo "All replicas are ready."
      return
    fi

    sleep 1
  done

  echo "Timed out while waiting for replicas to become ready." >&2
  for (( replica_id = 0; replica_id < ORAM_REPLICA_COUNT; replica_id++ )); do
    echo "--- oramRep${replica_id}.log (tail) ---" >&2
    tail -n 20 "$ABS_LOG_DIR/oramRep${replica_id}.log" >&2 || true
  done
  for (( replica_id = 0; replica_id < REPLICA_COUNT; replica_id++ )); do
    echo "--- rep${replica_id}.log (tail) ---" >&2
    tail -n 20 "$ABS_LOG_DIR/rep${replica_id}.log" >&2 || true
  done
  exit 1
}

run_populate() {
  echo "Running PopulateDB..."
  (
    cd "$ROOT_DIR/build/local/$POPULATE_CLIENT_DIR"
    exec bash smartrun.sh sse.populatedb.PopulateDB \
      --client-id "$POPULATE_CLIENT_ID" \
      --input "$ABS_DATASET_PATH" \
      --batch-size "$POPULATE_BATCH_SIZE" \
      --vocabulary "$ABS_VOCABULARY_PATH"
  ) >"$ABS_LOG_DIR/populate.log" 2>&1 &
  ACTIVE_CLIENT_PID="$!"
  wait_for_active_client

  if ! grep -q "PopulateDB finished." "$ABS_LOG_DIR/populate.log"; then
    echo "PopulateDB did not finish successfully." >&2
    tail -n 40 "$ABS_LOG_DIR/populate.log" >&2 || true
    exit 1
  fi
}

wait_for_active_client() {
  local exit_status=0

  wait "$ACTIVE_CLIENT_PID" || exit_status=$?
  ACTIVE_CLIENT_PID=""
  return "$exit_status"
}

run_benchmark() {
  echo "Running benchmark client..."
  (
    cd "$ROOT_DIR/build/local/$BENCHMARK_CLIENT_DIR"
    exec bash smartrun.sh sse.benchmark.BenchmarkClient "$RUNTIME_CONFIG_PATH"
  ) >"$ABS_LOG_DIR/benchmark.log" 2>&1 &
  ACTIVE_CLIENT_PID="$!"
  wait_for_active_client
}

verify_results() {
  local bucket_count expected_rows actual_rows

  ensure_non_empty_file "$ABS_OUTPUT_PATH"

  bucket_count="$(csv_item_count "$BUCKETS")"
  expected_rows=$((bucket_count * MEASUREMENTS_PER_BUCKET))
  actual_rows=$(( $(wc -l < "$ABS_OUTPUT_PATH") - 1 ))
  if (( actual_rows != expected_rows )); then
    echo "Expected $expected_rows search measurements, found $actual_rows in $ABS_OUTPUT_PATH." >&2
    exit 1
  fi

  echo "Benchmark results written to $ABS_OUTPUT_PATH ($actual_rows measurements)."
}

summarize_results() {
  ensure_command_exists python3
  ensure_non_empty_file "$ABS_OUTPUT_PATH"
  ensure_file_exists "$ABS_SUMMARIZE_SCRIPT"

  echo "Generating summary TSV..."
  (
    cd "$ROOT_DIR"
    python3 "$ABS_SUMMARIZE_SCRIPT" --input "$ABS_OUTPUT_PATH" --output "$ABS_SUMMARY_PATH"
  )
}

verify_summary() {
  local bucket_count expected_rows actual_rows

  ensure_non_empty_file "$ABS_SUMMARY_PATH"

  bucket_count="$(csv_item_count "$BUCKETS")"
  expected_rows=$((bucket_count * N_METRICS))
  actual_rows=$(( $(wc -l < "$ABS_SUMMARY_PATH") - 1 ))
  if (( actual_rows != expected_rows )); then
    echo "Expected $expected_rows metric summary rows, found $actual_rows in $ABS_SUMMARY_PATH." >&2
    exit 1
  fi

  echo "Summary written to $ABS_SUMMARY_PATH ($actual_rows metric rows)."
}

generate_plots() {
  ensure_command_exists gnuplot
  ensure_non_empty_file "$ABS_SUMMARY_PATH"
  ensure_file_exists "$ABS_GNUPLOT_SCRIPT"

  echo "Generating plots..."
  (
    cd "$ROOT_DIR"
    gnuplot \
      -e "input_path='$ABS_SUMMARY_PATH'; mean_output_path='$ABS_MEAN_PLOT_PATH'; median_output_path='$ABS_MEDIAN_PLOT_PATH'" \
      "$ABS_GNUPLOT_SCRIPT"
  )
}

verify_plots() {
  ensure_non_empty_file "$ABS_MEAN_PLOT_PATH"
  ensure_non_empty_file "$ABS_MEDIAN_PLOT_PATH"

  echo "Mean plot written to $ABS_MEAN_PLOT_PATH."
  echo "Median plot written to $ABS_MEDIAN_PLOT_PATH."
}

main() {
  parse_args "$@"
  load_config
  prepare_directories
  write_runtime_config
  generate_dataset
  check_local_ports
  prepare_local_deploy
  configure_local_deploy
  start_replicas
  wait_for_replicas_ready
  run_populate
  run_benchmark
  verify_results
  summarize_results
  verify_summary
  generate_plots
  verify_plots
}

main "$@"
