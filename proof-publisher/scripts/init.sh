#!/bin/bash
set -e

echo ">>> Init Directory"
(
set -x
mkdir -p data
sudo chown -R 10001:10001 data
)

