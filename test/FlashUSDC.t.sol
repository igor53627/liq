// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HuffDeployer} from "foundry-huff/HuffDeployer.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ILIQFlashUSDC {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external payable returns (bool);
    function maxFlashLoan(address token) external view returns (uint256);
    function flashFee(address token, uint256 amount) external view returns (uint256);
    function withdraw() external;
    function setTreasury(address treasury) external;
}

contract MockUSDCBorrower {
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    
    bool public shouldRepay = true;
    
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external returns (bytes32) {
        require(token == address(USDC), "wrong token");
        require(initiator == address(this), "wrong initiator");
        
        // Verify we received the USDC
        require(USDC.balanceOf(address(this)) >= amount, "didn't receive USDC");
        
        // Simulate arbitrage - we just return the USDC
        if (shouldRepay) {
            USDC.transfer(msg.sender, amount);
        }
        
        return CALLBACK_SUCCESS;
    }
    
    function borrow(ILIQFlashUSDC liq, uint256 amount) external payable returns (bool) {
        return liq.flashLoan{value: msg.value}(address(this), address(USDC), amount, "");
    }
    
    function setRepay(bool _repay) external {
        shouldRepay = _repay;
    }
    
    receive() external payable {}
}

contract FlashUSDCTest is Test {
    ILIQFlashUSDC liq;
    MockUSDCBorrower borrower;
    address treasury = address(0xBEEF);
    
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341; // Circle
    
    uint256 constant VAULT_BALANCE = 100_000e6; // 100k USDC
    
    function setUp() public {
        // Fork mainnet
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
        
        // Deploy LIQFlashUSDC
        liq = ILIQFlashUSDC(HuffDeployer.deploy("LIQFlashUSDC"));
        borrower = new MockUSDCBorrower();
        
        // Set treasury
        liq.setTreasury(treasury);
        
        // Fund the vault with USDC from whale
        vm.prank(USDC_WHALE);
        USDC.transfer(address(liq), VAULT_BALANCE);
    }
    
    function testMaxFlashLoan() public view {
        uint256 max = liq.maxFlashLoan(address(USDC));
        assertEq(max, VAULT_BALANCE, "Max should be vault balance");
    }
    
    function testMaxFlashLoanWrongToken() public view {
        uint256 max = liq.maxFlashLoan(address(0xDEAD));
        assertEq(max, 0, "Wrong token should return 0");
    }
    
    function testFlashFeeAtLowGas() public {
        // At 0.18 gwei (below 5 gwei threshold), fee should be 0
        vm.txGasPrice(0.18 gwei);
        uint256 fee = liq.flashFee(address(USDC), 10_000e6);
        assertEq(fee, 0, "Fee should be 0 at low gas");
    }
    
    function testFlashFeeAt10Gwei() public {
        vm.txGasPrice(10 gwei);
        uint256 fee = liq.flashFee(address(USDC), 10_000e6);
        // (10 gwei - 5 gwei) * MAX_FEE / 15 gwei = 5/15 * MAX_FEE = 0.33 * MAX_FEE
        uint256 maxFee = 333333333333333; // 0x12F2A36ECD555 = ~$1 at $3k ETH
        uint256 expected = maxFee / 3; // 5/15 = 1/3 of max
        assertApproxEqRel(fee, expected, 0.01e18, "Fee should be ~33% of max");
    }
    
    function testFlashFeeAt20Gwei() public {
        vm.txGasPrice(20 gwei);
        uint256 fee = liq.flashFee(address(USDC), 10_000e6);
        uint256 maxFee = 333333333333333;
        assertEq(fee, maxFee, "Fee should be max at 20 gwei");
    }
    
    function testFlashFeeAt100Gwei() public {
        vm.txGasPrice(100 gwei);
        uint256 fee = liq.flashFee(address(USDC), 10_000e6);
        uint256 maxFee = 333333333333333;
        assertEq(fee, maxFee, "Fee should be capped at max");
    }
    
    function testBasicFlashLoan() public {
        vm.txGasPrice(0.18 gwei); // Free tier
        
        uint256 vaultBefore = USDC.balanceOf(address(liq));
        
        borrower.borrow(liq, 10_000e6);
        
        uint256 vaultAfter = USDC.balanceOf(address(liq));
        assertEq(vaultAfter, vaultBefore, "Vault should have same balance after repay");
    }
    
    function testFlashLoanWithFee() public {
        vm.txGasPrice(20 gwei); // Max fee tier
        
        uint256 fee = liq.flashFee(address(USDC), 10_000e6);
        vm.deal(address(borrower), fee);
        
        uint256 treasuryBefore = treasury.balance;
        
        borrower.borrow{value: fee}(liq, 10_000e6);
        
        uint256 treasuryAfter = treasury.balance;
        assertEq(treasuryAfter - treasuryBefore, fee, "Treasury should receive fee");
    }
    
    function testRevertNotRepaid() public {
        vm.txGasPrice(0.18 gwei);
        
        borrower.setRepay(false);
        vm.expectRevert();
        borrower.borrow(liq, 10_000e6);
    }
    
    function testRevertInsufficientFee() public {
        vm.txGasPrice(20 gwei);
        
        // Send less than required fee
        vm.deal(address(borrower), 0.0001 ether);
        vm.expectRevert();
        borrower.borrow{value: 0.0001 ether}(liq, 10_000e6);
    }
    
    function testExcessFeeRefund() public {
        vm.txGasPrice(10 gwei);
        
        uint256 fee = liq.flashFee(address(USDC), 10_000e6);
        uint256 excess = 0.01 ether;
        vm.deal(address(borrower), fee + excess);
        
        uint256 borrowerBefore = address(borrower).balance;
        
        borrower.borrow{value: fee + excess}(liq, 10_000e6);
        
        uint256 borrowerAfter = address(borrower).balance;
        assertApproxEqAbs(borrowerAfter, excess, 1000, "Excess should be refunded");
    }
    
    function testGasUsage() public {
        vm.txGasPrice(0.18 gwei); // Free tier for cleaner measurement
        
        // Warm up
        borrower.borrow(liq, 10_000e6);
        
        uint256 g1 = gasleft();
        borrower.borrow(liq, 10_000e6);
        uint256 gasUsed = g1 - gasleft();
        
        console.log("=========================================");
        console.log("  LIQFlashUSDC Gas Report");
        console.log("=========================================");
        console.log("");
        console.log("Warm flash loan gas:", gasUsed);
        console.log("");
        console.log("Breakdown estimate:");
        console.log("  - USDC.transfer (optimistic):", "~30,000");
        console.log("  - Callback overhead:         ", "~5,000");
        console.log("  - USDC.balanceOf check:      ", "~2,600");
        console.log("  - Fee calc + handling:       ", "~3,000");
        console.log("");
        console.log("vs Balancer V2 minimum:         71,527");
        console.log("Savings:                       ", 71527 > gasUsed ? 71527 - gasUsed : 0, "gas");
    }
    
    function testGasUsageWithFee() public {
        vm.txGasPrice(20 gwei);
        
        uint256 fee = liq.flashFee(address(USDC), 10_000e6);
        vm.deal(address(borrower), fee * 3);
        
        // Warm up
        borrower.borrow{value: fee}(liq, 10_000e6);
        
        uint256 g1 = gasleft();
        borrower.borrow{value: fee}(liq, 10_000e6);
        uint256 gasUsed = g1 - gasleft();
        
        console.log("=========================================");
        console.log("  LIQFlashUSDC Gas Report (with ETH fee)");
        console.log("=========================================");
        console.log("");
        console.log("Warm flash loan gas:", gasUsed);
        console.log("ETH fee paid:       ", fee);
    }
    
    function testWithdraw() public {
        uint256 balBefore = USDC.balanceOf(address(this));
        
        liq.withdraw();
        
        uint256 balAfter = USDC.balanceOf(address(this));
        assertEq(balAfter - balBefore, VAULT_BALANCE, "Should withdraw all USDC");
    }
}

// ============================================
// Break-even Analysis vs AAVE
// ============================================
contract BreakEvenAnalysis is Test {
    
    function testBreakEvenVsAAVE() public pure {
        // AAVE USDC Supply APY: 3.07%
        uint256 capital = 10_000; // $10k USDC
        uint256 aaveAPY = 307; // 3.07% in basis points
        
        uint256 aaveYearlyYield = capital * aaveAPY / 10000; // $307/year
        
        console.log("=========================================");
        console.log("  LIQFlashUSDC vs AAVE Break-Even");
        console.log("=========================================");
        console.log("");
        console.log("Capital:           $", capital);
        console.log("AAVE USDC APY:     3.07%");
        console.log("AAVE yearly yield: $", aaveYearlyYield);
        console.log("");
        
        // Fee scenarios
        uint256 maxFee = 1; // $1 at 20+ gwei
        uint256 midFee = 50; // $0.50 at ~10 gwei (in cents)
        uint256 lowFee = 10; // $0.10 at ~6 gwei (in cents)
        
        console.log("Break-even loans per year to match AAVE:");
        console.log("");
        console.log("  At $1.00/loan (20+ gwei):", aaveYearlyYield / maxFee, "loans/year");
        console.log("  At $0.50/loan (10 gwei): ", aaveYearlyYield * 100 / midFee, "loans/year");
        console.log("  At $0.10/loan (6 gwei):  ", aaveYearlyYield * 100 / lowFee, "loans/year");
        console.log("");
        console.log("Daily loan targets:");
        console.log("");
        console.log("  At $1.00/loan:", aaveYearlyYield / maxFee / 365, "loans/day");
        console.log("  At $0.50/loan:", aaveYearlyYield * 100 / midFee / 365, "loans/day");
        console.log("  At $0.10/loan:", aaveYearlyYield * 100 / lowFee / 365, "loans/day");
        console.log("");
        console.log("=========================================");
        console.log("  Historical Balancer Flash Loan Volume");
        console.log("=========================================");
        console.log("");
        console.log("From blocks 19M-21M (Balancer V2 data):");
        console.log("  - USDC flash loans: 10,437 events");
        console.log("  - Block range: ~2M blocks (~167 days)");
        console.log("  - Average: ~62 USDC flash loans/day");
        console.log("");
        console.log("If LIQ captures 10% of Balancer USDC volume:");
        console.log("  - ~6 loans/day");
        console.log("  - At $0.50 avg fee: $3/day = $1,095/year");
        console.log("  - ROI on $10k: 10.95%");
        console.log("");
        console.log("If LIQ captures 50% of volume:");
        console.log("  - ~31 loans/day");
        console.log("  - At $0.50 avg fee: $15.50/day = $5,657/year");
        console.log("  - ROI on $10k: 56.57%");
    }
}
