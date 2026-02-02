# LND Esplora Testing

Test environment for LND's Esplora backend implementation.

## Prerequisites

- Docker and Docker Compose
- [just](https://github.com/casey/just) command runner
- LND built with esplora support (in `../lnd`)

## Quick Start

```bash
# Start everything (containers, wallet, 150 blocks)
just setup-everything

# Check it's working
just info
curl http://localhost:3002/blocks/tip/height
```

## Available Commands

```bash
just setup-everything # Start containers, create wallet, generate 150 blocks
just up              # Start the environment
just down            # Stop and remove containers
just stop            # Stop containers
just reset           # Remove everything including volumes
just logs            # View all logs
just logs-bitcoind   # View bitcoind logs
just logs-electrs    # View electrs logs

# Bitcoin CLI
just bcli <command>  # Run bitcoin-cli commands
just create-wallet   # Create a test wallet
just generate 10     # Generate blocks
just newaddr         # Get a new address
just send <addr> <amt>  # Send bitcoin
just info            # Get blockchain info
```

## Running Tests

```bash
just test-e2e           # Full end-to-end test
just test-force-close   # Force close test
just test-wallet-rescan # Wallet recovery test
just test-scb-restore   # SCB disaster recovery test
just test-all           # Run all tests
```

### Environment Variables

| Variable         | Default         | Description                        |
| ---------------- | --------------- | ---------------------------------- |
| `LND_DIR`        | `../lnd`        | Path to LND source directory       |
| `RPC_USER`       | `bitcoin`       | Bitcoin RPC username               |
| `RPC_PASS`       | `bitcoin`       | Bitcoin RPC password               |
| `DOCKER_BITCOIN` | (auto-detected) | Docker container name for bitcoind |

Example with custom LND path:

```bash
LND_DIR=/path/to/lnd just test-e2e
```

## Endpoints

| Service  | Port  | URL                    |
| -------- | ----- | ---------------------- |
| Esplora  | 3002  | http://localhost:3002  |
| Electrum | 50001 | tcp://localhost:50001  |
| Bitcoin  | 18443 | http://localhost:18443 |

## Credentials

- Bitcoin RPC: `bitcoin:bitcoin`
