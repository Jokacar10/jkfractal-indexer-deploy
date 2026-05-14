# Fractal Proof Publisher

This optional stack runs `fractal-proof-publisher`, a proof submission daemon
that publishes `register` and `prove` inscriptions on Bitcoin.

It is intentionally separate from the `fractal-indexer` and `stake-indexer`
stacks because it holds signing material and can broadcast transactions.

## Dependencies

- A running Fractald node with RPC reachable from Docker as `http://fractald:10332`
- A running Fractal indexer API reachable as `http://fractal-indexer:8000`
- A signing private key and change address
- A UniSat Open API key when using the default `unisat_open_api` mode

`docker-compose.yaml` maps `fractald` and `fractal-indexer` to the Docker host
with `extra_hosts`. Keep these defaults when Fractald and the Fractal indexer
API are published on the host. Otherwise, update `config.json` and the compose
host mappings.

## Configuration

Create a local config:

```bash
cp config.example.json config.json
```

Edit `config.json` and set:

- `bitcoin_rpc.user`
- `bitcoin_rpc.password`
- `signing.private_key_wif` or `signing.private_key_hex`
- `signing.change_address`
- `register.reward_addr`
- `register.name`
- `runtime.unisat_open_api_key`

If the indexer is already registered, set `register.indexer_id` to the existing
value. If it is empty, the publisher will create and advance a `register`
submission before publishing proofs.

The default state API setting is:

```json
"state_api": {
  "base_url": "http://fractal-indexer:8000",
  "provider": "query-fip101"
}
```

This makes the publisher read state hashes from:

```text
GET /brc20/statehash?start={height}&end={height}
```

## Start

```bash
bash ./scripts/init.sh
docker-compose up -d
```

## Verify

```bash
docker-compose ps
docker-compose logs --tail=100 -f proof-publisher
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/status
```

## Notes

- Do not commit `config.json`, private keys, API keys, or the `data/` directory.
- Test with a small funded address before enabling production publishing.
- In `unisat_open_api` mode, `signing.initial_utxos` can remain empty because
  UTXOs are fetched from UniSat Open API.
