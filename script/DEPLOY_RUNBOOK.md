# Kana Finance — Deployment Runbook

Covers deploying KanaVault (USDC) and SEIVault (WSEI) to SEI mainnet (chainid 1329).

---

## Pre-Deploy Checklist

- [ ] Copy `.env.example` → `.env` and fill in all values
- [ ] Verify `PRIVATE_KEY` wallet has sufficient funds:
  - ≥ 1 USDC (seed deposit for KanaVault)
  - ≥ 0.001 WSEI (seed deposit for SEIVault)
  - SEI for gas (estimate ~0.5 SEI per deploy script)
- [ ] Confirm `GUARDIAN_ADDRESS` is a secure, accessible wallet (not the deployer EOA)
- [ ] Confirm `MULTISIG_ADDRESS` is the correct Gnosis Safe or equivalent
- [ ] Verify external protocol addresses are still live (spot-check via `cast call`):
  ```sh
  # Yei pool should return a non-zero reserve count
  cast call 0x4a4d9abD36F923cBA0Af62A39C01dEC2944fb638 "getReservesList()(address[])" --rpc-url $SEI_RPC_URL
  ```
- [ ] Run `forge build` — zero errors
- [ ] Run `forge test --no-match-contract ForkTest` — 242 passing, ≤21 pre-existing failures

---

## Step 1 — Deploy USDC Vault

```sh
forge script script/DeployMainnet.s.sol \
  --rpc-url $SEI_RPC_URL \
  --broadcast \
  --verify
```

Note addresses from output:
- `KanaVault: <KANA_VAULT_ADDR>`
- `USDCStrategy: <USDC_STRATEGY_ADDR>`

---

## Step 2 — Deploy WSEI Vault

```sh
forge script script/DeploySEIMainnet.s.sol \
  --rpc-url $SEI_RPC_URL \
  --broadcast \
  --verify
```

Note addresses from output:
- `SEIVault: <SEI_VAULT_ADDR>`
- `SEIStrategy: <SEI_STRATEGY_ADDR>`

---

## Step 3 — Post-Deploy State Verification

Run these `cast call` checks for each deployed contract. Replace addresses with actual values.

```sh
# KanaVault
cast call <KANA_VAULT_ADDR> "strategy()(address)"      --rpc-url $SEI_RPC_URL
cast call <KANA_VAULT_ADDR> "keeper()(address)"        --rpc-url $SEI_RPC_URL
cast call <KANA_VAULT_ADDR> "guardian()(address)"      --rpc-url $SEI_RPC_URL
cast call <KANA_VAULT_ADDR> "feeRecipient()(address)"  --rpc-url $SEI_RPC_URL
cast call <KANA_VAULT_ADDR> "owner()(address)"         --rpc-url $SEI_RPC_URL

# USDCStrategy
cast call <USDC_STRATEGY_ADDR> "vault()(address)"      --rpc-url $SEI_RPC_URL
cast call <USDC_STRATEGY_ADDR> "keeper()(address)"     --rpc-url $SEI_RPC_URL
cast call <USDC_STRATEGY_ADDR> "guardian()(address)"   --rpc-url $SEI_RPC_URL
cast call <USDC_STRATEGY_ADDR> "maxSlippageBps()(uint256)" --rpc-url $SEI_RPC_URL
cast call <USDC_STRATEGY_ADDR> "owner()(address)"      --rpc-url $SEI_RPC_URL

# SEIVault
cast call <SEI_VAULT_ADDR> "strategy()(address)"       --rpc-url $SEI_RPC_URL
cast call <SEI_VAULT_ADDR> "keeper()(address)"         --rpc-url $SEI_RPC_URL
cast call <SEI_VAULT_ADDR> "guardian()(address)"       --rpc-url $SEI_RPC_URL
cast call <SEI_VAULT_ADDR> "feeRecipient()(address)"   --rpc-url $SEI_RPC_URL
cast call <SEI_VAULT_ADDR> "owner()(address)"          --rpc-url $SEI_RPC_URL

# SEIStrategy
cast call <SEI_STRATEGY_ADDR> "vault()(address)"       --rpc-url $SEI_RPC_URL
cast call <SEI_STRATEGY_ADDR> "keeper()(address)"      --rpc-url $SEI_RPC_URL
cast call <SEI_STRATEGY_ADDR> "guardian()(address)"    --rpc-url $SEI_RPC_URL
cast call <SEI_STRATEGY_ADDR> "maxSlippageBps()(uint256)" --rpc-url $SEI_RPC_URL
cast call <SEI_STRATEGY_ADDR> "owner()(address)"       --rpc-url $SEI_RPC_URL
```

Expected values:
| Field | Expected |
|-------|----------|
| `strategy` | Corresponding strategy address |
| `keeper` | Deployer EOA (temporary) |
| `guardian` | `GUARDIAN_ADDRESS` from .env |
| `feeRecipient` | Deployer EOA (temporary) |
| `owner` | Deployer EOA (will be transferred in Step 4) |
| `maxSlippageBps` | 500 (5%) |

---

## Step 4 — Transfer Ownership to Multisig

Transfer ownership for all four contracts. The contracts use plain `Ownable` (single-step transfer) — ownership is effective immediately.

```sh
# KanaVault
cast send <KANA_VAULT_ADDR> "transferOwnership(address)" $MULTISIG_ADDRESS \
  --private-key $PRIVATE_KEY --rpc-url $SEI_RPC_URL

# USDCStrategy
cast send <USDC_STRATEGY_ADDR> "transferOwnership(address)" $MULTISIG_ADDRESS \
  --private-key $PRIVATE_KEY --rpc-url $SEI_RPC_URL

# SEIVault
cast send <SEI_VAULT_ADDR> "transferOwnership(address)" $MULTISIG_ADDRESS \
  --private-key $PRIVATE_KEY --rpc-url $SEI_RPC_URL

# SEIStrategy
cast send <SEI_STRATEGY_ADDR> "transferOwnership(address)" $MULTISIG_ADDRESS \
  --private-key $PRIVATE_KEY --rpc-url $SEI_RPC_URL
```

Verify ownership transferred:

```sh
cast call <KANA_VAULT_ADDR>    "owner()(address)" --rpc-url $SEI_RPC_URL
cast call <USDC_STRATEGY_ADDR> "owner()(address)" --rpc-url $SEI_RPC_URL
cast call <SEI_VAULT_ADDR>     "owner()(address)" --rpc-url $SEI_RPC_URL
cast call <SEI_STRATEGY_ADDR>  "owner()(address)" --rpc-url $SEI_RPC_URL
# All should return $MULTISIG_ADDRESS
```

---

## Step 5 — Optional Post-Deploy Configuration

These steps require the multisig to be the caller. Execute via your Safe UI or `cast send` with multisig signing.

### Set Merkl Distributor (for Morpho reward claiming)

Once the Morpho Merkl distributor address is known:

```sh
# Via multisig — USDCStrategy
cast send <USDC_STRATEGY_ADDR> "setMerklDistributor(address)" <MERKL_ADDR> \
  --private-key $MULTISIG_PK --rpc-url $SEI_RPC_URL

# Via multisig — SEIStrategy
cast send <SEI_STRATEGY_ADDR> "setMerklDistributor(address)" <MERKL_ADDR> \
  --private-key $MULTISIG_PK --rpc-url $SEI_RPC_URL
```

### Update Keeper to Bot Wallet

```sh
cast send <KANA_VAULT_ADDR>    "setKeeper(address)" <BOT_WALLET> --private-key $MULTISIG_PK --rpc-url $SEI_RPC_URL
cast send <USDC_STRATEGY_ADDR> "setKeeper(address)" <BOT_WALLET> --private-key $MULTISIG_PK --rpc-url $SEI_RPC_URL
cast send <SEI_VAULT_ADDR>     "setKeeper(address)" <BOT_WALLET> --private-key $MULTISIG_PK --rpc-url $SEI_RPC_URL
cast send <SEI_STRATEGY_ADDR>  "setKeeper(address)" <BOT_WALLET> --private-key $MULTISIG_PK --rpc-url $SEI_RPC_URL
```

### Lock Fee Recipient (optional)

Once fee recipient is finalised, lock it to prevent future changes:

```sh
cast send <KANA_VAULT_ADDR> "lockFeeRecipient()" --private-key $MULTISIG_PK --rpc-url $SEI_RPC_URL
cast send <SEI_VAULT_ADDR>  "lockFeeRecipient()" --private-key $MULTISIG_PK --rpc-url $SEI_RPC_URL
```

### Adjust Yield Source Splits

Initial deploy allocates 100% to Takara. Adjust via multisig once yield rates are confirmed:

```sh
# Example: 30% Yei / 50% Takara / 20% Morpho
cast send <USDC_STRATEGY_ADDR> "setSplits(uint256,uint256,uint256)" 3000 5000 2000 \
  --private-key $MULTISIG_PK --rpc-url $SEI_RPC_URL
```

---

## Dry-Run (no broadcast)

To simulate the deploy scripts without sending transactions:

```sh
forge script script/DeployMainnet.s.sol    --rpc-url $SEI_RPC_URL
forge script script/DeploySEIMainnet.s.sol --rpc-url $SEI_RPC_URL
```

Omitting `--broadcast` runs the script in simulation mode — Forge will report any reverts before any transactions are sent.

---

## Redeployment (Fund Migration)

Use `RedeployAllV2.s.sol` when contract code has been updated and a full redeploy is needed. The script:

1. Redeems all deployer shares from the old KanaVault and SEIVault
2. Deploys fresh KanaVault + USDCStrategy and SEIVault + SEIStrategy
3. Wires up keeper/guardian roles
4. Re-deposits all rescued funds into the new vaults

**Pre-redeploy checks:**
- Confirm deployer is the only depositor (seed funds only)
- Verify old vault addresses in the script match `.env`

**Dry run:**
```sh
forge script script/RedeployAllV2.s.sol --rpc-url $SEI_RPC_URL
```

**Live run:**
```sh
forge script script/RedeployAllV2.s.sol --rpc-url $SEI_RPC_URL --broadcast
```

**After broadcast:**
- Note the 4 new addresses from script output
- Update `.env`: `KANA_VAULT_ADDRESS`, `USDC_STRATEGY_ADDRESS`, `SEI_VAULT_ADDRESS`, `SEI_STRATEGY_ADDRESS`
- Run post-deploy `cast call` checks (Step 3 above) against the new addresses
- Transfer ownership to multisig (Step 4 above)
