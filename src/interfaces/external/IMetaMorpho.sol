// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMetaMorpho
/// @notice Minimal ERC-4626 interface for MetaMorpho curated vaults (e.g. Feather)
interface IMetaMorpho {
    /// @notice Deposit assets, receive shares
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Redeem shares, receive assets
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Withdraw exact assets by burning shares
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Total assets held by the vault
    function totalAssets() external view returns (uint256);

    /// @notice Share balance of an account
    function balanceOf(address account) external view returns (uint256);

    /// @notice Convert shares to assets
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice Underlying asset address
    function asset() external view returns (address);
}
