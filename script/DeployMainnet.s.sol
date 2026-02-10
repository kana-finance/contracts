// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployMainnet
/// @notice Deploys Kana with REAL protocol addresses on SEI mainnet
contract DeployMainnet is Script {
    // ═══════════════════════════════════════════════════════════════════
    // SEI MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════
    
    // USDC on SEI
    address constant USDC = 0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392;
    
    // Yei Finance (Aave V3 fork)
    address constant YEI_POOL = 0x4a4d9abD36F923cBA0Af62A39C01dEC2944fb638;      // Pool Proxy
    address constant YEI_AUSDC = 0x817B3C191092694C65f25B4d38D4935a8aB65616;     // aYeiUSDC
    
    // Takara (Compound fork)
    address constant TAKARA_CUSDC = 0xd1E6a6F58A29F64ab2365947ACb53EfEB6Cc05e0;  // tnUSDC
    address constant TAKARA_COMPTROLLER = address(0); // TODO: Get comptroller address
    
    // Morpho
    address constant MORPHO = 0x015F10a56e97e02437D294815D8e079e1903E41C;
    
    // DEX Router (Sailor or other SEI DEX)
    address constant DRAGONSWAP_ROUTER = 0x11DA6463D6Cb5a03411Dbf5ab6f6bc3997Ac7428;
    address constant SAILOR_ROUTER = 0xd1EFe48B71Acd98Db16FcB9E7152B086647Ef544;
    
    // ═══════════════════════════════════════════════════════════════════
    
    KanaVault public vault;
    USDCStrategy public strategy;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== KANA MAINNET DEPLOYMENT ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");
        
        // Verify we're on SEI
        require(block.chainid == 1329, "Not on SEI mainnet!");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Deploy KanaVault
        vault = new KanaVault(
            IERC20(USDC),
            deployer, // feeRecipient
            1000      // 10% performance fee
        );
        console.log("KanaVault deployed:", address(vault));
        
        // 2. Deploy USDCStrategy with real protocol addresses
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
        
        // Start with 100% to Yei (safest, most battle-tested)
        strategy = new USDCStrategy(
            addrs,
            10000, // 100% to Yei initially
            0,     // 0% to Takara
            0,     // 0% to Morpho
            4      // Morpho max iterations
        );
        console.log("USDCStrategy deployed:", address(strategy));
        
        // 3. Connect vault to strategy
        vault.setStrategy(strategy);
        console.log("Strategy connected to vault");
        
        vm.stopBroadcast();
        
        // Output deployment summary
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Core Contracts:");
        console.log("  Vault:", address(vault));
        console.log("  Strategy:", address(strategy));
        console.log("");
        console.log("Connected Protocols:");
        console.log("  USDC:", USDC);
        console.log("  Yei Pool:", YEI_POOL);
        console.log("  Yei aUSDC:", YEI_AUSDC);
        console.log("  Takara cUSDC:", TAKARA_CUSDC);
        console.log("  Morpho:", MORPHO);
        console.log("");
        console.log("Configuration:");
        console.log("  Performance Fee: 10%");
        console.log("  Initial Allocation: 100% Yei");
        console.log("===========================");
    }
}
