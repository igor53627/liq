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
    
    function borrow(address payable lender, uint256 amount) external {
        ILIQFlashYul(lender).flashLoan(
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

contract ReentrantBorrower {
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    
    enum AttackType { DEPOSIT, WITHDRAW, FLASH_LOAN }
    AttackType public attackType;
    bool public attacked;
    
    function setAttackType(AttackType _type) external {
        attackType = _type;
    }
    
    function borrow(address payable lender, uint256 amount) external {
        ILIQFlashYul(lender).flashLoan(
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
        if (!attacked) {
            attacked = true;
            
            if (attackType == AttackType.DEPOSIT) {
                // Try to deposit borrowed funds (should fail - LOCKED)
                USDC.approve(msg.sender, amount);
                ILIQFlashYul(msg.sender).deposit(amount);
            } else if (attackType == AttackType.WITHDRAW) {
                // Try to withdraw (should fail - LOCKED)
                ILIQFlashYul(msg.sender).withdraw(amount);
            } else if (attackType == AttackType.FLASH_LOAN) {
                // Try nested flash loan (should fail - LOCKED)
                ILIQFlashYul(msg.sender).flashLoan(
                    address(this),
                    address(USDC),
                    amount,
                    ""
                );
            }
        }
        
        // Repay
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
        uint256 amount = 10_000e6;
        uint256 fee = ILIQFlashYul(address(lender)).flashFee(address(USDC), amount);
        assertEq(fee, 0, "Fee should be 0");
        
        borrower.borrow(payable(address(lender)), amount);
        
        console.log("[PASS] Flash loan completed (zero fee)");
    }
    
    function testGasBenchmark() public {
        uint256 amount = 10_000e6;
        
        // First call (cold)
        uint256 gasBefore = gasleft();
        borrower.borrow(payable(address(lender)), amount);
        uint256 gasCold = gasBefore - gasleft();
        
        // Second call (warm)
        gasBefore = gasleft();
        borrower.borrow(payable(address(lender)), amount);
        uint256 gasWarm = gasBefore - gasleft();
        
        console.log("=== YUL GAS BENCHMARK (NO FEE) ===");
        console.log("Flash loan (cold):", gasCold);
        console.log("Flash loan (warm):", gasWarm);
    }
    
    function testMaxFlashLoan() public view {
        uint256 max = ILIQFlashYul(address(lender)).maxFlashLoan(address(USDC));
        console.log("Max flash loan:", max);
        assertEq(max, 100_000e6);
    }
    
    function testMaxFlashLoanWrongToken() public view {
        address NOT_USDC = address(0x1234);
        uint256 max = ILIQFlashYul(address(lender)).maxFlashLoan(NOT_USDC);
        assertEq(max, 0, "Wrong token should return 0");
    }
    
    function testFlashFeeWrongToken() public {
        address NOT_USDC = address(0x1234);
        vm.expectRevert();
        ILIQFlashYul(address(lender)).flashFee(NOT_USDC, 1000e6);
    }
    
    function testFlashLoanWrongToken() public {
        address NOT_USDC = address(0x1234);
        vm.expectRevert();
        ILIQFlashYul(address(lender)).flashLoan(
            address(borrower),
            NOT_USDC,
            1000e6,
            ""
        );
    }
    
    function testReentrancyDeposit() public {
        ReentrantBorrower attacker = new ReentrantBorrower();
        attacker.setAttackType(ReentrantBorrower.AttackType.DEPOSIT);
        
        vm.expectRevert();
        attacker.borrow(payable(address(lender)), 10_000e6);
        
        // Verify poolBalance unchanged
        assertEq(lender.poolBalance(), 100_000e6, "poolBalance should be unchanged");
        console.log("[PASS] Reentrant deposit blocked");
    }
    
    function testReentrancyWithdraw() public {
        ReentrantBorrower attacker = new ReentrantBorrower();
        attacker.setAttackType(ReentrantBorrower.AttackType.WITHDRAW);
        
        vm.expectRevert();
        attacker.borrow(payable(address(lender)), 10_000e6);
        
        console.log("[PASS] Reentrant withdraw blocked");
    }
    
    function testReentrancyFlashLoan() public {
        ReentrantBorrower attacker = new ReentrantBorrower();
        attacker.setAttackType(ReentrantBorrower.AttackType.FLASH_LOAN);
        
        vm.expectRevert();
        attacker.borrow(payable(address(lender)), 10_000e6);
        
        console.log("[PASS] Nested flash loan blocked");
    }
}
