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
///         routes funds to a single strategy that allocates across lending
///         protocols and auto-compounds rewards.
/// @dev Implements ERC-4626. One strategy per asset — the strategy handles
///      internal allocation across protocols (Yei, Takara, Morpho).
contract KanaVault is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice The strategy that manages fund allocation across protocols
    IStrategy public strategy;

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

    event StrategySet(address indexed oldStrategy, address indexed newStrategy);
    event Harvest(uint256 profit, uint256 fee);
    event PerformanceFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    // ─── Errors ──────────────────────────────────────────────────────────

    error InvalidFee();
    error InvalidAddress();
    error NoStrategy();
    error StrategyAssetMismatch();

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

    /// @notice Set the strategy contract
    /// @param _strategy Address of the strategy (must match vault asset)
    function setStrategy(IStrategy _strategy) external onlyOwner {
        if (address(_strategy) == address(0)) revert InvalidAddress();
        if (_strategy.asset() != asset()) revert StrategyAssetMismatch();

        address oldStrategy = address(strategy);

        // If there's an existing strategy with funds, withdraw everything first
        if (oldStrategy != address(0)) {
            uint256 bal = strategy.balanceOf();
            if (bal > 0) {
                strategy.withdraw(bal);
            }
            // Revoke approval
            IERC20(asset()).approve(oldStrategy, 0);
        }

        strategy = _strategy;

        // Approve new strategy
        IERC20(asset()).approve(address(_strategy), type(uint256).max);

        // If vault has idle funds, deploy them to new strategy
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle > 0 && address(_strategy) != address(0)) {
            IERC20(asset()).safeTransfer(address(_strategy), idle);
            _strategy.deposit(idle);
        }

        emit StrategySet(oldStrategy, address(_strategy));
    }

    // ─── Harvest ─────────────────────────────────────────────────────────

    /// @notice Harvest rewards from the strategy, take fees, compound
    function harvest() external onlyOwner {
        _harvest(0, 0);
    }

    /// @notice Harvest with slippage protection for reward token swaps
    /// @param takaraMinOut Minimum USDC expected from Takara reward swap
    /// @param morphoMinOut Minimum USDC expected from Morpho reward swap
    function harvestWithSlippage(
        uint256 takaraMinOut,
        uint256 morphoMinOut
    ) external onlyOwner {
        _harvest(takaraMinOut, morphoMinOut);
    }

    function _harvest(uint256 takaraMinOut, uint256 morphoMinOut) internal {
        if (address(strategy) == address(0)) revert NoStrategy();

        // Harvest converts reward tokens → asset and returns profit amount
        uint256 profit;
        if (takaraMinOut > 0 || morphoMinOut > 0) {
            // Use slippage-protected version
            // Cast to USDCStrategy to call harvestWithSlippage
            (bool success, bytes memory data) = address(strategy).call(
                abi.encodeWithSignature(
                    "harvestWithSlippage(uint256,uint256)",
                    takaraMinOut,
                    morphoMinOut
                )
            );
            require(success, "Harvest failed");
            profit = abi.decode(data, (uint256));
        } else {
            profit = strategy.harvest();
        }

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

    /// @notice Total assets = vault balance + strategy balance
    function totalAssets() public view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));

        if (address(strategy) != address(0)) {
            total += strategy.balanceOf();
        }

        return total;
    }

    /// @dev After deposit, deploy funds to the strategy
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        super._deposit(caller, receiver, assets, shares);

        // Deploy to strategy if one is set
        if (address(strategy) != address(0)) {
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

        if (vaultBalance < assets && address(strategy) != address(0)) {
            uint256 deficit = assets - vaultBalance;
            uint256 available = strategy.balanceOf();
            uint256 toWithdraw = deficit > available ? available : deficit;

            if (toWithdraw > 0) {
                strategy.withdraw(toWithdraw);
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

    /// @notice Whether the fee recipient is permanently locked
    bool public feeRecipientLocked;

    /// @notice Update fee recipient (only if not locked)
    function setFeeRecipient(address _recipient) external onlyOwner {
        if (feeRecipientLocked) revert FeeRecipientIsLocked();
        if (_recipient == address(0)) revert InvalidAddress();
        address oldRecipient = feeRecipient;
        feeRecipient = _recipient;
        emit FeeRecipientUpdated(oldRecipient, _recipient);
    }

    /// @notice Permanently lock the fee recipient (irreversible)
    /// @dev Used when switching from team multisig to staking contract
    function lockFeeRecipient() external onlyOwner {
        if (feeRecipient == address(0)) revert InvalidAddress();
        feeRecipientLocked = true;
        emit FeeRecipientLocked(feeRecipient);
    }

    event FeeRecipientLocked(address recipient);
    error FeeRecipientIsLocked();
}
