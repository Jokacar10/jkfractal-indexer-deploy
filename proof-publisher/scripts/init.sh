#!/bin/bash
set -e

NETWORK_NAME="fractal-indexer-fip101-net"
docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME" >/dev/null

echo ">>> Init Directory"
(
set -x
mkdir -p data
sudo chown -R 10001:10001 data
)
