// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract MinimalHuffTest is Test {
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    
    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
    }
    
    function testMinimalTransfer() public {
        bytes memory initCode = hex"5f60015560c780600d3d393df360243573a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4814156100c3577f70a08231000000000000000000000000000000000000000000000000000000005f523060045260205f60245f73a0b86991c6218b36c1d19d4a2e9eb0ce3606eb485afa156100c3575f516044357fa9059cbb000000000000000000000000000000000000000000000000000000005f526004356004528060245260205f60445f73a0b86991c6218b36c1d19d4a2e9eb0ce3606eb485af1156100c35760015f5260205ff35b5f5ffd";
        
        address liq;
        assembly {
            liq := create(0, add(initCode, 32), mload(initCode))
        }
        require(liq != address(0), "deploy failed");
        console.log("Deployed at:", liq);
        console.log("Code size:", liq.code.length);
        
        // Fund
        vm.prank(USDC_WHALE);
        USDC.transfer(liq, 1000e6);
        console.log("LIQ balance:", USDC.balanceOf(liq));
        
        // Call with flashLoan calldata format
        address receiver = address(0xDEAD);
        bytes memory callData = abi.encodeWithSelector(
            bytes4(0x5cffe9de),
            receiver,
            address(USDC),
            uint256(100e6),
            bytes("")
        );
        
        console.log("Calling...");
        (bool success, bytes memory result) = liq.call(callData);
        console.log("Success:", success);
        if (success) {
            console.log("Result:", abi.decode(result, (uint256)));
            console.log("Receiver balance:", USDC.balanceOf(receiver));
        }
    }
}
