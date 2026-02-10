// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMerklDistributor
/// @notice Interface for the Merkl distributor contract used by Morpho rewards
interface IMerklDistributor {
    /// @notice Claim accumulated rewards
    /// @param user Address to claim for
    /// @param tokens Array of reward token addresses
    /// @param amounts Array of cumulative claimable amounts
    /// @param proofs Array of merkle proofs per token
    function claim(
        address user,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;
}
