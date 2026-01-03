// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
}

interface IFlashLender {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
}

/// @title TestBorrower
/// @notice Simple flash loan borrower for testing - borrows and repays immediately
contract TestBorrower {
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    
    /// @notice Tracks the expected lender during a flash loan to prevent unauthorized callbacks
    address private expectedLender;
    
    event FlashLoanExecuted(address lender, uint256 amount);
    
    /// @notice Borrow with event (for testing/debugging)
    function borrow(address lender, uint256 amount) external {
        expectedLender = lender;
        IFlashLender(lender).flashLoan(address(this), USDC, amount, "");
        expectedLender = address(0);
        emit FlashLoanExecuted(lender, amount);
    }
    
    /// @notice Borrow without event (gas optimized for production)
    function borrowSilent(address lender, uint256 amount) external {
        expectedLender = lender;
        IFlashLender(lender).flashLoan(address(this), USDC, amount, "");
        expectedLender = address(0);
    }
    
    function onFlashLoan(
        address,
        address,
        uint256 amount,
        uint256,
        bytes calldata
    ) external returns (bytes32) {
        require(msg.sender == expectedLender, "unauthorized callback");
        bool success = IERC20(USDC).transfer(msg.sender, amount);
        require(success, "transfer failed");
        return CALLBACK_SUCCESS;
    }
}
