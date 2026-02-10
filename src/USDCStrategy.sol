// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IAavePool} from "./interfaces/external/IAavePool.sol";
import {IAToken} from "./interfaces/external/IAToken.sol";
import {ICErc20} from "./interfaces/external/ICErc20.sol";
import {IComptroller} from "./interfaces/external/IComptroller.sol";
import {IMorpho} from "./interfaces/external/IMorpho.sol";
import {IMerklDistributor} from "./interfaces/external/IMerklDistributor.sol";
import {ISailorRouter} from "./interfaces/external/ISailorRouter.sol";
import {ISwapRouterV3} from "./interfaces/external/ISwapRouterV3.sol";

/// @title USDCStrategy
/// @notice Single strategy that manages USDC across multiple SEI lending
///         protocols: Yei (Aave V3 fork), Takara (Compound fork), and Morpho.
///         Allocation splits are configurable by the owner (keeper/vault).
/// @dev Follows the one-strategy-per-asset pattern. The strategy handles all
///      protocol interactions internally. Only the vault can deposit/withdraw.
contract USDCStrategy is IStrategy, Ownable {
    using SafeERC20 for IERC20;

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice The vault that owns this strategy
    address public vault;

    /// @notice USDC token
    IERC20 public immutable usdc;

    // ─── Protocol References ─────────────────────────────────────────────

    /// @notice Yei (Aave V3 fork) lending pool
    IAavePool public immutable yeiPool;

    /// @notice Yei aUSDC token
    IAToken public immutable aToken;

    /// @notice Takara cUSDC token (Compound fork)
    ICErc20 public immutable cToken;

    /// @notice Takara Comptroller
    IComptroller public immutable comptroller;

    /// @notice Morpho protocol
    IMorpho public immutable morpho;

    /// @notice Router type enum
    enum RouterType { V2, V3 }

    /// @notice V2 DEX router (DragonSwap)
    ISailorRouter public routerV2;

    /// @notice V3 DEX router (Sailor Finance)
    ISwapRouterV3 public routerV3;

    /// @notice Which router to use for swaps
    RouterType public activeRouter;

    /// @notice V3 pool fee tier (default 3000 = 0.3%)
    uint24 public v3PoolFee = 3000;

    /// @notice Merkl distributor for Morpho rewards
    IMerklDistributor public merklDistributor;

    // ─── Allocation ──────────────────────────────────────────────────────

    /// @notice Allocation to Yei in basis points
    uint256 public splitYei;

    /// @notice Allocation to Takara in basis points
    uint256 public splitTakara;

    /// @notice Allocation to Morpho in basis points
    uint256 public splitMorpho;

    uint256 public constant SPLIT_TOTAL = 10000; // 100%

    /// @notice Morpho P2P matching iterations
    uint256 public morphoMaxIterations;

    // ─── Reward Config ───────────────────────────────────────────────────

    /// @notice Takara reward token (if any)
    address public takaraRewardToken;

    /// @notice Swap path: Takara reward → USDC
    address[] public takaraSwapPath;

    /// @notice Morpho reward token (if any)
    address public morphoRewardToken;

    /// @notice Swap path: Morpho reward → USDC
    address[] public morphoSwapPath;

    // ─── Events ──────────────────────────────────────────────────────────

    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);
    event Harvested(uint256 profit);
    event SplitUpdated(uint256 yei, uint256 takara, uint256 morpho);
    event Rebalanced();
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    // ─── Errors ──────────────────────────────────────────────────────────

    error OnlyVault();
    error InvalidAddress();
    error InvalidSplit();
    error MintFailed(uint256 errorCode);
    error RedeemFailed(uint256 errorCode);

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    struct ProtocolAddresses {
        address usdc;
        address vault;
        address yeiPool;
        address aToken;
        address cToken;
        address comptroller;
        address morpho;
        address routerV2;
        address routerV3;
    }

    /// @param addrs Protocol addresses
    /// @param _splitYei Initial Yei allocation (bps)
    /// @param _splitTakara Initial Takara allocation (bps)
    /// @param _splitMorpho Initial Morpho allocation (bps)
    /// @param _morphoMaxIterations Morpho P2P matching iterations
    constructor(
        ProtocolAddresses memory addrs,
        uint256 _splitYei,
        uint256 _splitTakara,
        uint256 _splitMorpho,
        uint256 _morphoMaxIterations
    ) Ownable(msg.sender) {
        if (addrs.usdc == address(0) || addrs.vault == address(0)) revert InvalidAddress();
        if (_splitYei + _splitTakara + _splitMorpho != SPLIT_TOTAL) revert InvalidSplit();

        usdc = IERC20(addrs.usdc);
        vault = addrs.vault;
        yeiPool = IAavePool(addrs.yeiPool);
        aToken = IAToken(addrs.aToken);
        cToken = ICErc20(addrs.cToken);
        comptroller = IComptroller(addrs.comptroller);
        morpho = IMorpho(addrs.morpho);
        routerV2 = ISailorRouter(addrs.routerV2);
        routerV3 = ISwapRouterV3(addrs.routerV3);
        activeRouter = addrs.routerV2 != address(0) ? RouterType.V2 : RouterType.V3;

        splitYei = _splitYei;
        splitTakara = _splitTakara;
        splitMorpho = _splitMorpho;
        morphoMaxIterations = _morphoMaxIterations;

        // Pre-approve protocols to spend USDC
        IERC20(addrs.usdc).safeIncreaseAllowance(addrs.yeiPool, type(uint256).max);
        IERC20(addrs.usdc).safeIncreaseAllowance(addrs.cToken, type(uint256).max);
        IERC20(addrs.usdc).safeIncreaseAllowance(addrs.morpho, type(uint256).max);
    }

    // ─── IStrategy Implementation ────────────────────────────────────────

    /// @inheritdoc IStrategy
    function deposit(uint256 amount) external override onlyVault {
        _deployToProtocols(amount);
        emit Deposited(amount);
    }

    /// @inheritdoc IStrategy
    function withdraw(uint256 amount) external override onlyVault {
        _withdrawFromProtocols(amount);
        usdc.safeTransfer(vault, amount);
        emit Withdrawn(amount);
    }

    /// @inheritdoc IStrategy
    /// @dev Kept for interface compatibility — calls harvestWithSlippage with 0 minAmounts
    function harvest() external override onlyVault returns (uint256 profit) {
        profit = _harvestAll(0, 0);
        emit Harvested(profit);
    }

    /// @notice Harvest with slippage protection
    /// @param takaraMinOut Minimum USDC expected from Takara reward swap
    /// @param morphoMinOut Minimum USDC expected from Morpho reward swap
    function harvestWithSlippage(
        uint256 takaraMinOut,
        uint256 morphoMinOut
    ) external onlyVault returns (uint256 profit) {
        profit = _harvestAll(takaraMinOut, morphoMinOut);
        emit Harvested(profit);
    }

    /// @inheritdoc IStrategy
    function balanceOf() external view override returns (uint256) {
        return _totalBalance();
    }

    /// @inheritdoc IStrategy
    function asset() external view override returns (address) {
        return address(usdc);
    }

    // ─── Internal: Deploy ────────────────────────────────────────────────

    /// @dev Split deposit across protocols according to allocation
    function _deployToProtocols(uint256 amount) internal {
        uint256 toYei = (amount * splitYei) / SPLIT_TOTAL;
        uint256 toTakara = (amount * splitTakara) / SPLIT_TOTAL;
        uint256 toMorpho = amount - toYei - toTakara; // Remainder to Morpho (avoids dust)

        if (toYei > 0) {
            yeiPool.supply(address(usdc), toYei, address(this), 0);
        }

        if (toTakara > 0) {
            uint256 err = cToken.mint(toTakara);
            if (err != 0) revert MintFailed(err);
        }

        if (toMorpho > 0) {
            morpho.supply(address(usdc), toMorpho, address(this), morphoMaxIterations);
        }
    }

    // ─── Internal: Withdraw ──────────────────────────────────────────────

    /// @dev Withdraw proportionally from each protocol
    function _withdrawFromProtocols(uint256 amount) internal {
        uint256 total = _totalBalance();
        if (total == 0) return;

        // Withdraw proportionally based on each protocol's current share
        uint256 yeiBalance = _yeiBalance();
        uint256 takaraBalance = _takaraBalance();
        uint256 morphoBalance = _morphoBalance();

        uint256 fromYei = (amount * yeiBalance) / total;
        uint256 fromTakara = (amount * takaraBalance) / total;
        uint256 fromMorpho = amount - fromYei - fromTakara;

        if (fromYei > 0 && yeiBalance > 0) {
            uint256 actual = fromYei > yeiBalance ? yeiBalance : fromYei;
            yeiPool.withdraw(address(usdc), actual, address(this));
        }

        if (fromTakara > 0 && takaraBalance > 0) {
            uint256 actual = fromTakara > takaraBalance ? takaraBalance : fromTakara;
            uint256 err = cToken.redeemUnderlying(actual);
            if (err != 0) revert RedeemFailed(err);
        }

        if (fromMorpho > 0 && morphoBalance > 0) {
            uint256 actual = fromMorpho > morphoBalance ? morphoBalance : fromMorpho;
            morpho.withdraw(address(usdc), actual, address(this), morphoMaxIterations);
        }
    }

    // ─── Internal: Harvest ───────────────────────────────────────────────

    /// @dev Harvest rewards from all protocols, swap to USDC, re-deploy
    /// @param takaraMinOut Minimum USDC from Takara reward swap (0 = no protection)
    /// @param morphoMinOut Minimum USDC from Morpho reward swap (0 = no protection)
    function _harvestAll(uint256 takaraMinOut, uint256 morphoMinOut) internal returns (uint256 profit) {
        uint256 balanceBefore = usdc.balanceOf(address(this));

        // 1. Yei: interest accrues automatically in aToken balance (no claim needed)

        // 2. Takara: claim COMP-style rewards
        if (takaraRewardToken != address(0)) {
            comptroller.claimComp(address(this));
            uint256 rewardBal = IERC20(takaraRewardToken).balanceOf(address(this));
            if (rewardBal > 0 && takaraSwapPath.length >= 2) {
                _swap(takaraRewardToken, rewardBal, takaraSwapPath, takaraMinOut);
            }
        }

        // 3. Morpho: rewards are claimed separately via claimMorphoRewards()
        //    (requires off-chain merkle proof from Merkl API)
        //    Any morpho reward tokens already in the contract get swapped here
        if (morphoRewardToken != address(0)) {
            uint256 rewardBal = IERC20(morphoRewardToken).balanceOf(address(this));
            if (rewardBal > 0 && morphoSwapPath.length >= 2) {
                _swap(morphoRewardToken, rewardBal, morphoSwapPath, morphoMinOut);
            }
        }

        // Re-deploy any loose USDC
        uint256 looseUsdc = usdc.balanceOf(address(this));
        profit = looseUsdc - balanceBefore;

        if (looseUsdc > 0) {
            _deployToProtocols(looseUsdc);
        }
    }

    // ─── Internal: Swap ──────────────────────────────────────────────────

    function _swap(
        address tokenIn,
        uint256 amountIn,
        address[] storage path,
        uint256 minAmountOut
    ) internal {
        if (amountIn == 0 || path.length < 2) return;
        // Copy storage to memory for unified _executeSwap
        address[] memory memPath = new address[](path.length);
        for (uint256 i = 0; i < path.length; i++) {
            memPath[i] = path[i];
        }
        _executeSwap(tokenIn, memPath[memPath.length - 1], amountIn, minAmountOut, memPath);
    }

    /// @dev Swap tokens via router using a dynamic path (for Merkl claims)
    function _swapDynamic(
        address tokenIn,
        uint256 amountIn,
        address[] storage path,
        uint256 minAmountOut
    ) internal {
        if (amountIn == 0 || path.length < 2) return;

        // Build path: tokenIn → intermediaries → USDC
        address[] memory swapPath = new address[](path.length);
        swapPath[0] = tokenIn;
        for (uint256 i = 1; i < path.length; i++) {
            swapPath[i] = path[i];
        }

        _executeSwap(tokenIn, swapPath[swapPath.length - 1], amountIn, minAmountOut, swapPath);
    }

    /// @dev Execute swap on active router (V2 or V3)
    function _executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address[] memory path
    ) internal {
        if (activeRouter == RouterType.V2) {
            if (address(routerV2) == address(0)) return;
            IERC20(tokenIn).safeIncreaseAllowance(address(routerV2), amountIn);
            routerV2.swapExactTokensForTokens(
                amountIn,
                minAmountOut,
                path,
                address(this),
                block.timestamp
            );
        } else {
            if (address(routerV3) == address(0)) return;
            IERC20(tokenIn).safeIncreaseAllowance(address(routerV3), amountIn);
            routerV3.exactInputSingle(
                ISwapRouterV3.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: v3PoolFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: minAmountOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }
    }

    // ─── Internal: Balance Helpers ───────────────────────────────────────

    function _yeiBalance() internal view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function _takaraBalance() internal view returns (uint256) {
        uint256 cTokenBal = cToken.balanceOf(address(this));
        if (cTokenBal == 0) return 0;
        uint256 exchangeRate = cToken.exchangeRateStored();
        return (cTokenBal * exchangeRate) / 1e18;
    }

    function _morphoBalance() internal view returns (uint256) {
        return morpho.supplyBalance(address(usdc), address(this));
    }

    function _totalBalance() internal view returns (uint256) {
        return _yeiBalance() + _takaraBalance() + _morphoBalance()
            + usdc.balanceOf(address(this));
    }

    // ─── Admin: Allocation ───────────────────────────────────────────────

    /// @notice Update protocol allocation splits
    /// @param _splitYei Yei allocation in bps
    /// @param _splitTakara Takara allocation in bps
    /// @param _splitMorpho Morpho allocation in bps
    function setSplits(
        uint256 _splitYei,
        uint256 _splitTakara,
        uint256 _splitMorpho
    ) external onlyOwner {
        if (_splitYei + _splitTakara + _splitMorpho != SPLIT_TOTAL) revert InvalidSplit();

        splitYei = _splitYei;
        splitTakara = _splitTakara;
        splitMorpho = _splitMorpho;

        emit SplitUpdated(_splitYei, _splitTakara, _splitMorpho);
    }

    /// @notice Rebalance: withdraw all, re-deploy with current splits
    function rebalance() external onlyOwner {
        uint256 total = _totalBalance();
        if (total == 0) return;

        // Withdraw everything
        uint256 yei = _yeiBalance();
        uint256 takara = _takaraBalance();
        uint256 morphoBal = _morphoBalance();

        if (yei > 0) yeiPool.withdraw(address(usdc), yei, address(this));
        if (takara > 0) {
            uint256 err = cToken.redeemUnderlying(takara);
            if (err != 0) revert RedeemFailed(err);
        }
        if (morphoBal > 0) morpho.withdraw(address(usdc), morphoBal, address(this), morphoMaxIterations);

        // Re-deploy with current splits
        uint256 balance = usdc.balanceOf(address(this));
        if (balance > 0) {
            _deployToProtocols(balance);
        }

        emit Rebalanced();
    }

    // ─── Admin: Config ───────────────────────────────────────────────────

    /// @notice Update the vault address
    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert InvalidAddress();
        address old = vault;
        vault = _vault;
        emit VaultUpdated(old, _vault);
    }

    /// @notice Configure Takara reward token and swap path
    function setTakaraRewardConfig(
        address _rewardToken,
        address[] calldata _swapPath
    ) external onlyOwner {
        takaraRewardToken = _rewardToken;
        takaraSwapPath = _swapPath;
    }

    /// @notice Configure Morpho reward token and swap path
    function setMorphoRewardConfig(
        address _rewardToken,
        address[] calldata _swapPath
    ) external onlyOwner {
        morphoRewardToken = _rewardToken;
        morphoSwapPath = _swapPath;
    }

    /// @notice Update Morpho max iterations
    function setMorphoMaxIterations(uint256 _maxIterations) external onlyOwner {
        morphoMaxIterations = _maxIterations;
    }

    /// @notice Update V2 DEX router (DragonSwap)
    function setRouterV2(address _router) external onlyOwner {
        routerV2 = ISailorRouter(_router);
    }

    /// @notice Update V3 DEX router (Sailor Finance)
    function setRouterV3(address _router) external onlyOwner {
        routerV3 = ISwapRouterV3(_router);
    }

    /// @notice Switch active router type
    function setActiveRouter(RouterType _type) external onlyOwner {
        activeRouter = _type;
    }

    /// @notice Set V3 pool fee tier
    function setV3PoolFee(uint24 _fee) external onlyOwner {
        v3PoolFee = _fee;
    }

    /// @notice Update Merkl distributor address
    function setMerklDistributor(address _distributor) external onlyOwner {
        merklDistributor = IMerklDistributor(_distributor);
    }

    /// @notice Claim Morpho rewards via Merkl distributor and swap to USDC
    /// @dev Called by keeper with merkle proof data fetched from Merkl API
    /// @param tokens Reward token addresses to claim
    /// @param amounts Cumulative claimable amounts per token
    /// @param proofs Merkle proofs per token
    /// @param minAmountsOut Minimum USDC expected per token swap (same length as tokens)
    function claimMorphoRewards(
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs,
        uint256[] calldata minAmountsOut
    ) external onlyOwner {
        if (address(merklDistributor) == address(0)) return;

        // Claim from Merkl distributor
        merklDistributor.claim(address(this), tokens, amounts, proofs);

        // Swap each claimed token to USDC (skip if token is already USDC)
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(usdc)) continue;

            uint256 bal = IERC20(tokens[i]).balanceOf(address(this));
            if (bal > 0 && morphoSwapPath.length >= 2) {
                uint256 minOut = i < minAmountsOut.length ? minAmountsOut[i] : 0;
                _swapDynamic(tokens[i], bal, morphoSwapPath, minOut);
            }
        }

        // Re-deploy any loose USDC
        uint256 looseUsdc = usdc.balanceOf(address(this));
        if (looseUsdc > 0) {
            _deployToProtocols(looseUsdc);
        }
    }

    // ─── Emergency ───────────────────────────────────────────────────────

    /// @notice Rescue stuck tokens (not USDC)
    function rescueToken(address _token, uint256 _amount) external onlyOwner {
        if (_token == address(usdc)) revert InvalidAddress();
        IERC20(_token).safeTransfer(owner(), _amount);
    }
}
