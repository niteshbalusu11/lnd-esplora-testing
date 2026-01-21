# Gap Limit Proposal for Esplora Wallet Scanning

## Overview

This document proposes an optimization for Esplora-based wallet scanning by distinguishing between two scenarios (restore vs rescan) and implementing a gap limit approach for address discovery.

## Problem Statement

Currently, wallet recovery with Esplora uses a fixed recovery window (e.g., 10,000 addresses per scope), generating approximately 100,000 addresses upfront:

```
Recovery window: 10,000
× 5 address scopes (p2wkh, np2wkh, p2tr, etc.)
× 2 chains (external + internal)
= ~100,000 addresses to scan
```

This approach is:
1. Extremely slow on mainnet (hours of scanning)
2. Wasteful for typical wallets (most have <100 used addresses)
3. Does not distinguish between restore and rescan scenarios

## Two Distinct Scenarios

### Scenario 1: Restore from Seed

**Context:**
- User has only a seed phrase (24 words)
- No existing wallet database
- Must discover which addresses were used

**Current approach:**
- Generate 100,000 addresses upfront
- Scan all of them against blockchain
- Time: Hours on mainnet

**Optimal approach:**
- Use gap limit (BIP-44 standard: 20 consecutive unused addresses)
- Generate addresses incrementally
- Stop when gap limit reached
- Time: Seconds to minutes

### Scenario 2: Rescan Existing Wallet

**Context:**
- User has existing wallet.db
- Wallet knows which addresses have been used
- Just needs to re-check for missed transactions

**Current approach:**
- Same as restore - scan 100,000 addresses
- Time: Hours on mainnet

**Optimal approach:**
- Query only addresses marked as used in wallet.db
- Plus small lookahead for recent addresses
- Time: Seconds

## Gap Limit Approach

### What is Gap Limit?

BIP-44 defines the gap limit as the maximum number of consecutive unused addresses before a wallet stops generating new ones. The standard gap limit is 20.

### Algorithm for Restore

```
function restoreWallet(seed):
    for each addressScope in [p2wpkh, np2wkh, p2tr, ...]:
        for each chain in [external, internal]:
            highestUsedIndex = -1
            currentIndex = 0
            
            while (currentIndex - highestUsedIndex) <= GAP_LIMIT:
                address = deriveAddress(seed, scope, chain, currentIndex)
                hasTransactions = queryEsplora(address)
                
                if hasTransactions:
                    highestUsedIndex = currentIndex
                    markAddressUsed(address)
                    importTransactions(address)
                
                currentIndex++
            
            // Gap limit reached, move to next chain/scope
```

### Why This Works

Most wallets have a small number of used addresses clustered at low indices:

```
Typical wallet address usage:

Index:  0  1  2  3  4  5  6  7  8  9  10 ... 19 20 21 22 23 24
Used:   ✓  ✓  -  ✓  ✓  ✓  -  -  -  -  -  ... -  -  -  -  -  -
                          ↑
                    Highest used = 5
                    
Check up to index 25 (5 + 20 gap limit)
After 20 consecutive unused addresses → stop
```

### Performance Comparison

| Scenario | Current Approach | Gap Limit Approach |
|----------|------------------|-------------------|
| Wallet with 5 used addresses | 100,000 queries | ~50 queries |
| Wallet with 50 used addresses | 100,000 queries | ~150 queries |
| Wallet with 500 used addresses | 100,000 queries | ~1,000 queries |
| Empty wallet (new seed) | 100,000 queries | ~100 queries |

**Time savings (at 300ms per query):**

| Scenario | Current Time | Gap Limit Time | Speedup |
|----------|--------------|----------------|---------|
| Typical wallet (5 addresses) | 8+ hours | ~15 seconds | 2000x |
| Heavy user (50 addresses) | 8+ hours | ~45 seconds | 600x |
| Exchange wallet (500 addresses) | 8+ hours | ~5 minutes | 100x |

## Implementation Approach

### Option A: Client-Side Gap Limit

Implement gap limit logic in the Esplora chain client:

```go
// In esplora/chainclient.go

func (c *ChainClient) RestoreWalletWithGapLimit(
    seed []byte, 
    gapLimit int,
) error {
    for _, scope := range addressScopes {
        for _, chain := range []int{external, internal} {
            err := c.scanChainWithGapLimit(seed, scope, chain, gapLimit)
            if err != nil {
                return err
            }
        }
    }
    return nil
}

func (c *ChainClient) scanChainWithGapLimit(
    seed []byte,
    scope KeyScope,
    chain int,
    gapLimit int,
) error {
    highestUsed := -1
    current := 0
    
    for (current - highestUsed) <= gapLimit {
        addr := deriveAddress(seed, scope, chain, current)
        
        txs, err := c.client.GetAddressTxs(ctx, addr.String())
        if err != nil {
            return err
        }
        
        if len(txs) > 0 {
            highestUsed = current
            // Import transactions and mark address used
        }
        
        current++
    }
    
    return nil
}
```

### Option B: Batch Gap Limit Scanning

Fetch addresses in batches to reduce round trips:

```go
func (c *ChainClient) scanChainWithGapLimitBatched(
    seed []byte,
    scope KeyScope,
    chain int,
    gapLimit int,
    batchSize int,
) error {
    highestUsed := -1
    current := 0
    
    for {
        // Generate batch of addresses
        batch := make([]btcutil.Address, batchSize)
        for i := 0; i < batchSize; i++ {
            batch[i] = deriveAddress(seed, scope, chain, current+i)
        }
        
        // Query all addresses in parallel
        results := c.queryAddressesConcurrently(batch)
        
        // Process results
        foundAny := false
        for i, result := range results {
            if len(result.txs) > 0 {
                highestUsed = current + i
                foundAny = true
            }
        }
        
        current += batchSize
        
        // Check if gap limit reached
        if !foundAny && (current - highestUsed) > gapLimit {
            break
        }
    }
    
    return nil
}
```

### Option C: Modify FilterBlocks Interface

Change how btcwallet calls FilterBlocks for Esplora:

```go
// Add new method to chain.Interface
type Interface interface {
    // Existing methods...
    FilterBlocks(*FilterBlocksRequest) (*FilterBlocksResponse, error)
    
    // New method for gap-limit scanning
    ScanAddressesWithGapLimit(
        scopes []KeyScope,
        gapLimit int,
        birthday time.Time,
    ) (*ScanResult, error)
}
```

## Rescan Optimization

For rescanning an existing wallet, we should query only known addresses:

```go
func (c *ChainClient) RescanKnownAddresses(
    knownAddresses []btcutil.Address,
    startHeight int32,
) error {
    // Query each known address
    for _, addr := range knownAddresses {
        txs, err := c.client.GetAddressTxs(ctx, addr.String())
        if err != nil {
            continue
        }
        
        // Filter to transactions after startHeight
        for _, tx := range txs {
            if tx.Status.BlockHeight >= int64(startHeight) {
                // Process transaction
            }
        }
    }
    
    return nil
}
```

## API Considerations

### Detecting Restore vs Rescan

The wallet needs to communicate which scenario applies:

```go
type RecoveryMode int

const (
    RecoveryModeRestore RecoveryMode = iota  // From seed only
    RecoveryModeRescan                        // Existing wallet.db
)

type RecoveryRequest struct {
    Mode            RecoveryMode
    Seed            []byte           // For restore
    KnownAddresses  []btcutil.Address // For rescan
    GapLimit        int
    Birthday        time.Time
}
```

### Wallet Birthday Optimization

For restore, we can skip blocks before the wallet birthday:

```go
func (c *ChainClient) RestoreWithBirthday(
    seed []byte,
    birthday time.Time,
    gapLimit int,
) error {
    // Find birthday block
    birthdayHeight := c.findBlockAtTime(birthday)
    
    // Only query transactions after birthday
    for addr := range discoveredAddresses {
        txs, _ := c.client.GetAddressTxs(ctx, addr.String())
        
        for _, tx := range txs {
            if tx.Status.BlockHeight >= birthdayHeight {
                // Process transaction
            }
        }
    }
}
```

## Backward Compatibility

### LND Configuration

Add configuration options:

```ini
[esplora]
# Enable gap limit optimization for wallet recovery
esplora.usegaplimit=true

# Gap limit value (default: 20 per BIP-44)
esplora.gaplimit=20

# Batch size for concurrent address queries
esplora.addressbatchsize=10
```

### Fallback Behavior

If gap limit scanning fails or is disabled, fall back to current block-based scanning:

```go
func (c *ChainClient) FilterBlocks(req *FilterBlocksRequest) (*FilterBlocksResponse, error) {
    // Check if gap limit mode is enabled and applicable
    if c.useGapLimit && isRestoreMode(req) {
        return c.filterBlocksWithGapLimit(req)
    }
    
    // Fall back to existing implementation
    return c.filterBlocksByScanning(req)
}
```

## Risks and Mitigations

### Risk 1: Non-Standard Wallet Usage

Some wallets don't follow sequential address generation (e.g., exchanges using random indices).

**Mitigation:** 
- Allow configurable gap limit (higher for exchange wallets)
- Provide option to fall back to full scan

### Risk 2: Address Reuse Detection

Gap limit scanning might miss addresses used after a gap.

**Mitigation:**
- After initial scan, do a secondary scan with larger gap limit
- Warn user if wallet appears to have unusual usage patterns

### Risk 3: API Rate Limiting

Many sequential queries might trigger rate limits.

**Mitigation:**
- Implement exponential backoff
- Use batched queries where possible
- Respect rate limit headers from API

## Conclusion

Implementing gap limit scanning for Esplora would transform wallet recovery from an hours-long process to seconds/minutes, making Esplora a viable option for mainnet mobile wallets.

### Recommended Implementation Order

1. **Phase 1:** Implement basic gap limit for restore scenario
2. **Phase 2:** Add rescan optimization using known addresses
3. **Phase 3:** Add batched/concurrent address queries
4. **Phase 4:** Add configuration options and fallback behavior

### Expected Outcomes

| Metric | Current | With Gap Limit |
|--------|---------|----------------|
| Restore time (typical wallet) | 8+ hours | 15-30 seconds |
| Rescan time (existing wallet) | 8+ hours | 5-15 seconds |
| API calls (restore) | 80,000+ | 50-200 |
| API calls (rescan) | 80,000+ | 10-50 |
