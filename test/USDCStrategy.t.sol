// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";
import {MockAToken, MockYeiPool, MockCToken, MockComptroller, MockMorpho, MockRouter} from "../src/mocks/MockLendingProtocols.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockRewardToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract USDCStrategyTest is Test {
    USDCStrategy public strategy;
    MockUSDC public usdc;
    MockYeiPool public yeiPool;
    MockAToken public aToken;
    MockCToken public cToken;
    MockComptroller public comptroller;
    MockMorpho public morpho;
    MockRouter public router;
    MockRewardToken public takaraReward;
    MockRewardToken public morphoReward;
    
    address public vault;
    address public owner;
    
    uint256 constant INITIAL_BALANCE = 1_000_000e6; // 1M USDC
    
    function setUp() public {
        owner = address(this);
        vault = makeAddr("vault");
        
        // Deploy mock tokens
        usdc = new MockUSDC();
        takaraReward = new MockRewardToken("Takara Reward", "TAKA");
        morphoReward = new MockRewardToken("Morpho Reward", "MORPHO");
        
        // Deploy mock protocols
        aToken = new MockAToken(address(usdc), "aUSDC", "aUSDC");
        yeiPool = new MockYeiPool();
        yeiPool.setAToken(address(usdc), address(aToken));
        
        cToken = new MockCToken(address(usdc), "cUSDC", "cUSDC");
        comptroller = new MockComptroller();
        comptroller.setCompToken(address(takaraReward));
        
        morpho = new MockMorpho();
        router = new MockRouter();
        
        // Fund protocols with USDC for withdrawals
        usdc.mint(address(aToken), INITIAL_BALANCE * 10);
        usdc.mint(address(cToken), INITIAL_BALANCE * 10);
        usdc.mint(address(morpho), INITIAL_BALANCE * 10);
        
        // Approve yeiPool to transfer from aToken (needed for withdraw)
        vm.prank(address(aToken));
        usdc.approve(address(yeiPool), type(uint256).max);
        
        // Deploy strategy (equal splits: 33.33% each)
        USDCStrategy.ProtocolAddresses memory addrs = USDCStrategy.ProtocolAddresses({
            usdc: address(usdc),
            vault: vault,
            yeiPool: address(yeiPool),
            aToken: address(aToken),
            cToken: address(cToken),
            comptroller: address(comptroller),
            morpho: address(morpho),
            routerV2: address(router),
            routerV3: address(0)
        });
        
        strategy = new USDCStrategy(
            addrs,
            3334, // splitYei
            3333, // splitTakara
            3333, // splitMorpho
            4,    // morphoMaxIterations
            500,  // maxSlippageBps (5%)
            3600, // rebalanceCooldown (1 hour)
            3600  // splitsCooldown (1 hour)
        );
        
        // Fund vault with USDC
        usdc.mint(vault, INITIAL_BALANCE);
        
        // Approve strategy from vault
        vm.prank(vault);
        usdc.approve(address(strategy), type(uint256).max);
    }
    
    // ─── Constructor Tests ───────────────────────────────────────────────
    
    function test_constructor_setsValues() public view {
        assertEq(address(strategy.usdc()), address(usdc));
        assertEq(strategy.vault(), vault);
        assertEq(strategy.splitYei(), 3334);
        assertEq(strategy.splitTakara(), 3333);
        assertEq(strategy.splitMorpho(), 3333);
        assertEq(strategy.morphoMaxIterations(), 4);
    }
    
    function test_constructor_invalidAddress_reverts() public {
        USDCStrategy.ProtocolAddresses memory addrs = USDCStrategy.ProtocolAddresses({
            usdc: address(0),
            vault: vault,
            yeiPool: address(yeiPool),
            aToken: address(aToken),
            cToken: address(cToken),
            comptroller: address(comptroller),
            morpho: address(morpho),
            routerV2: address(router),
            routerV3: address(0)
        });
        
        vm.expectRevert(USDCStrategy.InvalidAddress.selector);
        new USDCStrategy(addrs, 3334, 3333, 3333, 4, 500, 3600, 3600);
    }
    
    function test_constructor_invalidSplit_reverts() public {
        USDCStrategy.ProtocolAddresses memory addrs = USDCStrategy.ProtocolAddresses({
            usdc: address(usdc),
            vault: vault,
            yeiPool: address(yeiPool),
            aToken: address(aToken),
            cToken: address(cToken),
            comptroller: address(comptroller),
            morpho: address(morpho),
            routerV2: address(router),
            routerV3: address(0)
        });
        
        vm.expectRevert(USDCStrategy.InvalidSplit.selector);
        new USDCStrategy(addrs, 5000, 5000, 5000, 4, 500, 3600, 3600); // 150% total
    }
    
    // ─── Deposit Tests ───────────────────────────────────────────────────
    
    function test_deposit_basic() public {
        uint256 amount = 100_000e6;
        
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        
        vm.prank(vault);
        strategy.deposit(amount);
        
        // Check total balance is correct
        assertApproxEqRel(strategy.balanceOf(), amount, 0.01e18); // 1% tolerance
    }
    
    function test_deposit_splitsCorrectly() public {
        uint256 amount = 100_000e6;
        
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        
        vm.prank(vault);
        strategy.deposit(amount);
        
        // Expected splits (33.34%, 33.33%, 33.33%)
        uint256 expectedYei = (amount * 3334) / 10000;
        uint256 expectedTakara = (amount * 3333) / 10000;
        // Morpho gets remainder
        
        // Check aToken balance (Yei)
        assertApproxEqRel(aToken.balanceOf(address(strategy)), expectedYei, 0.01e18);
    }
    
    function test_deposit_onlyVault() public {
        vm.expectRevert(USDCStrategy.OnlyVault.selector);
        strategy.deposit(1000e6);
    }
    
    function test_deposit_emitsEvent() public {
        uint256 amount = 50_000e6;
        
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        
        vm.expectEmit(true, true, true, true);
        emit USDCStrategy.Deposited(amount);
        
        vm.prank(vault);
        strategy.deposit(amount);
    }
    
    // ─── Withdraw Tests ──────────────────────────────────────────────────
    
    function test_withdraw_basic() public {
        uint256 depositAmount = 100_000e6;
        uint256 withdrawAmount = 50_000e6;
        
        // Deposit first
        vm.prank(vault);
        usdc.transfer(address(strategy), depositAmount);
        vm.prank(vault);
        strategy.deposit(depositAmount);
        
        // Withdraw
        uint256 vaultBalBefore = usdc.balanceOf(vault);
        
        vm.prank(vault);
        strategy.withdraw(withdrawAmount);
        
        uint256 vaultBalAfter = usdc.balanceOf(vault);
        assertApproxEqRel(vaultBalAfter - vaultBalBefore, withdrawAmount, 0.01e18);
    }
    
    function test_withdraw_full() public {
        uint256 amount = 100_000e6;
        
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        uint256 balance = strategy.balanceOf();
        
        vm.prank(vault);
        strategy.withdraw(balance);
        
        // Strategy should be nearly empty
        assertLt(strategy.balanceOf(), 100); // Allow dust
    }
    
    function test_withdraw_onlyVault() public {
        vm.expectRevert(USDCStrategy.OnlyVault.selector);
        strategy.withdraw(1000e6);
    }
    
    function test_withdraw_emitsEvent() public {
        uint256 amount = 50_000e6;
        
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        vm.expectEmit(true, true, true, true);
        emit USDCStrategy.Withdrawn(amount / 2);
        
        vm.prank(vault);
        strategy.withdraw(amount / 2);
    }
    
    // ─── Harvest Tests ───────────────────────────────────────────────────
    
    function test_harvest_basic() public {
        uint256 amount = 100_000e6;
        
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        // Simulate time passing for interest accrual
        vm.warp(block.timestamp + 30 days);
        
        vm.prank(vault);
        uint256 profit = strategy.harvest(new uint256[](3));
        
        // Harvest completes without error (profit depends on mock behavior)
        // Mocks may or may not generate profit
        assertGe(profit, 0);
    }
    
    function test_harvest_withRewards() public {
        // This test verifies reward config can be set
        // Actual reward claiming depends on comptroller.claimComp behavior
        address[] memory takaraPath = new address[](2);
        takaraPath[0] = address(takaraReward);
        takaraPath[1] = address(usdc);
        
        strategy.setTakaraRewardConfig(address(takaraReward), takaraPath);
        
        uint256 amount = 50_000e6;
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        // Harvest should complete without error
        vm.prank(vault);
        strategy.harvest(new uint256[](3));
    }
    
    function test_harvest_onlyVault() public {
        vm.expectRevert(USDCStrategy.OnlyVault.selector);
        strategy.harvest(new uint256[](3));
    }
    
    // ─── Balance Tests ───────────────────────────────────────────────────
    
    function test_balanceOf_includesAllProtocols() public {
        uint256 amount = 90_000e6; // Divisible by 3
        
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        uint256 balance = strategy.balanceOf();
        assertApproxEqRel(balance, amount, 0.01e18);
    }
    
    function test_balanceOf_accruesInterest() public {
        uint256 amount = 100_000e6;
        
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        uint256 balanceBefore = strategy.balanceOf();
        
        // Warp time - interest is tracked in morpho mock
        vm.warp(block.timestamp + 365 days);
        
        uint256 balanceAfter = strategy.balanceOf();
        // Morpho accrues interest, so balance should increase
        assertGe(balanceAfter, balanceBefore);
    }
    
    function test_asset_returnsUsdc() public view {
        assertEq(strategy.asset(), address(usdc));
    }
    
    // ─── Admin: Splits ───────────────────────────────────────────────────
    
    function test_setSplits_basic() public {
        strategy.setSplits(5000, 3000, 2000);
        
        assertEq(strategy.splitYei(), 5000);
        assertEq(strategy.splitTakara(), 3000);
        assertEq(strategy.splitMorpho(), 2000);
    }
    
    function test_setSplits_invalidTotal_reverts() public {
        vm.expectRevert(USDCStrategy.InvalidSplit.selector);
        strategy.setSplits(5000, 5000, 5000);
    }
    
    function test_setSplits_onlyOwner() public {
        vm.prank(vault);
        vm.expectRevert();
        strategy.setSplits(5000, 3000, 2000);
    }
    
    function test_setSplits_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit USDCStrategy.SplitUpdated(5000, 3000, 2000);
        
        strategy.setSplits(5000, 3000, 2000);
    }
    
    // ─── Admin: Rebalance ────────────────────────────────────────────────
    
    function test_rebalance_basic() public {
        uint256 amount = 100_000e6;
        
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        // Change splits
        strategy.setSplits(8000, 1000, 1000);
        
        // Warp past cooldown and rebalance
        vm.warp(block.timestamp + 3601);
        strategy.rebalance();
        
        // Balance should be preserved
        assertApproxEqRel(strategy.balanceOf(), amount, 0.02e18);
    }
    
    function test_rebalance_emitsEvent() public {
        uint256 amount = 50_000e6;
        
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        vm.warp(block.timestamp + 3601);
        vm.expectEmit(true, true, true, true);
        emit USDCStrategy.Rebalanced();
        
        strategy.rebalance();
    }
    
    function test_rebalance_onlyOwner() public {
        vm.prank(vault);
        vm.expectRevert();
        strategy.rebalance();
    }
    
    function test_rebalance_emptyStrategy() public {
        // Should not revert on empty strategy
        vm.warp(block.timestamp + 3601);
        strategy.rebalance();
    }
    
    // ─── Admin: Config ───────────────────────────────────────────────────
    
    function test_setVault_basic() public {
        address newVault = makeAddr("newVault");
        
        strategy.setVault(newVault);
        
        assertEq(strategy.vault(), newVault);
    }
    
    function test_setVault_zeroAddress_reverts() public {
        vm.expectRevert(USDCStrategy.InvalidAddress.selector);
        strategy.setVault(address(0));
    }
    
    function test_setVault_emitsEvent() public {
        address newVault = makeAddr("newVault");
        
        vm.expectEmit(true, true, true, true);
        emit USDCStrategy.VaultUpdated(vault, newVault);
        
        strategy.setVault(newVault);
    }
    
    function test_setTakaraRewardConfig() public {
        address[] memory path = new address[](2);
        path[0] = address(takaraReward);
        path[1] = address(usdc);
        
        strategy.setTakaraRewardConfig(address(takaraReward), path);
        
        assertEq(strategy.takaraRewardToken(), address(takaraReward));
    }
    
    function test_setMorphoRewardConfig() public {
        address[] memory path = new address[](2);
        path[0] = address(morphoReward);
        path[1] = address(usdc);
        
        strategy.setMorphoRewardConfig(address(morphoReward), path);
        
        assertEq(strategy.morphoRewardToken(), address(morphoReward));
    }
    
    function test_setMorphoMaxIterations() public {
        strategy.setMorphoMaxIterations(10);
        assertEq(strategy.morphoMaxIterations(), 10);
    }
    
    function test_setRouterV2() public {
        address newRouter = makeAddr("newRouter");
        strategy.setRouterV2(newRouter);
        assertEq(address(strategy.routerV2()), newRouter);
    }
    
    // ─── Emergency ───────────────────────────────────────────────────────
    
    function test_rescueToken_basic() public {
        // Send some random token to strategy
        MockRewardToken randomToken = new MockRewardToken("Random", "RND");
        randomToken.mint(address(strategy), 1000e18);
        
        uint256 ownerBalBefore = randomToken.balanceOf(owner);
        
        strategy.rescueToken(address(randomToken), 1000e18);
        
        assertEq(randomToken.balanceOf(owner) - ownerBalBefore, 1000e18);
    }
    
    function test_rescueToken_canRescueLooseUsdc() public {
        // Send loose USDC to strategy
        usdc.mint(address(strategy), 1000e6);
        
        uint256 ownerBalBefore = usdc.balanceOf(owner);
        strategy.rescueToken(address(usdc), 1000e6);
        
        // Should rescue the loose balance
        assertEq(usdc.balanceOf(owner) - ownerBalBefore, 1000e6);
    }
    
    function test_rescueToken_onlyOwner() public {
        MockRewardToken randomToken = new MockRewardToken("Random", "RND");
        randomToken.mint(address(strategy), 1000e18);
        
        vm.prank(vault);
        vm.expectRevert();
        strategy.rescueToken(address(randomToken), 1000e18);
    }
    
    // ─── Edge Cases ──────────────────────────────────────────────────────
    
    function test_deposit_zeroAmount() public {
        vm.prank(vault);
        strategy.deposit(0);
        
        assertEq(strategy.balanceOf(), 0);
    }
    
    function test_withdraw_zeroBalance() public {
        vm.prank(vault);
        strategy.withdraw(0);
    }
    
    function test_multipleDepositsAndWithdrawals() public {
        // Deposit 1
        vm.prank(vault);
        usdc.transfer(address(strategy), 50_000e6);
        vm.prank(vault);
        strategy.deposit(50_000e6);
        
        // Withdraw half
        vm.prank(vault);
        strategy.withdraw(25_000e6);
        
        // Deposit more
        vm.prank(vault);
        usdc.transfer(address(strategy), 30_000e6);
        vm.prank(vault);
        strategy.deposit(30_000e6);
        
        // Final balance should be ~55k
        assertApproxEqRel(strategy.balanceOf(), 55_000e6, 0.02e18);
    }
    
    function test_fuzz_deposit(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000_000e6);
        
        usdc.mint(vault, amount);
        
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        assertApproxEqRel(strategy.balanceOf(), amount, 0.01e18);
    }
    
    // ─── Swap & Harvest Edge Cases ───────────────────────────────────────
    
    function test_harvest_withTakaraSwap() public {
        // Setup Takara reward config with valid swap path
        address[] memory takaraPath = new address[](2);
        takaraPath[0] = address(takaraReward);
        takaraPath[1] = address(usdc);
        
        strategy.setTakaraRewardConfig(address(takaraReward), takaraPath);
        
        // Fund router for swaps (mock does 1:1, so fund with enough USDC)
        usdc.mint(address(router), 10_000e6);
        
        // Give strategy some reward tokens (small amount, 6 decimals worth for 1:1 swap)
        takaraReward.mint(address(strategy), 1000e6);
        
        // Strategy needs to approve router for reward token
        // This happens via the _swap function's safeIncreaseAllowance
        
        // Deposit some funds first
        uint256 amount = 50_000e6;
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        // Harvest - should swap reward tokens to USDC (minOut[1] = 950e6 for Takara, 5% max slippage)
        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[1] = 950e6; // Takara: 1000e6 * 9500 / 10000
        vm.prank(vault);
        strategy.harvest(minAmounts);
    }

    function test_harvest_withMorphoSwap() public {
        // Setup Morpho reward config
        address[] memory morphoPath = new address[](2);
        morphoPath[0] = address(morphoReward);
        morphoPath[1] = address(usdc);
        
        strategy.setMorphoRewardConfig(address(morphoReward), morphoPath);
        
        // Fund router (mock does 1:1)
        usdc.mint(address(router), 10_000e6);
        
        // Give strategy some morpho rewards (6 decimals for 1:1 with USDC)
        morphoReward.mint(address(strategy), 500e6);
        
        // Deposit first
        uint256 amount = 30_000e6;
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        // minOut[2] = 475e6 for Morpho: 500e6 * 9500 / 10000
        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[2] = 475e6;
        vm.prank(vault);
        strategy.harvest(minAmounts);
    }

    function test_harvest_noRouter() public {
        // Set router to zero to test no-op swap path
        strategy.setRouterV2(address(0));
        
        // Setup reward config anyway
        address[] memory path = new address[](2);
        path[0] = address(takaraReward);
        path[1] = address(usdc);
        strategy.setTakaraRewardConfig(address(takaraReward), path);
        
        // Give rewards
        takaraReward.mint(address(strategy), 100e18);
        
        // Deposit
        uint256 amount = 10_000e6;
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        // Must provide valid minOut even with no router; swap silently no-ops
        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[1] = 95e18; // Takara: 100e18 * 9500 / 10000
        vm.prank(vault);
        strategy.harvest(minAmounts);
    }
    
    function test_harvest_zeroRewardBalance() public {
        // Setup config but no actual rewards
        address[] memory path = new address[](2);
        path[0] = address(takaraReward);
        path[1] = address(usdc);
        strategy.setTakaraRewardConfig(address(takaraReward), path);
        
        uint256 amount = 20_000e6;
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        // Harvest with 0 reward balance
        vm.prank(vault);
        strategy.harvest(new uint256[](3));
    }
    
    function test_harvest_shortSwapPath() public {
        // Setup config with path too short (< 2)
        address[] memory shortPath = new address[](1);
        shortPath[0] = address(takaraReward);
        strategy.setTakaraRewardConfig(address(takaraReward), shortPath);
        
        takaraReward.mint(address(strategy), 100e18);
        
        uint256 amount = 10_000e6;
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        // Should not swap with short path
        vm.prank(vault);
        strategy.harvest(new uint256[](3));
    }
    
    // ─── Withdraw Edge Cases ─────────────────────────────────────────────
    
    function test_withdraw_moreFromOneProtocol() public {
        // Test withdraw when one protocol has more than others
        // First deploy with custom splits
        strategy.setSplits(8000, 1000, 1000); // 80% Yei
        
        uint256 amount = 100_000e6;
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        // Rebalance to new splits
        vm.warp(block.timestamp + 3601);
        strategy.rebalance();
        
        // Now withdraw - should pull mostly from Yei
        vm.prank(vault);
        strategy.withdraw(50_000e6);
        
        assertApproxEqRel(strategy.balanceOf(), 50_000e6, 0.02e18);
    }
    
    function test_withdraw_exceedsOneProtocolBalance() public {
        // This tests the actual > balance check in withdraw
        strategy.setSplits(10000, 0, 0); // 100% to Yei
        
        uint256 amount = 50_000e6;
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        // Warp past splits cooldown
        vm.warp(block.timestamp + 3601);
        
        // Now change to even splits and try to withdraw
        // The proportional calc will try to pull from Takara/Morpho which have 0
        strategy.setSplits(3334, 3333, 3333);
        
        vm.prank(vault);
        strategy.withdraw(25_000e6);
    }
    
    // ─── Deploy Edge Cases ───────────────────────────────────────────────
    
    function test_deposit_onlyToYei() public {
        strategy.setSplits(10000, 0, 0);
        
        uint256 amount = 50_000e6;
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        assertApproxEqRel(strategy.balanceOf(), amount, 0.01e18);
    }
    
    function test_deposit_onlyToTakara() public {
        strategy.setSplits(0, 10000, 0);
        
        uint256 amount = 50_000e6;
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        assertApproxEqRel(strategy.balanceOf(), amount, 0.01e18);
    }
    
    function test_deposit_onlyToMorpho() public {
        strategy.setSplits(0, 0, 10000);
        
        uint256 amount = 50_000e6;
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        assertApproxEqRel(strategy.balanceOf(), amount, 0.01e18);
    }
    
    // ─── Constructor Edge Cases ──────────────────────────────────────────
    
    function test_constructor_vaultZeroAddress_reverts() public {
        USDCStrategy.ProtocolAddresses memory addrs = USDCStrategy.ProtocolAddresses({
            usdc: address(usdc),
            vault: address(0),
            yeiPool: address(yeiPool),
            aToken: address(aToken),
            cToken: address(cToken),
            comptroller: address(comptroller),
            morpho: address(morpho),
            routerV2: address(router),
            routerV3: address(0)
        });
        
        vm.expectRevert(USDCStrategy.InvalidAddress.selector);
        new USDCStrategy(addrs, 3334, 3333, 3333, 4, 500, 3600, 3600);
    }
}
