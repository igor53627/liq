// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LIQFlashYul
/// @author LIQ Protocol
/// @notice Gas-optimized USDC flash loans with zero fees
/// @dev Pure Yul implementation for maximum gas efficiency
/// @dev Implements ERC-3156 flash loan interface
/// @custom:security-contact security@liq.protocol
///
/// @dev Storage Layout:
///   Slot 0: owner (address) - Can withdraw USDC
///   Slot 1: poolBalance (uint256) - Tracked USDC balance
///   Slot 2: locked (uint256) - Reentrancy guard (0 = unlocked, 1 = locked)
///
/// @dev Security Model:
///   - Optimistic transfer: USDC sent before callback, verified after
///   - Balance check ensures repayment: finalBalance >= poolBalance
///   - Reentrancy guard prevents poolBalance desync during callback
///   - Callback return value not checked (balance verification sufficient)
///
/// @dev Gas Optimization Techniques:
///   - Pure Yul fallback dispatcher (no Solidity overhead)
///   - Inline constants (no SLOAD for USDC address)
///   - Cached calldataload values
///   - Zero fees (no fee calculation or transfer)
///   - poolBalance storage instead of balanceOf() before transfer
///
/// @dev Supported Functions:
///   - flashLoan(address,address,uint256,bytes) [0x5cffe9de] - ERC-3156 flash loan
///   - maxFlashLoan(address) [0x613255ab] - Returns available liquidity
///   - flashFee(address,uint256) [0xd9d98ce4] - Always returns 0
///   - deposit(uint256) [0xb6b55f25] - Deposit USDC (requires approval)
///   - withdraw(uint256) [0x2e1a7d4d] - Withdraw USDC (owner only)
///   - sync() [0xfff6cae9] - Sync poolBalance to actual balance (owner only)
contract LIQFlashYul {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev USDC token address on Ethereum mainnet
    /// @dev Proxy: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract owner - can withdraw funds
    /// @dev Stored in slot 0
    address public owner;

    /// @notice Tracked USDC balance (avoids balanceOf call in hot path)
    /// @dev Stored in slot 1
    /// @dev Updated on deposit/withdraw, verified against actual balance after flash loan
    uint256 public poolBalance;

    /// @notice Reentrancy guard
    /// @dev Stored in slot 2 (0 = unlocked, 1 = locked)
    /// @dev Prevents poolBalance desync via reentrant deposit/withdraw during flashLoan
    uint256 private locked;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys the flash loan contract
    /// @dev Sets deployer as owner
    constructor() {
        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                            FLASH LOAN LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Handles all function calls via Yul dispatcher
    /// @dev Function selectors:
    ///   - 0x5cffe9de: flashLoan(address,address,uint256,bytes)
    ///   - 0x613255ab: maxFlashLoan(address)
    ///   - 0xd9d98ce4: flashFee(address,uint256)
    ///   - 0xb6b55f25: deposit(uint256)
    ///   - 0x2e1a7d4d: withdraw(uint256)
    fallback() external {
        assembly {
            //------------------------------------------------------
            // DISPATCHER
            //------------------------------------------------------
            let sel := shr(224, calldataload(0))

            //------------------------------------------------------
            // flashLoan(address receiver, address token, uint256 amount, bytes data)
            // Selector: 0x5cffe9de
            //
            // @param receiver - Contract to receive USDC and callback
            // @param token - Must be USDC (ignored, always USDC)
            // @param amount - Amount of USDC to borrow
            // @param data - Arbitrary data passed to callback
            // @return success - Always true if no revert
            //
            // Flow:
            //   1. Cache poolBalance as expected final balance
            //   2. Transfer USDC to receiver (optimistic)
            //   3. Call receiver.onFlashLoan(initiator, token, amount, 0, data)
            //   4. Verify USDC balance >= expected (ensures repayment)
            //   5. Return true
            //
            // Security:
            //   - Reverts if USDC transfer fails
            //   - Reverts if callback reverts
            //   - Reverts if USDC not fully repaid
            //------------------------------------------------------
            if eq(sel, 0x5cffe9de) {
                // Reentrancy guard - prevents poolBalance desync via callback
                if sload(2) { revert(0, 0) } // LOCKED
                sstore(2, 1)

                // Cache calldata values (saves ~6 gas per reuse)
                let receiver := calldataload(0x04)
                let token := calldataload(0x24)
                let amount := calldataload(0x44)

                // Enforce token == USDC (ERC-3156 compliance)
                if iszero(eq(token, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)) {
                    revert(0, 0) // UNSUPPORTED_TOKEN
                }

                // Load poolBalance for borrow cap and repayment check
                let poolBal := sload(1)

                // Prevent borrowing more than tracked pool
                if gt(amount, poolBal) {
                    revert(0, 0) // AMOUNT_EXCEEDS_POOL
                }

                // Transfer USDC to receiver
                // transfer(address to, uint256 amount)
                mstore(0x00, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
                mstore(0x04, receiver)
                mstore(0x24, amount)
                if iszero(call(gas(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0, 0x00, 0x44, 0x00, 0x20)) {
                    revert(0, 0)
                }

                // Build callback calldata
                // onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes data)
                // Selector: 0x23e30c8b
                mstore(0x100, 0x23e30c8b00000000000000000000000000000000000000000000000000000000)
                mstore(0x104, caller()) // initiator = msg.sender
                mstore(0x124, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) // token = USDC
                mstore(0x144, amount) // amount
                mstore(0x164, 0) // fee = 0 (zero fee flash loans)
                mstore(0x184, 0xa0) // data offset (160 bytes from start)

                // Copy bytes data from calldata to memory
                let dataOffset := add(calldataload(0x64), 0x04)
                let dataLen := calldataload(dataOffset)
                mstore(0x1a4, dataLen) // data.length
                calldatacopy(0x1c4, add(dataOffset, 0x20), dataLen) // data bytes

                // Call receiver.onFlashLoan(...)
                // Return value not checked - balance verification is sufficient
                if iszero(call(gas(), receiver, 0, 0x100, add(0xc4, dataLen), 0x00, 0x20)) {
                    revert(0, 0)
                }

                // Verify repayment: final balance >= poolBalance
                // Owner must call sync() to protect any excess USDC from direct transfers
                mstore(0x00, 0x70a0823100000000000000000000000000000000000000000000000000000000)
                mstore(0x04, address())
                if iszero(staticcall(gas(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0x00, 0x24, 0x00, 0x20)) {
                    revert(0, 0)
                }
                if lt(mload(0x00), poolBal) {
                    revert(0, 0) // NOT_REPAID
                }

                // Emit FlashLoan(receiver, token, amount)
                // topic0 = keccak256("FlashLoan(address,address,uint256)") = 0xc76f1b4f...
                mstore(0x00, amount)
                log3(
                    0x00,
                    0x20,
                    0xc76f1b4fe4396ac07a9fa55a415d4ca430e72651d37d3401f3bed7cb13fc4f12,
                    receiver,
                    0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
                )

                // Unlock reentrancy guard
                sstore(2, 0)

                // Return true
                mstore(0x00, 1)
                return(0x00, 0x20)
            }

            //------------------------------------------------------
            // maxFlashLoan(address token)
            // Selector: 0x613255ab
            //
            // @param token - Token address (returns 0 for non-USDC)
            // @return maxLoan - Maximum available flash loan amount
            //------------------------------------------------------
            if eq(sel, 0x613255ab) {
                let token := calldataload(0x04)
                // Return 0 for unsupported tokens (ERC-3156 compliant)
                if iszero(eq(token, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)) {
                    mstore(0x00, 0)
                    return(0x00, 0x20)
                }
                mstore(0x00, sload(1)) // poolBalance
                return(0x00, 0x20)
            }

            //------------------------------------------------------
            // flashFee(address token, uint256 amount)
            // Selector: 0xd9d98ce4
            //
            // @param token - Token address (reverts for non-USDC)
            // @param amount - Loan amount (ignored)
            // @return fee - Always 0 (zero fee flash loans)
            //------------------------------------------------------
            if eq(sel, 0xd9d98ce4) {
                let token := calldataload(0x04)
                // Revert for unsupported tokens (ERC-3156 spec)
                if iszero(eq(token, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)) {
                    revert(0, 0) // UNSUPPORTED_TOKEN
                }
                mstore(0x00, 0)
                return(0x00, 0x20)
            }

            //------------------------------------------------------
            // deposit(uint256 amount)
            // Selector: 0xb6b55f25
            //
            // @param amount - USDC amount to deposit
            // @dev Requires prior USDC approval
            // @dev Anyone can deposit (adds liquidity)
            // @dev Blocked during flash loan callback (reentrancy protection)
            //------------------------------------------------------
            if eq(sel, 0xb6b55f25) {
                // Reentrancy guard - prevent deposit during flashLoan callback
                if sload(2) { revert(0, 0) } // LOCKED

                let amt := calldataload(0x04)

                // transferFrom(address from, address to, uint256 amount)
                mstore(0x00, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
                mstore(0x04, caller())
                mstore(0x24, address())
                mstore(0x44, amt)
                if iszero(call(gas(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0, 0x00, 0x64, 0x00, 0x20)) {
                    revert(0, 0)
                }

                // Update poolBalance (slot 1)
                sstore(1, add(sload(1), amt))
                stop()
            }

            //------------------------------------------------------
            // withdraw(uint256 amount)
            // Selector: 0x2e1a7d4d
            //
            // @param amount - USDC amount to withdraw
            // @dev Only owner can withdraw
            // @dev Blocked during flash loan callback (reentrancy protection)
            //------------------------------------------------------
            if eq(sel, 0x2e1a7d4d) {
                // Reentrancy guard - prevent withdraw during flashLoan callback
                if sload(2) { revert(0, 0) } // LOCKED

                let c := caller()

                // Owner check (slot 0)
                if iszero(eq(c, sload(0))) {
                    revert(0, 0) // NOT_OWNER
                }

                let amt := calldataload(0x04)
                let currentBal := sload(1)

                // Underflow protection: revert if amt > poolBalance
                if gt(amt, currentBal) {
                    revert(0, 0) // INSUFFICIENT_BALANCE
                }

                // Update poolBalance first (slot 1)
                sstore(1, sub(currentBal, amt))

                // transfer(address to, uint256 amount)
                mstore(0x00, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
                mstore(0x04, c)
                mstore(0x24, amt)
                if iszero(call(gas(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0, 0x00, 0x44, 0x00, 0x20)) {
                    revert(0, 0)
                }
                stop()
            }

            //------------------------------------------------------
            // sync()
            // Selector: 0xfff6cae9
            //
            // @dev Syncs poolBalance to actual USDC balance
            // @dev Only owner can call, blocked during flash loan
            // @dev Call after direct USDC transfers to protect excess
            //------------------------------------------------------
            if eq(sel, 0xfff6cae9) {
                // Reentrancy guard - prevent sync during flashLoan callback
                if sload(2) { revert(0, 0) } // LOCKED

                // Owner check (slot 0)
                if iszero(eq(caller(), sload(0))) {
                    revert(0, 0) // NOT_OWNER
                }

                // Get actual USDC balance
                mstore(0x00, 0x70a0823100000000000000000000000000000000000000000000000000000000)
                mstore(0x04, address())
                if iszero(staticcall(gas(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0x00, 0x24, 0x00, 0x20)) {
                    revert(0, 0)
                }

                // Update poolBalance to actual balance (slot 1)
                sstore(1, mload(0x00))
                stop()
            }

            //------------------------------------------------------
            // Unknown selector: revert
            //------------------------------------------------------
            revert(0, 0)
        }
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfer ownership
    /// @param newOwner New owner address
    /// @dev Only callable by current owner
    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "NOT_OWNER");
        require(newOwner != address(0), "ZERO_ADDRESS");
        owner = newOwner;
    }
}
