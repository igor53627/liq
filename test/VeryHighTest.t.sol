// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// Pure assembly contract that mimics what Huff does
contract PureAsmContract {
    constructor() {
        // Copy runtime code
        assembly {
            // Store some state in slot 0 to mimic constructor
            sstore(0, origin())
        }
    }
    
    fallback() external payable {
        assembly {
            // Simple: just do balanceOf and return the result
            // Memory at 0x400
            let USDC := 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
            let sel := 0x70a0823100000000000000000000000000000000000000000000000000000000
            
            mstore(0x400, sel)
            mstore(0x404, address())
            
            let success := staticcall(gas(), USDC, 0x400, 0x24, 0x400, 0x20)
            if iszero(success) { revert(0, 0) }
            
            let bal := mload(0x400)
            mstore(0x400, bal)
            return(0x400, 0x20)
        }
    }
}

contract VeryHighTest is Test {
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    
    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
    }
    
    function testPureAsmContract() public {
        PureAsmContract c = new PureAsmContract();
        
        vm.prank(USDC_WHALE);
        USDC.transfer(address(c), 1000e6);
        
        (bool success, bytes memory result) = address(c).call("");
        console.log("Success:", success);
        if (success && result.length > 0) {
            console.log("Balance:", abi.decode(result, (uint256)));
        }
    }
}
