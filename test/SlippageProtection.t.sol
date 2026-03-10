// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {MockAToken, MockYeiPool, MockCToken, MockComptroller, MockMorpho, MockRouter} from "../src/mocks/MockLendingProtocols.sol";
import {IMerklDistributor} from "../src/interfaces/external/IMerklDistributor.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ─── Test Helpers ────────────────────────────────────────────────────────────

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract MockRewardToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice Router that returns less than input (simulates bad price / MEV)
contract BadRouter {
    using SafeERC20 for IERC20;

    uint256 public slippageBps;

    constructor(uint256 _slippageBps) {
        slippageBps = _slippageBps;
    }

    function setSlippage(uint256 _bps) external {
        slippageBps = _bps;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(path.length >= 2, "Invalid path");
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = (amountIn * (10000 - slippageBps)) / 10000;
        require(amountOut >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[path.length - 1]).safeTransfer(to, amountOut);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountOut;
    }
}

/// @notice Mock Merkl distributor that mints reward tokens on claim
contract MockMerklDistributor is IMerklDistributor {
    mapping(address => uint256) public tokenAmounts;

    function setClaimAmount(address token, uint256 amount) external {
        tokenAmounts[token] = amount;
    }

    function claim(
        address user,
        address[] calldata tokens,
        uint256[] calldata,
        bytes32[][] calldata
    ) external override {
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amt = tokenAmounts[tokens[i]];
            if (amt > 0) {
                MockRewardToken(tokens[i]).mint(user, amt);
            }
        }
    }
}

// ─── Slippage Protection Tests ───────────────────────────────────────────────

contract SlippageProtectionTest is Test {
    USDCStrategy public strategy;
    MockUSDC public usdc;
    MockYeiPool public yeiPool;
    MockAToken public aToken;
    MockCToken public cToken;
    MockComptroller public comptroller;
    MockMorpho public morpho;
    MockRewardToken public takaraReward;
    MockRewardToken public morphoReward;
    BadRouter public badRouter;
    MockMerklDistributor public merklDistributor;

    address public vault;
    address public owner;
    address public keeperAddr;

    function setUp() public {
        owner = address(this);
        vault = makeAddr("vault");
        keeperAddr = makeAddr("keeper");

        usdc = new MockUSDC();
        takaraReward = new MockRewardToken("Takara Reward", "TAKA");
        morphoReward = new MockRewardToken("Morpho Reward", "MORPHO");

        aToken = new MockAToken(address(usdc), "aUSDC", "aUSDC");
        yeiPool = new MockYeiPool();
        yeiPool.setAToken(address(usdc), address(aToken));
        cToken = new MockCToken(address(usdc), "cUSDC", "cUSDC");
        comptroller = new MockComptroller();
        comptroller.setCompToken(address(takaraReward));
        morpho = new MockMorpho();

        badRouter = new BadRouter(200); // 2% slippage
        merklDistributor = new MockMerklDistributor();

        usdc.mint(address(aToken), 10_000_000e6);
        usdc.mint(address(cToken), 10_000_000e6);
        usdc.mint(address(morpho), 10_000_000e6);
        usdc.mint(address(badRouter), 10_000_000e6);

        vm.prank(address(aToken));
        usdc.approve(address(yeiPool), type(uint256).max);

        USDCStrategy.ProtocolAddresses memory addrs = USDCStrategy.ProtocolAddresses({
            usdc: address(usdc),
            vault: vault,
            yeiPool: address(yeiPool),
            aToken: address(aToken),
            cToken: address(cToken),
            comptroller: address(comptroller),
            morpho: address(morpho),
            routerV2: address(badRouter),
            routerV3: address(0)
        });

        strategy = new USDCStrategy(addrs, 3334, 3333, 3333, 4, 500, 3600, 3600);
        strategy.setKeeper(keeperAddr);

        address[] memory takaraPath = new address[](2);
        takaraPath[0] = address(takaraReward);
        takaraPath[1] = address(usdc);
        strategy.setTakaraRewardConfig(address(takaraReward), takaraPath);

        address[] memory morphoPath = new address[](2);
        morphoPath[0] = address(morphoReward);
        morphoPath[1] = address(usdc);
        strategy.setMorphoRewardConfig(address(morphoReward), morphoPath);

        strategy.setMerklDistributor(address(merklDistributor));

        usdc.mint(vault, 1_000_000e6);
        vm.prank(vault);
        usdc.approve(address(strategy), type(uint256).max);
    }

    function _deposit(uint256 amount) internal {
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
    }

    // ═══════════════════════════════════════════════════════════════════
    // harvest with slippage (called via vault)
    // ═══════════════════════════════════════════════════════════════════

    function test_harvest_passesWithReasonableMin() public {
        _deposit(100_000e6);
        takaraReward.mint(address(strategy), 1000e6);

        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[0] = 0;     // Yei
        minAmounts[1] = 970e6; // Takara
        minAmounts[2] = 0;     // Morpho

        vm.prank(vault);
        strategy.harvest(minAmounts);
    }

    function test_harvest_revertsOnHighSlippage() public {
        _deposit(100_000e6);
        takaraReward.mint(address(strategy), 1000e6);

        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[0] = 0;     // Yei
        minAmounts[1] = 990e6; // Takara
        minAmounts[2] = 0;     // Morpho

        vm.prank(vault);
        vm.expectRevert("INSUFFICIENT_OUTPUT_AMOUNT");
        strategy.harvest(minAmounts);
    }

    function test_harvest_morphoRevertOnHighSlippage() public {
        _deposit(100_000e6);
        morphoReward.mint(address(strategy), 1000e6);

        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[0] = 0;     // Yei
        minAmounts[1] = 0;     // Takara
        minAmounts[2] = 990e6; // Morpho

        vm.prank(vault);
        vm.expectRevert("INSUFFICIENT_OUTPUT_AMOUNT");
        strategy.harvest(minAmounts);
    }

    function test_harvest_bothRewards() public {
        _deposit(100_000e6);
        takaraReward.mint(address(strategy), 500e6);
        morphoReward.mint(address(strategy), 300e6);

        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[0] = 0;     // Yei
        minAmounts[1] = 480e6; // Takara
        minAmounts[2] = 290e6; // Morpho

        vm.prank(vault);
        strategy.harvest(minAmounts);
    }

    function test_harvest_zeroMins_revertsWithSlippageCap() public {
        // Zero minAmounts now always revert when there are rewards to swap (slippage enforcement)
        _deposit(100_000e6);
        takaraReward.mint(address(strategy), 1000e6);

        uint256[] memory minAmounts = new uint256[](3);

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(
            USDCStrategy.SlippageExceedsCap.selector,
            0,
            950e6
        ));
        strategy.harvest(minAmounts);
    }

    function test_harvest_onlyVault() public {
        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[0] = 100;
        minAmounts[1] = 100;
        minAmounts[2] = 100;

        vm.expectRevert(USDCStrategy.OnlyVault.selector);
        strategy.harvest(minAmounts);
    }

    function test_harvest_noRewardsNoRevert() public {
        _deposit(50_000e6);
        uint256[] memory minAmounts = new uint256[](3);

        vm.prank(vault);
        uint256 profit = strategy.harvest(minAmounts);
        assertEq(profit, 0);
    }

    function test_harvest_sandwichAttackReverts() public {
        _deposit(100_000e6);
        takaraReward.mint(address(strategy), 10_000e6);
        badRouter.setSlippage(2000);

        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[0] = 0;      // Yei
        minAmounts[1] = 9900e6; // Takara
        minAmounts[2] = 0;      // Morpho

        vm.prank(vault);
        vm.expectRevert("INSUFFICIENT_OUTPUT_AMOUNT");
        strategy.harvest(minAmounts);
    }

    function test_harvest_returnsProfit() public {
        _deposit(100_000e6);
        takaraReward.mint(address(strategy), 5000e6);

        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[0] = 0;      // Yei
        minAmounts[1] = 4800e6; // Takara
        minAmounts[2] = 0;      // Morpho

        vm.prank(vault);
        uint256 profit = strategy.harvest(minAmounts);
        assertEq(profit, 4900e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    // claimMorphoRewards
    // ═══════════════════════════════════════════════════════════════════

    function test_claimMorphoRewards_passesWithReasonableMin() public {
        _deposit(100_000e6);
        merklDistributor.setClaimAmount(address(morphoReward), 1000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(morphoReward);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        uint256[] memory minOuts = new uint256[](1);
        minOuts[0] = 970e6;

        vm.prank(keeperAddr);
        strategy.claimMorphoRewards(tokens, amounts, proofs, minOuts);
    }

    function test_claimMorphoRewards_revertsOnHighSlippage() public {
        _deposit(100_000e6);
        merklDistributor.setClaimAmount(address(morphoReward), 1000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(morphoReward);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        uint256[] memory minOuts = new uint256[](1);
        minOuts[0] = 990e6;

        vm.prank(keeperAddr);
        vm.expectRevert("INSUFFICIENT_OUTPUT_AMOUNT");
        strategy.claimMorphoRewards(tokens, amounts, proofs, minOuts);
    }

    function test_claimMorphoRewards_multipleTokens() public {
        _deposit(100_000e6);
        MockRewardToken rewardB = new MockRewardToken("Reward B", "RWB");
        usdc.mint(address(badRouter), 1_000_000e6);

        merklDistributor.setClaimAmount(address(morphoReward), 500e6);
        merklDistributor.setClaimAmount(address(rewardB), 300e6);

        address[] memory tokens = new address[](2);
        tokens[0] = address(morphoReward);
        tokens[1] = address(rewardB);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 500e6;
        amounts[1] = 300e6;
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](0);
        proofs[1] = new bytes32[](0);
        uint256[] memory minOuts = new uint256[](2);
        minOuts[0] = 480e6;
        minOuts[1] = 290e6;

        vm.prank(keeperAddr);
        strategy.claimMorphoRewards(tokens, amounts, proofs, minOuts);
    }

    function test_claimMorphoRewards_skipsUSDC() public {
        _deposit(100_000e6);
        merklDistributor.setClaimAmount(address(usdc), 1000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        uint256[] memory minOuts = new uint256[](1);
        minOuts[0] = 1000e6;

        uint256 balBefore = strategy.balanceOf();
        vm.prank(keeperAddr);
        strategy.claimMorphoRewards(tokens, amounts, proofs, minOuts);
        assertGe(strategy.balanceOf(), balBefore);
    }

    /// @notice L-4 fix: empty minAmountsOut defaults to 0 which now reverts (slippage validation)
    function test_claimMorphoRewards_emptyMinAmountsRevertsWithSlippageCap() public {
        _deposit(100_000e6);
        merklDistributor.setClaimAmount(address(morphoReward), 1000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(morphoReward);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        uint256[] memory minOuts = new uint256[](0); // defaults to 0, now rejected

        vm.prank(keeperAddr);
        vm.expectRevert(); // SlippageExceedsCap — keeper cannot bypass slippage protection
        strategy.claimMorphoRewards(tokens, amounts, proofs, minOuts);
    }

    function test_claimMorphoRewards_noDistributorSetIsNoop() public {
        USDCStrategy.ProtocolAddresses memory addrs = USDCStrategy.ProtocolAddresses({
            usdc: address(usdc),
            vault: vault,
            yeiPool: address(yeiPool),
            aToken: address(aToken),
            cToken: address(cToken),
            comptroller: address(comptroller),
            morpho: address(morpho),
            routerV2: address(badRouter),
            routerV3: address(0)
        });
        USDCStrategy strat2 = new USDCStrategy(addrs, 3334, 3333, 3333, 4, 500, 3600, 3600);

        address[] memory tokens = new address[](1);
        tokens[0] = address(morphoReward);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        uint256[] memory minOuts = new uint256[](1);
        minOuts[0] = 990e6;

        // Owner can call (no keeper set on strat2)
        strat2.claimMorphoRewards(tokens, amounts, proofs, minOuts);
    }

    function test_claimMorphoRewards_onlyKeeperOrOwner() public {
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32[][] memory proofs = new bytes32[][](0);
        uint256[] memory minOuts = new uint256[](0);

        vm.prank(vault);
        vm.expectRevert(USDCStrategy.NotKeeperOrOwner.selector);
        strategy.claimMorphoRewards(tokens, amounts, proofs, minOuts);
    }

    // ═══════════════════════════════════════════════════════════════════
    // setMerklDistributor
    // ═══════════════════════════════════════════════════════════════════

    function test_setMerklDistributor() public {
        address newDist = makeAddr("newDistributor");
        strategy.setMerklDistributor(newDist);
        assertEq(address(strategy.merklDistributor()), newDist);
    }

    function test_setMerklDistributor_onlyOwner() public {
        vm.prank(vault);
        vm.expectRevert();
        strategy.setMerklDistributor(makeAddr("x"));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Rebalance Cooldown
    // ═══════════════════════════════════════════════════════════════════

    function test_rebalance_respectsCooldown() public {
        _deposit(100_000e6);

        vm.prank(keeperAddr);
        strategy.rebalance();

        // Try again immediately — should fail
        vm.prank(keeperAddr);
        vm.expectRevert(abi.encodeWithSelector(
            USDCStrategy.RebalanceCooldownActive.selector,
            block.timestamp + 3600
        ));
        strategy.rebalance();

        // Warp past cooldown
        vm.warp(block.timestamp + 3601);
        vm.prank(keeperAddr);
        strategy.rebalance(); // should succeed
    }

    function test_rebalance_ownerCanBypassNothing() public {
        _deposit(100_000e6);

        // Owner is also subject to cooldown
        strategy.rebalance();

        vm.expectRevert(abi.encodeWithSelector(
            USDCStrategy.RebalanceCooldownActive.selector,
            block.timestamp + 3600
        ));
        strategy.rebalance();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Keeper Role Separation
    // ═══════════════════════════════════════════════════════════════════

    function test_keeper_canSetSplits() public {
        vm.prank(keeperAddr);
        strategy.setSplits(5000, 3000, 2000);
        assertEq(strategy.splitYei(), 5000);
    }

    function test_keeper_canSetActiveRouter() public {
        vm.prank(keeperAddr);
        strategy.setActiveRouter(USDCStrategy.RouterType.V3);
    }

    function test_keeper_cannotSetRouterAddress() public {
        vm.prank(keeperAddr);
        vm.expectRevert();
        strategy.setRouterV2(makeAddr("evil"));
    }

    function test_keeper_cannotRescueTokens() public {
        vm.prank(keeperAddr);
        vm.expectRevert();
        strategy.rescueToken(address(takaraReward), 100);
    }

    function test_keeper_cannotSetVault() public {
        vm.prank(keeperAddr);
        vm.expectRevert();
        strategy.setVault(makeAddr("evil"));
    }

    function test_revokeKeeper() public {
        strategy.revokeKeeper();
        assertEq(strategy.keeper(), address(0));

        vm.prank(keeperAddr);
        vm.expectRevert(USDCStrategy.NotKeeperOrOwner.selector);
        strategy.setSplits(5000, 3000, 2000);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Max Slippage Cap
    // ═══════════════════════════════════════════════════════════════════

    function test_maxSlippage_cannotExceedCeiling() public {
        vm.expectRevert(USDCStrategy.SlippageTooHigh.selector);
        strategy.setMaxSlippage(1001); // > 10%
    }

    function test_maxSlippage_ownerCanUpdate() public {
        strategy.setMaxSlippage(300); // 3%
        assertEq(strategy.maxSlippageBps(), 300);
    }

    function test_maxSlippage_keeperCannotUpdate() public {
        vm.prank(keeperAddr);
        vm.expectRevert();
        strategy.setMaxSlippage(300);
    }

    // ═══════════════════════════════════════════════════════════════════
    // On-chain slippage cap enforcement
    // ═══════════════════════════════════════════════════════════════════

    function test_slippageCap_rejectsLowMinOut() public {
        // maxSlippageBps = 500 (5%), so for 1000 reward tokens,
        // minAmountOut must be >= 950. Passing 900 should revert.
        _deposit(100_000e6);
        takaraReward.mint(address(strategy), 1000e6);

        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[0] = 0;     // Yei
        minAmounts[1] = 900e6; // Takara
        minAmounts[2] = 0;     // Morpho

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(
            USDCStrategy.SlippageExceedsCap.selector,
            900e6,  // minAmountOut provided
            950e6   // minRequired (1000 * 9500 / 10000)
        ));
        strategy.harvest(minAmounts);
    }

    function test_slippageCap_acceptsAboveThreshold() public {
        // minAmountOut = 960 >= 950 threshold, should pass
        _deposit(100_000e6);
        takaraReward.mint(address(strategy), 1000e6);

        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[0] = 0;     // Yei
        minAmounts[1] = 960e6; // Takara
        minAmounts[2] = 0;     // Morpho

        vm.prank(vault);
        strategy.harvest(minAmounts);
    }

    function test_slippageCap_zeroMinAlwaysReverts() public {
        // Zero minAmountOut is never valid when rewards exist — always reverts with SlippageExceedsCap
        _deposit(100_000e6);
        takaraReward.mint(address(strategy), 1000e6);

        uint256[] memory minAmounts = new uint256[](3);

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(
            USDCStrategy.SlippageExceedsCap.selector,
            0,
            950e6
        ));
        strategy.harvest(minAmounts);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Splits cooldown
    // ═══════════════════════════════════════════════════════════════════

    function test_splitsCooldown_preventsRapidChanges() public {
        vm.prank(keeperAddr);
        strategy.setSplits(5000, 3000, 2000);

        // Try again immediately — should fail
        vm.prank(keeperAddr);
        vm.expectRevert(abi.encodeWithSelector(
            USDCStrategy.SplitsCooldownActive.selector,
            block.timestamp + 3600
        ));
        strategy.setSplits(8000, 1000, 1000);
    }

    function test_splitsCooldown_allowsAfterExpiry() public {
        vm.prank(keeperAddr);
        strategy.setSplits(5000, 3000, 2000);

        vm.warp(block.timestamp + 3601);

        vm.prank(keeperAddr);
        strategy.setSplits(8000, 1000, 1000); // should succeed
        assertEq(strategy.splitYei(), 8000);
    }

    function test_splitsCooldown_ownerCanSetCooldown() public {
        strategy.setSplitsCooldown(7200);
        assertEq(strategy.splitsCooldown(), 7200);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Vault integration
    // ═══════════════════════════════════════════════════════════════════

    function test_vault_harvest_integration() public {
        KanaVault kanaVault = new KanaVault(
            IERC20(address(usdc)),
            address(this)
        );

        USDCStrategy.ProtocolAddresses memory addrs = USDCStrategy.ProtocolAddresses({
            usdc: address(usdc),
            vault: address(kanaVault),
            yeiPool: address(yeiPool),
            aToken: address(aToken),
            cToken: address(cToken),
            comptroller: address(comptroller),
            morpho: address(morpho),
            routerV2: address(badRouter),
            routerV3: address(0)
        });
        USDCStrategy strat = new USDCStrategy(addrs, 3334, 3333, 3333, 4, 500, 3600, 3600);

        address[] memory takaraPath = new address[](2);
        takaraPath[0] = address(takaraReward);
        takaraPath[1] = address(usdc);
        strat.setTakaraRewardConfig(address(takaraReward), takaraPath);

        kanaVault.setStrategy(strat);
        kanaVault.setKeeper(keeperAddr);

        usdc.mint(address(this), 100_000e6);
        usdc.approve(address(kanaVault), 100_000e6);
        kanaVault.deposit(100_000e6, address(this));

        takaraReward.mint(address(strat), 5000e6);

        // Keeper harvests through vault
        vm.prank(keeperAddr);
        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[1] = 4800e6; // Takara
        kanaVault.harvest(minAmounts);
    }

    function test_vault_harvest_revertsOnBadPrice() public {
        KanaVault kanaVault = new KanaVault(
            IERC20(address(usdc)),
            address(this)
        );

        USDCStrategy.ProtocolAddresses memory addrs = USDCStrategy.ProtocolAddresses({
            usdc: address(usdc),
            vault: address(kanaVault),
            yeiPool: address(yeiPool),
            aToken: address(aToken),
            cToken: address(cToken),
            comptroller: address(comptroller),
            morpho: address(morpho),
            routerV2: address(badRouter),
            routerV3: address(0)
        });
        USDCStrategy strat = new USDCStrategy(addrs, 3334, 3333, 3333, 4, 500, 3600, 3600);

        address[] memory takaraPath = new address[](2);
        takaraPath[0] = address(takaraReward);
        takaraPath[1] = address(usdc);
        strat.setTakaraRewardConfig(address(takaraReward), takaraPath);

        kanaVault.setStrategy(strat);

        usdc.mint(address(this), 100_000e6);
        usdc.approve(address(kanaVault), 100_000e6);
        kanaVault.deposit(100_000e6, address(this));

        takaraReward.mint(address(strat), 5000e6);
        badRouter.setSlippage(2000);

        vm.expectRevert("INSUFFICIENT_OUTPUT_AMOUNT");
        uint256[] memory minAmounts2 = new uint256[](3);
        minAmounts2[1] = 4950e6; // Takara
        kanaVault.harvest(minAmounts2);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Fuzz
    // ═══════════════════════════════════════════════════════════════════

    function test_fuzz_slippageProtection(uint256 slippageBps, uint256 rewardAmt) public {
        slippageBps = bound(slippageBps, 0, 5000);
        rewardAmt = bound(rewardAmt, 1e6, 1_000_000e6);

        _deposit(100_000e6);
        badRouter.setSlippage(slippageBps);
        takaraReward.mint(address(strategy), rewardAmt);

        uint256 expectedOut = (rewardAmt * (10000 - slippageBps)) / 10000;
        uint256 minOut = (rewardAmt * 99) / 100;

        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[0] = 0;     // Yei
        minAmounts[1] = minOut; // Takara
        minAmounts[2] = 0;     // Morpho

        if (expectedOut >= minOut) {
            vm.prank(vault);
            strategy.harvest(minAmounts);
        } else {
            vm.prank(vault);
            vm.expectRevert("INSUFFICIENT_OUTPUT_AMOUNT");
            strategy.harvest(minAmounts);
        }
    }
}
