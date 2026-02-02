# LND Esplora Testing Justfile

set positional-arguments := true

# Default recipe to display available commands
default:
    @just --list

# Start the regtest environment (bitcoind + electrs)
up:
    docker compose up -d

# Stop the regtest environment and remove volumes
down:
    docker compose down -v

# Stop containers without removing them
stop:
    docker compose stop

# Setup everything: start containers, create wallet, generate 150 blocks
setup-everything:
    just up
    sleep 3
    just create-wallet
    just generate 150

# View logs
logs *args:
    docker compose logs "$@"

# View bitcoind logs
logs-bitcoind:
    docker compose logs -f bitcoind

# View electrs logs
logs-electrs:
    docker compose logs -f electrs

# Bitcoin CLI shortcut
bcli *args:
    docker compose exec bitcoind bitcoin-cli -regtest -rpcuser=bitcoin -rpcpassword=bitcoin "$@"

# Create a wallet in bitcoind
create-wallet name="test":
    just bcli createwallet {{ name }}

# Generate blocks
generate blocks="1":
    just bcli -generate {{ blocks }}

# Get blockchain info
info:
    just bcli getblockchaininfo

# Get new address from bitcoind wallet
newaddr:
    just bcli getnewaddress

# Send to address
send address amount:
    just bcli sendtoaddress {{ address }} {{ amount }}

# Run E2E test
test-e2e:
    ./scripts/test-esplora-e2e.sh http://127.0.0.1:3002

# Run force close test
test-force-close:
    ./scripts/test-esplora-force-close.sh http://127.0.0.1:3002

# Run wallet rescan test
test-wallet-rescan:
    ./scripts/test-esplora-wallet-rescan.sh http://127.0.0.1:3002

# Run SCB restore test
test-scb-restore:
    ./scripts/test-esplora-scb-restore.sh http://127.0.0.1:3002

# Run all tests
test-all: test-e2e test-force-close test-wallet-rescan test-scb-restore
