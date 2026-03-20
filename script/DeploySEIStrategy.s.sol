// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// DeploySEIStrategy.s.sol
//
// Deploys SEIStrategy and wires it to the already-deployed SEIVault.
// Run after FinishSEIVault.s.sol broadcast (which completed Phase C + SEIVault deploy
// but failed on SEIStrategy deploy due to block gas limit).

import {Script, console} from "forge-std/Script.sol";
import {SEIVault} from "../src/SEIVault.sol";
import {SEIStrategy} from "../src/SEIStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeploySEIStrategy is Script {
    address constant WSEI                    = 0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7;
    address constant YEI_POOL                = 0x4a4d9abD36F923cBA0Af62A39C01dEC2944fb638;
    address constant YEI_AWSEI               = 0x809FF4801aA5bDb33045d1fEC810D082490D63a4;
    address constant TAKARA_CWSEI            = 0xA26b9BFe606d29F16B5Aecf30F9233934452c4E2;
    address constant TAKARA_WSEI_COMPTROLLER = 0x71034bf5eC0FAd7aEE81a213403c8892F3d8CAeE;
    address constant FEATHER_WSEI_VAULT      = 0x948FcC6b7f68f4830Cd69dB1481a9e1A142A4923;
    address constant DRAGONSWAP_ROUTER       = 0xa4cF2F53D1195aDDdE9e4D3aCa54f556895712f2;
    address constant SAILOR_ROUTER           = 0xd1EFe48B71Acd98Db16FcB9E7152B086647Ef544;

    // Already deployed in FinishSEIVault.s.sol broadcast
    address constant NEW_SEI_VAULT = 0x390d9D31A484716170056dcb5da431fAA02fe275;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");

        console.log("=== DEPLOY SEI STRATEGY ===");
        console.log("Deployer:", deployer);
        console.log("SEIVault:", NEW_SEI_VAULT);
        require(block.chainid == 1329, "Not on SEI mainnet!");

        vm.startBroadcast(deployerPrivateKey);

        SEIStrategy.ProtocolAddresses memory addrs = SEIStrategy.ProtocolAddresses({
            wsei: WSEI,
            vault: NEW_SEI_VAULT,
            yeiPool: YEI_POOL,
            aToken: YEI_AWSEI,
            cToken: TAKARA_CWSEI,
            comptroller: TAKARA_WSEI_COMPTROLLER,
            morpho: FEATHER_WSEI_VAULT,
            routerV2: DRAGONSWAP_ROUTER,
            routerV3: SAILOR_ROUTER
        });

        SEIStrategy newSEIStrategy = new SEIStrategy(
            addrs, 0, 10000, 0, 4, 500, 3600, 3600
        );
        console.log("New SEIStrategy:", address(newSEIStrategy));

        SEIVault newSEIVault = SEIVault(NEW_SEI_VAULT);
        newSEIVault.setStrategy(newSEIStrategy);
        newSEIVault.setKeeper(deployer);
        newSEIVault.setGuardian(guardian);
        newSEIStrategy.setKeeper(deployer);
        newSEIStrategy.setGuardian(guardian);

        uint256 wseiBalance = IERC20(WSEI).balanceOf(deployer);
        console.log("Deployer WSEI balance:", wseiBalance);
        require(wseiBalance > 0, "No WSEI to deposit");

        IERC20(WSEI).approve(NEW_SEI_VAULT, wseiBalance);
        newSEIVault.deposit(wseiBalance, deployer);
        console.log("WSEI deposited:", wseiBalance);

        vm.stopBroadcast();

        // Verify
        require(address(newSEIVault.strategy()) == address(newSEIStrategy), "strategy mismatch");
        require(newSEIVault.keeper() == deployer,                           "keeper mismatch");
        require(newSEIVault.guardian() == guardian,                         "guardian mismatch");
        require(newSEIStrategy.vault() == NEW_SEI_VAULT,                    "vault mismatch");
        require(newSEIStrategy.keeper() == deployer,                        "strat keeper mismatch");
        require(newSEIStrategy.guardian() == guardian,                      "strat guardian mismatch");

        console.log("All verifications passed.");
        console.log("=== SEI STRATEGY DEPLOY COMPLETE ===");
        console.log("New SEIVault:    ", NEW_SEI_VAULT);
        console.log("New SEIStrategy:", address(newSEIStrategy));
        console.log("Update .env with these addresses.");
    }
}
