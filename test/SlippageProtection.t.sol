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

    uint256 public slippageBps; // e.g., 500 = 5% slippage

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

        // Return less than input based on slippage
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
    mapping(address => uint256) public tokenAmounts; // how much to mint per claim

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

    function setUp() public {
        owner = address(this);
        vault = makeAddr("vault");

        // Deploy tokens
        usdc = new MockUSDC();
        takaraReward = new MockRewardToken("Takara Reward", "TAKA");
        morphoReward = new MockRewardToken("Morpho Reward", "MORPHO");

        // Deploy protocols
        aToken = new MockAToken(address(usdc), "aUSDC", "aUSDC");
        yeiPool = new MockYeiPool();
        yeiPool.setAToken(address(usdc), address(aToken));
        cToken = new MockCToken(address(usdc), "cUSDC", "cUSDC");
        comptroller = new MockComptroller();
        comptroller.setCompToken(address(takaraReward));
        morpho = new MockMorpho();

        // BadRouter with 2% slippage (normal market conditions)
        badRouter = new BadRouter(200);

        // Merkl distributor
        merklDistributor = new MockMerklDistributor();

        // Fund protocols
        usdc.mint(address(aToken), 10_000_000e6);
        usdc.mint(address(cToken), 10_000_000e6);
        usdc.mint(address(morpho), 10_000_000e6);
        usdc.mint(address(badRouter), 10_000_000e6);

        vm.prank(address(aToken));
        usdc.approve(address(yeiPool), type(uint256).max);

        // Deploy strategy
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

        strategy = new USDCStrategy(addrs, 3334, 3333, 3333, 4);

        // Configure rewards
        address[] memory takaraPath = new address[](2);
        takaraPath[0] = address(takaraReward);
        takaraPath[1] = address(usdc);
        strategy.setTakaraRewardConfig(address(takaraReward), takaraPath);

        address[] memory morphoPath = new address[](2);
        morphoPath[0] = address(morphoReward);
        morphoPath[1] = address(usdc);
        strategy.setMorphoRewardConfig(address(morphoReward), morphoPath);

        // Set Merkl distributor
        strategy.setMerklDistributor(address(merklDistributor));

        // Fund vault
        usdc.mint(vault, 1_000_000e6);
        vm.prank(vault);
        usdc.approve(address(strategy), type(uint256).max);
    }

    // ─── Helper ──────────────────────────────────────────────────────────

    function _deposit(uint256 amount) internal {
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
    }

    // ═════════════════════════════════════════════════════════════════════
    // harvestWithSlippage
    // ═════════════════════════════════════════════════════════════════════

    function test_harvestWithSlippage_passesWithReasonableMin() public {
        _deposit(100_000e6);

        // Give strategy Takara rewards
        takaraReward.mint(address(strategy), 1000e6);

        // Router has 2% slippage → 1000 becomes 980
        // Set minOut to 970 (3% tolerance) → should pass
        vm.prank(vault);
        strategy.harvestWithSlippage(970e6, 0);
    }

    function test_harvestWithSlippage_revertsOnHighSlippage() public {
        _deposit(100_000e6);

        takaraReward.mint(address(strategy), 1000e6);

        // Router has 2% slippage → returns 980
        // Set minOut to 990 (1% tolerance) → should revert
        vm.prank(vault);
        vm.expectRevert("INSUFFICIENT_OUTPUT_AMOUNT");
        strategy.harvestWithSlippage(990e6, 0);
    }

    function test_harvestWithSlippage_morphoRevertOnHighSlippage() public {
        _deposit(100_000e6);

        morphoReward.mint(address(strategy), 1000e6);

        // Router returns 980, min is 990 → revert
        vm.prank(vault);
        vm.expectRevert("INSUFFICIENT_OUTPUT_AMOUNT");
        strategy.harvestWithSlippage(0, 990e6);
    }

    function test_harvestWithSlippage_bothRewards() public {
        _deposit(100_000e6);

        takaraReward.mint(address(strategy), 500e6);
        morphoReward.mint(address(strategy), 300e6);

        // 2% slippage: 500→490, 300→294
        // Reasonable mins: 480 and 290
        vm.prank(vault);
        strategy.harvestWithSlippage(480e6, 290e6);
    }

    function test_harvestWithSlippage_zeroMinsBehavesLikeHarvest() public {
        _deposit(100_000e6);

        takaraReward.mint(address(strategy), 1000e6);

        // minOut = 0 should always pass (same as harvest())
        vm.prank(vault);
        strategy.harvestWithSlippage(0, 0);
    }

    function test_harvestWithSlippage_onlyVault() public {
        vm.expectRevert(USDCStrategy.OnlyVault.selector);
        strategy.harvestWithSlippage(100, 100);
    }

    function test_harvestWithSlippage_noRewardsNoRevert() public {
        _deposit(50_000e6);

        // No rewards minted — should just return 0 profit without reverting
        vm.prank(vault);
        uint256 profit = strategy.harvestWithSlippage(0, 0);
        assertEq(profit, 0);
    }

    function test_harvestWithSlippage_sandwichAttackReverts() public {
        _deposit(100_000e6);

        takaraReward.mint(address(strategy), 10_000e6);

        // Simulate sandwich: 20% slippage (attacker manipulated pool)
        badRouter.setSlippage(2000);

        // Keeper set 1% tolerance → revert
        vm.prank(vault);
        vm.expectRevert("INSUFFICIENT_OUTPUT_AMOUNT");
        strategy.harvestWithSlippage(9900e6, 0);
    }

    function test_harvestWithSlippage_returnsProfit() public {
        _deposit(100_000e6);

        takaraReward.mint(address(strategy), 5000e6);

        // 2% slippage → 4900 USDC received
        vm.prank(vault);
        uint256 profit = strategy.harvestWithSlippage(4800e6, 0);
        assertEq(profit, 4900e6);
    }

    // ═════════════════════════════════════════════════════════════════════
    // claimMorphoRewards with slippage
    // ═════════════════════════════════════════════════════════════════════

    function test_claimMorphoRewards_passesWithReasonableMin() public {
        _deposit(100_000e6);

        // Configure Merkl to give 1000 morpho rewards
        merklDistributor.setClaimAmount(address(morphoReward), 1000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(morphoReward);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);

        uint256[] memory minOuts = new uint256[](1);
        minOuts[0] = 970e6; // 3% tolerance, router has 2% slippage → pass

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
        minOuts[0] = 990e6; // 1% tolerance, router has 2% → revert

        vm.expectRevert("INSUFFICIENT_OUTPUT_AMOUNT");
        strategy.claimMorphoRewards(tokens, amounts, proofs, minOuts);
    }

    function test_claimMorphoRewards_multipleTokens() public {
        _deposit(100_000e6);

        MockRewardToken rewardB = new MockRewardToken("Reward B", "RWB");
        usdc.mint(address(badRouter), 1_000_000e6);

        merklDistributor.setClaimAmount(address(morphoReward), 500e6);
        merklDistributor.setClaimAmount(address(rewardB), 300e6);

        // Need swap path for rewardB — but morphoSwapPath is used for all in _swapDynamic
        // Actually claimMorphoRewards uses morphoSwapPath for all tokens
        // So rewardB will use the morphoReward swap path with rewardB as tokenIn

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
        minOuts[0] = 480e6; // ok
        minOuts[1] = 290e6; // ok

        strategy.claimMorphoRewards(tokens, amounts, proofs, minOuts);
    }

    function test_claimMorphoRewards_skipsUSDC() public {
        _deposit(100_000e6);

        // If one of the tokens IS USDC, it should be skipped (no swap)
        merklDistributor.setClaimAmount(address(usdc), 1000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);

        uint256[] memory minOuts = new uint256[](1);
        minOuts[0] = 1000e6; // doesn't matter, skipped

        uint256 balBefore = strategy.balanceOf();
        strategy.claimMorphoRewards(tokens, amounts, proofs, minOuts);
        // USDC should have been redeployed
        assertGe(strategy.balanceOf(), balBefore);
    }

    function test_claimMorphoRewards_emptyMinAmountsDefaultsToZero() public {
        _deposit(100_000e6);

        merklDistributor.setClaimAmount(address(morphoReward), 1000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(morphoReward);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);

        // Empty minAmountsOut — should default to 0 (no protection)
        uint256[] memory minOuts = new uint256[](0);

        strategy.claimMorphoRewards(tokens, amounts, proofs, minOuts);
    }

    function test_claimMorphoRewards_noDistributorSetIsNoop() public {
        // Deploy strategy without merkl distributor
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
        USDCStrategy strat2 = new USDCStrategy(addrs, 3334, 3333, 3333, 4);

        address[] memory tokens = new address[](1);
        tokens[0] = address(morphoReward);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        uint256[] memory minOuts = new uint256[](1);
        minOuts[0] = 990e6;

        // Should not revert — just returns early
        strat2.claimMorphoRewards(tokens, amounts, proofs, minOuts);
    }

    function test_claimMorphoRewards_onlyOwner() public {
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32[][] memory proofs = new bytes32[][](0);
        uint256[] memory minOuts = new uint256[](0);

        vm.prank(vault);
        vm.expectRevert();
        strategy.claimMorphoRewards(tokens, amounts, proofs, minOuts);
    }

    // ═════════════════════════════════════════════════════════════════════
    // setMerklDistributor
    // ═════════════════════════════════════════════════════════════════════

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

    // ═════════════════════════════════════════════════════════════════════
    // KanaVault.harvestWithSlippage integration
    // ═════════════════════════════════════════════════════════════════════

    function test_vault_harvestWithSlippage() public {
        // Deploy a real vault
        KanaVault kanaVault = new KanaVault(
            IERC20(address(usdc)),
            address(this), // fee recipient
            1000 // 10% performance fee
        );

        // Deploy strategy with vault = kanaVault
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
        USDCStrategy strat = new USDCStrategy(addrs, 3334, 3333, 3333, 4);

        // Configure rewards on new strategy
        address[] memory takaraPath = new address[](2);
        takaraPath[0] = address(takaraReward);
        takaraPath[1] = address(usdc);
        strat.setTakaraRewardConfig(address(takaraReward), takaraPath);

        // Set strategy on vault
        kanaVault.setStrategy(strat);

        // Deposit into vault
        usdc.mint(address(this), 100_000e6);
        usdc.approve(address(kanaVault), 100_000e6);
        kanaVault.deposit(100_000e6, address(this));

        // Give strategy rewards
        takaraReward.mint(address(strat), 5000e6);

        // Harvest with slippage through vault
        // 2% slippage: 5000 → 4900, min 4800 → should pass
        kanaVault.harvestWithSlippage(4800e6, 0);
    }

    function test_vault_harvestWithSlippage_revertsOnBadPrice() public {
        KanaVault kanaVault = new KanaVault(
            IERC20(address(usdc)),
            address(this),
            1000
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
        USDCStrategy strat = new USDCStrategy(addrs, 3334, 3333, 3333, 4);

        address[] memory takaraPath = new address[](2);
        takaraPath[0] = address(takaraReward);
        takaraPath[1] = address(usdc);
        strat.setTakaraRewardConfig(address(takaraReward), takaraPath);

        kanaVault.setStrategy(strat);

        usdc.mint(address(this), 100_000e6);
        usdc.approve(address(kanaVault), 100_000e6);
        kanaVault.deposit(100_000e6, address(this));

        takaraReward.mint(address(strat), 5000e6);

        // Sandwich: 20% slippage
        badRouter.setSlippage(2000);

        // Keeper expects 1% tolerance → revert bubbles up through vault
        vm.expectRevert("Harvest failed");
        kanaVault.harvestWithSlippage(4950e6, 0);
    }

    function test_vault_harvest_stillWorksWithoutSlippage() public {
        KanaVault kanaVault = new KanaVault(
            IERC20(address(usdc)),
            address(this),
            1000
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
        USDCStrategy strat = new USDCStrategy(addrs, 3334, 3333, 3333, 4);

        kanaVault.setStrategy(strat);

        usdc.mint(address(this), 50_000e6);
        usdc.approve(address(kanaVault), 50_000e6);
        kanaVault.deposit(50_000e6, address(this));

        // Original harvest() still works
        kanaVault.harvest();
    }

    // ═════════════════════════════════════════════════════════════════════
    // Fuzz
    // ═════════════════════════════════════════════════════════════════════

    function test_fuzz_slippageProtection(uint256 slippageBps, uint256 rewardAmt) public {
        slippageBps = bound(slippageBps, 0, 5000); // 0-50%
        rewardAmt = bound(rewardAmt, 1e6, 1_000_000e6);

        _deposit(100_000e6);
        badRouter.setSlippage(slippageBps);
        takaraReward.mint(address(strategy), rewardAmt);

        uint256 expectedOut = (rewardAmt * (10000 - slippageBps)) / 10000;
        uint256 minOut = (rewardAmt * 99) / 100; // 1% tolerance

        if (expectedOut >= minOut) {
            // Should pass
            vm.prank(vault);
            strategy.harvestWithSlippage(minOut, 0);
        } else {
            // Should revert
            vm.prank(vault);
            vm.expectRevert("INSUFFICIENT_OUTPUT_AMOUNT");
            strategy.harvestWithSlippage(minOut, 0);
        }
    }
}
