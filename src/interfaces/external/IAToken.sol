// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IAToken
/// @notice Minimal interface for Aave V3 aToken (yield-bearing receipt token)
interface IAToken is IERC20 {
    /// @notice Returns the scaled balance of the user
    function scaledBalanceOf(address user) external view returns (uint256);

    /// @notice Returns the address of the underlying asset
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}
