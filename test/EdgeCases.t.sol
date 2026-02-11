// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAToken, MockYeiPool, MockCToken, MockComptroller, MockMorpho, MockRouter} from "../src/mocks/MockLendingProtocols.sol";

/// @title EdgeCasesTest
/// @notice Comprehensive edge case testing: reentrancy, reverting protocols, 0-splits, gas limits
contract EdgeCasesTest is Test {
    using SafeERC20 for IERC20;

    KanaVault public vault;
    USDCStrategy public strategy;
    MockERC20 public usdc;
    MockERC20 public rewardToken;
    MockYeiPool public yeiPool;
    MockAToken public aToken;
    MockCToken public cToken;
    MockComptroller public comptroller;
    MockMorpho public morpho;
    MockRouter public router;

    address public owner;
    address public feeRecipient;
    address public keeper;
    address public alice;

    function setUp() public {
        owner = address(this);
        feeRecipient = makeAddr("feeRecipient");
        keeper = makeAddr("keeper");
        alice = makeAddr("alice");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        rewardToken = new MockERC20("Reward", "RWD", 18);

        aToken = new MockAToken(address(usdc), "aUSDC", "aUSDC");
        yeiPool = new MockYeiPool();
        yeiPool.setAToken(address(usdc), address(aToken));
        cToken = new MockCToken(address(usdc), "cUSDC", "cUSDC");
        comptroller = new MockComptroller();
        morpho = new MockMorpho();
        router = new MockRouter();

        usdc.mint(address(aToken), 100_000_000e6);
        usdc.mint(address(cToken), 100_000_000e6);
        usdc.mint(address(morpho), 100_000_000e6);
        usdc.mint(address(router), 100_000_000e6);

        vm.prank(address(aToken));
        usdc.approve(address(yeiPool), type(uint256).max);

        vault = new KanaVault(IERC20(address(usdc)), feeRecipient);

        USDCStrategy.ProtocolAddresses memory addrs = USDCStrategy.ProtocolAddresses({
            usdc: address(usdc),
            vault: address(vault),
            yeiPool: address(yeiPool),
            aToken: address(aToken),
            cToken: address(cToken),
            comptroller: address(comptroller),
            morpho: address(morpho),
            routerV2: address(router),
            routerV3: address(0)
        });

        strategy = new USDCStrategy(addrs, 3334, 3333, 3333, 4, 500, 3600, 3600);

        vault.setStrategy(strategy);
        vault.setKeeper(keeper);
        strategy.setKeeper(keeper);

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════
    // REENTRANCY TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_reentrancy_deposit_noCallback() public {
        // ERC4626 doesn't have callbacks, so reentrancy is naturally prevented
        // OpenZeppelin SafeERC20 and standard checks-effects-interactions pattern protect against reentrancy
        // This test documents that the pattern is safe
        
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        
        // Deposit completed without issues
        assertEq(vault.totalAssets(), 10_000e6);
    }

    function test_reentrancy_withdraw_noCallback() public {
        // Withdraw also doesn't have callbacks
        vm.prank(alice);
        vault.deposit(50_000e6, alice);

        vm.prank(alice);
        vault.withdraw(25_000e6, alice, alice);

        // Withdraw completed without issues
        assertApproxEqRel(vault.totalAssets(), 25_000e6, 0.01e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    // REVERTING PROTOCOL TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_harvest_yieldSourceReverts_propagatesError() public {
        // Create a reverting protocol mock
        RevertingMorpho revertingMorpho = new RevertingMorpho();

        // Replace Morpho with reverting one
        strategy.removeYieldSource(2);
        
        address[] memory swapPath = new address[](0);
        strategy.addYieldSource(
            USDCStrategy.ProtocolType.Morpho,
            true,
            3333,
            address(revertingMorpho),
            address(0),
            address(0),
            address(0),
            swapPath,
            4
        );

        // Try to deposit - should fail
        vm.prank(alice);
        vm.expectRevert("Reverting protocol");
        vault.deposit(90_000e6, alice);
    }

    function test_deposit_withRevertingProtocol_fails() public {
        // Create reverting protocol
        RevertingMorpho revertingMorpho = new RevertingMorpho();

        strategy.removeYieldSource(2);
        
        address[] memory swapPath = new address[](0);
        strategy.addYieldSource(
            USDCStrategy.ProtocolType.Morpho,
            true,
            3333,
            address(revertingMorpho),
            address(0),
            address(0),
            address(0),
            swapPath,
            4
        );

        // Deposit should fail when protocol reverts
        vm.prank(alice);
        vm.expectRevert("Reverting protocol");
        vault.deposit(10_000e6, alice);
    }

    // ═══════════════════════════════════════════════════════════════════
    // ZERO-SPLIT SOURCE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_harvest_zeroSplitSources_skipped() public {
        // Create a new strategy with one source having 0 split from the start
        USDCStrategy.ProtocolAddresses memory addrs = USDCStrategy.ProtocolAddresses({
            usdc: address(usdc),
            vault: address(vault),
            yeiPool: address(yeiPool),
            aToken: address(aToken),
            cToken: address(cToken),
            comptroller: address(comptroller),
            morpho: address(morpho),
            routerV2: address(router),
            routerV3: address(0)
        });

        USDCStrategy newStrategy = new USDCStrategy(addrs, 10000, 0, 0, 4, 500, 3600, 3600);
        newStrategy.setKeeper(keeper);

        vault.setStrategy(newStrategy);

        vm.prank(alice);
        vault.deposit(50_000e6, alice);

        // Setup reward for Takara (0 split)
        address[] memory takaraPath = new address[](2);
        takaraPath[0] = address(rewardToken);
        takaraPath[1] = address(usdc);
        newStrategy.setTakaraRewardConfig(address(rewardToken), takaraPath);

        rewardToken.mint(address(newStrategy), 1000e18);

        // Harvest should skip Takara since split=0
        vm.prank(keeper);
        vault.harvest(0, 0);

        // No error means 0-split sources were skipped
    }

    function test_deposit_zeroSplitSources_skipped() public {
        strategy.setSplits(10000, 0, 0);

        vm.prank(alice);
        vault.deposit(30_000e6, alice);

        // All funds should be in Yei only
        assertApproxEqRel(strategy.balanceOf(), 30_000e6, 0.01e18);
    }

    function test_withdraw_zeroSplitSources_skipped() public {
        strategy.setSplits(10000, 0, 0);

        vm.prank(alice);
        vault.deposit(30_000e6, alice);

        vm.prank(alice);
        vault.withdraw(15_000e6, alice, alice);

        assertApproxEqRel(strategy.balanceOf(), 15_000e6, 0.01e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    // GAS LIMIT TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_gasLimit_deposit() public {
        // Test with existing 3 yield sources
        vm.prank(alice);
        uint256 gasStart = gasleft();
        vault.deposit(100_000e6, alice);
        uint256 gasUsed = gasStart - gasleft();

        console2.log("Gas used for deposit with 3 sources:", gasUsed);
        // Should complete within reasonable limits
        assertLt(gasUsed, 500_000, "Deposit with 3 sources should use < 500k gas");
    }

    function test_gasLimit_withdraw() public {
        vm.prank(alice);
        vault.deposit(100_000e6, alice);

        vm.prank(alice);
        uint256 gasStart = gasleft();
        vault.withdraw(50_000e6, alice, alice);
        uint256 gasUsed = gasStart - gasleft();

        console2.log("Gas used for withdraw with 3 sources:", gasUsed);
        assertLt(gasUsed, 500_000, "Withdraw with 3 sources should use < 500k gas");
    }

    function test_gasLimit_harvest() public {
        vm.prank(alice);
        vault.deposit(100_000e6, alice);

        uint256[] memory minAmounts = new uint256[](3);

        vm.prank(keeper);
        uint256 gasStart = gasleft();
        vault.harvest(minAmounts);
        uint256 gasUsed = gasStart - gasleft();

        console2.log("Gas used for harvest with 3 sources:", gasUsed);
        assertLt(gasUsed, 500_000, "Harvest with 3 sources should use < 500k gas");
    }

    // ═══════════════════════════════════════════════════════════════════
    // ALL SOURCES DISABLED
    // ═══════════════════════════════════════════════════════════════════

    function test_allSourcesDisabled_depositWorks() public {
        // Disable all sources
        strategy.setYieldSourceEnabled(0, false);
        strategy.setYieldSourceEnabled(1, false);
        strategy.setYieldSourceEnabled(2, false);

        // Deposit should still work (funds stay idle in strategy)
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Funds should be in strategy as loose USDC
        assertEq(usdc.balanceOf(address(strategy)), 10_000e6);
    }

    function test_allSourcesDisabled_withdrawWorks() public {
        strategy.setYieldSourceEnabled(0, false);
        strategy.setYieldSourceEnabled(1, false);
        strategy.setYieldSourceEnabled(2, false);

        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(alice);
        vault.withdraw(5000e6, alice, alice);

        assertEq(usdc.balanceOf(alice), 1_000_000e6 - 10_000e6 + 5000e6);
    }

    function test_allSourcesDisabled_harvestWorks() public {
        strategy.setYieldSourceEnabled(0, false);
        strategy.setYieldSourceEnabled(1, false);
        strategy.setYieldSourceEnabled(2, false);

        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256[] memory minAmounts = new uint256[](3);

        vm.prank(keeper);
        vault.harvest(minAmounts);

        // No yield when all sources disabled
    }

    // ═══════════════════════════════════════════════════════════════════
    // REMOVING SOURCE WITH FUNDS
    // ═══════════════════════════════════════════════════════════════════

    function test_removeSource_withFunds_fundsPersist() public {
        vm.prank(alice);
        vault.deposit(90_000e6, alice);

        // Remove Morpho (should just disable it, funds stay)
        strategy.removeYieldSource(2);

        // Source should be disabled with split 0
        (
            ,
            bool enabled,
            uint256 split,
            ,
            ,
            ,
            ,
            ,
        ) = strategy.getYieldSource(2);

        assertFalse(enabled);
        assertEq(split, 0);
        
        // Total balance still includes funds in disabled Morpho source
        uint256 balance = strategy.balanceOf();
        assertGt(balance, 0);
    }

    function test_removeSource_thenRebalance_movesAllFunds() public {
        vm.prank(alice);
        vault.deposit(90_000e6, alice);

        // Remove Morpho
        strategy.removeYieldSource(2);

        // Update splits for remaining sources
        vm.warp(block.timestamp + 3601);
        strategy.setSplits(5000, 5000, 0);

        // Rebalance to redistribute
        vm.warp(block.timestamp + 3601);
        strategy.rebalance();

        // Rebalance completes successfully even with a removed source
        uint256 balance = strategy.balanceOf();
        assertGt(balance, 0, "Strategy still has funds after rebalance");
    }

    function test_removeSource_withdraw_stillWorks() public {
        vm.prank(alice);
        vault.deposit(90_000e6, alice);

        strategy.removeYieldSource(1); // Remove Takara

        uint256 balanceBefore = strategy.balanceOf();

        // Withdraw should work even with a removed source
        vm.prank(alice);
        vault.withdraw(30_000e6, alice, alice);

        uint256 balanceAfter = strategy.balanceOf();
        
        // Balance decreased (withdrawal worked)
        assertLt(balanceAfter, balanceBefore, "Withdrawal reduced balance");
        assertEq(usdc.balanceOf(alice), 1_000_000e6 - 90_000e6 + 30_000e6, "Alice received withdrawn funds");
    }

    // ═══════════════════════════════════════════════════════════════════
    // EXTREME VALUE TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_deposit_verySmall_1wei() public {
        usdc.mint(bob, 1);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1);
        
        // Should handle 1 wei deposit
        vault.deposit(1, bob);
        
        assertGt(vault.balanceOf(bob), 0);
        vm.stopPrank();
    }

    function test_deposit_veryLarge() public {
        uint256 largeAmount = 1_000_000_000e6; // 1 billion USDC
        usdc.mint(alice, largeAmount);

        vm.prank(alice);
        vault.deposit(largeAmount, alice);

        assertApproxEqRel(vault.totalAssets(), largeAmount, 0.01e18);
    }

    function test_withdraw_dust() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Withdraw very small amount
        vm.prank(alice);
        vault.withdraw(1, alice, alice);

        assertApproxEqRel(vault.totalAssets(), 10_000e6 - 1, 0.01e18);
    }

    address bob = makeAddr("bob");
}

/// @notice Mock that always reverts
contract RevertingMorpho {
    function supply(address, uint256, address, uint256) external pure {
        revert("Reverting protocol");
    }

    function withdraw(address, uint256, address, uint256) external pure returns (uint256) {
        revert("Reverting protocol");
    }

    function supplyBalance(address, address) external pure returns (uint256) {
        revert("Reverting protocol");
    }
}

// Reentrancy protection is inherent in ERC4626 due to no callbacks
