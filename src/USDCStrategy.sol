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
import {ISailorRouter} from "./interfaces/external/ISailorRouter.sol";

/// @title USDCStrategy
/// @notice Single strategy that manages USDC across multiple SEI lending
///         protocols: Yei (Aave V3 fork), Takara (Compound fork), and Morpho.
///         Allocation splits are configurable by the owner (keeper/vault).
/// @dev Follows the one-strategy-per-asset pattern. The strategy handles all
///      protocol interactions internally. Only the vault can deposit/withdraw.
contract USDCStrategy is IStrategy, Ownable {
    using SafeERC20 for IERC20;

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice The vault that owns this strategy
    address public vault;

    /// @notice USDC token
    IERC20 public immutable usdc;

    // ─── Protocol References ─────────────────────────────────────────────

    /// @notice Yei (Aave V3 fork) lending pool
    IAavePool public immutable yeiPool;

    /// @notice Yei aUSDC token
    IAToken public immutable aToken;

    /// @notice Takara cUSDC token (Compound fork)
    ICErc20 public immutable cToken;

    /// @notice Takara Comptroller
    IComptroller public immutable comptroller;

    /// @notice Morpho protocol
    IMorpho public immutable morpho;

    /// @notice Sailor DEX router for reward swaps
    ISailorRouter public router;

    // ─── Allocation ──────────────────────────────────────────────────────

    /// @notice Allocation to Yei in basis points
    uint256 public splitYei;

    /// @notice Allocation to Takara in basis points
    uint256 public splitTakara;

    /// @notice Allocation to Morpho in basis points
    uint256 public splitMorpho;

    uint256 public constant SPLIT_TOTAL = 10000; // 100%

    /// @notice Morpho P2P matching iterations
    uint256 public morphoMaxIterations;

    // ─── Reward Config ───────────────────────────────────────────────────

    /// @notice Takara reward token (if any)
    address public takaraRewardToken;

    /// @notice Swap path: Takara reward → USDC
    address[] public takaraSwapPath;

    /// @notice Morpho reward token (if any)
    address public morphoRewardToken;

    /// @notice Swap path: Morpho reward → USDC
    address[] public morphoSwapPath;

    // ─── Events ──────────────────────────────────────────────────────────

    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);
    event Harvested(uint256 profit);
    event SplitUpdated(uint256 yei, uint256 takara, uint256 morpho);
    event Rebalanced();
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    // ─── Errors ──────────────────────────────────────────────────────────

    error OnlyVault();
    error InvalidAddress();
    error InvalidSplit();
    error MintFailed(uint256 errorCode);
    error RedeemFailed(uint256 errorCode);

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
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
        address router;
    }

    /// @param addrs Protocol addresses
    /// @param _splitYei Initial Yei allocation (bps)
    /// @param _splitTakara Initial Takara allocation (bps)
    /// @param _splitMorpho Initial Morpho allocation (bps)
    /// @param _morphoMaxIterations Morpho P2P matching iterations
    constructor(
        ProtocolAddresses memory addrs,
        uint256 _splitYei,
        uint256 _splitTakara,
        uint256 _splitMorpho,
        uint256 _morphoMaxIterations
    ) Ownable(msg.sender) {
        if (addrs.usdc == address(0) || addrs.vault == address(0)) revert InvalidAddress();
        if (_splitYei + _splitTakara + _splitMorpho != SPLIT_TOTAL) revert InvalidSplit();

        usdc = IERC20(addrs.usdc);
        vault = addrs.vault;
        yeiPool = IAavePool(addrs.yeiPool);
        aToken = IAToken(addrs.aToken);
        cToken = ICErc20(addrs.cToken);
        comptroller = IComptroller(addrs.comptroller);
        morpho = IMorpho(addrs.morpho);
        router = ISailorRouter(addrs.router);

        splitYei = _splitYei;
        splitTakara = _splitTakara;
        splitMorpho = _splitMorpho;
        morphoMaxIterations = _morphoMaxIterations;

        // Pre-approve protocols to spend USDC
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
    function harvest() external override onlyVault returns (uint256 profit) {
        profit = _harvestAll();
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

    /// @dev Split deposit across protocols according to allocation
    function _deployToProtocols(uint256 amount) internal {
        uint256 toYei = (amount * splitYei) / SPLIT_TOTAL;
        uint256 toTakara = (amount * splitTakara) / SPLIT_TOTAL;
        uint256 toMorpho = amount - toYei - toTakara; // Remainder to Morpho (avoids dust)

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

    /// @dev Withdraw proportionally from each protocol
    function _withdrawFromProtocols(uint256 amount) internal {
        uint256 total = _totalBalance();
        if (total == 0) return;

        // Withdraw proportionally based on each protocol's current share
        uint256 yeiBalance = _yeiBalance();
        uint256 takaraBalance = _takaraBalance();
        uint256 morphoBalance = _morphoBalance();

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

        if (fromMorpho > 0 && morphoBalance > 0) {
            uint256 actual = fromMorpho > morphoBalance ? morphoBalance : fromMorpho;
            morpho.withdraw(address(usdc), actual, address(this), morphoMaxIterations);
        }
    }

    // ─── Internal: Harvest ───────────────────────────────────────────────

    /// @dev Harvest rewards from all protocols, swap to USDC, re-deploy
    function _harvestAll() internal returns (uint256 profit) {
        uint256 balanceBefore = usdc.balanceOf(address(this));

        // 1. Yei: interest accrues automatically in aToken balance (no claim needed)

        // 2. Takara: claim COMP-style rewards
        if (takaraRewardToken != address(0)) {
            comptroller.claimComp(address(this));
            uint256 rewardBal = IERC20(takaraRewardToken).balanceOf(address(this));
            if (rewardBal > 0 && takaraSwapPath.length >= 2) {
                _swap(takaraRewardToken, rewardBal, takaraSwapPath);
            }
        }

        // 3. Morpho: claim rewards if configured
        if (morphoRewardToken != address(0)) {
            uint256 rewardBal = IERC20(morphoRewardToken).balanceOf(address(this));
            if (rewardBal > 0 && morphoSwapPath.length >= 2) {
                _swap(morphoRewardToken, rewardBal, morphoSwapPath);
            }
        }

        // Re-deploy any loose USDC
        uint256 looseUsdc = usdc.balanceOf(address(this));
        profit = looseUsdc - balanceBefore;

        if (looseUsdc > 0) {
            _deployToProtocols(looseUsdc);
        }
    }

    // ─── Internal: Swap ──────────────────────────────────────────────────

    function _swap(
        address tokenIn,
        uint256 amountIn,
        address[] storage path
    ) internal {
        if (amountIn == 0 || address(router) == address(0)) return;

        IERC20(tokenIn).safeIncreaseAllowance(address(router), amountIn);

        router.swapExactTokensForTokens(
            amountIn,
            0, // MEV protection at keeper level
            path,
            address(this),
            block.timestamp
        );
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

    // ─── Admin: Allocation ───────────────────────────────────────────────

    /// @notice Update protocol allocation splits
    /// @param _splitYei Yei allocation in bps
    /// @param _splitTakara Takara allocation in bps
    /// @param _splitMorpho Morpho allocation in bps
    function setSplits(
        uint256 _splitYei,
        uint256 _splitTakara,
        uint256 _splitMorpho
    ) external onlyOwner {
        if (_splitYei + _splitTakara + _splitMorpho != SPLIT_TOTAL) revert InvalidSplit();

        splitYei = _splitYei;
        splitTakara = _splitTakara;
        splitMorpho = _splitMorpho;

        emit SplitUpdated(_splitYei, _splitTakara, _splitMorpho);
    }

    /// @notice Rebalance: withdraw all, re-deploy with current splits
    function rebalance() external onlyOwner {
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

        emit Rebalanced();
    }

    // ─── Admin: Config ───────────────────────────────────────────────────

    /// @notice Update the vault address
    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert InvalidAddress();
        address old = vault;
        vault = _vault;
        emit VaultUpdated(old, _vault);
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

    /// @notice Update Sailor DEX router
    function setRouter(address _router) external onlyOwner {
        router = ISailorRouter(_router);
    }

    // ─── Emergency ───────────────────────────────────────────────────────

    /// @notice Rescue stuck tokens (not USDC)
    function rescueToken(address _token, uint256 _amount) external onlyOwner {
        if (_token == address(usdc)) revert InvalidAddress();
        IERC20(_token).safeTransfer(owner(), _amount);
    }
}
