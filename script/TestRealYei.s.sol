// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";

/// @title TestRealYei
/// @notice Test Kana with REAL Yei Finance on forked SEI
contract TestRealYei is Script {
    // Real SEI addresses
    address constant USDC = 0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392;
    address constant YEI_POOL = 0x4a4d9abD36F923cBA0Af62A39C01dEC2944fb638;
    address constant YEI_AUSDC = 0x817B3C191092694C65f25B4d38D4935a8aB65616;
    address constant TAKARA_CUSDC = 0xd1E6a6F58A29F64ab2365947ACb53EfEB6Cc05e0;
    address constant MORPHO = 0x015F10a56e97e02437D294815D8e079e1903E41C;
    
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        
        console.log("=== KANA REAL YEI TEST ===");
        console.log("User:", user);
        
        // Check if user has any USDC
        uint256 usdcBal = IERC20(USDC).balanceOf(user);
        console.log("User USDC balance:", usdcBal / 1e6, "USDC");
        
        if (usdcBal == 0) {
            console.log("");
            console.log("User has no USDC. Finding a whale to impersonate...");
            
            // Find a USDC whale on SEI by checking aYeiUSDC holders
            // The aToken contract holds a lot of USDC
            uint256 aTokenBal = IERC20(USDC).balanceOf(YEI_AUSDC);
            console.log("Yei aUSDC contract has:", aTokenBal / 1e6, "USDC");
            
            // We'll deal some USDC to our user using vm.deal equivalent for ERC20
            vm.startBroadcast(pk);
            // Can't deal ERC20 directly in broadcast, need to use pranks in test
            vm.stopBroadcast();
            
            console.log("To test, we need USDC. Options:");
            console.log("1. Bridge USDC to SEI testnet");
            console.log("2. Use forge test with vm.deal");
            console.log("3. Find and impersonate a whale");
            return;
        }
        
        vm.startBroadcast(pk);
        
        // 1. Deploy Vault
        console.log("");
        console.log("1. Deploying KanaVault...");
        KanaVault vault = new KanaVault(
            IERC20(USDC),
            user,
            1000
        );
        console.log("   Vault:", address(vault));
        
        // 2. Deploy Strategy (100% to Yei)
        console.log("2. Deploying USDCStrategy (100% Yei)...");
        USDCStrategy.ProtocolAddresses memory addrs = USDCStrategy.ProtocolAddresses({
            usdc: USDC,
            vault: address(vault),
            yeiPool: YEI_POOL,
            aToken: YEI_AUSDC,
            cToken: TAKARA_CUSDC,
            comptroller: address(0), // Not using Takara yet
            morpho: MORPHO,
            routerV2: address(0),
            routerV3: address(0) // Not using swaps yet
        });
        
        USDCStrategy strategy = new USDCStrategy(
            addrs,
            10000, // 100% Yei
            0,
            0,
            4
        );
        console.log("   Strategy:", address(strategy));
        
        // 3. Connect
        vault.setStrategy(strategy);
        console.log("3. Strategy connected to vault");
        
        // 4. Approve & Deposit
        uint256 depositAmount = usdcBal / 10; // Deposit 10% of balance
        console.log("");
        console.log("4. Depositing", depositAmount / 1e6, "USDC...");
        
        IERC20(USDC).approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user);
        console.log("   Received shares:", shares);
        
        // 5. Check state
        console.log("");
        console.log("5. State after deposit:");
        console.log("   Vault total assets:", vault.totalAssets() / 1e6, "USDC");
        console.log("   Strategy balance:", strategy.balanceOf() / 1e6, "USDC");
        console.log("   aYeiUSDC held by strategy:", IERC20(YEI_AUSDC).balanceOf(address(strategy)));
        
        // 6. Withdraw half
        console.log("");
        console.log("6. Withdrawing half...");
        uint256 halfShares = shares / 2;
        uint256 withdrawn = vault.redeem(halfShares, user, user);
        console.log("   Withdrawn:", withdrawn / 1e6, "USDC");
        
        // Final state
        console.log("");
        console.log("=== FINAL STATE ===");
        console.log("User USDC:", IERC20(USDC).balanceOf(user) / 1e6);
        console.log("User vault shares:", vault.balanceOf(user));
        console.log("Vault total assets:", vault.totalAssets() / 1e6, "USDC");
        
        vm.stopBroadcast();
    }
}
