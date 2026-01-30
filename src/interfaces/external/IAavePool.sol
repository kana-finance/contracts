// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAavePool
/// @notice Minimal interface for Aave V3 Pool (used by Yei Finance on SEI)
interface IAavePool {
    /// @notice Supplies an amount of underlying asset into the reserve
    /// @param asset The address of the underlying asset to supply
    /// @param amount The amount to be supplied
    /// @param onBehalfOf The address that will receive the aTokens
    /// @param referralCode Code used to register the integrator (0 for none)
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    /// @notice Withdraws an amount of underlying asset from the reserve
    /// @param asset The address of the underlying asset to withdraw
    /// @param amount The amount to be withdrawn (type(uint256).max for all)
    /// @param to Address that will receive the underlying
    /// @return The final amount withdrawn
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}
