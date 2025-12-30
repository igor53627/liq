// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/LIQYul.sol";
import {HuffDeployer} from "foundry-huff/HuffDeployer.sol";

interface IFlashLender {
    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool);
    
    function maxFlashLoan(address token) external view returns (uint256);
    function flashFee(address token, uint256 amount) external view returns (uint256);
}

contract MockBorrower {
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    
    function onFlashLoan(
        address,    // initiator
        address,    // token
        uint256,    // amount
        uint256,    // fee
        bytes calldata // data
    ) external pure returns (bytes32) {
        return CALLBACK_SUCCESS;
    }
    
    function borrow(IFlashLender lender, uint256 amount) external returns (bool) {
        return lender.flashLoan(address(this), address(lender), amount, "");
    }
}

contract FlashGasTest is Test {
    LIQYul yul;
    IFlashLender huff;
    IFlashLender huffV4;
    MockBorrower borrower;
    
    function setUp() public {
        yul = new LIQYul();
        borrower = new MockBorrower();
        
        // Deploy Huff contracts
        huff = IFlashLender(HuffDeployer.deploy("LIQFlashV2"));
        huffV4 = IFlashLender(HuffDeployer.deploy("LIQFlashV4"));
    }
    
    function testYulFlashMint() public {
        // Warm up
        borrower.borrow(IFlashLender(address(yul)), 1e18);
        
        // Measure warm call
        uint256 gasBefore = gasleft();
        borrower.borrow(IFlashLender(address(yul)), 1e18);
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Yul warm flash mint gas:", gasUsed);
    }
    
    function testHuffFlashMint() public {
        // Warm up
        borrower.borrow(huff, 1e18);
        
        // Measure warm call
        uint256 gasBefore = gasleft();
        borrower.borrow(huff, 1e18);
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Huff warm flash mint gas:", gasUsed);
    }
    
    function testColdVsWarm() public {
        // Measure cold call (first call in tx)
        uint256 gasBefore = gasleft();
        borrower.borrow(huff, 1e18);
        uint256 coldGas = gasBefore - gasleft();
        
        // Measure warm call
        gasBefore = gasleft();
        borrower.borrow(huff, 1e18);
        uint256 warmGas = gasBefore - gasleft();
        
        console.log("Huff cold flash mint gas:", coldGas);
        console.log("Huff warm flash mint gas:", warmGas);
        console.log("Cold-warm delta:", coldGas - warmGas);
    }
    
    function testSideBySide() public {
        // Warm up all
        borrower.borrow(IFlashLender(address(yul)), 1e18);
        borrower.borrow(huff, 1e18);
        borrower.borrow(huffV4, 1e18);
        
        // Yul
        uint256 g1 = gasleft();
        borrower.borrow(IFlashLender(address(yul)), 1e18);
        uint256 yulGas = g1 - gasleft();
        
        // Huff V2
        uint256 g2 = gasleft();
        borrower.borrow(huff, 1e18);
        uint256 huffGas = g2 - gasleft();
        
        // Huff V4 (optimized)
        uint256 g3 = gasleft();
        borrower.borrow(huffV4, 1e18);
        uint256 huffV4Gas = g3 - gasleft();
        
        console.log("=== Side-by-side comparison ===");
        console.log("Yul     warm gas:", yulGas);
        console.log("Huff V2 warm gas:", huffGas);
        console.log("Huff V4 warm gas:", huffV4Gas);
        
        console.log("");
        console.log("=== Savings vs Yul ===");
        console.log("Huff V2 saves gas:", yulGas - huffGas);
        console.log("Huff V4 saves gas:", yulGas - huffV4Gas);
    }
    
    function testAllVersions() public {
        console.log("=== COLD vs WARM Gas Comparison ===");
        console.log("");
        
        // YUL
        uint256 g1 = gasleft();
        borrower.borrow(IFlashLender(address(yul)), 1e18);
        uint256 yulCold = g1 - gasleft();
        g1 = gasleft();
        borrower.borrow(IFlashLender(address(yul)), 1e18);
        uint256 yulWarm = g1 - gasleft();
        
        // HUFF V2
        g1 = gasleft();
        borrower.borrow(huff, 1e18);
        uint256 huffCold = g1 - gasleft();
        g1 = gasleft();
        borrower.borrow(huff, 1e18);
        uint256 huffWarm = g1 - gasleft();
        
        console.log("Yul:     cold=", yulCold, " warm=", yulWarm);
        console.log("Huff V2: cold=", huffCold, " warm=", huffWarm);
        
        console.log("");
        console.log("=== Savings ===");
        console.log("Huff saves (cold):", yulCold - huffCold);
        console.log("Huff saves (warm):", yulWarm - huffWarm);
    }
}
