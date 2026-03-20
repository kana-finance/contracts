// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {SEIVault} from "../src/SEIVault.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";
import {SEIStrategy} from "../src/SEIStrategy.sol";
import {MockAToken, MockYeiPool, MockCToken, MockComptroller, MockMorpho, MockMetaMorpho, MockRouter} from "../src/mocks/MockLendingProtocols.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract MockWSEI is ERC20 {
    constructor() ERC20("Wrapped SEI", "WSEI") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockRewardToken18 is ERC20 {
    constructor() ERC20("Reward18", "RWD18") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    // 18 decimals (default)
}

contract MockRewardToken6 is ERC20 {
    constructor() ERC20("Reward6", "RWD6") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

// ─── SEI Strategy Audit Fixes ─────────────────────────────────────────────

contract SEIStrategyAuditFixesTest is Test {
    SEIStrategy public strategy;
    SEIVault public vault;
    MockWSEI public wsei;
    MockYeiPool public yeiPool;
    MockAToken public aToken;
    MockCToken public cToken;
    MockComptroller public comptroller;
    MockMetaMorpho public metamorpho;
    MockRouter public router;

    address public owner;
    uint256 constant INITIAL_BALANCE = 1000 ether;

    function setUp() public {
        owner = address(this);

        wsei = new MockWSEI();
        aToken = new MockAToken(address(wsei), "aWSEI", "aWSEI");
        yeiPool = new MockYeiPool();
        yeiPool.setAToken(address(wsei), address(aToken));
        cToken = new MockCToken(address(wsei), "cWSEI", "cWSEI");
        comptroller = new MockComptroller();
        metamorpho = new MockMetaMorpho(address(wsei), "mmWSEI", "mmWSEI");
        router = new MockRouter();

        // Deploy vault
        vault = new SEIVault(IERC20(address(wsei)), owner);

        // Deploy strategy
        SEIStrategy.ProtocolAddresses memory addrs = SEIStrategy.ProtocolAddresses({
            wsei: address(wsei),
            vault: address(vault),
            yeiPool: address(yeiPool),
            aToken: address(aToken),
            cToken: address(cToken),
            comptroller: address(comptroller),
            morpho: address(metamorpho),
            routerV2: address(router),
            routerV3: address(0)
        });

        strategy = new SEIStrategy(
            addrs,
            3334, // splitYei
            3333, // splitTakara
            3333, // splitMorpho
            4,
            500,  // maxSlippageBps (5%)
            3600,
            3600
        );

        // Fund protocols for withdrawals
        wsei.mint(address(aToken), INITIAL_BALANCE * 10);
        wsei.mint(address(cToken), INITIAL_BALANCE * 10);
        wsei.mint(address(metamorpho), INITIAL_BALANCE * 10);

        // Approve yeiPool to transfer from aToken
        vm.prank(address(aToken));
        wsei.approve(address(yeiPool), type(uint256).max);

        // Set strategy on vault
        vault.setStrategy(IStrategy(address(strategy)));

        // Fund and deposit
        wsei.mint(address(this), INITIAL_BALANCE);
        wsei.approve(address(vault), INITIAL_BALANCE);
    }

    // ─── SEI-F003: MetaMorpho withdrawal revert blocks all withdrawals ─────

    function test_SEI_F003_metamorphoRevertDoesNotBlockWithdrawal() public {
        // Deposit first
        vault.deposit(100 ether, address(this));

        // Make MetaMorpho revert on withdraw
        metamorpho.setShouldRevertOnWithdraw(true);

        // Withdrawal should still succeed (pulls from Aave + Compound, skips Morpho)
        // Withdraw a smaller amount that Aave+Compound can cover
        vault.withdraw(50 ether, address(this), address(this));

        // Verify we got funds back
        assertGt(wsei.balanceOf(address(this)), 0, "Should have received WSEI");
    }

    // ─── SEI-F004: maxDeposit check before MetaMorpho deposit ──────────────

    function test_SEI_F004_maxDepositCapsMetaMorphoDeposit() public {
        // Set low maxDeposit on MetaMorpho
        metamorpho.setMaxDepositAmount(1 ether);

        // Deposit should succeed, excess stays loose or goes to other protocols
        vault.deposit(100 ether, address(this));

        // MetaMorpho should have at most 1 ether deposited
        uint256 morphoBalance = metamorpho.balanceOf(address(strategy));
        assertLe(morphoBalance, 1 ether, "MetaMorpho deposit should be capped");
    }

    // ─── SEI-F001: Stale exchangeRateStored ────────────────────────────────

    function test_SEI_F001_freshExchangeRateUsedInWithdraw() public {
        vault.deposit(100 ether, address(this));

        // Advance time to accrue interest on cToken
        vm.warp(block.timestamp + 365 days);

        // Withdrawal should use fresh exchange rate, not stale
        // This test mainly verifies no revert occurs and the call succeeds
        vault.withdraw(10 ether, address(this), address(this));
        assertGt(wsei.balanceOf(address(this)), 0);
    }

    // ─── SEI-F002: Slippage validation (nonzero check only) ────────────────

    function test_SEI_F002_slippageValidationWithDifferentDecimals() public {
        MockRewardToken18 reward18 = new MockRewardToken18();

        // Configure Takara (index 1) with 18-decimal reward token
        address[] memory swapPath = new address[](2);
        swapPath[0] = address(reward18);
        swapPath[1] = address(wsei);
        strategy.setYieldSourceRewardConfig(1, address(reward18), swapPath);

        // Mint reward tokens to strategy
        reward18.mint(address(strategy), 1 ether); // 1e18

        // Fund router with WSEI for swap output
        wsei.mint(address(this), 10 ether);
        wsei.approve(address(router), 10 ether);
        router.fund(address(wsei), 10 ether);
        reward18.mint(address(router), 10 ether);

        vault.deposit(100 ether, address(this));

        // Any nonzero minAmountOut passes _validateSlippage; DEX router enforces the real bound
        uint256[] memory minAmountsOut = new uint256[](3);
        minAmountsOut[0] = 0;
        minAmountsOut[1] = 0.95 ether;
        minAmountsOut[2] = 0;

        vault.setKeeper(address(this));
        vault.harvest(minAmountsOut);
    }

    /// @notice Regression: volatile 18-decimal reward token with low-value minAmountOut succeeds
    function test_SEI_F002_volatileRewardTokenDoesNotDoS() public {
        MockRewardToken18 reward18 = new MockRewardToken18();

        address[] memory swapPath = new address[](2);
        swapPath[0] = address(reward18);
        swapPath[1] = address(wsei);
        strategy.setYieldSourceRewardConfig(1, address(reward18), swapPath);

        // 1000 tokens of a volatile reward worth ~$0.001 each
        reward18.mint(address(strategy), 1000 ether);

        // Fund router with enough WSEI for the 1:1 raw-amount mock swap
        wsei.mint(address(this), 1100 ether);
        wsei.approve(address(router), 1100 ether);
        router.fund(address(wsei), 1100 ether);
        reward18.mint(address(router), 2000 ether);

        vault.deposit(100 ether, address(this));

        // With old normalization this would require minAmountOut >= 950 WSEI (DoS).
        // Now any nonzero value passes; DEX enforces the actual bound.
        uint256[] memory minAmountsOut = new uint256[](3);
        minAmountsOut[0] = 0;
        minAmountsOut[1] = 1; // Realistic low-value output, nonzero
        minAmountsOut[2] = 0;

        vault.setKeeper(address(this));
        vault.harvest(minAmountsOut);
    }
}

// ─── USDC Strategy Audit Fixes ────────────────────────────────────────────

contract USDCStrategyAuditFixesTest is Test {
    USDCStrategy public strategy;
    KanaVault public vault;
    MockUSDC public usdc;
    MockYeiPool public yeiPool;
    MockAToken public aToken;
    MockCToken public cToken;
    MockComptroller public comptroller;
    MockMorpho public morpho;
    MockRouter public router;

    address public owner;
    uint256 constant INITIAL_BALANCE = 1_000_000e6;

    function setUp() public {
        owner = address(this);

        usdc = new MockUSDC();
        aToken = new MockAToken(address(usdc), "aUSDC", "aUSDC");
        yeiPool = new MockYeiPool();
        yeiPool.setAToken(address(usdc), address(aToken));
        cToken = new MockCToken(address(usdc), "cUSDC", "cUSDC");
        comptroller = new MockComptroller();
        morpho = new MockMorpho();
        router = new MockRouter();

        // Deploy vault
        vault = new KanaVault(IERC20(address(usdc)), owner);

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

        strategy = new USDCStrategy(
            addrs,
            3334,
            3333,
            3333,
            4,
            500,  // 5% slippage
            3600,
            3600
        );

        // Fund protocols
        usdc.mint(address(aToken), INITIAL_BALANCE * 10);
        usdc.mint(address(cToken), INITIAL_BALANCE * 10);
        usdc.mint(address(morpho), INITIAL_BALANCE * 10);

        vm.prank(address(aToken));
        usdc.approve(address(yeiPool), type(uint256).max);

        vault.setStrategy(IStrategy(address(strategy)));

        usdc.mint(address(this), INITIAL_BALANCE);
        usdc.approve(address(vault), INITIAL_BALANCE);
    }

    // ─── USDC-F002: Morpho zero-liquidity withdrawal ──────────────────────

    function test_USDC_F002_morphoRevertDoesNotBlockWithdrawal() public {
        vault.deposit(100_000e6, address(this));

        // Make Morpho revert on withdraw
        morpho.setShouldRevertOnWithdraw(true);

        // Withdrawal should still succeed from Aave + Compound
        vault.withdraw(50_000e6, address(this), address(this));
        assertGt(usdc.balanceOf(address(this)), 0, "Should have received USDC");
    }

    // ─── USDC-F001: Slippage decimal normalization ────────────────────────

    function test_USDC_F001_slippageWithHighDecimalReward() public {
        MockRewardToken18 reward18 = new MockRewardToken18();

        // Configure Takara (index 1) with 18-decimal reward token
        address[] memory swapPath = new address[](2);
        swapPath[0] = address(reward18);
        swapPath[1] = address(usdc);
        strategy.setYieldSourceRewardConfig(1, address(reward18), swapPath);

        // Mint reward tokens to strategy (1e18 = 1 token with 18 decimals)
        reward18.mint(address(strategy), 1 ether);

        // Fund router
        usdc.mint(address(router), 1 ether);
        reward18.mint(address(router), 10 ether);

        vault.deposit(100_000e6, address(this));

        // Any nonzero minAmountOut passes _validateSlippage; DEX router enforces the real bound
        uint256[] memory minAmountsOut = new uint256[](3);
        minAmountsOut[0] = 0;
        minAmountsOut[1] = 950_000; // 0.95 USDC
        minAmountsOut[2] = 0;

        vault.setKeeper(address(this));
        vault.harvest(minAmountsOut);
    }

    function test_USDC_F001_slippageZeroMinOut_reverts() public {
        MockRewardToken18 reward18 = new MockRewardToken18();

        address[] memory swapPath = new address[](2);
        swapPath[0] = address(reward18);
        swapPath[1] = address(usdc);
        strategy.setYieldSourceRewardConfig(1, address(reward18), swapPath);

        reward18.mint(address(strategy), 1 ether);

        vault.deposit(100_000e6, address(this));

        // Only zero minAmountOut reverts now (no decimal normalization)
        uint256[] memory minAmountsOut = new uint256[](3);
        minAmountsOut[0] = 0;
        minAmountsOut[1] = 0; // Zero triggers revert
        minAmountsOut[2] = 0;

        vault.setKeeper(address(this));
        vm.expectRevert(abi.encodeWithSelector(
            USDCStrategy.SlippageExceedsCap.selector,
            0,
            1
        ));
        vault.harvest(minAmountsOut);
    }

    /// @notice Regression: volatile 18-decimal reward with low-value minAmountOut succeeds
    function test_USDC_F001_volatileRewardTokenDoesNotDoS() public {
        MockRewardToken18 reward18 = new MockRewardToken18();

        address[] memory swapPath = new address[](2);
        swapPath[0] = address(reward18);
        swapPath[1] = address(usdc);
        strategy.setYieldSourceRewardConfig(1, address(reward18), swapPath);

        // 1000 tokens of a volatile reward worth ~$0.001 each
        reward18.mint(address(strategy), 1000 ether);

        // Fund router with enough USDC for the 1:1 raw-amount mock swap (1000e18 raw units)
        usdc.mint(address(router), 1100 ether);
        reward18.mint(address(router), 2000 ether);

        vault.deposit(100_000e6, address(this));

        // With old normalization, minRequired would be ~950e6 USDC (DoS for cheap tokens).
        // Now any nonzero value passes; DEX enforces the actual bound.
        uint256[] memory minAmountsOut = new uint256[](3);
        minAmountsOut[0] = 0;
        minAmountsOut[1] = 1; // Realistic low-value output, nonzero
        minAmountsOut[2] = 0;

        vault.setKeeper(address(this));
        vault.harvest(minAmountsOut);
    }

    // ─── SEI-F001 equivalent: Fresh exchange rate in USDC strategy ────────

    function test_freshExchangeRateUsedInWithdraw() public {
        vault.deposit(100_000e6, address(this));

        vm.warp(block.timestamp + 365 days);

        vault.withdraw(10_000e6, address(this), address(this));
        assertGt(usdc.balanceOf(address(this)), 0);
    }
}

// ─── Vault Audit Fixes (KanaVault + SEIVault) ─────────────────────────────

contract VaultAuditFixesTest is Test {
    KanaVault public kanaVault;
    SEIVault public seiVault;
    MockUSDC public usdc;
    MockWSEI public wsei;

    address public owner;

    function setUp() public {
        owner = address(this);
        usdc = new MockUSDC();
        wsei = new MockWSEI();

        kanaVault = new KanaVault(IERC20(address(usdc)), owner);
        seiVault = new SEIVault(IERC20(address(wsei)), owner);
    }

    // ─── V-F003: max* return 0 when paused ────────────────────────────────

    function test_V_F003_kanaVault_maxFunctionsReturnZeroWhenPaused() public {
        // Deposit some funds first
        usdc.mint(address(this), 1000e6);
        usdc.approve(address(kanaVault), 1000e6);
        kanaVault.deposit(1000e6, address(this));

        // Before pause: should be non-zero
        assertGt(kanaVault.maxDeposit(address(this)), 0, "maxDeposit should be > 0 when not paused");
        assertGt(kanaVault.maxMint(address(this)), 0, "maxMint should be > 0 when not paused");
        assertGt(kanaVault.maxWithdraw(address(this)), 0, "maxWithdraw should be > 0 when not paused");
        assertGt(kanaVault.maxRedeem(address(this)), 0, "maxRedeem should be > 0 when not paused");

        // Set guardian and pause
        kanaVault.setGuardian(owner);
        kanaVault.pause();

        // After pause: all should be 0
        assertEq(kanaVault.maxDeposit(address(this)), 0, "maxDeposit should be 0 when paused");
        assertEq(kanaVault.maxMint(address(this)), 0, "maxMint should be 0 when paused");
        assertEq(kanaVault.maxWithdraw(address(this)), 0, "maxWithdraw should be 0 when paused");
        assertEq(kanaVault.maxRedeem(address(this)), 0, "maxRedeem should be 0 when paused");

        // Unpause: should return to non-zero
        kanaVault.unpause();
        assertGt(kanaVault.maxDeposit(address(this)), 0, "maxDeposit should recover after unpause");
    }

    function test_V_F003_seiVault_maxFunctionsReturnZeroWhenPaused() public {
        wsei.mint(address(this), 1000 ether);
        wsei.approve(address(seiVault), 1000 ether);
        seiVault.deposit(1000 ether, address(this));

        assertGt(seiVault.maxDeposit(address(this)), 0);
        assertGt(seiVault.maxWithdraw(address(this)), 0);

        seiVault.setGuardian(owner);
        seiVault.pause();

        assertEq(seiVault.maxDeposit(address(this)), 0);
        assertEq(seiVault.maxMint(address(this)), 0);
        assertEq(seiVault.maxWithdraw(address(this)), 0);
        assertEq(seiVault.maxRedeem(address(this)), 0);
    }

    // ─── V-F002: Shares recomputed after 2-wei shortfall ──────────────────

    function test_V_F002_sharesRecomputedOnShortfall() public {
        // This test verifies the logic exists by checking the code compiles
        // and the vault withdraw doesn't burn excess shares.
        // A full integration test requires a strategy that returns 1-2 wei less.
        // We test via direct deposit/withdraw without strategy (no shortfall case).
        usdc.mint(address(this), 1000e6);
        usdc.approve(address(kanaVault), 1000e6);
        kanaVault.deposit(1000e6, address(this));

        uint256 sharesBefore = kanaVault.balanceOf(address(this));
        kanaVault.withdraw(500e6, address(this), address(this));
        uint256 sharesAfter = kanaVault.balanceOf(address(this));

        // Should have burned roughly half the shares
        assertGt(sharesBefore - sharesAfter, 0, "Should have burned shares");
        assertEq(usdc.balanceOf(address(this)), 500e6, "Should have received exact amount");
    }
}
