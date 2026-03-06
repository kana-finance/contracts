// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";

contract KanaVaultTest is Test {
    KanaVault public vault;
    MockERC20 public usdc;
    MockStrategy public strategy;

    address public owner = makeAddr("owner");
    address public feeRecipient = makeAddr("feeRecipient");
    address public keeperAddr = makeAddr("keeper");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant INITIAL_BALANCE = 100_000e6;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new KanaVault(IERC20(address(usdc)), feeRecipient);
        strategy = new MockStrategy(address(usdc));
        vault.setStrategy(IStrategy(address(strategy)));
        vault.setKeeper(keeperAddr);
        vm.stopPrank();

        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  DEPOSIT
    // ═══════════════════════════════════════════════════════════════════

    function test_deposit_basic() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // With virtual offset, shares won't be exactly 1:1 for first depositor
        // but totalAssets should be correct
        assertEq(vault.totalAssets(), 10_000e6, "Total assets wrong");
        assertGt(vault.balanceOf(alice), 0, "Alice should have shares");
    }

    function test_deposit_routes_to_strategy() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        assertEq(strategy.balanceOf(), 10_000e6, "Strategy should hold deposited funds");
    }

    function test_deposit_multiple_users() public {
        vm.prank(alice);
        vault.deposit(50_000e6, alice);
        vm.prank(bob);
        vault.deposit(30_000e6, bob);

        assertEq(vault.totalAssets(), 80_000e6, "Total assets should be sum");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  WITHDRAW
    // ═══════════════════════════════════════════════════════════════════

    function test_withdraw_basic() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        // With virtual offset, may lose a tiny amount to rounding
        assertApproxEqAbs(assets, 10_000e6, 1, "Should withdraw full deposit");
        assertEq(vault.totalAssets(), 0, "Vault should be empty");
    }

    function test_withdraw_partial() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(alice);
        vault.withdraw(5_000e6, alice, alice);

        assertApproxEqAbs(vault.totalAssets(), 5_000e6, 1);
    }

    function test_withdraw_pulls_from_strategy() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        assertEq(strategy.balanceOf(), 10_000e6);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(strategy.balanceOf(), 0, "Strategy should be empty");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  STRATEGY MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════

    function test_setStrategy() public {
        MockStrategy newStrategy = new MockStrategy(address(usdc));

        vm.prank(owner);
        vault.setStrategy(IStrategy(address(newStrategy)));

        assertEq(address(vault.strategy()), address(newStrategy));
    }

    function test_setStrategy_migrates_funds() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        assertEq(strategy.balanceOf(), 10_000e6);

        MockStrategy newStrategy = new MockStrategy(address(usdc));
        vm.prank(owner);
        vault.setStrategy(IStrategy(address(newStrategy)));

        assertEq(strategy.balanceOf(), 0, "Old strategy should be empty");
        assertEq(newStrategy.balanceOf(), 10_000e6, "New strategy should hold funds");
        assertEq(vault.totalAssets(), 10_000e6, "Total assets should be preserved");
    }

    function test_setStrategy_assetMismatch_reverts() public {
        MockERC20 otherToken = new MockERC20("DAI", "DAI", 18);
        MockStrategy badStrategy = new MockStrategy(address(otherToken));

        vm.prank(owner);
        vm.expectRevert(KanaVault.StrategyAssetMismatch.selector);
        vault.setStrategy(IStrategy(address(badStrategy)));
    }

    function test_setStrategy_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(KanaVault.InvalidAddress.selector);
        vault.setStrategy(IStrategy(address(0)));
    }

    function test_setStrategy_onlyOwner() public {
        MockStrategy newStrategy = new MockStrategy(address(usdc));
        vm.prank(alice);
        vm.expectRevert();
        vault.setStrategy(IStrategy(address(newStrategy)));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  HARVEST & FEES
    // ═══════════════════════════════════════════════════════════════════

    function test_harvest_with_yield() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Simulate 100 USDC yield
        usdc.mint(address(strategy), 100e6);
        strategy.simulateYield(100e6);

        vm.prank(owner);
        vault.harvest(new uint256[](3));

        // 10% fee on 100 USDC = 10 USDC
        assertEq(usdc.balanceOf(feeRecipient), 10e6, "Fee recipient should get 10%");
        assertEq(vault.totalProfitAccrued(), 100e6, "Profit tracking wrong");
    }

    function test_harvest_no_yield() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(owner);
        vault.harvest(new uint256[](3)); // should not revert

        assertEq(usdc.balanceOf(feeRecipient), 0);
    }

    function test_harvest_noStrategy_reverts() public {
        vm.startPrank(owner);
        KanaVault emptyVault = new KanaVault(IERC20(address(usdc)), feeRecipient);

        vm.expectRevert(KanaVault.NoStrategy.selector);
        emptyVault.harvest(new uint256[](3));
        vm.stopPrank();
    }

    function test_harvest_onlyKeeperOrOwner() public {
        vm.prank(alice);
        vm.expectRevert(KanaVault.NotKeeperOrOwner.selector);
        vault.harvest(new uint256[](3));
    }

    function test_harvest_keeper_can_call() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        usdc.mint(address(strategy), 100e6);
        strategy.simulateYield(100e6);

        vm.prank(keeperAddr);
        vault.harvest(new uint256[](3));

        assertEq(usdc.balanceOf(feeRecipient), 10e6, "Keeper harvest should work");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  KEEPER MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════

    function test_setKeeper() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(owner);
        vault.setKeeper(newKeeper);
        assertEq(vault.keeper(), newKeeper);
    }

    function test_revokeKeeper() public {
        vm.prank(owner);
        vault.revokeKeeper();
        assertEq(vault.keeper(), address(0));
    }

    function test_setKeeper_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setKeeper(alice);
    }

    function test_revokedKeeper_cannot_harvest() public {
        vm.prank(owner);
        vault.revokeKeeper();

        vm.prank(keeperAddr);
        vm.expectRevert(KanaVault.NotKeeperOrOwner.selector);
        vault.harvest(new uint256[](3));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  FEE ADMIN
    // ═══════════════════════════════════════════════════════════════════

    function test_performanceFee_is_constant() public view {
        assertEq(vault.PERFORMANCE_FEE_BPS(), 1000);
    }

    function test_setFeeRecipient() public {
        address newRecipient = makeAddr("newFeeRecipient");
        vm.prank(owner);
        vault.setFeeRecipient(newRecipient);
        assertEq(vault.feeRecipient(), newRecipient);
    }

    function test_setFeeRecipient_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(KanaVault.InvalidAddress.selector);
        vault.setFeeRecipient(address(0));
    }

    function test_lockFeeRecipient() public {
        vm.startPrank(owner);
        vault.lockFeeRecipient();
        assertTrue(vault.feeRecipientLocked());

        vm.expectRevert(KanaVault.FeeRecipientIsLocked.selector);
        vault.setFeeRecipient(makeAddr("new"));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ERC-4626 CONFORMANCE
    // ═══════════════════════════════════════════════════════════════════

    function test_erc4626_metadata() public view {
        assertEq(vault.asset(), address(usdc));
        assertEq(vault.name(), "Kana USDC Vault");
        assertEq(vault.symbol(), "kUSDC");
    }

    function test_totalAssets_includes_yield() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        usdc.mint(address(strategy), 500e6);
        assertEq(vault.totalAssets(), 10_500e6);
    }

    function test_sharePrice_increases_with_yield() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // 10% yield
        usdc.mint(address(strategy), 1_000e6);

        // Bob gets fewer shares for same deposit
        vm.prank(bob);
        uint256 bobShares = vault.deposit(10_000e6, bob);
        uint256 aliceShares = vault.balanceOf(alice);
        assertLt(bobShares, aliceShares, "Bob should get fewer shares");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  INFLATION ATTACK PROTECTION
    // ═══════════════════════════════════════════════════════════════════

    function test_inflationAttack_mitigated() public {
        // Attacker deposits 1 wei
        usdc.mint(address(this), 1);
        usdc.approve(address(vault), 1);
        vault.deposit(1, address(this));

        // Attacker donates large amount directly to vault/strategy
        usdc.mint(address(strategy), 10_000e6);

        // Victim deposits — should NOT get 0 shares
        vm.prank(alice);
        uint256 victimShares = vault.deposit(10_000e6, alice);
        assertGt(victimShares, 0, "Victim should get non-zero shares");

        // Victim should be able to withdraw most of their deposit
        vm.prank(alice);
        uint256 received = vault.redeem(victimShares, alice, alice);
        // With virtual offset, loss should be negligible
        assertGt(received, 9_900e6, "Victim should not lose significant funds");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  FULL E2E FLOW
    // ═══════════════════════════════════════════════════════════════════

    function test_fullFlow() public {
        // 1. Alice deposits 10k
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // 2. Yield accrues (200 USDC)
        usdc.mint(address(strategy), 200e6);
        strategy.simulateYield(200e6);

        // 3. Harvest — 10% fee = 20 USDC
        vm.prank(keeperAddr);
        vault.harvest(new uint256[](3));
        assertEq(usdc.balanceOf(feeRecipient), 20e6);

        // 4. Alice redeems
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 received = vault.redeem(aliceShares, alice, alice);

        // Should get ~10,180 (deposit + yield - fee), ±2 for rounding with virtual offset
        assertApproxEqAbs(received, 10_180e6, 2, "Alice should get deposit + yield - fee");
    }

    function test_multipleDepositsAndWithdrawals() public {
        vm.prank(alice);
        vault.deposit(50_000e6, alice);
        vm.prank(bob);
        vault.deposit(30_000e6, bob);

        vm.prank(alice);
        vault.withdraw(20_000e6, alice, alice);

        assertApproxEqAbs(vault.totalAssets(), 60_000e6, 1);
    }
}
