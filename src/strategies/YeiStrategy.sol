// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseStrategy} from "./BaseStrategy.sol";
import {IAavePool} from "../interfaces/external/IAavePool.sol";
import {IAToken} from "../interfaces/external/IAToken.sol";

/// @title YeiStrategy
/// @notice Strategy for depositing USDC into Yei Finance (Aave V3 fork on SEI).
///         USDC is supplied to the Yei lending pool; yield accrues via aToken
///         balance growth. Rewards (if any) are harvested and swapped to USDC.
contract YeiStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice Yei (Aave V3) lending pool
    IAavePool public immutable pool;

    /// @notice aUSDC token (interest-bearing receipt)
    IAToken public immutable aToken;

    /// @notice Reward token address (YEI token if applicable)
    address public rewardToken;

    /// @notice Swap path: rewardToken → USDC
    address[] public swapPath;

    /// @notice Cached APY estimate in bps (updated off-chain by keeper)
    uint256 public cachedAPY;

    // ─── Constructor ─────────────────────────────────────────────────────

    /// @param _want USDC address
    /// @param _vault Kana vault address
    /// @param _router Sailor DEX router
    /// @param _pool Yei (Aave V3) lending pool address
    /// @param _aToken aUSDC token address
    constructor(
        address _want,
        address _vault,
        address _router,
        address _pool,
        address _aToken
    ) BaseStrategy(_want, _vault, _router) {
        pool = IAavePool(_pool);
        aToken = IAToken(_aToken);

        // Pre-approve pool to spend our USDC
        IERC20(_want).safeIncreaseAllowance(_pool, type(uint256).max);
    }

    // ─── Strategy Implementation ─────────────────────────────────────────

    /// @dev Supply USDC to Yei pool → receive aUSDC
    function _deposit(uint256 amount) internal override {
        pool.supply(address(want), amount, address(this), 0);
    }

    /// @dev Withdraw USDC from Yei pool (burns aUSDC)
    function _withdraw(uint256 amount) internal override {
        pool.withdraw(address(want), amount, address(this));
    }

    /// @dev Harvest:
    ///      1. Calculate profit from aToken balance growth
    ///      2. Claim reward tokens (if configured)
    ///      3. Swap rewards → USDC
    ///      4. Re-deposit all USDC profit
    ///      Returns total profit in USDC
    function _harvest() internal override returns (uint256 profit) {
        // aToken balance = principal + accrued interest
        uint256 aTokenBalance = aToken.balanceOf(address(this));
        uint256 wantBalance = want.balanceOf(address(this));
        uint256 currentTotal = aTokenBalance + wantBalance;

        // Swap reward tokens to USDC if configured
        if (rewardToken != address(0) && swapPath.length >= 2) {
            uint256 rewardBalance = IERC20(rewardToken).balanceOf(address(this));
            if (rewardBalance > 0) {
                uint256 swapped = _swap(rewardToken, rewardBalance, swapPath);
                currentTotal += swapped;
            }
        }

        // Re-deposit any loose USDC back into pool
        uint256 looseWant = want.balanceOf(address(this));
        if (looseWant > 0) {
            pool.supply(address(want), looseWant, address(this), 0);
            profit = looseWant; // Profit = what we harvested
        }

        return profit;
    }

    // ─── IStrategy View ──────────────────────────────────────────────────

    /// @notice Total USDC value: aToken balance + loose USDC
    function balanceOf() external view override returns (uint256) {
        return aToken.balanceOf(address(this)) + want.balanceOf(address(this));
    }

    /// @notice Returns cached APY estimate (updated by keeper)
    function estimatedAPY() external view override returns (uint256) {
        return cachedAPY;
    }

    /// @notice Protocol identifier
    function protocolName() external pure override returns (string memory) {
        return "Yei Finance";
    }

    // ─── Admin ───────────────────────────────────────────────────────────

    /// @notice Configure reward token and swap path
    /// @param _rewardToken The reward token address
    /// @param _swapPath Path from reward token to USDC
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
}
