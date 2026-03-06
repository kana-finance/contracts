// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";

/// @title ForkTest
/// @notice Integration tests against REAL Yei Finance on forked SEI
/// @dev Run with: forge test --match-contract ForkTest --fork-url https://evm-rpc.sei-apis.com -vvv
contract ForkTest is Test {
    address constant USDC = 0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392;
    address constant YEI_POOL = 0x4a4d9abD36F923cBA0Af62A39C01dEC2944fb638;
    address constant YEI_AUSDC = 0x817B3C191092694C65f25B4d38D4935a8aB65616;
    address constant TAKARA_CUSDC = 0xd1E6a6F58A29F64ab2365947ACb53EfEB6Cc05e0;
    address constant MORPHO = 0x015F10a56e97e02437D294815D8e079e1903E41C;

    KanaVault public vault;
    USDCStrategy public strategy;
    address public user;

    uint256 constant INITIAL_BALANCE = 100_000e6;

    function setUp() public {
        if (block.chainid != 1329) return;

        user = makeAddr("user");
        deal(USDC, user, INITIAL_BALANCE);

        vault = new KanaVault(
            IERC20(USDC),
            address(this)
        );

        USDCStrategy.ProtocolAddresses memory addrs = USDCStrategy.ProtocolAddresses({
            usdc: USDC,
            vault: address(vault),
            yeiPool: YEI_POOL,
            aToken: YEI_AUSDC,
            cToken: TAKARA_CUSDC,
            comptroller: address(0),
            morpho: MORPHO,
            routerV2: address(0),
            routerV3: address(0)
        });

        strategy = new USDCStrategy(addrs, 10000, 0, 0, 4, 500, 3600, 3600);

        vault.setStrategy(strategy);

        vm.prank(user);
        IERC20(USDC).approve(address(vault), type(uint256).max);
    }

    function test_fork_deposit() public {
        if (block.chainid != 1329) { console2.log("Skipping"); return; }

        uint256 depositAmount = 10_000e6;
        vm.prank(user);
        uint256 shares = vault.deposit(depositAmount, user);

        assertGt(shares, 0);
        assertApproxEqRel(vault.totalAssets(), depositAmount, 0.01e18);
        assertGt(IERC20(YEI_AUSDC).balanceOf(address(strategy)), 0);
    }

    function test_fork_depositAndWithdraw() public {
        if (block.chainid != 1329) { console2.log("Skipping"); return; }

        uint256 depositAmount = 50_000e6;
        vm.prank(user);
        uint256 shares = vault.deposit(depositAmount, user);

        uint256 balBefore = IERC20(USDC).balanceOf(user);
        vm.prank(user);
        uint256 withdrawn = vault.redeem(shares / 2, user, user);

        assertApproxEqRel(withdrawn, depositAmount / 2, 0.01e18);
        assertEq(IERC20(USDC).balanceOf(user) - balBefore, withdrawn);
    }

    function test_fork_yieldAccrual() public {
        if (block.chainid != 1329) { console2.log("Skipping"); return; }

        vm.prank(user);
        vault.deposit(100_000e6, user);

        uint256 assetsBefore = vault.totalAssets();
        vm.warp(block.timestamp + 30 days);
        uint256 assetsAfter = vault.totalAssets();

        console2.log("Yield accrued:", (assetsAfter - assetsBefore) / 1e6, "USDC");
    }

    function test_fork_harvest() public {
        if (block.chainid != 1329) { console2.log("Skipping"); return; }

        vm.prank(user);
        vault.deposit(50_000e6, user);
        vm.warp(block.timestamp + 7 days);

        vault.harvest(new uint256[](3));
        console2.log("Vault total assets:", vault.totalAssets() / 1e6, "USDC");
    }

    function test_fork_fullCycle() public {
        if (block.chainid != 1329) { console2.log("Skipping"); return; }

        uint256 depositAmount = 25_000e6;
        vm.prank(user);
        uint256 shares = vault.deposit(depositAmount, user);

        vm.warp(block.timestamp + 14 days);
        vault.harvest(new uint256[](3));

        vm.prank(user);
        vault.deposit(depositAmount, user);

        vm.prank(user);
        vault.redeem(shares / 2, user, user);

        assertGt(vault.totalAssets(), 0);
        assertGt(vault.balanceOf(user), 0);
    }
}
