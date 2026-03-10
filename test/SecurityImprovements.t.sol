// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MockAToken, MockYeiPool, MockCToken, MockComptroller, MockMorpho, MockRouter} from "../src/mocks/MockLendingProtocols.sol";
import {IMerklDistributor} from "../src/interfaces/external/IMerklDistributor.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";

/// @title SecurityImprovementsTest
/// @notice Comprehensive tests for Pausable + Guardian + rescueToken improvements
contract SecurityImprovementsTest is Test {
    KanaVault public vault;
    USDCStrategy public strategy;
    MockERC20 public usdc;
    MockYeiPool public yeiPool;
    MockAToken public aToken;
    MockCToken public cToken;
    MockComptroller public comptroller;
    MockMorpho public morpho;
    MockRouter public router;

    address public owner;
    address public feeRecipient;
    address public keeper;
    address public guardian;
    address public alice;
    address public bob;

    function setUp() public {
        owner = address(this);
        feeRecipient = makeAddr("feeRecipient");
        keeper = makeAddr("keeper");
        guardian = makeAddr("guardian");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy USDC
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy mock protocols
        aToken = new MockAToken(address(usdc), "aUSDC", "aUSDC");
        yeiPool = new MockYeiPool();
        yeiPool.setAToken(address(usdc), address(aToken));
        cToken = new MockCToken(address(usdc), "cUSDC", "cUSDC");
        comptroller = new MockComptroller();
        morpho = new MockMorpho();
        router = new MockRouter();

        // Fund protocols
        usdc.mint(address(aToken), 10_000_000e6);
        usdc.mint(address(cToken), 10_000_000e6);
        usdc.mint(address(morpho), 10_000_000e6);
        usdc.mint(address(router), 10_000_000e6);

        vm.prank(address(aToken));
        usdc.approve(address(yeiPool), type(uint256).max);

        // Deploy vault
        vault = new KanaVault(IERC20(address(usdc)), feeRecipient);

        // Deploy strategy
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

        // Setup vault
        vault.setStrategy(strategy);
        vault.setKeeper(keeper);
        vault.setGuardian(guardian);

        // Setup strategy
        strategy.setKeeper(keeper);
        strategy.setGuardian(guardian);

        // Fund users
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════
    // PAUSABLE + GUARDIAN: VAULT TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_vault_setGuardian() public {
        address newGuardian = makeAddr("newGuardian");
        vault.setGuardian(newGuardian);
        assertEq(vault.guardian(), newGuardian);
    }

    function test_vault_setGuardian_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setGuardian(alice);
    }

    function test_vault_guardian_canPause() public {
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_vault_guardian_cannotUnpause() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(guardian);
        vm.expectRevert();
        vault.unpause();
    }

    function test_vault_owner_canPause() public {
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_vault_owner_canUnpause() public {
        vault.pause();
        assertTrue(vault.paused());

        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_vault_paused_blocksDeposit() public {
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(1000e6, alice);
    }

    function test_vault_paused_blocksWithdraw() public {
        // Deposit first
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Pause
        vault.pause();

        // Try withdraw
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(1000e6, alice, alice);
    }

    function test_vault_paused_blocksHarvest() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vault.pause();

        vm.prank(keeper);
        vm.expectRevert();
        vault.harvest(new uint256[](3));
    }

    function test_vault_paused_blocksSetStrategy() public {
        MockStrategy newStrategy = new MockStrategy(address(usdc));
        
        vault.pause();

        vm.expectRevert();
        vault.setStrategy(newStrategy);
    }

    function test_vault_unpause_allowsOperations() public {
        vault.pause();
        vault.unpause();

        vm.prank(alice);
        vault.deposit(5000e6, alice);

        assertEq(vault.totalAssets(), 5000e6);
    }

    function test_vault_randomUser_cannotPause() public {
        vm.prank(alice);
        vm.expectRevert(KanaVault.NotGuardianOrOwner.selector);
        vault.pause();
    }

    function test_vault_keeper_cannotPause() public {
        vm.prank(keeper);
        vm.expectRevert(KanaVault.NotGuardianOrOwner.selector);
        vault.pause();
    }

    // ═══════════════════════════════════════════════════════════════════
    // PAUSABLE + GUARDIAN: STRATEGY TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_strategy_setGuardian() public {
        address newGuardian = makeAddr("newGuardian");
        strategy.setGuardian(newGuardian);
        assertEq(strategy.guardian(), newGuardian);
    }

    function test_strategy_setGuardian_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        strategy.setGuardian(alice);
    }

    function test_strategy_guardian_canPause() public {
        vm.prank(guardian);
        strategy.pause();
        assertTrue(strategy.paused());
    }

    function test_strategy_guardian_cannotUnpause() public {
        vm.prank(guardian);
        strategy.pause();

        vm.prank(guardian);
        vm.expectRevert();
        strategy.unpause();
    }

    function test_strategy_owner_canPause() public {
        strategy.pause();
        assertTrue(strategy.paused());
    }

    function test_strategy_owner_canUnpause() public {
        strategy.pause();
        assertTrue(strategy.paused());

        strategy.unpause();
        assertFalse(strategy.paused());
    }

    function test_strategy_paused_blocksDeposit() public {
        strategy.pause();

        usdc.mint(address(vault), 10_000e6);
        vm.prank(address(vault));
        usdc.transfer(address(strategy), 1000e6);

        vm.prank(address(vault));
        vm.expectRevert();
        strategy.deposit(1000e6);
    }

    function test_strategy_paused_blocksWithdraw() public {
        usdc.mint(address(vault), 10_000e6);
        vm.prank(address(vault));
        usdc.transfer(address(strategy), 10_000e6);
        vm.prank(address(vault));
        strategy.deposit(10_000e6);

        strategy.pause();

        vm.prank(address(vault));
        vm.expectRevert();
        strategy.withdraw(1000e6);
    }

    function test_strategy_paused_blocksHarvest() public {
        usdc.mint(address(vault), 10_000e6);
        vm.prank(address(vault));
        usdc.transfer(address(strategy), 10_000e6);
        vm.prank(address(vault));
        strategy.deposit(10_000e6);

        strategy.pause();

        uint256[] memory minAmounts = new uint256[](3);
        vm.prank(address(vault));
        vm.expectRevert();
        strategy.harvest(minAmounts);
    }

    function test_strategy_paused_blocksRebalance() public {
        strategy.pause();

        vm.prank(keeper);
        vm.expectRevert();
        strategy.rebalance();
    }

    function test_strategy_paused_blocksSetSplits() public {
        strategy.pause();

        vm.prank(keeper);
        vm.expectRevert();
        strategy.setSplits(5000, 3000, 2000);
    }

    function test_strategy_randomUser_cannotPause() public {
        vm.prank(alice);
        vm.expectRevert(USDCStrategy.NotGuardianOrOwner.selector);
        strategy.pause();
    }

    function test_strategy_keeper_cannotPause() public {
        vm.prank(keeper);
        vm.expectRevert(USDCStrategy.NotGuardianOrOwner.selector);
        strategy.pause();
    }

    // ═══════════════════════════════════════════════════════════════════
    // RESCUE TOKEN: USDC RECOVERY
    // ═══════════════════════════════════════════════════════════════════

    function test_rescueToken_canRescueLooseUSDC() public {
        // Send USDC directly to strategy (not deposited)
        usdc.mint(address(strategy), 5000e6);

        uint256 ownerBalBefore = usdc.balanceOf(owner);

        strategy.rescueToken(address(usdc), 0);

        uint256 ownerBalAfter = usdc.balanceOf(owner);
        assertEq(ownerBalAfter - ownerBalBefore, 5000e6);
    }

    function test_rescueToken_onlyRescuesLooseBalance() public {
        // Deposit to protocols
        usdc.mint(address(vault), 20_000e6);
        vm.prank(address(vault));
        usdc.transfer(address(strategy), 20_000e6);
        vm.prank(address(vault));
        strategy.deposit(20_000e6);

        // Send additional loose USDC
        usdc.mint(address(strategy), 1000e6);

        uint256 balanceBeforeRescue = strategy.balanceOf();
        uint256 ownerBalBefore = usdc.balanceOf(owner);

        // Rescue should only get the 1000e6 loose USDC
        strategy.rescueToken(address(usdc), 999999e6); // Amount param ignored for USDC

        uint256 ownerBalAfter = usdc.balanceOf(owner);
        assertEq(ownerBalAfter - ownerBalBefore, 1000e6, "Should only rescue loose balance");
        
        // Deployed funds should remain untouched (allow 5% tolerance for mock interest accrual)
        assertApproxEqRel(strategy.balanceOf(), balanceBeforeRescue, 0.05e18, "Deployed funds intact");
    }

    function test_rescueToken_noLooseUSDC_noRevert() public {
        // Deposit to protocols (no loose USDC)
        usdc.mint(address(vault), 10_000e6);
        vm.prank(address(vault));
        usdc.transfer(address(strategy), 10_000e6);
        vm.prank(address(vault));
        strategy.deposit(10_000e6);

        uint256 ownerBalBefore = usdc.balanceOf(owner);

        // Should not revert even with no loose balance
        strategy.rescueToken(address(usdc), 0);

        uint256 ownerBalAfter = usdc.balanceOf(owner);
        assertEq(ownerBalAfter, ownerBalBefore, "No transfer if no loose balance");
    }

    function test_rescueToken_nonUSDC_stillWorks() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(address(strategy), 1000e18);

        uint256 ownerBalBefore = randomToken.balanceOf(owner);

        strategy.rescueToken(address(randomToken), 1000e18);

        uint256 ownerBalAfter = randomToken.balanceOf(owner);
        assertEq(ownerBalAfter - ownerBalBefore, 1000e18);
    }

    function test_rescueToken_onlyOwner() public {
        usdc.mint(address(strategy), 1000e6);

        vm.prank(alice);
        vm.expectRevert();
        strategy.rescueToken(address(usdc), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INTEGRATION: PAUSE BOTH VAULT AND STRATEGY
    // ═══════════════════════════════════════════════════════════════════

    function test_integration_pauseBoth_blocksEverything() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Guardian pauses both
        vm.prank(guardian);
        vault.pause();
        vm.prank(guardian);
        strategy.pause();

        // Deposit blocked
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(5000e6, bob);

        // Withdraw blocked
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(1000e6, alice, alice);

        // Harvest blocked
        vm.prank(keeper);
        vm.expectRevert();
        vault.harvest(new uint256[](3));
    }

    function test_integration_unpauseBoth_resumesOperations() public {
        vm.prank(guardian);
        vault.pause();
        vm.prank(guardian);
        strategy.pause();

        // Owner unpauses both
        vault.unpause();
        strategy.unpause();

        // Operations work again
        vm.prank(alice);
        vault.deposit(5000e6, alice);
        assertEq(vault.totalAssets(), 5000e6);

        vm.prank(alice);
        vault.withdraw(2000e6, alice, alice);
        assertApproxEqAbs(vault.totalAssets(), 3000e6, 1);
    }

    // ═══════════════════════════════════════════════════════════════════
    // AUDIT FIX TESTS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice H-2: After setStrategy, old strategy approval is revoked and new strategy is approved
    function test_H2_setStrategy_approvesNewAfterWithdrawingFromOld() public {
        // Fund alice and deposit
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        assertGt(strategy.balanceOf(), 0);

        // Deploy new strategy
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
        USDCStrategy newStrategy = new USDCStrategy(addrs, 3334, 3333, 3333, 4, 500, 3600, 3600);

        vault.setStrategy(newStrategy);

        // Old strategy should have zero approval
        assertEq(IERC20(address(usdc)).allowance(address(vault), address(strategy)), 0);
        // New strategy should have max approval
        assertEq(IERC20(address(usdc)).allowance(address(vault), address(newStrategy)), type(uint256).max);
        // Funds migrated to new strategy
        assertGt(newStrategy.balanceOf(), 0);
    }

    /// @notice M-4: setSplits reverts when more than 3 yield sources exist
    function test_M4_setSplits_revertsWithMoreThan3Sources() public {
        // Use a fresh protocol address so safeIncreaseAllowance doesn't overflow
        MockYeiPool extraPool = new MockYeiPool();
        MockAToken extraAToken = new MockAToken(address(usdc), "aExtra", "aExtra");

        address[] memory emptyPath = new address[](0);
        strategy.addYieldSource(
            USDCStrategy.ProtocolType.Aave,
            false,   // disabled
            0,       // split = 0, total remains 10000
            address(extraPool),
            address(extraAToken),
            address(0),
            address(0),
            emptyPath,
            0
        );

        // setSplits should now revert because yieldSources.length == 4 > 3
        vm.expectRevert(USDCStrategy.TooManyYieldSources.selector);
        vm.prank(keeper);
        strategy.setSplits(5000, 3000, 2000);
    }

    /// @notice L-4: claimMorphoRewards with minAmountsOut = [0] reverts due to slippage validation
    function test_L4_claimMorphoRewards_revertsOnZeroMinAmount() public {
        // Set up reward token
        MockERC20 rewardToken = new MockERC20("Reward", "RWD", 18);
        address[] memory swapPath = new address[](2);
        swapPath[0] = address(rewardToken);
        swapPath[1] = address(usdc);

        // Configure yield source[2] (morpho) with a reward token and swap path
        strategy.setYieldSourceRewardConfig(2, address(rewardToken), swapPath);

        // Set up a mock merkl distributor that transfers reward tokens when claimed
        SimpleMockMerkl merkl = new SimpleMockMerkl(rewardToken);
        strategy.setMerklDistributor(address(merkl));
        rewardToken.mint(address(merkl), 1000e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);

        // minAmountsOut = [0] should revert: _validateSlippage(1000e18, 0) with maxSlippageBps=500
        uint256[] memory minAmountsOut = new uint256[](1);
        minAmountsOut[0] = 0;

        vm.expectRevert(abi.encodeWithSelector(
            USDCStrategy.SlippageExceedsCap.selector,
            0,
            (1000e18 * (10000 - 500)) / 10000
        ));
        vm.prank(keeper);
        strategy.claimMorphoRewards(tokens, amounts, proofs, minAmountsOut);
    }

    /// @notice M-1: harvest must revert when minAmountsOut length != yieldSources length
    function test_M1_harvest_revertsWithWrongMinAmountsLength() public {
        // Strategy has 3 yield sources; pass a 2-element array
        uint256[] memory minAmounts = new uint256[](2);

        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(USDCStrategy.InvalidMinAmountsLength.selector));
        strategy.harvest(minAmounts);
    }
}

/// @notice Minimal merkl distributor mock: just transfers claimed amounts
contract SimpleMockMerkl is IMerklDistributor {
    IERC20 private rewardToken;

    constructor(IERC20 _token) { rewardToken = _token; }

    function claim(
        address user,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata
    ) external override {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(rewardToken)) {
                rewardToken.transfer(user, amounts[i]);
            }
        }
    }
}
