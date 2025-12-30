// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HuffDeployer} from "foundry-huff/HuffDeployer.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract ForkDebugTest is Test {
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    
    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
    }
    
    function testDirectHuffCall() public {
        address liq = HuffDeployer.deploy("LIQFlashUSDC");
        
        // Fund it
        vm.prank(USDC_WHALE);
        USDC.transfer(liq, 100_000e6);
        
        console.log("LIQ address:", liq);
        console.log("LIQ USDC balance:", USDC.balanceOf(liq));
        
        // Set low gas price for free tier
        vm.txGasPrice(0.18 gwei);
        
        // Build flashLoan calldata manually
        bytes memory callData = abi.encodeWithSelector(
            bytes4(0x5cffe9de),
            address(this),
            address(USDC),
            uint256(1000e6),
            bytes("")
        );
        
        console.log("Calling flashLoan...");
        console.log("Calldata length:", callData.length);
        
        // Try with assembly to see the exact error
        assembly {
            let success := call(gas(), liq, 0, add(callData, 32), mload(callData), 0, 0)
            if iszero(success) {
                // Get return data size
                let size := returndatasize()
                // Log it
                mstore(0x40, size)
            }
        }
        
        uint256 retSize;
        assembly { retSize := mload(0x40) }
        console.log("Return data size:", retSize);
    }
    
    function testManualBalanceOfFirst() public {
        address liq = HuffDeployer.deploy("LIQFlashUSDC");
        
        vm.prank(USDC_WHALE);
        USDC.transfer(liq, 100_000e6);
        
        vm.txGasPrice(0.18 gwei);
        
        // First, manually call balanceOf on USDC to warm the slot
        uint256 bal1 = USDC.balanceOf(liq);
        console.log("Direct balance check:", bal1);
        
        // Now try flashLoan
        bytes memory callData = abi.encodeWithSelector(
            bytes4(0x5cffe9de),
            address(this),
            address(USDC),
            uint256(1000e6),
            bytes("")
        );
        
        (bool success, ) = liq.call{gas: 500000}(callData);
        console.log("FlashLoan success:", success);
    }
}
