// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/// @title SEIVault
/// @notice WSEI yield aggregator vault on SEI. Users deposit WSEI, the vault
///         routes funds to a single strategy that allocates across lending
///         protocols and auto-compounds rewards.
/// @dev Implements ERC-4626 with virtual shares offset to prevent inflation attacks.
///      One strategy per asset — the strategy handles internal allocation.
contract SEIVault is ERC4626, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice The strategy that manages fund allocation across protocols
    IStrategy public strategy;

    /// @notice Address that receives performance fees
    address public feeRecipient;

    /// @notice Total profit tracked for fee calculation
    uint256 public totalProfitAccrued;

    /// @notice Whether the fee recipient is permanently locked
    bool public feeRecipientLocked;

    /// @notice Keeper address — can trigger harvest
    address public keeper;

    /// @notice Guardian address — can pause in emergencies
    address public guardian;

    // ─── Constants ───────────────────────────────────────────────────────

    /// @notice Performance fee: 10% (immutable)
    uint256 public constant PERFORMANCE_FEE_BPS = 1000;
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ─── Events ──────────────────────────────────────────────────────────

    event StrategySet(address indexed oldStrategy, address indexed newStrategy);
    event Harvest(uint256 profit, uint256 fee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event FeeRecipientLocked(address recipient);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    // ─── Errors ──────────────────────────────────────────────────────────

    error InvalidAddress();
    error NoStrategy();
    error StrategyAssetMismatch();
    error FeeRecipientIsLocked();
    error NotKeeperOrOwner();
    error NotGuardianOrOwner();
    error InsufficientWithdrawBalance(uint256 requested, uint256 available);

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeperOrOwner();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    /// @param _asset WSEI token address on SEI
    /// @param _feeRecipient Address to receive performance fees
    constructor(
        IERC20 _asset,
        address _feeRecipient
    )
        ERC4626(_asset)
        ERC20("Kana SEI Vault", "kSEI")
        Ownable(msg.sender)
    {
        if (_feeRecipient == address(0)) revert InvalidAddress();
        feeRecipient = _feeRecipient;
    }

    // ─── Strategy Management ─────────────────────────────────────────────

    /// @notice Set the strategy contract (owner only)
    /// @param _strategy Address of the strategy (must match vault asset)
    function setStrategy(IStrategy _strategy) external onlyOwner whenNotPaused nonReentrant {
        if (address(_strategy) == address(0)) revert InvalidAddress();
        if (_strategy.asset() != asset()) revert StrategyAssetMismatch();

        IStrategy oldStrategy = strategy;
        address oldStrategyAddr = address(oldStrategy);

        // Update strategy reference
        strategy = _strategy;

        // Withdraw from old strategy FIRST, then revoke its approval (H-2 fix)
        if (oldStrategyAddr != address(0)) {
            uint256 bal = oldStrategy.balanceOf();
            if (bal > 0) {
                oldStrategy.withdraw(bal);
            }
            SafeERC20.forceApprove(IERC20(asset()), oldStrategyAddr, 0);
        }

        // THEN approve new strategy (after old strategy funds are recovered)
        SafeERC20.forceApprove(IERC20(asset()), address(_strategy), type(uint256).max);

        // Deploy idle funds to new strategy
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle > 0) {
            IERC20(asset()).safeTransfer(address(_strategy), idle);
            _strategy.deposit(idle);
        }

        emit StrategySet(oldStrategyAddr, address(_strategy));
    }

    // ─── Harvest ─────────────────────────────────────────────────────────

    /// @notice Harvest rewards from the strategy with slippage protection
    /// @param minAmountsOut Minimum WSEI expected from each yield source's reward swap
    function harvest(
        uint256[] calldata minAmountsOut
    ) external onlyKeeperOrOwner whenNotPaused nonReentrant {
        if (address(strategy) == address(0)) revert NoStrategy();

        uint256 profit = strategy.harvest(minAmountsOut);

        if (profit > 0) {
            uint256 fee = (profit * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;

            if (fee > 0) {
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

    /// @dev Virtual offset to prevent inflation attack (OpenZeppelin pattern)
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6; // Adds 1e6 virtual shares/assets
    }

    /// @dev After deposit, deploy funds to the strategy
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused nonReentrant {
        super._deposit(caller, receiver, assets, shares);

        if (address(strategy) != address(0)) {
            IERC20(asset()).safeTransfer(address(strategy), assets);
            strategy.deposit(assets);
        }
    }

    /// @dev Before withdrawal, pull funds from strategy if vault balance insufficient
    function _withdraw(
        address caller,
        address receiver,
        address _owner,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused nonReentrant {
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));

        if (vaultBalance < assets && address(strategy) != address(0)) {
            uint256 deficit = assets - vaultBalance;
            uint256 available = strategy.balanceOf();
            uint256 toWithdraw = deficit > available ? available : deficit;
            if (toWithdraw > 0) {
                strategy.withdraw(toWithdraw);
            }
            // Revert if strategy returned less than requested (H-1 fix)
            uint256 actualBalance = IERC20(asset()).balanceOf(address(this));
            if (actualBalance < assets) {
                revert InsufficientWithdrawBalance(assets, actualBalance);
            }
        }

        super._withdraw(caller, receiver, _owner, assets, shares);
    }

    // ─── Admin ───────────────────────────────────────────────────────────

    /// @notice Set keeper address (owner only)
    /// @param _keeper Address of the keeper bot
    function setKeeper(address _keeper) external onlyOwner {
        address old = keeper;
        keeper = _keeper;
        emit KeeperUpdated(old, _keeper);
    }

    /// @notice Revoke keeper access (owner only)
    function revokeKeeper() external onlyOwner {
        address old = keeper;
        keeper = address(0);
        emit KeeperUpdated(old, address(0));
    }

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

    /// @notice Set guardian address (owner only)
    /// @param _guardian Address of the guardian
    function setGuardian(address _guardian) external onlyOwner {
        if (_guardian == address(0)) revert InvalidAddress();
        address old = guardian;
        guardian = _guardian;
        emit GuardianUpdated(old, _guardian);
    }

    /// @notice Pause the contract (guardian or owner only)
    /// @dev Blocks deposits, withdrawals, harvest, and strategy changes
    function pause() external onlyGuardianOrOwner {
        _pause();
    }

    /// @notice Unpause the contract (owner only)
    function unpause() external onlyOwner {
        _unpause();
    }
}
