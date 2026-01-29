// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockStrategy
/// @notice Simulates a lending strategy for vault testing.
///         Tracks deposits/withdrawals and can simulate yield + harvest.
contract MockStrategy is IStrategy {
    using SafeERC20 for IERC20;

    IERC20 public want;
    uint256 public totalDeposited;
    uint256 public apy;
    string public name;

    /// @notice Simulated pending yield (set by test to simulate interest)
    uint256 public pendingYield;

    constructor(address _want, string memory _name, uint256 _apy) {
        want = IERC20(_want);
        name = _name;
        apy = _apy;
    }

    function deposit(uint256 amount) external override {
        // Vault already transferred tokens to us before calling deposit
        // Just track the deposit amount
        totalDeposited += amount;
    }

    function withdraw(uint256 amount) external override {
        totalDeposited -= amount;
        want.safeTransfer(msg.sender, amount);
    }

    function harvest() external override returns (uint256 profit) {
        profit = pendingYield;
        if (profit > 0) {
            // In real strategy, this would come from protocol rewards
            // For testing, the yield is already in the contract (minted by test)
            totalDeposited += profit;
            pendingYield = 0;
        }
    }

    function balanceOf() external view override returns (uint256) {
        return want.balanceOf(address(this));
    }

    function estimatedAPY() external view override returns (uint256) {
        return apy;
    }

    function protocolName() external view override returns (string memory) {
        return name;
    }

    // ─── Test Helpers ────────────────────────────────────────────────────

    /// @notice Simulate yield accrual (test mints tokens to strategy)
    function simulateYield(uint256 amount) external {
        pendingYield += amount;
    }

    function setAPY(uint256 _apy) external {
        apy = _apy;
    }
}
