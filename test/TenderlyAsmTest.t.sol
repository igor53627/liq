// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/LIQFlashUSDCAsm.sol";

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

contract MockBorrower {
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    
    function borrow(address payable lender, uint256 amount) external payable {
        LIQFlashUSDCAsm(lender).flashLoan{value: msg.value}(
            address(this),
            address(USDC),
            amount,
            ""
        );
    }
    
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        // Repay the loan
        USDC.transfer(msg.sender, amount);
        return CALLBACK_SUCCESS;
    }
}

contract TenderlyAsmTest is Test {
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    
    LIQFlashUSDCAsm lender;
    MockBorrower borrower;
    address treasury;
    
    receive() external payable {}
    
    function setUp() public {
        lender = new LIQFlashUSDCAsm();
        borrower = new MockBorrower();
        treasury = address(this);
        
        // Fund the lender with USDC via deposit (updates poolBalance)
        vm.prank(USDC_WHALE);
        USDC.transfer(address(this), 100_000e6);
        IERC20Approve(address(USDC)).approve(address(lender), 100_000e6);
        lender.deposit(100_000e6);
    }
    
    function testFlashLoanAsm() public {
        vm.txGasPrice(20 gwei);
        
        uint256 amount = 10_000e6;
        uint256 fee = lender.flashFee(address(USDC), amount);
        console.log("Fee:", fee);
        
        vm.deal(address(borrower), fee);
        borrower.borrow{value: fee}(payable(address(lender)), amount);
        
        console.log("[PASS] Flash loan completed successfully");
    }
    
    function testGasBenchmark() public {
        vm.txGasPrice(20 gwei);
        
        uint256 amount = 10_000e6;
        uint256 fee = lender.flashFee(address(USDC), amount);
        vm.deal(address(borrower), fee * 2);
        
        // Measure first call (cold storage) 
        uint256 gasBefore = gasleft();
        borrower.borrow{value: fee}(payable(address(lender)), amount);
        uint256 gasCold = gasBefore - gasleft();
        
        // Measure second call (warm storage)
        gasBefore = gasleft();
        borrower.borrow{value: fee}(payable(address(lender)), amount);
        uint256 gasWarm = gasBefore - gasleft();
        
        console.log("=== GAS BENCHMARK ===");
        console.log("Flash loan (cold):", gasCold);
        console.log("Flash loan (warm):", gasWarm);
    }
    
    function testMaxFlashLoan() public view {
        uint256 max = lender.maxFlashLoan(address(USDC));
        console.log("Max flash loan:", max);
        assertEq(max, 100_000e6);
    }
    
    function testFlashFeeScaling() public {
        vm.txGasPrice(5 gwei);
        uint256 fee5 = lender.flashFee(address(USDC), 1e6);
        console.log("Fee at 5 gwei:", fee5);
        
        vm.txGasPrice(20 gwei);
        uint256 fee20 = lender.flashFee(address(USDC), 1e6);
        console.log("Fee at 20 gwei:", fee20);
    }
    
    function testOwnerFunctions() public {
        // Test partial withdraw
        uint256 balBefore = USDC.balanceOf(address(this));
        lender.withdraw(10_000e6);
        uint256 balAfter = USDC.balanceOf(address(this));
        assertEq(balAfter - balBefore, 10_000e6);
        console.log("Partial withdraw: 10k USDC");
        
        // Test deposit (need approval first)
        IERC20Approve(address(USDC)).approve(address(lender), 5_000e6);
        lender.deposit(5_000e6);
        assertEq(lender.maxFlashLoan(address(USDC)), 95_000e6);
        console.log("Deposit: 5k USDC back");
        
        // Test transferOwnership
        address newOwner = address(0x1234);
        lender.transferOwnership(newOwner);
        assertEq(lender.owner(), newOwner);
        console.log("Ownership transferred");
    }
    
    function testWithdrawAll() public {
        uint256 poolBal = lender.maxFlashLoan(address(USDC));
        lender.withdrawAll();
        assertEq(lender.maxFlashLoan(address(USDC)), 0);
        assertEq(USDC.balanceOf(address(this)), poolBal);
        console.log("Withdrew all:", poolBal);
    }
}
