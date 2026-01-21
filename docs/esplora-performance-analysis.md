# Esplora Backend Performance Analysis

This document analyzes the performance characteristics of different Bitcoin chain backends for LND wallet scanning and recovery operations.

## Problem: Wallet Recovery Scanning

When recovering a wallet from a seed phrase, LND must:

1. Generate thousands of addresses from the seed (typically 10,000+ with lookahead)
2. Scan historical blocks to find transactions involving those addresses
3. Identify both received funds (outputs) and spent funds (inputs)

This is computationally and network-intensive, especially on mainnet where blocks are full.

## Backend Comparison

### 1. Neutrino (BIP 157/158 Compact Block Filters)

**How it works:**
- Downloads compact block filters (~20KB per block) instead of full blocks
- Filters are Golomb-Coded Sets (GCS) that summarize all scriptPubKeys in a block
- Tests ALL watched addresses against the filter locally (microseconds)
- Only downloads full blocks when the filter indicates a potential match

**Performance:**
```
For 1000 blocks with 100,000 watched addresses:
- Filter downloads: 1000 × 20KB = 20MB
- Filter matching: Local CPU operation, ~milliseconds total
- Full block downloads: Only for matches (typically <10 blocks)
- Total time: ~1-2 minutes
```

**Why it's fast:**
- Probabilistic filters eliminate 99%+ of blocks without downloading them
- All address matching is done locally with no network round-trips
- Minimal data transfer

### 2. Bitcoin Core (Local)

**How it works:**
- Full blockchain stored on local disk (~600GB+)
- `getblock` RPC returns full block data from disk
- Scans each block locally for matching addresses

**Performance:**
```
For 1000 blocks:
- Block reads: 1000 × ~1.5MB = 1.5GB from local SSD
- SSD read speed: ~500MB/s
- Scanning: Local CPU operation
- Total time: ~5-10 minutes
```

**Why it's fast:**
- No network latency - direct disk I/O
- SSDs provide high throughput for sequential reads
- All processing is local

### 3. Bitcoin Core (Remote RPC)

**How it works:**
- Same as local, but blocks transferred over network via RPC

**Performance:**
```
For 1000 blocks:
- Block transfers: 1000 × ~1.5MB = 1.5GB over network
- Network speed dependent (e.g., 100Mbps = ~2 minutes transfer)
- Plus RPC overhead per request
- Total time: 10-30+ minutes
```

**Why it's slower:**
- Network bandwidth becomes bottleneck
- RPC serialization overhead
- Latency per request

### 4. Esplora REST API

**Challenge:** No compact block filter support, no batch address queries.

#### Approach A: Per-Address Queries

Query each address individually via `/address/:addr/txs`.

**Performance:**
```
For 100,000 addresses:
- API calls: 100,000
- Time per call: ~300ms
- Total time: 100,000 × 0.3s = 30,000s = 8.3 HOURS
```

#### Approach B: Block-Based Scanning (Empty Blocks - Testnet)

Fetch all transactions per block via `/block/:hash/txs`, scan locally.

**Performance on Testnet4 (mostly empty blocks):**
```
For 450 blocks with ~1 tx each:
- API calls: ~450 (one per block)
- Time per call: ~300ms
- Parallel fetches: 20 concurrent
- Total fetch time: ~8 seconds
- Local scanning: ~milliseconds
- Total time: ~10 seconds
```

#### Approach C: Block-Based Scanning (Full Blocks - Mainnet)

**Performance on Mainnet (~2000 txs per block):**
```
For 1000 blocks:
- Txs per block: ~2000
- API pagination: 25 txs per page
- API calls per block: 2000/25 = 80
- Total API calls: 1000 × 80 = 80,000
- Time: 80,000 × 0.3s / 20 parallel = 1,200s = 20 minutes
```

## Performance Summary Table

| Backend | 1000 Blocks (Mainnet) | Network Data | Local Storage |
|---------|----------------------|--------------|---------------|
| Neutrino | ~2 minutes | ~20MB filters | None |
| Bitcoin Core (Local) | ~5 minutes | None | 600GB+ |
| Bitcoin Core (Remote) | ~15 minutes | ~1.5GB | None |
| Esplora (Block Scan) | ~20 minutes | ~100MB JSON | None |
| Esplora (Per-Address) | ~8 hours | Variable | None |

## Esplora Optimizations Implemented

### 1. Block-Based Scanning for Large Address Sets

When recovering with many addresses (>500), we switch from per-address queries to block-based scanning:

```go
if totalAddrs > filterBlocksAddressThreshold {
    return c.filterBlocksByScanning(req)
}
return c.filterBlocksByAddress(req)
```

### 2. Use `/block/:hash/txs` Endpoint

This endpoint returns transaction data with addresses pre-parsed:

```go
// Returns addresses directly - no script parsing needed
txInfos, err := c.client.GetBlockTxs(ctx, blockHash)
for _, txInfo := range txInfos {
    for _, vout := range txInfo.Vout {
        addrStr := vout.ScriptPubKeyAddr  // Already decoded!
        if _, ok := watchedAddrs[addrStr]; ok {
            // Match found
        }
    }
}
```

### 3. Parallel Block Fetching

Fetch multiple blocks concurrently:

```go
const maxConcurrentBlockFetches = 20

for i, blockMeta := range req.Blocks {
    go func(idx int, meta BlockMeta) {
        txInfos, err := c.client.GetBlockTxs(ctx, meta.Hash.String())
        resultChan <- blockTxsResult{blockIdx: idx, txInfos: txInfos}
    }(i, blockMeta)
}
```

### 4. Only Fetch Raw Transactions for Matches

Instead of fetching raw transaction data for every transaction, we:

1. Scan block transaction info (lightweight JSON with addresses)
2. Record matched transaction IDs
3. Fetch raw transactions only for matches (typically <10)

```go
// Scan all blocks first (using address strings from API)
for _, txInfo := range txInfos {
    if addressMatches(txInfo) {
        matchedTxIDs[txInfo.TxID] = blockIdx
    }
}

// Fetch raw tx only for matches
for txid := range matchedTxIDs {
    tx, _ := c.client.GetRawTransactionMsgTx(ctx, txid)
    relevantTxns = append(relevantTxns, tx)
}
```

### 5. Handle API Pagination

The `/block/:hash/txs` endpoint returns 25 transactions per page:

```go
for {
    endpoint := fmt.Sprintf("/block/%s/txs/%d", blockHash, startIndex)
    txs, err := c.doGet(ctx, endpoint)
    allTxs = append(allTxs, txs...)
    if len(txs) < 25 {
        break  // Last page
    }
    startIndex += 25
}
```

## Recommendations

### For Mobile Wallets

1. **Prefer Neutrino** if compact block filter servers are available
2. **Use Electrum protocol** if available (supports batch scripthash queries)
3. **Accept slower Esplora recovery** with user warning about time required
4. **Reduce recovery window** (e.g., 2500 addresses instead of 10000)

### For Server/Desktop

1. **Run local Bitcoin Core** for fastest recovery
2. **Use Neutrino** for light client without full node
3. **Esplora is acceptable** for occasional recoveries with patience

### For Esplora API Providers

Consider implementing:

1. **BIP 157 filter endpoint**: `/block/:hash/filter`
2. **Batch address query**: `/addresses/txs` with POST body
3. **Larger pagination**: 100+ txs per page instead of 25

## Conclusion

Esplora REST API is fundamentally limited for efficient wallet recovery due to:

1. No compact block filters (requires downloading all block data)
2. No batch address queries (one round-trip per address)
3. Small pagination size (many requests for full blocks)

Our optimizations reduce mainnet recovery time from ~8 hours to ~20 minutes, but this is still significantly slower than Neutrino (~2 minutes) or local Bitcoin Core (~5 minutes).

For production mobile wallets on mainnet, Esplora should be considered a fallback option rather than the primary backend for wallet recovery operations.
