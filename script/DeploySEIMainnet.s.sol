// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {SEIVault} from "../src/SEIVault.sol";
import {SEIStrategy} from "../src/SEIStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeploySEIMainnet is Script {
    // SEI Mainnet Addresses
    address constant WSEI = 0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7;

    // TODO: Fill in after on-chain research
    address constant YEI_POOL         = address(0); // TODO: Yei WSEI pool address
    address constant YEI_AWSEI        = address(0); // TODO: aWSEI (Yei receipt token)
    address constant TAKARA_CWSEI     = address(0); // TODO: cWSEI (Takara cToken)
    address constant TAKARA_COMPTROLLER = address(0); // TODO: Takara Comptroller
    address constant MORPHO           = address(0); // TODO: Morpho market for WSEI

    // DEX Routers (same as USDC vault)
    address constant DRAGONSWAP_ROUTER = 0xa4cF2F53D1195aDDdE9e4D3aCa54f556895712f2;
    address constant SAILOR_ROUTER     = 0xd1EFe48B71Acd98Db16FcB9E7152B086647Ef544;

    SEIVault public vault;
    SEIStrategy public strategy;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== KANA SEI VAULT MAINNET DEPLOYMENT ===");
        console.log("Deployer:", deployer);
        require(block.chainid == 1329, "Not on SEI mainnet!");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy SEIVault (10% fee hardcoded)
        vault = new SEIVault(IERC20(WSEI), deployer);
        console.log("SEIVault:", address(vault));

        // 2. Deploy SEIStrategy
        SEIStrategy.ProtocolAddresses memory addrs = SEIStrategy.ProtocolAddresses({
            wsei: WSEI,
            vault: address(vault),
            yeiPool: YEI_POOL,
            aToken: YEI_AWSEI,
            cToken: TAKARA_CWSEI,
            comptroller: TAKARA_COMPTROLLER,
            morpho: MORPHO,
            routerV2: DRAGONSWAP_ROUTER,
            routerV3: SAILOR_ROUTER
        });

        strategy = new SEIStrategy(
            addrs,
            0,      // 0% Yei (TODO: enable once pool address is confirmed)
            10000,  // 100% Takara initially (TODO: adjust once cWSEI confirmed)
            0,      // 0% Morpho (TODO: enable once market confirmed)
            4,      // Morpho max iterations
            500,    // 5% max slippage cap
            3600,   // 1 hour rebalance cooldown
            3600    // 1 hour splits cooldown
        );
        console.log("SEIStrategy:", address(strategy));

        // 3. Connect vault <-> strategy
        vault.setStrategy(strategy);

        // 4. Set keeper (deployer for now, change to bot wallet later)
        vault.setKeeper(deployer);
        strategy.setKeeper(deployer);

        // 5. First deposit — 0.001 WSEI (1e15) to prevent inflation attack
        uint256 seedAmount = 1e15; // 0.001 WSEI
        IERC20(WSEI).approve(address(vault), seedAmount);
        vault.deposit(seedAmount, deployer);
        console.log("Seed deposit: 0.001 WSEI");

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Vault:", address(vault));
        console.log("Strategy:", address(strategy));
        console.log("Fee: 10% (constant)");
        console.log("Max Slippage Cap: 5%");
        console.log("Rebalance Cooldown: 1 hour");
        console.log("Initial Allocation: 100% Takara (pending address confirmation)");
    }
}
