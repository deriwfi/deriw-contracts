// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../libraries/utils/ReentrancyGuard.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IGlpManager.sol";
import "../core/interfaces/IMintable.sol";
import "../access/Governable.sol";
import "../fund-pool/v2/interfaces/IFundReader.sol";
import "../Pendant/interfaces/IPhase.sol";
import "../Pendant/interfaces/ICoinData.sol";
import "../Pendant/interfaces/ISlippage.sol";

pragma solidity ^0.8.0;

contract GlpManager is ReentrancyGuard, Governable, IGlpManager {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant MAX_COOLDOWN_DURATION = 48 hours;
    uint256 public cooldownDuration;

    IVault public vault;
    IPhase public phase;
    IFundReader public foundReader;
    ISlippage public slippage;

    address public override glp;
    address public usdt;
    address public immutable glpRewardRouter;

    mapping (address => uint256) public lastAddedAt;
   
    event AddLiquidity(
        address account,
        address token,
        uint256 amount,
        uint256 glpSupply,
        uint256 afterAmount,
        uint256 mintAmount
    );

    event RemoveLiquidity(
        address account,
        address token,
        uint256 amount,
        uint256 glpSupply,
        uint256 afterAmount
    );

    event AddLiquidityEvent(
        address token,
        address from, 
        address to, 
        uint256 amount, 
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );

    event RemoveLiquidityEvent(
        address token,
        address from, 
        address to, 
        uint256 amount, 
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );

    constructor(
        address _glpRewardRouter,
        address _vault, 
        address _glp, 
        uint256 _cooldownDuration
    ) {
        require(_vault != address(0) && _glp != address(0) && _glpRewardRouter  != address(0), "addr err");

        gov = msg.sender;

        glpRewardRouter = _glpRewardRouter;
        vault = IVault(_vault);
        glp = _glp;
        cooldownDuration = _cooldownDuration;
    }

    function setContract(
        address _usdt,  
        address _foundReader,
        address _phase,
        address _slippage
    ) external onlyGov {
        require(
            _usdt != address(0) &&
            _foundReader != address(0) &&
            _phase != address(0) &&
            _slippage != address(0),
            "addr err"
        );

        usdt = _usdt;
        foundReader = IFundReader(_foundReader);
        phase = IPhase(_phase);
        slippage = ISlippage(_slippage);
    }

    function setCooldownDuration(uint256 _cooldownDuration) external override onlyGov {
        require(_cooldownDuration <= MAX_COOLDOWN_DURATION, "GlpManager: invalid _cooldownDuration");
        cooldownDuration = _cooldownDuration;
    }

    /// @param _indexToken is add memeToken address or common token is use usdt address
    /// @param _fundingAccount Address for deducting collateralToken
    /// @param _account Obtain the address for the GLP
    /// @param _collateralToken Collateral token address
    /// @param _amount The quantity of collateral tokens
    /// @param _minGlp Expected minimum obtained glp
    function addLiquidityForAccount(
        address _indexToken, 
        address _fundingAccount, 
        address _account, 
        address _collateralToken, 
        uint256 _amount, 
        uint256 _minGlp
    ) external override nonReentrant returns (uint256) {
        _validateHandler();
        return _addLiquidity(_indexToken, _fundingAccount, _account, _collateralToken, _amount, _minGlp);
    }

    /// @param _indexToken is add memeToken address or common token is use usdt address
    /// @param _account Need to destroy the address of GLP
    /// @param _tokenOut Income token
    /// @param _glpAmount The quantity of GLP that needs to be destroyed
    /// @param _minOut Expected minimum obtained _tokenOut
    /// @param _receiver Income address
    function removeLiquidityForAccount(
        address _indexToken, 
        address _account, 
        address _tokenOut, 
        uint256 _glpAmount, 
        uint256 _minOut, 
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validateHandler();
        return _removeLiquidity(_indexToken, _account, _tokenOut, _glpAmount, _minOut, _receiver);
    }

    function _addLiquidity(address _indexToken, address _fundingAccount, address _account, address _collateralToken, uint256 _amount, uint256 _minGlp) private returns (uint256) {
        require(_amount > 0, "GlpManager: invalid _amount");

        phase.calculatePrice(_indexToken, _collateralToken);
        uint256 glpAmount = phase.getGlpAmount(_indexToken, _collateralToken, _amount);
        require(glpAmount >= _minGlp, "min err");

        uint256 glpSupply = slippage.glpTokenSupply(_indexToken, _collateralToken);

        uint256 beforeAmount = getAmount(_collateralToken, _fundingAccount);
        uint256 beforeValue = getAmount(_collateralToken, address(vault));
        IERC20(_collateralToken).safeTransferFrom(_fundingAccount, address(vault), _amount);
        uint256 afterAmount = getAmount(_collateralToken, _fundingAccount);
        uint256 afterValue = getAmount(_collateralToken, address(vault));
        _amount = afterValue - beforeValue;

        emit AddLiquidityEvent(_collateralToken, _fundingAccount, address(vault), _amount, beforeAmount, afterAmount, beforeValue, afterValue);
       
        vault.addTokenBalances(_indexToken, _collateralToken, _amount);
        slippage.addGlpAmount(_indexToken, _collateralToken, glpAmount);

        IMintable(glp).mint(_account, glpAmount);
        lastAddedAt[_account] = block.timestamp;

        emit AddLiquidity(_account, _collateralToken, _amount, glpSupply, IERC20(glp).totalSupply(), glpAmount);

        phase.calculatePrice(_indexToken, _collateralToken);

        return glpAmount;
    }

    function getAmount(address token, address account) public view returns(uint256) {
        return IERC20(token).balanceOf(account);
    }

    function _removeLiquidity(address _indexToken, address _account, address _tokenOut, uint256 _glpAmount, uint256 _minOut, address _receiver) private returns (uint256) {
        require(_glpAmount > 0, "GlpManager: invalid _glpAmount");
        require(lastAddedAt[_account].add(cooldownDuration) <= block.timestamp, "GlpManager: cooldown duration not yet passed");

        uint256 glpSupply = slippage.glpTokenSupply(_indexToken, _tokenOut);

        uint256 amount = phase.getOutAmount(_indexToken, _tokenOut, _glpAmount);
        require(amount >= _minOut, "amount err");
        phase.calculatePrice(_indexToken, _tokenOut);

        slippage.subGlpAmount(_indexToken, _tokenOut, _glpAmount);
        IMintable(glp).burn(_account, _glpAmount);

        uint256 beforeAmount = getAmount(_tokenOut, address(vault));
        uint256 beforeValue = getAmount(_tokenOut, _receiver);
        vault.transferOut(_indexToken, _tokenOut, _receiver, amount);
        uint256 afterAmount = getAmount(_tokenOut, address(vault));
        uint256 afterValue = getAmount(_tokenOut, _receiver);

        emit RemoveLiquidityEvent(_tokenOut, address(vault), _receiver, amount, beforeAmount, afterAmount, beforeValue, afterValue);
        emit RemoveLiquidity(_account, _tokenOut, _glpAmount, glpSupply, IERC20(glp).totalSupply());

        phase.calculatePrice(_indexToken, _tokenOut);

        return amount;
    }

    function _validateHandler() private view {
        require(msg.sender == glpRewardRouter, "GlpManager: forbidden");
    }
}
