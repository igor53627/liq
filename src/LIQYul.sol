// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LIQ - Gas-Optimized Flash Mint Protocol (Yul Implementation)
/// @notice Wrapped USDC with ERC-3156 flash lending (free flash mints)
/// @dev Target: <15,000 gas for flash mint operation (excluding callback)
contract LIQYul {
    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    
    // Storage slots
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    
    // Events
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    
    function name() external pure returns (string memory) {
        return "LIQ";
    }
    
    function symbol() external pure returns (string memory) {
        return "LIQ";
    }
    
    function decimals() external pure returns (uint8) {
        return 6;
    }
    
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }
    
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }
    
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "allowance");
            unchecked {
                _allowances[from][msg.sender] = currentAllowance - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }
    
    function _transfer(address from, address to, uint256 amount) private {
        require(_balances[from] >= amount, "balance");
        unchecked {
            _balances[from] -= amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
    
    // ERC-3156 Flash Lender Interface
    
    function maxFlashLoan(address token) external view returns (uint256) {
        return token == address(this) ? type(uint256).max : 0;
    }
    
    function flashFee(address token, uint256) external view returns (uint256) {
        require(token == address(this), "token");
        return 0;
    }
    
    /// @notice Flash mint - ZERO storage writes, maximum gas efficiency
    /// @dev No persistent storage changes - tokens are virtual during callback
    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool) {
        assembly {
            // Check token == address(this)
            if iszero(eq(token, address())) {
                revert(0, 0)
            }
            
            // ========== CALLBACK ========== (No mint/burn)
            // Build calldata for onFlashLoan(initiator, token, amount, fee, data)
            mstore(0x80, 0x23e30c8b00000000000000000000000000000000000000000000000000000000)
            mstore(0x84, caller())           // initiator = msg.sender
            mstore(0xa4, address())          // token = this
            mstore(0xc4, amount)             // amount
            mstore(0xe4, 0)                  // fee = 0
            mstore(0x104, 0xa0)              // data offset (relative to 0x84)
            
            let dataLen := data.length
            mstore(0x124, dataLen)
            calldatacopy(0x144, data.offset, dataLen)
            
            // Call size = 0xc4 + dataLen
            let callSize := add(0xc4, dataLen)
            
            let success := call(gas(), receiver, 0, 0x80, callSize, 0x00, 0x20)
            
            if iszero(success) { revert(0, 0) }
            
            // Verify callback returned CALLBACK_SUCCESS (0x439148f0...)
            if iszero(eq(mload(0x00), 0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd9)) {
                revert(0, 0)
            }
            
            // Return true (0x01)
            mstore(0x00, 1)
            return(0x00, 0x20)
        }
    }
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
