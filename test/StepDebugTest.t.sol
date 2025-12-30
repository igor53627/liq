// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract StepDebugTest is Test {
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    
    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
    }
    
    function testMinimalHuff() public {
        // Minimal flash loan contract - just does balanceOf + transfer
        // Uses same memory layout as the real one
        bytes memory initCode = hex"5f60015560af8060103d393df360243573a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4814600e575f5ffd5b7f70a08231000000000000000000000000000000000000000000000000000000005f523060045260205f60245f73a0b86991c6218b36c1d19d4a2e9eb0ce3606eb485afa15609f575f516044357fa9059cbb000000000000000000000000000000000000000000000000000000005f526004356004528060245260205f60445f73a0b86991c6218b36c1d19d4a2e9eb0ce3606eb485af115609f5760015f5260205ff35b5f5ffd";
        
        address liq;
        assembly {
            liq := create(0, add(initCode, 32), mload(initCode))
        }
        console.log("Deployed at:", liq);
        console.log("Code size:", liq.code.length);
        
        vm.prank(USDC_WHALE);
        USDC.transfer(liq, 1000e6);
        
        // Call it with flashLoan-like calldata
        bytes memory callData = abi.encodeWithSelector(
            bytes4(0x5cffe9de),
            address(0xDEAD),
            address(USDC),
            uint256(100e6),
            bytes("")
        );
        
        (bool success, ) = liq.call(callData);
        console.log("Success:", success);
    }
}
