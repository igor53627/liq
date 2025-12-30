// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract RawDeployTest is Test {
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    
    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
    }
    
    function testRawBytecode() public {
        // Bytecode from huffc
        bytes memory initCode = hex"325f55326001556104078060113d393df35f3560e01c80635cffe9de1461003e578063613255ab1461025b578063d9d98ce4146102d05780633ccfd60b146103405763f0f44260146103e2575f5ffd5b5060243573a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4814156103f3577f70a08231000000000000000000000000000000000000000000000000000000005f523060045260205f60245f73a0b86991c6218b36c1d19d4a2e9eb0ce3606eb485afa15610403575f516044357fa9059cbb000000000000000000000000000000000000000000000000000000005f52600435600452806024525f5f60445f73a0b86991c6218b36c1d19d4a2e9eb0ce3606eb485af115610403573a64012a05f20081106101405764012a05f200900366012f2a36ecd5550264037e11d600900466012f2a36ecd555811161013257610143565b5066012f2a36ecd555610143565b505f5b6323e30c8b60e01b6080523360845273a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4860a4528160c4528060e45260a0610104526064356004018035806101245290602001610144376064356004013560c40160205f8260805f6004355af11561040357505f517f439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd914156103f7577f70a08231000000000000000000000000000000000000000000000000000000005f523060045260205f60245f73a0b86991c6218b36c1d19d4a2e9eb0ce3606eb485afa15610403575f5190919281106103fb57505090508034106103ff57600154905f5f5f5f84855af1503490038015610251575f5f5f5f84335af1505b5060015f5260205ff35b5060043573a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4814156102c8577f70a08231000000000000000000000000000000000000000000000000000000005f523060045260205f60245f73a0b86991c6218b36c1d19d4a2e9eb0ce3606eb485afa156102c85760205ff35b5f5f5260205ff35b5060043573a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4814156103f3573a64012a05f20081106103365764012a05f200900366012f2a36ecd5550264037e11d600900466012f2a36ecd555811161032857610339565b5066012f2a36ecd555610339565b505f5b5f5260205ff35b505f54321415610403577f70a08231000000000000000000000000000000000000000000000000000000005f523060045260205f60245f73a0b86991c6218b36c1d19d4a2e9eb0ce3606eb485afa15610403575f517fa9059cbb000000000000000000000000000000000000000000000000000000005f52336004526024525f5f60445f73a0b86991c6218b36c1d19d4a2e9eb0ce3606eb485af11561040357005b5f5432141561040357600435600155005b5f5ffd5b5f5ffd5b5f5ffd5b5f5ffd5b5f5ffd";
        
        // Deploy
        address liq;
        assembly {
            liq := create(0, add(initCode, 32), mload(initCode))
        }
        require(liq != address(0), "deployment failed");
        console.log("Deployed at:", liq);
        console.log("Code size:", liq.code.length);
        
        // Fund it
        vm.prank(USDC_WHALE);
        USDC.transfer(liq, 100_000e6);
        console.log("LIQ balance:", USDC.balanceOf(liq));
        
        // Check flashFee
        vm.txGasPrice(0.18 gwei);
        (bool success, bytes memory result) = liq.staticcall(
            abi.encodeWithSelector(bytes4(0xd9d98ce4), address(USDC), uint256(1000e6))
        );
        console.log("flashFee success:", success);
        if (success) {
            console.log("Fee:", abi.decode(result, (uint256)));
        }
        
        // Try flashLoan
        bytes memory flashData = abi.encodeWithSelector(
            bytes4(0x5cffe9de),
            address(this),
            address(USDC),
            uint256(1000e6),
            bytes("")
        );
        
        console.log("Trying flashLoan...");
        (success, result) = liq.call(flashData);
        console.log("flashLoan success:", success);
        if (!success && result.length > 0) {
            console.logBytes(result);
        }
    }
}
