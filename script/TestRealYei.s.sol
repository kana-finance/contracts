// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";

contract TestRealYei is Script {
    address constant USDC = 0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392;
    address constant YEI_POOL = 0x4a4d9abD36F923cBA0Af62A39C01dEC2944fb638;
    address constant YEI_AUSDC = 0x817B3C191092694C65f25B4d38D4935a8aB65616;
    address constant TAKARA_CUSDC = 0xd1E6a6F58A29F64ab2365947ACb53EfEB6Cc05e0;
    address constant MORPHO = 0x015F10a56e97e02437D294815D8e079e1903E41C;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);

        uint256 usdcBal = IERC20(USDC).balanceOf(user);
        if (usdcBal == 0) {
            console.log("No USDC. Fund wallet first.");
            return;
        }

        vm.startBroadcast(pk);

        KanaVault vault = new KanaVault(IERC20(USDC), user);

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

        USDCStrategy strategy = new USDCStrategy(addrs, 10000, 0, 0, 4, 500, 3600, 3600);
        vault.setStrategy(strategy);
        vault.setKeeper(user);
        strategy.setKeeper(user);

        uint256 depositAmount = usdcBal / 10;
        IERC20(USDC).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);

        console.log("Vault:", address(vault));
        console.log("Strategy:", address(strategy));
        console.log("Deposited:", depositAmount / 1e6, "USDC");
        console.log("Total assets:", vault.totalAssets() / 1e6, "USDC");

        vm.stopBroadcast();
    }
}
