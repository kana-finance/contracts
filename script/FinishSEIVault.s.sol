// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// FinishSEIVault.s.sol
//
// Rescues WSEI from old SEIVault and deploys the new SEIVault + SEIStrategy.
// Run after FinishRedeployV2 has handled the USDC side.

import {Script, console} from "forge-std/Script.sol";
import {SEIVault} from "../src/SEIVault.sol";
import {SEIStrategy} from "../src/SEIStrategy.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract WSEIRescue is IStrategy {
    IERC20 public immutable token;
    address public immutable vaultAddr;
    constructor(address _token, address _vault) { token = IERC20(_token); vaultAddr = _vault; }
    function asset() external view override returns (address) { return address(token); }
    function deposit(uint256) external override {}
    function withdraw(uint256 amount) external override {
        uint256 bal = token.balanceOf(address(this));
        uint256 toSend = bal < amount ? bal : amount;
        if (toSend > 0) token.transfer(vaultAddr, toSend);
    }
    function harvest(uint256[] calldata) external pure override returns (uint256) { return 0; }
    function balanceOf() external view override returns (uint256) { return token.balanceOf(address(this)); }
}

contract FinishSEIVault is Script {
    address constant WSEI = 0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7;
    address constant YEI_POOL                = 0x4a4d9abD36F923cBA0Af62A39C01dEC2944fb638;
    address constant YEI_AWSEI               = 0x809FF4801aA5bDb33045d1fEC810D082490D63a4;
    address constant TAKARA_CWSEI            = 0xA26b9BFe606d29F16B5Aecf30F9233934452c4E2;
    address constant TAKARA_WSEI_COMPTROLLER = 0x71034bf5eC0FAd7aEE81a213403c8892F3d8CAeE;
    address constant FEATHER_WSEI_VAULT      = 0x948FcC6b7f68f4830Cd69dB1481a9e1A142A4923;
    address constant DRAGONSWAP_ROUTER       = 0xa4cF2F53D1195aDDdE9e4D3aCa54f556895712f2;
    address constant SAILOR_ROUTER           = 0xd1EFe48B71Acd98Db16FcB9E7152B086647Ef544;
    address constant OLD_SEI_VAULT           = 0x3468982893352808d1e248b98A1c5bab0f2833BC;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");

        console.log("=== KANA SEI VAULT FINISH DEPLOY ===");
        console.log("Deployer:", deployer);
        require(block.chainid == 1329, "Not on SEI mainnet!");

        vm.startBroadcast(deployerPrivateKey);

        // ─── Phase C: Rescue WSEI ────────────────────────────────────────────────
        console.log("--- Phase C: Rescuing WSEI ---");
        SEIVault oldSEIVault = SEIVault(OLD_SEI_VAULT);
        uint256 wseiShares = oldSEIVault.balanceOf(deployer);
        console.log("Old SEIVault shares:", wseiShares);

        uint256 rescuedWsei = 0;
        if (wseiShares > 0) {
            WSEIRescue wseiRescue = new WSEIRescue(WSEI, address(oldSEIVault));
            oldSEIVault.setStrategy(IStrategy(address(wseiRescue)));
            console.log("Switched to rescue strategy");

            uint256 wseiBefore = IERC20(WSEI).balanceOf(deployer);
            oldSEIVault.redeem(wseiShares, deployer, deployer);
            rescuedWsei = IERC20(WSEI).balanceOf(deployer) - wseiBefore;
            console.log("Rescued WSEI:", rescuedWsei);
        }

        // ─── Phase D: Deploy new SEI vault ──────────────────────────────────────
        console.log("--- Phase D: Deploying new SEI vault ---");

        SEIVault newSEIVault = new SEIVault(IERC20(WSEI), deployer);
        console.log("New SEIVault:", address(newSEIVault));

        SEIStrategy.ProtocolAddresses memory addrs = SEIStrategy.ProtocolAddresses({
            wsei: WSEI,
            vault: address(newSEIVault),
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

        newSEIVault.setStrategy(newSEIStrategy);
        newSEIVault.setKeeper(deployer);
        newSEIVault.setGuardian(guardian);
        newSEIStrategy.setKeeper(deployer);
        newSEIStrategy.setGuardian(guardian);

        uint256 wseiDeposit = rescuedWsei > 0 ? rescuedWsei : 1e15;
        IERC20(WSEI).approve(address(newSEIVault), wseiDeposit);
        newSEIVault.deposit(wseiDeposit, deployer);
        console.log("WSEI deposited:", wseiDeposit);

        vm.stopBroadcast();

        // ─── Verify ─────────────────────────────────────────────────────────────
        require(address(newSEIVault.strategy()) == address(newSEIStrategy),  "strategy mismatch");
        require(newSEIVault.keeper() == deployer,                             "keeper mismatch");
        require(newSEIVault.guardian() == guardian,                           "guardian mismatch");
        require(newSEIStrategy.vault() == address(newSEIVault),               "vault mismatch");
        require(newSEIStrategy.keeper() == deployer,                          "strat keeper mismatch");
        require(newSEIStrategy.guardian() == guardian,                        "strat guardian mismatch");

        console.log("All verifications passed.");
        console.log("=== SEI VAULT DEPLOY COMPLETE ===");
        console.log("New SEIVault:    ", address(newSEIVault));
        console.log("New SEIStrategy:", address(newSEIStrategy));
        console.log("Update .env with these addresses.");
    }
}
