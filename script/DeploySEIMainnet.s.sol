// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {SEIVault} from "../src/SEIVault.sol";
import {SEIStrategy} from "../src/SEIStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeploySEIMainnet is Script {
    // SEI Mainnet Addresses — all verified on-chain
    address constant WSEI               = 0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7;
    address constant YEI_POOL           = 0x4a4d9abD36F923cBA0Af62A39C01dEC2944fb638; // Yei lending pool (shared across all assets)
    address constant YEI_AWSEI          = 0x809FF4801aA5bDb33045d1fEC810D082490D63a4; // aWSEI receipt token (slot[8] of getReserveData)
    address constant TAKARA_CWSEI       = 0xA26b9BFe606d29F16B5Aecf30F9233934452c4E2; // cWSEI (verified via getAllMarkets + underlying())
    address constant TAKARA_COMPTROLLER = 0x71034bf5eC0FAd7aEE81a213403c8892F3d8CAeE; // real comptroller (from cUSDC.comptroller())
    address constant FEATHER_WSEI_VAULT = 0x948FcC6b7f68f4830Cd69dB1481a9e1A142A4923; // Feather MetaMorpho WSEI vault (~5.67M WSEI TVL)

    // DEX Routers (same as USDC vault)
    address constant DRAGONSWAP_ROUTER = 0xa4cF2F53D1195aDDdE9e4D3aCa54f556895712f2;
    address constant SAILOR_ROUTER     = 0xd1EFe48B71Acd98Db16FcB9E7152B086647Ef544;

    SEIVault public vault;
    SEIStrategy public strategy;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");

        console.log("=== KANA SEI VAULT MAINNET DEPLOYMENT ===");
        console.log("Deployer:", deployer);
        console.log("Guardian:", guardian);
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
            morpho: FEATHER_WSEI_VAULT,
            routerV2: DRAGONSWAP_ROUTER,
            routerV3: SAILOR_ROUTER
        });

        strategy = new SEIStrategy(
            addrs,
            0,      // 0% Yei (enable by calling setSplits after deployment)
            10000,  // 100% Takara initially — adjust via setSplits once live
            0,      // 0% Feather/Morpho (enable by calling setSplits after deployment)
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

        // 5. Set guardian (pause-only role)
        vault.setGuardian(guardian);
        strategy.setGuardian(guardian);

        // 6. First deposit — 0.001 WSEI (1e15) to seed the vault and prevent inflation attack
        uint256 seedAmount = 1e15; // 0.001 WSEI
        IERC20(WSEI).approve(address(vault), seedAmount);
        vault.deposit(seedAmount, deployer);
        console.log("Seed deposit: 0.001 WSEI");

        vm.stopBroadcast();

        // ─── Post-Deploy Verification ───────────────────────────────────────────
        require(address(vault.strategy()) == address(strategy), "VERIFY: vault.strategy mismatch");
        require(vault.keeper() == deployer, "VERIFY: vault.keeper mismatch");
        require(vault.guardian() == guardian, "VERIFY: vault.guardian mismatch");
        require(strategy.vault() == address(vault), "VERIFY: strategy.vault mismatch");
        require(strategy.keeper() == deployer, "VERIFY: strategy.keeper mismatch");
        require(strategy.guardian() == guardian, "VERIFY: strategy.guardian mismatch");
        console.log("All post-deploy assertions passed.");

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Vault:", address(vault));
        console.log("Strategy:", address(strategy));
        console.log("Guardian:", guardian);
        console.log("Fee: 10% (constant)");
        console.log("Max Slippage Cap: 5%");
        console.log("Rebalance Cooldown: 1 hour");
        console.log("Initial Allocation: 100% Takara, 0% Yei, 0% Feather");
        console.log("Yield Sources: Yei aWSEI, Takara cWSEI, Feather MetaMorpho WSEI vault");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("  1. Transfer ownership of all 4 contracts to multisig");
        console.log("  2. Call setMerklDistributor once Morpho Merkl address is known");
        console.log("  3. Update keeper address to dedicated bot wallet");
        console.log("  See script/DEPLOY_RUNBOOK.md for full post-deploy checklist");
    }
}
