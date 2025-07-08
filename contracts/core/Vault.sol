// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../libraries/utils/ReentrancyGuard.sol";
import "./interfaces/IVaultUtils.sol";
import "./interfaces/IVaultPriceFeed.sol";
import "../Pendant/interfaces/ISlippage.sol";
import "../Pendant/interfaces/IPhase.sol";
import "./interfaces/IERC20Metadata.sol";
import "../referrals/interfaces/IReferralData.sol";
import "./interfaces/IEventStruct.sol";
import "../upgradeability/Synchron.sol";
import "../Pendant/interfaces/ICoinData.sol";

contract Vault is Synchron, ReentrancyGuard, IEventStruct {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant MIN_LEVERAGE = 10000; // 1x
    uint256 public constant MAX_FEE_BASIS_POINTS = 500; // 5%
    uint256 public constant MAX_LIQUIDATION_FEE_USD = 100 * (10 ** 30); // 100 USD

    IVaultUtils public vaultUtils;
    ISlippage public slippage;
    IPhase public phase;
    IReferralData public referralData;

    address public errorController;
    address public usdt;
    address public router;
    address public priceFeed;
    address public gov;

    address[] public allWhitelistedTokens;

    uint256 public maxLeverage;
    uint256 public liquidationFeeUsd;
    uint256 public marginFeeBasisPoints; // 0.02%
    uint256 public minProfitTime;
    uint256 public totalTokenWeights;
    uint256 public multiplier;

    bool public includeAmmPrice;
    bool public inPrivateLiquidationMode;
    bool public isLeverageEnabled;
    bool public initialized;

    IncreaseEvent iEvent;
    DecreaseEvent dData;

    mapping (address => uint256) public tokenDecimals;
    mapping (address => uint256) public minProfitBasisPoints;
    mapping (address => bool) public isFrom;
    mapping (address => bool) public isLiquidator;
    mapping (address => bool) public isManager;
    mapping (address => bool) public whitelistedTokens;
    mapping (address => bool) public stableTokens;
    mapping (address => bool) public shortableTokens;
    mapping (address => bool) public iswrapped;

    // _tokenBalances is used only to determine _transferIn values
    mapping (address => mapping(address => uint256)) _tokenBalances;

    // tokenWeights allows customisation of index composition
    mapping (address => uint256) public  tokenWeights;

    // _poolAmounts tracks the number of received tokens that can be used for leverage
    // this is tracked separately from _tokenBalances to exclude funds that are deposited as margin collateral
    mapping (address => mapping(address => uint256)) _poolAmounts;

    // _reservedAmounts tracks the number of tokens reserved for open leverage positions
    mapping (address => mapping (address => uint256)) _reservedAmounts;

    mapping (address => mapping (address => uint256)) _guaranteedUsd;

    // positions tracks all open positions
    mapping (bytes32 => Position) public positions;
    mapping (address => uint256) public globalShortSizes;
    mapping (address => uint256) public globalShortAveragePrices;
    mapping (address => uint256) public maxGlobalShortSizes;
    mapping (address => uint256) public globalLongSizes;
    mapping (address => uint256) public globalLongAveragePrices;
    mapping (uint256 => string) errors;

    event IncreasePosition(IncreaseEvent increaseEvent);
    event DecreasePosition(DecreaseEvent decreaseEvent, uint256 collateralValue);
    event LiquidatePosition(LiquidateEvent liquidateEvent);
    event ClosePosition(ClosePositionEvent cEvent);
    event DecreasePositionEvent(DecreaseEventFor dt, uint256 collateralValue);
    event UpdateFundingRate(address token, uint256 fundingRate);
    event UpdatePnl(bytes32 key, bool hasProfit, uint256 delta);
    event DirectPoolDeposit(address _indexToken, address _collateralToken, uint256 amount);
    event IncreasePoolAmount(address _indexToken, address _collateralToken, uint256 amount);
    event DecreasePoolAmount(address _indexToken, address _collateralToken, uint256 amount);
    event IncreaseReservedAmount(address _indexToken, address _collateralToken, uint256 amount);
    event DecreaseReservedAmount(address _indexToken, address _collateralToken, uint256 amount);
    event IncreaseGuaranteedUsd(address _indexToken, address _collateralToken, uint256 amount);
    event DecreaseGuaranteedUsd(address _indexToken, address _collateralToken, uint256 amount);
    event LiquidationFeeUsd(address token, uint256 liquidationFeeUsd, uint256 tokenAmount);
    event LiquidatePositionFee(address token, uint256 feeUsd, uint256 feeTokens);

    event UpdatePosition(
        bytes32 key,
        address account,
        address collteraltoken,
        address indextoken,
        bool islong,
        uint256 markPrice,
        Position pos
    );

    event SetTokenConfig(
        string _symbol,
        address _token,
        uint256 _tokenDecimals,
        bool _isStable,
        bool _isShortable,
        bool _iswrapped,
        bool _isFrom
    );

    event TransferOut(
        address _token, 
        address _receiver, 
        uint256 amount
    );

    event LiquidatePositionEvent(
        bytes32 key,
        address from, 
        address to, 
        uint256 amount, 
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );

    event CollectMarginFees(
        uint8 cType,
        bytes32 typeKey,
        bytes32 key,
        address from, 
        address to, 
        uint256 amount, 
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );
    
    constructor() {
        initialized = true;
    }



    modifier onlyWhitelistedToken(address _token) {
        require(whitelistedTokens[_token], "token err");
        _;
    }

    function initialize(address _usdt) external {
        require(!initialized, "has initialized");
        initialized = true;

        usdt = _usdt;
        isLeverageEnabled = true;
        maxLeverage = 200 * 10000; // 200x
        marginFeeBasisPoints = 2; // 0.02
        includeAmmPrice = true;
        minProfitTime = 5;
        gov = msg.sender;
    }

    function setData(
        address _router,
        uint256 _liquidationFeeUsd,
        uint256 _multiplier,
        IVaultUtils _vaultUtils,
        address _errorController
    ) external {
        _onlyGov();
        require(_multiplier > 0, "mul err");

        router = _router;
        liquidationFeeUsd = _liquidationFeeUsd;
        multiplier = _multiplier;
        vaultUtils = _vaultUtils;
        errorController = _errorController;
    }

    function setSlippage(
        address slippage_, 
        address phase_,
        address referralData_
    ) external {
        _onlyGov();

        slippage = ISlippage(slippage_);
        phase = IPhase(phase_);
        referralData = IReferralData(referralData_);
    }   

    function setError(uint256 _errorCode, string calldata _error) external  {
        if(msg.sender != errorController) {
            revert();
        }
        errors[_errorCode] = _error;
    }

    function setManager(address _manager, bool _isManager) external {
        _onlyGov();
        isManager[_manager] = _isManager;
    }

    function setInPrivateLiquidationMode(bool _inPrivateLiquidationMode) external {
        _onlyGov();
        inPrivateLiquidationMode = _inPrivateLiquidationMode;
    }
 
    function setLiquidator(address _liquidator, bool _isActive) external {
        _onlyGov();
        isLiquidator[_liquidator] = _isActive;
    }

    function setIsLeverageEnabled(bool _isLeverageEnabled) external {
        _onlyGov();
        isLeverageEnabled = _isLeverageEnabled;
    }

    function setGov(address _gov) external {
        require(_gov != address(0), "_gov err");
        _onlyGov();
        gov = _gov;
    }

    function setPriceFeed(address _priceFeed) external {
        _onlyGov();
        priceFeed = _priceFeed;
    }

    function setMaxLeverage(uint256 _maxLeverage) external {
        _onlyGov();
        _validate(_maxLeverage > MIN_LEVERAGE, 2);
        maxLeverage = _maxLeverage;
    }

    function setMaxGlobalShortSize(address _token, uint256 _amount) external {
        _onlyGov();
        maxGlobalShortSizes[_token] = _amount;
    }

    function setFees(
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime
    ) external {
        _onlyGov();
        require(
            _marginFeeBasisPoints <= MAX_FEE_BASIS_POINTS &&
            _liquidationFeeUsd <= MAX_LIQUIDATION_FEE_USD,
            "data err"
        );

        marginFeeBasisPoints = _marginFeeBasisPoints;
        liquidationFeeUsd = _liquidationFeeUsd;
        minProfitTime = _minProfitTime;
    }

    function setTokenConfig(
        address _token,
        uint256 _tokenDecimals,
        uint256 _tokenWeight,
        uint256 _minProfitBps,
        bool _isStable,
        bool _isShortable,
        bool _iswrapped,
        bool _isFrom
    ) external {
        _onlyGov();
        // increment token count for the first time
        if (!whitelistedTokens[_token]) {
            allWhitelistedTokens.push(_token);
        }
        
        if(uint256(IERC20Metadata(_token).decimals()) != _tokenDecimals) {
            revert();
        }

        uint256 _totalTokenWeights = totalTokenWeights;
        _totalTokenWeights -= tokenWeights[_token];

        whitelistedTokens[_token] = true;
        tokenDecimals[_token] = _tokenDecimals;
        tokenWeights[_token] = _tokenWeight;
        minProfitBasisPoints[_token] = _minProfitBps;
        stableTokens[_token] = _isStable;
        shortableTokens[_token] = _isShortable;
        iswrapped[_token] = _iswrapped;
        isFrom[_token] = _isFrom;

        totalTokenWeights = _totalTokenWeights + _tokenWeight;

        // validate price feed
        getMaxPrice(_token);
        string memory _symbol = IERC20Metadata(_token).symbol();
        
        emit SetTokenConfig(_symbol, _token, _tokenDecimals, _isStable, _isShortable, _iswrapped, _isFrom);
    }

    function directPoolDeposit(address _indexToken, address _collateralToken, uint256 _amount) external {
        _validateManager();
        _validate(_amount > 0 && whitelistedTokens[_indexToken], 15);

        _transferIn(_indexToken, _collateralToken, _amount);

        _increasePoolAmount(_indexToken, _collateralToken, _amount);
        emit DirectPoolDeposit(_indexToken, _collateralToken, _amount);
    }

    function addTokenBalances(address _indexToken, address _collateralToken, uint256 _amount)  onlyWhitelistedToken(_indexToken) external {
        _validateManager();
        _transferIn(_indexToken, _collateralToken, _amount);

        _increasePoolAmount(_indexToken, _collateralToken, _amount);
    }


    function transferOut(
        address _indexToken, 
        address _collateralToken, 
        address _receiver, 
        uint256 _amount
    ) external onlyWhitelistedToken(_indexToken)  nonReentrant {
        _validateManager();

        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        //  value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2
        if(getCoinType(_indexToken) == 1) {
            _poolAmounts[_collateralToken][_collateralToken] -= _amount;
            emit DecreasePoolAmount(_collateralToken, _collateralToken, _amount);
        } else {
            _poolAmounts[_indexToken][_collateralToken] -= _amount;
            emit DecreasePoolAmount(_indexToken, _collateralToken, _amount);
        }

        _transferOut(_indexToken, _collateralToken, _amount, _receiver);


        emit TransferOut(_collateralToken, _receiver, _amount);
    }

    function increasePosition(
        bytes32 _key, 
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _sizeDelta, 
        bool _isLong,
        uint256 _amount
    ) external nonReentrant {
        require(isFrom[_collateralToken] && _collateralToken == usdt, "token err");
        slippage.validateRemoveTime(_indexToken);

        _validate(isLeverageEnabled, 28);
        _validateRouter();
        phase.validateTokens(_collateralToken, _indexToken);

        vaultUtils.validateIncreasePosition(_account, _collateralToken, _indexToken, _sizeDelta, _isLong);

        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];
        phase.setKey(_account, _collateralToken, _indexToken, key, _isLong);
        uint256 price = _isLong ? getMaxPrice(_indexToken) : getMinPrice(_indexToken);

        price = slippage.getVaultPrice(_indexToken, _sizeDelta, _isLong, price);

        if (position.size == 0) {
            position.averagePrice = price;
        }

        if (position.size > 0 && _sizeDelta > 0) {
            position.averagePrice = getNextAveragePrice(_indexToken, position.size, position.averagePrice, _isLong, price, _sizeDelta, position.lastIncreasedTime);
        }

        (uint256 fee, uint256 feeTokens) = vaultUtils.collectMarginFees(_account, _collateralToken, _indexToken, _isLong, _sizeDelta);

        _transferIn(_indexToken, _collateralToken, _amount);
        _transferFee(phase.codeType(_key), _key, key, _collateralToken, _account, feeTokens, _indexToken);

        uint256 collateralDeltaUsd = tokenToUsdMin(_collateralToken, _amount);
        position.collateral += collateralDeltaUsd;
        _validate(position.collateral >= fee, 29);
        position.collateral -= fee;
        position.size += _sizeDelta;
        position.lastIncreasedTime = block.timestamp;

        _validate(position.size > 0, 30);
        _validatePosition(position.size, position.collateral);
        validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);

        // reserve tokens to pay profits on the position
        uint256 reserveDelta = usdToTokenMax(_collateralToken, _sizeDelta);
        position.reserveAmount += reserveDelta;
        _increaseReservedAmount(_indexToken, _collateralToken, reserveDelta);

        if (_isLong) {
            // _guaranteedUsd stores the sum of (position.size - position.collateral) for all positions
            // if a fee is charged on the collateral then _guaranteedUsd should be increased by that fee amount
            // since (position.size - position.collateral) would have increased by `fee`
            _increaseGuaranteedUsd(_indexToken, _collateralToken, _sizeDelta + fee);
            _decreaseGuaranteedUsd(_indexToken, _collateralToken,  collateralDeltaUsd);
            // treat the deposited collateral as part of the pool
            
            //_increasePoolAmount(_collateralToken, collateralDelta);
            // fees need to be deducted from the pool since fees are deducted from position.collateral
            // and collateral is treated as part of the pool
            //_decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, fee));
            if (globalLongSizes[_indexToken] == 0) {
                globalLongAveragePrices[_indexToken] = price;
            } else {
                globalLongAveragePrices[_indexToken] = getNextGlobalLongAveragePrice(_indexToken, price, _sizeDelta);
            }
            _increaseGlobalLongSize(_indexToken, _sizeDelta);
            vaultUtils.increaseUserGlobalLongSize(_account, _collateralToken, _indexToken, _sizeDelta);
        } else {
            if (globalShortSizes[_indexToken] == 0) {
                globalShortAveragePrices[_indexToken] = price;
            } else {
                globalShortAveragePrices[_indexToken] = getNextGlobalShortAveragePrice(_indexToken, price, _sizeDelta);
            }

            _increaseGlobalShortSize(_indexToken, _sizeDelta);
            vaultUtils.increaseUserGlobalShortSize(_account, _collateralToken, _indexToken, _sizeDelta);
        }

        iEvent = IncreaseEvent(
            _key, 
            key, 
            _account, 
            _collateralToken, 
            _indexToken, 
            collateralDeltaUsd,
            _sizeDelta, 
            _isLong, 
            price, 
            fee
        );

        emit IncreasePosition(iEvent);
        delete iEvent;
        emit UpdatePosition(key, _account, _collateralToken, _indexToken, _isLong, price, position);
    }

    function decreasePosition(
        bytes32 _key, 
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _collateralDelta, 
        uint256 _sizeDelta, 
        bool _isLong, 
        address _receiver
    ) external  nonReentrant returns (uint256) {
        _validateRouter();
        slippage.validateRemoveTime(_indexToken);
        uint8 cType = phase.codeType(_key);

        return _decreasePosition(
            cType,
            _key, 
            _account, 
            _collateralToken, 
            _indexToken, 
            _collateralDelta, 
            _sizeDelta, 
            _isLong, 
            _receiver
        );
    }

    function _decreasePosition(
        uint8 cType,
        bytes32 _key,
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _collateralDelta, 
        uint256 _sizeDelta, 
        bool _isLong, 
        address _receiver
    ) private returns (uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];
        if(_sizeDelta >= position.size) {
            _sizeDelta = position.size;
            _collateralDelta = 0;
        }

        uint256 _collateralValue;
        if(position.size != 0) {
            _collateralValue = position.collateral * _sizeDelta / position.size;
        }

        RedCollateral memory rtl = RedCollateral(
            cType, 
            _key, 
            _account, 
            _collateralToken, 
            _indexToken, 
            _collateralDelta, 
            _sizeDelta, 
            _isLong
        );

        (, uint256 reserveDelta) = vaultUtils.validatePositionFrom(
            _account, 
            _collateralToken, 
            _indexToken, 
            _collateralDelta, 
            _sizeDelta, 
            _isLong, 
            _receiver
        );

        {
            dData = DecreaseEvent(
                _key,
                key, 
                _account, 
                _collateralToken, 
                _indexToken, 
                _collateralDelta, 
                _sizeDelta, 
                _isLong,
                0, 
                0, 
                0, 
                position.averagePrice, 
                block.timestamp, 
                0,
                0,
                0
            ); 
        }

        uint8 _cType = cType;
        uint256 collateral = position.collateral;

        position.reserveAmount -= reserveDelta;
        _decreaseReservedAmount(_indexToken, _collateralToken, reserveDelta);
        
        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(rtl);


        dData.fee = usdOut - usdOutAfterFee;
        dData.usdOutAfterFee = usdOutAfterFee;
        dData.averagePrice = position.averagePrice;
        dData.collateral = collateral;

        if (position.size != rtl._sizeDelta) {
            position.size -= rtl._sizeDelta;

            _validatePosition(position.size, position.collateral);

            if(_cType != uint8(5)) {
                vaultUtils.validateLiquidation(rtl._account, rtl._collateralToken, rtl._indexToken, rtl._isLong, true);
            }

            if (_isLong) {
                _increaseGuaranteedUsd(rtl._indexToken, rtl._collateralToken, collateral - position.collateral);
                _decreaseGuaranteedUsd(rtl._indexToken, rtl._collateralToken,  rtl._sizeDelta);
            }

            dData.price =_isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);

            emit UpdatePosition(key, rtl._account, rtl._collateralToken, rtl._indexToken, rtl._isLong, dData.price, position);
        } else {
            if (_isLong) {
                _increaseGuaranteedUsd(rtl._indexToken, rtl._collateralToken,  collateral);
                _decreaseGuaranteedUsd(rtl._indexToken, rtl._collateralToken,  rtl._sizeDelta);
            }

            dData.price =_isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
            
            ClosePositionEvent memory cEvent = ClosePositionEvent(
                rtl._collateralToken, 
                rtl._account, 
                rtl._indexToken, 
                rtl._isLong, 
                key, 
                position.size, 
                position.collateral, 
                position.averagePrice, 
                0, 
                position.reserveAmount, 
                position.realisedPnl
            );

            emit ClosePosition(cEvent);

            delete positions[key];
        }

        DecreaseEventFor memory dt = DecreaseEventFor(
            rtl.cType, 
            rtl._key, 
            key, 
            address(this), 
            _receiver, 
            0, 
            0, 
            0, 
            0, 
            0
        );

        if (!_isLong) {
            _decreaseGlobalShortSize(rtl._account, rtl._indexToken, rtl._sizeDelta);
        } else {
            _decreaseGlobalLongSize(rtl._account, rtl._indexToken, rtl._sizeDelta);   
        }

        uint256 amountOutAfterFees;
        if (usdOut > 0) {
            address rec = _receiver;
            address tokenFor = rtl._collateralToken;
            amountOutAfterFees = usdToTokenMin(tokenFor, usdOutAfterFee);

            dt.amount = amountOutAfterFees;

            TransferAmountData memory tData = _transferOut(rtl._indexToken, tokenFor, amountOutAfterFees, rec);
            
            dt.beforeAmount = tData.beforeAmount;
            dt.beforeValue = tData.beforeValue;
            dt.afterAmount = tData.afterAmount;
            dt.afterValue = tData.afterValue;

           emit DecreasePositionEvent(dt, _collateralValue);
        }

        dData.amountOutAfterFees = amountOutAfterFees;
        dData.afterCollateral = position.collateral;

        emit DecreasePosition(dData, _collateralValue);
        delete dData;
        return amountOutAfterFees;
    }

    function _liquidate() internal {
        if (inPrivateLiquidationMode) {
            _validate(isLiquidator[msg.sender], 34);
        }

        // set includeAmmPrice to false to prevent manipulated liquidations
        includeAmmPrice = false;
    }

    function liquidatePosition(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        bool _isLong, 
        address _feeReceiver
    ) external  nonReentrant {
        _liquidate();

        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        _validate(position.size > 0, 35);
        
        (uint256 liquidationState, uint256 marginFees) = validateLiquidation(_account, _collateralToken, _indexToken, _isLong, false);
        _validate(liquidationState != 0, 36);

        address addr = _account;
        if (liquidationState == 2) {
            uint256 _size = position.size;
            // max leverage exceeded but there is collateral remaining after deducting losses so decreasePosition instead
            _decreasePosition(4, phase.typeCode(4),  addr, _collateralToken, _indexToken, 0, _size, _isLong, addr);
            includeAmmPrice = true;
            return;
        }

        uint256 feeTokens = usdToTokenMin(_collateralToken, marginFees);

        _transferFee(3, phase.typeCode(3), key, _collateralToken, _account, feeTokens, _indexToken);
        emit LiquidatePositionFee(_collateralToken, marginFees, feeTokens);

        _decreaseReservedAmount(_indexToken, _collateralToken, position.reserveAmount);
        if (_isLong) {
            _decreaseGuaranteedUsd(_indexToken, _collateralToken,  position.size - position.collateral);
        }

        uint256 markPrice = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        LiquidateEvent memory lEvent = LiquidateEvent(
            key, 
            _account, 
            _collateralToken, 
            _indexToken, 
            _isLong, 
            position.size, 
            position.collateral, 
            position.reserveAmount, 
            position.realisedPnl,
            markPrice,
            position.averagePrice
        );

        address _cToken = _collateralToken;
        emit LiquidatePosition(lEvent);

        if (marginFees < position.collateral) {
            uint256 remainingCollateral = position.collateral - marginFees;
            _increasePoolAmount(_indexToken, _cToken, usdToTokenMin(_cToken, remainingCollateral));
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_account, _indexToken, position.size);
        } else {
            _decreaseGlobalLongSize(_account, _indexToken, position.size);
        }

        delete positions[key];

        _liquidatePosition(_indexToken, key, _cToken, _feeReceiver);
    }

    function _liquidatePosition(address _indexToken, bytes32 _key, address _collateralToken, address _feeReceiver) internal {
        // pay the fee receiver using the pool, we assume that in general the liquidated amount should be sufficient to cover
        // the liquidation fees
        _decreasePoolAmount(_indexToken, _collateralToken, usdToTokenMin(_collateralToken, liquidationFeeUsd));
        uint256 tokenAmount = usdToTokenMin(_collateralToken, liquidationFeeUsd);

        TransferAmountData memory tData = _transferOut(_indexToken, _collateralToken, tokenAmount, _feeReceiver);

        emit LiquidatePositionEvent(
            _key, 
            address(this), 
            _feeReceiver, 
            tokenAmount, 
            tData.beforeAmount, 
            tData.afterAmount, 
            tData.beforeValue, 
            tData.afterValue
        );
        emit LiquidationFeeUsd(_collateralToken, liquidationFeeUsd, tokenAmount);
        includeAmmPrice = true;
    }

    // validateLiquidation returns (state, fees)
    function validateLiquidation(address _account, address _collateralToken, address _indexToken, bool _isLong, bool _raise)  public view returns (uint256, uint256) {
        return vaultUtils.validateLiquidation(_account, _collateralToken, _indexToken, _isLong, _raise);
    }

    function getMaxPrice(address _token) public  view returns (uint256) {
        return IVaultPriceFeed(priceFeed).getPrice(_token, true, includeAmmPrice, false);
    }

    function getMinPrice(address _token) public  view returns (uint256) {
        return IVaultPriceFeed(priceFeed).getPrice(_token, false, includeAmmPrice, false);
    }

    function tokenToUsdMin(address _token, uint256 _tokenAmount) public  view returns (uint256) {
        return phase.tokenToUsdMin(_token, _tokenAmount);
    }

    function usdToTokenMax(address _token, uint256 _usdAmount) public view returns (uint256) {
        if (_usdAmount == 0) { return 0; }
        return usdToToken(_token, _usdAmount, getMinPrice(_token));
    }

    function usdToTokenMin(address _token, uint256 _usdAmount) public view returns (uint256) {
        if (_usdAmount == 0) { return 0; }
        return usdToToken(_token, _usdAmount, getMaxPrice(_token));
    }

    function usdToToken(address _token, uint256 _usdAmount, uint256 _price) public view returns (uint256) {
        return phase.usdToToken(_token, _usdAmount, _price);
    }

    function getPosition(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        bool _isLong
    ) public  view returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256) {

        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        uint256 realisedPnl = position.realisedPnl > 0 ? uint256(position.realisedPnl) : uint256(-position.realisedPnl);
        return (
            position.size, // 0
            position.collateral, // 1
            position.averagePrice, // 2
            0, // 3
            position.reserveAmount, // 4
            realisedPnl, // 5
            position.realisedPnl >= 0, // 6
            position.lastIncreasedTime // 7
        );
    }

    function getPositionKey(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        bool _isLong
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        ));
    }

    function getPositionLeverage(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        bool _isLong
    ) public view returns (uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        _validate(position.collateral > 0, 37);
        return position.size*10000/position.collateral;
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function getNextAveragePrice(
        address _indexToken, 
        uint256 _size, 
        uint256 _averagePrice, 
        bool _isLong, 
        uint256 _nextPrice, 
        uint256 _sizeDelta, 
        uint256 _lastIncreasedTime
    ) public view returns (uint256) {
        return phase.getNextAveragePrice(_indexToken, _size, _averagePrice, _isLong, _nextPrice, _sizeDelta, _lastIncreasedTime);
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function getNextGlobalShortAveragePrice(
        address _indexToken, 
        uint256 _nextPrice, 
        uint256 _sizeDelta
    ) public view returns (uint256) {
        return phase.getNextGlobalShortAveragePrice(_indexToken, _nextPrice, _sizeDelta);
    }

    function getNextGlobalLongAveragePrice(
        address _indexToken, 
        uint256 _nextPrice, 
        uint256 _sizeDelta
    ) public view returns (uint256) {
        return phase.getNextGlobalLongAveragePrice(_indexToken, _nextPrice, _sizeDelta);
    }

    function getGlobalShortDelta(address _token) public view returns (bool, uint256) {
        return phase.getGlobalShortDelta(_token);
    }

    function getPositionDelta(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        bool _isLong
    ) public view returns (bool, uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        return getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
    }

    function getDelta(
        address _indexToken, 
        uint256 _size, 
        uint256 _averagePrice, 
        bool _isLong, 
        uint256 _lastIncreasedTime
    ) public  view returns (bool, uint256) {
        _validate(_averagePrice > 0, 38);
        
        return phase.getDelta(_indexToken, _size, _averagePrice, _isLong, _lastIncreasedTime);
    }

    function getPositionFee(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        bool _isLong, 
        uint256 _sizeDelta
    ) public view returns (uint256) {
        return vaultUtils.getPositionFee(_account, _collateralToken, _indexToken, _isLong, _sizeDelta);
    }

    function _validatePosition(uint256 _size, uint256 _collateral) private view {
        if (_size == 0) {
            _validate(_collateral == 0, 39);
            return;
        }
        _validate(_size >= _collateral, 40);
    }

    function _validateRouter() private view {
        require(msg.sender == router || msg.sender == address(phase), "router");
    }

    function getAmount(address token, address account) public view returns(uint256) {
        return IERC20(token).balanceOf(account);
    }

    function _transferFee(
        uint8 cType, 
        bytes32 typeKey, 
        bytes32 key, 
        address token, 
        address account, 
        uint256 fee,
        address indexToken
    ) internal {
        if(fee > 0) {
            TransferAmountData memory tData = _transferOut(indexToken, token, fee, address(referralData));
            referralData.addFee(cType, typeKey, key, account, token, fee, indexToken);

            emit CollectMarginFees(
                cType,
                typeKey, 
                key,  
                address(this), 
                address(referralData), 
                fee,
                tData.beforeAmount, 
                tData.afterAmount, 
                tData.beforeValue, 
                tData.afterValue
            );
        }
    }
 
    function _transferIn(address _indexToken, address _collateralToken, uint256 _amount) private {
        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2
        if(getCoinType(_indexToken) == 1) {
            _tokenBalances[_collateralToken][_collateralToken] += _amount;
        } else {
            _tokenBalances[_indexToken][_collateralToken] += _amount;
        }
    }

    function _transferOut(
        address _indexToken, 
        address _collateralToken, 
        uint256 _amount, 
        address _receiver
    ) private returns(TransferAmountData memory tData) {
        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2
        if(getCoinType(_indexToken)== 1) {
            _tokenBalances[_collateralToken][_collateralToken] -= _amount;
        } else {
            _tokenBalances[_indexToken][_collateralToken] -= _amount;
        }
        
        if(_amount > 0) {
            tData.beforeAmount = getAmount(_collateralToken, address(this));
            tData.beforeValue = getAmount(_collateralToken, _receiver);
            IERC20(_collateralToken).safeTransfer(_receiver, _amount);
            tData.afterAmount = getAmount(_collateralToken, address(this));
            tData.afterValue = getAmount(_collateralToken, _receiver);
        }
    }

    function _increasePoolAmount(address _indexToken, address _collateralToken, uint256 _amount) private {
        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2
        if(getCoinType(_indexToken)== 1) {
            _poolAmounts[_collateralToken][_collateralToken] += _amount;
            emit IncreasePoolAmount(_collateralToken, _collateralToken, _amount);
        } else {
            _poolAmounts[_indexToken][_collateralToken] += _amount;
            emit IncreasePoolAmount(_indexToken, _collateralToken, _amount);
        }
    }

    function _decreasePoolAmount(address _indexToken, address _collateralToken, uint256 _amount) private {
        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2
        if(getCoinType(_indexToken)== 1) {
            if(_poolAmounts[_collateralToken][_collateralToken] < _amount) {
                revert();
            }
            _poolAmounts[_collateralToken][_collateralToken] -= _amount;
            _validate(_reservedAmounts[_collateralToken][_collateralToken] <= _poolAmounts[_collateralToken][_collateralToken]  * multiplier / 10000, 50);
            emit DecreasePoolAmount(_collateralToken, _collateralToken, _amount);
        } else {
            if(_poolAmounts[_indexToken][_collateralToken] < _amount) {
                revert();
            }

            _poolAmounts[_indexToken][_collateralToken] -= _amount;
            _validate(_reservedAmounts[_indexToken][_collateralToken] <= _poolAmounts[_indexToken][_collateralToken]  * multiplier / 10000, 50);
            emit DecreasePoolAmount(_indexToken, _collateralToken, _amount);
        }

    }

    function _increaseReservedAmount(address _indexToken, address _collateralToken, uint256 _amount) private {
        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2
        if(getCoinType(_indexToken)== 1) {
            _reservedAmounts[_collateralToken][_collateralToken] +=_amount;
            _validate(_reservedAmounts[_collateralToken][_collateralToken] <= _poolAmounts[_collateralToken][_collateralToken] * multiplier / 10000, 52);
            emit IncreaseReservedAmount(_collateralToken, _collateralToken, _amount);
        } else {
            _reservedAmounts[_indexToken][_collateralToken] +=_amount;
            _validate(_reservedAmounts[_indexToken][_collateralToken] <= _poolAmounts[_indexToken][_collateralToken] * multiplier / 10000, 52);
            emit IncreaseReservedAmount(_indexToken, _collateralToken, _amount);
        }
    }

    function _decreaseReservedAmount(address _indexToken, address _collateralToken, uint256 _amount) private {
        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2
        if(getCoinType(_indexToken)== 1) {
            _reservedAmounts[_collateralToken][_collateralToken] -= _amount;
            emit DecreaseReservedAmount(_collateralToken, _collateralToken, _amount);
        } else {
            _reservedAmounts[_indexToken][_collateralToken] -= _amount;
            emit DecreaseReservedAmount(_indexToken, _collateralToken, _amount);
        }
    }

    function _increaseGuaranteedUsd(address _indexToken, address _collateralToken,  uint256 _usdAmount) private {        
        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2
        if(getCoinType(_indexToken)== 1) {
            _guaranteedUsd[_collateralToken][_collateralToken] += _usdAmount;
        
            emit IncreaseGuaranteedUsd(_collateralToken, _collateralToken, _usdAmount);
        } else {
            _guaranteedUsd[_indexToken][_collateralToken] += _usdAmount;
        
            emit IncreaseGuaranteedUsd(_indexToken, _collateralToken, _usdAmount);
        }

    }

    function _decreaseGuaranteedUsd(address _indexToken, address _collateralToken, uint256 _usdAmount) private {
        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2
        if(getCoinType(_indexToken)== 1) {
            _guaranteedUsd[_collateralToken][_collateralToken] -= _usdAmount;

            emit DecreaseGuaranteedUsd(_collateralToken, _collateralToken, _usdAmount);
        } else {
            _guaranteedUsd[_indexToken][_collateralToken] -= _usdAmount;

            emit DecreaseGuaranteedUsd(_indexToken, _collateralToken, _usdAmount);
        }
    }

    function _increaseGlobalLongSize(address _indexToken, uint256 _amount) internal {
        globalLongSizes[_indexToken] += _amount;

        uint256 maxSize = maxGlobalLongSizes[_indexToken];
        if (maxSize != 0) {
            require(globalLongSizes[_indexToken] <= maxSize, "long");
        }
    }

    function _decreaseGlobalLongSize(address user, address _indexToken, uint256 _amount) private {
        uint256 size = globalLongSizes[_indexToken];

        vaultUtils.decreaseUserGlobalLongSize(user, _amount);
        if (_amount > size) {
          globalLongSizes[_indexToken] = 0;
          return;
        }

        globalLongSizes[_indexToken] = size - _amount;
    }

    function _increaseGlobalShortSize(address _indexToken, uint256 _amount) internal {
        globalShortSizes[_indexToken] += _amount;

        uint256 maxSize = maxGlobalShortSizes[_indexToken];
        if (maxSize != 0) {
            require(globalShortSizes[_indexToken] <= maxSize, "shorts");
        }
    }

    function _decreaseGlobalShortSize(address user, address _indexToken, uint256 _amount) private {
        uint256 size = globalShortSizes[_indexToken];
        vaultUtils.decreaseUserGlobalShortSize(user, _amount);
        if (_amount > size) {
          globalShortSizes[_indexToken] = 0;
          return;
        }

        globalShortSizes[_indexToken] = size - _amount;

    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _onlyGov() private view {
        _validate(msg.sender == gov, 53);
    }


    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateManager() private view {
        require(isManager[msg.sender], "not manager"); 
    }

    function _validate(bool _condition, uint256 _errorCode) private view {
        require(_condition, errors[_errorCode]);
    }

    function validate(bool _condition, uint256 _errorCode) external view {
        require(_condition, errors[_errorCode]);
    }

    function getAllWhitelistedTokens() external view returns(address[] memory) {
        return allWhitelistedTokens;
    }

    function getPositionFrom(bytes32 key) external view returns(Position memory)  {
        return positions[key];
    }    

    function _reduceCollateral(
        RedCollateral memory rtl
    ) private returns (uint256, uint256) {
        bytes32 key = getPositionKey(rtl._account, rtl._collateralToken, rtl._indexToken, rtl._isLong);
        Position storage position = positions[key];

        (uint256 fee, uint256 feeTokens) = vaultUtils.collectMarginFees(
            rtl._account, rtl._collateralToken, rtl._indexToken, rtl._isLong, rtl._sizeDelta
        );

        _transferFee(rtl.cType, rtl._key, key, rtl._collateralToken, rtl._account, feeTokens, rtl._indexToken);
        bool hasProfit;
        uint256 adjustedDelta;

        // scope variables to avoid stack too deep errors
        {
            (bool _hasProfit, uint256 delta) = getDelta(
                rtl._indexToken, 
                position.size, 
                position.averagePrice, 
                rtl._isLong, 
                position.lastIncreasedTime
            );
            hasProfit = _hasProfit;
            // get the proportional change in pnl
            adjustedDelta = rtl._sizeDelta * delta / position.size;
        }

        uint256 usdOut;
        // transfer profits out
        if (hasProfit && adjustedDelta > 0) {
            usdOut = adjustedDelta;
            position.realisedPnl += int256(adjustedDelta);

            uint256 tokenAmount = usdToTokenMin(rtl._collateralToken, adjustedDelta);
            _decreasePoolAmount(rtl._indexToken, rtl._collateralToken, tokenAmount);
            
        }

        if (!hasProfit && adjustedDelta > 0) {
            position.collateral -= adjustedDelta;

            // transfer realised losses to the pool for short positions
            // realised losses for long positions are not transferred here as
            // _increasePoolAmount was already called in increasePosition for longs
            uint256 tokenAmount = usdToTokenMin(rtl._collateralToken, adjustedDelta);
            _increasePoolAmount(rtl._indexToken, rtl._collateralToken, tokenAmount);
            
            position.realisedPnl -= int256(adjustedDelta);
        }

        // reduce the position's collateral by _collateralDelta
        // transfer _collateralDelta out
        if (rtl._collateralDelta > 0) {
            usdOut = usdOut + rtl._collateralDelta;
            position.collateral -= rtl._collateralDelta;
        }


        // if the position will be closed, then transfer the remaining collateral out
        if (position.size == rtl._sizeDelta) {
            usdOut += position.collateral;
            position.collateral = 0;
        }

        // if the usdOut is more than the fee then deduct the fee from the usdOut directly
        // else deduct the fee from the position's collateral
        uint256 usdOutAfterFee = usdOut;
        if (usdOut > fee) {
            usdOutAfterFee = usdOut - fee;
        } else {
            if(position.collateral < fee) {
                revert();
            }
            position.collateral -= fee;
        }

        emit UpdatePnl(key, hasProfit, adjustedDelta);

        return (usdOut, usdOutAfterFee);
    }

    function autoDecreasePosition(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        bool _isLong
    ) external  nonReentrant returns(uint256) {
        require(msg.sender == address(slippage), "not slippage");
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);

        return _decreasePosition(
            6, 
            phase.typeCode(6),  
            _account, 
            _collateralToken, 
            _indexToken, 
            0, 
            positions[key].size, 
            _isLong, 
            msg.sender
        );
    }

    function allWhitelistedTokensLength() external  view returns (uint256) {
        return allWhitelistedTokens.length;
    }

    function getCoinType(address _indexToken) public  view returns(uint8) {
        return ICoinData(IPhase(phase).coinData()).getCoinType(_indexToken);
    }
    
    function poolAmounts(address _indexToken, address _collateralToken) external view returns(uint256) {
        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2
        // If other tokens are transferred, there will be zero returned
        if(getCoinType(_indexToken) == 1) {
            return _poolAmounts[_collateralToken][_collateralToken];
        } else {
            return _poolAmounts[_indexToken][_collateralToken];
        }
    }

    function reservedAmounts(address _indexToken, address _collateralToken) external view returns(uint256) {
        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2
        // If other tokens are transferred, there will be zero returned
        if(getCoinType(_indexToken) == 1) {
            return _reservedAmounts[_collateralToken][_collateralToken];
        } else {
            return _reservedAmounts[_indexToken][_collateralToken];
        }
    }

    function guaranteedUsd(address _indexToken, address _collateralToken) external view returns(uint256) {
        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2
        // If other tokens are transferred, there will be zero returned
        if(getCoinType(_indexToken) == 1) {
            return _guaranteedUsd[_collateralToken][_collateralToken];
        } else {
            return _guaranteedUsd[_indexToken][_collateralToken];
        }
    }

    function tokenBalances(address _indexToken, address _collateralToken) external view returns(uint256) {
        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2
        // If other tokens are transferred, there will be zero returned
        if(getCoinType(_indexToken) == 1) {
            return _tokenBalances[_collateralToken][_collateralToken];
        } else {
            return _tokenBalances[_indexToken][_collateralToken];
        }
    }

    mapping (address => uint256) public maxGlobalLongSizes;
    function setMaxGlobalLongSize(address _token, uint256 _amount) external {
        _onlyGov();
        maxGlobalLongSizes[_token] = _amount;
    }

}
