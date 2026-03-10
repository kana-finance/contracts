// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";

contract TestFlow is Script {
    // Deployed addresses from DeployTestnet
    address constant USDC = 0xf5059a5D33d5853360D16C683c16e67980206f36;
    address constant VAULT = 0x9d4454B023096f34B160D6B654540c56A1F81688;
    address constant STRATEGY = 0x5eb3Bc0a489C5A8288765d2336659EbCA68FCd00;
    
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        
        IERC20 usdc = IERC20(USDC);
        KanaVault vault = KanaVault(VAULT);
        USDCStrategy strategy = USDCStrategy(STRATEGY);
        
        console.log("=== KANA TEST FLOW ===");
        console.log("User:", user);
        
        // Check initial balances
        uint256 usdcBal = usdc.balanceOf(user);
        console.log("Initial USDC balance:", usdcBal / 1e6, "USDC");
        
        vm.startBroadcast(pk);
        
        // 1. Approve vault
        console.log("\n1. Approving vault...");
        usdc.approve(VAULT, type(uint256).max);
        
        // 2. Deposit 10,000 USDC
        uint256 depositAmount = 10_000 * 1e6;
        console.log("2. Depositing", depositAmount / 1e6, "USDC...");
        uint256 shares = vault.deposit(depositAmount, user);
        console.log("   Received shares:", shares);
        
        // 3. Check vault state
        console.log("\n3. Vault State After Deposit:");
        console.log("   Total Assets:", vault.totalAssets() / 1e6, "USDC");
        console.log("   User Shares:", vault.balanceOf(user));
        console.log("   Strategy Balance:", strategy.balanceOf() / 1e6, "USDC");
        
        vm.stopBroadcast();
        
        // 4. Simulate 30 days passing (for yield)
        console.log("\n4. Simulating 30 days...");
        vm.warp(block.timestamp + 30 days);
        
        vm.startBroadcast(pk);
        
        // 5. Harvest yield
        // minAmountsOut is zeros here because the testnet mock protocols don't produce
        // reward tokens, so there are no swaps to protect. On mainnet with reward tokens
        // configured, pass non-zero values to enforce slippage limits.
        console.log("5. Harvesting yield...");
        vault.harvest(new uint256[](3));
        console.log("   Total Assets after harvest:", vault.totalAssets() / 1e6, "USDC");
        
        // 6. Check share value
        uint256 shareValue = vault.previewRedeem(shares);
        console.log("\n6. Share Value Check:");
        console.log("   Shares owned:", shares);
        console.log("   Worth in USDC:", shareValue / 1e6);
        
        // 7. Withdraw half
        uint256 withdrawShares = shares / 2;
        console.log("\n7. Withdrawing half...");
        uint256 withdrawn = vault.redeem(withdrawShares, user, user);
        console.log("   Withdrew:", withdrawn / 1e6, "USDC");
        
        // Final state
        console.log("\n=== FINAL STATE ===");
        console.log("USDC Balance:", usdc.balanceOf(user) / 1e6, "USDC");
        console.log("Vault Shares:", vault.balanceOf(user));
        console.log("Vault Total Assets:", vault.totalAssets() / 1e6, "USDC");
        
        vm.stopBroadcast();
    }
}
