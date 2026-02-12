// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployMainnet is Script {
    // SEI Mainnet Addresses
    address constant USDC = 0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392;
    address constant YEI_POOL = 0x4a4d9abD36F923cBA0Af62A39C01dEC2944fb638;
    address constant YEI_AUSDC = 0x817B3C191092694C65f25B4d38D4935a8aB65616;
    address constant TAKARA_CUSDC = 0xd1E6a6F58A29F64ab2365947ACb53EfEB6Cc05e0;
    address constant TAKARA_COMPTROLLER = 0x56A171Acb1bBa46D4fdF21AfBE89377574B8D9BD;
    address constant MORPHO = 0x015F10a56e97e02437D294815D8e079e1903E41C;
    address constant DRAGONSWAP_ROUTER = 0xa4cF2F53D1195aDDdE9e4D3aCa54f556895712f2;
    address constant SAILOR_ROUTER = 0xd1EFe48B71Acd98Db16FcB9E7152B086647Ef544;

    KanaVault public vault;
    USDCStrategy public strategy;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== KANA MAINNET DEPLOYMENT ===");
        console.log("Deployer:", deployer);
        require(block.chainid == 1329, "Not on SEI mainnet!");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy KanaVault (10% fee hardcoded)
        vault = new KanaVault(IERC20(USDC), deployer);
        console.log("KanaVault:", address(vault));

        // 2. Deploy USDCStrategy
        USDCStrategy.ProtocolAddresses memory addrs = USDCStrategy.ProtocolAddresses({
            usdc: USDC,
            vault: address(vault),
            yeiPool: YEI_POOL,
            aToken: YEI_AUSDC,
            cToken: TAKARA_CUSDC,
            comptroller: TAKARA_COMPTROLLER,
            morpho: MORPHO,
            routerV2: DRAGONSWAP_ROUTER,
            routerV3: SAILOR_ROUTER
        });

        strategy = new USDCStrategy(
            addrs,
            0,      // 0% Yei
            10000,  // 100% Takara initially
            0,      // 0% Morpho
            4,      // Morpho max iterations
            500,    // 5% max slippage cap
            3600,   // 1 hour rebalance cooldown
            3600    // 1 hour splits cooldown
        );
        console.log("USDCStrategy:", address(strategy));

        // 3. Connect vault ↔ strategy
        vault.setStrategy(strategy);

        // 4. Set keeper (deployer for now, change to bot wallet later)
        vault.setKeeper(deployer);
        strategy.setKeeper(deployer);

        // 5. First deposit — 10 USDC to prevent inflation attack
        uint256 seedAmount = 1e6; // 1 USDC
        IERC20(USDC).approve(address(vault), seedAmount);
        vault.deposit(seedAmount, deployer);
        console.log("Seed deposit: 1 USDC");

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Vault:", address(vault));
        console.log("Strategy:", address(strategy));
        console.log("Fee: 10% (constant)");
        console.log("Max Slippage Cap: 5%");
        console.log("Rebalance Cooldown: 1 hour");
        console.log("Initial Allocation: 100% Takara");
    }
}
