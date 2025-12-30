# LIQ Flash Mint - Ultra Gas-Optimized ERC-3156 Flash Loans

## Overview

LIQ is a **zero-fee, unlimited liquidity** flash mint implementation with the lowest gas costs in DeFi.

| Provider | Warm Gas | Cold Gas | Fee |
|----------|----------|----------|-----|
| **LIQ (Huff)** | **5,166** | 9,666 | 0% |
| LIQ (Yul) | 6,296 | 15,296 | 0% |
| Euler | 18,570 | - | 0% |
| Balancer | 28,500 | - | 0% |

**LIQ is 5.5x cheaper than Balancer and 3.6x cheaper than Euler.**

## Key Innovation

Traditional flash loans require:
1. SSTORE to mint tokens (+20,000 gas)
2. SSTORE to burn tokens (+5,000 gas)

LIQ's insight: **Flash minted tokens are virtual.** The borrower receives the `amount` in the callback arguments - no storage writes needed.

## Bot Discovery

### Method 1: ERC-165 Interface Detection

```solidity
interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// ERC-3156 FlashLender interface ID
bytes4 constant ERC3156_LENDER = 0x2f0a18c5;

// Check if contract supports flash loans
bool isFlashLender = IERC165(target).supportsInterface(ERC3156_LENDER);
```

### Method 2: Direct Query

```solidity
interface IERC3156FlashLender {
    function maxFlashLoan(address token) external view returns (uint256);
    function flashFee(address token, uint256 amount) external view returns (uint256);
}

// Query capabilities
uint256 maxAmount = liq.maxFlashLoan(address(liq)); // Returns type(uint256).max
uint256 fee = liq.flashFee(address(liq), 1e18);      // Returns 0
```

### Method 3: Event Indexing

```solidity
event FlashLoan(address indexed receiver, address indexed token, uint256 amount);
// Topic0: 0xc76f1b4fe4396ac07a9fa55a415d4ca430e72651d37d3401f3bed7cb13fc4f12
```

Index this event to track flash loan usage and discover active LIQ deployments.

## Usage

```solidity
import "IERC3156FlashBorrower.sol";

contract Arbitrageur is IERC3156FlashBorrower {
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    
    function executeArbitrage(address liq, uint256 amount) external {
        IERC3156FlashLender(liq).flashLoan(
            address(this),  // receiver
            liq,            // token (LIQ itself)
            amount,         // any amount up to uint256.max
            abi.encode(arbitrageParams)
        );
    }
    
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,      // Always 0 for LIQ
        bytes calldata data
    ) external returns (bytes32) {
        // NOTE: You don't have `amount` tokens in your balance!
        // The `amount` is passed as an argument for your arbitrage logic.
        
        // Execute your arbitrage here...
        
        return CALLBACK_SUCCESS;
    }
}
```

## Important: Virtual Token Model

LIQ flash mints are **virtual** - tokens are not actually minted to your balance. The `amount` is provided as a callback argument for your calculations. This enables:

1. **Unlimited liquidity**: Borrow any amount up to `uint256.max`
2. **Zero storage cost**: No SSTORE operations
3. **Lowest possible gas**: 5,166 gas warm

## Contract Addresses

| Network | Address | Verified |
|---------|---------|----------|
| Mainnet | TBD | - |
| Sepolia | TBD | - |

## Development

```bash
# Build
forge build

# Test
forge test -vvv

# Gas benchmarks
forge test --match-test testSideBySide -vvv
```

## Files

- `src/LIQFlashV2.huff` - Optimized flash mint (5,166 gas)
- `src/LIQFlashDiscoverable.huff` - With ERC-165 + events (7,000 gas)
- `src/LIQYul.sol` - Yul reference implementation

## License

MIT
