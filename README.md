# LND Esplora Testing

Test environment for LND's Esplora backend implementation.

## Prerequisites

- Docker and Docker Compose
- [just](https://github.com/casey/just) command runner
- LND built with esplora support (in `../lnd`)

## Quick Start

```bash
# Start bitcoind + electrs
just up

# Create a wallet and generate some blocks
just create-wallet
just generate 101

# Check it's working
just info
curl http://localhost:3002/blocks/tip/height
```

## Available Commands

```bash
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

## Endpoints

| Service  | Port  | URL                        |
| -------- | ----- | -------------------------- |
| Esplora  | 3002  | http://localhost:3002      |
| Electrum | 50001 | tcp://localhost:50001      |
| Bitcoin  | 18443 | http://localhost:18443     |

## Credentials

- Bitcoin RPC: `bitcoin:bitcoin`
