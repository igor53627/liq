// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// Simulates exactly what Huff does: mstore, mstore, staticcall, iszero, jumpi, mload
contract HuffSimulator {
    fallback() external payable {
        assembly {
            let USDC := 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
            let BALANCE_OF_SIG := 0x70a0823100000000000000000000000000000000000000000000000000000000
            
            // Step 1: mstore selector at 0x100
            mstore(0x100, BALANCE_OF_SIG)
            
            // Step 2: mstore address at 0x104
            mstore(0x104, address())
            
            // Step 3: staticcall(gas, usdc, 0x100, 0x24, 0x100, 0x20)
            let success := staticcall(gas(), USDC, 0x100, 0x24, 0x100, 0x20)
            
            // Step 4: iszero check
            if iszero(success) { revert(0, 0) }
            
            // Step 5: mload from 0x100
            let bal := mload(0x100)
            
            // Return it
            mstore(0x100, bal)
            return(0x100, 0x20)
        }
    }
}

contract AsmSequenceTest is Test {
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    
    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
    }
    
    function testHuffSimulator() public {
        HuffSimulator c = new HuffSimulator();
        
        vm.prank(USDC_WHALE);
        USDC.transfer(address(c), 1000e6);
        
        (bool success, bytes memory result) = address(c).call("");
        console.log("Success:", success);
        if (success && result.length > 0) {
            console.log("Balance:", abi.decode(result, (uint256)));
        }
    }
}
