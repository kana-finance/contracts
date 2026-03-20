// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// FinishRedeployV2.s.sol
//
// Completes the V2 redeploy after USDC was already rescued manually.
// Run this script to:
//   1. Deploy new KanaVault + USDCStrategy, deposit rescued USDC
//   2. Rescue WSEI from old SEIVault via RescueStrategy swap
//   3. Deploy new SEIVault + SEIStrategy, deposit rescued WSEI
//   4. Verify all wiring
//
// Pre-conditions (already completed before running this):
//   - Rescued USDC sitting in deployer wallet from old KanaVault rescue

import {Script, console} from "forge-std/Script.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";
import {SEIVault} from "../src/SEIVault.sol";
import {SEIStrategy} from "../src/SEIStrategy.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Minimal pass-through strategy used to bypass the 0-tolerance rounding check
// in old SEIVault (same pattern used to rescue old KanaVault funds).
contract RescueStrategy2 is IStrategy {
    IERC20 public immutable token;
    address public immutable vaultAddr;

    constructor(address _token, address _vault) {
        token = IERC20(_token);
        vaultAddr = _vault;
    }

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

contract FinishRedeployV2 is Script {
    // ─── Token Addresses ────────────────────────────────────────────────────────
    address constant USDC = 0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392;
    address constant WSEI = 0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7;

    // ─── Protocol Addresses ─────────────────────────────────────────────────────
    address constant YEI_POOL                = 0x4a4d9abD36F923cBA0Af62A39C01dEC2944fb638;
    address constant YEI_AUSDC               = 0x817B3C191092694C65f25B4d38D4935a8aB65616;
    address constant TAKARA_CUSDC            = 0xd1E6a6F58A29F64ab2365947ACb53EfEB6Cc05e0;
    address constant TAKARA_USDC_COMPTROLLER = 0x56A171Acb1bBa46D4fdF21AfBE89377574B8D9BD;
    address constant MORPHO_USDC             = 0x015F10a56e97e02437D294815D8e079e1903E41C;
    address constant YEI_AWSEI               = 0x809FF4801aA5bDb33045d1fEC810D082490D63a4;
    address constant TAKARA_CWSEI            = 0xA26b9BFe606d29F16B5Aecf30F9233934452c4E2;
    address constant TAKARA_WSEI_COMPTROLLER = 0x71034bf5eC0FAd7aEE81a213403c8892F3d8CAeE;
    address constant FEATHER_WSEI_VAULT      = 0x948FcC6b7f68f4830Cd69dB1481a9e1A142A4923;
    address constant DRAGONSWAP_ROUTER       = 0xa4cF2F53D1195aDDdE9e4D3aCa54f556895712f2;
    address constant SAILOR_ROUTER           = 0xd1EFe48B71Acd98Db16FcB9E7152B086647Ef544;

    // ─── Old Vault ───────────────────────────────────────────────────────────────
    address constant OLD_SEI_VAULT = 0x3468982893352808d1e248b98A1c5bab0f2833BC;

    KanaVault    public newKanaVault;
    USDCStrategy public newUSDCStrategy;
    SEIVault     public newSEIVault;
    SEIStrategy  public newSEIStrategy;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");

        console.log("=== KANA FINISH REDEPLOY V2 ===");
        console.log("Deployer:", deployer);
        console.log("Guardian:", guardian);
        require(block.chainid == 1329, "Not on SEI mainnet!");

        vm.startBroadcast(deployerPrivateKey);

        // ─── Phase B: Deploy new USDC vault ─────────────────────────────────────
        console.log("");
        console.log("--- Phase B: Deploying new USDC vault ---");

        newKanaVault = new KanaVault(IERC20(USDC), deployer);
        console.log("New KanaVault:", address(newKanaVault));

        USDCStrategy.ProtocolAddresses memory usdcAddrs = USDCStrategy.ProtocolAddresses({
            usdc: USDC,
            vault: address(newKanaVault),
            yeiPool: YEI_POOL,
            aToken: YEI_AUSDC,
            cToken: TAKARA_CUSDC,
            comptroller: TAKARA_USDC_COMPTROLLER,
            morpho: MORPHO_USDC,
            routerV2: DRAGONSWAP_ROUTER,
            routerV3: SAILOR_ROUTER
        });

        newUSDCStrategy = new USDCStrategy(
            usdcAddrs,
            0,      // 0% Yei
            10000,  // 100% Takara
            0,      // 0% Morpho
            4,      // Morpho max iterations
            500,    // 5% max slippage cap
            3600,   // 1 hour rebalance cooldown
            3600    // 1 hour splits cooldown
        );
        console.log("New USDCStrategy:", address(newUSDCStrategy));

        newKanaVault.setStrategy(newUSDCStrategy);
        newKanaVault.setKeeper(deployer);
        newKanaVault.setGuardian(guardian);
        newUSDCStrategy.setKeeper(deployer);
        newUSDCStrategy.setGuardian(guardian);

        uint256 rescuedUsdc = IERC20(USDC).balanceOf(deployer);
        require(rescuedUsdc > 0, "No USDC in deployer wallet");
        IERC20(USDC).approve(address(newKanaVault), rescuedUsdc);
        newKanaVault.deposit(rescuedUsdc, deployer);
        console.log("USDC deposited into new vault:", rescuedUsdc);

        // ─── Phase C: Rescue WSEI from old vault ────────────────────────────────
        console.log("");
        console.log("--- Phase C: Rescuing WSEI from old SEIVault ---");
        SEIVault oldSEIVault = SEIVault(OLD_SEI_VAULT);
        uint256 wseiShares = oldSEIVault.balanceOf(deployer);
        console.log("Old SEIVault shares:", wseiShares);
        uint256 rescuedWsei = 0;
        if (wseiShares > 0) {
            RescueStrategy2 wseiRescue = new RescueStrategy2(WSEI, address(oldSEIVault));
            oldSEIVault.setStrategy(IStrategy(address(wseiRescue)));
            console.log("Switched old SEIVault to RescueStrategy, funds are now unlocked");

            uint256 wseiBefore = IERC20(WSEI).balanceOf(deployer);
            oldSEIVault.redeem(wseiShares, deployer, deployer);
            rescuedWsei = IERC20(WSEI).balanceOf(deployer) - wseiBefore;
            console.log("Rescued WSEI (raw):", rescuedWsei);
        } else {
            console.log("No shares to redeem from old SEIVault");
        }

        // ─── Phase D: Deploy new WSEI vault ─────────────────────────────────────
        console.log("");
        console.log("--- Phase D: Deploying new WSEI vault ---");

        newSEIVault = new SEIVault(IERC20(WSEI), deployer);
        console.log("New SEIVault:", address(newSEIVault));

        SEIStrategy.ProtocolAddresses memory wseiAddrs = SEIStrategy.ProtocolAddresses({
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

        newSEIStrategy = new SEIStrategy(
            wseiAddrs,
            0,      // 0% Yei
            10000,  // 100% Takara
            0,      // 0% Feather/Morpho
            4,      // Morpho max iterations
            500,    // 5% max slippage cap
            3600,   // 1 hour rebalance cooldown
            3600    // 1 hour splits cooldown
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
        console.log("WSEI deposited into new vault:", wseiDeposit);

        vm.stopBroadcast();

        // ─── Phase E: Post-Deploy Verification ──────────────────────────────────
        console.log("");
        console.log("--- Phase E: Post-Deploy Verification ---");

        require(address(newKanaVault.strategy()) == address(newUSDCStrategy), "VERIFY: kanaVault.strategy mismatch");
        require(newKanaVault.keeper() == deployer,                             "VERIFY: kanaVault.keeper mismatch");
        require(newKanaVault.guardian() == guardian,                           "VERIFY: kanaVault.guardian mismatch");
        require(newUSDCStrategy.vault() == address(newKanaVault),              "VERIFY: usdcStrategy.vault mismatch");
        require(newUSDCStrategy.keeper() == deployer,                          "VERIFY: usdcStrategy.keeper mismatch");
        require(newUSDCStrategy.guardian() == guardian,                        "VERIFY: usdcStrategy.guardian mismatch");

        require(address(newSEIVault.strategy()) == address(newSEIStrategy),    "VERIFY: seiVault.strategy mismatch");
        require(newSEIVault.keeper() == deployer,                              "VERIFY: seiVault.keeper mismatch");
        require(newSEIVault.guardian() == guardian,                            "VERIFY: seiVault.guardian mismatch");
        require(newSEIStrategy.vault() == address(newSEIVault),                "VERIFY: seiStrategy.vault mismatch");
        require(newSEIStrategy.keeper() == deployer,                           "VERIFY: seiStrategy.keeper mismatch");
        require(newSEIStrategy.guardian() == guardian,                         "VERIFY: seiStrategy.guardian mismatch");

        console.log("All post-deploy assertions passed.");

        console.log("");
        console.log("=== REDEPLOY COMPLETE ===");
        console.log("New KanaVault:    ", address(newKanaVault));
        console.log("New USDCStrategy:", address(newUSDCStrategy));
        console.log("New SEIVault:     ", address(newSEIVault));
        console.log("New SEIStrategy: ", address(newSEIStrategy));
        console.log("");
        console.log("NEXT STEPS:");
        console.log("  1. Update .env with the 4 new addresses above");
        console.log("  2. Transfer ownership of all 4 contracts to multisig");
        console.log("  3. Update keeper address to dedicated bot wallet");
        console.log("  4. Call setMerklDistributor once Morpho Merkl address is known");
        console.log("  See script/DEPLOY_RUNBOOK.md for full post-deploy checklist");
    }
}
