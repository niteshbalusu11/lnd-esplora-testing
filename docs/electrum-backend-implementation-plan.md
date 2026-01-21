# Esplora Backend Implementation Plan for LND

This document describes the implementation of an Esplora HTTP API backend for LND, providing a lightweight way to connect to the Bitcoin blockchain without running a full node.

## Overview

The Esplora backend uses only HTTP REST API calls to interact with the blockchain. This provides a simpler, more consistent approach compared to the previous hybrid Electrum implementation that mixed TCP protocol with HTTP REST API.

**Supported Esplora API providers:**

- Local mempool/electrs instance (e.g., http://localhost:3002)
- Blockstream.info API (https://blockstream.info/api)
- Mempool.space API (https://mempool.space/api)
- Any compatible Esplora REST API

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         LND                                  │
├─────────────────────────────────────────────────────────────┤
│  chainreg/chainregistry.go                                  │
│  └── NewPartialChainControl() - creates Esplora components  │
├─────────────────────────────────────────────────────────────┤
│  esplora/                                                    │
│  ├── client.go          - HTTP client with block polling    │
│  ├── chainclient.go     - chain.Interface implementation    │
│  ├── fee_estimator.go   - Fee estimation via /fee-estimates │
│  └── scripthash.go      - Address to scripthash conversion  │
├─────────────────────────────────────────────────────────────┤
│  chainntnfs/esploranotify/                                  │
│  └── esplora.go         - ChainNotifier implementation      │
├─────────────────────────────────────────────────────────────┤
│  routing/chainview/                                         │
│  └── esplora.go         - FilteredChainView implementation  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Esplora HTTP API                          │
│             (mempool/electrs, blockstream, etc.)             │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Bitcoin Core                              │
│             (or any full node backend)                       │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Status

### Completed ✅

| Component          | File(s)                                             | Status      |
| ------------------ | --------------------------------------------------- | ----------- |
| Configuration      | `lncfg/esplora.go`                                  | ✅ Complete |
| HTTP Client        | `esplora/client.go`                                 | ✅ Complete |
| Chain Client       | `esplora/chainclient.go`                            | ✅ Complete |
| Fee Estimator      | `esplora/fee_estimator.go`                          | ✅ Complete |
| Scripthash Utils   | `esplora/scripthash.go`                             | ✅ Complete |
| Chain Notifier     | `chainntnfs/esploranotify/esplora.go`               | ✅ Complete |
| Chain View         | `routing/chainview/esplora.go`                      | ✅ Complete |
| Chain Registry     | `chainreg/chainregistry.go`                         | ✅ Complete |
| Config Validation  | `config.go`                                         | ✅ Complete |
| Logging            | `esplora/log.go`, `chainntnfs/esploranotify/log.go` | ✅ Complete |
| E2E Test Script    | `scripts/test-esplora-e2e.sh`                       | ✅ Complete |
| Force Close Test   | `scripts/test-esplora-force-close.sh`               | ✅ Complete |
| Wallet Rescan Test | `scripts/test-esplora-wallet-rescan.sh`             | ✅ Complete |
| SCB Restore Test   | `scripts/test-esplora-scb-restore.sh`               | ✅ Complete |

### Key Implementation Details

The Esplora backend has several important design decisions:

1. **Subscriber-based Block Notifications**: The `Client` uses a fan-out pattern where multiple consumers (ChainClient, EsploraNotifier, ChainView) each get their own subscription channel. This prevents race conditions where blocks would be lost when multiple goroutines read from a single channel.

2. **Sequential Block Processing**: The `ChainClient` tracks `lastProcessedHeight` and catches up on any missing intermediate blocks before processing new ones. This ensures btcwallet receives blocks in order (required for its internal consistency checks).

3. **Retry Logic**: `GetBlockHash` and `GetBlockHeader` include retry logic to handle race conditions where the Esplora API hasn't indexed a block yet.

4. **TestMempoolAccept Fallback**: Returns `rpcclient.ErrBackendVersion` to trigger the wallet to fall back to direct transaction broadcast (Esplora doesn't support mempool acceptance testing).

## Configuration

### Config File (lnd.conf)

```ini
[Bitcoin]
bitcoin.regtest=true
bitcoin.node=esplora

[esplora]
# Required: Base URL of the Esplora API
esplora.url=http://localhost:3002

# Optional: HTTP request timeout (default: 30s)
esplora.requesttimeout=30s

# Optional: Max retries for failed requests (default: 3)
esplora.maxretries=3

# Optional: Block polling interval (default: 10s)
esplora.pollinterval=10s

[protocol]
# Enable taproot channels (optional)
protocol.simple-taproot-chans=true
```

### Command Line

```bash
lnd --bitcoin.regtest --bitcoin.node=esplora \
    --esplora.url=http://localhost:3002 \
    --noseedbackup
```

### Public API URLs

| Network | Provider      | URL                                  |
| ------- | ------------- | ------------------------------------ |
| Mainnet | Blockstream   | https://blockstream.info/api         |
| Mainnet | Mempool.space | https://mempool.space/api            |
| Testnet | Blockstream   | https://blockstream.info/testnet/api |
| Testnet | Mempool.space | https://mempool.space/testnet/api    |
| Signet  | Mempool.space | https://mempool.space/signet/api     |

## API Endpoints Used

The Esplora client uses the following HTTP endpoints:

| Endpoint                       | Purpose                             |
| ------------------------------ | ----------------------------------- |
| `GET /blocks/tip/height`       | Get current blockchain height       |
| `GET /blocks/tip/hash`         | Get current tip block hash          |
| `GET /block/:hash`             | Get block info (JSON)               |
| `GET /block/:hash/header`      | Get raw block header                |
| `GET /block/:hash/txids`       | Get transaction IDs in block        |
| `GET /block-height/:height`    | Get block hash at height            |
| `GET /tx/:txid`                | Get transaction info (JSON)         |
| `GET /tx/:txid/hex`            | Get raw transaction hex             |
| `GET /tx/:txid/status`         | Get transaction confirmation status |
| `GET /tx/:txid/merkle-proof`   | Get merkle proof for tx             |
| `GET /tx/:txid/outspend/:vout` | Check if output is spent            |
| `GET /tx/:txid/outspends`      | Get spend status for all outputs    |
| `GET /address/:address/txs`    | Get address transactions            |
| `GET /address/:address/utxo`   | Get address UTXOs                   |
| `GET /scripthash/:hash/txs`    | Get scripthash transactions         |
| `GET /scripthash/:hash/utxo`   | Get scripthash UTXOs                |
| `GET /fee-estimates`           | Get fee rate estimates              |
| `POST /tx`                     | Broadcast transaction               |

## Key Features

### Block Polling

Since HTTP doesn't support subscriptions, the client polls for new blocks at regular intervals (configurable via `esplora.pollinterval`). The default is 10 seconds.

### Fee Estimation

Fee estimates are fetched from the `/fee-estimates` endpoint which returns fee rates in sat/vB for various confirmation targets. These are converted to sat/kw for LND's internal use.

### Spend Detection

The client uses the `/tx/:txid/outspend/:vout` endpoint to efficiently check if outputs have been spent, which is critical for channel close detection.

### Full Block Retrieval

Unlike the Electrum TCP protocol, Esplora's REST API supports fetching full blocks by retrieving all transaction IDs and then each transaction individually.

## Supported Operations

| Operation             | Status | Notes                        |
| --------------------- | ------ | ---------------------------- |
| Chain sync            | ✅     | Via block polling            |
| Block notifications   | ✅     | Via polling                  |
| Transaction broadcast | ✅     | POST /tx endpoint            |
| Fee estimation        | ✅     | /fee-estimates endpoint      |
| Address monitoring    | ✅     | Via scripthash queries       |
| Spend detection       | ✅     | Via outspend endpoint        |
| Full block retrieval  | ✅     | Via txids + tx hex endpoints |
| Channel opening       | ✅     | Full support                 |
| Channel closing       | ✅     | Cooperative and force close  |
| Lightning payments    | ✅     | Full support                 |
| Taproot channels      | ✅     | Full support                 |

## Limitations

1. **Polling vs Push**: New blocks are detected via polling, introducing a small delay compared to websocket-based backends.

2. **API Rate Limits**: Public Esplora APIs may have rate limits. For production use, consider running your own instance.

3. **Trust Model**: Like Electrum, this requires trusting the Esplora server for blockchain data accuracy.

4. **Privacy**: The Esplora server can see which addresses and transactions you're interested in.

## Differences from Electrum Backend

| Aspect              | Electrum (previous)    | Esplora (new)           |
| ------------------- | ---------------------- | ----------------------- |
| Protocol            | TCP + HTTP hybrid      | HTTP only               |
| Block notifications | TCP subscription       | HTTP polling            |
| Complexity          | Higher (two protocols) | Lower (single protocol) |
| Dependency          | go-electrum library    | Standard HTTP client    |
| Full blocks         | Via REST API fallback  | Native support          |

## Local Testing

### Prerequisites

1. Bitcoin Core running in regtest mode
2. mempool/electrs or similar Esplora-compatible server
3. LND built with default tags (no special build tag needed)

### Building LND

```bash
cd lnd
go build -o lnd-dev ./cmd/lnd
go build -o lncli-dev ./cmd/lncli
```

### Running

```bash
# Start LND with Esplora backend
./lnd-dev --bitcoin.regtest --bitcoin.node=esplora \
    --esplora.url=http://127.0.0.1:3002 \
    --noseedbackup --debuglevel=debug

# In another terminal, check status
./lncli-dev --network=regtest getinfo
```

## Debug Logging

Enable debug logging for Esplora components:

```ini
[Application Options]
debuglevel=ESPL=debug,ESPN=debug,CHRE=debug
```

Log subsystems:

- `ESPL` - Esplora client and chain client
- `ESPN` - Esplora chain notifier
- `CHRE` - Chain registry

## File Summary

### New Files Created

```
lnd/lncfg/esplora.go                    - Configuration struct
lnd/esplora/client.go                   - HTTP client with block polling
lnd/esplora/chainclient.go              - chain.Interface implementation
lnd/esplora/fee_estimator.go            - Fee estimation
lnd/esplora/scripthash.go               - Scripthash utilities
lnd/esplora/log.go                      - Logging setup
lnd/chainntnfs/esploranotify/esplora.go - Chain notifier
lnd/chainntnfs/esploranotify/driver.go  - Notifier driver registration
lnd/chainntnfs/esploranotify/log.go     - Logging setup
lnd/routing/chainview/esplora.go        - Filtered chain view
```

### Modified Files

```
lnd/config.go              - Added esploraBackendName, EsploraMode
lnd/lncfg/chain.go         - Added "esplora" choice
lnd/chainreg/chainregistry.go - Added esplora case
lnd/config_builder.go      - Pass EsploraMode to chain config
lnd/log.go                 - Register ESPL and ESPN subsystems
```

## Migration from Electrum

If you were previously using the Electrum backend with the REST API requirement:

**Before (Electrum):**

```ini
[Bitcoin]
bitcoin.node=electrum

[electrum]
electrum.server=127.0.0.1:50001
electrum.resturl=http://127.0.0.1:3002
```

**After (Esplora):**

```ini
[Bitcoin]
bitcoin.node=esplora

[esplora]
esplora.url=http://127.0.0.1:3002
```

The Esplora backend is simpler as it only requires a single URL configuration.

## Testing

### E2E Test Script

Run the full end-to-end test:

```bash
./scripts/test-esplora-e2e.sh [esplora_url]

# Example:
./scripts/test-esplora-e2e.sh http://127.0.0.1:3002
```

This tests:

- Chain sync
- Wallet funding
- Regular (anchors) channel open/close
- Taproot channel open/close
- Lightning payments

### Force Close Test Script

Run the force close test:

```bash
./scripts/test-esplora-force-close.sh [esplora_url]

# Example:
./scripts/test-esplora-force-close.sh http://127.0.0.1:3002
```

This tests:

- Force close initiation
- CSV timelock handling
- Sweep transaction creation
- Time-locked output recovery

### Wallet Rescan Test Script

Run the wallet rescan/recovery test:

```bash
./scripts/test-esplora-wallet-rescan.sh [esplora_url]

# Example:
./scripts/test-esplora-wallet-rescan.sh http://127.0.0.1:3002
```

This tests:

- Wallet creation with seed phrase (no `noseedbackup`)
- On-chain funding with multiple UTXOs (P2WPKH and P2TR)
- Wallet data deletion (simulating data loss)
- Wallet restoration from seed phrase with birthday
- Blockchain rescan to recover funds
- UTXO discovery via Esplora scripthash/address queries

### SCB (Static Channel Backup) Restore Test Script

Run the SCB disaster recovery test:

```bash
./scripts/test-esplora-scb-restore.sh [esplora_url]

# Example:
./scripts/test-esplora-scb-restore.sh http://127.0.0.1:3002
```

This tests:

- Wallet creation with seed phrases for both nodes
- Channel opening and Lightning payments
- Saving channel.backup file before disaster
- Complete wallet data destruction (simulating data loss)
- Wallet restoration from seed phrase
- Channel backup restoration triggering DLP force close
- Fund recovery after force close resolution

## Future Improvements

1. **Connection pooling**: Add HTTP connection pooling for better performance
2. **Caching**: Implement more aggressive caching for block headers and transactions
3. **Multiple servers**: Support failover between multiple Esplora servers
4. **Batch requests**: Use batch endpoints where available for efficiency

## TODO: Cleanup Tasks

### Delete Old Electrum Code (After Esplora is Fully Tested)

The old Electrum backend implementation (which used a hybrid TCP protocol + REST API approach) is still in the codebase for reference. Once the Esplora HTTP-only implementation is fully tested and working, the following files should be deleted:

**Electrum package (`lnd/electrum/`):**

- `lnd/electrum/client.go` - TCP protocol client
- `lnd/electrum/methods.go` - Electrum RPC methods
- `lnd/electrum/rest.go` - REST client (functionality moved to esplora)
- `lnd/electrum/chainclient.go` - Chain interface implementation
- `lnd/electrum/chainview_adapter.go` - ChainView adapter
- `lnd/electrum/fee_estimator.go` - Fee estimator
- `lnd/electrum/scripthash.go` - Scripthash utilities (copied to esplora)
- `lnd/electrum/log.go` - Logging setup
- `lnd/electrum/*_test.go` - All test files

**Electrum notifier (`lnd/chainntnfs/electrumnotify/`):**

- `lnd/chainntnfs/electrumnotify/electrum.go`
- `lnd/chainntnfs/electrumnotify/driver.go`
- `lnd/chainntnfs/electrumnotify/log.go`

**Chainview:**

- `lnd/routing/chainview/electrum.go`
- `lnd/routing/chainview/electrum_test.go`

**Config:**

- `lnd/lncfg/electrum.go` - Electrum configuration

**Other files to update:**

- `lnd/config.go` - Remove `electrumBackendName` and `ElectrumMode`
- `lnd/lncfg/chain.go` - Remove "electrum" choice
- `lnd/chainreg/chainregistry.go` - Remove electrum case and imports
- `lnd/config_builder.go` - Remove ElectrumMode reference
- `lnd/log.go` - Remove ELEC and ELNF subsystem registrations
- `lnd/sample-lnd.conf` - Remove [electrum] section

**Test scripts:**

- `lnd/scripts/test-electrum-e2e.sh` - Delete (replaced by test-esplora-e2e.sh)
- `lnd/scripts/test-electrum-force-close.sh` - Delete (replaced by test-esplora-force-close.sh)

### Verification Before Deletion

Before deleting the Electrum code, verify:

1. [x] Esplora E2E tests pass (`./scripts/test-esplora-e2e.sh`)
2. [x] Channel open/close works correctly
3. [x] Lightning payments work
4. [x] Force close and sweep transactions work (`./scripts/test-esplora-force-close.sh`)
5. [x] Taproot channels work
6. [x] Fee estimation works
7. [x] Chain sync works reliably
8. [ ] Reorg handling works
