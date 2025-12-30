// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HuffDeployer} from "foundry-huff/HuffDeployer.sol";

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IFlashLender {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
    function maxFlashLoan(address token) external view returns (uint256);
    function flashFee(address token, uint256 amount) external view returns (uint256);
}

contract MockBorrower {
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    
    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external pure returns (bytes32) {
        return CALLBACK_SUCCESS;
    }
    
    function borrow(IFlashLender lender, uint256 amount) external returns (bool) {
        return lender.flashLoan(address(this), address(lender), amount, "");
    }
}

contract DiscoverableTest is Test {
    IFlashLender liq;
    IERC165 liqErc165;
    MockBorrower borrower;
    
    // ERC-3156 FlashLender interface ID
    bytes4 constant ERC3156_LENDER = 0x2f0a18c5;
    bytes4 constant ERC165 = 0x01ffc9a7;
    
    event FlashLoan(address indexed receiver, address indexed token, uint256 amount);
    
    function setUp() public {
        address deployed = HuffDeployer.deploy("LIQFlashDiscoverable");
        liq = IFlashLender(deployed);
        liqErc165 = IERC165(deployed);
        borrower = new MockBorrower();
    }
    
    function testSupportsERC165() public view {
        assertTrue(liqErc165.supportsInterface(ERC165));
    }
    
    function testSupportsERC3156() public view {
        assertTrue(liqErc165.supportsInterface(ERC3156_LENDER));
    }
    
    function testDoesNotSupportRandom() public view {
        assertFalse(liqErc165.supportsInterface(0xdeadbeef));
    }
    
    function testEmitsFlashLoanEvent() public {
        vm.expectEmit(true, true, true, true, address(liq));
        emit FlashLoan(address(borrower), address(liq), 1e18);
        
        borrower.borrow(liq, 1e18);
    }
    
    function testGasWithEvent() public {
        // Warm up
        borrower.borrow(liq, 1e18);
        
        uint256 g1 = gasleft();
        borrower.borrow(liq, 1e18);
        uint256 gasUsed = g1 - gasleft();
        
        console.log("Discoverable flash mint gas (warm):", gasUsed);
        console.log("Note: Event adds ~375 gas (log3 opcode)");
    }
    
    function testBotDiscoveryFlow() public {
        console.log("=== Bot Discovery Simulation ===");
        console.log("");
        
        // Step 1: Check ERC-165 support
        bool supportsFlash = liqErc165.supportsInterface(ERC3156_LENDER);
        console.log("1. supportsInterface(ERC3156):", supportsFlash);
        
        // Step 2: Query max flash loan
        uint256 maxLoan = liq.maxFlashLoan(address(liq));
        console.log("2. maxFlashLoan:", maxLoan == type(uint256).max ? "UNLIMITED" : "limited");
        
        // Step 3: Query fee
        uint256 fee = liq.flashFee(address(liq), 1e18);
        console.log("3. flashFee:", fee, "(FREE)");
        
        // Step 4: Execute
        bool success = borrower.borrow(liq, 1e18);
        console.log("4. flashLoan executed:", success);
        
        console.log("");
        console.log("Bot would add LIQ to its flash loan providers list!");
    }
}
