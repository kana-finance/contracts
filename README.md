# Kana Contracts

USDC yield aggregator on SEI — simple, auto-compounding, high-yield savings for everyone.

## Overview

Kana automatically allocates USDC deposits to the highest-yielding lending protocol on SEI. Users deposit USDC, receive `kUSDC` shares, and earn yield. All rewards are swapped to USDC and auto-compounded.

Think of it as a **high-yield savings account** — deposit USDC, earn more USDC.

## Architecture

### Vault (ERC-4626)
- `KanaVault.sol` — Handles deposits, withdrawals, and fee collection
- Users deposit USDC → receive kUSDC shares
- Share price grows as yield accrues
- 10% performance fee on harvested yield

### Strategies
Each strategy manages USDC in one lending protocol:
- `YeiStrategy.sol` — Yei Finance (Aave V3 fork)
- `TakaraStrategy.sol` — Takara (Compound fork)
- `MorphoStrategy.sol` — Morpho Protocol

### Flow
```
User deposits USDC → Vault → Active Strategy → Lending Protocol
                                    ↓
                              Yield accrues
                                    ↓
Keeper harvests → Swap rewards → Compound → Share price grows
```

## Yield Sources
| Protocol | Type | How it works |
|----------|------|--------------|
| Yei Finance | Aave V3 fork | Supply USDC → aUSDC, interest accrues via balance growth |
| Takara | Compound fork | Mint cUSDC, interest accrues via exchange rate growth |
| Morpho | P2P optimizer | Matches lenders/borrowers P2P for better rates |

## Development

### Build
```bash
forge build
```

### Test
```bash
forge test -v
```

### Format
```bash
forge fmt
```

## Tech Stack
- **Solidity** 0.8.20+
- **Foundry** (Forge, Cast, Anvil)
- **OpenZeppelin** Contracts v5
- **SEI** EVM

## License
MIT
