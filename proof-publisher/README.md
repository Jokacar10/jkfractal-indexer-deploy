# Fractal Proof Publisher

`proof-publisher` runs `fractal-proof-publisher`, the service that registers
your Fractal indexer and publishes `prove` inscriptions from your indexed state.
In this deployment repository it is a required component for users who want to
submit proofs and receive proof submission rewards.

The service holds signing material and can broadcast transactions. Configure it
manually, review every address and key, and start it only after the Fractal node
and Fractal indexer API are running.

## What It Does

- Publishes a `register` inscription when `register.indexer_id` is empty.
- Publishes `prove` inscriptions for eligible block heights.
- Reads state hashes from the local Fractal indexer API.
- Signs commit/reveal transactions with the configured publishing wallet.
- Broadcasts transactions through UniSat Open API in the default deployment
  mode, or through Fractald RPC in advanced default mode.
- Stores local progress in SQLite under `data/`.

## Dependencies

- A running Fractald node with RPC reachable from Docker as `http://fractald:10332`
- A running Fractal indexer API reachable as `http://fractal-indexer:8000`
- A funded publishing wallet private key and its change address
- A reward address for indexer registration
- A UniSat Open API key when using `runtime.mode: "unisat_open_api"`

The default compose file expects Fractald and the Fractal indexer API to be
attached to the shared external Docker network `fractal-indexer-fip101-net`.

## Quick Configuration

Run the top-level deployment first so `fractald` and `fractal-indexer` are
configured and started:

```bash
cd ..
scripts/deploy.sh --snapshot=latest
```

Then review the proof publisher config:

```bash
cd proof-publisher
cp config.example.json config.json  # only if config.json does not already exist
```

`scripts/deploy.sh` can generate `proof-publisher/config.json` with the Fractald
RPC credentials and Fractal indexer API address. You still need to review and
set the signing wallet, reward address, indexer name, and UniSat Open API key.

For the recommended `unisat_open_api` mode, set:

- `bitcoin_rpc.user`
- `bitcoin_rpc.password`
- `signing.private_key_wif` or `signing.private_key_hex`
- `signing.change_address`
- `register.reward_addr`
- `register.name`
- `runtime.mode`: `unisat_open_api`
- `runtime.unisat_open_api_key`

If the indexer is already registered, set `register.indexer_id` to the existing
value. If it is empty, the publisher creates a `register` submission before
publishing proofs.

Start the service:

```bash
bash ./scripts/init.sh
docker compose up -d
```

## Required Config Values

### Fractald RPC

`bitcoin_rpc.user` and `bitcoin_rpc.password` come from
`fractald/conf/bitcoin.conf`:

```text
rpcuser=...
rpcpassword=...
```

When you use the top-level `scripts/deploy.sh`, it generates or reuses these
credentials and can write them into `proof-publisher/config.json`.

`bitcoin_rpc.url` should normally stay as:

```json
"url": "http://fractald:10332"
```

### Fractal Indexer API

`state_api.base_url` should normally stay as:

```json
"base_url": "http://fractal-indexer:8000"
```

With `provider: "query-fip101"`, the publisher reads state hashes from:

```text
GET /brc20/statehash?start={height}&end={height}
```

### UniSat Open API Key

The recommended deployment mode uses UniSat Open API for UTXO lookup and
transaction broadcast.

To get the key:

1. Open [UniSat Developer Center](https://developer.unisat.io/).
2. Register or log in.
3. Find the `Fractal Mainnet` page.
4. Copy the `API-Key`.
5. Put it in `runtime.unisat_open_api_key`.

Reference documentation:
[docs.unisat.io/developer-support/open-api-documentation](https://docs.unisat.io/developer-support/open-api-documentation)

You can paste the raw API key. The publisher normalizes it to Bearer token
format internally.

### Publishing Private Key

`signing.private_key_wif` or `signing.private_key_hex` is the private key used
to sign `register` and `prove` commit/reveal transactions.

Recommended setup:

1. Create a dedicated Fractal/Bitcoin-compatible wallet for publishing.
2. Export the private key for that wallet address in WIF format.
3. Set it as `signing.private_key_wif`.
4. Send a small amount of FB to the wallet address for publishing costs and
   transaction fees.

Do not use a main treasury wallet or a wallet holding large funds. This service
is a hot-wallet process.

### Change Address

`signing.change_address` is the address controlled by the publishing private
key. Commit transaction change and reveal outputs are sent to this address.

Use the address that matches `signing.private_key_wif` or
`signing.private_key_hex`. If the private key cannot spend funds from
`signing.change_address`, transaction signing or later spending will fail.

### Reward Address

`register.reward_addr` is the reward address announced when the publisher
registers your indexer.

It can be the same as `signing.change_address`, but using a separate receiving
or cold-wallet address is safer for long-term funds. Set
`register.reward_addr_type` to match the address type, for example `p2wpkh`.

### Indexer Name and ID

- `register.name`: public name for your indexer registration.
- `register.indexer_id`: existing on-chain indexer ID.

Leave `register.indexer_id` empty for a new registration. After registration is
confirmed, the publisher stores the indexer ID in its local SQLite database. If
you are moving an existing registered indexer to this deployment, set the known
ID before starting.

## Runtime Mode

### Recommended: `unisat_open_api`

This deployment template is designed for:

```json
"runtime": {
  "mode": "unisat_open_api",
  "unisat_open_api_url": "https://open-api.unisat.io",
  "unisat_open_api_key": "REPLACE_UNISAT_OPEN_API_KEY"
}
```

In this mode:

- `runtime.unisat_open_api_url` and `runtime.unisat_open_api_key` are required.
- `signing.initial_utxos` can remain empty.
- UTXOs are fetched from UniSat Open API for `signing.change_address`.
- Commit and reveal transactions are pushed through UniSat Open API.
- Fractald RPC is still required for block reads and scanning.

### Advanced: `default`

The upstream publisher treats only `unisat_open_api` as a special runtime mode.
An empty value, `default`, or any other string uses default mode.

In default mode:

- `runtime.unisat_open_api_key` is not required.
- `signing.initial_utxos` must contain at least one spendable UTXO.
- Commit and reveal transactions are broadcast with Fractald RPC
  `sendrawtransaction`.
- Commit and reveal confirmations are detected by scanning blocks through
  Fractald RPC.

Each `signing.initial_utxos` item must describe an unspent output controlled by
the signing key:

```json
{
  "txid": "REPLACE_TXID",
  "vout": 0,
  "amount_sat": 100000,
  "address": "REPLACE_UTXO_ADDRESS",
  "script_pub_key": "REPLACE_SCRIPT_PUB_KEY",
  "address_type": "p2wpkh"
}
```

`script_pub_key` must be the output script for that exact UTXO, and
`address_type` must match the address type used by the output, such as
`p2wpkh`, `p2tr`, `p2sh-p2wpkh`, or `p2pkh`. Do not reuse UTXOs that are spent
or reserved by another process.

## Operational Flags

- `runtime.dry_run=true`: exits without doing publishing work.
- `runtime.disable_broadcast=true`: builds and records transactions but does
  not broadcast them.
- `runtime.health_addr`: starts the local health/status HTTP server, default
  `:8080`.

## Verify

```bash
docker compose ps
docker compose logs --tail=100 -f proof-publisher
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/status
```

The health/API port binds to `127.0.0.1` by default. Set `BIND_HOST=0.0.0.0`
only when external access is required and the host firewall/security group is
configured.

## Security Notes

- Do not commit `config.json`, private keys, API keys, or the `data/` directory.
- Use a dedicated hot wallet and fund it with only the amount needed for
  publishing and fees.
- Test with a small balance before running long-term.
- Back up the publishing wallet key securely.
- Do not expose Fractald RPC, databases, caches, or proof publisher status APIs
  to the public internet unless your firewall and access controls are already
  configured.
