// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMorpho
/// @notice Minimal interface for Morpho protocol supply/withdraw
/// @dev Morpho optimizes rates by matching P2P where possible, falling back
///      to the underlying pool (Aave/Compound) for unmatched liquidity.
interface IMorpho {
    /// @notice Supply tokens to a Morpho market
    /// @param underlying The address of the underlying token
    /// @param amount The amount to supply
    /// @param onBehalf The address that will own the position
    /// @param maxIterations Max P2P matching iterations (0 for pool-only)
    /// @return supplied The amount actually supplied
    function supply(
        address underlying,
        uint256 amount,
        address onBehalf,
        uint256 maxIterations
    ) external returns (uint256 supplied);

    /// @notice Withdraw tokens from a Morpho market
    /// @param underlying The address of the underlying token
    /// @param amount The amount to withdraw (type(uint256).max for all)
    /// @param receiver Address to receive withdrawn tokens
    /// @param maxIterations Max P2P matching iterations
    /// @return withdrawn The amount actually withdrawn
    function withdraw(
        address underlying,
        uint256 amount,
        address receiver,
        uint256 maxIterations
    ) external returns (uint256 withdrawn);

    /// @notice Get the current supply balance for a user in a market
    /// @param underlying The underlying token address
    /// @param user The user address
    /// @return The total supply balance (principal + interest)
    function supplyBalance(
        address underlying,
        address user
    ) external view returns (uint256);
}
