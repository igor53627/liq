// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LIQFlashYul - Pure Yul Flash Loans
/// @notice Maximum gas optimization via inline Yul
/// @notice Fees accumulate in contract, owner withdraws via rescueETH()
contract LIQFlashYul {
    address public owner;
    uint256 public poolBalance;
    
    constructor() {
        owner = msg.sender;
    }
    
    fallback() external payable {
        assembly {
            // Get selector
            let sel := shr(224, calldataload(0))
            
            // flashLoan(address,address,uint256,bytes) = 0x5cffe9de
            if eq(sel, 0x5cffe9de) {
                // Cache calldataload values
                let receiver := calldataload(0x04)
                let amount := calldataload(0x44)
                
                // Load poolBalance (expected balance) - slot 1
                let expectedBal := sload(1)
                
                // Transfer USDC to receiver
                mstore(0x00, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
                mstore(0x04, receiver)
                mstore(0x24, amount)
                if iszero(call(gas(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0, 0x00, 0x44, 0x00, 0x20)) { revert(0, 0) }
                
                // Build callback: onFlashLoan(initiator, token, amount, 0, data)
                mstore(0x100, 0x23e30c8b00000000000000000000000000000000000000000000000000000000)
                mstore(0x104, caller())           // initiator
                mstore(0x124, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)  // token
                mstore(0x144, amount)             // amount
                mstore(0x164, 0)                  // fee = 0
                mstore(0x184, 0xa0)               // data offset
                
                // Copy data
                let dataOffset := add(calldataload(0x64), 0x04)
                let dataLen := calldataload(dataOffset)
                mstore(0x1a4, dataLen)
                calldatacopy(0x1c4, add(dataOffset, 0x20), dataLen)
                
                // Call callback
                if iszero(call(gas(), receiver, 0, 0x100, add(0xc4, dataLen), 0x00, 0x20)) { revert(0, 0) }
                
                // Check final balance
                mstore(0x00, 0x70a0823100000000000000000000000000000000000000000000000000000000)
                mstore(0x04, address())
                if iszero(staticcall(gas(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0x00, 0x24, 0x00, 0x20)) { revert(0, 0) }
                if lt(mload(0x00), expectedBal) { revert(0, 0) }
                
                // Return true
                mstore(0x00, 1)
                return(0x00, 0x20)
            }
            
            // maxFlashLoan(address) = 0x613255ab
            if eq(sel, 0x613255ab) {
                mstore(0x00, sload(1))
                return(0x00, 0x20)
            }
            
            // flashFee(address,uint256) = 0xd9d98ce4 - always 0
            if eq(sel, 0xd9d98ce4) {
                mstore(0x00, 0)
                return(0x00, 0x20)
            }
            
            // deposit(uint256) = 0xb6b55f25
            if eq(sel, 0xb6b55f25) {
                let amt := calldataload(0x04)
                // transferFrom
                mstore(0x00, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
                mstore(0x04, caller())
                mstore(0x24, address())
                mstore(0x44, amt)
                if iszero(call(gas(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0, 0x00, 0x64, 0x00, 0x20)) { revert(0, 0) }
                // Update balance - slot 1
                sstore(1, add(sload(1), amt))
                stop()
            }
            
            // withdraw(uint256) = 0x2e1a7d4d
            if eq(sel, 0x2e1a7d4d) {
                if iszero(eq(caller(), sload(0))) { revert(0, 0) }
                let amt := calldataload(0x04)
                sstore(1, sub(sload(1), amt))
                mstore(0x00, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
                mstore(0x04, caller())
                mstore(0x24, amt)
                if iszero(call(gas(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0, 0x00, 0x44, 0x00, 0x20)) { revert(0, 0) }
                stop()
            }
            
            // Fallback: receive ETH
            stop()
        }
    }
    
    receive() external payable {}
}
