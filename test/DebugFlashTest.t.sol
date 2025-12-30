// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HuffDeployer} from "foundry-huff/HuffDeployer.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ILIQFlashUSDC {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external payable returns (bool);
    function flashFee(address token, uint256 amount) external view returns (uint256);
}

contract DebugFlashTest is Test {
    ILIQFlashUSDC liq;
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    
    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
        liq = ILIQFlashUSDC(HuffDeployer.deploy("LIQFlashUSDC"));
        
        // Fund with USDC
        vm.prank(USDC_WHALE);
        USDC.transfer(address(liq), 100_000e6);
    }
    
    function testCallBytes() public {
        vm.txGasPrice(0.18 gwei);
        
        // Check what bytecode looks like
        bytes memory code = address(liq).code;
        console.log("Code length:", code.length);
        
        // Try calling flashFee first (works)
        uint256 fee = liq.flashFee(address(USDC), 10_000e6);
        console.log("Fee:", fee);
        
        // Now try direct low-level call with flashLoan
        bytes memory data = abi.encodeWithSelector(
            0x5cffe9de,  // flashLoan selector
            address(this),  // receiver
            address(USDC),  // token
            uint256(10_000e6),  // amount
            ""  // empty data
        );
        
        console.log("Calldata length:", data.length);
        console.logBytes(data);
        
        // Call with limited gas to see where it fails
        (bool success, bytes memory ret) = address(liq).call{gas: 100000}(data);
        console.log("Success:", success);
        if (!success) {
            console.log("Return length:", ret.length);
            console.logBytes(ret);
        }
    }
}
