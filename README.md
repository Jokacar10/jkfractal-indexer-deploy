# Fractal Indexer Deploy

This repository provides Docker Compose deployments for Fractal network services:

- `fractald/`: runs the Fractal node used by the indexers
- `fractal-indexer/`: indexes BRC20 data and exposes a query API
- `stake-indexer/`: indexes staking data and depends on the Fractal indexer API
- `proof-publisher/`: optional proof submission daemon that publishes `register` and `prove` inscriptions

The top-level deploy script orchestrates these stacks. Each service directory
also contains its own Docker Compose files and initialization scripts.

Upstream project repositories:

- `fractald`: [github.com/fractal-bitcoin/fractald-release](https://github.com/fractal-bitcoin/fractald-release)
- `fractal-indexer`: [github.com/fractal-bitcoin/fractal-indexer](https://github.com/fractal-bitcoin/fractal-indexer)
- `stake-indexer`: [github.com/fractal-bitcoin/stake-indexer](https://github.com/fractal-bitcoin/stake-indexer)
- `fractal-proof-publisher`: [github.com/fractal-bitcoin/fractal-proof-publisher](https://github.com/fractal-bitcoin/fractal-proof-publisher)

## Service Endpoints

- Fractald RPC: `http://localhost:10332`
- Fractal indexer API: `http://localhost:8000`
- Stake indexer API: `http://localhost:9637`
- Proof publisher health: `http://localhost:8080/healthz`

## Prerequisites

Install these tools before running the deploy script:

- Docker with Docker Compose
- `jq`, See the official installation guide: [https://jqlang.org/download/](https://jqlang.org/download/)
- `kopia`, required for snapshot restore. See the official Kopia installation guide: [kopia.io/docs/installation](https://kopia.io/docs/installation/)

## Resource Requirements

- `fractald`: disk `400 GB+`, minimum memory `8 GB`, recommended memory `16 GB`
- `fractal-indexer`: disk `400 GB+`, minimum memory `64 GB`, recommended memory `128 GB`

## Quick Start

`scripts/deploy.sh` only supports fresh deployments by default. To redeploy,
stop all services first and remove the runtime `data` directories before running
the script again:

```bash
scripts/stop.sh

rm -rf fractald/data fractal-indexer/data stake-indexer/data proof-publisher/data
```

The `--force` option skips existing data directory checks. When used with
`--snapshot`, snapshot restore also enables Kopia `--delete-extra`, so files in
the target data directories that are not present in the selected snapshot are
deleted.

The recommended quick start deploys from Kopia snapshots. This avoids syncing
`fractald` and rebuilding `fractal-indexer` data from genesis.

The current default snapshot height is `1820067`:

```bash
git clone https://github.com/fractal-bitcoin/fractal-indexer-deploy
cd fractal-indexer-deploy

scripts/deploy.sh --snapshot=1820067
```

The deploy script starts `fractald`, `fractal-indexer`, and `stake-indexer`, and
generates `proof-publisher/config.json`. It starts `proof-publisher` only when
all signing and broadcast environment variables are provided.

## Manual Service Deployment

For manual deployment of individual services, see the README in each service
directory:

- `fractald`: [fractald/README.md](fractald/README.md)
- `fractal-indexer`: [fractal-indexer/README.md](fractal-indexer/README.md)
- `stake-indexer`: [stake-indexer/README.md](stake-indexer/README.md)
- `proof-publisher`: [proof-publisher/README.md](proof-publisher/README.md)

## Fractald Deployment

`fractald` is started by `scripts/deploy.sh` before the indexers. The script
generates `fractald/conf/bitcoin.conf` with RPC credentials on first run. If
`fractald/conf/bitcoin.conf` already exists, the script reads the existing
`rpcuser` and `rpcpassword` and reuses them for all generated indexer configs.

When deploying with `--snapshot`, the script restores the Fractald `blocks` and
`chainstate` datasets before starting the node, then waits until Fractald RPC
responds successfully.

Fractald exposes these container ports through Docker Compose:

- P2P: `10333`
- RPC: `10332`
- ZMQ raw block: `10330`
- ZMQ raw transaction: `10331`

## Restore One Snapshot Dataset

Use `scripts/restore-kopia-snapshot.sh` to restore a single Kopia snapshot
dataset by height, dataset name, and target directory:

```bash
scripts/restore-kopia-snapshot.sh \
  --height=1820067 \
  --dataset=fractald-blocks \
  --target=fractald/data/blocks
```

By default, the restore script deletes files in the target directory that are not
present in the snapshot. Add `--no-delete-extra` to keep extra files.

Common datasets:

- `fractald-blocks` to `fractald/data/blocks`
- `fractald-chainstate` to `fractald/data/chainstate`
- `fractal-indexer-data` to `fractal-indexer/data`

## Deploy Without Snapshots

You can run the deploy script without `--snapshot`:

```bash
scripts/deploy.sh
```

Without snapshots, Fractald must sync from genesis and `fractal-indexer` must
build its data from the beginning. This can take a long time.

Before running without snapshots, consider removing the Fractald `prune`
configuration from `fractald/conf/bitcoin.conf` or
`fractald/conf/bitcoin.conf.example`. Running `fractal-indexer` against a pruned
node may cause indexing failures.

A full node plus full index data requires more than `3 TB` of disk space. For a
full index rebuild from genesis, `128 GB+` memory is recommended.

## Optional Proof Publisher

The proof publisher holds a signing key and can broadcast transactions, so it is
not started by default.

```bash
cd proof-publisher
cp config.example.json config.json
```

Edit `config.json` and set the Fractald RPC credentials, signing key, change
address, reward address, indexer name, and UniSat Open API key. The default
`state_api.base_url` is `http://fractal-indexer:8000`, which points to the
Fractal indexer API through Docker host mapping.

Then start it:

```bash
bash ./scripts/init.sh
docker-compose up -d
cd ..
```

## Validation

Use these commands after startup:

```bash
docker-compose ps
docker-compose logs --tail=100 -f
```

Check:

- `http://localhost:8000/brc20/bestheight` for the Fractal indexer API
- `http://localhost:9637/indexer/status` for the stake indexer API
- `http://localhost:8080/healthz` for the optional proof publisher

## Changelog

### 20260602

1. Updated `stake-indexer` to version `v0.2.0`.
2. Updated `stake-indexer/conf/indexer/config.yaml`.


### 20260526

1. Updated `stake-indexer` to version `v0.1.1`.
2. Updated `stake-indexer/conf/indexer/config.yaml`.
