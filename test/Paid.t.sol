// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HuffDeployer} from "foundry-huff/HuffDeployer.sol";

interface ILIQPaid {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
    function maxFlashLoan(address token) external view returns (uint256);
    function flashFee(address token, uint256 amount) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function setTreasury(address treasury) external;
}

contract MockPaidBorrower {
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    
    function onFlashLoan(
        address,
        address,
        uint256,
        uint256 fee,
        bytes calldata
    ) external pure returns (bytes32) {
        require(fee == 1e6, "unexpected fee");
        return CALLBACK_SUCCESS;
    }
    
    function borrow(ILIQPaid liq, uint256 amount) external returns (bool) {
        return liq.flashLoan(address(this), address(liq), amount, "");
    }
}

contract PaidTest is Test {
    ILIQPaid liq;
    MockPaidBorrower borrower;
    address treasury = address(0xBEEF);
    
    // Storage slot for balances (slot 0, mapping)
    function balanceSlot(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, uint256(0)));
    }
    
    function setUp() public {
        liq = ILIQPaid(HuffDeployer.deploy("LIQFlashPaid"));
        borrower = new MockPaidBorrower();
        
        // Set treasury
        liq.setTreasury(treasury);
        
        // Give borrower 10 LIQ balance (direct storage write)
        vm.store(address(liq), balanceSlot(address(borrower)), bytes32(uint256(10e6)));
    }
    
    function testFlashFeeReturns1LIQ() public view {
        uint256 fee = liq.flashFee(address(liq), 1e18);
        assertEq(fee, 1e6, "Fee should be 1 LIQ");
    }
    
    function testBorrowerHasBalance() public view {
        uint256 bal = liq.balanceOf(address(borrower));
        assertEq(bal, 10e6, "Borrower should have 10 LIQ");
    }
    
    function testFlashLoanChargesFee() public {
        uint256 borrowerBefore = liq.balanceOf(address(borrower));
        uint256 treasuryBefore = liq.balanceOf(treasury);
        
        borrower.borrow(liq, 1e18);
        
        uint256 borrowerAfter = liq.balanceOf(address(borrower));
        uint256 treasuryAfter = liq.balanceOf(treasury);
        
        assertEq(borrowerBefore - borrowerAfter, 1e6, "Borrower should pay 1 LIQ");
        assertEq(treasuryAfter - treasuryBefore, 1e6, "Treasury should receive 1 LIQ");
    }
    
    function testMultipleFlashLoans() public {
        borrower.borrow(liq, 1e18);
        borrower.borrow(liq, 1e18);
        borrower.borrow(liq, 1e18);
        
        assertEq(liq.balanceOf(address(borrower)), 7e6, "3 loans = 3 LIQ fee");
        assertEq(liq.balanceOf(treasury), 3e6, "Treasury got 3 LIQ");
    }
    
    function testRevertInsufficientBalance() public {
        // Give borrower only 0.5 LIQ
        vm.store(address(liq), balanceSlot(address(borrower)), bytes32(uint256(0.5e6)));
        vm.expectRevert();
        borrower.borrow(liq, 1e18);
    }
    
    function testGasWithFee() public {
        // Warm up
        borrower.borrow(liq, 1e18);
        
        uint256 g1 = gasleft();
        borrower.borrow(liq, 1e18);
        uint256 gasUsed = g1 - gasleft();
        
        console.log("=== Flash Loan with 1 LIQ Fee ===");
        console.log("Warm gas with fee:", gasUsed);
        console.log("");
        console.log("Breakdown:");
        console.log("  - Free flash (V2): 5,166 gas");
        console.log("  - Fee overhead:   ", gasUsed - 5166, "gas");
        console.log("");
        console.log("Fee overhead = 2x SSTORE (warm) + 1x log3 + hashing");
    }
}
