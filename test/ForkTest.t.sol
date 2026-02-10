// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";

/// @title ForkTest
/// @notice Integration tests against REAL Yei Finance on forked SEI
/// @dev Run with: forge test --match-contract ForkTest --fork-url https://evm-rpc.sei-apis.com -vvv
contract ForkTest is Test {
    // Real SEI mainnet addresses
    address constant USDC = 0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392;
    address constant YEI_POOL = 0x4a4d9abD36F923cBA0Af62A39C01dEC2944fb638;
    address constant YEI_AUSDC = 0x817B3C191092694C65f25B4d38D4935a8aB65616;
    address constant TAKARA_CUSDC = 0xd1E6a6F58A29F64ab2365947ACb53EfEB6Cc05e0;
    address constant MORPHO = 0x015F10a56e97e02437D294815D8e079e1903E41C;
    
    KanaVault public vault;
    USDCStrategy public strategy;
    address public user;
    
    uint256 constant INITIAL_BALANCE = 100_000e6; // 100k USDC
    
    function setUp() public {
        // This test requires a fork
        // Skip if not forked
        if (block.chainid != 1329) {
            return;
        }
        
        user = makeAddr("user");
        
        // Deal USDC to user (works on fork!)
        deal(USDC, user, INITIAL_BALANCE);
        
        // Deploy Vault
        vault = new KanaVault(
            IERC20(USDC),
            address(this), // feeRecipient
            1000 // 10% fee
        );
        
        // Deploy Strategy (100% to Yei initially)
        USDCStrategy.ProtocolAddresses memory addrs = USDCStrategy.ProtocolAddresses({
            usdc: USDC,
            vault: address(vault),
            yeiPool: YEI_POOL,
            aToken: YEI_AUSDC,
            cToken: TAKARA_CUSDC,
            comptroller: address(0),
            morpho: MORPHO,
            routerV2: address(0),
            routerV3: address(0)
        });
        
        strategy = new USDCStrategy(
            addrs,
            10000, // 100% Yei
            0,
            0,
            4
        );
        
        vault.setStrategy(strategy);
        
        // Approve
        vm.prank(user);
        IERC20(USDC).approve(address(vault), type(uint256).max);
    }
    
    function test_fork_deposit() public {
        if (block.chainid != 1329) {
            console2.log("Skipping - not on SEI fork");
            return;
        }
        
        uint256 depositAmount = 10_000e6;
        
        console2.log("=== FORK TEST: DEPOSIT ===");
        console2.log("User USDC before:", IERC20(USDC).balanceOf(user) / 1e6);
        
        vm.prank(user);
        uint256 shares = vault.deposit(depositAmount, user);
        
        console2.log("Deposited:", depositAmount / 1e6, "USDC");
        console2.log("Received shares:", shares);
        console2.log("Vault total assets:", vault.totalAssets() / 1e6, "USDC");
        console2.log("Strategy balance:", strategy.balanceOf() / 1e6, "USDC");
        
        // Verify aYeiUSDC was received
        uint256 aTokenBal = IERC20(YEI_AUSDC).balanceOf(address(strategy));
        console2.log("aYeiUSDC held by strategy:", aTokenBal);
        
        assertGt(shares, 0, "Should receive shares");
        assertApproxEqRel(vault.totalAssets(), depositAmount, 0.01e18, "Total assets should match deposit");
        assertGt(aTokenBal, 0, "Strategy should hold aYeiUSDC");
    }
    
    function test_fork_depositAndWithdraw() public {
        if (block.chainid != 1329) {
            console2.log("Skipping - not on SEI fork");
            return;
        }
        
        uint256 depositAmount = 50_000e6;
        
        console2.log("=== FORK TEST: DEPOSIT & WITHDRAW ===");
        
        // Deposit
        vm.prank(user);
        uint256 shares = vault.deposit(depositAmount, user);
        console2.log("Deposited USDC:", depositAmount / 1e6);
        console2.log("Got shares:", shares);
        
        uint256 balBefore = IERC20(USDC).balanceOf(user);
        
        // Withdraw half
        vm.prank(user);
        uint256 withdrawn = vault.redeem(shares / 2, user, user);
        console2.log("Withdrew:", withdrawn / 1e6, "USDC");
        
        uint256 balAfter = IERC20(USDC).balanceOf(user);
        
        assertApproxEqRel(withdrawn, depositAmount / 2, 0.01e18, "Should withdraw ~half");
        assertEq(balAfter - balBefore, withdrawn, "User should receive USDC");
        
        // Check remaining
        console2.log("Remaining vault assets:", vault.totalAssets() / 1e6, "USDC");
        assertApproxEqRel(vault.totalAssets(), depositAmount / 2, 0.01e18, "Half should remain");
    }
    
    function test_fork_yieldAccrual() public {
        if (block.chainid != 1329) {
            console2.log("Skipping - not on SEI fork");
            return;
        }
        
        uint256 depositAmount = 100_000e6;
        
        console2.log("=== FORK TEST: YIELD ACCRUAL ===");
        
        // Deposit
        vm.prank(user);
        vault.deposit(depositAmount, user);
        
        uint256 assetsBefore = vault.totalAssets();
        console2.log("Assets after deposit:", assetsBefore / 1e6, "USDC");
        
        // Warp 30 days
        vm.warp(block.timestamp + 30 days);
        
        // Check if yield accrued (aToken balance should increase)
        uint256 assetsAfter = vault.totalAssets();
        console2.log("Assets after 30 days:", assetsAfter / 1e6, "USDC");
        
        // Yei should have accrued some interest
        // Note: On a static fork, yield won't actually accrue
        // This test verifies the plumbing works
        console2.log("Yield accrued:", (assetsAfter - assetsBefore) / 1e6, "USDC");
    }
    
    function test_fork_harvest() public {
        if (block.chainid != 1329) {
            console2.log("Skipping - not on SEI fork");
            return;
        }
        
        uint256 depositAmount = 50_000e6;
        
        console2.log("=== FORK TEST: HARVEST ===");
        
        vm.prank(user);
        vault.deposit(depositAmount, user);
        
        // Warp time
        vm.warp(block.timestamp + 7 days);
        
        // Harvest
        vault.harvest();
        
        console2.log("Harvest completed successfully");
        console2.log("Vault total assets:", vault.totalAssets() / 1e6, "USDC");
    }
    
    function test_fork_fullCycle() public {
        if (block.chainid != 1329) {
            console2.log("Skipping - not on SEI fork");
            return;
        }
        
        console2.log("=== FORK TEST: FULL CYCLE ===");
        
        // 1. Deposit
        uint256 depositAmount = 25_000e6;
        vm.prank(user);
        uint256 shares = vault.deposit(depositAmount, user);
        console2.log("1. Deposited", depositAmount / 1e6, "USDC");
        
        // 2. Time passes
        vm.warp(block.timestamp + 14 days);
        console2.log("2. 14 days passed");
        
        // 3. Harvest
        vault.harvest();
        console2.log("3. Harvested");
        
        // 4. Another deposit
        vm.prank(user);
        vault.deposit(depositAmount, user);
        console2.log("4. Deposited another", depositAmount / 1e6, "USDC");
        
        // 5. Partial withdraw
        vm.prank(user);
        uint256 withdrawn = vault.redeem(shares / 2, user, user);
        console2.log("5. Withdrew", withdrawn / 1e6, "USDC");
        
        // 6. Final state
        console2.log("");
        console2.log("Final vault assets:", vault.totalAssets() / 1e6, "USDC");
        console2.log("Final user shares:", vault.balanceOf(user));
        console2.log("Strategy in Yei:", IERC20(YEI_AUSDC).balanceOf(address(strategy)));
        
        // Verify
        assertGt(vault.totalAssets(), 0, "Vault should have assets");
        assertGt(vault.balanceOf(user), 0, "User should have shares");
    }
}
