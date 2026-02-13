// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";
import {KanaVault} from "../src/KanaVault.sol";

contract UpgradeStrategy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        
        // Existing vault
        address vault = 0x14410FF2a124D0669C6e8Adfe3695F25C92a6d03;
        
        // SEI mainnet addresses
        address usdc = 0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392;
        address takaraCUSDC = 0xd1E6a6F58A29F64ab2365947ACb53EfEB6Cc05e0;
        address takaraComptroller = 0x56A171Acb1bBa46D4fdF21AfBE89377574B8D9BD;
        address dragonSwapRouter = 0xa4cF2F53D1195aDDdE9e4D3aCa54f556895712f2;

        console.log("=== STRATEGY UPGRADE ===");
        console.log("Deployer:", deployer);
        console.log("Vault:", vault);

        vm.startBroadcast(deployerKey);

        // Deploy new strategy with same params
        USDCStrategy newStrategy = new USDCStrategy(
            USDCStrategy.ProtocolAddresses({
                usdc: usdc,
                vault: vault,
                yeiPool: address(0),
                aToken: address(0),
                cToken: takaraCUSDC,
                comptroller: takaraComptroller,
                morpho: address(0),
                routerV2: dragonSwapRouter,
                routerV3: address(0)
            }),
            0,      // splitYei
            10000,  // splitTakara (100%)
            0,      // splitMorpho
            4,      // morphoMaxIterations
            500,    // maxSlippageBps (5%)
            3600,   // rebalanceCooldown (1h)
            3600    // splitsCooldown (1h)
        );

        console.log("New USDCStrategy:", address(newStrategy));

        // Set keeper on new strategy
        newStrategy.setKeeper(deployer);
        
        // Set new strategy on vault (this will withdraw from old and deposit to new)
        KanaVault(vault).setStrategy(newStrategy);

        console.log("Strategy upgraded!");

        vm.stopBroadcast();
    }
}
