# Kana Contracts

USDC yield aggregator on SEI — simple, auto-compounding, high-yield savings for everyone.

## Architecture

### One strategy per asset

Kana follows the **one-strategy-per-asset** pattern. The vault holds user deposits and issues shares. A single strategy handles all protocol allocation internally.

```
User deposits USDC → KanaVault (ERC-4626, kUSDC shares, fees)
                        → USDCStrategy (splits across protocols)
                             → Yei Finance (Aave V3 fork)
                             → Takara (Compound fork)
                             → Morpho (P2P optimizer)
```

### Vault
- `KanaVault.sol` — ERC-4626 vault, handles deposits/withdrawals/fees
- Users deposit USDC → receive kUSDC shares
- 10% performance fee on harvested yield

### Strategy
- `USDCStrategy.sol` — manages USDC across all three lending protocols
- Configurable allocation splits (basis points, must sum to 10000)
- Internal rebalancing between protocols
- Reward harvesting + swap to USDC via Sailor DEX

### Yield Sources
| Protocol | Type | Mechanism |
|----------|------|-----------|
| Yei Finance | Aave V3 fork | aToken balance growth |
| Takara | Compound fork | cToken exchange rate growth + COMP rewards |
| Morpho | P2P optimizer | Better rates via lender/borrower matching |

## Development

```bash
# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std

# Build
forge build

# Test
forge test -v
```

## License
MIT
