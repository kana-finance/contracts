# Kana Finance Contracts — Claude Guidelines

## Project Overview

USDC/WSEI yield aggregator on SEI blockchain. ERC-4626 vaults delegate to strategy contracts that manage funds across Yei (Aave fork), Takara (Compound fork), and Morpho/MetaMorpho.

- **KanaVault** (`src/KanaVault.sol`) — USDC ERC-4626 vault
- **SEIVault** (`src/SEIVault.sol`) — WSEI ERC-4626 vault
- **USDCStrategy** (`src/USDCStrategy.sol`) — USDC allocation strategy
- **SEIStrategy** (`src/SEIStrategy.sol`) — WSEI allocation strategy
- **IStrategy** (`src/interfaces/IStrategy.sol`) — Strategy interface

## Architecture Rules

- One vault ↔ one strategy (never multi-strategy)
- Virtual shares offset = 6 (inflation attack prevention — do not change)
- Performance fee = 10% (PERFORMANCE_FEE_BPS = 1000 — immutable by design)
- Maximum 3 yield sources per strategy (`TooManyYieldSources` error if exceeded)
- BPS splits must sum to exactly 10000

## Role Model

| Role | Permissions |
|------|------------|
| owner (multisig) | All admin functions, unpause |
| keeper (bot) | harvest only |
| guardian | pause only (cannot unpause) |

## Security Requirements

### Must check on every PR:

1. **CEI pattern** — state changes before external calls in all vault/strategy functions
2. **Approval order in setStrategy** — revoke old approval after withdrawing, then grant new
3. **Reentrancy** — `nonReentrant` on all state-changing external functions in vault
4. **Access control** — new functions use appropriate modifiers (`onlyOwner`, `onlyKeeperOrOwner`, `onlyGuardianOrOwner`)
5. **No silent failures** — `_withdraw` must revert with `InsufficientWithdrawBalance` if strategy shortchanges; do not silently adjust assets
6. **Slippage** — `minAmountsOut` validated > 0 before each swap in `claimMorphoRewards`
7. **forceApprove** — use `SafeERC20.forceApprove` for USDT-like token compatibility

### High-risk patterns to flag immediately:
- Raw `.call()` without typed ABI encoding (use typed interfaces instead)
- Approval granted before withdrawing from old strategy
- Yield source array growing beyond 3 entries
- Harvest function missing `uint256[]` parameter
- `whenNotPaused` missing on deposit/withdraw/harvest

## Code Style

- Solidity `^0.8.20`, optimizer 200 runs
- OpenZeppelin v5.x patterns
- Custom errors (not `require` strings) for gas efficiency
- NatSpec on all public/external functions
- Section comments using `// ─── Section Name ─...` style
- No magic numbers — use named constants

## Testing

- Framework: Foundry (`forge test`)
- Test files in `test/`, mocks in `test/mocks/`
- Fork tests in `test/ForkTest.t.sol` (excluded from CI — require live RPC)
- Run tests: `forge test --no-match-contract ForkTest`
- Expected baseline: 242 passing, 21 pre-existing failures in `SEIVaultTest.t.sol:SEIStrategyTest` (mock setup issue, unrelated to contract logic)

### Test requirements for PRs:
- New functions → new test in the relevant test file
- Bug fixes → regression test demonstrating the fix
- Security fixes → test that triggers the vulnerable path and verifies the fix

## Known Pre-existing Issues (do not flag)

- 21 failures in `SEIVaultTest.t.sol:SEIStrategyTest` — mock WSEI setup issue, unrelated to contract logic
- `_swap` function in strategies is untested (mock protocols don't produce reward tokens)
