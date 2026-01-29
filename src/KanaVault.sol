// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/// @title KanaVault
/// @notice USDC yield aggregator vault on SEI. Users deposit USDC, the vault
///         allocates to the highest-yielding strategy and auto-compounds rewards.
/// @dev Implements ERC-4626 for composability. Strategies are pluggable.
contract KanaVault is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice List of registered strategies
    IStrategy[] public strategies;

    /// @notice Index of the currently active strategy (receives all deposits)
    uint256 public activeStrategyIndex;

    /// @notice Performance fee in basis points (10% = 1000)
    uint256 public performanceFeeBps;

    /// @notice Address that receives performance fees
    address public feeRecipient;

    /// @notice Total profit tracked for fee calculation
    uint256 public totalProfitAccrued;

    // ─── Constants ───────────────────────────────────────────────────────

    uint256 public constant MAX_FEE_BPS = 2000; // 20% max
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ─── Events ──────────────────────────────────────────────────────────

    event StrategyAdded(address indexed strategy, uint256 index);
    event StrategyRemoved(address indexed strategy, uint256 index);
    event ActiveStrategyChanged(uint256 indexed oldIndex, uint256 indexed newIndex);
    event Harvest(uint256 profit, uint256 fee);
    event Rebalanced(uint256 fromIndex, uint256 toIndex, uint256 amount);
    event PerformanceFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    // ─── Errors ──────────────────────────────────────────────────────────

    error StrategyAlreadyAdded();
    error StrategyNotFound();
    error InvalidFee();
    error InvalidAddress();
    error NoStrategies();

    // ─── Constructor ─────────────────────────────────────────────────────

    /// @param _asset USDC token address on SEI
    /// @param _feeRecipient Address to receive performance fees
    /// @param _performanceFeeBps Performance fee in bps (1000 = 10%)
    constructor(
        IERC20 _asset,
        address _feeRecipient,
        uint256 _performanceFeeBps
    )
        ERC4626(_asset)
        ERC20("Kana USDC Vault", "kUSDC")
        Ownable(msg.sender)
    {
        if (_feeRecipient == address(0)) revert InvalidAddress();
        if (_performanceFeeBps > MAX_FEE_BPS) revert InvalidFee();

        feeRecipient = _feeRecipient;
        performanceFeeBps = _performanceFeeBps;
    }

    // ─── Strategy Management ─────────────────────────────────────────────

    /// @notice Add a new strategy to the vault
    /// @param _strategy Address of the strategy contract
    function addStrategy(IStrategy _strategy) external onlyOwner {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (address(strategies[i]) == address(_strategy)) {
                revert StrategyAlreadyAdded();
            }
        }

        strategies.push(_strategy);

        // Approve strategy to pull USDC from vault
        IERC20(asset()).approve(address(_strategy), type(uint256).max);

        emit StrategyAdded(address(_strategy), strategies.length - 1);
    }

    /// @notice Remove a strategy (must withdraw all funds first)
    /// @param _index Index of the strategy to remove
    function removeStrategy(uint256 _index) external onlyOwner {
        if (_index >= strategies.length) revert StrategyNotFound();

        // Withdraw all funds from the strategy first
        IStrategy strategy = strategies[_index];
        uint256 strategyBalance = strategy.balanceOf();
        if (strategyBalance > 0) {
            strategy.withdraw(strategyBalance);
        }

        // Revoke approval
        IERC20(asset()).approve(address(strategy), 0);

        emit StrategyRemoved(address(strategy), _index);

        // Replace with last element and pop
        strategies[_index] = strategies[strategies.length - 1];
        strategies.pop();

        // Adjust active index if needed
        if (activeStrategyIndex == _index) {
            activeStrategyIndex = 0;
        } else if (activeStrategyIndex == strategies.length) {
            activeStrategyIndex = _index;
        }
    }

    /// @notice Set the active strategy that receives new deposits
    /// @param _index Index of the strategy to activate
    function setActiveStrategy(uint256 _index) external onlyOwner {
        if (_index >= strategies.length) revert StrategyNotFound();

        uint256 oldIndex = activeStrategyIndex;
        activeStrategyIndex = _index;

        emit ActiveStrategyChanged(oldIndex, _index);
    }

    // ─── Rebalancing ─────────────────────────────────────────────────────

    /// @notice Rebalance funds from current strategy to a new best strategy
    /// @param _newIndex Index of the strategy to rebalance into
    function rebalance(uint256 _newIndex) external onlyOwner {
        if (_newIndex >= strategies.length) revert StrategyNotFound();
        if (_newIndex == activeStrategyIndex) return;

        uint256 oldIndex = activeStrategyIndex;
        IStrategy oldStrategy = strategies[oldIndex];
        IStrategy newStrategy = strategies[_newIndex];

        // Withdraw everything from old strategy
        uint256 amount = oldStrategy.balanceOf();
        if (amount > 0) {
            oldStrategy.withdraw(amount);

            // Deposit into new strategy
            IERC20(asset()).safeTransfer(address(newStrategy), amount);
            newStrategy.deposit(amount);
        }

        activeStrategyIndex = _newIndex;

        emit Rebalanced(oldIndex, _newIndex, amount);
    }

    // ─── Harvest ─────────────────────────────────────────────────────────

    /// @notice Harvest rewards from the active strategy, take fees, compound
    function harvest() external onlyOwner {
        if (strategies.length == 0) revert NoStrategies();

        IStrategy strategy = strategies[activeStrategyIndex];

        // Harvest converts reward tokens → USDC and returns profit amount
        uint256 profit = strategy.harvest();

        if (profit > 0) {
            // Calculate and collect performance fee
            uint256 fee = (profit * performanceFeeBps) / BPS_DENOMINATOR;

            if (fee > 0) {
                // Withdraw fee amount from strategy
                strategy.withdraw(fee);
                IERC20(asset()).safeTransfer(feeRecipient, fee);
            }

            totalProfitAccrued += profit;

            emit Harvest(profit, fee);
        }
    }

    // ─── ERC4626 Overrides ───────────────────────────────────────────────

    /// @notice Total assets = vault balance + all strategy balances
    function totalAssets() public view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));

        for (uint256 i = 0; i < strategies.length; i++) {
            total += strategies[i].balanceOf();
        }

        return total;
    }

    /// @dev After deposit, deploy funds to the active strategy
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        super._deposit(caller, receiver, assets, shares);

        // Deploy to active strategy if one exists
        if (strategies.length > 0) {
            IStrategy strategy = strategies[activeStrategyIndex];
            IERC20(asset()).safeTransfer(address(strategy), assets);
            strategy.deposit(assets);
        }
    }

    /// @dev Before withdrawal, pull funds from strategy if vault balance insufficient
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));

        if (vaultBalance < assets && strategies.length > 0) {
            uint256 deficit = assets - vaultBalance;

            // Pull from active strategy first
            IStrategy strategy = strategies[activeStrategyIndex];
            uint256 available = strategy.balanceOf();
            uint256 toWithdraw = deficit > available ? available : deficit;

            if (toWithdraw > 0) {
                strategy.withdraw(toWithdraw);
            }

            // If still not enough, pull from other strategies
            if (toWithdraw < deficit) {
                uint256 remaining = deficit - toWithdraw;
                for (uint256 i = 0; i < strategies.length && remaining > 0; i++) {
                    if (i == activeStrategyIndex) continue;
                    available = strategies[i].balanceOf();
                    toWithdraw = remaining > available ? available : remaining;
                    if (toWithdraw > 0) {
                        strategies[i].withdraw(toWithdraw);
                        remaining -= toWithdraw;
                    }
                }
            }
        }

        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ─── Admin ───────────────────────────────────────────────────────────

    /// @notice Update performance fee
    function setPerformanceFee(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert InvalidFee();
        uint256 oldFee = performanceFeeBps;
        performanceFeeBps = _feeBps;
        emit PerformanceFeeUpdated(oldFee, _feeBps);
    }

    /// @notice Update fee recipient
    function setFeeRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert InvalidAddress();
        address oldRecipient = feeRecipient;
        feeRecipient = _recipient;
        emit FeeRecipientUpdated(oldRecipient, _recipient);
    }

    // ─── View ────────────────────────────────────────────────────────────

    /// @notice Number of registered strategies
    function strategiesCount() external view returns (uint256) {
        return strategies.length;
    }

    /// @notice Get the active strategy address
    function activeStrategy() external view returns (IStrategy) {
        if (strategies.length == 0) revert NoStrategies();
        return strategies[activeStrategyIndex];
    }
}
