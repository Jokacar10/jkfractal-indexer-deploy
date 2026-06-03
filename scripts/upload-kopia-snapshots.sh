#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/upload-kopia-snapshots.sh <snapshot-height>

Required environment:
  AWS_ACCESS_KEY_ID       Write-capable Cloudflare R2 access key
  AWS_SECRET_ACCESS_KEY   Write-capable Cloudflare R2 secret key

Optional environment:
  KOPIA_R2_BUCKET              Default: kopia-repo
  KOPIA_R2_ENDPOINT            Default: eccc9c966ad74b3b2b15c2961767d059.r2.cloudflarestorage.com
  KOPIA_REPOSITORY_PASSWORD    Default: fractalbitcoin
  KOPIA_REPOSITORY_PREFIX      Default: fractald-pruned
  KOPIA_USERNAME               Default: fractalbitcoin
  KOPIA_HOSTNAME               Default: fractalbitcoin-fip101
  UPLOAD_BASE_DIR              Default: /opt/fractal-indexer-deploy
  ALLOW_PARTIAL_UPLOAD         Set to 1 to skip missing datasets
EOF
}

snapshot_height="${1:-}"

if [ "$#" -ne 1 ]; then
  usage_error "expected exactly one snapshot height argument"
fi

if ! is_numeric "$snapshot_height"; then
  usage_error "snapshot height must be numeric"
fi

require_command kopia
require_command jq
require_env AWS_ACCESS_KEY_ID
require_env AWS_SECRET_ACCESS_KEY
require_env KOPIA_REPOSITORY_PASSWORD

datasets=$(
  cat <<EOF
fractald-blocks|${UPLOAD_BASE_DIR}/fractald/data/blocks
fractald-chainstate|${UPLOAD_BASE_DIR}/fractald/data/chainstate
EOF
#fractal-indexer-brc20|${UPLOAD_BASE_DIR}/fractal-indexer/data/brc20
#fractal-indexer-clickhouse|${UPLOAD_BASE_DIR}/fractal-indexer/data/clickhouse
#fractal-indexer-pika|${UPLOAD_BASE_DIR}/fractal-indexer/data/pika
#fractal-indexer-pika-brc20|${UPLOAD_BASE_DIR}/fractal-indexer/data/pika-brc20
)

missing=0
while IFS='|' read -r dataset path; do
  [ -n "$dataset" ] || continue
  if [ ! -d "$path" ]; then
    warn "missing dataset ${dataset}: ${path}"
    missing=1
  fi
done <<EOF
$datasets
EOF

if [ "$missing" -ne 0 ] && [ "${ALLOW_PARTIAL_UPLOAD:-}" != "1" ]; then
  die "one or more dataset paths are missing; set ALLOW_PARTIAL_UPLOAD=1 to upload available datasets"
fi

if command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' | grep -E 'fractald|fractal-indexer|clickhouse|pika' >/dev/null 2>&1; then
    warn "related containers appear to be running; hot snapshots may be inconsistent"
  fi
fi

log "Connecting Kopia repository"
kopia_connect_s3

summary_file="$(mktemp)"
trap 'rm -f "$summary_file"' EXIT

while IFS='|' read -r dataset path; do
  [ -n "$dataset" ] || continue

  if [ ! -d "$path" ]; then
    warn "skipping missing dataset ${dataset}: ${path}"
    continue
  fi

  tag_args=(
    --tags="height:${snapshot_height}"
    --tags="network:fractal-mainnet"
    --tags="dataset:${dataset}"
  )

  log "Uploading ${dataset} from ${path}"
  kopia snapshot create "$path" "${tag_args[@]}"

  snapshot_id="$(kopia_snapshot_object_id "height:${snapshot_height}" "dataset:${dataset}")"

  printf '%s\t%s\t%s\t%s\n' "$snapshot_height" "$dataset" "$snapshot_id" "$path" >>"$summary_file"
done <<EOF
$datasets
EOF

log "Publish summary"
printf 'height\tdataset\tsnapshot_object\tpath\n'
cat "$summary_file"
