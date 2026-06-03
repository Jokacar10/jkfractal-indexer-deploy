#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/deploy.sh [--snapshot=<height>] [--force]

Snapshot restore environment:
  AWS_ACCESS_KEY_ID       Read-only Cloudflare R2 access key; defaults to bundled read-only key
  AWS_SECRET_ACCESS_KEY   Read-only Cloudflare R2 secret key; defaults to bundled read-only key

Without --snapshot, the script initializes configs and starts services without
restoring Kopia snapshot data.

Options:
  --force                  Skip runtime data directory existence checks.

Optional proof-publisher environment. If all are provided, proof-publisher
will be started; otherwise config.json is generated but the service is not
started:
  PROOF_PRIVATE_KEY_WIF
  PROOF_CHANGE_ADDRESS
  PROOF_REWARD_ADDRESS
  PROOF_INDEXER_NAME
  PROOF_UNISAT_OPEN_API_KEY
  PROOF_INDEXER_ID
EOF
}

snapshot_height=""
force=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot=*)
      snapshot_height="${1#--snapshot=}"
      ;;
    --force)
      force=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
  shift
done

if [ -n "$snapshot_height" ] && ! is_numeric "$snapshot_height"; then
  usage_error "snapshot height must be numeric"
fi

use_snapshot=0
if [ -n "$snapshot_height" ]; then
  use_snapshot=1
fi

: "${AWS_ACCESS_KEY_ID:=d10a4a18c0d604d803049c94a01dace5}"
if [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  require_command base64
  AWS_SECRET_ACCESS_KEY="$(printf '%s' 'OTAyZTFiYmQ0NmUyOWQ3NTQxZTBhMzY5MmI0YTU2OGY3MmJmN2RiZmIyNzNiMmE0ZDkwMmI0ZmUzYjA5MGRmYg==' | base64 -d)"
fi
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY

require_command docker
require_command jq
compose_cmd >/dev/null

if [ "$use_snapshot" -eq 1 ]; then
  require_command kopia
  require_env AWS_ACCESS_KEY_ID
  require_env AWS_SECRET_ACCESS_KEY
  require_env KOPIA_REPOSITORY_PASSWORD
fi

log "Checking ports"
if proof_publisher_can_start; then
  check_ports_free 10330 10331 10332 10333 8000 9637 9432 9379 8080
else
  check_ports_free 10330 10331 10332 10333 8000 9637 9432 9379
fi

if [ "$force" -eq 1 ]; then
  warn "Skipping runtime data directory checks because --force was provided"
else
  log "Checking runtime data directories"
  ensure_empty_or_missing "${REPO_ROOT}/fractald/data"
  ensure_empty_or_missing "${REPO_ROOT}/fractal-indexer/data"
  ensure_empty_or_missing "${REPO_ROOT}/stake-indexer/data"
fi

load_fractald_rpc_credentials() {
  local config="${REPO_ROOT}/fractald/conf/bitcoin.conf"

  rpc_user="$(sed -n 's/^[[:space:]]*rpcuser[[:space:]]*=[[:space:]]*//p' "$config" | head -n 1)"
  rpc_password="$(sed -n 's/^[[:space:]]*rpcpassword[[:space:]]*=[[:space:]]*//p' "$config" | head -n 1)"

  if [ -z "$rpc_user" ] || [ -z "$rpc_password" ]; then
    die "${config} exists but rpcuser or rpcpassword is missing"
  fi
}

rpc_user=""
rpc_password=""
fractald_config="${REPO_ROOT}/fractald/conf/bitcoin.conf"
if [ -f "$fractald_config" ]; then
  log "Loading fractald RPC credentials from existing config"
  load_fractald_rpc_credentials
else
  rpc_user="fip101"
  rpc_password="$(generate_password)"

  log "Generating fractald config"
  generate_fractald_config "$rpc_user" "$rpc_password"
fi

restore_dataset() {
  local dataset="$1"
  local target="$2"
  local object_id tags_display
  local tags=(
    "network:fractal"
    "role:snapshot"
    "dataset:${dataset}"
    "height:${snapshot_height}"
  )

  tags_display="$(IFS=,; printf '%s' "${tags[*]}")"
  log "Resolving ${dataset} (${tags_display})"
  object_id="$(kopia_snapshot_object_id "${tags[@]}")"

  mkdir -p "$(dirname "$target")"
  log "Restoring ${dataset} to ${target}"
  kopia snapshot restore "$object_id" "$target"
  printf '%s\t%s\t%s\n' "$dataset" "$object_id" "$target" >>"$restore_summary_file"
}

ensure_clickhouse_data_small_enough_for_db_init() {
  local path="${REPO_ROOT}/fractal-indexer/data/clickhouse"
  local max_size_mb=1024
  local size_mb=0

  if [ -d "$path" ]; then
    size_mb="$(du -sm "$path" | awk '{print $1}')"
  fi

  if [ "$size_mb" -gt "$max_size_mb" ]; then
    die "${path} is ${size_mb}M, greater than ${max_size_mb}M; refusing to run fractal-indexer init.sh db"
  fi
}

restore_summary_file=""
fractald_info_file=""
fractald_rpc_error_file=""
restore_summary_file="$(mktemp)"
fractald_info_file="$(mktemp)"
fractald_rpc_error_file="$(mktemp)"
trap 'rm -f "${restore_summary_file:-}" "${fractald_info_file:-}" "${fractald_rpc_error_file:-}"' EXIT

if [ "$use_snapshot" -eq 1 ]; then
  log "Connecting Kopia repository as read-only"
  kopia_connect_s3 readonly

  log "Restoring fractald snapshots"
  restore_dataset fractald-blocks "${REPO_ROOT}/fractald/data/blocks"
  restore_dataset fractald-chainstate "${REPO_ROOT}/fractald/data/chainstate"
fi

log "Initializing fractald directory ownership"
(
  cd "${REPO_ROOT}/fractald"
  bash ./scripts/init.sh
)

log "Starting fractald"
run_compose "${REPO_ROOT}/fractald" up -d

log "Waiting for fractald RPC"
for attempt in $(seq 1 120); do
  if run_compose "${REPO_ROOT}/fractald" exec -T fractald bitcoin-cli --conf=/conf/bitcoin.conf getblockchaininfo >"$fractald_info_file" 2>"${fractald_rpc_error_file:-/dev/null}"; then
    log "fractald RPC response:"
    sed 's/^/  /' "$fractald_info_file"
    if [ -n "${fractald_rpc_error_file:-}" ] && [ -s "$fractald_rpc_error_file" ]; then
      warn "fractald RPC stderr:"
      sed 's/^/  /' "$fractald_rpc_error_file"
    fi
    break
  fi
  sleep 5
done

if [ ! -s "$fractald_info_file" ]; then
  die "fractald RPC did not become available"
fi

node_height="$(jq -r '.blocks // 0' "$fractald_info_file")"
log "fractald height: ${node_height}"

if [ "$use_snapshot" -eq 1 ] && [ "$node_height" -lt "$snapshot_height" ]; then
  die "fractald height ${node_height} is below requested snapshot height ${snapshot_height}"
fi

log "Generating fractal-indexer config"
generate_fractal_indexer_chain_config "$rpc_user" "$rpc_password"

if [ "$use_snapshot" -eq 1 ]; then
  log "Restoring fractal-indexer snapshots"
  restore_dataset fractal-indexer-data "${REPO_ROOT}/fractal-indexer/data"
fi

log "Initializing fractal-indexer"
(
  cd "${REPO_ROOT}/fractal-indexer"
  if [ "$use_snapshot" -eq 1 ]; then
    bash ./scripts/init.sh
  else
    ensure_clickhouse_data_small_enough_for_db_init
    bash ./scripts/init.sh db
  fi
)

log "Starting fractal-indexer storage services"
run_compose "${REPO_ROOT}/fractal-indexer" up -d clickhouse pika pika-brc20

log "Starting fractal-indexer indexer and API"
run_compose "${REPO_ROOT}/fractal-indexer" up -d indexer api

log "Initializing stake-indexer"
(
  cd "${REPO_ROOT}/stake-indexer"
  bash ./scripts/init.sh
)
generate_stake_indexer_chain_config "$rpc_user" "$rpc_password"

log "Starting stake-indexer"
run_compose "${REPO_ROOT}/stake-indexer" up -d

log "Initializing proof-publisher config"
(
  cd "${REPO_ROOT}/proof-publisher"
  bash ./scripts/init.sh
)
generate_proof_publisher_config "$rpc_user" "$rpc_password"

if proof_publisher_can_start; then
  log "Starting proof-publisher"
  run_compose "${REPO_ROOT}/proof-publisher" up -d
else
  warn "proof-publisher config generated but service not started; signing env vars are incomplete"
fi

log "Final service status"
printf '\n[fractald]\n'
run_compose "${REPO_ROOT}/fractald" ps
printf '\n[fractal-indexer]\n'
run_compose "${REPO_ROOT}/fractal-indexer" ps
printf '\n[stake-indexer]\n'
run_compose "${REPO_ROOT}/stake-indexer" ps
if proof_publisher_can_start; then
  printf '\n[proof-publisher]\n'
  run_compose "${REPO_ROOT}/proof-publisher" ps
fi

if [ "$use_snapshot" -eq 1 ]; then
  snapshot_summary="Restored snapshots:
$(cat "$restore_summary_file")

Selected snapshot height: ${snapshot_height}"
else
  snapshot_summary="Snapshot restore: skipped"
fi

cat <<EOF

${snapshot_summary}

Fractal indexer API: http://localhost:8000
Stake indexer API: http://localhost:9637
Proof publisher: http://localhost:8080
EOF
