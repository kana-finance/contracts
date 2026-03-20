// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICErc20
/// @notice Minimal interface for Compound-style cToken (used by Takara on SEI)
interface ICErc20 {
    /// @notice Sender supplies assets into the market and receives cTokens
    /// @param mintAmount The amount of the underlying asset to supply
    /// @return 0 on success, otherwise an error code
    function mint(uint256 mintAmount) external returns (uint256);

    /// @notice Sender redeems cTokens in exchange for a specified amount of underlying
    /// @param redeemAmount The amount of underlying to redeem
    /// @return 0 on success, otherwise an error code
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    /// @notice Get the underlying balance of the owner
    function balanceOfUnderlying(address owner) external returns (uint256);

    /// @notice Get the stored exchange rate (no state change)
    /// @return The exchange rate (scaled by 1e18)
    function exchangeRateStored() external view returns (uint256);

    /// @notice Accrue interest then return the up-to-date exchange rate
    function exchangeRateCurrent() external returns (uint256);

    /// @notice Get the cToken balance of an account
    function balanceOf(address owner) external view returns (uint256);

    /// @notice Address of the underlying asset
    function underlying() external view returns (address);
}
