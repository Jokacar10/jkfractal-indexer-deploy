#!/bin/bash
set -e

echo ">>> Init Directory"
(
set -x
mkdir -p data/{clickhouse,pika,pika-brc20,brc20}
mkdir -p data/pika/{db,dump}
mkdir -p data/pika-brc20/{db,dump}
mkdir -p logs/{clickhouse,pika,pika-brc20}
sudo chown -R 1000:1000 data logs
sudo chown -R 101:101 data/clickhouse logs/clickhouse
)

if [ "${1:-}" = "db" ]; then
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: missing docker compose command" >&2
    exit 1
  fi

  echo ">>> Init Database"
  set -x
  docker compose run --rm indexer -full -end 256
  set +x
fi
