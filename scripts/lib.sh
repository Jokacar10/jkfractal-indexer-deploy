#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${KOPIA_R2_BUCKET:=kopia-repo}"
: "${KOPIA_R2_ENDPOINT:=eccc9c966ad74b3b2b15c2961767d059.r2.cloudflarestorage.com}"
: "${KOPIA_REPOSITORY_PASSWORD:=fractalbitcoin}"
: "${KOPIA_REPOSITORY_PREFIX:=fractald-pruned}"
: "${KOPIA_USERNAME:=fractalbitcoin}"
: "${KOPIA_HOSTNAME:=fractalbitcoin-fip101}"
: "${UPLOAD_BASE_DIR:=/opt/fractal-indexer-deploy}"
: "${KOPIA_CACHE_DIRECTORY:=${REPO_ROOT}/.kopia-cache}"

log() {
  printf '>>> %s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'ERROR: %s\n\n' "$1" >&2
  usage >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    die "missing required environment variable: ${name}"
  fi
}

is_numeric() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

compose_cmd_array() {
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    return
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return
  fi

  die "missing docker compose command"
}

compose_cmd() {
  compose_cmd_array
  printf '%s\n' "${COMPOSE_CMD[*]}"
}

run_compose() {
  local dir="$1"
  shift

  compose_cmd_array
  (
    cd "$dir"
    "${COMPOSE_CMD[@]}" "$@"
  )
}

port_in_use() {
  local port="$1"

  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi

  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${port}$"
    return
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -an | grep -E "[.:]${port}[[:space:]].*LISTEN" >/dev/null 2>&1
    return
  fi

  warn "cannot check port ${port}; lsof, ss, and netstat are unavailable"
  return 1
}

check_ports_free() {
  local port

  for port in "$@"; do
    if port_in_use "$port"; then
      die "port ${port} is already in use"
    fi
  done
}

ensure_empty_or_missing() {
  local path="$1"

  if [ -e "$path" ] && [ "$(find "$path" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]; then
    die "${path} already exists and is not empty"
  fi
}

generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
    return
  fi

  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48
  printf '\n'
}

kopia_connect_s3() {
  local mode="${1:-}"
  local readonly_args=()
  local override_args=()

  require_env AWS_ACCESS_KEY_ID
  require_env AWS_SECRET_ACCESS_KEY
  require_env KOPIA_REPOSITORY_PASSWORD

  mkdir -p "$KOPIA_CACHE_DIRECTORY"

  if [ "$mode" = "readonly" ]; then
    readonly_args=(--readonly)
  else
    override_args=(--override-username="$KOPIA_USERNAME" --override-hostname="$KOPIA_HOSTNAME")
  fi

  KOPIA_CHECK_FOR_UPDATES=false kopia repository connect s3 \
    --bucket="$KOPIA_R2_BUCKET" \
    --endpoint="$KOPIA_R2_ENDPOINT" \
    --prefix="$KOPIA_REPOSITORY_PREFIX" \
    --password="$KOPIA_REPOSITORY_PASSWORD" \
    --cache-directory="$KOPIA_CACHE_DIRECTORY" \
    "${override_args[@]}" \
    "${readonly_args[@]}"
}

kopia_snapshot_json_by_tags() {
  local tag_args=()
  local tag

  for tag in "$@"; do
    tag_args+=(--tags="$tag")
  done

  kopia snapshot list --all --json "${tag_args[@]}"
}

kopia_snapshot_object_id() {
  kopia_snapshot_json_by_tags "$@" \
    | jq -er '
      if type == "array" then flatten else [.] end
      | map(select(.rootEntry.obj != null))
      | sort_by(.startTime // .endTime // "")
      | last
      | .rootEntry.obj
    '
}

write_fractald_config() {
  local user="$1"
  local password="$2"
  local target="${REPO_ROOT}/fractald/conf/bitcoin.conf"

  mkdir -p "$(dirname "$target")"
  cat >"$target" <<EOF
server=1
port=10333
txindex=1
blocksxor=0

prune=102400

datadir=/data
blocksdir=/data
dbcache=4096

rpcbind=0.0.0.0
rpcallowip=0.0.0.0/0
rpcport=10332
rpcuser=${user}
rpcpassword=${password}
rpcworkqueue=2048
rpcthreads=32
rpcservertimeout=120

zmqpubrawblock=tcp://0.0.0.0:10330
zmqpubrawtx=tcp://0.0.0.0:10331
EOF
}

write_fractal_indexer_chain_config() {
  local rpc_user="$1"
  local rpc_password="$2"
  local target="${REPO_ROOT}/fractal-indexer/conf/indexer/chain.yaml"

  cat >"$target" <<EOF
chain_type: Fractal
skip_missing_utxo: false

zmq_block: "tcp://fractald:10330"
zmq_tx: "tcp://fractald:10331"
rpc: "http://fractald:10332"
rpc_auth: "${rpc_user}:${rpc_password}"


utxo_pika_batch: 1024

jubilee_activation_height: 21000
ordinals_activation_height: 21000
reinscription_activation_height: 21000
brc20_single_step_transfer_height: 930930
EOF
}

write_stake_indexer_chain_config() {
  local rpc_user="$1"
  local rpc_password="$2"
  local target="${REPO_ROOT}/stake-indexer/conf/indexer/chain.yaml"

  cat >"$target" <<EOF
rpc: "http://fractald:10332"
rpc_auth: "${rpc_user}:${rpc_password}"
EOF
}

write_proof_publisher_config() {
  local rpc_user="$1"
  local rpc_password="$2"
  local target="${REPO_ROOT}/proof-publisher/config.json"

  cp "${REPO_ROOT}/proof-publisher/config.example.json" "$target"

  jq \
    --arg rpc_user "$rpc_user" \
    --arg rpc_password "$rpc_password" \
    --arg private_key "${PROOF_PRIVATE_KEY_WIF:-REPLACE_PRIVATE_KEY_WIF}" \
    --arg change_address "${PROOF_CHANGE_ADDRESS:-REPLACE_CHANGE_ADDRESS}" \
    --arg reward_address "${PROOF_REWARD_ADDRESS:-REPLACE_REWARD_ADDRESS}" \
    --arg indexer_name "${PROOF_INDEXER_NAME:-REPLACE_INDEXER_NAME}" \
    --arg indexer_id "${PROOF_INDEXER_ID:-}" \
    --arg unisat_key "${PROOF_UNISAT_OPEN_API_KEY:-REPLACE_UNISAT_OPEN_API_KEY}" \
    '
      .bitcoin_rpc.user = $rpc_user
      | .bitcoin_rpc.password = $rpc_password
      | .signing.private_key_wif = $private_key
      | .signing.change_address = $change_address
      | .register.reward_addr = $reward_address
      | .register.name = $indexer_name
      | .register.indexer_id = $indexer_id
      | .runtime.unisat_open_api_key = $unisat_key
    ' "$target" >"${target}.tmp"

  mv "${target}.tmp" "$target"
}

proof_publisher_can_start() {
  [ -n "${PROOF_PRIVATE_KEY_WIF:-}" ] \
    && [ -n "${PROOF_CHANGE_ADDRESS:-}" ] \
    && [ -n "${PROOF_REWARD_ADDRESS:-}" ] \
    && [ -n "${PROOF_INDEXER_NAME:-}" ] \
    && [ -n "${PROOF_UNISAT_OPEN_API_KEY:-}" ]
}
