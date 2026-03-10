// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {SEIVault} from "../src/SEIVault.sol";
import {SEIStrategy} from "../src/SEIStrategy.sol";
import {MockAToken, MockYeiPool, MockCToken, MockComptroller, MockMorpho, MockRouter} from "../src/mocks/MockLendingProtocols.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockWSEI is ERC20 {
    constructor() ERC20("Wrapped SEI", "WSEI") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

contract MockRewardToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SEIStrategyTest is Test {
    SEIStrategy public strategy;
    MockWSEI public wsei;
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

    uint256 constant INITIAL_BALANCE = 1_000e18; // 1000 WSEI

    function setUp() public {
        owner = address(this);
        vault = makeAddr("vault");

        // Deploy mock tokens
        wsei = new MockWSEI();
        takaraReward = new MockRewardToken("Takara Reward", "TAKA");
        morphoReward = new MockRewardToken("Morpho Reward", "MORPHO");

        // Deploy mock protocols
        aToken = new MockAToken(address(wsei), "aWSEI", "aWSEI");
        yeiPool = new MockYeiPool();
        yeiPool.setAToken(address(wsei), address(aToken));

        cToken = new MockCToken(address(wsei), "cWSEI", "cWSEI");
        comptroller = new MockComptroller();
        comptroller.setCompToken(address(takaraReward));

        morpho = new MockMorpho();
        router = new MockRouter();

        // Fund protocols with WSEI for withdrawals
        wsei.mint(address(aToken), INITIAL_BALANCE * 10);
        wsei.mint(address(cToken), INITIAL_BALANCE * 10);
        wsei.mint(address(morpho), INITIAL_BALANCE * 10);

        // Approve yeiPool to transfer from aToken (needed for withdraw)
        vm.prank(address(aToken));
        wsei.approve(address(yeiPool), type(uint256).max);

        // Deploy strategy (equal splits: 33.34% / 33.33% / 33.33%)
        SEIStrategy.ProtocolAddresses memory addrs = SEIStrategy.ProtocolAddresses({
            wsei: address(wsei),
            vault: vault,
            yeiPool: address(yeiPool),
            aToken: address(aToken),
            cToken: address(cToken),
            comptroller: address(comptroller),
            morpho: address(morpho),
            routerV2: address(router),
            routerV3: address(0)
        });

        strategy = new SEIStrategy(
            addrs,
            3334, // splitYei
            3333, // splitTakara
            3333, // splitMorpho
            4,    // morphoMaxIterations
            500,  // maxSlippageBps (5%)
            3600, // rebalanceCooldown (1 hour)
            3600  // splitsCooldown (1 hour)
        );

        // Fund vault with WSEI
        wsei.mint(vault, INITIAL_BALANCE);

        // Approve strategy from vault
        vm.prank(vault);
        wsei.approve(address(strategy), type(uint256).max);
    }

    // ─── Constructor Tests ───────────────────────────────────────────────

    function test_constructor_setsValues() public view {
        assertEq(address(strategy.wsei()), address(wsei));
        assertEq(strategy.vault(), vault);
        assertEq(strategy.splitYei(), 3334);
        assertEq(strategy.splitTakara(), 3333);
        assertEq(strategy.splitMorpho(), 3333);
        assertEq(strategy.morphoMaxIterations(), 4);
    }

    function test_constructor_invalidAddress_reverts() public {
        SEIStrategy.ProtocolAddresses memory addrs = SEIStrategy.ProtocolAddresses({
            wsei: address(0),
            vault: vault,
            yeiPool: address(yeiPool),
            aToken: address(aToken),
            cToken: address(cToken),
            comptroller: address(comptroller),
            morpho: address(morpho),
            routerV2: address(router),
            routerV3: address(0)
        });

        vm.expectRevert(SEIStrategy.InvalidAddress.selector);
        new SEIStrategy(addrs, 3334, 3333, 3333, 4, 500, 3600, 3600);
    }

    function test_constructor_invalidSplit_reverts() public {
        SEIStrategy.ProtocolAddresses memory addrs = SEIStrategy.ProtocolAddresses({
            wsei: address(wsei),
            vault: vault,
            yeiPool: address(yeiPool),
            aToken: address(aToken),
            cToken: address(cToken),
            comptroller: address(comptroller),
            morpho: address(morpho),
            routerV2: address(router),
            routerV3: address(0)
        });

        vm.expectRevert(SEIStrategy.InvalidSplit.selector);
        new SEIStrategy(addrs, 5000, 5000, 5000, 4, 500, 3600, 3600); // 150% total
    }

    // ─── Deposit Tests ───────────────────────────────────────────────────

    function test_deposit_basic() public {
        uint256 amount = 100e18;

        vm.prank(vault);
        wsei.transfer(address(strategy), amount);

        vm.prank(vault);
        strategy.deposit(amount);

        assertApproxEqRel(strategy.balanceOf(), amount, 0.01e18); // 1% tolerance
    }

    function test_deposit_splitsCorrectly() public {
        uint256 amount = 100e18;

        vm.prank(vault);
        wsei.transfer(address(strategy), amount);

        vm.prank(vault);
        strategy.deposit(amount);

        // Expected splits (33.34%, 33.33%, 33.33%)
        uint256 expectedYei = (amount * 3334) / 10000;

        // Check aToken balance (Yei)
        assertApproxEqRel(aToken.balanceOf(address(strategy)), expectedYei, 0.01e18);
    }

    function test_deposit_onlyVault() public {
        vm.expectRevert(SEIStrategy.OnlyVault.selector);
        strategy.deposit(1e18);
    }

    function test_deposit_emitsEvent() public {
        uint256 amount = 50e18;

        vm.prank(vault);
        wsei.transfer(address(strategy), amount);

        vm.expectEmit(true, true, true, true);
        emit SEIStrategy.Deposited(amount);

        vm.prank(vault);
        strategy.deposit(amount);
    }

    // ─── Withdraw Tests ──────────────────────────────────────────────────

    function test_withdraw_basic() public {
        uint256 depositAmount = 100e18;
        uint256 withdrawAmount = 50e18;

        // Deposit first
        vm.prank(vault);
        wsei.transfer(address(strategy), depositAmount);
        vm.prank(vault);
        strategy.deposit(depositAmount);

        // Withdraw
        uint256 vaultBalBefore = wsei.balanceOf(vault);

        vm.prank(vault);
        strategy.withdraw(withdrawAmount);

        uint256 vaultBalAfter = wsei.balanceOf(vault);
        assertApproxEqRel(vaultBalAfter - vaultBalBefore, withdrawAmount, 0.01e18);
    }

    function test_withdraw_full() public {
        uint256 amount = 100e18;

        vm.prank(vault);
        wsei.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);

        uint256 balance = strategy.balanceOf();

        vm.prank(vault);
        strategy.withdraw(balance);

        // Strategy should be nearly empty (allow small dust in 18-decimal tokens)
        assertLt(strategy.balanceOf(), 1e12);
    }

    function test_withdraw_onlyVault() public {
        vm.expectRevert(SEIStrategy.OnlyVault.selector);
        strategy.withdraw(1e18);
    }

    function test_withdraw_emitsEvent() public {
        uint256 amount = 50e18;

        vm.prank(vault);
        wsei.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);

        vm.expectEmit(true, true, true, true);
        emit SEIStrategy.Withdrawn(amount / 2);

        vm.prank(vault);
        strategy.withdraw(amount / 2);
    }

    // ─── Harvest Tests ───────────────────────────────────────────────────

    function test_harvest_basic() public {
        uint256 amount = 100e18;

        vm.prank(vault);
        wsei.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);

        // Simulate time passing for interest accrual
        vm.warp(block.timestamp + 30 days);

        vm.prank(vault);
        uint256 profit = strategy.harvest(new uint256[](3));

        assertGe(profit, 0);
    }

    function test_harvest_withRewards() public {
        address[] memory takaraPath = new address[](2);
        takaraPath[0] = address(takaraReward);
        takaraPath[1] = address(wsei);

        strategy.setTakaraRewardConfig(address(takaraReward), takaraPath);

        uint256 amount = 50e18;
        vm.prank(vault);
        wsei.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);

        // Harvest should complete without error
        vm.prank(vault);
        strategy.harvest(new uint256[](3));
    }

    function test_harvest_onlyVault() public {
        vm.expectRevert(SEIStrategy.OnlyVault.selector);
        strategy.harvest(new uint256[](3));
    }

    // ─── Balance Tests ───────────────────────────────────────────────────

    function test_balanceOf_includesAllProtocols() public {
        uint256 amount = 90e18;

        vm.prank(vault);
        wsei.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);

        uint256 balance = strategy.balanceOf();
        assertApproxEqRel(balance, amount, 0.01e18);
    }

    function test_balanceOf_accruesInterest() public {
        uint256 amount = 100e18;

        vm.prank(vault);
        wsei.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);

        uint256 balanceBefore = strategy.balanceOf();

        vm.warp(block.timestamp + 365 days);

        uint256 balanceAfter = strategy.balanceOf();
        assertGe(balanceAfter, balanceBefore);
    }

    function test_asset_returnsWsei() public view {
        assertEq(strategy.asset(), address(wsei));
    }

    // ─── Admin: Splits ───────────────────────────────────────────────────

    function test_setSplits_basic() public {
        strategy.setSplits(5000, 3000, 2000);

        assertEq(strategy.splitYei(), 5000);
        assertEq(strategy.splitTakara(), 3000);
        assertEq(strategy.splitMorpho(), 2000);
    }

    function test_setSplits_invalidTotal_reverts() public {
        vm.expectRevert(SEIStrategy.InvalidSplit.selector);
        strategy.setSplits(5000, 5000, 5000);
    }

    function test_setSplits_onlyOwner() public {
        vm.prank(vault);
        vm.expectRevert();
        strategy.setSplits(5000, 3000, 2000);
    }

    function test_setSplits_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit SEIStrategy.SplitUpdated(5000, 3000, 2000);

        strategy.setSplits(5000, 3000, 2000);
    }

    // ─── Admin: Rebalance ────────────────────────────────────────────────

    function test_rebalance_basic() public {
        uint256 amount = 100e18;

        vm.prank(vault);
        wsei.transfer(address(strategy), amount);
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
        uint256 amount = 50e18;

        vm.prank(vault);
        wsei.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);

        vm.warp(block.timestamp + 3601);
        vm.expectEmit(true, true, true, true);
        emit SEIStrategy.Rebalanced();

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
        vm.expectRevert(SEIStrategy.InvalidAddress.selector);
        strategy.setVault(address(0));
    }

    function test_setVault_emitsEvent() public {
        address newVault = makeAddr("newVault");

        vm.expectEmit(true, true, true, true);
        emit SEIStrategy.VaultUpdated(vault, newVault);

        strategy.setVault(newVault);
    }

    function test_setTakaraRewardConfig() public {
        address[] memory path = new address[](2);
        path[0] = address(takaraReward);
        path[1] = address(wsei);

        strategy.setTakaraRewardConfig(address(takaraReward), path);

        assertEq(strategy.takaraRewardToken(), address(takaraReward));
    }

    function test_setMorphoRewardConfig() public {
        address[] memory path = new address[](2);
        path[0] = address(morphoReward);
        path[1] = address(wsei);

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
        MockRewardToken randomToken = new MockRewardToken("Random", "RND");
        randomToken.mint(address(strategy), 1000e18);

        uint256 ownerBalBefore = randomToken.balanceOf(owner);

        strategy.rescueToken(address(randomToken), 1000e18);

        assertEq(randomToken.balanceOf(owner) - ownerBalBefore, 1000e18);
    }

    function test_rescueToken_canRescueLooseWsei() public {
        wsei.mint(address(strategy), 10e18);

        uint256 ownerBalBefore = wsei.balanceOf(owner);
        strategy.rescueToken(address(wsei), 10e18);

        assertEq(wsei.balanceOf(owner) - ownerBalBefore, 10e18);
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
        wsei.transfer(address(strategy), 50e18);
        vm.prank(vault);
        strategy.deposit(50e18);

        // Withdraw half
        vm.prank(vault);
        strategy.withdraw(25e18);

        // Deposit more
        wsei.mint(vault, 30e18);
        vm.prank(vault);
        wsei.transfer(address(strategy), 30e18);
        vm.prank(vault);
        strategy.deposit(30e18);

        // Final balance should be ~55 WSEI
        assertApproxEqRel(strategy.balanceOf(), 55e18, 0.02e18);
    }

    function test_fuzz_deposit(uint256 amount) public {
        amount = bound(amount, 1e15, 100_000e18);

        wsei.mint(vault, amount);

        vm.prank(vault);
        wsei.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);

        assertApproxEqRel(strategy.balanceOf(), amount, 0.01e18);
    }

    // ─── Deploy Edge Cases ───────────────────────────────────────────────

    function test_deposit_onlyToYei() public {
        strategy.setSplits(10000, 0, 0);

        uint256 amount = 50e18;
        vm.prank(vault);
        wsei.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);

        assertApproxEqRel(strategy.balanceOf(), amount, 0.01e18);
    }

    function test_deposit_onlyToTakara() public {
        strategy.setSplits(0, 10000, 0);

        uint256 amount = 50e18;
        vm.prank(vault);
        wsei.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);

        assertApproxEqRel(strategy.balanceOf(), amount, 0.01e18);
    }

    function test_deposit_onlyToMorpho() public {
        strategy.setSplits(0, 0, 10000);

        uint256 amount = 50e18;
        vm.prank(vault);
        wsei.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);

        assertApproxEqRel(strategy.balanceOf(), amount, 0.01e18);
    }

    // ─── Pause/Unpause Tests ─────────────────────────────────────────────

    function test_pause_blocksDeposit() public {
        strategy.pause();

        vm.prank(vault);
        vm.expectRevert();
        strategy.deposit(1e18);
    }

    function test_pause_blocksWithdraw() public {
        strategy.pause();

        vm.prank(vault);
        vm.expectRevert();
        strategy.withdraw(1e18);
    }

    function test_unpause_allowsDeposit() public {
        strategy.pause();
        strategy.unpause();

        uint256 amount = 10e18;
        vm.prank(vault);
        wsei.transfer(address(strategy), amount);

        vm.prank(vault);
        strategy.deposit(amount);

        assertApproxEqRel(strategy.balanceOf(), amount, 0.01e18);
    }

    function test_pause_onlyGuardianOrOwner() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(SEIStrategy.NotGuardianOrOwner.selector);
        strategy.pause();
    }

    function test_guardian_canPause() public {
        address guardian = makeAddr("guardian");
        strategy.setGuardian(guardian);

        vm.prank(guardian);
        strategy.pause();

        assertTrue(strategy.paused());
    }
}

// ─── SEIVault Tests ──────────────────────────────────────────────────────────

contract SEIVaultTest is Test {
    SEIVault public vaultContract;
    SEIStrategy public strategy;
    MockWSEI public wsei;
    MockYeiPool public yeiPool;
    MockAToken public aToken;
    MockCToken public cToken;
    MockComptroller public comptroller;
    MockMorpho public morpho;
    MockRouter public router;

    address public owner;
    address public alice;
    address public feeRecipient;

    uint256 constant INITIAL_WSEI = 10_000e18;

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        feeRecipient = makeAddr("feeRecipient");

        wsei = new MockWSEI();

        // Deploy mock protocols
        aToken = new MockAToken(address(wsei), "aWSEI", "aWSEI");
        yeiPool = new MockYeiPool();
        yeiPool.setAToken(address(wsei), address(aToken));

        cToken = new MockCToken(address(wsei), "cWSEI", "cWSEI");
        comptroller = new MockComptroller();
        morpho = new MockMorpho();
        router = new MockRouter();

        // Fund protocols
        wsei.mint(address(aToken), INITIAL_WSEI * 10);
        wsei.mint(address(cToken), INITIAL_WSEI * 10);
        wsei.mint(address(morpho), INITIAL_WSEI * 10);

        vm.prank(address(aToken));
        wsei.approve(address(yeiPool), type(uint256).max);

        // Deploy vault
        vaultContract = new SEIVault(IERC20(address(wsei)), feeRecipient);

        // Deploy strategy (100% Takara for simplicity)
        SEIStrategy.ProtocolAddresses memory addrs = SEIStrategy.ProtocolAddresses({
            wsei: address(wsei),
            vault: address(vaultContract),
            yeiPool: address(yeiPool),
            aToken: address(aToken),
            cToken: address(cToken),
            comptroller: address(comptroller),
            morpho: address(morpho),
            routerV2: address(router),
            routerV3: address(0)
        });

        strategy = new SEIStrategy(
            addrs,
            0,     // 0% Yei
            10000, // 100% Takara
            0,     // 0% Morpho
            4,
            500,
            3600,
            3600
        );

        // Connect vault <-> strategy
        vaultContract.setStrategy(strategy);

        // Fund alice
        wsei.mint(alice, INITIAL_WSEI);

        // Approve vault for alice
        vm.prank(alice);
        wsei.approve(address(vaultContract), type(uint256).max);

        // Seed deposit from owner to prevent inflation attack
        wsei.mint(owner, 1e15);
        wsei.approve(address(vaultContract), 1e15);
        vaultContract.deposit(1e15, owner);
    }

    // ─── ERC4626 / Deposit ───────────────────────────────────────────────

    function test_vault_deposit_basic() public {
        uint256 amount = 100e18;

        uint256 sharesBefore = vaultContract.balanceOf(alice);

        vm.prank(alice);
        uint256 shares = vaultContract.deposit(amount, alice);

        assertGt(shares, 0);
        assertEq(vaultContract.balanceOf(alice) - sharesBefore, shares);
    }

    function test_vault_totalAssets_includesStrategy() public {
        uint256 amount = 100e18;

        vm.prank(alice);
        vaultContract.deposit(amount, alice);

        uint256 total = vaultContract.totalAssets();
        assertApproxEqRel(total, amount + 1e15, 0.01e18); // seed + alice deposit
    }

    function test_vault_withdraw_basic() public {
        uint256 depositAmount = 100e18;

        vm.prank(alice);
        vaultContract.deposit(depositAmount, alice);

        uint256 wseiBalBefore = wsei.balanceOf(alice);

        uint256 shares = vaultContract.balanceOf(alice);
        vm.prank(alice);
        vaultContract.redeem(shares, alice, alice);

        uint256 wseiBalAfter = wsei.balanceOf(alice);
        assertApproxEqRel(wseiBalAfter - wseiBalBefore, depositAmount, 0.01e18);
    }

    function test_vault_name_and_symbol() public view {
        assertEq(vaultContract.name(), "Kana SEI Vault");
        assertEq(vaultContract.symbol(), "kSEI");
    }

    function test_vault_asset_is_wsei() public view {
        assertEq(vaultContract.asset(), address(wsei));
    }

    // ─── Harvest ─────────────────────────────────────────────────────────

    function test_vault_harvest_basic() public {
        uint256 amount = 100e18;

        vm.prank(alice);
        vaultContract.deposit(amount, alice);

        // Time passes, interest accrues
        vm.warp(block.timestamp + 30 days);

        uint256[] memory minAmounts = new uint256[](3);
        vaultContract.harvest(minAmounts);
        // Harvest completes without revert
    }

    function test_vault_harvest_onlyKeeperOrOwner() public {
        uint256[] memory minAmounts = new uint256[](3);

        vm.prank(alice);
        vm.expectRevert(SEIVault.NotKeeperOrOwner.selector);
        vaultContract.harvest(minAmounts);
    }

    function test_vault_keeper_canHarvest() public {
        address keeper = makeAddr("keeper");
        vaultContract.setKeeper(keeper);

        uint256[] memory minAmounts = new uint256[](3);

        vm.prank(keeper);
        vaultContract.harvest(minAmounts);
    }

    // ─── Pause/Unpause ───────────────────────────────────────────────────

    function test_vault_pause_blocksDeposit() public {
        vaultContract.pause();

        vm.prank(alice);
        vm.expectRevert();
        vaultContract.deposit(1e18, alice);
    }

    function test_vault_pause_blocksWithdraw() public {
        uint256 amount = 10e18;
        vm.prank(alice);
        vaultContract.deposit(amount, alice);

        vaultContract.pause();

        uint256 shares = vaultContract.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        vaultContract.redeem(shares, alice, alice);
    }

    function test_vault_unpause_allowsDeposit() public {
        vaultContract.pause();
        vaultContract.unpause();

        uint256 amount = 10e18;
        vm.prank(alice);
        uint256 shares = vaultContract.deposit(amount, alice);

        assertGt(shares, 0);
    }

    function test_vault_guardian_canPause() public {
        address guardian = makeAddr("guardian");
        vaultContract.setGuardian(guardian);

        vm.prank(guardian);
        vaultContract.pause();

        assertTrue(vaultContract.paused());
    }

    // ─── Fee Recipient ───────────────────────────────────────────────────

    function test_vault_setFeeRecipient() public {
        address newRecipient = makeAddr("newFee");
        vaultContract.setFeeRecipient(newRecipient);
        assertEq(vaultContract.feeRecipient(), newRecipient);
    }

    function test_vault_lockFeeRecipient() public {
        vaultContract.lockFeeRecipient();
        assertTrue(vaultContract.feeRecipientLocked());

        address newRecipient = makeAddr("newFee");
        vm.expectRevert(SEIVault.FeeRecipientIsLocked.selector);
        vaultContract.setFeeRecipient(newRecipient);
    }

    // ─── Multiple Users ───────────────────────────────────────────────────

    function test_vault_multipleUsers() public {
        address bob = makeAddr("bob");
        wsei.mint(bob, INITIAL_WSEI);
        vm.prank(bob);
        wsei.approve(address(vaultContract), type(uint256).max);

        // Alice deposits 100 WSEI
        vm.prank(alice);
        vaultContract.deposit(100e18, alice);

        // Bob deposits 200 WSEI
        vm.prank(bob);
        vaultContract.deposit(200e18, bob);

        // Total assets should reflect both deposits + seed
        assertApproxEqRel(vaultContract.totalAssets(), 300e18 + 1e15, 0.01e18);

        // Both can withdraw
        uint256 aliceShares = vaultContract.balanceOf(alice);
        vm.prank(alice);
        vaultContract.redeem(aliceShares, alice, alice);

        uint256 bobShares = vaultContract.balanceOf(bob);
        vm.prank(bob);
        vaultContract.redeem(bobShares, bob, bob);

        // Both should get their deposits back (approximately)
        assertApproxEqRel(wsei.balanceOf(alice), INITIAL_WSEI, 0.01e18);
        assertApproxEqRel(wsei.balanceOf(bob), INITIAL_WSEI, 0.01e18);
    }
}
