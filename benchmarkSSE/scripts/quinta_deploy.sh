#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_CLUSTER_CONFIG="$ROOT_DIR/benchmarkSSE/config/quinta.env"

COMMAND=""
CLUSTER_CONFIG="$DEFAULT_CLUSTER_CONFIG"
SSE_REPLICA_COUNT=10
ORAM_REPLICA_COUNT=-1
ORAM_MAX_CONCURRENT_CLIENTS=1
CLIENT_COUNT=1
RUN_NAME="latest"
BENCHMARK_CHECKPOINT_PERIOD=10000000

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  layout      Show replica/client placement.
  prepare-local  Build and validate local deploy folders without contacting Quinta.
  preflight   Check SSH, Java, IPs, disk, and relevant ports.
  deploy      Build local deploy, configure it, and copy it to Quinta.
  start       Start remote replicas.
  wait        Wait for all replicas to become ready.
  status      Show remote process status and log tails.
  stop        Stop remote replicas for the run.
  clean       Remove the remote run directory.
  preclean    Stop stale Quinta benchmark processes, free run ports, and remove the remote run directory.

Options:
  --cluster-config PATH  Default: benchmarkSSE/config/quinta.env
  --sseReplicas N        Default: 10
  --oramReplicas N       Default: match SSE
  --oramMaxConcurrentClients N  Default: 1
  --clients N            Default: 1
  --run-name NAME        Default: latest
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

ssh_remote() {
  ssh -n \
    -o BatchMode=yes \
    -o ConnectTimeout="${QUINTA_SSH_CONNECT_TIMEOUT_SECONDS:-10}" \
    -o ServerAliveInterval="${QUINTA_SSH_SERVER_ALIVE_INTERVAL_SECONDS:-5}" \
    -o ServerAliveCountMax="${QUINTA_SSH_SERVER_ALIVE_COUNT_MAX:-2}" \
    "$@"
}

rsync_remote() {
  rsync -az --delete \
    -e "ssh -o BatchMode=yes -o ConnectTimeout=${QUINTA_SSH_CONNECT_TIMEOUT_SECONDS:-10} -o ServerAliveInterval=${QUINTA_SSH_SERVER_ALIVE_INTERVAL_SECONDS:-5} -o ServerAliveCountMax=${QUINTA_SSH_SERVER_ALIVE_COUNT_MAX:-2}" \
    "$@"
}

parse_args() {
  if [[ "$#" -lt 1 ]]; then
    usage
    exit 1
  fi

  COMMAND="$1"
  shift

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
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
        SSE_REPLICA_COUNT="$2"
        shift 2
        ;;
      --sseReplicas=*)
        SSE_REPLICA_COUNT="${1#--sseReplicas=}"
        [[ -n "$SSE_REPLICA_COUNT" ]] || die "Missing value for --sseReplicas"
        shift
        ;;
      --oramReplicas)
        [[ "$#" -ge 2 && "$2" != --* ]] || die "Missing value for --oramReplicas"
        ORAM_REPLICA_COUNT="$2"
        shift 2
        ;;
      --oramReplicas=*)
        ORAM_REPLICA_COUNT="${1#--oramReplicas=}"
        [[ -n "$ORAM_REPLICA_COUNT" ]] || die "Missing value for --oramReplicas"
        shift
        ;;
      --oramMaxConcurrentClients)
        [[ "$#" -ge 2 && "$2" != --* ]] || die "Missing value for --oramMaxConcurrentClients"
        ORAM_MAX_CONCURRENT_CLIENTS="$2"
        shift 2
        ;;
      --oramMaxConcurrentClients=*)
        ORAM_MAX_CONCURRENT_CLIENTS="${1#--oramMaxConcurrentClients=}"
        [[ -n "$ORAM_MAX_CONCURRENT_CLIENTS" ]] || die "Missing value for --oramMaxConcurrentClients"
        shift
        ;;
      --clients)
        [[ "$#" -ge 2 ]] || die "Missing value for --clients"
        CLIENT_COUNT="$2"
        shift 2
        ;;
      --clients=*)
        CLIENT_COUNT="${1#--clients=}"
        [[ -n "$CLIENT_COUNT" ]] || die "Missing value for --clients"
        shift
        ;;
      --run-name)
        [[ "$#" -ge 2 ]] || die "Missing value for --run-name"
        RUN_NAME="$2"
        shift 2
        ;;
      --run-name=*)
        RUN_NAME="${1#--run-name=}"
        [[ -n "$RUN_NAME" ]] || die "Missing value for --run-name"
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
}

load_cluster_config() {
  if [[ "$CLUSTER_CONFIG" != /* ]]; then
    CLUSTER_CONFIG="$ROOT_DIR/$CLUSTER_CONFIG"
  fi
  [[ -f "$CLUSTER_CONFIG" ]] || die "Cluster config not found: $CLUSTER_CONFIG"
  # shellcheck source=/dev/null
  source "$CLUSTER_CONFIG"

  [[ "${#QUINTA_NODES[@]}" -gt 0 ]] || die "QUINTA_NODES cannot be empty"
  [[ "${#QUINTA_NODES[@]}" -eq "${#QUINTA_NODE_IPS[@]}" ]] || die "QUINTA_NODES and QUINTA_NODE_IPS must have the same length"
  validate_positive_integer "$SSE_REPLICA_COUNT" "sseReplicas"
  [[ "$SSE_REPLICA_COUNT" -ge 4 ]] || die "sseReplicas must be at least 4"
  if [[ "$ORAM_REPLICA_COUNT" == "-1" ]]; then
    ORAM_REPLICA_COUNT="$SSE_REPLICA_COUNT"
  fi
  validate_positive_integer "$ORAM_REPLICA_COUNT" "oramReplicas"
  [[ "$ORAM_REPLICA_COUNT" -ge 4 ]] || die "oramReplicas must be at least 4"
  validate_replica_capacity
  validate_positive_integer "$ORAM_MAX_CONCURRENT_CLIENTS" "oramMaxConcurrentClients"
  validate_positive_integer "$CLIENT_COUNT" "clients"
  validate_positive_integer "$QUINTA_BASE_CLIENT_PORT" "QUINTA_BASE_CLIENT_PORT"
  validate_positive_integer "$QUINTA_ORAM_BASE_CLIENT_PORT" "QUINTA_ORAM_BASE_CLIENT_PORT"
  validate_positive_integer "$QUINTA_PORT_STEP" "QUINTA_PORT_STEP"
  validate_positive_integer "$QUINTA_TTP_PORT" "QUINTA_TTP_PORT"
  validate_positive_integer "$QUINTA_ORAM_TTP_PORT" "QUINTA_ORAM_TTP_PORT"
  [[ "$QUINTA_PORT_STEP" -ge 3 ]] || die "QUINTA_PORT_STEP must be at least 3 for SSE/ORAM replicas"
  validate_port_ranges
  [[ "$RUN_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "run-name may only contain letters, numbers, dot, underscore, and dash"
}

validate_replica_capacity() {
  local max_replicas
  max_replicas=$((${#QUINTA_NODES[@]} - 1))

  (( SSE_REPLICA_COUNT <= max_replicas )) \
    || die "sseReplicas cannot exceed $max_replicas: one Quinta node must remain reserved for clients"
  (( ORAM_REPLICA_COUNT <= max_replicas )) \
    || die "oramReplicas cannot exceed $max_replicas: one Quinta node must remain reserved for clients"
}

validate_port_ranges() {
  local node_count_value="${#QUINTA_NODES[@]}"
  local sse_last_port oram_last_port

  # COBRA also listens one port after the replica-to-replica port.
  sse_last_port=$((QUINTA_BASE_CLIENT_PORT + ((SSE_REPLICA_COUNT - 1) / node_count_value) * QUINTA_PORT_STEP + 2))
  oram_last_port=$((QUINTA_ORAM_BASE_CLIENT_PORT + ((ORAM_REPLICA_COUNT - 1) / node_count_value) * QUINTA_PORT_STEP + 2))

  (( sse_last_port < QUINTA_TTP_PORT && QUINTA_TTP_PORT < QUINTA_ORAM_BASE_CLIENT_PORT )) \
    || die "SSE replica, SSE TTP, and ORAM port ranges overlap"
  (( oram_last_port < QUINTA_ORAM_TTP_PORT && QUINTA_ORAM_TTP_PORT <= 65535 )) \
    || die "ORAM replica and ORAM TTP port ranges overlap or exceed 65535"
}

validate_positive_integer() {
  local value="$1"
  local label="$2"
  [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]] || die "$label must be a positive integer"
}

node_count() {
  printf '%s\n' "${#QUINTA_NODES[@]}"
}

node_ip() {
  local node="$1"
  local node_index
  for node_index in "${!QUINTA_NODES[@]}"; do
    if [[ "${QUINTA_NODES[$node_index]}" == "$node" ]]; then
      printf '%s\n' "${QUINTA_NODE_IPS[$node_index]}"
      return
    fi
  done
  die "Unknown Quinta node: $node"
}

fault_count() {
  local replica_count="${1:-$SSE_REPLICA_COUNT}"
  printf '%s\n' $(((replica_count - 1) / 3))
}

initial_view() {
  local replica_count="${1:-$SSE_REPLICA_COUNT}"
  local replica_id view=""
  for (( replica_id = 0; replica_id < replica_count; replica_id++ )); do
    [[ -z "$view" ]] || view+=","
    view+="$replica_id"
  done
  printf '%s\n' "$view"
}

replica_node_index() {
  local replica_id="$1"
  printf '%s\n' $((replica_id % $(node_count)))
}

replica_slot_on_node() {
  local replica_id="$1"
  printf '%s\n' $((replica_id / $(node_count)))
}

replica_node() {
  local node_index
  node_index="$(replica_node_index "$1")"
  printf '%s\n' "${QUINTA_NODES[$node_index]}"
}

replica_ip() {
  local node_index
  node_index="$(replica_node_index "$1")"
  printf '%s\n' "${QUINTA_NODE_IPS[$node_index]}"
}

replica_client_port() {
  local slot
  slot="$(replica_slot_on_node "$1")"
  printf '%s\n' $((QUINTA_BASE_CLIENT_PORT + slot * QUINTA_PORT_STEP))
}

replica_server_port() {
  printf '%s\n' $(($(replica_client_port "$1") + 1))
}

oram_replica_client_port() {
  local slot
  slot="$(replica_slot_on_node "$1")"
  printf '%s\n' $((QUINTA_ORAM_BASE_CLIENT_PORT + slot * QUINTA_PORT_STEP))
}

oram_replica_server_port() {
  printf '%s\n' $(($(oram_replica_client_port "$1") + 1))
}

client_node() {
  local node_index="$SSE_REPLICA_COUNT"
  (( ORAM_REPLICA_COUNT <= node_index )) || node_index="$ORAM_REPLICA_COUNT"
  printf '%s\n' "${QUINTA_NODES[$node_index]}"
}

ssh_host() {
  printf '%s%s\n' "$QUINTA_SSH_PREFIX" "$1"
}

remote_run_dir() {
  printf '%s/%s\n' "$QUINTA_REMOTE_ROOT" "$RUN_NAME"
}

remote_replica_dir() {
  printf '%s/rep%s\n' "$(remote_run_dir)" "$1"
}

remote_oram_replica_dir() {
  printf '%s/oramRep%s\n' "$(remote_run_dir)" "$1"
}

remote_client_dir() {
  printf '%s/cli%s\n' "$(remote_run_dir)" "$1"
}

print_layout() {
  local replica_id client_index

  echo "Run: $RUN_NAME"
  echo "SSE replicas: $SSE_REPLICA_COUNT (f=$(fault_count))"
  echo "ORAM replicas: $ORAM_REPLICA_COUNT"
  echo "ORAM max concurrent clients: $ORAM_MAX_CONCURRENT_CLIENTS"
  echo "Clients: $CLIENT_COUNT"
  echo "Remote root: $(remote_run_dir)"
  echo "Ports shown below are client/server; COBRA also uses server port + 1."
  echo
  echo "SSE replicas:"
  for (( replica_id = 0; replica_id < SSE_REPLICA_COUNT; replica_id++ )); do
    printf '  rep%-3s -> %-4s %-13s %s/%s\n' \
      "$replica_id" "$(replica_node "$replica_id")" "$(replica_ip "$replica_id")" \
      "$(replica_client_port "$replica_id")" "$(replica_server_port "$replica_id")"
  done
  echo
  echo "ORAM replicas:"
  for (( replica_id = 0; replica_id < ORAM_REPLICA_COUNT; replica_id++ )); do
    printf '  oramRep%-3s -> %-4s %-13s %s/%s\n' \
      "$replica_id" "$(replica_node "$replica_id")" "$(replica_ip "$replica_id")" \
      "$(oram_replica_client_port "$replica_id")" "$(oram_replica_server_port "$replica_id")"
  done
  echo
  echo "Clients:"
  for (( client_index = 0; client_index < CLIENT_COUNT; client_index++ )); do
    printf '  cli%-3s -> %s\n' "$client_index" "$(client_node "$client_index")"
  done
}

write_system_config() {
  local path="$1"
  local replica_count="$2"
  local tmp_path="${path}.tmp"
  awk \
    -v replica_count="$replica_count" \
    -v fault_count_value="$(fault_count "$replica_count")" \
    -v initial_view_value="$(initial_view "$replica_count")" \
    -v checkpoint_period="$BENCHMARK_CHECKPOINT_PERIOD" \
    '
      /^system\.servers\.num[[:space:]]*=/ {
        print "system.servers.num = " replica_count
        next
      }
      /^system\.servers\.f[[:space:]]*=/ {
        print "system.servers.f = " fault_count_value
        next
      }
      /^system\.initial\.view[[:space:]]*=/ {
        print "system.initial.view = " initial_view_value
        next
      }
      /^system\.totalordermulticast\.checkpoint_period[[:space:]]*=/ {
        print "system.totalordermulticast.checkpoint_period = " checkpoint_period
        next
      }
      { print }
    ' "$path" > "$tmp_path"
  mv "$tmp_path" "$path"

  grep -qx \
    "system.totalordermulticast.checkpoint_period = $BENCHMARK_CHECKPOINT_PERIOD" \
    "$path" || die "Failed to configure checkpoint period in $path"
}

write_hosts_config() {
  local path="$1"
  local replica_count="$2"
  local base_port="$3"
  local ttp_port="$4"
  local replica_id slot client_port
  {
    printf '# Generated by quinta_deploy.sh for run %s.\n' "$RUN_NAME"
    printf '#server id, address and port (the ids from 0 to n-1 are the service replicas)\n'
    for (( replica_id = 0; replica_id < replica_count; replica_id++ )); do
      slot="$(replica_slot_on_node "$replica_id")"
      client_port=$((base_port + slot * QUINTA_PORT_STEP))
      printf '%s %s %s %s\n' \
        "$replica_id" "$(replica_ip "$replica_id")" \
        "$client_port" "$((client_port + 1))"
    done
    printf '\n7002 %s %s\n' "$QUINTA_TTP_IP" "$ttp_port"
  } > "$path"
}

configure_local_deploy() {
  local deploy_dir deploy_index

  for (( deploy_index = 0; deploy_index < SSE_REPLICA_COUNT; deploy_index++ )); do
    deploy_dir="$ROOT_DIR/build/local/rep${deploy_index}"
    [[ -d "$deploy_dir" ]] || die "Missing local deploy directory: $deploy_dir"
    repair_local_deploy_from_reference "$deploy_dir" "$ROOT_DIR/config"
    write_system_config "$deploy_dir/config/system.config" "$SSE_REPLICA_COUNT"
    write_hosts_config "$deploy_dir/config/hosts.config" "$SSE_REPLICA_COUNT" "$QUINTA_BASE_CLIENT_PORT" "$QUINTA_TTP_PORT"
  done

  for (( deploy_index = 0; deploy_index < ORAM_REPLICA_COUNT; deploy_index++ )); do
    deploy_dir="$ROOT_DIR/build/local/oramRep${deploy_index}"
    [[ -d "$deploy_dir" ]] || die "Missing local deploy directory: $deploy_dir"
    repair_local_deploy_from_reference "$deploy_dir" "$ROOT_DIR/oram_config"
    write_system_config "$deploy_dir/config/system.config" "$ORAM_REPLICA_COUNT"
    write_hosts_config "$deploy_dir/config/hosts.config" "$ORAM_REPLICA_COUNT" "$QUINTA_ORAM_BASE_CLIENT_PORT" "$QUINTA_ORAM_TTP_PORT"
  done

  for (( deploy_index = 0; deploy_index < CLIENT_COUNT; deploy_index++ )); do
    deploy_dir="$ROOT_DIR/build/local/cli${deploy_index}"
    [[ -d "$deploy_dir" ]] || die "Missing local deploy directory: $deploy_dir"
    repair_local_deploy_from_reference "$deploy_dir" "$ROOT_DIR/oram_config"
    mkdir -p "$deploy_dir/sse_config"
    cp -R "$ROOT_DIR/config/." "$deploy_dir/sse_config/"
    write_system_config "$deploy_dir/sse_config/system.config" "$SSE_REPLICA_COUNT"
    write_hosts_config "$deploy_dir/sse_config/hosts.config" "$SSE_REPLICA_COUNT" "$QUINTA_BASE_CLIENT_PORT" "$QUINTA_TTP_PORT"
    write_system_config "$deploy_dir/config/system.config" "$ORAM_REPLICA_COUNT"
    write_hosts_config "$deploy_dir/config/hosts.config" "$ORAM_REPLICA_COUNT" "$QUINTA_ORAM_BASE_CLIENT_PORT" "$QUINTA_ORAM_TTP_PORT"
  done
}

reference_deploy_dir() {
  printf '%s\n' "$ROOT_DIR/build/install/cobra"
}

expected_source_jar_count() {
  local source_jars project_jars

  source_jars="$(find "$ROOT_DIR/lib" -maxdepth 1 -type f -name '*.jar' | wc -l | tr -d ' ')"
  project_jars="$(find "$ROOT_DIR/build/libs" -maxdepth 1 -type f -name '*.jar' | wc -l | tr -d ' ')"
  printf '%s\n' $((source_jars + project_jars))
}

validate_source_inputs() {
  local required_path

  for required_path in \
    config \
    oram_config \
    pairing \
    scripts \
    lib \
    pairing_based_execution.sh \
    config/system.config \
    config/hosts.config \
    config/keysSSL_TLS/EC_KeyPair_256.pkcs12 \
    config/keysECDSA/publickey1001 \
    config/keysRSA/publickey1001 \
    config/keysSunEC/publickey1001 \
    oram_config/system.config \
    oram_config/hosts.config \
    oram_config/keysSSL_TLS/EC_KeyPair_256.pkcs12 \
    oram_config/keysECDSA/publickey1001 \
    oram_config/keysRSA/publickey1001 \
    oram_config/keysSunEC/publickey1001 \
    pairing/relic/relic.zip \
    scripts/smartrun.sh; do
    [[ -e "$ROOT_DIR/$required_path" ]] || die "Missing source deploy path: $ROOT_DIR/$required_path"
  done

  [[ "$(find "$ROOT_DIR/lib" -maxdepth 1 -type f -name '*.jar' | wc -l | tr -d ' ')" -gt 0 ]] \
    || die "No source jars found in $ROOT_DIR/lib"
  [[ "$(find "$ROOT_DIR/build/libs" -maxdepth 1 -type f -name '*.jar' | wc -l | tr -d ' ')" -gt 0 ]] \
    || die "No project jar found in $ROOT_DIR/build/libs"
}

deploy_file_count() {
  local deploy_dir="$1"
  find "$deploy_dir" -type f | wc -l | tr -d ' '
}

deploy_jar_count() {
  local deploy_dir="$1"
  find "$deploy_dir/lib" -maxdepth 1 -type f -name '*.jar' | wc -l | tr -d ' '
}

repair_local_deploy_from_reference() {
  local deploy_dir="$1"
  local config_source_dir="$2"
  local reference_dir

  reference_dir="$(reference_deploy_dir)"
  [[ -d "$reference_dir" ]] || die "Missing reference deploy directory: $reference_dir"
  [[ -d "$config_source_dir" ]] || die "Missing config source directory: $config_source_dir"

  mkdir -p "$deploy_dir"
  cp -R "$reference_dir/." "$deploy_dir/"
  rm -rf "$deploy_dir/config"
  mkdir -p "$deploy_dir/config"
  cp -R "$config_source_dir/." "$deploy_dir/config/"
}

validate_config_copy() {
  local target_dir="$1"
  local source_dir="$2"
  local source_path relative_path

  [[ -d "$target_dir" ]] || die "Missing local config directory: $target_dir"
  while IFS= read -r source_path; do
    relative_path="${source_path#"$source_dir/"}"
    [[ -e "$target_dir/$relative_path" ]] \
      || die "Missing local deploy copy of source config: $target_dir/$relative_path"
  done < <(find "$source_dir" -type f)
}

validate_one_local_deploy() {
  local deploy_dir="$1"
  local expected_source_jars="$2"
  local config_source_dir="$3"
  local actual_jars required_path source_path relative_path target_path

  [[ -d "$deploy_dir" ]] || die "Missing local deploy directory: $deploy_dir"

  for required_path in \
    config \
    lib \
    pairing \
    smartrun.sh \
    config/system.config \
    config/hosts.config \
    config/keysSSL_TLS/EC_KeyPair_256.pkcs12 \
    config/keysECDSA/publickey1001 \
    config/keysRSA/publickey1001 \
    config/keysSunEC/publickey1001; do
    [[ -e "$deploy_dir/$required_path" ]] || die "Missing local deploy path: $deploy_dir/$required_path"
  done

  validate_config_copy "$deploy_dir/config" "$config_source_dir"

  while IFS= read -r source_path; do
    relative_path="${source_path#"$ROOT_DIR/pairing/"}"
    [[ -e "$deploy_dir/pairing/$relative_path" ]] \
      || die "Missing local deploy copy of source pairing: $deploy_dir/pairing/$relative_path"
  done < <(find "$ROOT_DIR/pairing" -type f)

  while IFS= read -r source_path; do
    target_path="$deploy_dir/$(basename "$source_path")"
    [[ -e "$target_path" ]] \
      || die "Missing local deploy copy of source script: $target_path"
  done < <(find "$ROOT_DIR/scripts" -type f)

  [[ -e "$deploy_dir/pairing_based_execution.sh" ]] \
    || die "Missing local deploy copy of source file: $deploy_dir/pairing_based_execution.sh"

  while IFS= read -r source_path; do
    target_path="$deploy_dir/lib/$(basename "$source_path")"
    [[ -e "$target_path" ]] \
      || die "Missing local deploy copy of source jar: $target_path"
  done < <(find "$ROOT_DIR/lib" -maxdepth 1 -type f -name '*.jar')

  while IFS= read -r source_path; do
    target_path="$deploy_dir/lib/$(basename "$source_path")"
    [[ -e "$target_path" ]] \
      || die "Missing local deploy copy of project jar: $target_path"
  done < <(find "$ROOT_DIR/build/libs" -maxdepth 1 -type f -name '*.jar')

  actual_jars="$(deploy_jar_count "$deploy_dir")"
  [[ "$actual_jars" -ge "$expected_source_jars" ]] \
    || die "$deploy_dir/lib has $actual_jars jars; expected at least $expected_source_jars source/project jars"
}

validate_remote_deploy() {
  local local_dir="$1"
  local host="$2"
  local remote_target="$3"
  local expected_files expected_jars client_checks=""

  expected_files="$(deploy_file_count "$local_dir")"
  expected_jars="$(deploy_jar_count "$local_dir")"

  if [[ "$(basename "$local_dir")" == cli* ]]; then
    local required_path
    for required_path in \
      sse_config/system.config \
      sse_config/hosts.config \
      datasets/vocabulary/vocabulary.txt; do
      [[ -s "$local_dir/$required_path" ]] \
        || { echo "Local client deploy missing file: $local_dir/$required_path" >&2; return 1; }
      client_checks+=" test -s '$remote_target/$required_path' || { echo 'Remote client deploy missing file: $remote_target/$required_path' >&2; exit 1; };"
    done
  fi

  ssh_remote "$host" "
    for required_path in \
      '$remote_target' \
      '$remote_target/config' \
      '$remote_target/lib' \
      '$remote_target/pairing' \
      '$remote_target/smartrun.sh' \
      '$remote_target/config/system.config' \
      '$remote_target/config/hosts.config' \
      '$remote_target/config/keysSSL_TLS/EC_KeyPair_256.pkcs12' \
      '$remote_target/config/keysECDSA/publickey1001' \
      '$remote_target/config/keysRSA/publickey1001' \
      '$remote_target/config/keysSunEC/publickey1001'; do
      test -e \"\$required_path\" || { echo \"Remote deploy missing required path: \$required_path\" >&2; exit 1; }
    done;
    $client_checks
    actual_files=\$(find '$remote_target' -type f | wc -l | tr -d ' ');
    test \"\$actual_files\" -eq '$expected_files' || { echo '$remote_target has' \"\$actual_files\" 'files; expected $expected_files' >&2; exit 1; };
    actual_jars=\$(find '$remote_target/lib' -maxdepth 1 -type f -name '*.jar' | wc -l | tr -d ' ');
    test \"\$actual_jars\" -eq '$expected_jars' || { echo '$remote_target/lib has' \"\$actual_jars\" 'jars; expected $expected_jars' >&2; exit 1; }
  "
}

copy_local_deploy_dir() {
  local local_dir="$1"
  local host="$2"
  local remote_dir="$3"
  local deploy_name remote_target

  deploy_name="$(basename "$local_dir")"
  remote_target="$remote_dir/$deploy_name"

  rsync_remote "$local_dir/" "$host:$remote_target/"
  if ! validate_remote_deploy "$local_dir" "$host" "$remote_target"; then
    echo "  remote deploy incomplete after rsync; retrying $deploy_name on $host..."
    rsync_remote "$local_dir/" "$host:$remote_target/"
    validate_remote_deploy "$local_dir" "$host" "$remote_target" \
      || die "Remote deploy is incomplete after retry: $host:$remote_target"
  fi
}

validate_local_deploy() {
  local expected_source_jars deploy_index
  validate_source_inputs
  expected_source_jars="$(expected_source_jar_count)"

  for (( deploy_index = 0; deploy_index < SSE_REPLICA_COUNT; deploy_index++ )); do
    validate_one_local_deploy "$ROOT_DIR/build/local/rep${deploy_index}" "$expected_source_jars" "$ROOT_DIR/config"
  done
  for (( deploy_index = 0; deploy_index < ORAM_REPLICA_COUNT; deploy_index++ )); do
    validate_one_local_deploy "$ROOT_DIR/build/local/oramRep${deploy_index}" "$expected_source_jars" "$ROOT_DIR/oram_config"
  done
  for (( deploy_index = 0; deploy_index < CLIENT_COUNT; deploy_index++ )); do
    validate_one_local_deploy "$ROOT_DIR/build/local/cli${deploy_index}" "$expected_source_jars" "$ROOT_DIR/oram_config"
    validate_config_copy "$ROOT_DIR/build/local/cli${deploy_index}/sse_config" "$ROOT_DIR/config"
    [[ -s "$ROOT_DIR/build/local/cli${deploy_index}/datasets/vocabulary/vocabulary.txt" ]] \
      || die "Missing client vocabulary: build/local/cli${deploy_index}/datasets/vocabulary/vocabulary.txt"
  done
}

prepare_local_deploy() {
  echo "Preparing local deploy..."
  (
    cd "$ROOT_DIR"
    ./gradlew --no-daemon --no-watch-fs clean localDeploy -Pservers="$SSE_REPLICA_COUNT" -PoramServers="$ORAM_REPLICA_COUNT" -Pclients="$CLIENT_COUNT"
  )
  configure_local_deploy
  validate_local_deploy
}

deploy() {
  local replica_id client_index node host remote_dir

  prepare_local_deploy

  print_layout

  echo "Stopping previous processes for this run..."
  stop

  echo "Preparing remote directories..."
  for node in "${QUINTA_NODES[@]}"; do
    host="$(ssh_host "$node")"
    ssh_remote "$host" "rm -rf '$(remote_run_dir)' && mkdir -p '$(remote_run_dir)'"
  done

  echo "Copying replicas..."
  for (( replica_id = 0; replica_id < SSE_REPLICA_COUNT; replica_id++ )); do
    node="$(replica_node "$replica_id")"
    host="$(ssh_host "$node")"
    remote_dir="$(remote_run_dir)"
    echo "  rep$replica_id -> $host"
    copy_local_deploy_dir "$ROOT_DIR/build/local/rep${replica_id}" "$host" "$remote_dir"
  done

  echo "Copying ORAM replicas..."
  for (( replica_id = 0; replica_id < ORAM_REPLICA_COUNT; replica_id++ )); do
    node="$(replica_node "$replica_id")"
    host="$(ssh_host "$node")"
    remote_dir="$(remote_run_dir)"
    echo "  oramRep$replica_id -> $host"
    copy_local_deploy_dir "$ROOT_DIR/build/local/oramRep${replica_id}" "$host" "$remote_dir"
  done

  echo "Copying clients..."
  for (( client_index = 0; client_index < CLIENT_COUNT; client_index++ )); do
    node="$(client_node "$client_index")"
    host="$(ssh_host "$node")"
    remote_dir="$(remote_run_dir)"
    echo "  cli$client_index -> $host"
    copy_local_deploy_dir "$ROOT_DIR/build/local/cli${client_index}" "$host" "$remote_dir"
  done
}

preflight() {
  local node host expected_ip ports

  print_layout
  echo
  echo "Preflight:"
  for node_index in "${!QUINTA_NODES[@]}"; do
    node="${QUINTA_NODES[$node_index]}"
    expected_ip="${QUINTA_NODE_IPS[$node_index]}"
    host="$(ssh_host "$node")"
    echo "=== $host ==="
    ports="$(run_ports_for_node "$node")"
    if [[ "$expected_ip" == "$QUINTA_TTP_IP" ]]; then
      ports+=" $QUINTA_TTP_PORT $QUINTA_ORAM_TTP_PORT"
    fi
    ssh_remote "$host" "
      echo whoami=\$(whoami);
      hostname;
      ip -4 addr | grep -q '$expected_ip' || { echo 'Expected IP $expected_ip was not found' >&2; exit 1; };
      echo ip-ok=$expected_ip;
      df -h / | tail -n 1;
      java_output=\$(java -version 2>&1 | head -n 1) || { echo 'Java is not installed' >&2; exit 1; };
      echo \"\$java_output\";
      java_major=\$(printf '%s\n' \"\$java_output\" | sed -n 's/.*version \"\([0-9][0-9]*\).*/\1/p');
      test \"\$java_major\" = '$QUINTA_REQUIRED_JAVA_MAJOR' || { echo \"Expected Java $QUINTA_REQUIRED_JAVA_MAJOR, found \$java_output\" >&2; exit 1; };
      command -v ss >/dev/null || { echo 'ss is not installed' >&2; exit 1; };
      listeners=\$(ss -ltn) || exit 1;
      for port in $ports; do
        if printf '%s\n' \"\$listeners\" | grep -q \":\$port \"; then
          echo \"Port \$port is already in use\" >&2;
          exit 1;
        fi;
      done
    " || die "Preflight failed on $host"
  done
}

start() {
  local replica_id node host remote_dir

  echo "Starting ORAM replicas..."
  for (( replica_id = 0; replica_id < ORAM_REPLICA_COUNT; replica_id++ )); do
    node="$(replica_node "$replica_id")"
    host="$(ssh_host "$node")"
    remote_dir="$(remote_oram_replica_dir "$replica_id")"
    echo "Starting oramRep$replica_id on $host"
    ssh_remote -f "$host" "cd '$remote_dir' && { nohup env JAVA_OPTS='$QUINTA_ORAM_REPLICA_JAVA_OPTS' bash smartrun.sh oram.server.ORAMServer '$ORAM_MAX_CONCURRENT_CLIENTS' '$replica_id' > server.log 2>&1 < /dev/null & echo \$! > server.pid; }"
  done

  echo "Starting SSE replicas..."
  for (( replica_id = 0; replica_id < SSE_REPLICA_COUNT; replica_id++ )); do
    node="$(replica_node "$replica_id")"
    host="$(ssh_host "$node")"
    remote_dir="$(remote_replica_dir "$replica_id")"
    echo "Starting rep$replica_id on $host"
    ssh_remote -f "$host" "cd '$remote_dir' && { nohup env JAVA_OPTS='$QUINTA_REPLICA_JAVA_OPTS' bash smartrun.sh sse.demo.server.Server '$replica_id' > server.log 2>&1 < /dev/null & echo \$! > server.pid; }"
  done
}

remote_replica_ready() {
  local host="$1"
  local remote_dir="$2"
  ssh_remote "$host" "test -s '$remote_dir/server.pid' && pid=\$(cat '$remote_dir/server.pid') && [[ \"\$pid\" =~ ^[0-9]+\$ ]] && [[ \$(readlink -f /proc/\$pid/cwd 2>/dev/null) == '$remote_dir' ]] && kill -0 \"\$pid\" 2>/dev/null && grep -q 'Ready to process operations' '$remote_dir/server.log' 2>/dev/null" >/dev/null 2>&1
}

remote_replica_alive() {
  local host="$1"
  local remote_dir="$2"
  ssh_remote "$host" "test -s '$remote_dir/server.pid' && pid=\$(cat '$remote_dir/server.pid') && [[ \"\$pid\" =~ ^[0-9]+\$ ]] && [[ \$(readlink -f /proc/\$pid/cwd 2>/dev/null) == '$remote_dir' ]] && kill -0 \"\$pid\" 2>/dev/null" >/dev/null 2>&1
}

wait_ready() {
  local deadline=$((SECONDS + QUINTA_READY_TIMEOUT_SECONDS))
  local replica_id node host remote_dir ready

  echo "Waiting up to ${QUINTA_READY_TIMEOUT_SECONDS}s for replicas..."
  while (( SECONDS < deadline )); do
    ready=1
    for (( replica_id = 0; replica_id < ORAM_REPLICA_COUNT; replica_id++ )); do
      node="$(replica_node "$replica_id")"
      host="$(ssh_host "$node")"
      remote_dir="$(remote_oram_replica_dir "$replica_id")"
      if ! remote_replica_ready "$host" "$remote_dir"; then
        if ! remote_replica_alive "$host" "$remote_dir"; then
          echo "$host oramRep$replica_id exited before becoming ready." >&2
          status >&2 || true
          return 1
        fi
        ready=0
        break
      fi
    done
    for (( replica_id = 0; replica_id < SSE_REPLICA_COUNT; replica_id++ )); do
      node="$(replica_node "$replica_id")"
      host="$(ssh_host "$node")"
      remote_dir="$(remote_replica_dir "$replica_id")"
      if ! remote_replica_ready "$host" "$remote_dir"; then
        if ! remote_replica_alive "$host" "$remote_dir"; then
          echo "$host rep$replica_id exited before becoming ready." >&2
          status >&2 || true
          return 1
        fi
        ready=0
        break
      fi
    done
    if [[ "$ready" -eq 1 ]]; then
      echo "All replicas are ready."
      return
    fi
    sleep 2
  done

  echo "Timed out waiting for replicas." >&2
  status >&2 || true
  exit 1
}

status() {
  local replica_id node host remote_dir

  for (( replica_id = 0; replica_id < ORAM_REPLICA_COUNT; replica_id++ )); do
    node="$(replica_node "$replica_id")"
    host="$(ssh_host "$node")"
    remote_dir="$(remote_oram_replica_dir "$replica_id")"
    echo "=== $host oramRep$replica_id ==="
    ssh_remote "$host" "if test -s '$remote_dir/server.pid'; then pid=\$(cat '$remote_dir/server.pid'); ps -p \"\$pid\" -o pid=,args= || echo 'not running'; else echo 'no server.pid'; fi; grep -n 'Ready to process operations' '$remote_dir/server.log' 2>/dev/null || tail -n 20 '$remote_dir/server.log' 2>/dev/null || echo 'no server.log'"
  done
  for (( replica_id = 0; replica_id < SSE_REPLICA_COUNT; replica_id++ )); do
    node="$(replica_node "$replica_id")"
    host="$(ssh_host "$node")"
    remote_dir="$(remote_replica_dir "$replica_id")"
    echo "=== $host rep$replica_id ==="
    ssh_remote "$host" "if test -s '$remote_dir/server.pid'; then pid=\$(cat '$remote_dir/server.pid'); ps -p \"\$pid\" -o pid=,args= || echo 'not running'; else echo 'no server.pid'; fi; grep -n 'Ready to process operations' '$remote_dir/server.log' 2>/dev/null || tail -n 20 '$remote_dir/server.log' 2>/dev/null || echo 'no server.log'"
  done
}

run_ports_for_node() {
  local node="$1"
  local replica_id client_port ports=""

  for (( replica_id = 0; replica_id < SSE_REPLICA_COUNT; replica_id++ )); do
    if [[ "$(replica_node "$replica_id")" == "$node" ]]; then
      client_port="$(replica_client_port "$replica_id")"
      ports+=" $client_port $((client_port + 1)) $((client_port + 2))"
    fi
  done
  for (( replica_id = 0; replica_id < ORAM_REPLICA_COUNT; replica_id++ )); do
    if [[ "$(replica_node "$replica_id")" == "$node" ]]; then
      client_port="$(oram_replica_client_port "$replica_id")"
      ports+=" $client_port $((client_port + 1)) $((client_port + 2))"
    fi
  done
  printf '%s\n' "$ports"
}

stop_current_run_processes() {
  local host="$1"
  local signal="$2"
  local show_listeners="${3:-false}"
  local listeners_command=""

  [[ "$show_listeners" == "true" ]] && listeners_command="ss -ltn"
  ssh_remote "$host" "
    for process_dir in /proc/[0-9]*; do
      pid=\${process_dir##*/};
      process_cwd=\$(readlink -f \"\$process_dir/cwd\" 2>/dev/null || true);
      case \"\$process_cwd\" in
        '$(remote_run_dir)'/*) kill -$signal \"\$pid\" 2>/dev/null || true ;;
      esac;
    done;
    $listeners_command
  "
}

stop() {
  local node host port ports listeners

  echo "Stopping SSE and ORAM replicas for this run..."
  for node in "${QUINTA_NODES[@]}"; do
    stop_current_run_processes "$(ssh_host "$node")" TERM
  done
  sleep 2

  for node in "${QUINTA_NODES[@]}"; do
    host="$(ssh_host "$node")"
    listeners="$(stop_current_run_processes "$host" KILL true)" \
      || { echo "$host could not stop processes or list listening ports; refusing to remove this run's files." >&2; return 1; }
    ports="$(run_ports_for_node "$node")"
    if [[ "$(node_ip "$node")" == "$QUINTA_TTP_IP" ]]; then
      ports+=" $QUINTA_TTP_PORT $QUINTA_ORAM_TTP_PORT"
    fi
    for port in $ports; do
      if printf '%s\n' "$listeners" | grep -q ":$port "; then
        echo "$host still has port $port in use; refusing to remove this run's files." >&2
        return 1
      fi
    done
  done
}

stop_stale_benchmark_processes() {
  local host="$1"
  local signal="$2"

  ssh_remote "$host" "for process_dir in /proc/[0-9]*; do pid=\${process_dir##*/}; process_cwd=\$(readlink -f \"\$process_dir/cwd\" 2>/dev/null || true); case \"\$process_cwd\" in '$QUINTA_REMOTE_ROOT'/*) echo \"Stopping stale benchmark process: pid=\$pid cwd=\$process_cwd signal=$signal\"; kill -$signal \"\$pid\" 2>/dev/null || true ;; esac; done"
}

verify_no_stale_benchmark_processes() {
  local host="$1"

  ssh_remote "$host" "for process_dir in /proc/[0-9]*; do pid=\${process_dir##*/}; process_cwd=\$(readlink -f \"\$process_dir/cwd\" 2>/dev/null || true); case \"\$process_cwd\" in '$QUINTA_REMOTE_ROOT'/*) echo \"Still running: pid=\$pid cwd=\$process_cwd\" >&2; exit 1 ;; esac; done"
}

preclean() {
  local node host

  echo "Stopping all stale processes under $QUINTA_REMOTE_ROOT..."
  for node in "${QUINTA_NODES[@]}"; do
    host="$(ssh_host "$node")"
    stop_stale_benchmark_processes "$host" TERM
  done

  sleep 2

  for node in "${QUINTA_NODES[@]}"; do
    host="$(ssh_host "$node")"
    stop_stale_benchmark_processes "$host" KILL
    verify_no_stale_benchmark_processes "$host" \
      || die "$host still has a process running under $QUINTA_REMOTE_ROOT"
  done

  for node in "${QUINTA_NODES[@]}"; do
    host="$(ssh_host "$node")"
    echo "Cleaning on $host"
    ssh_remote "$host" "rm -rf '$(remote_run_dir)'"
  done
}

clean() {
  local node host

  stop
  for node in "${QUINTA_NODES[@]}"; do
    host="$(ssh_host "$node")"
    echo "Cleaning on $host"
    ssh_remote "$host" "rm -rf '$(remote_run_dir)'"
  done
}

main() {
  parse_args "$@"
  load_cluster_config

  case "$COMMAND" in
    layout) print_layout ;;
    prepare-local) prepare_local_deploy ;;
    preflight) preflight ;;
    deploy) deploy ;;
    start) start ;;
    wait) wait_ready ;;
    status) status ;;
    stop) stop ;;
    clean) clean ;;
    preclean) preclean ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
