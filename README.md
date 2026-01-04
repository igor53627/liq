# LIQ Flash Loans

[![CI](https://github.com/igor53627/liq/actions/workflows/ci.yml/badge.svg)](https://github.com/igor53627/liq/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Deployed on Ethereum](https://img.shields.io/badge/Deployed-Ethereum%20Mainnet-blue)](https://etherscan.io/address/0xe9eb8a0f6328e243086fe6efee0857e14fa2cb87)

**Zero-fee, gas-optimized USDC flash loans for arbitrage and liquidation bots.**

## Quick Links

| Resource | Link |
|----------|------|
| Contract | [`0xe9eb8a0f6328e243086fe6efee0857e14fa2cb87`](https://etherscan.io/address/0xe9eb8a0f6328e243086fe6efee0857e14fa2cb87) |
| Gas Analysis | [research/BALANCER_COMPARISON.md](research/BALANCER_COMPARISON.md) |
| Security Policy | [SECURITY.md](SECURITY.md) |

## Gas Comparison

| Protocol | Gas (receipt) | Fee | Source |
|----------|---------------|-----|--------|
| Aave V3 | ~120,000 | 0.05% | Estimated |
| Balancer | 86,268 (min) | 0% | On-chain data |
| Morpho Blue | ~88,000 | 0% | Estimated |
| Euler V2 | ~75,000 | 0% | Estimated |
| **LIQ** | **85,292** | **0%** | [Verified tx](https://etherscan.io/tx/0x35274dd1af81d4424cfa35cadff05508a3148a72805730bfef8de9f6d686af5c) |

LIQ and Balancer have comparable gas costs (~85k vs ~86k). The main advantage of LIQ is **zero fees** and **ERC-3156 compatibility**.

## Features

- **Zero fees** - Bots keep 100% of profits
- **ERC-3156 compatible** - Works with existing flash loan code
- **Pure Yul** - Maximum gas optimization
- **Single token** - USDC only (simplicity = efficiency)

## Usage

### For Bots

```solidity
interface IERC3156FlashBorrower {
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32);
}

contract MyBot is IERC3156FlashBorrower {
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    
    function executeArbitrage(address lender, uint256 amount) external {
        IFlashLender(lender).flashLoan(address(this), USDC, amount, "");
    }
    
    function onFlashLoan(
        address,
        address token,
        uint256 amount,
        uint256,  // fee is always 0
        bytes calldata
    ) external returns (bytes32) {
        // 1. Do arbitrage/liquidation here
        // 2. Repay
        IERC20(token).transfer(msg.sender, amount);
        return CALLBACK_SUCCESS;
    }
}
```

### Contract Interface

```solidity
interface ILIQFlash {
    /// @notice Execute flash loan
    /// @param receiver Contract implementing IERC3156FlashBorrower
    /// @param token Must be USDC
    /// @param amount Amount to borrow
    /// @param data Arbitrary data passed to callback
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
    
    /// @notice Get maximum available loan
    function maxFlashLoan(address token) external view returns (uint256);
    
    /// @notice Get fee (always 0)
    function flashFee(address token, uint256 amount) external view returns (uint256);
    
    /// @notice Deposit USDC (requires approval)
    function deposit(uint256 amount) external;
    
    /// @notice Withdraw USDC (owner only)
    function withdraw(uint256 amount) external;
}
```

## Security Model

### How it works

1. Borrow: USDC transferred to receiver (optimistic)
2. Callback: `receiver.onFlashLoan(...)` called
3. Verify: Contract checks `balanceOf(this) >= poolBalance`
4. If balance is insufficient → revert (atomic, all-or-nothing)

### Key Security Properties

| Property | Implementation |
|----------|---------------|
| Repayment enforced | Balance check after callback |
| Reentrancy safe | Balance check is atomic protection |
| No callback check | Balance verification is sufficient |
| Owner-only withdraw | Slot 0 check in Yul |

### What's NOT checked

- Callback return value (balance check is sufficient security)

## Mainnet Deployment

| Contract | Address | Etherscan |
|----------|---------|-----------|
| LIQFlashYul | `0xe9eb8a0f6328e243086fe6efee0857e14fa2cb87` | [View](https://etherscan.io/address/0xe9eb8a0f6328e243086fe6efee0857e14fa2cb87) |
| TestBorrower | `0x7e13a21ce933a7122a8d1bdf0aeced4ba48ecad6` | [View](https://etherscan.io/address/0x7e13a21ce933a7122a8d1bdf0aeced4ba48ecad6) |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | [View](https://etherscan.io/address/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) |

Owner: `0xaF7EB1455e2939DF433042ba64d06D0Cb478B1c7`

## Development

```bash
# Install dependencies
forge install

# Run tests (mainnet fork)
forge test --fork-url https://ethereum-rpc.publicnode.com --match-contract YulTest -vvv

# Deploy (interactive mnemonic prompt)
npx tsx script/deploy.ts --mnemonic

# Deploy TestBorrower
npx tsx script/deploy-borrower.ts
```

## Storage Layout

| Slot | Variable | Type |
|------|----------|------|
| 0 | owner | address |
| 1 | poolBalance | uint256 |

## Function Selectors

| Function | Selector |
|----------|----------|
| flashLoan(address,address,uint256,bytes) | 0x5cffe9de |
| maxFlashLoan(address) | 0x613255ab |
| flashFee(address,uint256) | 0xd9d98ce4 |
| deposit(uint256) | 0xb6b55f25 |
| withdraw(uint256) | 0x2e1a7d4d |
| sync() | 0xfff6cae9 |

## Gas Breakdown

Verified transaction gas: **85,292** ([real mainnet tx](https://etherscan.io/tx/0x35274dd1af81d4424cfa35cadff05508a3148a72805730bfef8de9f6d686af5c) - using legacy TestBorrower)

| Component | Estimated Gas | Notes |
|-----------|---------------|-------|
| Intrinsic tx cost | ~21,000 | Base transaction cost |
| USDC transfer out | ~27,000 | Proxy + implementation |
| Callback + repay | ~27,000 | Borrower's transfer back |
| balanceOf check | ~2,500 | USDC staticcall |
| Protocol logic | ~700 | Dispatcher, storage, event |

Most gas is spent on USDC transfers (proxy overhead) - unavoidable without a different token.

### LIQ Repayment Pattern

LIQ uses `transfer()` + `balanceOf()` instead of `approve()` + `transferFrom()`:

| Pattern | Description |
|---------|-------------|
| **LIQ** | Borrower calls `USDC.transfer(lender, amount)`, lender verifies via `balanceOf()` |
| **Others** | Borrower calls `USDC.approve()`, lender calls `transferFrom()` |

The `transfer()` + `balanceOf()` pattern saves one external call compared to `approve()` + `transferFrom()`.

## FAQ

**Why USDC only?**

Single-token focus enables maximum gas optimization. Supporting multiple tokens would require additional storage reads and conditional logic, increasing gas costs. USDC is the most liquid stablecoin for arbitrage and liquidation use cases.

**Why Pure Yul?**

Yul (inline assembly) eliminates Solidity's safety checks and ABI encoding overhead. For a simple flash loan contract, these checks are redundant - the balance verification after callback is the only security that matters.

**Why not check the callback return value?**

ERC-3156 specifies that borrowers should return `keccak256("ERC3156FlashBorrower.onFlashLoan")`. However, checking this adds gas and provides no additional security - if the borrower doesn't repay, the transaction reverts anyway due to the balance check. The return value check is security theater.

**What happens if someone sends USDC directly to the contract?**

Direct transfers increase the actual balance but not `poolBalance`. **Warning: This excess USDC can be extracted by anyone via flash loan.** The repayment check only verifies `balanceAfter >= poolBalance`, so a borrower can effectively keep the excess by repaying less than borrowed. The owner should call `sync()` immediately after any direct transfer to protect excess funds by updating `poolBalance` to match the actual balance.

## Security

For security concerns, vulnerability reports, or questions about the security model, see [SECURITY.md](SECURITY.md).

## License

MIT
