#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/stop.sh

Stops all Docker Compose services managed by this repository:
  proof-publisher
  stake-indexer
  fractal-indexer
  fractald
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 0 ]; then
  usage_error "unexpected arguments"
fi

require_command docker
compose_cmd >/dev/null

stop_stack() {
  local name="$1"
  local dir="$2"

  log "Stopping ${name}"
  run_compose "$dir" down
}

stop_stack proof-publisher "${REPO_ROOT}/proof-publisher"
stop_stack stake-indexer "${REPO_ROOT}/stake-indexer"
stop_stack fractal-indexer "${REPO_ROOT}/fractal-indexer"
stop_stack fractald "${REPO_ROOT}/fractald"

log "All services stopped"
