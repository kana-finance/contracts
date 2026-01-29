// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";

contract KanaVaultTest is Test {
    // ─── Contracts ───────────────────────────────────────────────────────

    KanaVault public vault;
    MockERC20 public usdc;
    MockStrategy public strategyA; // "Yei" — 5% APY
    MockStrategy public strategyB; // "Takara" — 8% APY
    MockStrategy public strategyC; // "Morpho" — 6% APY

    // ─── Actors ──────────────────────────────────────────────────────────

    address public owner = makeAddr("owner");
    address public feeRecipient = makeAddr("feeRecipient");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    // ─── Constants ───────────────────────────────────────────────────────

    uint256 public constant PERFORMANCE_FEE_BPS = 1000; // 10%
    uint256 public constant INITIAL_BALANCE = 100_000e6; // 100k USDC (6 decimals)

    // ─── Setup ───────────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(owner);

        // Deploy USDC mock (6 decimals like real USDC)
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy vault
        vault = new KanaVault(
            IERC20(address(usdc)),
            feeRecipient,
            PERFORMANCE_FEE_BPS
        );

        // Deploy strategies
        strategyA = new MockStrategy(address(usdc), "Yei Finance", 500);
        strategyB = new MockStrategy(address(usdc), "Takara", 800);
        strategyC = new MockStrategy(address(usdc), "Morpho", 600);

        // Add strategies to vault
        vault.addStrategy(IStrategy(address(strategyA)));
        vault.addStrategy(IStrategy(address(strategyB)));
        vault.addStrategy(IStrategy(address(strategyC)));

        vm.stopPrank();

        // Fund users
        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);

        // Approve vault
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  DEPOSIT TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit_basic() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Should get shares equal to deposit (1:1 initially)
        assertEq(shares, depositAmount, "Shares should equal deposit on first deposit");
        assertEq(vault.balanceOf(alice), depositAmount, "Alice vault balance wrong");
        assertEq(vault.totalAssets(), depositAmount, "Total assets wrong");
    }

    function test_deposit_deploys_to_active_strategy() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Funds should be in strategyA (index 0 = default active)
        assertEq(
            strategyA.balanceOf(),
            depositAmount,
            "Strategy A should hold deposited funds"
        );
    }

    function test_deposit_multiple_users() public {
        vm.prank(alice);
        vault.deposit(50_000e6, alice);

        vm.prank(bob);
        vault.deposit(30_000e6, bob);

        assertEq(vault.totalAssets(), 80_000e6, "Total assets should be sum of deposits");
        assertEq(vault.balanceOf(alice), 50_000e6, "Alice shares wrong");
        assertEq(vault.balanceOf(bob), 30_000e6, "Bob shares wrong");
    }

    function test_deposit_zero_noShares() public {
        vm.prank(alice);
        // ERC4626 mints 0 shares for 0 assets (no revert by default)
        uint256 shares = vault.deposit(0, alice);
        assertEq(shares, 0, "Should get 0 shares for 0 deposit");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  WITHDRAWAL TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_withdraw_basic() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertEq(assets, depositAmount, "Should withdraw full deposit");
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE, "Alice should have original balance");
        assertEq(vault.totalAssets(), 0, "Vault should be empty");
    }

    function test_withdraw_partial() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(alice);
        vault.withdraw(5_000e6, alice, alice);

        assertEq(vault.balanceOf(alice), 5_000e6, "Alice should have half remaining");
        assertEq(vault.totalAssets(), 5_000e6, "Half should remain in vault");
    }

    function test_withdraw_pulls_from_strategy() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Verify funds are in strategy
        assertEq(strategyA.balanceOf(), 10_000e6, "Strategy should hold funds");

        // Withdraw should pull from strategy
        vm.prank(alice);
        vault.withdraw(10_000e6, alice, alice);

        assertEq(strategyA.balanceOf(), 0, "Strategy should be empty after withdrawal");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  STRATEGY MANAGEMENT TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_addStrategy() public {
        MockStrategy newStrategy = new MockStrategy(address(usdc), "New", 1000);

        vm.prank(owner);
        vault.addStrategy(IStrategy(address(newStrategy)));

        assertEq(vault.strategiesCount(), 4, "Should have 4 strategies");
    }

    function test_addStrategy_duplicate_reverts() public {
        vm.prank(owner);
        vm.expectRevert(KanaVault.StrategyAlreadyAdded.selector);
        vault.addStrategy(IStrategy(address(strategyA)));
    }

    function test_addStrategy_onlyOwner() public {
        MockStrategy newStrategy = new MockStrategy(address(usdc), "New", 1000);

        vm.prank(alice);
        vm.expectRevert();
        vault.addStrategy(IStrategy(address(newStrategy)));
    }

    function test_removeStrategy() public {
        vm.prank(owner);
        vault.removeStrategy(2); // Remove Morpho (index 2)

        assertEq(vault.strategiesCount(), 2, "Should have 2 strategies");
    }

    function test_removeStrategy_withdraws_funds() public {
        // Deposit first
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Remove active strategy — should withdraw all funds first
        vm.prank(owner);
        vault.removeStrategy(0);

        // Funds should be back in vault (not lost)
        assertEq(vault.totalAssets(), 10_000e6, "Assets shouldn't be lost on removal");
    }

    function test_setActiveStrategy() public {
        vm.prank(owner);
        vault.setActiveStrategy(1); // Switch to Takara

        // New deposits should go to strategy B
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        assertEq(strategyB.balanceOf(), 10_000e6, "Takara should receive deposits");
        assertEq(strategyA.balanceOf(), 0, "Yei should have nothing");
    }

    function test_setActiveStrategy_invalid_reverts() public {
        vm.prank(owner);
        vm.expectRevert(KanaVault.StrategyNotFound.selector);
        vault.setActiveStrategy(99);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  REBALANCE TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_rebalance() public {
        // Deposit into strategy A
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        assertEq(strategyA.balanceOf(), 10_000e6, "A should hold funds");

        // Rebalance to strategy B (Takara has higher APY)
        vm.prank(owner);
        vault.rebalance(1);

        assertEq(strategyA.balanceOf(), 0, "A should be empty after rebalance");
        assertEq(strategyB.balanceOf(), 10_000e6, "B should hold all funds");
        assertEq(vault.activeStrategyIndex(), 1, "Active strategy should be B");
    }

    function test_rebalance_preserves_totalAssets() public {
        vm.prank(alice);
        vault.deposit(50_000e6, alice);

        uint256 totalBefore = vault.totalAssets();

        vm.prank(owner);
        vault.rebalance(2); // Move to Morpho

        assertEq(vault.totalAssets(), totalBefore, "Total assets shouldn't change on rebalance");
    }

    function test_rebalance_sameStrategy_noop() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Rebalance to same strategy — should be a no-op
        vm.prank(owner);
        vault.rebalance(0);

        assertEq(strategyA.balanceOf(), 10_000e6, "Should still be in A");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  HARVEST & FEE TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_harvest_with_yield() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Simulate 100 USDC yield in strategy
        uint256 yield = 100e6;
        usdc.mint(address(strategyA), yield);
        strategyA.simulateYield(yield);

        // Harvest
        vm.prank(owner);
        vault.harvest();

        // 10% fee on 100 USDC = 10 USDC to fee recipient
        assertEq(usdc.balanceOf(feeRecipient), 10e6, "Fee recipient should get 10%");

        // Total profit tracked
        assertEq(vault.totalProfitAccrued(), yield, "Profit tracking wrong");
    }

    function test_harvest_no_yield() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Harvest with no yield — should not revert
        vm.prank(owner);
        vault.harvest();

        assertEq(usdc.balanceOf(feeRecipient), 0, "No fee if no yield");
    }

    function test_harvest_onlyOwner() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(alice);
        vm.expectRevert();
        vault.harvest();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  FEE ADMIN TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_setPerformanceFee() public {
        vm.prank(owner);
        vault.setPerformanceFee(500); // 5%

        assertEq(vault.performanceFeeBps(), 500, "Fee should be 5%");
    }

    function test_setPerformanceFee_tooHigh_reverts() public {
        vm.prank(owner);
        vm.expectRevert(KanaVault.InvalidFee.selector);
        vault.setPerformanceFee(2001); // > 20%
    }

    function test_setFeeRecipient() public {
        address newRecipient = makeAddr("newFeeRecipient");

        vm.prank(owner);
        vault.setFeeRecipient(newRecipient);

        assertEq(vault.feeRecipient(), newRecipient, "Fee recipient not updated");
    }

    function test_setFeeRecipient_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(KanaVault.InvalidAddress.selector);
        vault.setFeeRecipient(address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ERC4626 CONFORMANCE TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_erc4626_asset() public view {
        assertEq(vault.asset(), address(usdc), "Asset should be USDC");
    }

    function test_erc4626_name_symbol() public view {
        assertEq(vault.name(), "Kana USDC Vault", "Name wrong");
        assertEq(vault.symbol(), "kUSDC", "Symbol wrong");
    }

    function test_erc4626_convertToShares() public view {
        // Initially 1:1
        assertEq(vault.convertToShares(1000e6), 1000e6, "Conversion should be 1:1 initially");
    }

    function test_erc4626_convertToAssets() public view {
        assertEq(vault.convertToAssets(1000e6), 1000e6, "Conversion should be 1:1 initially");
    }

    function test_erc4626_maxDeposit() public view {
        assertEq(vault.maxDeposit(alice), type(uint256).max, "Max deposit should be unlimited");
    }

    function test_erc4626_totalAssets_with_yield() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Simulate yield
        usdc.mint(address(strategyA), 500e6);

        // Total assets should include yield
        assertEq(vault.totalAssets(), 10_500e6, "Should include strategy yield");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SHARE PRICE TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_sharePrice_increases_with_yield() public {
        // Alice deposits 10k
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Simulate 1000 USDC yield (10%)
        usdc.mint(address(strategyA), 1_000e6);

        // Now 1 share = 1.1 USDC (10k shares for 11k assets)
        uint256 assetsPerShare = vault.convertToAssets(1e6);
        assertGt(assetsPerShare, 1e6, "Share price should increase with yield");

        // Bob deposits 10k — should get fewer shares
        vm.prank(bob);
        uint256 bobShares = vault.deposit(10_000e6, bob);
        assertLt(bobShares, 10_000e6, "Bob should get fewer shares due to yield");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  EDGE CASES
    // ═══════════════════════════════════════════════════════════════════════

    function test_multipleDepositsAndWithdrawals() public {
        // Alice deposits 50k
        vm.prank(alice);
        vault.deposit(50_000e6, alice);

        // Bob deposits 30k
        vm.prank(bob);
        vault.deposit(30_000e6, bob);

        // Alice withdraws 20k
        vm.prank(alice);
        vault.withdraw(20_000e6, alice, alice);

        // Check balances
        assertEq(vault.totalAssets(), 60_000e6, "Total should be 80k - 20k = 60k");
        assertEq(vault.balanceOf(alice), 30_000e6, "Alice should have 30k shares");
        assertEq(vault.balanceOf(bob), 30_000e6, "Bob should have 30k shares");
    }

    function test_fullFlow_deposit_yield_harvest_withdraw() public {
        // 1. Alice deposits 10k
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // 2. Simulate 200 USDC yield
        usdc.mint(address(strategyA), 200e6);
        strategyA.simulateYield(200e6);

        // 3. Owner harvests — 10% fee = 20 USDC
        vm.prank(owner);
        vault.harvest();

        assertEq(usdc.balanceOf(feeRecipient), 20e6, "Fee should be 20 USDC");

        // 4. Alice redeems all shares
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 received = vault.redeem(aliceShares, alice, alice);

        // Should get original 10k + yield minus fee ≈ 10,180 (±1 rounding)
        assertApproxEqAbs(received, 10_180e6, 1, "Alice should get deposit + yield - fee");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  VIEW FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_strategiesCount() public view {
        assertEq(vault.strategiesCount(), 3, "Should have 3 strategies");
    }

    function test_activeStrategy() public view {
        assertEq(
            address(vault.activeStrategy()),
            address(strategyA),
            "Active strategy should be A"
        );
    }

    function test_activeStrategy_noStrategies_reverts() public {
        // Deploy a fresh vault with no strategies
        vm.prank(owner);
        KanaVault emptyVault = new KanaVault(
            IERC20(address(usdc)),
            feeRecipient,
            PERFORMANCE_FEE_BPS
        );

        vm.expectRevert(KanaVault.NoStrategies.selector);
        emptyVault.activeStrategy();
    }
}
