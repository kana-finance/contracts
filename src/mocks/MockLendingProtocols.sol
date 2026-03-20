// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAavePool} from "../interfaces/external/IAavePool.sol";
import {IAToken} from "../interfaces/external/IAToken.sol";
import {ICErc20} from "../interfaces/external/ICErc20.sol";
import {IComptroller} from "../interfaces/external/IComptroller.sol";
import {IMorpho} from "../interfaces/external/IMorpho.sol";
import {IMetaMorpho} from "../interfaces/external/IMetaMorpho.sol";
import {ISailorRouter} from "../interfaces/external/ISailorRouter.sol";

/// @title MockAToken
/// @notice Mock aToken for Yei (Aave V3 fork) testing - implements IAToken
contract MockAToken is ERC20 {
    using SafeERC20 for IERC20;
    
    IERC20 public immutable underlyingAsset;
    uint256 public aprBps; // APR in basis points (1000 = 10%)
    uint256 public lastUpdateTime;
    
    constructor(address _underlying, string memory name, string memory symbol) ERC20(name, symbol) {
        underlyingAsset = IERC20(_underlying);
        aprBps = 500; // 5% default APR
        lastUpdateTime = block.timestamp;
    }
    
    function setApr(uint256 _aprBps) external {
        _accrueInterest();
        aprBps = _aprBps;
    }
    
    function _accrueInterest() internal {
        if (totalSupply() == 0) {
            lastUpdateTime = block.timestamp;
            return;
        }
        
        uint256 elapsed = block.timestamp - lastUpdateTime;
        if (elapsed > 0) {
            // Simple interest: amount * apr * time / (365 days * 10000)
            uint256 interest = (totalSupply() * aprBps * elapsed) / (365 days * 10000);
            if (interest > 0) {
                _mint(address(this), interest);
            }
            lastUpdateTime = block.timestamp;
        }
    }
    
    // Called by MockYeiPool
    function mintTo(address to, uint256 amount) external {
        _accrueInterest();
        _mint(to, amount);
    }
    
    function burnFrom(address from, uint256 amount) external {
        _accrueInterest();
        _burn(from, amount);
    }
    
    function getApr() external view returns (uint256) {
        return aprBps;
    }
    
    // Allow pool to withdraw underlying - needed for mock to work
    function approvePool(address pool) external {
        underlyingAsset.approve(pool, type(uint256).max);
    }
}

/// @title MockYeiPool
/// @notice Mock Aave V3 Pool implementing IAavePool interface
contract MockYeiPool is IAavePool {
    using SafeERC20 for IERC20;
    
    mapping(address => MockAToken) public aTokens;
    
    function setAToken(address asset, address aToken) external {
        aTokens[asset] = MockAToken(aToken);
    }
    
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16
    ) external override {
        IERC20(asset).safeTransferFrom(msg.sender, address(aTokens[asset]), amount);
        aTokens[asset].mintTo(onBehalfOf, amount);
    }
    
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external override returns (uint256) {
        MockAToken aToken = aTokens[asset];
        aToken.burnFrom(msg.sender, amount);
        IERC20(asset).safeTransferFrom(address(aToken), to, amount);
        return amount;
    }
    
    function setApr(address asset, uint256 aprBps) external {
        aTokens[asset].setApr(aprBps);
    }
}

/// @title MockCToken
/// @notice Mock cToken implementing ICErc20 interface for Takara testing
contract MockCToken is ERC20, ICErc20 {
    using SafeERC20 for IERC20;

    address public immutable override underlying;
    uint256 public override exchangeRateStored;
    uint256 public aprBps;
    uint256 public lastUpdateTime;

    uint256 constant EXCHANGE_RATE_BASE = 1e18;

    constructor(address _underlying, string memory name, string memory symbol) ERC20(name, symbol) {
        underlying = _underlying;
        exchangeRateStored = EXCHANGE_RATE_BASE;
        aprBps = 600; // 6% default APR
        lastUpdateTime = block.timestamp;
    }

    function setApr(uint256 _aprBps) external {
        _accrueInterest();
        aprBps = _aprBps;
    }

    function _accrueInterest() internal {
        uint256 elapsed = block.timestamp - lastUpdateTime;
        if (elapsed > 0 && totalSupply() > 0) {
            uint256 rateIncrease = (exchangeRateStored * aprBps * elapsed) / (365 days * 10000);
            exchangeRateStored += rateIncrease;
            lastUpdateTime = block.timestamp;
        } else {
            lastUpdateTime = block.timestamp;
        }
    }

    function mint(uint256 mintAmount) external override returns (uint256) {
        _accrueInterest();
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), mintAmount);

        uint256 cTokens = (mintAmount * EXCHANGE_RATE_BASE) / exchangeRateStored;
        _mint(msg.sender, cTokens);
        return 0; // 0 = success
    }

    function redeemUnderlying(uint256 redeemAmount) external override returns (uint256) {
        _accrueInterest();

        uint256 cTokens = (redeemAmount * EXCHANGE_RATE_BASE) / exchangeRateStored;
        _burn(msg.sender, cTokens);
        IERC20(underlying).safeTransfer(msg.sender, redeemAmount);
        return 0;
    }

    // Override balanceOf to satisfy both ERC20 and ICErc20
    function balanceOf(address owner) public view override(ERC20, ICErc20) returns (uint256) {
        return super.balanceOf(owner);
    }

    function balanceOfUnderlying(address owner) external override returns (uint256) {
        _accrueInterest();
        return (balanceOf(owner) * exchangeRateStored) / EXCHANGE_RATE_BASE;
    }

    function exchangeRateCurrent() external override returns (uint256) {
        _accrueInterest();
        return exchangeRateStored;
    }

    function getApr() external view returns (uint256) {
        return aprBps;
    }
}

/// @title MockComptroller
/// @notice Mock Comptroller implementing IComptroller
contract MockComptroller is IComptroller {
    address public compToken;
    
    function setCompToken(address _compToken) external {
        compToken = _compToken;
    }
    
    function claimComp(address) external override {
        // No-op for testing
    }
    
    function getCompAddress() external view override returns (address) {
        return compToken;
    }
}

/// @title MockMorpho
/// @notice Mock Morpho protocol implementing IMorpho interface
contract MockMorpho is IMorpho {
    using SafeERC20 for IERC20;

    mapping(address => mapping(address => uint256)) public override supplyBalance;
    mapping(address => mapping(address => uint256)) public depositTime;
    mapping(address => uint256) public aprBps;
    bool public shouldRevertOnWithdraw;
    
    function setApr(address asset, uint256 _aprBps) external {
        aprBps[asset] = _aprBps;
    }
    
    function supply(
        address asset,
        uint256 amount,
        address onBehalf,
        uint256
    ) external override returns (uint256) {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        
        // Accrue interest for existing balance first
        _accrueInterest(asset, onBehalf);
        
        supplyBalance[asset][onBehalf] += amount;
        depositTime[asset][onBehalf] = block.timestamp;
        
        return amount;
    }
    
    function setShouldRevertOnWithdraw(bool _shouldRevert) external {
        shouldRevertOnWithdraw = _shouldRevert;
    }

    function withdraw(
        address asset,
        uint256 amount,
        address receiver,
        uint256
    ) external override returns (uint256) {
        require(!shouldRevertOnWithdraw, "MockMorpho: withdrawal disabled");
        // Accrue interest first
        _accrueInterest(asset, msg.sender);
        
        uint256 balance = supplyBalance[asset][msg.sender];
        uint256 toWithdraw = amount > balance ? balance : amount;
        
        supplyBalance[asset][msg.sender] = balance - toWithdraw;
        IERC20(asset).safeTransfer(receiver, toWithdraw);
        
        return toWithdraw;
    }
    
    function _accrueInterest(address asset, address user) internal {
        uint256 balance = supplyBalance[asset][user];
        if (balance == 0) return;
        
        uint256 elapsed = block.timestamp - depositTime[asset][user];
        if (elapsed > 0) {
            uint256 apr = aprBps[asset] > 0 ? aprBps[asset] : 700; // 7% default
            uint256 interest = (balance * apr * elapsed) / (365 days * 10000);
            supplyBalance[asset][user] += interest;
            depositTime[asset][user] = block.timestamp;
        }
    }
    
    function getApr(address asset) external view returns (uint256) {
        return aprBps[asset] > 0 ? aprBps[asset] : 700;
    }
}

/// @title MockRouter
/// @notice Mock DEX router implementing ISailorRouter interface
contract MockRouter is ISailorRouter {
    using SafeERC20 for IERC20;
    
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256,
        address[] calldata path,
        address to,
        uint256
    ) external override returns (uint256[] memory amounts) {
        require(path.length >= 2, "Invalid path");
        
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        // 1:1 swap for testing
        IERC20(path[path.length - 1]).safeTransfer(to, amountIn);
        
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn;
    }
    
    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external pure override returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        // 1:1 for testing
        for (uint256 i = 0; i < path.length; i++) {
            amounts[i] = amountIn;
        }
    }
    
    // Fund the router with tokens for testing
    function fund(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }
}

/// @title MockMetaMorpho
/// @notice Mock MetaMorpho ERC-4626 vault implementing IMetaMorpho
contract MockMetaMorpho is ERC20, IMetaMorpho {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlyingAsset;
    bool public shouldRevertOnWithdraw;
    uint256 public maxDepositAmount;

    constructor(address _underlying, string memory name, string memory symbol) ERC20(name, symbol) {
        underlyingAsset = IERC20(_underlying);
        maxDepositAmount = type(uint256).max;
    }

    function setShouldRevertOnWithdraw(bool _shouldRevert) external {
        shouldRevertOnWithdraw = _shouldRevert;
    }

    function setMaxDepositAmount(uint256 _maxDeposit) external {
        maxDepositAmount = _maxDeposit;
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        underlyingAsset.safeTransferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1 for simplicity
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address _owner) external override returns (uint256 shares) {
        require(!shouldRevertOnWithdraw, "MockMetaMorpho: withdrawal disabled");
        shares = assets; // 1:1 for simplicity
        _burn(_owner, shares);
        underlyingAsset.safeTransfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address _owner) external override returns (uint256 assets) {
        require(!shouldRevertOnWithdraw, "MockMetaMorpho: withdrawal disabled");
        assets = shares; // 1:1 for simplicity
        _burn(_owner, shares);
        underlyingAsset.safeTransfer(receiver, assets);
    }

    function totalAssets() external view override returns (uint256) {
        return underlyingAsset.balanceOf(address(this));
    }

    function balanceOf(address account) public view override(ERC20, IMetaMorpho) returns (uint256) {
        return super.balanceOf(account);
    }

    function convertToAssets(uint256 shares) external pure override returns (uint256) {
        return shares; // 1:1
    }

    function maxDeposit(address) external view override returns (uint256) {
        return maxDepositAmount;
    }

    function asset() external view override returns (address) {
        return address(underlyingAsset);
    }
}
