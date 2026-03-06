// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISwapRouterV3
/// @notice Minimal Uniswap V3 SwapRouter interface (used by Sailor Finance on SEI)
interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut);
}
