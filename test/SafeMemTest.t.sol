// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract SafeMemTest is Test {
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    
    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
    }
    
    function testSafeMemLayout() public {
        address target = address(0xBEEF);
        vm.prank(USDC_WHALE);
        USDC.transfer(target, 1000e6);
        
        address usdc = address(USDC);
        
        // Use memory starting at 0x80 (safe area)
        assembly {
            mstore(0x80, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(0x84, target)
            
            let success := staticcall(gas(), usdc, 0x80, 0x24, 0xc0, 0x20)
            
            if iszero(success) {
                revert(0, 0)
            }
            
            let bal := mload(0xc0)
            mstore(0x100, bal)
        }
        
        uint256 bal;
        assembly { bal := mload(0x100) }
        console.log("Balance from safe ASM:", bal);
    }
}
