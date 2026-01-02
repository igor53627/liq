// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/LIQFlashYul.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface ILIQFlashYul {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external payable returns (bool);
    function maxFlashLoan(address token) external view returns (uint256);
    function flashFee(address token, uint256 amount) external view returns (uint256);
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
}

contract MockBorrower {
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    
    function borrow(address payable lender, uint256 amount) external payable {
        ILIQFlashYul(lender).flashLoan{value: msg.value}(
            address(this),
            address(USDC),
            amount,
            ""
        );
    }
    
    function onFlashLoan(
        address,
        address,
        uint256 amount,
        uint256,
        bytes calldata
    ) external returns (bytes32) {
        USDC.transfer(msg.sender, amount);
        return CALLBACK_SUCCESS;
    }
}

contract YulTest is Test {
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    
    LIQFlashYul lender;
    MockBorrower borrower;
    
    receive() external payable {}
    
    function setUp() public {
        lender = new LIQFlashYul();
        borrower = new MockBorrower();
        
        // Fund lender via deposit
        vm.prank(USDC_WHALE);
        USDC.transfer(address(this), 100_000e6);
        USDC.approve(address(lender), 100_000e6);
        ILIQFlashYul(address(lender)).deposit(100_000e6);
    }
    
    function testFlashLoan() public {
        vm.txGasPrice(20 gwei);
        
        uint256 amount = 10_000e6;
        uint256 fee = ILIQFlashYul(address(lender)).flashFee(address(USDC), amount);
        console.log("Fee:", fee);
        
        vm.deal(address(borrower), fee);
        borrower.borrow{value: fee}(payable(address(lender)), amount);
        
        console.log("[PASS] Flash loan completed");
    }
    
    function testGasBenchmark() public {
        vm.txGasPrice(20 gwei);
        
        uint256 amount = 10_000e6;
        uint256 fee = ILIQFlashYul(address(lender)).flashFee(address(USDC), amount);
        vm.deal(address(borrower), fee * 2);
        
        // First call (cold)
        uint256 gasBefore = gasleft();
        borrower.borrow{value: fee}(payable(address(lender)), amount);
        uint256 gasCold = gasBefore - gasleft();
        
        // Second call (warm)
        gasBefore = gasleft();
        borrower.borrow{value: fee}(payable(address(lender)), amount);
        uint256 gasWarm = gasBefore - gasleft();
        
        console.log("=== YUL GAS BENCHMARK ===");
        console.log("Flash loan (cold):", gasCold);
        console.log("Flash loan (warm):", gasWarm);
    }
    
    function testMaxFlashLoan() public view {
        uint256 max = ILIQFlashYul(address(lender)).maxFlashLoan(address(USDC));
        console.log("Max flash loan:", max);
        assertEq(max, 100_000e6);
    }
}
