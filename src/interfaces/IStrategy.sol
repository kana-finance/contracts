// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IStrategy
/// @notice Interface for Kana vault strategies. Each strategy manages a single
///         asset (e.g. USDC) and allocates it across multiple lending protocols.
interface IStrategy {
    /// @notice Deposit assets into the strategy (deployed across protocols)
    /// @param amount Amount of the asset to deposit
    function deposit(uint256 amount) external;

    /// @notice Withdraw assets from the strategy
    /// @param amount Amount of the asset to withdraw
    function withdraw(uint256 amount) external;

    /// @notice Harvest rewards from all protocols, swap to asset, compound
    /// @param minAmountsOut Minimum asset expected from each reward token swap
    /// @return profit The amount of asset profit generated
    function harvest(uint256[] calldata minAmountsOut) external returns (uint256 profit);

    /// @notice Total asset value managed by this strategy across all protocols
    function balanceOf() external view returns (uint256);

    /// @notice The underlying asset token address
    function asset() external view returns (address);
}
