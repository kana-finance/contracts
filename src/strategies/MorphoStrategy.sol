// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseStrategy} from "./BaseStrategy.sol";
import {IMorpho} from "../interfaces/external/IMorpho.sol";

/// @title MorphoStrategy
/// @notice Strategy for depositing USDC into Morpho on SEI.
///         Morpho optimizes yields by matching suppliers and borrowers P2P,
///         falling back to the underlying pool for unmatched liquidity.
///         This gives better rates than pure pool lending.
contract MorphoStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice Morpho protocol contract
    IMorpho public immutable morpho;

    /// @notice Max P2P matching iterations (higher = more gas, better rate)
    uint256 public maxIterations;

    /// @notice Reward token address (MORPHO token if applicable)
    address public rewardToken;

    /// @notice Swap path: rewardToken → USDC
    address[] public swapPath;

    /// @notice Cached APY estimate in bps (updated off-chain by keeper)
    uint256 public cachedAPY;

    /// @notice Track deposited amount for profit calculation
    uint256 public totalDeposited;

    // ─── Constructor ─────────────────────────────────────────────────────

    /// @param _want USDC address
    /// @param _vault Kana vault address
    /// @param _router Sailor DEX router
    /// @param _morpho Morpho protocol address
    /// @param _maxIterations Max P2P matching iterations
    constructor(
        address _want,
        address _vault,
        address _router,
        address _morpho,
        uint256 _maxIterations
    ) BaseStrategy(_want, _vault, _router) {
        morpho = IMorpho(_morpho);
        maxIterations = _maxIterations;

        // Pre-approve Morpho to spend our USDC
        IERC20(_want).safeIncreaseAllowance(_morpho, type(uint256).max);
    }

    // ─── Strategy Implementation ─────────────────────────────────────────

    /// @dev Supply USDC to Morpho
    function _deposit(uint256 amount) internal override {
        morpho.supply(address(want), amount, address(this), maxIterations);
        totalDeposited += amount;
    }

    /// @dev Withdraw USDC from Morpho
    function _withdraw(uint256 amount) internal override {
        morpho.withdraw(address(want), amount, address(this), maxIterations);
        if (amount <= totalDeposited) {
            totalDeposited -= amount;
        } else {
            totalDeposited = 0;
        }
    }

    /// @dev Harvest:
    ///      1. Check balance growth (interest accrued in Morpho)
    ///      2. Swap any reward tokens → USDC
    ///      3. Re-deposit profit
    ///      Returns total profit in USDC
    function _harvest() internal override returns (uint256 profit) {
        // Calculate interest accrued
        uint256 currentBalance = morpho.supplyBalance(address(want), address(this));
        uint256 looseWant = want.balanceOf(address(this));
        uint256 total = currentBalance + looseWant;

        // Swap reward tokens to USDC
        if (rewardToken != address(0) && swapPath.length >= 2) {
            uint256 rewardBalance = IERC20(rewardToken).balanceOf(address(this));
            if (rewardBalance > 0) {
                uint256 swapped = _swap(rewardToken, rewardBalance, swapPath);
                total += swapped;
            }
        }

        // Profit = current total - what we originally deposited
        if (total > totalDeposited) {
            profit = total - totalDeposited;
        }

        // Re-deposit any loose USDC
        looseWant = want.balanceOf(address(this));
        if (looseWant > 0) {
            morpho.supply(address(want), looseWant, address(this), maxIterations);
            totalDeposited += looseWant;
        }

        return profit;
    }

    // ─── IStrategy View ──────────────────────────────────────────────────

    /// @notice Total USDC value: Morpho supply balance + loose USDC
    function balanceOf() external view override returns (uint256) {
        return morpho.supplyBalance(address(want), address(this))
            + want.balanceOf(address(this));
    }

    /// @notice Returns cached APY estimate (updated by keeper)
    function estimatedAPY() external view override returns (uint256) {
        return cachedAPY;
    }

    /// @notice Protocol identifier
    function protocolName() external pure override returns (string memory) {
        return "Morpho";
    }

    // ─── Admin ───────────────────────────────────────────────────────────

    /// @notice Configure reward token and swap path
    function setRewardConfig(
        address _rewardToken,
        address[] calldata _swapPath
    ) external onlyOwner {
        rewardToken = _rewardToken;
        swapPath = _swapPath;
    }

    /// @notice Update cached APY (called by keeper)
    function updateAPY(uint256 _apy) external onlyOwner {
        cachedAPY = _apy;
    }

    /// @notice Update max P2P iterations
    function setMaxIterations(uint256 _maxIterations) external onlyOwner {
        maxIterations = _maxIterations;
    }
}
