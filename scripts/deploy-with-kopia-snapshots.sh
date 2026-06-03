#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/deploy-with-kopia-snapshots.sh <snapshot-height>

Required environment:
  AWS_ACCESS_KEY_ID       Read-only Cloudflare R2 access key
  AWS_SECRET_ACCESS_KEY   Read-only Cloudflare R2 secret key

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

snapshot_height="${1:-}"

if [ "$#" -ne 1 ]; then
  usage_error "expected exactly one snapshot height argument"
fi

if ! is_numeric "$snapshot_height"; then
  usage_error "snapshot height must be numeric"
fi

require_command docker
require_command curl
require_command jq
require_command kopia
compose_cmd >/dev/null
require_env AWS_ACCESS_KEY_ID
require_env AWS_SECRET_ACCESS_KEY
require_env KOPIA_REPOSITORY_PASSWORD

log "Checking ports"
if proof_publisher_can_start; then
  check_ports_free 10330 10331 10332 10333 8000 9637 9432 9379 8080
else
  check_ports_free 10330 10331 10332 10333 8000 9637 9432 9379
fi

log "Checking runtime data directories"
ensure_empty_or_missing "${REPO_ROOT}/fractald/data"
ensure_empty_or_missing "${REPO_ROOT}/fractal-indexer/data"
ensure_empty_or_missing "${REPO_ROOT}/stake-indexer/data"

rpc_user="fip101"
rpc_password="$(generate_password)"

log "Generating fractald config"
write_fractald_config "$rpc_user" "$rpc_password"

log "Connecting Kopia repository as read-only"
kopia_connect_s3 readonly

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

restore_summary_file="$(mktemp)"
fractald_info_file="$(mktemp)"
trap 'rm -f "$restore_summary_file" "$fractald_info_file"' EXIT

log "Restoring fractald snapshots"
restore_dataset fractald-blocks "${REPO_ROOT}/fractald/data/blocks"
restore_dataset fractald-chainstate "${REPO_ROOT}/fractald/data/chainstate"

log "Initializing fractald directory ownership"
(
  cd "${REPO_ROOT}/fractald"
  bash ./scripts/init.sh
)

log "Starting fractald"
run_compose "${REPO_ROOT}/fractald" up -d

log "Waiting for fractald RPC"
for _ in $(seq 1 120); do
  if run_compose "${REPO_ROOT}/fractald" exec -T fractald bitcoin-cli --conf=/conf/bitcoin.conf getblockchaininfo >"$fractald_info_file" 2>/dev/null; then
    break
  fi
  sleep 5
done

if [ ! -s "$fractald_info_file" ]; then
  die "fractald RPC did not become available"
fi

node_height="$(jq -r '.blocks // 0' "$fractald_info_file")"
log "fractald height: ${node_height}"

if [ "$node_height" -lt "$snapshot_height" ]; then
  die "fractald height ${node_height} is below requested snapshot height ${snapshot_height}"
fi

log "Initializing fractal-indexer"
(
  cd "${REPO_ROOT}/fractal-indexer"
  bash ./scripts/init.sh
)
write_fractal_indexer_chain_config "$rpc_user" "$rpc_password"

log "Restoring fractal-indexer snapshots"
restore_dataset fractal-indexer-data "${REPO_ROOT}/fractal-indexer/data"

log "Fixing fractal-indexer ownership"
sudo chown -R 1000:1000 \
  "${REPO_ROOT}/fractal-indexer/data/brc20" \
  "${REPO_ROOT}/fractal-indexer/data/pika" \
  "${REPO_ROOT}/fractal-indexer/data/pika-brc20" \
  "${REPO_ROOT}/fractal-indexer/logs/pika" \
  "${REPO_ROOT}/fractal-indexer/logs/pika-brc20"
sudo chown -R 101:101 \
  "${REPO_ROOT}/fractal-indexer/data/clickhouse" \
  "${REPO_ROOT}/fractal-indexer/logs/clickhouse"

log "Starting fractal-indexer storage services"
run_compose "${REPO_ROOT}/fractal-indexer" up -d clickhouse pika pika-brc20

log "Starting fractal-indexer indexer and API"
run_compose "${REPO_ROOT}/fractal-indexer" up -d indexer api

log "Initializing stake-indexer"
(
  cd "${REPO_ROOT}/stake-indexer"
  bash ./scripts/init.sh
)
write_stake_indexer_chain_config "$rpc_user" "$rpc_password"

log "Starting stake-indexer"
run_compose "${REPO_ROOT}/stake-indexer" up -d

log "Initializing proof-publisher config"
(
  cd "${REPO_ROOT}/proof-publisher"
  bash ./scripts/init.sh
)
write_proof_publisher_config "$rpc_user" "$rpc_password"

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

cat <<EOF

Restored snapshots:
$(cat "$restore_summary_file")

Selected snapshot height: ${snapshot_height}
Fractal indexer API: http://localhost:8000
Stake indexer API: http://localhost:9637
Proof publisher: http://localhost:8080
EOF
