// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {KanaVault} from "../src/KanaVault.sol";
import {USDCStrategy} from "../src/USDCStrategy.sol";
import {MockYeiPool, MockAToken, MockCToken, MockComptroller, MockMorpho, MockRouter} from "../src/mocks/MockLendingProtocols.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Mintable ERC20 for testnet
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @title DeployTestnet
/// @notice Deploys Kana with mock protocols on SEI testnet
contract DeployTestnet is Script {
    // Deployed addresses (will be logged)
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
        console.log("MockUSDC deployed:", address(usdc));
        
        // 2. Deploy Mock Protocols
        // Yei (Aave V3 fork)
        aToken = new MockAToken(address(usdc), "Kana aUSDC", "kaUSDC");
        yeiPool = new MockYeiPool();
        yeiPool.setAToken(address(usdc), address(aToken));
        console.log("MockYeiPool deployed:", address(yeiPool));
        console.log("MockAToken deployed:", address(aToken));
        
        // Takara (Compound fork)
        cToken = new MockCToken(address(usdc), "Kana cUSDC", "kcUSDC");
        comptroller = new MockComptroller();
        console.log("MockCToken deployed:", address(cToken));
        console.log("MockComptroller deployed:", address(comptroller));
        
        // Morpho
        morpho = new MockMorpho();
        console.log("MockMorpho deployed:", address(morpho));
        
        // DEX Router
        router = new MockRouter();
        console.log("MockRouter deployed:", address(router));
        
        // 3. Deploy KanaVault
        vault = new KanaVault(
            IERC20(address(usdc)),
            deployer, // feeRecipient
            1000 // 10% performance fee
        );
        console.log("KanaVault deployed:", address(vault));
        
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
        
        // Start with 100% to Yei (highest default APR will be adjusted by keeper)
        strategy = new USDCStrategy(
            addrs,
            10000, // 100% to Yei initially
            0,     // 0% to Takara
            0,     // 0% to Morpho
            4      // Morpho max iterations
        );
        console.log("USDCStrategy deployed:", address(strategy));
        
        // 5. Connect vault to strategy
        vault.setStrategy(strategy);
        console.log("Strategy connected to vault");
        
        // 6. Transfer strategy ownership to vault owner (for keeper operations)
        // Strategy owner can call setSplits and rebalance
        strategy.transferOwnership(deployer);
        
        // 7. Mint some USDC to deployer for testing
        usdc.mint(deployer, 100_000 * 1e6); // 100k USDC
        console.log("Minted 100,000 USDC to deployer");
        
        // 8. Set initial APRs for mock protocols (simulating different yields)
        aToken.setApr(500);  // 5% APR for Yei
        cToken.setApr(600);  // 6% APR for Takara
        morpho.setApr(address(usdc), 700); // 7% APR for Morpho
        console.log("Set initial APRs: Yei=5%, Takara=6%, Morpho=7%");
        
        // 9. Fund mock protocols with USDC for withdrawals and set approvals
        usdc.mint(address(aToken), 10_000_000 * 1e6);  // 10M for aToken
        usdc.mint(address(cToken), 10_000_000 * 1e6);  // 10M for cToken  
        usdc.mint(address(morpho), 10_000_000 * 1e6);  // 10M for Morpho
        
        // Critical: aToken must approve yeiPool for withdrawals
        aToken.approvePool(address(yeiPool));
        console.log("Funded mock protocols and set approvals");
        
        vm.stopBroadcast();
        
        // Output deployment summary
        console.log("");
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("Network: SEI Testnet (atlantic-2)");
        console.log("");
        console.log("Core Contracts:");
        console.log("  USDC:", address(usdc));
        console.log("  Vault:", address(vault));
        console.log("  Strategy:", address(strategy));
        console.log("");
        console.log("Mock Protocols:");
        console.log("  YeiPool:", address(yeiPool));
        console.log("  AToken:", address(aToken));
        console.log("  CToken:", address(cToken));
        console.log("  Comptroller:", address(comptroller));
        console.log("  Morpho:", address(morpho));
        console.log("  Router:", address(router));
        console.log("");
        console.log("Configuration:");
        console.log("  Performance Fee: 10%");
        console.log("  Fee Recipient:", deployer);
        console.log("  Initial Allocation: 100% Yei");
        console.log("========================");
    }
}
