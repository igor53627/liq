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
///   Slot 0: owner (address) - Can withdraw USDC and rescue ETH
///   Slot 1: poolBalance (uint256) - Tracked USDC balance
///
/// @dev Security Model:
///   - Optimistic transfer: USDC sent before callback, verified after
///   - Balance check ensures repayment: finalBalance >= poolBalance
///   - No reentrancy guard needed: balance check is atomic protection
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
    fallback() external payable {
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
                // Cache calldata values (saves ~6 gas per reuse)
                let receiver := calldataload(0x04)
                let amount := calldataload(0x44)

                // Load poolBalance - this is the minimum balance after repayment
                // Stored in slot 1
                let expectedBal := sload(1)

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
                mstore(0x104, caller())           // initiator = msg.sender
                mstore(0x124, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)  // token = USDC
                mstore(0x144, amount)             // amount
                mstore(0x164, 0)                  // fee = 0 (zero fee flash loans)
                mstore(0x184, 0xa0)               // data offset (160 bytes from start)

                // Copy bytes data from calldata to memory
                let dataOffset := add(calldataload(0x64), 0x04)
                let dataLen := calldataload(dataOffset)
                mstore(0x1a4, dataLen)            // data.length
                calldatacopy(0x1c4, add(dataOffset, 0x20), dataLen)  // data bytes

                // Call receiver.onFlashLoan(...)
                // Return value not checked - balance verification is sufficient
                if iszero(call(gas(), receiver, 0, 0x100, add(0xc4, dataLen), 0x00, 0x20)) {
                    revert(0, 0)
                }

                // Verify repayment: actual balance >= expected balance
                // balanceOf(address account)
                mstore(0x00, 0x70a0823100000000000000000000000000000000000000000000000000000000)
                mstore(0x04, address())
                if iszero(staticcall(gas(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0x00, 0x24, 0x00, 0x20)) {
                    revert(0, 0)
                }
                if lt(mload(0x00), expectedBal) {
                    revert(0, 0)  // NOT_REPAID
                }

                // Return true
                mstore(0x00, 1)
                return(0x00, 0x20)
            }

            //------------------------------------------------------
            // maxFlashLoan(address token)
            // Selector: 0x613255ab
            //
            // @param token - Token address (ignored, always returns USDC balance)
            // @return maxLoan - Maximum available flash loan amount
            //------------------------------------------------------
            if eq(sel, 0x613255ab) {
                mstore(0x00, sload(1))  // poolBalance
                return(0x00, 0x20)
            }

            //------------------------------------------------------
            // flashFee(address token, uint256 amount)
            // Selector: 0xd9d98ce4
            //
            // @param token - Token address (ignored)
            // @param amount - Loan amount (ignored)
            // @return fee - Always 0 (zero fee flash loans)
            //------------------------------------------------------
            if eq(sel, 0xd9d98ce4) {
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
            //------------------------------------------------------
            if eq(sel, 0xb6b55f25) {
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
            //------------------------------------------------------
            if eq(sel, 0x2e1a7d4d) {
                // Owner check (slot 0)
                if iszero(eq(caller(), sload(0))) {
                    revert(0, 0)  // NOT_OWNER
                }

                let amt := calldataload(0x04)

                // Update poolBalance first (slot 1)
                sstore(1, sub(sload(1), amt))

                // transfer(address to, uint256 amount)
                mstore(0x00, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
                mstore(0x04, caller())
                mstore(0x24, amt)
                if iszero(call(gas(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0, 0x00, 0x44, 0x00, 0x20)) {
                    revert(0, 0)
                }
                stop()
            }

            //------------------------------------------------------
            // Fallback: Accept ETH (for rescueETH)
            //------------------------------------------------------
            stop()
        }
    }

    /// @notice Accept ETH transfers
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                              ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Rescue ETH accidentally sent to contract
    /// @dev Only callable by owner
    function rescueETH() external {
        require(msg.sender == owner, "NOT_OWNER");
        payable(owner).transfer(address(this).balance);
    }

    /// @notice Transfer ownership
    /// @param newOwner New owner address
    /// @dev Only callable by current owner
    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "NOT_OWNER");
        require(newOwner != address(0), "ZERO_ADDRESS");
        owner = newOwner;
    }
}
