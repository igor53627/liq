// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HuffDeployer} from "foundry-huff/HuffDeployer.sol";

interface ILIQFinal {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
    function flashLoanRaw(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
    function maxFlashLoan(address token) external view returns (uint256);
    function flashFee(address token, uint256 amount) external view returns (uint256);
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

contract MockBorrower {
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    
    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external pure returns (bytes32) {
        return CALLBACK_SUCCESS;
    }
    
    function borrowWithEvent(ILIQFinal liq, uint256 amount) external returns (bool) {
        return liq.flashLoan(address(this), address(liq), amount, "");
    }
    
    function borrowRaw(ILIQFinal liq, uint256 amount) external returns (bool) {
        return liq.flashLoanRaw(address(this), address(liq), amount, "");
    }
}

contract FinalTest is Test {
    ILIQFinal liq;
    MockBorrower borrower;
    
    event FlashLoan(address indexed receiver, address indexed token, uint256 amount);
    
    function setUp() public {
        liq = ILIQFinal(HuffDeployer.deploy("LIQFlashFinal"));
        borrower = new MockBorrower();
    }
    
    function testFlashLoanWithEvent() public {
        vm.expectEmit(true, true, true, true, address(liq));
        emit FlashLoan(address(borrower), address(liq), 1e18);
        
        borrower.borrowWithEvent(liq, 1e18);
    }
    
    function testFlashLoanRawNoEvent() public {
        vm.recordLogs();
        borrower.borrowRaw(liq, 1e18);
        
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "Raw should emit no events");
    }
    
    function testGasComparison() public {
        // Warm up
        borrower.borrowWithEvent(liq, 1e18);
        borrower.borrowRaw(liq, 1e18);
        
        // With event
        uint256 g1 = gasleft();
        borrower.borrowWithEvent(liq, 1e18);
        uint256 withEvent = g1 - gasleft();
        
        // Raw (no event)
        uint256 g2 = gasleft();
        borrower.borrowRaw(liq, 1e18);
        uint256 raw = g2 - gasleft();
        
        console.log("=== Dual-Mode Gas Comparison ===");
        console.log("flashLoan (with event):", withEvent);
        console.log("flashLoanRaw (no event):", raw);
        console.log("Event overhead:", withEvent - raw);
    }
    
    function testSupportsInterface() public view {
        assertTrue(liq.supportsInterface(0x01ffc9a7)); // ERC165
        assertTrue(liq.supportsInterface(0x2f0a18c5)); // ERC3156
        assertFalse(liq.supportsInterface(0xdeadbeef));
    }
    
    function testMaxFlashLoan() public view {
        assertEq(liq.maxFlashLoan(address(liq)), type(uint256).max);
        assertEq(liq.maxFlashLoan(address(0x1234)), 0);
    }
    
    function testFlashFee() public view {
        assertEq(liq.flashFee(address(liq), 1e18), 0);
    }
}
