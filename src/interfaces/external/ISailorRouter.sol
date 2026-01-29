// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISailorRouter
/// @notice Minimal interface for Sailor DEX router on SEI (most liquidity)
interface ISailorRouter {
    /// @notice Swap exact tokens for tokens through a path
    /// @param amountIn The amount of input tokens to send
    /// @param amountOutMin The minimum amount of output tokens to receive
    /// @param path An array of token addresses (route)
    /// @param to Recipient of the output tokens
    /// @param deadline Unix timestamp after which the tx reverts
    /// @return amounts The amounts of tokens for each step in the path
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Returns the amounts out for a given path
    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}
