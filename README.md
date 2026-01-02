# LIQ Flash Loans

**Zero-fee, gas-optimized USDC flash loans for arbitrage and liquidation bots.**

## Gas Comparison

| Protocol | Warm Gas | Overhead |
|----------|----------|----------|
| Balancer | ~80,000 | ~28,000 |
| Aave V3 | ~90,000 | ~38,000 |
| **LIQ** | **40,736** | **~700** |

LIQ is **~50% cheaper** than alternatives.

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
- Token parameter (always USDC)

## Deployment

```bash
# Install dependencies
forge install

# Run tests (requires Tenderly RPC for mainnet fork)
source ~/.zsh_secrets
forge test --fork-url "$TENDERLY_VIRTUAL_TESTNET_RPC" --match-contract YulTest -vvv

# Deploy
forge create src/LIQFlashYul.sol:LIQFlashYul --rpc-url $RPC_URL --private-key $PRIVATE_KEY
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

## Gas Breakdown

Total warm gas: **40,736**

| Component | Gas | Notes |
|-----------|-----|-------|
| USDC transfer out | ~29,000 | Proxy + implementation |
| Callback + repay | ~7,000 | Borrower's transfer |
| balanceOf check | ~2,500 | USDC call |
| Protocol logic | ~700 | Dispatcher, storage, return |

The ~40k is USDC's overhead - unavoidable without a different token.

## License

MIT
