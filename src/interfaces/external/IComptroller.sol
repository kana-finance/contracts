// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IComptroller
/// @notice Minimal interface for Compound-style Comptroller (used by Takara)
interface IComptroller {
    /// @notice Claim COMP-style rewards for a holder
    /// @param holder The address to claim for
    function claimComp(address holder) external;

    /// @notice Returns the COMP-style reward token address
    function getCompAddress() external view returns (address);
}
