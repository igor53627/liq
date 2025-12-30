// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC3156FlashBorrower {
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data) external returns (bytes32);
}

contract SimpleLIQFlash {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    
    address public owner;
    address public treasury;
    
    constructor() {
        owner = tx.origin;
        treasury = tx.origin;
    }
    
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external payable returns (bool) {
        require(token == USDC, "wrong token");
        
        uint256 initialBalance = IERC20(USDC).balanceOf(address(this));
        
        IERC20(USDC).transfer(receiver, amount);
        
        uint256 fee = 0; // simplified
        
        bytes32 result = IERC3156FlashBorrower(receiver).onFlashLoan(msg.sender, token, amount, fee, data);
        require(result == CALLBACK_SUCCESS, "callback failed");
        
        require(IERC20(USDC).balanceOf(address(this)) >= initialBalance, "not repaid");
        
        return true;
    }
    
    function setTreasury(address _treasury) external {
        require(tx.origin == owner, "not owner");
        treasury = _treasury;
    }
}

contract SimpleBorrower {
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata) external returns (bytes32) {
        USDC.transfer(msg.sender, amount);
        return CALLBACK_SUCCESS;
    }
    
    function borrow(SimpleLIQFlash liq, uint256 amount) external returns (bool) {
        return liq.flashLoan(address(this), address(USDC), amount, "");
    }
    
    receive() external payable {}
}

contract SolVersionTest is Test {
    SimpleLIQFlash liq;
    SimpleBorrower borrower;
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    
    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
        liq = new SimpleLIQFlash();
        borrower = new SimpleBorrower();
        
        vm.prank(USDC_WHALE);
        USDC.transfer(address(liq), 100_000e6);
    }
    
    function testSolFlashLoan() public {
        uint256 balBefore = USDC.balanceOf(address(liq));
        
        borrower.borrow(liq, 10_000e6);
        
        uint256 balAfter = USDC.balanceOf(address(liq));
        assertEq(balAfter, balBefore, "Balance should be same after repay");
        console.log("Solidity version works!");
    }
}
