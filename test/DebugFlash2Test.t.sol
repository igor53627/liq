// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HuffDeployer} from "foundry-huff/HuffDeployer.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ILIQFlashUSDC {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external payable returns (bool);
    function flashFee(address token, uint256 amount) external view returns (uint256);
}

contract DebugBorrower {
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    
    event Callback(address initiator, address token, uint256 amount, uint256 fee);
    
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external returns (bytes32) {
        emit Callback(initiator, token, amount, fee);
        USDC.transfer(msg.sender, amount);
        return CALLBACK_SUCCESS;
    }
    
    function borrow(ILIQFlashUSDC liq, uint256 amount) external payable returns (bool) {
        return liq.flashLoan{value: msg.value}(address(this), address(USDC), amount, "");
    }
    
    receive() external payable {}
}

contract DebugFlash2Test is Test {
    ILIQFlashUSDC liq;
    DebugBorrower borrower;
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    
    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
        liq = ILIQFlashUSDC(HuffDeployer.deploy("LIQFlashUSDC"));
        borrower = new DebugBorrower();
        
        vm.prank(USDC_WHALE);
        USDC.transfer(address(liq), 100_000e6);
    }
    
    function testStepByStep() public {
        vm.txGasPrice(0.18 gwei);
        
        console.log("=== Step 1: Check balances ===");
        console.log("LIQ USDC balance:", USDC.balanceOf(address(liq)));
        console.log("Borrower USDC balance:", USDC.balanceOf(address(borrower)));
        
        console.log("=== Step 2: Check fee ===");
        uint256 fee = liq.flashFee(address(USDC), 10_000e6);
        console.log("Fee:", fee);
        
        console.log("=== Step 3: Try flash loan ===");
        try borrower.borrow(liq, 10_000e6) returns (bool success) {
            console.log("Borrow success:", success);
        } catch Error(string memory reason) {
            console.log("Borrow failed with reason:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("Borrow failed with low level data:");
            console.logBytes(lowLevelData);
        }
    }
}
