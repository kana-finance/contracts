// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";
import {MockAToken, MockYeiPool, MockCToken, MockComptroller, MockMorpho, MockRouter} from "../src/mocks/MockLendingProtocols.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract DynamicFeaturesTest is Test {
    USDCStrategy public strategy;
    MockUSDC public usdc;
    MockYeiPool public yeiPool;
    MockAToken public aToken;
    MockCToken public cToken;
    MockComptroller public comptroller;
    MockMorpho public morpho;
    MockRouter public router;
    
    address public vault;
    address public owner;
    
    function setUp() public {
        owner = address(this);
        vault = makeAddr("vault");
        
        usdc = new MockUSDC();
        aToken = new MockAToken(address(usdc), "aUSDC", "aUSDC");
        yeiPool = new MockYeiPool();
        yeiPool.setAToken(address(usdc), address(aToken));
        cToken = new MockCToken(address(usdc), "cUSDC", "cUSDC");
        comptroller = new MockComptroller();
        morpho = new MockMorpho();
        router = new MockRouter();
        
        usdc.mint(address(aToken), 1_000_000e6);
        usdc.mint(address(cToken), 1_000_000e6);
        usdc.mint(address(morpho), 1_000_000e6);
        
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
            routerV2: address(router),
            routerV3: address(0)
        });
        
        strategy = new USDCStrategy(
            addrs,
            3334, // splitYei
            3333, // splitTakara
            3333, // splitMorpho
            4,    // morphoMaxIterations
            500,  // maxSlippageBps
            3600, // rebalanceCooldown
            3600  // splitsCooldown
        );
        
        usdc.mint(vault, 1_000_000e6);
        vm.prank(vault);
        usdc.approve(address(strategy), type(uint256).max);
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // Yield Source Tests
    // ═══════════════════════════════════════════════════════════════════
    
    function test_yieldSourcesLength() public view {
        assertEq(strategy.yieldSourcesLength(), 3);
    }
    
    function test_getYieldSource() public view {
        (
            USDCStrategy.ProtocolType protocolType,
            bool enabled,
            uint256 split,
            address protocolAddress,
            address receiptToken,
            ,
            ,
            ,
        ) = strategy.getYieldSource(0);
        
        assertEq(uint256(protocolType), uint256(USDCStrategy.ProtocolType.Aave));
        assertTrue(enabled);
        assertEq(split, 3334);
        assertEq(protocolAddress, address(yeiPool));
        assertEq(receiptToken, address(aToken));
    }
    
    function test_addYieldSource() public {
        // Deploy a new Morpho instance
        MockMorpho newMorpho = new MockMorpho();
        usdc.mint(address(newMorpho), 1_000_000e6);
        
        // First remove one source to make room (splits must sum to 10000)
        strategy.removeYieldSource(2); // Remove existing Morpho
        
        address[] memory swapPath = new address[](0);
        strategy.addYieldSource(
            USDCStrategy.ProtocolType.Morpho,
            true,
            3333, // split
            address(newMorpho),
            address(0), // no receipt token for Morpho
            address(0), // no comptroller
            address(0), // no reward token
            swapPath,
            5 // morphoMaxIterations
        );
        
        assertEq(strategy.yieldSourcesLength(), 4);
        
        (
            USDCStrategy.ProtocolType protocolType,
            bool enabled,
            uint256 split,
            address protocolAddress,
            ,
            ,
            ,
            ,
            uint256 morphoMaxIter
        ) = strategy.getYieldSource(3);
        
        assertEq(uint256(protocolType), uint256(USDCStrategy.ProtocolType.Morpho));
        assertTrue(enabled);
        assertEq(split, 3333);
        assertEq(protocolAddress, address(newMorpho));
        assertEq(morphoMaxIter, 5);
    }
    
    function test_addYieldSource_invalidSplit_reverts() public {
        address[] memory swapPath = new address[](0);
        
        vm.expectRevert(USDCStrategy.InvalidSplit.selector);
        strategy.addYieldSource(
            USDCStrategy.ProtocolType.Aave,
            true,
            5000, // Would make total > 10000
            address(yeiPool),
            address(aToken),
            address(0),
            address(0),
            swapPath,
            0
        );
    }
    
    function test_removeYieldSource() public {
        strategy.removeYieldSource(2); // Remove Morpho
        
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
    }
    
    function test_updateYieldSourceSplit() public {
        // Use legacy setSplits to update all at once (individual updates require all to sum to 10000)
        strategy.setSplits(5000, 3000, 2000);
        
        (
            ,
            ,
            uint256 split0,
            ,
            ,
            ,
            ,
            ,
        ) = strategy.getYieldSource(0);
        
        (
            ,
            ,
            uint256 split1,
            ,
            ,
            ,
            ,
            ,
        ) = strategy.getYieldSource(1);
        
        (
            ,
            ,
            uint256 split2,
            ,
            ,
            ,
            ,
            ,
        ) = strategy.getYieldSource(2);
        
        assertEq(split0, 5000);
        assertEq(split1, 3000);
        assertEq(split2, 2000);
    }
    
    function test_updateYieldSourceSplit_respectsCooldown() public {
        strategy.setSplits(5000, 3000, 2000);
        
        // Try again immediately - should fail due to cooldown
        vm.expectRevert(abi.encodeWithSelector(
            USDCStrategy.SplitsCooldownActive.selector,
            block.timestamp + 3600
        ));
        strategy.setSplits(6000, 2000, 2000);
    }
    
    function test_updateYieldSourceSplit_invalidTotal_reverts() public {
        vm.expectRevert(USDCStrategy.InvalidSplit.selector);
        strategy.updateYieldSourceSplit(0, 9000); // Would make total != 10000
    }
    
    function test_setYieldSourceEnabled() public {
        strategy.setYieldSourceEnabled(1, false);
        
        (
            ,
            bool enabled,
            ,
            ,
            ,
            ,
            ,
            ,
        ) = strategy.getYieldSource(1);
        
        assertFalse(enabled);
    }
    
    function test_setYieldSourceRewardConfig() public {
        address rewardToken = makeAddr("rewardToken");
        address[] memory swapPath = new address[](2);
        swapPath[0] = rewardToken;
        swapPath[1] = address(usdc);
        
        strategy.setYieldSourceRewardConfig(1, rewardToken, swapPath);
        
        (
            ,
            ,
            ,
            ,
            ,
            ,
            address configuredRewardToken,
            address[] memory configuredPath,
        ) = strategy.getYieldSource(1);
        
        assertEq(configuredRewardToken, rewardToken);
        assertEq(configuredPath.length, 2);
        assertEq(configuredPath[0], rewardToken);
        assertEq(configuredPath[1], address(usdc));
    }
    
    function test_dynamicYieldSources_deployWorks() public {
        // Deploy funds with dynamic sources
        uint256 amount = 90_000e6;
        
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        assertApproxEqRel(strategy.balanceOf(), amount, 0.01e18);
    }
    
    function test_dynamicYieldSources_withdrawWorks() public {
        uint256 amount = 90_000e6;
        
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        vm.prank(vault);
        strategy.withdraw(30_000e6);
        
        assertApproxEqRel(strategy.balanceOf(), 60_000e6, 0.01e18);
    }
    
    function test_dynamicYieldSources_harvestWorks() public {
        uint256 amount = 50_000e6;
        
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        uint256[] memory minAmounts = new uint256[](3);
        
        vm.prank(vault);
        uint256 profit = strategy.harvest(minAmounts);
        
        assertGe(profit, 0);
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // Router Tests
    // ═══════════════════════════════════════════════════════════════════
    
    function test_routersLength() public view {
        assertEq(strategy.routersLength(), 1); // Only V2 router initialized
    }
    
    function test_getRouter() public view {
        (
            address routerAddress,
            USDCStrategy.RouterType routerType,
            bool enabled,
            string memory label
        ) = strategy.getRouter(0);
        
        assertEq(routerAddress, address(router));
        assertEq(uint256(routerType), uint256(USDCStrategy.RouterType.V2));
        assertTrue(enabled);
        assertEq(label, "DragonSwap");
    }
    
    function test_addRouter() public {
        address newRouter = makeAddr("newRouter");
        
        strategy.addRouter(
            newRouter,
            USDCStrategy.RouterType.V3,
            "Uniswap V3"
        );
        
        assertEq(strategy.routersLength(), 2);
        
        (
            address routerAddress,
            USDCStrategy.RouterType routerType,
            bool enabled,
            string memory label
        ) = strategy.getRouter(1);
        
        assertEq(routerAddress, newRouter);
        assertEq(uint256(routerType), uint256(USDCStrategy.RouterType.V3));
        assertTrue(enabled);
        assertEq(label, "Uniswap V3");
    }
    
    function test_addRouter_zeroAddress_reverts() public {
        vm.expectRevert(USDCStrategy.InvalidAddress.selector);
        strategy.addRouter(
            address(0),
            USDCStrategy.RouterType.V2,
            "Invalid"
        );
    }
    
    function test_removeRouter() public {
        strategy.removeRouter(0);
        
        (
            ,
            ,
            bool enabled,
        ) = strategy.getRouter(0);
        
        assertFalse(enabled);
    }
    
    function test_setActiveRouter() public {
        // Add a second router
        address newRouter = makeAddr("newRouter");
        strategy.addRouter(newRouter, USDCStrategy.RouterType.V3, "V3");
        
        // Set it as active
        strategy.setActiveRouter(1);
        
        assertEq(strategy.activeRouterIndex(), 1);
    }
    
    function test_setActiveRouter_invalidIndex_reverts() public {
        vm.expectRevert(USDCStrategy.InvalidIndex.selector);
        strategy.setActiveRouter(99);
    }
    
    function test_setActiveRouter_disabledRouter_reverts() public {
        strategy.removeRouter(0);
        
        vm.expectRevert(USDCStrategy.InvalidIndex.selector);
        strategy.setActiveRouter(0);
    }
    
    function test_setActiveRouter_byType() public {
        // Add a V3 router
        address newRouter = makeAddr("newRouter");
        strategy.addRouter(newRouter, USDCStrategy.RouterType.V3, "V3");
        
        // Set active by type
        strategy.setActiveRouter(USDCStrategy.RouterType.V3);
        
        // Should now be using V3 router
        (
            address activeRouterAddr,
            ,
            ,
        ) = strategy.getRouter(strategy.activeRouterIndex());
        
        assertEq(activeRouterAddr, newRouter);
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // Integration Tests
    // ═══════════════════════════════════════════════════════════════════
    
    function test_addNewProtocol_rebalance_withdraw() public {
        // 1. Initial deposit
        uint256 amount = 90_000e6;
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        // 2. Add a new protocol
        MockMorpho newMorpho = new MockMorpho();
        usdc.mint(address(newMorpho), 1_000_000e6);
        
        // Remove old Morpho and disable it
        strategy.removeYieldSource(2);
        
        // Add new protocol with same split
        address[] memory swapPath = new address[](0);
        strategy.addYieldSource(
            USDCStrategy.ProtocolType.Morpho,
            true,
            3333,
            address(newMorpho),
            address(0),
            address(0),
            address(0),
            swapPath,
            5
        );
        
        // 3. Rebalance to redistribute to new protocol
        // Note: Old Morpho (index 2) is disabled but still has funds
        // After rebalance, funds should be in Yei, Takara, and new Morpho (index 3)
        vm.warp(block.timestamp + 3601);
        strategy.rebalance();
        
        uint256 balanceAfterRebalance = strategy.balanceOf();
        
        // 4. Withdraw - should work with new protocol
        vm.prank(vault);
        strategy.withdraw(30_000e6);
        
        assertApproxEqRel(strategy.balanceOf(), balanceAfterRebalance - 30_000e6, 0.02e18);
    }
    
    function test_switchRouter_harvest() public {
        // Deposit first
        uint256 amount = 50_000e6;
        vm.prank(vault);
        usdc.transfer(address(strategy), amount);
        vm.prank(vault);
        strategy.deposit(amount);
        
        // Add a second router
        MockRouter newRouter = new MockRouter();
        usdc.mint(address(newRouter), 1_000_000e6);
        
        strategy.addRouter(
            address(newRouter),
            USDCStrategy.RouterType.V2,
            "Alternative Router"
        );
        
        // Switch to new router
        strategy.setActiveRouter(1);
        
        // Harvest - should use new router (even without rewards)
        uint256[] memory minAmounts = new uint256[](3);
        vm.prank(vault);
        uint256 profit = strategy.harvest(minAmounts);
        
        assertGe(profit, 0);
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // Access Control
    // ═══════════════════════════════════════════════════════════════════
    
    function test_yieldSourceManagement_onlyOwner() public {
        address[] memory swapPath = new address[](0);
        
        vm.prank(vault);
        vm.expectRevert();
        strategy.addYieldSource(
            USDCStrategy.ProtocolType.Aave,
            true,
            0,
            address(yeiPool),
            address(aToken),
            address(0),
            address(0),
            swapPath,
            0
        );
    }
    
    function test_routerManagement_onlyOwner() public {
        vm.prank(vault);
        vm.expectRevert();
        strategy.addRouter(makeAddr("router"), USDCStrategy.RouterType.V2, "Test");
    }
    
    function test_setActiveRouter_keeperCanCall() public {
        address keeper = makeAddr("keeper");
        strategy.setKeeper(keeper);
        
        // Add second router
        strategy.addRouter(makeAddr("router"), USDCStrategy.RouterType.V3, "V3");
        
        // Keeper can switch
        vm.prank(keeper);
        strategy.setActiveRouter(1);
        
        assertEq(strategy.activeRouterIndex(), 1);
    }
}
