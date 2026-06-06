#!/bin/bash
set -ex

NETWORK_NAME="fractal-indexer-fip101-net"
docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME" >/dev/null

mkdir -p ./data/pgdata ./data/redis
sudo chown -R 999:999 ./data/pgdata
