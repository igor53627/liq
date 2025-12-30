// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HuffDeployer} from "foundry-huff/HuffDeployer.sol";

// Mock USDC for local testing
contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

interface ILIQFlashUSDC {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external payable returns (bool);
    function flashFee(address token, uint256 amount) external view returns (uint256);
}

contract LocalFlashTest is Test {
    function testDeployAndCallFee() public {
        address liq = HuffDeployer.deploy("LIQFlashUSDC");
        console.log("Deployed at:", liq);
        
        // Check if flashFee works
        // Note: this will fail because USDC address is hardcoded
        vm.txGasPrice(0.18 gwei);
        
        bytes memory callData = abi.encodeWithSelector(
            bytes4(0xd9d98ce4), // flashFee selector
            address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC
            uint256(10000e6)
        );
        
        (bool success, bytes memory result) = liq.call(callData);
        console.log("flashFee success:", success);
        if (success) {
            console.log("Fee:", abi.decode(result, (uint256)));
        }
    }
    
    function testLowLevelCall() public {
        address liq = HuffDeployer.deploy("LIQFlashUSDC");
        
        // Test raw bytes - flashLoan with minimal calldata
        bytes memory callData = abi.encodeWithSelector(
            bytes4(0x5cffe9de), // flashLoan selector
            address(0x1234567890123456789012345678901234567890), // receiver
            address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC
            uint256(1000),
            bytes("")
        );
        
        console.log("Calldata:");
        console.logBytes(callData);
        console.log("Calldata length:", callData.length);
        
        // This will fail early because there's no USDC contract here
        // but we should at least get past the initial dispatch
        (bool success, bytes memory result) = liq.call(callData);
        console.log("Call success:", success);
        console.log("Result length:", result.length);
        if (result.length > 0) {
            console.logBytes(result);
        }
    }
}
