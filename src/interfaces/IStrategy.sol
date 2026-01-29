// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IStrategy
/// @notice Interface for Kana vault strategies. Each strategy manages deposits
///         into a specific lending protocol and handles reward harvesting.
interface IStrategy {
    /// @notice Deposit assets into the underlying protocol
    /// @param amount Amount of USDC to deposit
    function deposit(uint256 amount) external;

    /// @notice Withdraw assets from the underlying protocol
    /// @param amount Amount of USDC to withdraw
    function withdraw(uint256 amount) external;

    /// @notice Harvest reward tokens, swap to USDC, and re-deposit (compound)
    /// @return profit The amount of USDC profit generated
    function harvest() external returns (uint256 profit);

    /// @notice Total USDC value managed by this strategy
    function balanceOf() external view returns (uint256);

    /// @notice Current APY estimate in basis points (e.g., 500 = 5%)
    function estimatedAPY() external view returns (uint256);

    /// @notice The underlying protocol name
    function protocolName() external view returns (string memory);
}
