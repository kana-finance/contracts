// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseStrategy} from "./BaseStrategy.sol";
import {ICErc20} from "../interfaces/external/ICErc20.sol";
import {IComptroller} from "../interfaces/external/IComptroller.sol";

/// @title TakaraStrategy
/// @notice Strategy for depositing USDC into Takara (Compound fork on SEI).
///         USDC is minted into cUSDC tokens; yield accrues via exchange rate
///         growth. COMP-style rewards are harvested and swapped to USDC.
contract TakaraStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice Takara cUSDC token (Compound-style)
    ICErc20 public immutable cToken;

    /// @notice Takara Comptroller (for claiming rewards)
    IComptroller public immutable comptroller;

    /// @notice Reward token address (TAKARA token)
    address public rewardToken;

    /// @notice Swap path: rewardToken → USDC
    address[] public swapPath;

    /// @notice Cached APY estimate in bps (updated off-chain by keeper)
    uint256 public cachedAPY;

    // ─── Errors ──────────────────────────────────────────────────────────

    error MintFailed(uint256 errorCode);
    error RedeemFailed(uint256 errorCode);

    // ─── Constructor ─────────────────────────────────────────────────────

    /// @param _want USDC address
    /// @param _vault Kana vault address
    /// @param _router Sailor DEX router
    /// @param _cToken Takara cUSDC address
    /// @param _comptroller Takara Comptroller address
    constructor(
        address _want,
        address _vault,
        address _router,
        address _cToken,
        address _comptroller
    ) BaseStrategy(_want, _vault, _router) {
        cToken = ICErc20(_cToken);
        comptroller = IComptroller(_comptroller);

        // Pre-approve cToken to spend our USDC (for minting)
        IERC20(_want).safeIncreaseAllowance(_cToken, type(uint256).max);
    }

    // ─── Strategy Implementation ─────────────────────────────────────────

    /// @dev Mint cUSDC by depositing USDC into Takara
    function _deposit(uint256 amount) internal override {
        uint256 err = cToken.mint(amount);
        if (err != 0) revert MintFailed(err);
    }

    /// @dev Redeem USDC from Takara by specifying the underlying amount
    function _withdraw(uint256 amount) internal override {
        uint256 err = cToken.redeemUnderlying(amount);
        if (err != 0) revert RedeemFailed(err);
    }

    /// @dev Harvest:
    ///      1. Claim COMP-style rewards from Comptroller
    ///      2. Swap rewards → USDC via Sailor
    ///      3. Re-deposit USDC profit into Takara
    ///      Returns total profit in USDC
    function _harvest() internal override returns (uint256 profit) {
        // Claim rewards from comptroller
        comptroller.claimComp(address(this));

        // Swap reward tokens to USDC
        if (rewardToken != address(0) && swapPath.length >= 2) {
            uint256 rewardBalance = IERC20(rewardToken).balanceOf(address(this));
            if (rewardBalance > 0) {
                profit += _swap(rewardToken, rewardBalance, swapPath);
            }
        }

        // Also capture any interest accrued (exchange rate growth)
        // The exchange rate increase is already reflected in balanceOf

        // Re-deposit any loose USDC
        uint256 looseWant = want.balanceOf(address(this));
        if (looseWant > 0) {
            uint256 err = cToken.mint(looseWant);
            if (err != 0) revert MintFailed(err);
            if (looseWant > profit) {
                profit = looseWant; // Loose want includes swapped rewards
            }
        }

        return profit;
    }

    // ─── IStrategy View ──────────────────────────────────────────────────

    /// @notice Total USDC value: cToken balance * exchange rate + loose USDC
    function balanceOf() external view override returns (uint256) {
        // cToken balance in underlying = cTokens * exchangeRate / 1e18
        uint256 cTokenBal = cToken.balanceOf(address(this));
        uint256 exchangeRate = cToken.exchangeRateStored();
        uint256 underlyingBal = (cTokenBal * exchangeRate) / 1e18;

        return underlyingBal + want.balanceOf(address(this));
    }

    /// @notice Returns cached APY estimate (updated by keeper)
    function estimatedAPY() external view override returns (uint256) {
        return cachedAPY;
    }

    /// @notice Protocol identifier
    function protocolName() external pure override returns (string memory) {
        return "Takara";
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
}
