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
    die "${path} already exists and is not empty; add --force to ignore this check"
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

  kopia snapshot list --all --json "${tag_args[@]}" || true
}

kopia_snapshot_object_id() {
  local object_id
  local tags_display

  tags_display="$(IFS=,; printf '%s' "$*")"
  object_id="$(kopia_snapshot_json_by_tags "$@" \
    | jq -er '
      if type == "array" then flatten else [.] end
      | map(select(.rootEntry.obj != null))
      | sort_by(.startTime // .endTime // "")
      | last
      | .rootEntry.obj // empty
    ' || true)"

  if [ -z "$object_id" ]; then
    die "snapshot not found for tags: ${tags_display}"
  fi

  printf '%s\n' "$object_id"
}

sed_replacement_escape() {
  sed -e 's/[\/&]/\\&/g'
}

generate_from_template() {
  local template="$1"
  local target="$2"
  local sed_args=()
  local placeholder value

  shift 2

  while [ "$#" -gt 0 ]; do
    placeholder="$1"
    value="$(printf '%s' "$2" | sed_replacement_escape)"
    sed_args+=(-e "s/${placeholder}/${value}/g")
    shift 2
  done

  mkdir -p "$(dirname "$target")"
  sed "${sed_args[@]}" "$template" >"$target"
}

generate_fractald_config() {
  local user="$1"
  local password="$2"
  local template="${REPO_ROOT}/fractald/conf/bitcoin.conf.example"
  local target="${REPO_ROOT}/fractald/conf/bitcoin.conf"

  generate_from_template "$template" "$target" \
    "{REPLACE_RPC_USER}" "$user" \
    "{REPLACE_RPC_PASSWORD}" "$password"
}

generate_fractal_indexer_chain_config() {
  local rpc_user="$1"
  local rpc_password="$2"
  local template="${REPO_ROOT}/fractal-indexer/conf/indexer/chain.yaml.example"
  local target="${REPO_ROOT}/fractal-indexer/conf/indexer/chain.yaml"

  generate_from_template "$template" "$target" \
    "{REPLACE_RPC_USER}" "$rpc_user" \
    "{REPLACE_RPC_PASSWORD}" "$rpc_password"
}

generate_stake_indexer_chain_config() {
  local rpc_user="$1"
  local rpc_password="$2"
  local template="${REPO_ROOT}/stake-indexer/conf/indexer/chain.yaml.example"
  local target="${REPO_ROOT}/stake-indexer/conf/indexer/chain.yaml"

  generate_from_template "$template" "$target" \
    "{REPLACE_RPC_USER}" "$rpc_user" \
    "{REPLACE_RPC_PASSWORD}" "$rpc_password"
}

generate_proof_publisher_config() {
  local rpc_user="$1"
  local rpc_password="$2"
  local template="${REPO_ROOT}/proof-publisher/config.example.json"
  local target="${REPO_ROOT}/proof-publisher/config.json"

  generate_from_template "$template" "$target" \
    "REPLACE_RPC_USER" "$rpc_user" \
    "REPLACE_RPC_PASSWORD" "$rpc_password" \
    "REPLACE_PRIVATE_KEY_WIF" "${PROOF_PRIVATE_KEY_WIF:-REPLACE_PRIVATE_KEY_WIF}" \
    "REPLACE_CHANGE_ADDRESS" "${PROOF_CHANGE_ADDRESS:-REPLACE_CHANGE_ADDRESS}" \
    "REPLACE_REWARD_ADDRESS" "${PROOF_REWARD_ADDRESS:-REPLACE_REWARD_ADDRESS}" \
    "REPLACE_INDEXER_NAME" "${PROOF_INDEXER_NAME:-REPLACE_INDEXER_NAME}" \
    "REPLACE_EXISTING_INDEXER_ID_OR_EMPTY" "${PROOF_INDEXER_ID:-}" \
    "REPLACE_UNISAT_OPEN_API_KEY" "${PROOF_UNISAT_OPEN_API_KEY:-REPLACE_UNISAT_OPEN_API_KEY}"
}

proof_publisher_can_start() {
  [ -n "${PROOF_PRIVATE_KEY_WIF:-}" ] \
    && [ -n "${PROOF_CHANGE_ADDRESS:-}" ] \
    && [ -n "${PROOF_REWARD_ADDRESS:-}" ] \
    && [ -n "${PROOF_INDEXER_NAME:-}" ] \
    && [ -n "${PROOF_UNISAT_OPEN_API_KEY:-}" ]
}
