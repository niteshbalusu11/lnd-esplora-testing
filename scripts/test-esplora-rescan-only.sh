#!/bin/bash
#
# Rescan-Only Test Script for LND Esplora Backend (Testnet)
#
# This script tests the RESCAN scenario (existing wallet.db) as opposed to
# RESTORE (from seed only). It uses an existing wallet directory from a
# previous restore test and triggers a rescan via --reset-wallet-transactions.
#
# This helps us verify whether rescans use the efficient "known addresses only"
# approach vs the full gap limit scan.
#
# Prerequisites:
#   - Run test-esplora-wallet-rescan-testnet.sh first to create the wallet
#   - Or provide a path to an existing wallet directory
#
# Usage:
#   ./scripts/test-esplora-rescan-only.sh [wallet_dir] [esplora_url]
#

set -e

# Configuration
WALLET_DIR="${1:-./test-esplora-wallet-rescan-testnet/alice}"
ESPLORA_URL="${2:-https://esploratestnet.noahwallet.io}"
TEST_DIR="./test-esplora-rescan-only"
ALICE_PORT=10128
ALICE_REST=8108
ALICE_PEER=9763
PASSWORD_FILE="./test-esplora-wallet-rescan-testnet/wallet_password.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${CYAN}[DEBUG]${NC} $1"
}

log_step() {
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}========================================${NC}\n"
}

cleanup() {
    log_step "Cleaning up..."

    if [ -f "$TEST_DIR/lnd.pid" ]; then
        kill $(cat "$TEST_DIR/lnd.pid") 2>/dev/null || true
        rm -f "$TEST_DIR/lnd.pid"
    fi

    pkill -f "lnd-esplora.*test-esplora-rescan-only" 2>/dev/null || true

    log_info "Cleanup complete"
}

trap cleanup EXIT

check_prerequisites() {
    log_step "Checking prerequisites..."

    # Check for existing wallet
    if [ ! -d "$WALLET_DIR" ]; then
        log_error "Wallet directory not found: $WALLET_DIR"
        log_error "Please run test-esplora-wallet-rescan-testnet.sh first to create a wallet"
        exit 1
    fi

    if [ ! -f "$WALLET_DIR/data/chain/bitcoin/testnet4/wallet.db" ]; then
        log_error "wallet.db not found in $WALLET_DIR/data/chain/bitcoin/testnet4/"
        log_error "Please run test-esplora-wallet-rescan-testnet.sh first to create a wallet"
        exit 1
    fi

    if [ ! -f "$PASSWORD_FILE" ]; then
        log_error "Password file not found: $PASSWORD_FILE"
        exit 1
    fi

    if ! command -v expect &> /dev/null; then
        log_error "expect not found"
        exit 1
    fi

    # Check Esplora API
    if ! curl -s "${ESPLORA_URL}/blocks/tip/height" &>/dev/null; then
        log_error "Esplora API not reachable at $ESPLORA_URL"
        exit 1
    fi

    log_info "Wallet directory: $WALLET_DIR"
    log_info "wallet.db found: $WALLET_DIR/data/chain/bitcoin/testnet4/wallet.db"
    log_info "Esplora API reachable at $ESPLORA_URL"

    # Build binaries
    log_info "Building lnd-esplora..."
    go build -o lnd-esplora ./cmd/lnd

    log_info "Building lncli-esplora..."
    go build -o lncli-esplora ./cmd/lncli

    log_info "All prerequisites met"
}

setup_test_directory() {
    log_step "Setting up test directory..."

    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"

    # Copy wallet data to test directory
    log_info "Copying wallet data from $WALLET_DIR to $TEST_DIR"
    cp -r "$WALLET_DIR/data" "$TEST_DIR/"

    # Create new config with different ports
    cat > "$TEST_DIR/lnd.conf" << EOF
[Bitcoin]
bitcoin.testnet4=true
bitcoin.node=esplora

[esplora]
esplora.url=$ESPLORA_URL
esplora.requesttimeout=60s
esplora.pollinterval=2s
esplora.usegaplimit=true
esplora.gaplimit=20
esplora.addressbatchsize=10

[Application Options]
debuglevel=debug,LNWL=trace,BTWL=trace,ESPL=trace,ESPN=trace
listen=127.0.0.1:$ALICE_PEER
rpclisten=127.0.0.1:$ALICE_PORT
restlisten=127.0.0.1:$ALICE_REST

[protocol]
protocol.simple-taproot-chans=true
EOF

    log_info "Test directory set up at $TEST_DIR"
}

start_lnd() {
    local reset_flag=$1

    if [ "$reset_flag" = "true" ]; then
        log_step "Starting LND with --reset-wallet-transactions flag..."
        ./lnd-esplora --lnddir="$TEST_DIR" --reset-wallet-transactions > "$TEST_DIR/lnd.log" 2>&1 &
    else
        log_step "Starting LND with existing wallet..."
        ./lnd-esplora --lnddir="$TEST_DIR" > "$TEST_DIR/lnd.log" 2>&1 &
    fi
    echo $! > "$TEST_DIR/lnd.pid"

    local max_attempts=60
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if ./lncli-esplora --lnddir="$TEST_DIR" --network=testnet4 --rpcserver=127.0.0.1:$ALICE_PORT state 2>/dev/null | grep -q "LOCKED\|WAITING_TO_START"; then
            log_info "LND ready for unlock"
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done

    log_error "LND failed to start. Check $TEST_DIR/lnd.log"
    tail -50 "$TEST_DIR/lnd.log"
    exit 1
}

unlock_wallet() {
    local password=$(cat "$PASSWORD_FILE")

    log_step "Unlocking wallet (rescan triggered by --reset-wallet-transactions)"

    # Mark the time before rescan
    echo "=== RESCAN START ===" >> "$TEST_DIR/lnd.log"
    local start_time=$(date +%s)

    expect << EOF > "$TEST_DIR/unlock.log" 2>&1
set timeout 600
spawn ./lncli-esplora --lnddir=$TEST_DIR --network=testnet4 --rpcserver=127.0.0.1:$ALICE_PORT unlock

expect "Input wallet password:"
send "$password\r"

expect eof
EOF

    log_info "Unlock command sent"

    # Wait for sync
    log_info "Waiting for rescan and sync to complete..."
    local max_wait=600
    local waited=0
    while [ $waited -lt $max_wait ]; do
        local synced=$(./lncli-esplora --lnddir="$TEST_DIR" --network=testnet4 --rpcserver=127.0.0.1:$ALICE_PORT getinfo 2>/dev/null | jq -r '.synced_to_chain // "false"')
        if [ "$synced" = "true" ]; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            log_info "Rescan and sync complete in ${duration} seconds"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
        if [ $((waited % 30)) -eq 0 ]; then
            log_debug "Still syncing... ($waited/${max_wait}s)"
        fi
    done

    log_error "Rescan failed to complete after ${max_wait}s"
    return 1
}

analyze_logs() {
    log_step "Analyzing rescan logs..."

    local log_file="$TEST_DIR/lnd.log"

    echo ""
    log_info "=== FilterBlocks calls ==="
    grep -E "FilterBlocks.*addresses" "$log_file" | tail -20 || echo "No FilterBlocks calls found"

    echo ""
    log_info "=== Gap limit scanning ==="
    grep -E "gap limit|Gap limit" "$log_file" | tail -20 || echo "No gap limit logs found"

    echo ""
    log_info "=== Block-based scanning ==="
    grep -E "block-based scanning|pre-fetching.*blocks" "$log_file" | tail -10 || echo "No block-based scanning found"

    echo ""
    log_info "=== Rescan method calls ==="
    grep -E "Rescan called|scanAddressHistory" "$log_file" | tail -10 || echo "No Rescan method calls found"

    echo ""
    log_info "=== Address scanning summary ==="
    grep -E "scanned.*found" "$log_file" | tail -10 || echo "No scanning summary found"

    # Count different scanning methods
    local gap_limit_count=$(grep -c "using gap limit scanning" "$log_file" 2>/dev/null || echo "0")
    local block_scan_count=$(grep -c "using block-based scanning" "$log_file" 2>/dev/null || echo "0")
    local rescan_count=$(grep -c "Rescan called" "$log_file" 2>/dev/null || echo "0")

    echo ""
    log_step "Scanning Method Summary"
    echo "Gap limit scanning calls: $gap_limit_count"
    echo "Block-based scanning calls: $block_scan_count"
    echo "Rescan method calls: $rescan_count"
}

capture_wallet_state() {
    log_step "Capturing wallet state after rescan"

    ./lncli-esplora --lnddir="$TEST_DIR" --network=testnet4 --rpcserver=127.0.0.1:$ALICE_PORT walletbalance > "$TEST_DIR/walletbalance.json" 2>/dev/null || true
    ./lncli-esplora --lnddir="$TEST_DIR" --network=testnet4 --rpcserver=127.0.0.1:$ALICE_PORT listunspent > "$TEST_DIR/listunspent.json" 2>/dev/null || true

    local balance=$(jq -r '.confirmed_balance // "0"' "$TEST_DIR/walletbalance.json" 2>/dev/null || echo "unknown")
    local utxos=$(jq -r '.utxos | length' "$TEST_DIR/listunspent.json" 2>/dev/null || echo "0")

    log_info "Confirmed balance: $balance sats"
    log_info "UTXO count: $utxos"

    if [ "$utxos" -gt 0 ] 2>/dev/null; then
        log_info "UTXOs found:"
        jq '.utxos[] | {address, amount_sat, confirmations}' "$TEST_DIR/listunspent.json" 2>/dev/null || true
    fi
}

run_rescan_test() {
    log_step "Running Rescan Test (--reset-wallet-transactions)"

    setup_test_directory
    start_lnd "true"
    unlock_wallet
    capture_wallet_state
    analyze_logs

    log_step "Test Complete"
    log_info "LND log: $TEST_DIR/lnd.log"
    log_info "Wallet balance: $TEST_DIR/walletbalance.json"
}

# Main
main() {
    echo -e "${GREEN}"
    echo "============================================"
    echo "  LND Esplora Rescan-Only Test (Testnet4)"
    echo "============================================"
    echo -e "${NC}"
    echo ""
    echo "This test uses an EXISTING wallet.db to trigger a RESCAN"
    echo "(as opposed to a RESTORE from seed)"
    echo ""
    echo "Wallet directory: $WALLET_DIR"
    echo "Esplora URL: $ESPLORA_URL"
    echo ""

    check_prerequisites

    # Test rescan with --reset-wallet-transactions
    log_step "Test: Rescan with --reset-wallet-transactions"
    run_rescan_test

    log_step "Summary"
    echo ""
    echo "The logs above show which scanning method was used during rescan."
    echo ""
    echo "Expected for RESCAN (existing wallet):"
    echo "  - Should use Rescan() method with known addresses only"
    echo "  - Should NOT trigger gap limit scanning for 100k addresses"
    echo ""
    echo "If you see 'using gap limit scanning for 100000 addresses',"
    echo "that means the rescan optimization is NOT working and we need"
    echo "to implement the 'known addresses only' optimization."
}

main "$@"
