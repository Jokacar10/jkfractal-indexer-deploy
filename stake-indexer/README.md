# Stake Indexer

`stake-indexer` deploys the staking index service for the Fractal network. It depends on the Fractal indexer API for chain state and uses PostgreSQL plus Redis for storage.

## Components

- `indexer`: stake indexing API on port `9637`
- `postgres`: primary relational store on internal port `5432`
- `redis`: auxiliary cache and state store on internal port `6379`

## Directory Layout

- `docker-compose.yaml`: stack definition
- `scripts/init.sh`: prepares local data directories
- `conf/indexer/chain.yaml.example`: template for Fractal node connectivity
- `conf/indexer/config.yaml`: stake indexer runtime settings
- `conf/indexer/pg.yaml`: PostgreSQL connection settings
- `conf/indexer/rdb_utxo.yaml`: Redis connection for UTXO data
- `conf/indexer/rdb_balance.yaml`: Redis connection for balance data
- `conf/redis/redis.conf`: Redis server configuration

## Prerequisites

- Docker and Docker Compose
- A running `fractal-indexer` stack reachable as `http://fractal-indexer:8000` from this Compose network
- A reachable Fractal node with RPC enabled
- Permission to run `sudo chown` from `scripts/init.sh`

## Configuration

Create the chain config before first start:

```bash
cp conf/indexer/chain.yaml.example conf/indexer/chain.yaml
```

Edit `conf/indexer/chain.yaml` and set:

- `rpc`
- `rpc_auth`

Review `conf/indexer/config.yaml` as well. By default it expects the Fractal indexer API at:

```yaml
state_api_base_url: http://fractal-indexer:8000
state_api_timeout: 5s
```

`fractal-indexer` and `fractald` are reached through Docker DNS on the shared
external network `fractal-indexer-fip101-net`.

## Manual Deployment

Run these steps when deploying `stake-indexer` by itself instead of using the
top-level `scripts/deploy.sh` workflow:

```bash
cd stake-indexer
cp conf/indexer/chain.yaml.example conf/indexer/chain.yaml
```

Edit `conf/indexer/chain.yaml` so `rpc` and `rpc_auth` point to your Fractald
node. If needed, edit `conf/indexer/config.yaml` so `state_api_base_url` points
to your Fractal indexer API. Then initialize and start the stack:

```bash
docker network create fractal-indexer-fip101-net
bash ./scripts/init.sh
docker compose up -d
```

## Initialization

Prepare local directories:

```bash
bash ./scripts/init.sh
```

This creates `data/pgdata` and `data/redis`, then applies ownership for PostgreSQL.

## Start the Stack

```bash
docker compose up -d
```

## Verify the Deployment

```bash
docker compose ps
docker compose logs --tail=100 -f indexer postgres redis
```

Endpoints:

- Stake API: `http://localhost:9637`

PostgreSQL and Redis are internal-only by default. The Stake API binds to
`127.0.0.1` by default. Set `BIND_HOST=0.0.0.0` only when external access is
required and the host firewall/security group is configured.
