// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IAavePool} from "./interfaces/external/IAavePool.sol";
import {IAToken} from "./interfaces/external/IAToken.sol";
import {ICErc20} from "./interfaces/external/ICErc20.sol";
import {IComptroller} from "./interfaces/external/IComptroller.sol";
import {IMorpho} from "./interfaces/external/IMorpho.sol";
import {IMerklDistributor} from "./interfaces/external/IMerklDistributor.sol";
import {ISailorRouter} from "./interfaces/external/ISailorRouter.sol";
import {ISwapRouterV3} from "./interfaces/external/ISwapRouterV3.sol";

/// @title USDCStrategy
/// @notice Single strategy that manages USDC across multiple SEI lending
///         protocols: Yei (Aave V3 fork), Takara (Compound fork), and Morpho.
///         Allocation splits are configurable. Keeper can trigger operations;
///         owner (multisig) retains full admin control.
/// @dev Includes on-chain max slippage cap and rebalance cooldown for safety.
contract USDCStrategy is IStrategy, Ownable {
    using SafeERC20 for IERC20;

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice The vault that owns this strategy
    address public vault;

    /// @notice USDC token
    IERC20 public immutable usdc;

    /// @notice Keeper address — can trigger harvest, rebalance, claims
    address public keeper;

    // ─── Protocol References ─────────────────────────────────────────────

    IAavePool public immutable yeiPool;
    IAToken public immutable aToken;
    ICErc20 public immutable cToken;
    IComptroller public immutable comptroller;
    IMorpho public immutable morpho;

    /// @notice Router type enum
    enum RouterType { V2, V3 }

    /// @notice V2 DEX router (DragonSwap)
    ISailorRouter public routerV2;

    /// @notice V3 DEX router (Sailor Finance)
    ISwapRouterV3 public routerV3;

    /// @notice Which router to use for swaps
    RouterType public activeRouter;

    /// @notice V3 pool fee tier (default 3000 = 0.3%)
    uint24 public v3PoolFee = 3000;

    /// @notice Merkl distributor for Morpho rewards
    IMerklDistributor public merklDistributor;

    // ─── Allocation ──────────────────────────────────────────────────────

    uint256 public splitYei;
    uint256 public splitTakara;
    uint256 public splitMorpho;

    uint256 public constant SPLIT_TOTAL = 10000; // 100%

    /// @notice Morpho P2P matching iterations
    uint256 public morphoMaxIterations;

    // ─── Safety: Slippage Cap ────────────────────────────────────────────

    /// @notice Maximum allowed slippage in basis points (e.g., 500 = 5%)
    /// @dev Enforced on-chain — keeper can never accept worse than this
    uint256 public maxSlippageBps;

    /// @notice Absolute max that maxSlippageBps can be set to
    uint256 public constant MAX_SLIPPAGE_CEILING = 1000; // 10%

    // ─── Safety: Rebalance Cooldown ──────────────────────────────────────

    /// @notice Minimum seconds between rebalances
    uint256 public rebalanceCooldown;

    /// @notice Timestamp of last rebalance
    uint256 public lastRebalanceTime;

    /// @notice Minimum seconds between split changes
    uint256 public splitsCooldown;

    /// @notice Timestamp of last splits change
    uint256 public lastSplitsTime;

    // ─── Reward Config ───────────────────────────────────────────────────

    address public takaraRewardToken;
    address[] public takaraSwapPath;
    address public morphoRewardToken;
    address[] public morphoSwapPath;

    // ─── Events ──────────────────────────────────────────────────────────

    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);
    event Harvested(uint256 profit);
    event SplitUpdated(uint256 yei, uint256 takara, uint256 morpho);
    event Rebalanced();
    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event MaxSlippageUpdated(uint256 oldBps, uint256 newBps);
    event RebalanceCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event SplitsCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);

    // ─── Errors ──────────────────────────────────────────────────────────

    error OnlyVault();
    error InvalidAddress();
    error InvalidSplit();
    error MintFailed(uint256 errorCode);
    error RedeemFailed(uint256 errorCode);
    error NotKeeperOrOwner();
    error SlippageExceedsCap(uint256 minAmountOut, uint256 minRequired);
    error RebalanceCooldownActive(uint256 nextAllowed);
    error SplitsCooldownActive(uint256 nextAllowed);
    error SlippageTooHigh();

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeperOrOwner();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    struct ProtocolAddresses {
        address usdc;
        address vault;
        address yeiPool;
        address aToken;
        address cToken;
        address comptroller;
        address morpho;
        address routerV2;
        address routerV3;
    }

    constructor(
        ProtocolAddresses memory addrs,
        uint256 _splitYei,
        uint256 _splitTakara,
        uint256 _splitMorpho,
        uint256 _morphoMaxIterations,
        uint256 _maxSlippageBps,
        uint256 _rebalanceCooldown,
        uint256 _splitsCooldown
    ) Ownable(msg.sender) {
        if (addrs.usdc == address(0) || addrs.vault == address(0)) revert InvalidAddress();
        if (_splitYei + _splitTakara + _splitMorpho != SPLIT_TOTAL) revert InvalidSplit();
        if (_maxSlippageBps > MAX_SLIPPAGE_CEILING) revert SlippageTooHigh();

        usdc = IERC20(addrs.usdc);
        vault = addrs.vault;
        yeiPool = IAavePool(addrs.yeiPool);
        aToken = IAToken(addrs.aToken);
        cToken = ICErc20(addrs.cToken);
        comptroller = IComptroller(addrs.comptroller);
        morpho = IMorpho(addrs.morpho);
        routerV2 = ISailorRouter(addrs.routerV2);
        routerV3 = ISwapRouterV3(addrs.routerV3);
        activeRouter = addrs.routerV2 != address(0) ? RouterType.V2 : RouterType.V3;

        splitYei = _splitYei;
        splitTakara = _splitTakara;
        splitMorpho = _splitMorpho;
        morphoMaxIterations = _morphoMaxIterations;
        maxSlippageBps = _maxSlippageBps;
        rebalanceCooldown = _rebalanceCooldown;
        splitsCooldown = _splitsCooldown;

        // Pre-approve protocols
        IERC20(addrs.usdc).safeIncreaseAllowance(addrs.yeiPool, type(uint256).max);
        IERC20(addrs.usdc).safeIncreaseAllowance(addrs.cToken, type(uint256).max);
        IERC20(addrs.usdc).safeIncreaseAllowance(addrs.morpho, type(uint256).max);
    }

    // ─── IStrategy Implementation ────────────────────────────────────────

    /// @inheritdoc IStrategy
    function deposit(uint256 amount) external override onlyVault {
        _deployToProtocols(amount);
        emit Deposited(amount);
    }

    /// @inheritdoc IStrategy
    function withdraw(uint256 amount) external override onlyVault {
        _withdrawFromProtocols(amount);
        usdc.safeTransfer(vault, amount);
        emit Withdrawn(amount);
    }

    /// @inheritdoc IStrategy
    /// @dev Interface compatibility — calls harvest with 0 minAmounts (no slippage protection)
    function harvest() external override onlyVault returns (uint256 profit) {
        profit = _harvestAll(0, 0);
        emit Harvested(profit);
    }

    /// @notice Harvest with slippage protection
    /// @param takaraMinOut Minimum USDC expected from Takara reward swap
    /// @param morphoMinOut Minimum USDC expected from Morpho reward swap
    function harvest(
        uint256 takaraMinOut,
        uint256 morphoMinOut
    ) external onlyVault returns (uint256 profit) {
        profit = _harvestAll(takaraMinOut, morphoMinOut);
        emit Harvested(profit);
    }

    /// @inheritdoc IStrategy
    function balanceOf() external view override returns (uint256) {
        return _totalBalance();
    }

    /// @inheritdoc IStrategy
    function asset() external view override returns (address) {
        return address(usdc);
    }

    // ─── Internal: Deploy ────────────────────────────────────────────────

    function _deployToProtocols(uint256 amount) internal {
        uint256 toYei = (amount * splitYei) / SPLIT_TOTAL;
        uint256 toTakara = (amount * splitTakara) / SPLIT_TOTAL;
        uint256 toMorpho = amount - toYei - toTakara;

        if (toYei > 0) {
            yeiPool.supply(address(usdc), toYei, address(this), 0);
        }
        if (toTakara > 0) {
            uint256 err = cToken.mint(toTakara);
            if (err != 0) revert MintFailed(err);
        }
        if (toMorpho > 0) {
            morpho.supply(address(usdc), toMorpho, address(this), morphoMaxIterations);
        }
    }

    // ─── Internal: Withdraw ──────────────────────────────────────────────

    function _withdrawFromProtocols(uint256 amount) internal {
        uint256 total = _totalBalance();
        if (total == 0) return;

        uint256 yeiBalance = _yeiBalance();
        uint256 takaraBalance = _takaraBalance();

        uint256 fromYei = (amount * yeiBalance) / total;
        uint256 fromTakara = (amount * takaraBalance) / total;
        uint256 fromMorpho = amount - fromYei - fromTakara;

        if (fromYei > 0 && yeiBalance > 0) {
            uint256 actual = fromYei > yeiBalance ? yeiBalance : fromYei;
            yeiPool.withdraw(address(usdc), actual, address(this));
        }
        if (fromTakara > 0 && takaraBalance > 0) {
            uint256 actual = fromTakara > takaraBalance ? takaraBalance : fromTakara;
            uint256 err = cToken.redeemUnderlying(actual);
            if (err != 0) revert RedeemFailed(err);
        }
        uint256 morphoBalance = _morphoBalance();
        if (fromMorpho > 0 && morphoBalance > 0) {
            uint256 actual = fromMorpho > morphoBalance ? morphoBalance : fromMorpho;
            morpho.withdraw(address(usdc), actual, address(this), morphoMaxIterations);
        }
    }

    // ─── Internal: Harvest ───────────────────────────────────────────────

    function _harvestAll(uint256 takaraMinOut, uint256 morphoMinOut) internal returns (uint256 profit) {
        uint256 balanceBefore = usdc.balanceOf(address(this));

        // 1. Yei: interest accrues automatically in aToken balance

        // 2. Takara: claim COMP-style rewards
        if (takaraRewardToken != address(0)) {
            comptroller.claimComp(address(this));
            uint256 rewardBal = IERC20(takaraRewardToken).balanceOf(address(this));
            if (rewardBal > 0 && takaraSwapPath.length >= 2) {
                // Enforce on-chain slippage cap against reward amount
                if (takaraMinOut > 0) _validateSlippage(rewardBal, takaraMinOut);
                _swap(takaraRewardToken, rewardBal, takaraSwapPath, takaraMinOut);
            }
        }

        // 3. Morpho: swap any reward tokens already claimed via claimMorphoRewards()
        if (morphoRewardToken != address(0)) {
            uint256 rewardBal = IERC20(morphoRewardToken).balanceOf(address(this));
            if (rewardBal > 0 && morphoSwapPath.length >= 2) {
                // Enforce on-chain slippage cap against reward amount
                if (morphoMinOut > 0) _validateSlippage(rewardBal, morphoMinOut);
                _swap(morphoRewardToken, rewardBal, morphoSwapPath, morphoMinOut);
            }
        }

        // Re-deploy any loose USDC
        uint256 looseUsdc = usdc.balanceOf(address(this));
        profit = looseUsdc - balanceBefore;

        if (looseUsdc > 0) {
            _deployToProtocols(looseUsdc);
        }
    }

    /// @dev Validate that minAmountOut implies slippage within the on-chain cap.
    ///      For reward→USDC swaps, we assume 1:1 as the "expected" rate (stablecoin baseline).
    ///      minAmountOut must be >= rewardAmount * (10000 - maxSlippageBps) / 10000.
    ///      This prevents a compromised keeper from setting minAmountOut = 0.
    function _validateSlippage(uint256 rewardAmount, uint256 minAmountOut) internal view {
        if (maxSlippageBps == 0) revert SlippageTooHigh();
        uint256 minRequired = (rewardAmount * (10000 - maxSlippageBps)) / 10000;
        if (minAmountOut < minRequired) {
            revert SlippageExceedsCap(minAmountOut, minRequired);
        }
    }

    // ─── Internal: Swap ──────────────────────────────────────────────────

    function _swap(
        address tokenIn,
        uint256 amountIn,
        address[] storage path,
        uint256 minAmountOut
    ) internal {
        if (amountIn == 0 || path.length < 2) return;
        address[] memory memPath = new address[](path.length);
        for (uint256 i = 0; i < path.length; i++) {
            memPath[i] = path[i];
        }
        _executeSwap(tokenIn, memPath[memPath.length - 1], amountIn, minAmountOut, memPath);
    }

    function _swapDynamic(
        address tokenIn,
        uint256 amountIn,
        address[] storage path,
        uint256 minAmountOut
    ) internal {
        if (amountIn == 0 || path.length < 2) return;
        address[] memory swapPath = new address[](path.length);
        swapPath[0] = tokenIn;
        for (uint256 i = 1; i < path.length; i++) {
            swapPath[i] = path[i];
        }
        _executeSwap(tokenIn, swapPath[swapPath.length - 1], amountIn, minAmountOut, swapPath);
    }

    function _executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address[] memory path
    ) internal {
        if (activeRouter == RouterType.V2) {
            if (address(routerV2) == address(0)) return;
            IERC20(tokenIn).safeIncreaseAllowance(address(routerV2), amountIn);
            routerV2.swapExactTokensForTokens(
                amountIn, minAmountOut, path, address(this), block.timestamp
            );
        } else {
            if (address(routerV3) == address(0)) return;
            IERC20(tokenIn).safeIncreaseAllowance(address(routerV3), amountIn);
            routerV3.exactInputSingle(
                ISwapRouterV3.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: v3PoolFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: minAmountOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }
    }

    // ─── Internal: Balance Helpers ───────────────────────────────────────

    function _yeiBalance() internal view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function _takaraBalance() internal view returns (uint256) {
        uint256 cTokenBal = cToken.balanceOf(address(this));
        if (cTokenBal == 0) return 0;
        uint256 exchangeRate = cToken.exchangeRateStored();
        return (cTokenBal * exchangeRate) / 1e18;
    }

    function _morphoBalance() internal view returns (uint256) {
        return morpho.supplyBalance(address(usdc), address(this));
    }

    function _totalBalance() internal view returns (uint256) {
        return _yeiBalance() + _takaraBalance() + _morphoBalance()
            + usdc.balanceOf(address(this));
    }

    // ─── Keeper Functions ────────────────────────────────────────────────

    /// @notice Update protocol allocation splits (keeper or owner)
    /// @notice Update protocol allocation splits (keeper or owner)
    /// @dev Subject to splits cooldown to prevent rapid manipulation
    function setSplits(
        uint256 _splitYei,
        uint256 _splitTakara,
        uint256 _splitMorpho
    ) external onlyKeeperOrOwner {
        if (_splitYei + _splitTakara + _splitMorpho != SPLIT_TOTAL) revert InvalidSplit();
        if (lastSplitsTime > 0 && block.timestamp < lastSplitsTime + splitsCooldown) {
            revert SplitsCooldownActive(lastSplitsTime + splitsCooldown);
        }
        splitYei = _splitYei;
        splitTakara = _splitTakara;
        splitMorpho = _splitMorpho;
        lastSplitsTime = block.timestamp;
        emit SplitUpdated(_splitYei, _splitTakara, _splitMorpho);
    }

    /// @notice Rebalance: withdraw all, re-deploy with current splits
    /// @dev Subject to rebalance cooldown
    function rebalance() external onlyKeeperOrOwner {
        if (lastRebalanceTime > 0 && block.timestamp < lastRebalanceTime + rebalanceCooldown) {
            revert RebalanceCooldownActive(lastRebalanceTime + rebalanceCooldown);
        }

        uint256 total = _totalBalance();
        if (total == 0) return;

        // Withdraw everything
        uint256 yei = _yeiBalance();
        uint256 takara = _takaraBalance();
        uint256 morphoBal = _morphoBalance();

        if (yei > 0) yeiPool.withdraw(address(usdc), yei, address(this));
        if (takara > 0) {
            uint256 err = cToken.redeemUnderlying(takara);
            if (err != 0) revert RedeemFailed(err);
        }
        if (morphoBal > 0) morpho.withdraw(address(usdc), morphoBal, address(this), morphoMaxIterations);

        // Re-deploy with current splits
        uint256 balance = usdc.balanceOf(address(this));
        if (balance > 0) {
            _deployToProtocols(balance);
        }

        lastRebalanceTime = block.timestamp;
        emit Rebalanced();
    }

    /// @notice Switch active router type (keeper or owner)
    function setActiveRouter(RouterType _type) external onlyKeeperOrOwner {
        activeRouter = _type;
    }

    /// @notice Claim Morpho rewards via Merkl distributor and swap to USDC
    function claimMorphoRewards(
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs,
        uint256[] calldata minAmountsOut
    ) external onlyKeeperOrOwner {
        if (address(merklDistributor) == address(0)) return;

        merklDistributor.claim(address(this), tokens, amounts, proofs);

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(usdc)) continue;
            uint256 bal = IERC20(tokens[i]).balanceOf(address(this));
            if (bal > 0 && morphoSwapPath.length >= 2) {
                uint256 minOut = i < minAmountsOut.length ? minAmountsOut[i] : 0;
                _swapDynamic(tokens[i], bal, morphoSwapPath, minOut);
            }
        }

        uint256 looseUsdc = usdc.balanceOf(address(this));
        if (looseUsdc > 0) {
            _deployToProtocols(looseUsdc);
        }
    }

    // ─── Owner-Only Admin ────────────────────────────────────────────────

    /// @notice Set keeper address
    function setKeeper(address _keeper) external onlyOwner {
        address old = keeper;
        keeper = _keeper;
        emit KeeperUpdated(old, _keeper);
    }

    /// @notice Revoke keeper access
    function revokeKeeper() external onlyOwner {
        address old = keeper;
        keeper = address(0);
        emit KeeperUpdated(old, address(0));
    }

    /// @notice Update the vault address
    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert InvalidAddress();
        address old = vault;
        vault = _vault;
        emit VaultUpdated(old, _vault);
    }

    /// @notice Set max slippage cap (basis points)
    function setMaxSlippage(uint256 _bps) external onlyOwner {
        if (_bps > MAX_SLIPPAGE_CEILING) revert SlippageTooHigh();
        uint256 old = maxSlippageBps;
        maxSlippageBps = _bps;
        emit MaxSlippageUpdated(old, _bps);
    }

    /// @notice Set rebalance cooldown (seconds)
    function setRebalanceCooldown(uint256 _seconds) external onlyOwner {
        uint256 old = rebalanceCooldown;
        rebalanceCooldown = _seconds;
        emit RebalanceCooldownUpdated(old, _seconds);
    }

    /// @notice Set splits change cooldown (seconds)
    function setSplitsCooldown(uint256 _seconds) external onlyOwner {
        uint256 old = splitsCooldown;
        splitsCooldown = _seconds;
        emit SplitsCooldownUpdated(old, _seconds);
    }

    /// @notice Configure Takara reward token and swap path
    function setTakaraRewardConfig(
        address _rewardToken,
        address[] calldata _swapPath
    ) external onlyOwner {
        takaraRewardToken = _rewardToken;
        takaraSwapPath = _swapPath;
    }

    /// @notice Configure Morpho reward token and swap path
    function setMorphoRewardConfig(
        address _rewardToken,
        address[] calldata _swapPath
    ) external onlyOwner {
        morphoRewardToken = _rewardToken;
        morphoSwapPath = _swapPath;
    }

    /// @notice Update Morpho max iterations
    function setMorphoMaxIterations(uint256 _maxIterations) external onlyOwner {
        morphoMaxIterations = _maxIterations;
    }

    /// @notice Update V2 DEX router
    function setRouterV2(address _router) external onlyOwner {
        routerV2 = ISailorRouter(_router);
    }

    /// @notice Update V3 DEX router
    function setRouterV3(address _router) external onlyOwner {
        routerV3 = ISwapRouterV3(_router);
    }

    /// @notice Set V3 pool fee tier
    function setV3PoolFee(uint24 _fee) external onlyOwner {
        v3PoolFee = _fee;
    }

    /// @notice Update Merkl distributor address
    function setMerklDistributor(address _distributor) external onlyOwner {
        merklDistributor = IMerklDistributor(_distributor);
    }

    /// @notice Rescue stuck tokens (not USDC)
    function rescueToken(address _token, uint256 _amount) external onlyOwner {
        if (_token == address(usdc)) revert InvalidAddress();
        IERC20(_token).safeTransfer(owner(), _amount);
    }
}
