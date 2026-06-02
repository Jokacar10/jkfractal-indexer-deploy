# Fractal Indexer Deploy

This repository provides Docker Compose deployments for Fractal network services:

- `fractal-indexer/`: indexes BRC20 data and exposes a query API
- `stake-indexer/`: indexes staking data and depends on the Fractal indexer API
- `proof-publisher/`: optional proof submission daemon that publishes `register` and `prove` inscriptions

Each stack is self-contained and should be started from its own directory.

Upstream project repositories:

- `fractal-indexer`: [github.com/fractal-bitcoin/fractal-indexer](https://github.com/fractal-bitcoin/fractal-indexer)
- `stake-indexer`: [github.com/fractal-bitcoin/stake-indexer](https://github.com/fractal-bitcoin/stake-indexer)
- `fractal-proof-publisher`: [github.com/fractal-bitcoin/fractal-proof-publisher](https://github.com/fractal-bitcoin/fractal-proof-publisher)

## Service Endpoints

- Fractal indexer API: `http://localhost:8000`
- Stake indexer API: `http://localhost:9637`
- Proof publisher health: `http://localhost:8080/healthz`

## Prerequisites

This deployment requires a running `fractald` node. `fractal-indexer` depends on the node's RPC and ZMQ interfaces; `stake-indexer` uses the node's RPC interface and the Fractal indexer API. The optional proof publisher uses Fractald RPC, the Fractal indexer API, and local signing material.

- Fractald deployment guide: [github.com/fractal-bitcoin/fractald-release](https://github.com/fractal-bitcoin/fractald-release)

## Resource Requirements

- `fractal-indexer`: disk `400 GB+`, minimum memory `64 GB`, recommended memory `128 GB`
- `stake-indexer`: disk `1 GB+`, minimum memory `1 GB`, recommended memory `1 GB`

## Quick Start

Follow the steps below in order. Start `fractal-indexer` first, then `stake-indexer`. Start `proof-publisher` only if this node should publish proofs on chain.

### 1. Clone this repository

```bash
git clone https://github.com/fractal-bitcoin/fractal-indexer-deploy
cd fractal-indexer-deploy
```

### 2. Prepare the chain configuration

Create local config files from the examples:

```bash
cp fractal-indexer/conf/indexer/chain.yaml.example fractal-indexer/conf/indexer/chain.yaml
cp stake-indexer/conf/indexer/chain.yaml.example stake-indexer/conf/indexer/chain.yaml
```

Then review these files:

- `fractal-indexer/conf/indexer/chain.yaml`
- `stake-indexer/conf/indexer/chain.yaml`

`fractal-indexer/conf/indexer/chain.yaml.example` points to a Fractald node at:

- `zmq_block: tcp://fractald:10330`
- `zmq_tx: tcp://fractald:10331`
- `rpc: http://fractald:10332`

`stake-indexer/conf/indexer/chain.yaml.example` only needs Fractald RPC:

- `rpc: http://fractald:10332`

Set `rpc_auth` to `<user>:<password>`, and change the host or ports if your node is not reachable as `fractald` from the containers.

If `stake-indexer` needs to read chain state from a different Fractal indexer endpoint, update `state_api_base_url` in `stake-indexer/conf/indexer/config.yaml`. The default is `http://fractal-indexer:8000`.

### 3. Start `fractal-indexer`

```bash
cd fractal-indexer
bash ./scripts/init.sh db
docker-compose up -d
cd ..
```

After startup, the indexer begins syncing chain data. This can take a long time. If you want a faster startup, use the snapshot described in [Fractal Indexer Snapshot](#fractal-indexer-snapshot).

### 4. Start `stake-indexer`

```bash
cd stake-indexer
bash ./scripts/init.sh
docker-compose up -d
cd ..
```

### 5. Optional: start `proof-publisher`

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

## Fractal Indexer Snapshot

The snapshot allows `fractal-indexer` to start from preloaded data instead of syncing from scratch.

The latest available snapshot in this README is at height `1753260`.

Before restoring a snapshot:

- stop all `fractal-indexer` services
- clear the existing `fractal-indexer/data` directory

Download and extract the snapshot:

```bash
mkdir -p fractal-indexer/data
cd fractal-indexer/data

curl https://snapshot.fractalbitcoin.io/fractal-indexer/1753260/pika-brc20.tar.zst | tar --zstd -xf -
curl https://snapshot.fractalbitcoin.io/fractal-indexer/1753260/brc20-base.tar.zst | tar --zstd -xf -
curl https://snapshot.fractalbitcoin.io/fractal-indexer/1753260/pika.tar.zst | tar --zstd -xf -
curl https://snapshot.fractalbitcoin.io/fractal-indexer/1753260/clickhouse.tar.zst | tar --zstd -xf -
cd ../..
```

These files are large, so downloading and extracting them may take from one hour to several hours.

After the snapshot is restored, run the initialization script once to fix directory ownership:

```bash
cd fractal-indexer
bash ./scripts/init.sh
```

Then start the stack:

```bash
docker-compose up -d
```

## Changelog

### 20260602

1. Updated `stake-indexer` to version `v0.2.0`.
2. Updated `stake-indexer/conf/indexer/config.yaml`.


### 20260526

1. Updated `stake-indexer` to version `v0.1.1`.
2. Updated `stake-indexer/conf/indexer/config.yaml`.

