#!/bin/bash
set -e

NETWORK_NAME="fractal-indexer-fip101-net"
docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME" >/dev/null

echo ">>> Init Directory"
(
set -x
mkdir -p data conf
test -f conf/bitcoin.conf || cp conf/bitcoin.conf.example conf/bitcoin.conf
sudo chown -R 1000:1000 data
)

if grep -q "REPLACE_RPC_" conf/bitcoin.conf; then
  cat <<'MSG'
>>> Update conf/bitcoin.conf before starting fractald.
    Set rpcuser and rpcpassword to non-placeholder values.
MSG
fi
