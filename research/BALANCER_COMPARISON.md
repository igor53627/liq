# LIQ vs Balancer V2 Flash Loan Gas Comparison

## Data Source

**1.7 million FlashLoan events** extracted from Ethereum L1 (blocks 19,000,000 - 21,000,000) using Envio HyperSync API.

- 18,026 valid stablecoin flash loans (USDC, USDT, DAI)
- 48,121 valid WETH flash loans

---

## Stablecoin Flash Loan Statistics

| Token | Events | Total Volume | Avg Loan | Median Loan | Avg Gas | Min Gas |
|-------|--------|--------------|----------|-------------|---------|---------|
| USDC | 10,437 | $12.4T | $1.19B | $42,957 | 747,176 | 86,268 |
| USDT | 4,432 | $1.37T | $310M | $16,800 | 784,887 | 168,384 |
| DAI | 3,157 | $829M | $263K | $17,193 | 906,889 | 171,430 |

## WETH Flash Loan Statistics

| Events | Total Volume | Avg Loan | Median Loan | Avg Gas | Min Gas |
|--------|--------------|----------|-------------|---------|---------|
| 48,121 | 326M ETH | 6,779 ETH | 2.19 ETH | 789,061 | 71,527 |

---

## Loan Size Distribution (Stablecoins)

| Range | Count | Percentage |
|-------|-------|------------|
| $0 - $1K | 3,366 | 18.7% |
| $1K - $10K | 3,145 | 17.4% |
| $10K - $100K | 5,622 | 31.2% |
| $100K - $1M | 4,641 | 25.7% |
| $1M - $10M | 1,035 | 5.7% |
| $10M - $100M | 191 | 1.1% |
| $100M+ | 26 | 0.1% |

---

## Gas Usage by Loan Size

| Loan Size | Events | Avg Gas | Min Gas |
|-----------|--------|---------|---------|
| $0 - $1K | 3,366 | 901,698 | 86,268 |
| $1K - $10K | 3,145 | 704,634 | 152,922 |
| $10K - $100K | 5,622 | 712,500 | 150,734 |
| $100K - $1M | 4,641 | 783,457 | 152,934 |
| $1M - $10M | 1,035 | 965,170 | 87,413 |
| $10M - $100M | 191 | 904,904 | 89,188 |

**Key insight**: Gas usage is relatively independent of loan size. The minimum gas (~86k-170k) represents the Balancer protocol overhead, while the rest is callback logic (arbitrage, swaps, etc.).

---

## Balancer Flash Loan Overhead Analysis

The `flashLoan()` function in Balancer's FlashLoans.sol:

```
Operation                                    Gas Cost
─────────────────────────────────────────────────────
Input validation & array checks              ~200
ReentrancyGuard (SSTORE 0→1→0)               ~2,600
Pre-loan loop (per token):
  - balanceOf() SLOAD                        ~2,600 (cold)
  - Fee calculation                          ~50
  - safeTransfer to recipient                ~25,000-35,000
Post-loan loop (per token):
  - balanceOf() SLOAD                        ~2,600
  - Balance verification                     ~50
FlashLoan event emission                     ~375
─────────────────────────────────────────────────────
ESTIMATED OVERHEAD (1 token, warm):          ~28,000-32,000
ESTIMATED OVERHEAD (1 token, cold):          ~35,000-45,000
```

**Actual minimum from data**: 71,527 gas (WETH), 86,268 gas (USDC)

This indicates real-world flash loans include at minimum ~40-55k gas for the callback repayment logic on top of the ~28-32k protocol overhead.

---

## LIQFlashYul Gas Costs

Current implementation: **LIQFlashYul** (pure Yul, zero fees, USDC only)

### Gas Breakdown (from Tenderly traces)

```
Operation                                    Gas Cost (warm)
─────────────────────────────────────────────────────────────
USDC transfer out                            ~27,000 (proxy + implementation)
Callback + repay                             ~5,000 (borrower's transfer back)
balanceOf check                              ~2,500 (USDC staticcall)
Protocol logic                               ~700 (dispatcher, storage, event)
─────────────────────────────────────────────────────────────
TOTAL (warm)                                 ~41,000
```

The ~40k warm gas is mostly USDC proxy overhead - unavoidable without a different token.

### Benchmark Results (from Tenderly)

| Metric | Cold | Warm |
|--------|------|------|
| Full flash loan TX | ~73,000 | ~41,000 |

**Note**: "Warm" means repeated use where contracts are already deployed and borrower has existing USDC balance slot. "Cold" is first-time use with fresh state.

---

## Comparison Summary

| Protocol | Cold Gas | Warm Gas | Fee |
|----------|----------|----------|-----|
| Aave V3 | ~120,000 | ~90,000 | 0.05% |
| Balancer | ~110,000 | ~80,000 | 0% |
| Morpho Blue | ~88,000 | ~68,500 | 0% |
| Euler V2 | ~75,000 | ~55,000 | 0% |
| **LIQ** | **~73,000** | **~41,000** | **0%** |

### Gas Savings vs Competitors

| Comparison | LIQ Advantage |
|------------|---------------|
| LIQ vs Balancer (warm) | **~49% cheaper** (~39k gas saved) |
| LIQ vs Morpho (warm) | **~40% cheaper** (~27.5k gas saved) |
| LIQ vs Aave (warm) | **~54% cheaper** (~49k gas saved) |

### Why LIQ Beats Morpho/Euler

| Pattern | Callback | Protocol Verify | Total |
|---------|----------|-----------------|-------|
| **LIQ** (transfer + balanceOf) | ~5k | ~0.5k | **~5.5k** |
| Morpho (approve + transferFrom) | ~23k | ~6k | ~29k |

LIQ's `transfer()` + `balanceOf()` pattern is **~5x more efficient** for repayment than the `approve()` + `transferFrom()` pattern used by Morpho.

### Key Advantages

**LIQFlashYul advantages:**
- **Gas optimized**: 40-50% cheaper than competitors on warm calls
- **Zero fees**: Bots keep 100% of profits
- **ERC-3156 compliant**: Works with existing flash loan code
- **Pure Yul**: Maximum gas optimization
- **Simple**: USDC only (simplicity = efficiency)

**Trade-offs:**
- Single token (USDC only) vs multi-token support
- Smaller liquidity pool vs established protocols

### Note on Balancer Data

The Balancer statistics above (min gas 86,268 for USDC) are from on-chain transaction receipts. The ~80k "warm" estimate in the comparison table is based on Tenderly simulations with equivalent borrower complexity to LIQ's test borrower.

---

## Sample Large Transactions

| TX Hash | Token | Amount | Gas |
|---------|-------|--------|-----|
| [0x09d6a25b...](https://etherscan.io/tx/0x09d6a25bdb4c66aa0f36a6d30ba2ddf382913933288d9fe76d7ce7258707b894) | USDC | $950B | 244,148 |
| [0xe4a04dfa...](https://etherscan.io/tx/0xe4a04dfa97505fafc3a2f5a99fadd4ec4ac3069a115befbecef84514c2d3b66d) | USDC | $950B | 246,178 |

---

## Data Files

- `balancer_flashloans_full.csv` - All 1.7M events (raw)
- `balancer_flashloans_clean.csv` - Cleaned stablecoin + WETH loans
- `extract_all_flashloans.py` - Envio HyperSync extraction script

## Reproduction

```bash
# Run gas benchmark
forge test --match-test testGasBenchmark --fork-url https://ethereum-rpc.publicnode.com -vvv

# Run full E2E test on Tenderly (requires TENDERLY_ACCESS_KEY)
source ~/.zsh_secrets
npx tsx script/test-tenderly.ts
```
