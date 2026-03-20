// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IAavePool} from "./interfaces/external/IAavePool.sol";
import {IAToken} from "./interfaces/external/IAToken.sol";
import {ICErc20} from "./interfaces/external/ICErc20.sol";
import {IComptroller} from "./interfaces/external/IComptroller.sol";
import {IMetaMorpho} from "./interfaces/external/IMetaMorpho.sol";
import {IMerklDistributor} from "./interfaces/external/IMerklDistributor.sol";
import {ISailorRouter} from "./interfaces/external/ISailorRouter.sol";
import {ISwapRouterV3} from "./interfaces/external/ISwapRouterV3.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SEIStrategy
/// @notice Single strategy that manages WSEI across multiple SEI lending
///         protocols with dynamic yield sources and DEX routers.
///         Allocation splits are configurable. Keeper can trigger operations;
///         owner (multisig) retains full admin control.
/// @dev Includes on-chain max slippage cap and rebalance cooldown for safety.
contract SEIStrategy is IStrategy, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Enums ───────────────────────────────────────────────────────────

    /// @notice Protocol type enum
    enum ProtocolType { Aave, Compound, Morpho }

    /// @notice Router type enum
    enum RouterType { V2, V3 }

    // ─── Structs ─────────────────────────────────────────────────────────

    /// @notice Yield source configuration
    struct YieldSource {
        ProtocolType protocolType;
        bool enabled;
        uint256 split; // basis points
        address protocolAddress; // yeiPool for Aave, cToken for Compound, morpho for Morpho
        address receiptToken; // aToken for Aave, cToken for Compound, unused for Morpho
        address comptroller; // Only for Compound
        address rewardToken;
        address[] swapPath;
        uint256 morphoMaxIterations; // Only for Morpho
    }

    /// @notice DEX router configuration
    struct DexRouter {
        address routerAddress;
        RouterType routerType;
        bool enabled;
        string label;
    }

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice The vault that owns this strategy
    address public vault;

    /// @notice WSEI token (18 decimals)
    IERC20 public immutable wsei;

    /// @notice Keeper address — can trigger harvest, rebalance, claims
    address public keeper;

    /// @notice Guardian address — can pause in emergencies
    address public guardian;

    /// @notice Dynamic yield sources
    YieldSource[] public yieldSources;

    /// @notice Dynamic DEX routers
    DexRouter[] public routers;

    /// @notice Active router index
    uint256 public activeRouterIndex;

    /// @notice V3 pool fee tier (default 3000 = 0.3%)
    uint24 public v3PoolFee = 3000;

    /// @notice Merkl distributor for Morpho rewards
    IMerklDistributor public merklDistributor;

    // ─── Constants ───────────────────────────────────────────────────────

    uint256 public constant SPLIT_TOTAL = 10000; // 100%
    uint256 public constant MAX_YIELD_SOURCES = 10;

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

    // ─── Events ──────────────────────────────────────────────────────────

    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);
    event Harvested(uint256 profit);
    event SplitUpdated(uint256 yei, uint256 takara, uint256 morpho); // Legacy event
    event YieldSourceAdded(uint256 indexed index, ProtocolType protocolType);
    event YieldSourceRemoved(uint256 indexed index);
    event YieldSourceSplitUpdated(uint256 indexed index, uint256 newSplit);
    event YieldSourceEnabled(uint256 indexed index, bool enabled);
    event RouterAdded(uint256 indexed index, address routerAddress, RouterType routerType);
    event RouterRemoved(uint256 indexed index);
    event ActiveRouterSet(uint256 indexed index);
    event Rebalanced();
    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event MaxSlippageUpdated(uint256 oldBps, uint256 newBps);
    event RebalanceCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event SplitsCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event V3PoolFeeUpdated(uint24 oldFee, uint24 newFee);

    // ─── Errors ──────────────────────────────────────────────────────────

    error OnlyVault();
    error InvalidAddress();
    error InvalidSplit();
    error InvalidIndex();
    error MintFailed(uint256 errorCode);
    error RedeemFailed(uint256 errorCode);
    error NotKeeperOrOwner();
    error NotGuardianOrOwner();
    error SlippageExceedsCap(uint256 minAmountOut, uint256 minRequired);
    error RebalanceCooldownActive(uint256 nextAllowed);
    error SplitsCooldownActive(uint256 nextAllowed);
    error SlippageTooHigh();
    error TooManyYieldSources();
    error InvalidMinAmountsLength();
    error MorphoSupplyFailed();
    error AaveWithdrawFailed();
    error MorphoWithdrawFailed();
    error V2SwapFailed();
    error V3SwapFailed();

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeperOrOwner();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    struct ProtocolAddresses {
        address wsei;
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
        if (addrs.wsei == address(0) || addrs.vault == address(0)) revert InvalidAddress();
        if (_splitYei + _splitTakara + _splitMorpho != SPLIT_TOTAL) revert InvalidSplit();
        if (_maxSlippageBps > MAX_SLIPPAGE_CEILING) revert SlippageTooHigh();

        wsei = IERC20(addrs.wsei);
        vault = addrs.vault;
        maxSlippageBps = _maxSlippageBps;
        rebalanceCooldown = _rebalanceCooldown;
        splitsCooldown = _splitsCooldown;

        // Initialize with 3 default yield sources (backward compatible)
        // 1. Yei (Aave)
        if (addrs.yeiPool != address(0) && addrs.aToken != address(0)) {
            yieldSources.push(YieldSource({
                protocolType: ProtocolType.Aave,
                enabled: _splitYei > 0,
                split: _splitYei,
                protocolAddress: addrs.yeiPool,
                receiptToken: addrs.aToken,
                comptroller: address(0),
                rewardToken: address(0),
                swapPath: new address[](0),
                morphoMaxIterations: 0
            }));
            IERC20(addrs.wsei).safeIncreaseAllowance(addrs.yeiPool, type(uint256).max);
        }

        // 2. Takara (Compound)
        if (addrs.cToken != address(0) && addrs.comptroller != address(0)) {
            yieldSources.push(YieldSource({
                protocolType: ProtocolType.Compound,
                enabled: _splitTakara > 0,
                split: _splitTakara,
                protocolAddress: addrs.cToken,
                receiptToken: addrs.cToken,
                comptroller: addrs.comptroller,
                rewardToken: address(0),
                swapPath: new address[](0),
                morphoMaxIterations: 0
            }));
            IERC20(addrs.wsei).safeIncreaseAllowance(addrs.cToken, type(uint256).max);
        }

        // 3. Morpho
        if (addrs.morpho != address(0)) {
            yieldSources.push(YieldSource({
                protocolType: ProtocolType.Morpho,
                enabled: _splitMorpho > 0,
                split: _splitMorpho,
                protocolAddress: addrs.morpho,
                receiptToken: address(0),
                comptroller: address(0),
                rewardToken: address(0),
                swapPath: new address[](0),
                morphoMaxIterations: _morphoMaxIterations
            }));
            IERC20(addrs.wsei).safeIncreaseAllowance(addrs.morpho, type(uint256).max);
        }

        // Initialize routers
        if (addrs.routerV2 != address(0)) {
            routers.push(DexRouter({
                routerAddress: addrs.routerV2,
                routerType: RouterType.V2,
                enabled: true,
                label: "DragonSwap"
            }));
        }

        if (addrs.routerV3 != address(0)) {
            routers.push(DexRouter({
                routerAddress: addrs.routerV3,
                routerType: RouterType.V3,
                enabled: true,
                label: "Sailor"
            }));
        }

        // Set active router to first available
        activeRouterIndex = 0;
    }

    // ─── IStrategy Implementation ────────────────────────────────────────

    /// @inheritdoc IStrategy
    function deposit(uint256 amount) external override onlyVault whenNotPaused nonReentrant {
        _deployToProtocols(amount);
        emit Deposited(amount);
    }

    /// @inheritdoc IStrategy
    function withdraw(uint256 amount) external override onlyVault whenNotPaused nonReentrant {
        _withdrawFromProtocols(amount);
        // Transfer actual balance (may be slightly less than requested due to protocol rounding)
        uint256 actual = wsei.balanceOf(address(this));
        if (actual < amount) amount = actual;
        wsei.safeTransfer(vault, amount);
        emit Withdrawn(amount);
    }

    /// @inheritdoc IStrategy
    /// @param minAmountsOut Minimum WSEI expected from each yield source's reward swap
    function harvest(
        uint256[] calldata minAmountsOut
    ) external override onlyVault whenNotPaused nonReentrant returns (uint256 profit) {
        if (minAmountsOut.length != yieldSources.length) revert InvalidMinAmountsLength();
        profit = _harvestAll(minAmountsOut);
        emit Harvested(profit);
    }

    /// @inheritdoc IStrategy
    function balanceOf() external view override returns (uint256) {
        return _totalBalance();
    }

    /// @inheritdoc IStrategy
    function asset() external view override returns (address) {
        return address(wsei);
    }

    // ─── Internal: Deploy ────────────────────────────────────────────────

    // slither-disable-start incorrect-equality
    function _deployToProtocols(uint256 amount) internal {
        uint256 len = yieldSources.length;
        for (uint256 i = 0; i < len; i++) {
            YieldSource storage source = yieldSources[i];
            if (!source.enabled) continue;

            uint256 toSource = (amount * source.split) / SPLIT_TOTAL;
            if (toSource == 0) continue;

            if (source.protocolType == ProtocolType.Aave) {
                IAavePool(source.protocolAddress).supply(address(wsei), toSource, address(this), 0);
            } else if (source.protocolType == ProtocolType.Compound) {
                uint256 err = ICErc20(source.protocolAddress).mint(toSource);
                if (err != 0) revert MintFailed(err);
            } else if (source.protocolType == ProtocolType.Morpho) {
                // Feather vault is a MetaMorpho ERC-4626 vault — use deposit()
                // Cap deposit to maxDeposit to avoid revert when vault is at capacity
                uint256 maxDep = IMetaMorpho(source.protocolAddress).maxDeposit(address(this));
                uint256 depositAmount = toSource > maxDep ? maxDep : toSource;
                if (depositAmount > 0) {
                    IMetaMorpho(source.protocolAddress).deposit(depositAmount, address(this));
                }
            }
        }
    }
    // slither-disable-end incorrect-equality

    // ─── Internal: Withdraw ──────────────────────────────────────────────

    // slither-disable-start reentrancy-balance
    // slither-disable-start incorrect-equality
    function _withdrawFromProtocols(uint256 amount) internal {
        uint256 total = _totalBalanceFresh();
        if (total == 0) return;

        uint256 len = yieldSources.length;
        for (uint256 i = 0; i < len; i++) {
            YieldSource storage source = yieldSources[i];
            if (!source.enabled) continue;

            uint256 sourceBalance = _getSourceBalance(source);
            if (sourceBalance == 0) continue;

            uint256 fromSource = (amount * sourceBalance) / total;
            if (fromSource == 0) continue;

            uint256 actual = fromSource > sourceBalance ? sourceBalance : fromSource;

            if (source.protocolType == ProtocolType.Aave) {
                uint256 withdrawn = IAavePool(source.protocolAddress).withdraw(address(wsei), actual, address(this));
                if (withdrawn == 0) revert AaveWithdrawFailed();
            } else if (source.protocolType == ProtocolType.Compound) {
                uint256 err = ICErc20(source.protocolAddress).redeemUnderlying(actual);
                if (err != 0) revert RedeemFailed(err);
            } else if (source.protocolType == ProtocolType.Morpho) {
                // MetaMorpho ERC-4626 — withdraw exact assets; skip if illiquid
                try IMetaMorpho(source.protocolAddress).withdraw(actual, address(this), address(this))
                    returns (uint256) {}
                catch {}
            }
        }

        // Handle any remaining deficit due to rounding by pulling from first available protocol
        uint256 balance = wsei.balanceOf(address(this));
        if (balance < amount) {
            uint256 deficit = amount - balance;

            for (uint256 i = 0; i < len; i++) {
                YieldSource storage source = yieldSources[i];
                if (!source.enabled) continue;

                uint256 sourceBalance = _getSourceBalance(source);
                if (sourceBalance == 0) continue;

                uint256 toWithdraw = deficit > sourceBalance ? sourceBalance : deficit;

                if (source.protocolType == ProtocolType.Aave) {
                    uint256 withdrawn = IAavePool(source.protocolAddress).withdraw(address(wsei), toWithdraw, address(this));
                    if (withdrawn == 0) revert AaveWithdrawFailed();
                } else if (source.protocolType == ProtocolType.Compound) {
                    uint256 err = ICErc20(source.protocolAddress).redeemUnderlying(toWithdraw);
                    if (err != 0) revert RedeemFailed(err);
                } else if (source.protocolType == ProtocolType.Morpho) {
                    try IMetaMorpho(source.protocolAddress).withdraw(toWithdraw, address(this), address(this))
                        returns (uint256) {}
                    catch {}
                }

                balance = wsei.balanceOf(address(this));
                if (balance >= amount) break;
            }
        }
    }
    // slither-disable-end incorrect-equality
    // slither-disable-end reentrancy-balance

    // ─── Internal: Harvest ───────────────────────────────────────────────

    function _harvestAll(uint256[] memory minAmountsOut) internal returns (uint256 profit) {
        uint256 balanceBefore = wsei.balanceOf(address(this));

        uint256 len = yieldSources.length;
        for (uint256 i = 0; i < len; i++) {
            YieldSource storage source = yieldSources[i];
            if (!source.enabled) continue;

            // Handle protocol-specific reward claiming
            if (source.protocolType == ProtocolType.Compound && source.comptroller != address(0)) {
                IComptroller(source.comptroller).claimComp(address(this));
            }

            // Swap rewards if configured
            if (source.rewardToken != address(0) && source.swapPath.length >= 2) {
                uint256 rewardBal = IERC20(source.rewardToken).balanceOf(address(this));
                if (rewardBal > 0) {
                    uint256 minOut = minAmountsOut[i];
                    uint8 rewardDecimals = ERC20(source.rewardToken).decimals();
                    _validateSlippage(rewardBal, minOut, rewardDecimals, 18);
                    _swap(source.rewardToken, rewardBal, source.swapPath, minOut);
                }
            }
        }

        // Re-deploy any loose WSEI
        uint256 looseWsei = wsei.balanceOf(address(this));
        profit = looseWsei - balanceBefore;

        if (looseWsei > 0) {
            _deployToProtocols(looseWsei);
        }
    }

    /// @dev Validate that minAmountOut implies slippage within the on-chain cap.
    ///      Normalizes reward amount to asset decimals before comparison.
    ///      This prevents a compromised keeper from setting minAmountOut = 0.
    function _validateSlippage(
        uint256 rewardAmount,
        uint256 minAmountOut,
        uint8 rewardDecimals,
        uint8 assetDecimals
    ) internal view {
        if (maxSlippageBps == 0) revert SlippageTooHigh();
        uint256 normalizedReward = rewardAmount;
        if (rewardDecimals > assetDecimals) {
            normalizedReward = rewardAmount / (10 ** (rewardDecimals - assetDecimals));
        } else if (assetDecimals > rewardDecimals) {
            normalizedReward = rewardAmount * (10 ** (assetDecimals - rewardDecimals));
        }
        uint256 minRequired = (normalizedReward * (10000 - maxSlippageBps)) / 10000;
        if (minAmountOut < minRequired) {
            revert SlippageExceedsCap(minAmountOut, minRequired);
        }
    }

    // ─── Internal: Swap ──────────────────────────────────────────────────

    // slither-disable-start incorrect-equality
    function _swap(
        address tokenIn,
        uint256 amountIn,
        address[] storage path,
        uint256 minAmountOut
    ) internal {
        if (amountIn == 0 || path.length < 2) return;
        if (routers.length == 0 || activeRouterIndex >= routers.length) return;

        DexRouter storage router = routers[activeRouterIndex];
        if (!router.enabled || router.routerAddress == address(0)) return;

        address[] memory memPath = new address[](path.length);
        for (uint256 i = 0; i < path.length; i++) {
            memPath[i] = path[i];
        }

        _executeSwap(router, tokenIn, memPath[memPath.length - 1], amountIn, minAmountOut, memPath);
    }

    function _swapDynamic(
        address tokenIn,
        uint256 amountIn,
        address[] storage path,
        uint256 minAmountOut
    ) internal {
        if (amountIn == 0 || path.length < 2) return;
        if (routers.length == 0 || activeRouterIndex >= routers.length) return;

        DexRouter storage router = routers[activeRouterIndex];
        if (!router.enabled || router.routerAddress == address(0)) return;

        address[] memory swapPath = new address[](path.length);
        swapPath[0] = tokenIn;
        for (uint256 i = 1; i < path.length; i++) {
            swapPath[i] = path[i];
        }

        _executeSwap(router, tokenIn, swapPath[swapPath.length - 1], amountIn, minAmountOut, swapPath);
    }

    function _executeSwap(
        DexRouter storage router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address[] memory path
    ) internal {
        IERC20(tokenIn).safeIncreaseAllowance(router.routerAddress, amountIn);

        if (router.routerType == RouterType.V2) {
            uint256[] memory amounts = ISailorRouter(router.routerAddress).swapExactTokensForTokens(
                amountIn, minAmountOut, path, address(this), block.timestamp
            );
            if (amounts.length == 0) revert V2SwapFailed();
        } else {
            uint256 amountOut = ISwapRouterV3(router.routerAddress).exactInputSingle(
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
            if (amountOut == 0) revert V3SwapFailed();
        }
    }

    // ─── Internal: Balance Helpers ───────────────────────────────────────

    function _getSourceBalance(YieldSource storage source) internal view returns (uint256) {
        if (source.protocolType == ProtocolType.Aave) {
            return IAToken(source.receiptToken).balanceOf(address(this));
        } else if (source.protocolType == ProtocolType.Compound) {
            uint256 cTokenBal = IERC20(source.receiptToken).balanceOf(address(this));
            if (cTokenBal == 0) return 0;
            uint256 exchangeRate = ICErc20(source.receiptToken).exchangeRateStored();
            return (cTokenBal * exchangeRate) / 1e18;
        } else if (source.protocolType == ProtocolType.Morpho) {
            // MetaMorpho ERC-4626: convert our share balance to asset value
            uint256 shares = IMetaMorpho(source.protocolAddress).balanceOf(address(this));
            if (shares == 0) return 0;
            return IMetaMorpho(source.protocolAddress).convertToAssets(shares);
        }
        return 0;
    }

    function _totalBalance() internal view returns (uint256 total) {
        uint256 len = yieldSources.length;
        for (uint256 i = 0; i < len; i++) {
            if (yieldSources[i].enabled) {
                total += _getSourceBalance(yieldSources[i]);
            }
        }
        total += wsei.balanceOf(address(this));
    }

    /// @dev Get source balance with fresh exchange rate (non-view, accrues interest)
    function _getSourceBalanceFresh(YieldSource storage source) internal returns (uint256) {
        if (source.protocolType == ProtocolType.Compound) {
            uint256 cTokenBal = IERC20(source.receiptToken).balanceOf(address(this));
            if (cTokenBal == 0) return 0;
            uint256 exchangeRate = ICErc20(source.receiptToken).exchangeRateCurrent();
            return (cTokenBal * exchangeRate) / 1e18;
        }
        return _getSourceBalance(source);
    }

    /// @dev Total balance using fresh exchange rates (non-view, accrues interest)
    function _totalBalanceFresh() internal returns (uint256 total) {
        uint256 len = yieldSources.length;
        for (uint256 i = 0; i < len; i++) {
            if (yieldSources[i].enabled) {
                total += _getSourceBalanceFresh(yieldSources[i]);
            }
        }
        total += wsei.balanceOf(address(this));
    }
    // slither-disable-end incorrect-equality

    // ─── Yield Source Management ─────────────────────────────────────────

    /// @notice Add a new yield source (owner only)
    function addYieldSource(
        ProtocolType _protocolType,
        bool _enabled,
        uint256 _split,
        address _protocolAddress,
        address _receiptToken,
        address _comptrollerAddress,
        address _rewardToken,
        address[] calldata _swapPath,
        uint256 _morphoMaxIter
    ) external onlyOwner {
        if (_protocolAddress == address(0)) revert InvalidAddress();
        if (yieldSources.length >= MAX_YIELD_SOURCES) revert TooManyYieldSources();

        // Validate total splits don't exceed SPLIT_TOTAL
        uint256 totalSplit = _split;
        uint256 len = yieldSources.length;
        for (uint256 i = 0; i < len; i++) {
            totalSplit += yieldSources[i].split;
        }
        if (totalSplit != SPLIT_TOTAL) revert InvalidSplit();

        yieldSources.push(YieldSource({
            protocolType: _protocolType,
            enabled: _enabled,
            split: _split,
            protocolAddress: _protocolAddress,
            receiptToken: _receiptToken,
            comptroller: _comptrollerAddress,
            rewardToken: _rewardToken,
            swapPath: _swapPath,
            morphoMaxIterations: _morphoMaxIter
        }));

        // Approve protocol
        wsei.safeIncreaseAllowance(_protocolAddress, type(uint256).max);

        emit YieldSourceAdded(yieldSources.length - 1, _protocolType);
    }

    /// @notice Remove a yield source (owner only)
    /// @dev Does not reorder array, just sets split to 0 and disables
    function removeYieldSource(uint256 index) external onlyOwner {
        if (index >= yieldSources.length) revert InvalidIndex();

        yieldSources[index].enabled = false;
        yieldSources[index].split = 0;

        emit YieldSourceRemoved(index);
    }

    /// @notice Update yield source split (owner only)
    function updateYieldSourceSplit(uint256 index, uint256 newSplit) external onlyOwner {
        if (index >= yieldSources.length) revert InvalidIndex();

        // Check cooldown
        if (lastSplitsTime > 0 && block.timestamp < lastSplitsTime + splitsCooldown) {
            revert SplitsCooldownActive(lastSplitsTime + splitsCooldown);
        }

        // Validate total splits
        uint256 totalSplit = newSplit;
        uint256 len = yieldSources.length;
        for (uint256 i = 0; i < len; i++) {
            if (i != index) {
                totalSplit += yieldSources[i].split;
            }
        }
        if (totalSplit != SPLIT_TOTAL) revert InvalidSplit();

        yieldSources[index].split = newSplit;
        lastSplitsTime = block.timestamp;

        emit YieldSourceSplitUpdated(index, newSplit);
    }

    /// @notice Enable/disable a yield source (owner only)
    function setYieldSourceEnabled(uint256 index, bool enabled) external onlyOwner {
        if (index >= yieldSources.length) revert InvalidIndex();
        yieldSources[index].enabled = enabled;
        emit YieldSourceEnabled(index, enabled);
    }

    /// @notice Update yield source reward config (owner only)
    function setYieldSourceRewardConfig(
        uint256 index,
        address _rewardToken,
        address[] calldata _swapPath
    ) external onlyOwner {
        if (index >= yieldSources.length) revert InvalidIndex();
        yieldSources[index].rewardToken = _rewardToken;
        yieldSources[index].swapPath = _swapPath;
    }

    /// @notice Set Takara reward config (helper for tests)
    function setTakaraRewardConfig(address _rewardToken, address[] calldata _swapPath) external onlyOwner {
        if (yieldSources.length > 1) {
            yieldSources[1].rewardToken = _rewardToken;
            yieldSources[1].swapPath = _swapPath;
        }
    }

    /// @notice Set Morpho reward config (helper for tests)
    function setMorphoRewardConfig(address _rewardToken, address[] calldata _swapPath) external onlyOwner {
        if (yieldSources.length > 2) {
            yieldSources[2].rewardToken = _rewardToken;
            yieldSources[2].swapPath = _swapPath;
        }
    }

    /// @notice Set router V2 address (helper for tests)
    function setRouterV2(address _router) external onlyOwner {
        uint256 len = routers.length;
        for (uint256 i = 0; i < len; i++) {
            if (routers[i].routerType == RouterType.V2) {
                routers[i].routerAddress = _router;
                return;
            }
        }
    }

    /// @notice Set router V3 address (helper for tests)
    function setRouterV3(address _router) external onlyOwner {
        uint256 len = routers.length;
        for (uint256 i = 0; i < len; i++) {
            if (routers[i].routerType == RouterType.V3) {
                routers[i].routerAddress = _router;
                return;
            }
        }
    }

    /// @notice Set Morpho max iterations (helper for tests)
    function setMorphoMaxIterations(uint256 _maxIterations) external onlyOwner {
        if (yieldSources.length > 2) {
            yieldSources[2].morphoMaxIterations = _maxIterations;
        }
    }

    /// @notice Get yield source count
    function yieldSourcesLength() external view returns (uint256) {
        return yieldSources.length;
    }

    /// @notice Get yield source details
    function getYieldSource(uint256 index) external view returns (
        ProtocolType protocolType,
        bool enabled,
        uint256 split,
        address protocolAddress,
        address receiptToken,
        address comptrollerAddr,
        address rewardToken,
        address[] memory swapPath,
        uint256 morphoMaxIter
    ) {
        if (index >= yieldSources.length) revert InvalidIndex();
        YieldSource storage source = yieldSources[index];
        return (
            source.protocolType,
            source.enabled,
            source.split,
            source.protocolAddress,
            source.receiptToken,
            source.comptroller,
            source.rewardToken,
            source.swapPath,
            source.morphoMaxIterations
        );
    }

    // ─── Router Management ───────────────────────────────────────────────

    /// @notice Add a new router (owner only)
    function addRouter(
        address _routerAddress,
        RouterType _routerType,
        string calldata _label
    ) external onlyOwner {
        if (_routerAddress == address(0)) revert InvalidAddress();

        routers.push(DexRouter({
            routerAddress: _routerAddress,
            routerType: _routerType,
            enabled: true,
            label: _label
        }));

        emit RouterAdded(routers.length - 1, _routerAddress, _routerType);
    }

    /// @notice Remove a router (owner only)
    function removeRouter(uint256 index) external onlyOwner {
        if (index >= routers.length) revert InvalidIndex();

        routers[index].enabled = false;

        // If removing active router, set to first enabled router
        if (index == activeRouterIndex) {
            uint256 len = routers.length;
            for (uint256 i = 0; i < len; i++) {
                if (routers[i].enabled) {
                    activeRouterIndex = i;
                    break;
                }
            }
        }

        emit RouterRemoved(index);
    }

    /// @notice Set active router by index (keeper or owner)
    function setActiveRouter(uint256 index) external onlyKeeperOrOwner {
        if (index >= routers.length) revert InvalidIndex();
        if (!routers[index].enabled) revert InvalidIndex();

        activeRouterIndex = index;
        emit ActiveRouterSet(index);
    }

    /// @notice Set active router by type (helper for tests)
    function setActiveRouter(RouterType _type) external onlyKeeperOrOwner {
        uint256 len = routers.length;
        for (uint256 i = 0; i < len; i++) {
            if (routers[i].routerType == _type && routers[i].enabled) {
                activeRouterIndex = i;
                emit ActiveRouterSet(i);
                return;
            }
        }
    }

    /// @notice Get router count
    function routersLength() external view returns (uint256) {
        return routers.length;
    }

    /// @notice Get router details
    function getRouter(uint256 index) external view returns (
        address routerAddress,
        RouterType routerType,
        bool enabled,
        string memory label
    ) {
        if (index >= routers.length) revert InvalidIndex();
        DexRouter storage router = routers[index];
        return (
            router.routerAddress,
            router.routerType,
            router.enabled,
            router.label
        );
    }

    // ─── Keeper Functions ────────────────────────────────────────────────

    /// @notice Update first 3 yield source splits at once (helper for backward compatibility)
    function setSplits(uint256 _splitYei, uint256 _splitTakara, uint256 _splitMorpho) external onlyKeeperOrOwner whenNotPaused {
        if (yieldSources.length > 3) revert TooManyYieldSources();
        if (_splitYei + _splitTakara + _splitMorpho != SPLIT_TOTAL) revert InvalidSplit();
        if (lastSplitsTime > 0 && block.timestamp < lastSplitsTime + splitsCooldown) {
            revert SplitsCooldownActive(lastSplitsTime + splitsCooldown);
        }

        if (yieldSources.length >= 1) yieldSources[0].split = _splitYei;
        if (yieldSources.length >= 2) yieldSources[1].split = _splitTakara;
        if (yieldSources.length >= 3) yieldSources[2].split = _splitMorpho;

        lastSplitsTime = block.timestamp;
        emit SplitUpdated(_splitYei, _splitTakara, _splitMorpho);
    }

    /// @notice Rebalance: withdraw all, re-deploy with current splits
    /// @dev Subject to rebalance cooldown
    // slither-disable-start reentrancy-balance
    // slither-disable-start incorrect-equality
    function rebalance() external onlyKeeperOrOwner whenNotPaused nonReentrant {
        if (lastRebalanceTime > 0 && block.timestamp < lastRebalanceTime + rebalanceCooldown) {
            revert RebalanceCooldownActive(lastRebalanceTime + rebalanceCooldown);
        }

        uint256 total = _totalBalanceFresh();
        if (total == 0) return;

        // Update state BEFORE external calls (checks-effects-interactions)
        lastRebalanceTime = block.timestamp;

        // Withdraw everything
        uint256 len = yieldSources.length;
        for (uint256 i = 0; i < len; i++) {
            YieldSource storage source = yieldSources[i];
            if (!source.enabled) continue;

            uint256 balance = _getSourceBalanceFresh(source);
            if (balance == 0) continue;

            if (source.protocolType == ProtocolType.Aave) {
                uint256 withdrawn = IAavePool(source.protocolAddress).withdraw(address(wsei), balance, address(this));
                if (withdrawn == 0) revert AaveWithdrawFailed();
            } else if (source.protocolType == ProtocolType.Compound) {
                uint256 err = ICErc20(source.protocolAddress).redeemUnderlying(balance);
                if (err != 0) revert RedeemFailed(err);
            } else if (source.protocolType == ProtocolType.Morpho) {
                // MetaMorpho ERC-4626 — redeem all shares
                uint256 shares = IMetaMorpho(source.protocolAddress).balanceOf(address(this));
                if (shares > 0) IMetaMorpho(source.protocolAddress).redeem(shares, address(this), address(this));
            }
        }

        // Re-deploy with current splits
        uint256 wseiBalance = wsei.balanceOf(address(this));
        if (wseiBalance > 0) {
            _deployToProtocols(wseiBalance);
        }

        emit Rebalanced();
    }
    // slither-disable-end incorrect-equality
    // slither-disable-end reentrancy-balance

    // slither-disable-start incorrect-equality
    /// @notice Claim Morpho rewards via Merkl distributor and swap to WSEI
    function claimMorphoRewards(
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs,
        uint256[] calldata minAmountsOut
    ) external onlyKeeperOrOwner nonReentrant {
        if (address(merklDistributor) == address(0)) return;

        merklDistributor.claim(address(this), tokens, amounts, proofs);

        uint256 tokensLen = tokens.length;
        uint256 sourcesLen = yieldSources.length;
        for (uint256 i = 0; i < tokensLen; i++) {
            if (tokens[i] == address(wsei)) continue;

            uint256 bal = IERC20(tokens[i]).balanceOf(address(this));
            if (bal == 0) continue;

            // Try to find a yield source with matching reward token
            for (uint256 j = 0; j < sourcesLen; j++) {
                if (yieldSources[j].rewardToken == tokens[i] && yieldSources[j].swapPath.length >= 2) {
                    uint256 minOut = i < minAmountsOut.length ? minAmountsOut[i] : 0;
                    uint8 rewardDecimals = ERC20(tokens[i]).decimals();
                    _validateSlippage(bal, minOut, rewardDecimals, 18);
                    _swapDynamic(tokens[i], bal, yieldSources[j].swapPath, minOut);
                    break;
                }
            }
        }

        uint256 looseWsei = wsei.balanceOf(address(this));
        if (looseWsei > 0) {
            _deployToProtocols(looseWsei);
        }
    }
    // slither-disable-end incorrect-equality

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

    /// @notice Set guardian address (owner only)
    /// @param _guardian Address of the guardian
    function setGuardian(address _guardian) external onlyOwner {
        if (_guardian == address(0)) revert InvalidAddress();
        address old = guardian;
        guardian = _guardian;
        emit GuardianUpdated(old, _guardian);
    }

    /// @notice Pause the contract (guardian or owner only)
    /// @dev Blocks deposits, withdrawals, harvest, rebalance, and setSplits
    function pause() external onlyGuardianOrOwner {
        _pause();
    }

    /// @notice Unpause the contract (owner only)
    function unpause() external onlyOwner {
        _unpause();
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

    /// @notice Set V3 pool fee tier
    function setV3PoolFee(uint24 _fee) external onlyOwner {
        uint24 oldFee = v3PoolFee;
        v3PoolFee = _fee;
        emit V3PoolFeeUpdated(oldFee, _fee);
    }

    /// @notice Update Merkl distributor address
    function setMerklDistributor(address _distributor) external onlyOwner {
        merklDistributor = IMerklDistributor(_distributor);
    }

    /// @notice Rescue stuck tokens
    /// @dev For WSEI, only rescues loose balance (not deployed to protocols)
    /// @param _token Token address to rescue
    /// @param _amount Amount to rescue (ignored for WSEI, uses actual balance)
    function rescueToken(address _token, uint256 _amount) external onlyOwner {
        if (_token == address(wsei)) {
            // Only rescue loose WSEI not deployed to any protocol
            uint256 looseBalance = wsei.balanceOf(address(this));
            if (looseBalance > 0) {
                wsei.safeTransfer(owner(), looseBalance);
            }
        } else {
            IERC20(_token).safeTransfer(owner(), _amount);
        }
    }

    // ─── Legacy Getters (Read Only) ──────────────────────────────────────

    function splitYei() external view returns (uint256) {
        return yieldSources.length > 0 ? yieldSources[0].split : 0;
    }

    function splitTakara() external view returns (uint256) {
        return yieldSources.length > 1 ? yieldSources[1].split : 0;
    }

    function splitMorpho() external view returns (uint256) {
        return yieldSources.length > 2 ? yieldSources[2].split : 0;
    }

    function morphoMaxIterations() external view returns (uint256) {
        return yieldSources.length > 2 ? yieldSources[2].morphoMaxIterations : 0;
    }

    function yeiPool() external view returns (address) {
        return yieldSources.length > 0 ? yieldSources[0].protocolAddress : address(0);
    }

    function aToken() external view returns (address) {
        return yieldSources.length > 0 ? yieldSources[0].receiptToken : address(0);
    }

    function cToken() external view returns (address) {
        return yieldSources.length > 1 ? yieldSources[1].protocolAddress : address(0);
    }

    function comptroller() external view returns (address) {
        return yieldSources.length > 1 ? yieldSources[1].comptroller : address(0);
    }

    function morpho() external view returns (address) {
        return yieldSources.length > 2 ? yieldSources[2].protocolAddress : address(0);
    }

    function takaraRewardToken() external view returns (address) {
        return yieldSources.length > 1 ? yieldSources[1].rewardToken : address(0);
    }

    function morphoRewardToken() external view returns (address) {
        return yieldSources.length > 2 ? yieldSources[2].rewardToken : address(0);
    }

    function routerV2() external view returns (address) {
        uint256 len = routers.length;
        for (uint256 i = 0; i < len; i++) {
            if (routers[i].routerType == RouterType.V2 && routers[i].enabled) {
                return routers[i].routerAddress;
            }
        }
        return address(0);
    }

    function routerV3() external view returns (address) {
        uint256 len = routers.length;
        for (uint256 i = 0; i < len; i++) {
            if (routers[i].routerType == RouterType.V3 && routers[i].enabled) {
                return routers[i].routerAddress;
            }
        }
        return address(0);
    }
}
