// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LIQFlashUSDCAsm - Pure Assembly Flash Loans
/// @notice Gas-optimized USDC flash loans with scaled ETH fee
contract LIQFlashUSDCAsm {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    bytes32 constant CALLBACK_SUCCESS = 0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd9;
    uint256 constant MIN_GAS_PRICE = 5 gwei;
    uint256 constant GAS_RANGE = 15 gwei;
    uint256 constant MAX_FEE_WEI = 333333333333333; // ~$1 at $3k ETH
    
    address public owner;
    address public treasury;
    uint256 public poolBalance;
    
    event Deposit(address indexed from, uint256 amount);
    event Withdraw(address indexed to, uint256 amount);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "!owner");
        _;
    }
    
    constructor() {
        owner = msg.sender;
        treasury = msg.sender;
    }
    
    /// @notice Deposit USDC into the pool (requires prior approval)
    function deposit(uint256 amount) external {
        IERC20Full(USDC).transferFrom(msg.sender, address(this), amount);
        poolBalance += amount;
        emit Deposit(msg.sender, amount);
    }
    
    /// @notice Withdraw USDC from the pool (owner only)
    function withdraw(uint256 amount) external onlyOwner {
        poolBalance -= amount;
        IERC20(USDC).transfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }
    
    /// @notice Withdraw all USDC (owner only)
    function withdrawAll() external onlyOwner {
        uint256 bal = poolBalance;
        poolBalance = 0;
        IERC20(USDC).transfer(msg.sender, bal);
        emit Withdraw(msg.sender, bal);
    }
    
    /// @notice Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "!zero");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    /// @notice Set treasury address for fee collection
    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }
    
    /// @notice Execute flash loan - HOT PATH, maximally optimized
    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external payable returns (bool) {
        require(token == USDC, "!USDC");
        
        // Cache expected balance from storage (avoids ~7k gas balanceOf call)
        uint256 expectedBalance = poolBalance;
        
        // Transfer amount to receiver (use 0x100 scratch space to avoid conflicts)
        assembly {
            mstore(0x100, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(0x104, receiver)
            mstore(0x124, amount)
            if iszero(call(gas(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0, 0x100, 0x44, 0x100, 0x20)) {
                revert(0, 0)
            }
        }
        
        // Inline fee calculation (saves function call overhead)
        uint256 fee;
        {
            uint256 gp = tx.gasprice;
            if (gp <= MIN_GAS_PRICE) {
                fee = 0;
            } else {
                fee = ((gp - MIN_GAS_PRICE) * MAX_FEE_WEI) / GAS_RANGE;
                if (fee > MAX_FEE_WEI) fee = MAX_FEE_WEI;
            }
        }
        
        // Call onFlashLoan(address,address,uint256,uint256,bytes) in assembly
        // Selector: 0x23e30c8b
        bytes32 result;
        assembly {
            let ptr := mload(0x40)  // Free memory pointer
            mstore(ptr, 0x23e30c8b00000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), caller())           // initiator = msg.sender
            mstore(add(ptr, 0x24), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)  // token = USDC
            mstore(add(ptr, 0x44), amount)             // amount
            mstore(add(ptr, 0x64), fee)                // fee
            mstore(add(ptr, 0x84), 0xa0)               // offset to data (160 bytes from start of args)
            mstore(add(ptr, 0xa4), data.length)        // data length
            calldatacopy(add(ptr, 0xc4), data.offset, data.length)  // data bytes
            
            let dataLen := add(0xc4, data.length)      // Total calldata size
            if iszero(call(gas(), receiver, 0, ptr, dataLen, ptr, 0x20)) {
                revert(0, 0)
            }
            result := mload(ptr)
        }
        require(result == CALLBACK_SUCCESS, "!callback");
        
        // Single balance check - must have at least what we started with
        uint256 finalBalance;
        assembly {
            mstore(0x100, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(0x104, address())
            if iszero(staticcall(gas(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0x100, 0x24, 0x100, 0x20)) {
                revert(0, 0)
            }
            finalBalance := mload(0x100)
        }
        
        require(finalBalance >= expectedBalance, "!repaid");
        require(msg.value >= fee, "!fee");
        
        // Use assembly call for ETH transfers (no 2300 gas stipend limit)
        assembly {
            if gt(fee, 0) {
                let success := call(gas(), sload(treasury.slot), fee, 0, 0, 0, 0)
                if iszero(success) { revert(0, 0) }
            }
            let refund := sub(callvalue(), fee)
            if gt(refund, 0) {
                let success := call(gas(), caller(), refund, 0, 0, 0, 0)
                if iszero(success) { revert(0, 0) }
            }
        }
        
        return true;
    }
    
    function maxFlashLoan(address token) external view returns (uint256) {
        if (token != USDC) return 0;
        return poolBalance;
    }
    
    function flashFee(address token, uint256) external view returns (uint256) {
        require(token == USDC, "!USDC");
        return _calculateFee();
    }
    
    function _calculateFee() internal view returns (uint256) {
        uint256 gp = tx.gasprice;
        if (gp <= MIN_GAS_PRICE) return 0;
        uint256 fee = ((gp - MIN_GAS_PRICE) * MAX_FEE_WEI) / GAS_RANGE;
        return fee > MAX_FEE_WEI ? MAX_FEE_WEI : fee;
    }
    
    /// @notice Rescue ETH stuck in contract
    function rescueETH() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }
    
    receive() external payable {}
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IERC20Full {
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IERC3156FlashBorrower {
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32);
}
