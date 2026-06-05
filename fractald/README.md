# Fractald

`fractald` deploys a Fractal Bitcoin node for the local indexer stacks. It
serves RPC and ZMQ traffic to `fractal-indexer`, `stake-indexer`, and the
optional `proof-publisher` on the shared Docker network.

## Directory Layout

- `docker-compose.yaml`: stack definition
- `scripts/init.sh`: creates local directories and config files
- `conf/bitcoin.conf.example`: template for Fractald runtime configuration

Runtime blockchain data is stored in `data/`.

## Prerequisites

- Docker and Docker Compose
- Permission to run `sudo chown` from `scripts/init.sh`
- Enough disk for the selected node mode or restored snapshot

## Configuration

Create local config before first start:

```bash
cp conf/bitcoin.conf.example conf/bitcoin.conf
```

Edit `conf/bitcoin.conf` and set:

- `rpcuser`
- `rpcpassword`

The default ports are:

- P2P: `10333`
- ZMQ raw block: `10330`
- ZMQ raw transaction: `10331`
- RPC: `10332`

These defaults match the indexer examples, where other Compose stacks reach the
node through Docker DNS as `fractald`.

## Manual Deployment

Run these steps when deploying `fractald` by itself instead of using the
top-level `scripts/deploy.sh` workflow:

```bash
cd fractald
cp conf/bitcoin.conf.example conf/bitcoin.conf
```

Edit `conf/bitcoin.conf`, set `rpcuser` and `rpcpassword`, then initialize and
start the stack:

```bash
bash ./scripts/init.sh
docker compose up -d
```

## Initialization

Prepare local directories and create local config files if missing:

```bash
bash ./scripts/init.sh
```

## Start the Stack

```bash
docker compose up -d
```

## Verify the Deployment

```bash
docker compose ps
docker compose logs --tail=100 -f fractald
docker compose exec fractald bitcoin-cli --conf=/conf/bitcoin.conf getblockchaininfo
```

RPC and ZMQ are internal-only by default and are available to containers on the
shared Docker network as `fractald:10332`, `fractald:10330`, and
`fractald:10331`.

The P2P port `10333` is published publicly by default.
