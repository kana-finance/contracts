// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {ISailorRouter} from "../interfaces/external/ISailorRouter.sol";

/// @title BaseStrategy
/// @notice Shared logic for all Kana strategies. Handles access control,
///         swap routing, and the common deposit/withdraw/harvest pattern.
/// @dev Strategies are owned by the vault. Only vault can deposit/withdraw.
abstract contract BaseStrategy is IStrategy, Ownable {
    using SafeERC20 for IERC20;

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice The vault that owns this strategy
    address public vault;

    /// @notice USDC token (the want token)
    IERC20 public immutable want;

    /// @notice DEX router for reward swaps
    ISailorRouter public router;

    // ─── Events ──────────────────────────────────────────────────────────

    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);
    event Harvested(uint256 profit);

    // ─── Errors ──────────────────────────────────────────────────────────

    error OnlyVault();
    error InvalidAddress();
    error SwapFailed();

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    /// @param _want USDC token address
    /// @param _vault Vault address (can call deposit/withdraw)
    /// @param _router Sailor DEX router for swaps
    constructor(
        address _want,
        address _vault,
        address _router
    ) Ownable(msg.sender) {
        if (_want == address(0) || _vault == address(0)) revert InvalidAddress();

        want = IERC20(_want);
        vault = _vault;
        router = ISailorRouter(_router);
    }

    // ─── IStrategy Implementation ────────────────────────────────────────

    /// @inheritdoc IStrategy
    function deposit(uint256 amount) external override onlyVault {
        _deposit(amount);
        emit Deposited(amount);
    }

    /// @inheritdoc IStrategy
    function withdraw(uint256 amount) external override onlyVault {
        _withdraw(amount);
        // Transfer back to vault
        want.safeTransfer(vault, amount);
        emit Withdrawn(amount);
    }

    /// @inheritdoc IStrategy
    function harvest() external override onlyVault returns (uint256 profit) {
        profit = _harvest();
        emit Harvested(profit);
    }

    // ─── Internal (override in children) ─────────────────────────────────

    /// @dev Deploy assets into the underlying protocol
    function _deposit(uint256 amount) internal virtual;

    /// @dev Pull assets from the underlying protocol
    function _withdraw(uint256 amount) internal virtual;

    /// @dev Claim rewards, swap to USDC, re-deposit. Return profit in USDC.
    function _harvest() internal virtual returns (uint256 profit);

    // ─── Swap Helper ─────────────────────────────────────────────────────

    /// @notice Swap reward tokens to USDC via Sailor DEX
    /// @param _tokenIn Reward token to sell
    /// @param _amountIn Amount to sell
    /// @param _path Swap path (tokenIn → ... → USDC)
    /// @return amountOut The USDC received
    function _swap(
        address _tokenIn,
        uint256 _amountIn,
        address[] memory _path
    ) internal returns (uint256 amountOut) {
        if (_amountIn == 0) return 0;
        if (address(router) == address(0)) revert InvalidAddress();

        IERC20(_tokenIn).safeIncreaseAllowance(address(router), _amountIn);

        uint256[] memory amounts = router.swapExactTokensForTokens(
            _amountIn,
            0, // Accept any amount (MEV protection should be at keeper level)
            _path,
            address(this),
            block.timestamp
        );

        amountOut = amounts[amounts.length - 1];
    }

    // ─── Admin ───────────────────────────────────────────────────────────

    /// @notice Update the vault address (only owner/deployer)
    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert InvalidAddress();
        address old = vault;
        vault = _vault;
        emit VaultUpdated(old, _vault);
    }

    /// @notice Update the DEX router
    function setRouter(address _router) external onlyOwner {
        address old = address(router);
        router = ISailorRouter(_router);
        emit RouterUpdated(old, _router);
    }

    // ─── Emergency ───────────────────────────────────────────────────────

    /// @notice Emergency rescue of stuck tokens (not want)
    function rescueToken(address _token, uint256 _amount) external onlyOwner {
        if (_token == address(want)) revert InvalidAddress();
        IERC20(_token).safeTransfer(owner(), _amount);
    }
}
