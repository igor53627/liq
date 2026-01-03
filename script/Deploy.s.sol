// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/LIQFlashYul.sol";

/// @title LIQFlashYul Deployment Script
/// @notice Deploys LIQFlashYul with mainnet safety checks
/// @dev Usage:
///   Dry run:    forge script script/Deploy.s.sol --rpc-url $RPC_URL
///   Simulate:   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --dry-run
///   Deploy:     forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
///   Verify:     forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
contract DeployLIQFlash is Script {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    
    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        
        console.log("============================================================");
        console.log("LIQFlashYul Deployment");
        console.log("============================================================");
        console.log("");
        console.log("Chain ID:    ", block.chainid);
        console.log("Deployer:    ", deployer);
        console.log("USDC:        ", USDC);
        console.log("");
        
        // Mainnet confirmation
        if (block.chainid == 1) {
            console.log("[!] MAINNET DEPLOYMENT");
            console.log("    Contract will be owned by deployer");
            console.log("    Use transferOwnership() to transfer to multisig");
            console.log("");
        }
        
        // Check deployer balance
        uint256 balance = deployer.balance;
        console.log("ETH Balance (wei):", balance);
        require(balance >= 0.01 ether, "Insufficient ETH for deployment");
        
        vm.startBroadcast(deployerKey);
        
        // Deploy contract
        LIQFlashYul liq = new LIQFlashYul();
        
        vm.stopBroadcast();
        
        // Verification
        console.log("");
        console.log("============================================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("============================================================");
        console.log("");
        console.log("LIQFlashYul:  ", address(liq));
        console.log("Owner:        ", liq.owner());
        console.log("Pool Balance: ", liq.poolBalance());
        console.log("");
        console.log("POST-DEPLOYMENT STEPS:");
        console.log("1. Verify contract on Etherscan:");
        console.log("   forge verify-contract", address(liq), "src/LIQFlashYul.sol:LIQFlashYul --chain mainnet");
        console.log("");
        console.log("2. Fund the contract via deposit():");
        console.log("   - Approve USDC first");
        console.log("   - Call deposit(amount)");
        console.log("");
        console.log("3. Update webapp/index.html with LIQ_ADDRESS:");
        console.log("   const LIQ_ADDRESS = '", address(liq), "';");
        console.log("");
        console.log("4. Optional: Transfer ownership to multisig");
        console.log("   liq.transferOwnership(SAFE_ADDRESS)");
    }
}
