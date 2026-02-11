// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

/// @title MockStrategy
/// @notice Simulates a single strategy for vault testing.
///         Tracks deposits and can simulate yield.
contract MockStrategy is IStrategy {
    using SafeERC20 for IERC20;

    IERC20 public want;
    uint256 public totalDeposited;
    uint256 public pendingYield;

    constructor(address _want) {
        want = IERC20(_want);
    }

    function deposit(uint256 amount) external override {
        totalDeposited += amount;
    }

    function withdraw(uint256 amount) external override {
        totalDeposited -= amount;
        want.safeTransfer(msg.sender, amount);
    }

    function harvest() external override returns (uint256 profit) {
        profit = pendingYield;
        if (profit > 0) {
            totalDeposited += profit;
            pendingYield = 0;
        }
    }

    /// @notice Harvest with slippage protection (for vault integration) - legacy signature
    function harvest(uint256, uint256) external returns (uint256 profit) {
        profit = pendingYield;
        if (profit > 0) {
            totalDeposited += profit;
            pendingYield = 0;
        }
    }

    /// @notice Harvest with dynamic slippage array (new signature)
    function harvest(uint256[] calldata) external returns (uint256 profit) {
        profit = pendingYield;
        if (profit > 0) {
            totalDeposited += profit;
            pendingYield = 0;
        }
    }

    function balanceOf() external view override returns (uint256) {
        return want.balanceOf(address(this));
    }

    function asset() external view override returns (address) {
        return address(want);
    }

    // ─── Test Helpers ────────────────────────────────────────────────────

    function simulateYield(uint256 amount) external {
        pendingYield += amount;
    }
}
