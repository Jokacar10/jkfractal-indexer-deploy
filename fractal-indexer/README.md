# Fractal Indexer

`fractal-indexer` deploys the BRC20 indexing stack for the Fractal network. It runs two application containers plus the required storage services:

- `indexer`: ingests chain data and writes indexed state
- `api`: serves query traffic on port `8000`
- `clickhouse`: analytical storage
- `pika`: key-value storage for indexer state
- `pika-brc20`: key-value storage used by the API

## Directory Layout

- `docker-compose.yaml`: stack definition
- `scripts/init.sh`: creates local data directories and optionally initializes the database
- `conf/indexer/chain.yaml.example`: template for Fractal node connectivity
- `conf/indexer/db.yaml`: ClickHouse connection settings
- `conf/indexer/kvdb.yaml`: Pika settings for the indexer
- `conf/indexer/api/conf.yaml`: API runtime settings
- `conf/indexer/api/kvdb_brc20.yaml`: Pika settings for API reads
- `conf/pika/pika.conf`: Pika server configuration

## Prerequisites

- Docker and Docker Compose
- A reachable Fractal node with ZMQ and RPC enabled
- Permission to run `sudo chown` from `scripts/init.sh`

## Configuration

Create the chain config before first start:

```bash
cp conf/indexer/chain.yaml.example conf/indexer/chain.yaml
```

Edit `conf/indexer/chain.yaml` and set:

- `zmq_block`
- `zmq_tx`
- `rpc`
- `rpc_auth`

The example uses `fractald` as the node hostname. This works when `fractald` is
attached to the shared external Docker network `fractal-indexer-fip101-net`.

## Manual Deployment

Run these steps when deploying `fractal-indexer` by itself instead of using the
top-level `scripts/deploy.sh` workflow:

```bash
cd fractal-indexer
cp conf/indexer/chain.yaml.example conf/indexer/chain.yaml
```

Edit `conf/indexer/chain.yaml` so `zmq_block`, `zmq_tx`, `rpc`, and `rpc_auth`
point to your Fractald node. Then prepare local data, initialize the DB, and
start the indexer:

```bash
bash ./scripts/init.sh db
docker compose up -d
```

## Initialization

Prepare local directories:

```bash
bash ./scripts/init.sh
```

Initialize the index tables before the first full start:

```bash
bash ./scripts/init.sh db
```

The `db` mode runs:

```bash
docker compose run --rm indexer -full -end 256
```

## Start the Stack

```bash
docker compose up -d indexer api
```

This also starts the dependent `clickhouse`, `pika`, and `pika-brc20` services through `depends_on`.

## Verify the Deployment

```bash
docker compose ps
docker compose logs --tail=100 -f indexer api
```

API endpoint:

- `http://localhost:8000`

The API port binds to `127.0.0.1` by default. Set `BIND_HOST=0.0.0.0` only when
external access is required and the host firewall/security group is configured.

The API may take time to become ready after startup because it needs to load indexed data first.
