// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";
import {MockYeiPool, MockAToken, MockCToken, MockComptroller, MockMorpho, MockRouter} from "../src/mocks/MockLendingProtocols.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract DeployTestnet is Script {
    MockUSDC public usdc;
    MockYeiPool public yeiPool;
    MockAToken public aToken;
    MockCToken public cToken;
    MockComptroller public comptroller;
    MockMorpho public morpho;
    MockRouter public router;
    KanaVault public vault;
    USDCStrategy public strategy;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Kana to SEI Testnet...");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Mock USDC
        usdc = new MockUSDC();

        // 2. Deploy Mock Protocols
        aToken = new MockAToken(address(usdc), "Kana aUSDC", "kaUSDC");
        yeiPool = new MockYeiPool();
        yeiPool.setAToken(address(usdc), address(aToken));
        cToken = new MockCToken(address(usdc), "Kana cUSDC", "kcUSDC");
        comptroller = new MockComptroller();
        morpho = new MockMorpho();
        router = new MockRouter();

        // 3. Deploy KanaVault
        vault = new KanaVault(IERC20(address(usdc)), deployer);

        // 4. Deploy USDCStrategy
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

        strategy = new USDCStrategy(addrs, 10000, 0, 0, 4, 500, 3600, 3600);

        // 5. Connect and configure
        vault.setStrategy(strategy);
        vault.setKeeper(deployer);
        strategy.setKeeper(deployer);
        strategy.transferOwnership(deployer);

        // 6. Mint test USDC
        usdc.mint(deployer, 100_000 * 1e6);

        // 7. Set mock APRs
        aToken.setApr(500);
        cToken.setApr(600);
        morpho.setApr(address(usdc), 700);

        // 8. Fund mock protocols
        usdc.mint(address(aToken), 10_000_000 * 1e6);
        usdc.mint(address(cToken), 10_000_000 * 1e6);
        usdc.mint(address(morpho), 10_000_000 * 1e6);
        aToken.approvePool(address(yeiPool));

        vm.stopBroadcast();

        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Vault:", address(vault));
        console.log("Strategy:", address(strategy));
    }
}
