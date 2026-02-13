// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStrategy {
    function rescueToken(address token, uint256 amount) external;
    function balanceOf() external view returns (uint256);
}

interface ICErc20 {
    function balanceOf(address) external view returns (uint256);
    function redeemUnderlying(uint256) external returns (uint256);
    function exchangeRateStored() external view returns (uint256);
}

contract RedeployAll is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address oldVault = 0x14410FF2a124D0669C6e8Adfe3695F25C92a6d03;
        address oldStrategy = 0x7b225747f78b8ed1cb5616696248b271e35b58C5;
        address usdc = 0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392;
        address takaraCUSDC = 0xd1E6a6F58A29F64ab2365947ACb53EfEB6Cc05e0;
        address takaraComptroller = 0x56A171Acb1bBa46D4fdF21AfBE89377574B8D9BD;
        address dragonSwapRouter = 0xa4cF2F53D1195aDDdE9e4D3aCa54f556895712f2;

        console.log("=== FULL REDEPLOY ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // Step 1: Rescue cUSDC from old strategy
        uint256 cUsdcBal = ICErc20(takaraCUSDC).balanceOf(oldStrategy);
        console.log("cUSDC in old strategy:", cUsdcBal);
        if (cUsdcBal > 0) {
            IStrategy(oldStrategy).rescueToken(takaraCUSDC, cUsdcBal);
            // Redeem cUSDC for USDC
            uint256 exchangeRate = ICErc20(takaraCUSDC).exchangeRateStored();
            uint256 underlying = (cUsdcBal * exchangeRate) / 1e18;
            uint256 err = ICErc20(takaraCUSDC).redeemUnderlying(underlying);
            if (err != 0) {
                ICErc20(takaraCUSDC).redeemUnderlying(underlying - 1);
            }
            console.log("Rescued and redeemed USDC from old strategy");
        }

        // Step 2: Redeem shares from old vault (if any)
        uint256 oldShares = IERC20(oldVault).balanceOf(deployer);
        console.log("Old vault shares:", oldShares);
        // Can't redeem from old vault due to the bug, but funds are already rescued above

        // Step 3: Deploy new vault
        KanaVault newVault = new KanaVault(IERC20(usdc), deployer);
        console.log("New KanaVault:", address(newVault));

        // Step 4: Deploy new strategy
        USDCStrategy newStrategy = new USDCStrategy(
            USDCStrategy.ProtocolAddresses({
                usdc: usdc,
                vault: address(newVault),
                yeiPool: address(0),
                aToken: address(0),
                cToken: takaraCUSDC,
                comptroller: takaraComptroller,
                morpho: address(0),
                routerV2: dragonSwapRouter,
                routerV3: address(0)
            }),
            0,      // splitYei
            10000,  // splitTakara (100%)
            0,      // splitMorpho
            4,      // morphoMaxIterations
            500,    // maxSlippageBps (5%)
            3600,   // rebalanceCooldown (1h)
            3600    // splitsCooldown (1h)
        );
        console.log("New USDCStrategy:", address(newStrategy));

        // Step 5: Configure
        newStrategy.setKeeper(deployer);
        newVault.setKeeper(deployer);
        newVault.setStrategy(newStrategy);

        // Step 6: Seed deposit
        uint256 usdcBal = IERC20(usdc).balanceOf(deployer);
        console.log("USDC to deposit:", usdcBal);
        if (usdcBal > 0) {
            IERC20(usdc).approve(address(newVault), usdcBal);
            newVault.deposit(usdcBal, deployer);
            console.log("Deposited:", usdcBal);
        }

        vm.stopBroadcast();

        console.log("=== REDEPLOY COMPLETE ===");
        console.log("Vault:", address(newVault));
        console.log("Strategy:", address(newStrategy));
    }
}
