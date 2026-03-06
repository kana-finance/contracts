// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICErc20 {
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
}

interface IStrategy {
    function rescueToken(address token, uint256 amount) external;
    function balanceOf() external view returns (uint256);
}

contract RescueAndUpgrade is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address vault = 0x14410FF2a124D0669C6e8Adfe3695F25C92a6d03;
        address oldStrategy = 0xEe574a21b30c250C5953Ec3B64255c3e47e0C6eD;
        address usdc = 0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392;
        address takaraCUSDC = 0xd1E6a6F58A29F64ab2365947ACb53EfEB6Cc05e0;
        address takaraComptroller = 0x56A171Acb1bBa46D4fdF21AfBE89377574B8D9BD;
        address dragonSwapRouter = 0xa4cF2F53D1195aDDdE9e4D3aCa54f556895712f2;

        console.log("=== RESCUE AND UPGRADE ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // Step 1: Rescue cUSDC from old strategy to deployer
        uint256 cUsdcBalance = ICErc20(takaraCUSDC).balanceOf(oldStrategy);
        console.log("cUSDC in old strategy:", cUsdcBalance);
        
        if (cUsdcBalance > 0) {
            IStrategy(oldStrategy).rescueToken(takaraCUSDC, cUsdcBalance);
            console.log("Rescued cUSDC to deployer");
        }

        // Step 2: Redeem cUSDC for USDC
        uint256 deployer_cUsdc = ICErc20(takaraCUSDC).balanceOf(deployer);
        console.log("Deployer cUSDC:", deployer_cUsdc);
        
        if (deployer_cUsdc > 0) {
            uint256 exchangeRate = ICErc20(takaraCUSDC).exchangeRateStored();
            uint256 underlyingAmount = (deployer_cUsdc * exchangeRate) / 1e18;
            console.log("Redeeming for ~USDC:", underlyingAmount);
            
            uint256 err = ICErc20(takaraCUSDC).redeemUnderlying(underlyingAmount);
            if (err != 0) {
                // Try redeeming slightly less
                err = ICErc20(takaraCUSDC).redeemUnderlying(underlyingAmount - 1);
                require(err == 0, "cUSDC redeem failed");
            }
            console.log("Redeemed cUSDC for USDC");
        }

        // Step 3: Deploy new strategy
        USDCStrategy newStrategy = new USDCStrategy(
            USDCStrategy.ProtocolAddresses({
                usdc: usdc,
                vault: vault,
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

        // Step 4: Set keeper
        newStrategy.setKeeper(deployer);

        // Step 5: Set new strategy on vault (old strategy now has 0 balance)
        KanaVault(vault).setStrategy(newStrategy);
        console.log("Strategy set on vault");

        // Step 6: Deposit recovered USDC back into vault
        uint256 usdcBalance = IERC20(usdc).balanceOf(deployer);
        console.log("Deployer USDC balance:", usdcBalance);
        
        if (usdcBalance > 0) {
            IERC20(usdc).approve(vault, usdcBalance);
            KanaVault(vault).deposit(usdcBalance, deployer);
            console.log("Deposited USDC back into vault:", usdcBalance);
        }

        vm.stopBroadcast();

        console.log("=== UPGRADE COMPLETE ===");
        console.log("New Strategy:", address(newStrategy));
    }
}
