# Kana Finance Contracts

USDC and WSEI yield aggregator on SEI blockchain — auto-compounding, high-yield savings across multiple lending protocols.

## Architecture

### One strategy per asset

Each vault delegates all protocol allocation to a single paired strategy. The vault handles user-facing ERC-4626 logic (deposits, withdrawals, share accounting, fees). The strategy handles protocol interaction (supply, withdraw, harvest, rebalance).

```
User deposits USDC → KanaVault (ERC-4626, kUSDC shares, 10% perf fee)
                         → USDCStrategy (configurable BPS splits)
                              → Yei Finance (Aave V3 fork)
                              → Takara (Compound fork)
                              → Morpho (P2P optimizer)

User deposits WSEI → SEIVault (ERC-4626, kWSEI shares, 10% perf fee)
                         → SEIStrategy (configurable BPS splits)
                              → Yei Finance (Aave V3 fork)
                              → Takara (Compound fork)
                              → Feather (MetaMorpho ERC-4626 vault)
```

## Contracts Overview

| Contract | Description |
|----------|-------------|
| `src/KanaVault.sol` | ERC-4626 vault for USDC deposits. Issues kUSDC shares, collects 10% performance fee on harvested yield. |
| `src/SEIVault.sol` | ERC-4626 vault for WSEI deposits. Issues kWSEI shares, same fee model as KanaVault. |
| `src/USDCStrategy.sol` | Manages USDC across Yei, Takara, and Morpho. Supports V2/V3 DEX routers for reward swaps. |
| `src/SEIStrategy.sol` | Manages WSEI across Yei, Takara, and Feather (MetaMorpho). Uses MetaMorpho ERC-4626 interface instead of raw Morpho P2P. |
| `src/interfaces/IStrategy.sol` | Common interface implemented by both strategies. |

## Yield Sources

| Protocol | USDC | WSEI | Mechanism |
|----------|:----:|:----:|-----------|
| Yei Finance (Aave V3 fork) | ✓ | ✓ | Supply → receive aToken; balance grows via index |
| Takara (Compound fork) | ✓ | ✓ | Supply → receive cToken; value grows via exchange rate; COMP rewards claimable |
| Morpho | ✓ | — | P2P rate optimizer on top of Yei/Takara |
| Feather MetaMorpho | — | ✓ | ERC-4626 MetaMorpho vault (WSEI-denominated) |

## Roles & Access Control

| Role | Held by | Permissions |
|------|---------|-------------|
| `owner` | Multisig | All admin functions: `setStrategy`, `setKeeper`, `setGuardian`, `setSplits`, `setMaxSlippage`, `setCooldowns`, `setFeeRecipient`, `unpause`, `emergencyWithdraw` |
| `keeper` | Automation bot | `harvest`, `rebalance`, `claimMorphoRewards` |
| `guardian` | Security monitor | `pause` only — cannot unpause |

## Security Features

- **Virtual shares offset = 6** — prevents ERC-4626 inflation attacks on first deposit
- **Reentrancy guards** — `nonReentrant` on all state-changing external vault and strategy functions
- **Pausable** — guardian can pause deposits, withdrawals, and harvests in emergencies; only owner can unpause
- **On-chain slippage cap** — `maxSlippageBps` enforced on every swap, with a hard ceiling of 10% (`MAX_SLIPPAGE_CEILING = 1000`)
- **Cooldown timers** — configurable cooldowns on `rebalance` and `setSplits` prevent sandwich attacks and rapid manipulation
- **CEI pattern** — state changes precede all external calls throughout vault and strategy logic
- **`SafeERC20.forceApprove`** — used for all token approvals to support USDT-like tokens with non-zero approval guards
- **Approval sequencing in `setStrategy`** — old strategy approval is revoked after funds are withdrawn, before the new strategy approval is granted
- **No silent failures** — `_withdraw` reverts with `InsufficientWithdrawBalance` if the strategy returns less than requested; no silent adjustments
- **Fee recipient lock** — `feeRecipient` cannot be the zero address; validated on every harvest
- **Immutable performance fee** — `PERFORMANCE_FEE_BPS = 1000` (10%) is a compile-time constant; cannot be changed after deployment

## Development

### Prerequisites

- [Foundry](https://getfoundry.sh/) (`forge`, `cast`, `anvil`)

### Install & Build

```bash
# Clone and install dependencies
git clone <repo-url>
cd contracts
forge install

# Build
forge build
```

### Test

```bash
# Run all unit tests (excludes fork tests that require a live RPC)
forge test --no-match-contract ForkTest

# Run with verbosity
forge test --no-match-contract ForkTest -vv

# Run a specific test file
forge test --match-path test/KanaVaultTest.t.sol -vv
```

**Known pre-existing failures:** 21 tests in `SEIVaultTest.t.sol:SEIStrategyTest` fail due to a mock WSEI setup issue unrelated to contract logic. These are expected and do not indicate bugs.

**Fork tests** in `test/ForkTest.t.sol` require a live SEI mainnet RPC and are excluded from CI.

## Deployment

Contracts are deployed via Foundry scripts in `script/`. All scripts target SEI mainnet (chain ID 1329) or testnet (chain ID 1328).

```bash
# Deploy USDC vault + strategy
forge script script/DeployMainnet.s.sol --rpc-url $SEI_RPC --broadcast

# Deploy WSEI vault + strategy
forge script script/DeploySEIMainnet.s.sol --rpc-url $SEI_RPC --broadcast
```

### External Protocol Addresses (SEI Mainnet)

#### USDC Ecosystem

| Contract | Address |
|----------|---------|
| USDC | `0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392` |
| Yei Lending Pool | `0x4a4d9abD36F923cBA0Af62A39C01dEC2944fb638` |
| Yei aUSDC | `0x817B3C191092694C65f25B4d38D4935a8aB65616` |
| Takara cUSDC | `0xd1E6a6F58A29F64ab2365947ACb53EfEB6Cc05e0` |
| Takara Comptroller | `0x56A171Acb1bBa46D4fdF21AfBE89377574B8D9BD` |
| Morpho | `0x015F10a56e97e02437D294815D8e079e1903E41C` |

#### WSEI Ecosystem

| Contract | Address |
|----------|---------|
| WSEI | `0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7` |
| Yei Lending Pool | `0x4a4d9abD36F923cBA0Af62A39C01dEC2944fb638` |
| Yei aWSEI | `0x809FF4801aA5bDb33045d1fEC810D082490D63a4` |
| Takara cWSEI | `0xA26b9BFe606d29F16B5Aecf30F9233934452c4E2` |
| Takara Comptroller | `0x71034bf5eC0FAd7aEE81a213403c8892F3d8CAeE` |
| Feather MetaMorpho Vault | `0x948FcC6b7f68f4830Cd69dB1481a9e1A142A4923` |

#### DEX Routers

| Router | Address |
|--------|---------|
| DragonSwap V2 | `0xa4cF2F53D1195aDDdE9e4D3aCa54f556895712f2` |
| Sailor V3 | `0xd1EFe48B71Acd98Db16FcB9E7152B086647Ef544` |

### Chain Info

| Network | Chain ID |
|---------|----------|
| SEI Mainnet | 1329 |
| SEI Testnet | 1328 |

## Configuration Defaults

| Parameter | Default | Notes |
|-----------|---------|-------|
| Performance fee | 10% (`PERFORMANCE_FEE_BPS = 1000`) | Immutable compile-time constant |
| Max slippage | 5% (500 bps) | Configurable by owner; hard ceiling 10% |
| Rebalance cooldown | 1 hour (3600s) | Configurable by owner |
| Splits change cooldown | 1 hour (3600s) | Configurable by owner |
| Optimizer runs | 200 | Set in `foundry.toml` |
| Solidity version | `^0.8.20` | |

## License

MIT
