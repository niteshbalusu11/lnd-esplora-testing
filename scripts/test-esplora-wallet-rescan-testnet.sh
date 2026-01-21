#!/bin/bash
#
# Wallet Rescan Debug Script for LND Esplora Backend (Testnet)
#
# This script restores a wallet from a provided seed phrase and rescans
# using the mempool.space Esplora API. It logs wallet balance and UTXOs
# to help debug missing funds after recovery. The script captures extensive
# debug output to aid investigation.
#
# Usage:
#   ./scripts/test-esplora-wallet-rescan-testnet.sh [--preserve] [esplora_url]
#
# Options:
#   --preserve    Keep wallet data after test completes (for rescan testing)
#
# Example:
#   ./scripts/test-esplora-wallet-rescan-testnet.sh --preserve
#   ./scripts/test-esplora-wallet-rescan-testnet.sh https://mempool.space/testnet/api
#

set -e

# Parse arguments
PRESERVE=false
ESPLORA_URL="https://esploratestnet.noahwallet.io"

while [[ $# -gt 0 ]]; do
    case $1 in
        --preserve)
            PRESERVE=true
            shift
            ;;
        *)
            ESPLORA_URL="$1"
            shift
            ;;
    esac
done

# Configuration
TEST_DIR="./test-esplora-wallet-rescan-testnet"
ALICE_DIR="$TEST_DIR/alice"
ALICE_PORT=10127
ALICE_REST=8107
ALICE_PEER=9762
SNAPSHOT_DIR="$TEST_DIR/snapshots"

# Provided testnet seed phrase
SEED_PHRASE="absorb trick burger hope minimum drop bracket question saddle bounce gym rib young pass movie fox isolate robot aerobic cliff month special aisle small"

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

timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

safe_lncli() {
    local out
    if out=$(./lncli-esplora --lnddir="$ALICE_DIR" --network=testnet4 --rpcserver=127.0.0.1:$ALICE_PORT "$@" 2>&1); then
        echo "$out"
        return 0
    fi

    log_warn "lncli command failed: $*"
    echo "$out" | sed 's/^/[lncli-error] /'
    return 1
}

cleanup() {
    log_step "Cleaning up..."

    if [ -f "$ALICE_DIR/lnd.pid" ]; then
        kill $(cat "$ALICE_DIR/lnd.pid") 2>/dev/null || true
        rm -f "$ALICE_DIR/lnd.pid"
    fi

    pkill -f "lnd-esplora.*test-esplora-wallet-rescan-testnet" 2>/dev/null || true

    if [ "$PRESERVE" = true ]; then
        log_info "Wallet data preserved at $TEST_DIR (--preserve flag)"
        log_info "You can run test-esplora-rescan-only.sh to test rescan"
    fi

    log_info "Cleanup complete"
}

trap cleanup EXIT

check_prerequisites() {
    log_step "Checking prerequisites..."

    if ! command -v curl &> /dev/null; then
        log_error "curl not found"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq not found"
        exit 1
    fi

    if ! command -v expect &> /dev/null; then
        log_error "expect not found. Please install expect (brew install expect or apt-get install expect)"
        exit 1
    fi

    if ! curl -s "${ESPLORA_URL}/blocks/tip/height" &>/dev/null; then
        log_error "Esplora API not reachable at $ESPLORA_URL"
        exit 1
    fi
    log_info "Esplora API reachable at $ESPLORA_URL"

    log_info "Esplora tip height: $(curl -s "${ESPLORA_URL}/blocks/tip/height" | tr -d '\n')"
    log_info "Esplora tip hash: $(curl -s "${ESPLORA_URL}/blocks/tip/hash" | tr -d '\n')"

    log_info "Building lnd-esplora..."
    go build -o lnd-esplora ./cmd/lnd

    log_info "Building lncli-esplora..."
    go build -o lncli-esplora ./cmd/lncli

    log_info "lnd-esplora version:"
    ./lnd-esplora --version 2>/dev/null || true

    log_info "All prerequisites met"
}

setup_directory() {
    log_step "Setting up test directory..."

    # Only delete if not preserving or no wallet exists
    if [ "$PRESERVE" = true ] && [ -f "$ALICE_DIR/data/testnet4/wallet.db" ]; then
        log_info "Existing wallet found and --preserve set, keeping wallet data"
        log_warn "This will SKIP restore and just update config"
        # Just update config, don't delete wallet
        mkdir -p "$SNAPSHOT_DIR"
    else
        rm -rf "$TEST_DIR"
        mkdir -p "$ALICE_DIR"
        mkdir -p "$SNAPSHOT_DIR"
    fi

    cat > "$ALICE_DIR/lnd.conf" << EOF
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

    log_info "Created config for Alice at $ALICE_DIR"
}

start_node_fresh() {
    log_info "Starting Alice (fresh wallet creation)..."

    ./lnd-esplora --lnddir="$ALICE_DIR" > "$ALICE_DIR/lnd.log" 2>&1 &
    echo $! > "$ALICE_DIR/lnd.pid"

    local max_attempts=60
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if ./lncli-esplora --lnddir="$ALICE_DIR" --network=testnet4 --rpcserver=127.0.0.1:$ALICE_PORT state 2>/dev/null | grep -q "WAITING_TO_START\|NON_EXISTING"; then
            log_info "LND ready for wallet creation"
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done

    log_error "LND failed to start. Check $ALICE_DIR/lnd.log"
    tail -50 "$ALICE_DIR/lnd.log"
    exit 1
}

unlock_wallet() {
    local password=$(cat "$TEST_DIR/wallet_password.txt")

    log_info "Unlocking wallet..."

    expect << EOF > /dev/null 2>&1
set timeout 60
spawn ./lncli-esplora --lnddir=$ALICE_DIR --network=testnet4 --rpcserver=127.0.0.1:$ALICE_PORT unlock

expect "Input wallet password:"
send "$password\r"

expect eof
EOF

    sleep 5
    log_info "Wallet unlocked"
}

restore_wallet() {
    local password="testpassword123"

    log_step "Restoring wallet from seed phrase..."

    echo "$password" > "$TEST_DIR/wallet_password.txt"

    expect << EOF > "$TEST_DIR/wallet_restore.log" 2>&1
set timeout 240
spawn ./lncli-esplora --lnddir=$ALICE_DIR --network=testnet4 --rpcserver=127.0.0.1:$ALICE_PORT create

expect "Input wallet password:"
send "$password\r"

expect "Confirm password:"
send "$password\r"

expect "Do you have an existing cipher seed mnemonic"
send "y\r"

expect "Input your 24-word mnemonic separated by spaces:"
send "$SEED_PHRASE\r"

expect "Input your cipher seed passphrase"
send "\r"

expect "Input an optional address look-ahead"
send "10000\r"

expect "lnd successfully initialized"
EOF

    log_info "Wallet restoration initiated"
    sleep 5
}

wait_for_sync() {
    local max_attempts=${1:-900}
    local attempt=0

    log_info "Waiting for Alice to sync (timeout: ${max_attempts}s)..."
    while [ $attempt -lt $max_attempts ]; do
        local synced=$(./lncli-esplora --lnddir="$ALICE_DIR" --network=testnet4 --rpcserver=127.0.0.1:$ALICE_PORT getinfo 2>/dev/null | jq -r '.synced_to_chain // "false"')
        if [ "$synced" = "true" ]; then
            log_info "Alice synced to chain"
            return 0
        fi
        if [ $((attempt % 60)) -eq 0 ] && [ $attempt -gt 0 ]; then
            log_debug "Still syncing... ($attempt/${max_attempts}s)"
        fi
        sleep 1
        attempt=$((attempt + 1))
    done

    log_error "Alice failed to sync after ${max_attempts}s"
    return 1
}

alice_cli() {
    ./lncli-esplora --lnddir="$ALICE_DIR" --network=testnet4 --rpcserver=127.0.0.1:$ALICE_PORT "$@"
}

capture_esplora_context() {
    log_step "Capturing Esplora context"

    curl -s "${ESPLORA_URL}/blocks/tip/height" > "$TEST_DIR/esplora_tip_height.txt" || true
    curl -s "${ESPLORA_URL}/blocks/tip/hash" > "$TEST_DIR/esplora_tip_hash.txt" || true
    curl -s "${ESPLORA_URL}/fee-estimates" > "$TEST_DIR/esplora_fee_estimates.json" || true

    log_info "Esplora tip height: $(cat "$TEST_DIR/esplora_tip_height.txt" 2>/dev/null || echo "unknown")"
    log_info "Esplora tip hash: $(cat "$TEST_DIR/esplora_tip_hash.txt" 2>/dev/null || echo "unknown")"
}

capture_lnd_state() {
    local label=$1
    local ts
    ts=$(timestamp)
    local snap_dir="$SNAPSHOT_DIR/$label-$(echo "$ts" | tr ':' '-')"
    mkdir -p "$snap_dir"

    log_step "Capturing LND state: $label ($ts)"

    safe_lncli state > "$snap_dir/state.txt" || true
    safe_lncli getinfo > "$snap_dir/getinfo.json" || true
    safe_lncli walletbalance > "$snap_dir/walletbalance.json" || true
    safe_lncli listunspent > "$snap_dir/listunspent.json" || true
    safe_lncli listtransactions > "$snap_dir/listtransactions.json" || true
    safe_lncli listchaintxns > "$snap_dir/listchaintxns.json" || true
    safe_lncli listaccounts > "$snap_dir/listaccounts.json" || true

    if [ -f "$ALICE_DIR/lnd.log" ]; then
        tail -200 "$ALICE_DIR/lnd.log" > "$snap_dir/lnd_tail.log" || true
    fi

    log_info "Snapshot saved at $snap_dir"
}

debug_esplora_for_utxos() {
    local utxo_file="$1"
    if [ ! -f "$utxo_file" ]; then
        return 0
    fi

    local addrs
    addrs=$(jq -r '.utxos[]?.address' "$utxo_file" 2>/dev/null | sort -u)
    if [ -z "$addrs" ]; then
        log_warn "No addresses found in UTXO list for Esplora cross-check"
        return 0
    fi

    log_step "Cross-checking UTXO addresses against Esplora"
    local count=0
    for addr in $addrs; do
        count=$((count + 1))
        if [ $count -gt 25 ]; then
            log_warn "Address cross-check limited to 25 addresses"
            break
        fi
        log_info "Esplora UTXOs for $addr"
        curl -s "${ESPLORA_URL}/address/${addr}/utxo" | tee "$TEST_DIR/esplora_addr_${count}_utxo.json" > /dev/null || true
    done
}

capture_wallet_state() {
    log_step "Capturing wallet state"

    safe_lncli getinfo | tee "$TEST_DIR/getinfo.json" > /dev/null
    safe_lncli walletbalance | tee "$TEST_DIR/walletbalance.json" > /dev/null
    safe_lncli listunspent | tee "$TEST_DIR/listunspent.json" > /dev/null
    safe_lncli listtransactions | tee "$TEST_DIR/listtransactions.json" > /dev/null
    safe_lncli listchaintxns | tee "$TEST_DIR/listchaintxns.json" > /dev/null
    safe_lncli listaccounts | tee "$TEST_DIR/listaccounts.json" > /dev/null

    local balance=$(jq -r '.confirmed_balance // "0"' "$TEST_DIR/walletbalance.json")
    local utxos=$(jq -r '.utxos | length' "$TEST_DIR/listunspent.json")

    log_info "Confirmed balance: $balance sats"
    log_info "UTXO count: $utxos"

    if [ "$utxos" -gt 0 ] 2>/dev/null; then
        log_step "UTXO details"
        jq '.utxos[] | {address, amount_sat, confirmations, address_type, outpoint}' "$TEST_DIR/listunspent.json"
    else
        log_warn "No UTXOs found in wallet"
    fi

    debug_esplora_for_utxos "$TEST_DIR/listunspent.json"
}

run_rescan_debug() {
    log_step "Starting Testnet4 Wallet Rescan Debug"

    setup_directory
    capture_esplora_context

    # Check if wallet already exists (--preserve mode with existing wallet)
    if [ -f "$ALICE_DIR/data/testnet4/wallet.db" ]; then
        log_info "Existing wallet found, skipping restore"
        start_node_fresh
        # Wait for wallet to be ready for unlock
        sleep 3
        unlock_wallet
    else
        start_node_fresh
        capture_lnd_state "after-start"
        restore_wallet
        capture_lnd_state "after-restore"
    fi

    log_step "Waiting for wallet rescan and sync"
    wait_for_sync 600
    capture_lnd_state "after-sync"

    log_step "Waiting for UTXO discovery"
    local max_wait=600
    local waited=0
    while [ $waited -lt $max_wait ]; do
        local current_balance=$(alice_cli walletbalance 2>/dev/null | jq -r '.confirmed_balance // "0"')
        if [ "$current_balance" != "0" ] && [ "$current_balance" != "null" ]; then
            log_info "Balance detected: $current_balance sats"
            break
        fi
        sleep 10
        waited=$((waited + 10))
        if [ $((waited % 60)) -eq 0 ]; then
            log_debug "Still scanning for UTXOs... ($waited/$max_wait seconds)"
            capture_lnd_state "progress-${waited}s"
        fi
    done

    capture_wallet_state

    log_step "Logs and outputs saved"
    log_info "LND log: $ALICE_DIR/lnd.log"
    log_info "Wallet restore log: $TEST_DIR/wallet_restore.log"
    log_info "Wallet balance: $TEST_DIR/walletbalance.json"
    log_info "List unspent: $TEST_DIR/listunspent.json"
    log_info "Snapshots: $SNAPSHOT_DIR"
}

# Main
main() {
    echo -e "${GREEN}"
    echo "============================================"
    echo "  LND Esplora Wallet Rescan Debug (Testnet4)"
    echo "============================================"
    echo -e "${NC}"
    echo ""
    echo "Esplora URL: $ESPLORA_URL"
    echo "Preserve mode: $PRESERVE"
    echo ""

    check_prerequisites
    run_rescan_debug
}

main "$@"
