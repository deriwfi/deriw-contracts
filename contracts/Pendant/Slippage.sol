// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../core/interfaces/IERC20Metadata.sol";
import "../core/interfaces/IVault.sol";
import "./interfaces/IPhase.sol";
import "../core/interfaces/IVaultUtils.sol";
import "../core/interfaces/IEventStruct.sol";
import "../core/interfaces/IOrderBook.sol";
import "./interfaces/ICoinData.sol";
import "../upgradeability/Synchron.sol";
import "../core/interfaces/IDataReader.sol";
import "../meme/interfaces/IMemeFactory.sol";
import "./interfaces/ISlippageControl.sol";
import "../oracle/interfaces/IPriceOracle.sol";

contract Slippage is Synchron, IEventStruct {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant muti = 1e8;
    uint256 public constant baseRate = 10000;
    uint256 public constant MAX_INT256 = uint256(type(int256).max);

    EnumerableSet.AddressSet indexTokens;  
    IVault public vault;
    IOrderBook public orderBook;
    ICoinData public coinData;

    address public USDT;
    address public gov;
    address public glpManager;

    uint256 public factor;
    uint256 public threshold;
    uint256 public decreaseFeeRate;

    bool public initialized;

    mapping(address => uint256) public removeNum;
    mapping(address => mapping(uint256 => RemoveShelves)) removeShelves;
    mapping(address => mapping(address => uint256)) _glpTokenSupply;
    /// @notice Per-token max leverage (basis points). Per current requirements this holds the
    ///         liquidation leverage threshold (set via setTokenLeverageConfig), falling back to
    ///         vault.maxLeverage() when unset (see getTokenMaxLeverage).
    mapping(address => uint256) public tokenMaxLeverage;
 
    struct RemoveShelves {
        uint256 pid;
        uint256 num;
        uint256 startTime;
        uint256 endtime;
    }

    struct TransferData {
        address token; 
        address from; 
        address account; 
        address feeAccount;
        uint256 amount; 
        uint256 feeAmount;
        uint256 beforeSliAmount; 
        uint256 beforeValue;
        uint256 beforeFeeAccountValue;
        uint256 afterSliAmount;
        uint256 afterValue;
        uint256 afterFeeAccountValue;
    }

    struct LeverageData{
        address indexToken;
        uint256 maxLeverage;
    }

    event TransferTo(TransferData tData);

    event SetRemoveTime(
        address token,
        uint256 rNum,
        uint256 startTime,
        uint256 endtime
    );

    event SetTokenMaxLeverage(LeverageData[] eDtata);

    constructor() {
        initialized = true;
    }

    modifier onlyGov() {
        require(msg.sender == gov, "Governable: forbidden");
        _;
    }

    modifier onlyGlpManager() {
        require(msg.sender == glpManager || msg.sender == coinData.memeData(), "not manager");
        _;
    }

    function initialize(address usdt) external {
        require(!initialized, "has initialized");
        require(usdt != address(0), "addr err");

        initialized = true;
        USDT = usdt;
        factor = 200;
        threshold = 7000;
        decreaseFeeRate = 100;

        gov = msg.sender;
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "_gov err");
        gov = _gov;
    }

    function setContract(
        address _coinData,
        address _glpManager,
        address _vault,
        address _orderBook
    ) external onlyGov {
        require(
            _coinData != address(0) &&
            _glpManager != address(0) &&
            _vault != address(0) &&
            _orderBook != address(0),
            "addr err"
        );

        coinData = ICoinData(_coinData);
        glpManager = _glpManager;
        vault = IVault(_vault);
        orderBook = IOrderBook(_orderBook);
    }
    
    function setTokenMaxLeverage(LeverageData[] memory /*eDtata*/) external onlyGov {}
    
    function setTreshold(uint256 threshold_) external onlyGov {
        require(threshold_ > 0, "threshold_ err");
        threshold = threshold_;
    }

    function setFactor(uint256 factor_) external onlyGov {
        require(factor_ > 0 && factor_ <= baseRate, "factor_ err");
        factor = factor_;
    }

    function addTokens(address indexToken) external {
        require(msg.sender == vault.phase(), "not phase");
        // _type == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // _type == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2        
        uint8 _type = coinData.getCoinType(indexToken);
        if(_type == 1) {
            indexTokens.add(indexToken);
        } else {
            memeIndexTokens.add(indexToken);
        }
    }

    function setDecreaseFeeRate(uint256 rate_) external onlyGov {
        require(rate_ <= 2000, "rate_ err");
        decreaseFeeRate = rate_;
    }

    function autoDecreasePosition(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        bool _isLong, 
        address _feeAccount
    ) external {
        validate();
        _autoDecreasePosition(_account, _collateralToken, _indexToken, _feeAccount, _isLong);
    }


    function addGlpAmount(address _indexToken, address _collateralToken, uint256 _amount) external onlyGlpManager {
        _indexToken = dataReader.getTargetIndexToken(_indexToken);
        _glpTokenSupply[_indexToken][_collateralToken] += _amount;
    }

    function subGlpAmount(address _indexToken, address _collateralToken, uint256 _amount) external onlyGlpManager {              
        _indexToken = dataReader.getTargetIndexToken(_indexToken);
        _glpTokenSupply[_indexToken][_collateralToken] -= _amount;
    }

    function glpTokenSupply(address _indexToken, address _collateralToken) external view returns(uint256) {
        _indexToken = dataReader.getTargetIndexToken(_indexToken);
             
        return _glpTokenSupply[_indexToken][_collateralToken];
    }

    // **********************************************************************
    function getVaultPrice(
        address indexToken, 
        uint256 size, 
        bool isLong, 
        uint256 price
    ) external view returns(uint256) {
        uint256 rate = getRate(indexToken, size, isLong);
        
        if(rate > 0) {
            if(isLong) {
                price = price * (muti + rate) / muti;
            } else {
                if(rate < muti) {
                    price = price * (muti - rate) / muti;
                } else {
                    revert("exceeds 100%");   
                }  
            }
        }
        return price;
    }

    function getRate(address indexToken, uint256 size, bool isLong) public view returns(uint256) {
        if(isLong) {
            return getLongRate(indexToken, size);
        } else {
            return getShortRate(indexToken, size);
        }
    }

    function getLongRate(address indexToken, uint256 size) public view returns(uint256) {
        (, uint256 finalSlip, ) = slippageControl.getSlipData(indexToken, USDT, size, true);

        return finalSlip;
    }

    function getShortRate(address indexToken, uint256 size)  public view returns(uint256) {
        (, uint256 finalSlip, ) = slippageControl.getSlipData(indexToken, USDT, size, false);

        return finalSlip;
    }

    /// @notice Deprecated legacy query: always returns 0 (implementation removed).
    /// @dev Kept only to preserve the external ABI/selector; do NOT restore it into active
    ///      pricing. If removed later, do NOT delete the underlying storage variables.
    function getPoolAmountSizeThreshold(address /*indexToken*/, bool /*isLong*/) public view returns(uint256) {}

    /// @notice Deprecated legacy query: always returns 0 (implementation removed).
    /// @dev Only the deprecated getPoolAmountSizeThreshold used this; retained for ABI compatibility.
    function getPoolAmountSize(address /*indexToken*/, bool /*isLong*/) public view returns(uint256) {}

    function getLongNetAmount(address indexToken, uint256 size) public view returns(uint256, uint256) {
        (
            uint256 globalShortSizes,
            uint256 globalLongSizes, 
        ) = getSizeData(indexToken);

        globalLongSizes += size;
        if(globalLongSizes > globalShortSizes) {
            return (globalLongSizes, globalLongSizes - globalShortSizes);
        } 
        return (globalLongSizes, 0);
    }

    function getShortNetAmount(address indexToken, uint256 size) public view returns(uint256, uint256) {
        (
            uint256 globalShortSizes,
            uint256 globalLongSizes, 
        ) = getSizeData(indexToken);


        globalShortSizes += size;
        if(globalShortSizes > globalLongSizes) {
            return (globalShortSizes, globalShortSizes - globalLongSizes);
        }
        return (globalShortSizes, 0);
    }
    
    //   ***********************************  
    function getConfig(address _token) external view returns(        
        uint256 tokenDecimals,
        uint256 tokenWeights,
        uint256 minProfitBasisPoints,
        bool stableTokens,
        bool shortableTokens,
        bool iswrapped, 
        bool isFrom
    ) 
    {        
        _token = dataReader.getIndexToken(_token);
        tokenDecimals = vault.tokenDecimals(_token);
        tokenWeights = vault.tokenWeights(_token);
        minProfitBasisPoints = vault.minProfitBasisPoints(_token);
        stableTokens = vault.stableTokens(_token);
        shortableTokens = vault.shortableTokens(_token);
        iswrapped = vault.iswrapped(_token);
        isFrom = vault.isFrom(_token);
    }

    function getValue(
        address /*user*/, 
        address indexToken, 
        uint256 poolTotalValue,
        uint256 _poolValue,
        uint256 min, 
        bool isLong
    ) external view returns(uint256, uint256) {
        (uint256 _min, uint256 num) = _getValue(indexToken, poolTotalValue, _poolValue, min, isLong);

        return (_min, num);
    }

    function _getValue(
        address indexToken, 
        uint256 poolTotalValue,
        uint256 _poolValue,
        uint256 min, 
        bool isLong
    ) internal view returns(uint256, uint256) {
        (
            uint256 globalShortSizes,
            uint256 globalLongSizes,
            uint256 totalSize
        ) = getSizeData(indexToken);

        if(poolTotalValue > totalSize) {
            uint256 _min = poolTotalValue - totalSize;
            min = getMin(min, _min);
        } else {
            return (0, 2);
        }

        address pool = memeFactory().channelMappedTokenPool(indexToken);
        if(pool == address(0)) {
            int256 longNetValue = int256(globalLongSizes) - int256(globalShortSizes);
            int256 shortNetValue = int256(globalShortSizes) - int256(globalLongSizes);

            if(isLong) {
                return getMinValue(min, _poolValue, longNetValue);
            } else {
                return getMinValue(min, _poolValue, shortNetValue);
            }
        } else {
            if(isLong) {
                if(_poolValue > globalLongSizes) {
                    min = getMin(min, _poolValue - globalLongSizes);
                    return (min, 6);
                } else {
                    return (0, 7);
                }
            } else {
                if(_poolValue > globalShortSizes) {
                    min = getMin(min, _poolValue - globalShortSizes);
                    return (min, 8);
                } else {
                    return (0, 9);
                }
            }
        }
    }

    function getMinValue(uint256 min, uint256 _poolValue, int256 netValue) public pure returns(uint256, uint256) {
        if(netValue > 0) {
            if(_poolValue > uint256(netValue)) {
                uint256 _min = _poolValue - uint256(netValue);
                min = getMin(min, _min);
                return (min, 3);
            } else {
                return (0, 4);
            }
        } else {
            uint256 _min = _poolValue + uint256(-netValue);
            min = getMin(min, _min);
            return (min, 5);
        }
    }

    function getMin(uint256 a, uint256 b) public pure returns(uint256 c) {
        c = a > b ? b : a;
    }

    function validateLever(
        address user,       
        address token,
        address indexToken,  
        uint256 _amountIn,
        uint256 _sizeDelta,
        bool isLong
    ) external view returns(bool) {
        uint256 size = vault.tokenToUsdMin(token, _amountIn);

        bytes32 key = vault.getPositionKey(user, token, indexToken, isLong);
        Position memory pos = vault.getPositionFrom(key);

        size += pos.collateral;
        _sizeDelta += pos.size;
        (uint256 maxLeverage,) = getTokenLeverage(indexToken);
        require(_sizeDelta * baseRate / size <= maxLeverage, "big err");
        
        validateCreate(indexToken);

        return true;
    }

    function getPhaseMinValue(address indexToken) external view returns(uint256, uint256) {
        IPhase phase = IPhase(vault.phase());

        uint256 indexTokenValue = phase.getIndextokenValue(indexToken);
        (int256 longValue, int256 shortValue) = phase.getLongShortValue(indexToken);
        int256 totalSizeValue = longValue + shortValue;

        uint256 min;
        if(totalSizeValue > 0) {
            uint256 totalValue = uint256(totalSizeValue);
            if(indexTokenValue > totalValue) {
                min = indexTokenValue - totalValue;
                return (min, 0);
            } else {
                return (0, 1);
            }
        }   else {
            min = indexTokenValue + uint256(-totalSizeValue);
            return (min, 0);
        }
    }

    //************************************************************************ 
    function getAmount(address token, address account) public view returns(uint256) {
        return IERC20(token).balanceOf(account);
    }

    function validateRemoveTime(address token) external view returns(bool) {
        uint256 endtime = getEndTime(token);
        (,,uint256 lastTime,) = dataReader.getTokenInfo(token);
        if(endtime != 0) {
            require(
                lastTime > endtime ||
                block.timestamp < endtime, 
                "has rmove shelves"
            );
        }
        return true;
    }

    function validateCreate(address token) public view returns(bool) {
        (uint256 startTime, uint256 endtime) = getRemoveTime(token);
        (,,uint256 lastTime,) = dataReader.getTokenInfo(token);
        if(startTime != 0) {
            require(
                lastTime > endtime ||
                block.timestamp < startTime, 
                "has rmove shelves"
            );
        }

        return true;
    }

    function getEndTime(address token) public  view returns(uint256) {
        token = dataReader.getIndexToken(token);
        uint256 rNum = removeNum[token];
        return removeShelves[token][rNum].endtime;
    }

    function getRemoveTime(address token) public view returns(uint256, uint256) {
        token = dataReader.getIndexToken(token);
        uint256 rNum = removeNum[token];
        return (removeShelves[token][rNum].startTime, removeShelves[token][rNum].endtime);
    }

    function setRemoveTime(
        address token,
        uint256 startTime,
        uint256 endTime
    ) external {
        validate();
        _setRemoveTime(token, startTime, endTime);
    }

    function getCurrRemoveShelves(
        address token
    ) external view returns(RemoveShelves memory) {
        return getRemoveShelves(token, removeNum[token]);
    }
 
    function getRemoveShelves(
        address token, 
        uint256 rNum
    ) public view returns(RemoveShelves memory) {
        token = dataReader.getIndexToken(token);
        return removeShelves[token][rNum];
    }

    function getSizeData(address indexToken) public view returns(
        uint256 globalShortSizes,
        uint256 globalLongSizes,
        uint256 totalSize
    ) {
        (globalShortSizes, globalLongSizes, totalSize) = dataReader.getSizeData(indexToken);
    }

    function getIndexTokensLength() external view returns(uint256) {
        return indexTokens.length();
    }

    function getIndexToken(uint256 index) external view returns(address) {
        return indexTokens.at(index);
    }

    // *************************************************************************
    function getDecreasePositionNextGlobalLongShortData(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        bool _isLong
    ) external view returns (uint256, uint256) {
        // DER-08: realised PnL must share the SAME execution price as the global-average update
        // below (Vault passes dData.price as _nextPrice), not a full-position re-priced quote.
        int256 realisedPnl = _getRealisedPnl(_account, _collateralToken, _indexToken, _sizeDelta, _isLong, _nextPrice);

        uint256 averagePrice = _isLong ? vault.globalLongAveragePrices(_indexToken) : vault.globalShortAveragePrices(_indexToken);
        uint256 priceDelta = averagePrice > _nextPrice ? averagePrice - _nextPrice : _nextPrice - averagePrice;

        uint256 nextSize;
        uint256 delta;
        // avoid stack to deep
        {
            uint256 size = _isLong ? vault.globalLongSizes(_indexToken) : vault.globalShortSizes(_indexToken);
            nextSize = size - _sizeDelta;

            if (nextSize == 0) {
                return (0, 0);
            }

            if (averagePrice == 0) {
                return (nextSize, _nextPrice);
            }

            delta = size * priceDelta / averagePrice;
        }

        uint256 nextAveragePrice = _getNextGlobalAveragePrice(
            averagePrice,
            _nextPrice,
            nextSize,
            delta,
            realisedPnl,
            _isLong
        );

        return (nextSize, nextAveragePrice);
    }

    /// @notice Realised PnL of a partial close, priced at the sizeDelta execution price so the
    ///         public view mirrors on-chain accounting (DER-08).
    function getRealisedPnl(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) public view returns (int256) {
        (,uint256 sPrice,) = slippageControl.getDecreaseSlipPrice(_indexToken, _sizeDelta, _isLong);
        return _getRealisedPnl(_account, _collateralToken, _indexToken, _sizeDelta, _isLong, sPrice);
    }

    /// @notice Realised PnL of a partial close priced at an explicitly supplied execution price.
    /// @dev DER-08: internal accounting passes _nextPrice (= dData.price from Vault), so PnL and
    ///      the global average-price update share one execution price instead of mixing a
    ///      full-position quote with a sizeDelta quote.
    function _getRealisedPnl(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _price
    ) internal view returns (int256) {
        IVault _vault = vault;
        (, , uint256 averagePrice, , , , , ) = _vault.getPosition(_account, _collateralToken, _indexToken, _isLong);
        if(averagePrice == 0) revert("_averagePrice err");

        uint256 priceDelta = averagePrice > _price ? averagePrice - _price : _price - averagePrice;
        bool hasProfit = _isLong ? _price > averagePrice : averagePrice > _price;

        uint256 adjustedDelta = _sizeDelta * priceDelta / averagePrice;
        require(adjustedDelta < MAX_INT256, "ShortsTracker: overflow");
        return hasProfit ? int256(adjustedDelta) : -int256(adjustedDelta);
    }

    function _getNextGlobalAveragePrice(
        uint256 _averagePrice,
        uint256 _nextPrice,
        uint256 _nextSize,
        uint256 _delta,
        int256 _realisedPnl,
        bool _isLong
    ) public pure returns (uint256) {
        (bool hasProfit, uint256 nextDelta) = _getNextDelta(_delta, _averagePrice, _nextPrice, _realisedPnl, _isLong);
        
        uint256 divisor;
        if (_isLong) {
            divisor = hasProfit ? _nextSize + nextDelta : _nextSize - nextDelta;
        } else {
            divisor = hasProfit ? _nextSize - nextDelta : _nextSize + nextDelta;
        }
        uint256 nextAveragePrice = _nextPrice * _nextSize / divisor;

        return nextAveragePrice;
    }


    function _getNextDelta(
        uint256 _delta,
        uint256 _averagePrice,
        uint256 _nextPrice,
        int256 _realisedPnl,
        bool _isLong
    ) internal pure returns (bool, uint256) {
        // global delta 10000, realised pnl 1000 => new pnl 9000
        // global delta 10000, realised pnl -1000 => new pnl 11000
        // global delta -10000, realised pnl 1000 => new pnl -11000
        // global delta -10000, realised pnl -1000 => new pnl -9000
        // global delta 10000, realised pnl 11000 => new pnl -1000 (flips sign)
        // global delta -10000, realised pnl -11000 => new pnl 1000 (flips sign)

        bool hasProfit = _isLong ? _averagePrice < _nextPrice : _averagePrice > _nextPrice;
        if (hasProfit) {
            // global shorts pnl is positive
            if (_realisedPnl > 0) {
                if (uint256(_realisedPnl) > _delta) {
                    _delta = uint256(_realisedPnl) - _delta;
                    hasProfit = false;
                } else {
                    _delta = _delta - uint256(_realisedPnl);
                }
            } else {
                _delta = _delta + uint256(-_realisedPnl);
            }

            return (hasProfit, _delta);
        }

        if (_realisedPnl > 0) {
            _delta = _delta + uint256(_realisedPnl);
        } else {
            if (uint256(-_realisedPnl) > _delta) {
                _delta = uint256(-_realisedPnl) - _delta;
                hasProfit = true;
            } else {
                _delta = _delta - uint256(-_realisedPnl);
            }
        }
        return (hasProfit, _delta);
    }

    function getPositionLeverage(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        bool _isLong
    ) public view returns (uint256) {
        (uint256 size, uint256 collateral,,,,,,) = IVault(vault).getPosition(_account, _collateralToken, _indexToken, _isLong);
        require(collateral > 0, "collateral err");
        return size * 10000 / collateral;
    }


    function getPositionDelta(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        bool _isLong
    ) public view returns (bool, uint256) {
        (uint256 size,, uint256 averagePrice,,,,,uint256 lastIncreasedTime) = IVault(vault).getPosition(_account, _collateralToken, _indexToken, _isLong);
        return vault.getDelta(_indexToken, size, averagePrice, _isLong, lastIncreasedTime);
    }

    /**
     * @notice Get the liquidation leverage threshold for a token
     * @dev    Resolves channel tokens to their underlying index token.
     *         Per current requirements, tokenMaxLeverage stores the liquidation leverage threshold
     *         (set via setTokenLeverageConfig), so this function returns the liquidation leverage,
     *         falling back to vault.maxLeverage() when the token is not configured.
     * @param  indexToken The token to query (auto-resolved to its underlying index token)
     * @return The liquidation leverage threshold (falls back to vault.maxLeverage() if unset)
     */
    function getTokenMaxLeverage(address indexToken) public view returns(uint256) {
        indexToken = dataReader.getIndexToken(indexToken);
        uint256 maxLeverage = tokenMaxLeverage[indexToken] == 0 ? vault.maxLeverage() : tokenMaxLeverage[indexToken];

        return maxLeverage;
    }

    // *****************************************************
    IDataReader public dataReader;
    EnumerableSet.AddressSet memeIndexTokens;  

    struct RemoveToken {
        address token;
        uint256 startTime;
        uint256 endTime;
    }

    struct AutoStruct {
        address account;
        address collateralToken;
        address indexToken;
        address feeAccount;
        bool isLong;
    }

    function setDataReader(address _dataReader) external onlyGov {
        require(_dataReader != address(0), "_dataReader err");
        dataReader = IDataReader(_dataReader);
    }

    function batchSetRemoveTime(RemoveToken[] memory removeToken) external {
        validate();
        uint256 len = removeToken.length;
        require(len > 0, "length err");

        for(uint256 i = 0; i < len; i++) {
            _setRemoveTime(removeToken[i].token, removeToken[i].startTime, removeToken[i].endTime);
        }
    }

    function batchAutoDecreasePosition(
        AutoStruct[] memory autoData
    ) external {
        validate();
        uint256 len = autoData.length;
        require(len > 0, "length err");
        for(uint256 i = 0; i < len; i++) {
            _autoDecreasePosition(
                autoData[i].account, 
                autoData[i].collateralToken, 
                autoData[i].indexToken, 
                autoData[i].feeAccount, 
                autoData[i].isLong
            );
        }
    }

    function _setRemoveTime(
        address token,
        uint256 startTime,
        uint256 endTime
    ) internal {
        uint256 num = removeNum[token];
        if(removeShelves[token][num].startTime > block.timestamp || removeShelves[token][num].startTime == 0) {
            require(
                startTime >= block.timestamp && 
                startTime < endTime, 
                "time err"
            );
        } else if (removeShelves[token][num].endtime > block.timestamp || removeShelves[token][num].endtime == 0) {
            require(
                startTime == removeShelves[token][num].startTime && 
                endTime > block.timestamp, 
                "time err"
            );
        }  else {
            require(
                startTime >= block.timestamp &&
                startTime < endTime,
                "time err"
            );
        }
 
        require(coinData.getTokenIsCanRemove(token), "token err");
 
        uint256 rNum = ++removeNum[token];
        removeShelves[token][rNum].endtime = endTime;
        removeShelves[token][rNum].startTime = startTime;
 
        emit SetRemoveTime(token, rNum, startTime, endTime);
    }

    function _autoDecreasePosition(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        address _feeAccount,
        bool _isLong
    ) internal {
        uint256 endtime = getEndTime(_indexToken);

        (,,uint256 lastTime,) = coinData.getTokenInfo(_indexToken);
        require(
            lastTime < endtime &&
            block.timestamp > endtime &&
            endtime != 0, 
            "auto err"
        );
        
        uint256 amount = vault.autoDecreasePosition(_account, _collateralToken, _indexToken, _isLong);
        uint256 fee = amount * decreaseFeeRate / baseRate;
        uint256 _afterFee = amount - fee;
        
        TransferData memory tData = TransferData(
            _collateralToken,
            address(this),
            _account,
            _feeAccount,
            _afterFee,
            fee,
            0,
            0,
            0,
            0,
            0,
            0  
        );

        tData.beforeSliAmount = getAmount(_collateralToken, address(this));
        tData.beforeValue = getAmount(_collateralToken, _account);
        tData.beforeFeeAccountValue = getAmount(_collateralToken, _feeAccount);

        if(fee > 0) {
            IERC20(_collateralToken).safeTransfer(_feeAccount, fee);
        }

        if(_afterFee > 0) {
            IERC20(_collateralToken).safeTransfer(_account, _afterFee);
        }

        tData.afterSliAmount = getAmount(_collateralToken, address(this));
        tData.afterValue = getAmount(_collateralToken, tData.account);
        tData.afterFeeAccountValue = getAmount(_collateralToken, _feeAccount);

        emit TransferTo(tData);
    }

    function validate() internal view {
        require(
            orderBook.cancelAccount() == msg.sender ||
            orderBook.isPositionKeeper(msg.sender),
            "no permission"
        );
    }

    function getMemeIndexTokensLength() external view returns(uint256) {
        return memeIndexTokens.length();
    }

    function getMemeIndexToken(uint256 index) external view returns(address) {
        return memeIndexTokens.at(index);
    }


    // *************************************************************************
    mapping(address => mapping(uint256 => uint256)) setTokenThresholdValue;
    mapping(address => mapping(address => uint256)) singleTokenThresholdValue;

    event SetIndexTokenThresholdValue(
        address indexed indexToken, 
        address indexed targetIndexToken, 
        uint256 memberTokenTargetID, 
        uint256 thresholdValue
    );

    /// @notice Deprecated legacy setter: no-op (implementation removed).
    /// @dev Retained only to preserve the external ABI/selector and the onlyGov guard; it no longer
    ///      writes setTokenThresholdValue / singleTokenThresholdValue nor emits SetIndexTokenThresholdValue.
    ///      The mappings are kept solely for storage-layout compatibility (do NOT delete them).
    function setIndexTokenThresholdValue(address /*_indexToken*/, uint256 /*_thresholdValue*/) external onlyGov() {}

    /// @notice Deprecated legacy query: always returns 0 (implementation removed).
    /// @dev No execution path reads threshold values anymore (slip pricing lives in
    ///      SlippageControl). Retained for ABI compatibility; do not restore without
    ///      re-reviewing the setter semantics (setIndexTokenThresholdValue writes are unread).
    function getThresholdValue(address /*_indexToken*/) public view returns(uint256) {}

    // ************************************Channel mode***********************************************

    /// @notice Custom factor per channel target token; overrides the global `factor` when set
    mapping(address => uint256) public channelFactor;

    /// @notice Emitted when a channel pool's slippage factor is set
    /// @param indexToken The channel pool token address
    /// @param targetToken The underlying target token address
    /// @param factor The new slippage factor value
    event SetChannelFactor(address indexToken, address targetToken, uint256 factor);

    /// @notice Emitted when an expired channel pool position is automatically closed
    /// @param pool Channel pool address
    /// @param account Position owner
    /// @param collateralToken Collateral token
    /// @param indexToken Index token (channel-mapped)
    /// @param isLong True for long, false for short
    /// @param amount Account received amount
    event ChannelAutoDecreasePosition(
        address pool,
        address account,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 amount
    );

    /// @notice Emitted when a pool owner force-closes a profitable position
    /// @param pool Channel pool address
    /// @param account Position owner
    /// @param collateralToken Collateral token
    /// @param indexToken Index token (channel-mapped)
    /// @param isLong True for long, false for short
    /// @param amount Account received amount
    event ChannelPoolDecreasePosition(
        address pool,
        address account,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 amount
    );

    /**
     * @notice Set a custom slippage factor for a channel pool's target token
     * @dev Only callable by governance. The factor is stored against the resolved target token,
     *      not the channel token itself, so it works uniformly across all pools sharing the same target.
     * @param _indexToken A channel token belonging to the target pool
     * @param _factor The new factor value (must be > 0 and <= baseRate = 10000)
     */
    function setChannelFactor(address _indexToken, uint256 _factor) external onlyGov {
        address pool = memeFactory().channelMappedTokenPool(_indexToken);
        require(pool != address(0), "pool err");
        require(_factor > 0 && _factor <= baseRate, "factor_ err");

        address _targetToken = memeFactory().channelMappedTargetToken(pool);
        channelFactor[_targetToken] = _factor;
        
        emit SetChannelFactor(_indexToken, _targetToken, _factor);
    }

    /**
     * @notice Get the effective slippage factor for a token
     * @dev Lookup chain: _indexToken → pool → targetToken → channelFactor[targetToken].
     *      If _indexToken belongs to a channel pool and that pool's target token
     *      has a custom channelFactor set (> 0), use it; otherwise fall back to
     *      the global `factor`.
     * @param _indexToken The token address (channel token or regular token)
     * @return uint256 The effective factor value
     */
    function getFactor(address _indexToken) public view returns(uint256) { 
        address pool = memeFactory().channelMappedTokenPool(_indexToken);
        if (pool != address(0)) {
            address targetToken = memeFactory().channelMappedTargetToken(pool);
            uint256 f = channelFactor[targetToken];
            if (f > 0) return f;
        }
        return factor;
    }

    /**
     * @notice Batch auto-decrease positions for expired channel pools
     * @dev Iterates over autoData array. For each entry:
     *      1. Resolve pool via channelMappedTokenPool(indexToken)
     *      2. Skip if: pos.size == 0, pool invalid, endTime not yet passed, or endTime == 0
     *      3. Otherwise: vault.autoDecreasePosition → close the position
     *      4. If amount > 0: transfer collateral back to account
     *      5. Emit ChannelAutoDecreasePosition per processed entry
     * @param autoData Array of AutoStruct with account, collateralToken, indexToken, isLong
     */
    function batchChannelAutoDecreasePosition(
        AutoStruct[] memory autoData
    ) external {
        validate();
        uint256 len = autoData.length;
        require(len > 0, "length err");
        
        for(uint256 i = 0; i < len; i++) {
            AutoStruct memory aData = autoData[i];
            address _indexToken = aData.indexToken;
            address pool = memeFactory().channelMappedTokenPool(_indexToken);
            (, , uint256 endTime) = memeFactory().channelPoolCloseInfo(pool);
            bytes32 key = vault.getPositionKey(aData.account, aData.collateralToken, aData.indexToken, aData.isLong);
            Position memory pos = vault.getPositionFrom(key);
            if(pos.size == 0 || pool == address(0) || endTime > block.timestamp || endTime == 0) {
                continue;
            }
            uint256 amount = vault.autoDecreasePosition(aData.account, aData.collateralToken, aData.indexToken, aData.isLong);
            if(amount > 0) {
                IERC20(aData.collateralToken).safeTransfer(aData.account, amount);
            }

            emit ChannelAutoDecreasePosition(pool, aData.account, aData.collateralToken, aData.indexToken, aData.isLong, amount);
        }
    }

    /**
     * @notice Force-close a profitable position in the caller's own channel pool
     * @dev Conditions:
     *      1. Caller must own a channel pool (channelOwnerPool[msg.sender])
     *      2. Index token's resolved target must match pool's channelPoolToken
     *      3. Position must exist (pos.size > 0)
     *      4. Position must be in profit (hasProfit == true)
     *      Calls vault.autoDecreasePosition to close at current market price.
     *      This allows pool owners to forcibly close profitable positions, reducing risk exposure.
     * @param _account Position owner address
     * @param _collateralToken Collateral token (USDT)
     * @param _indexToken Index token (channel-mapped)
     * @param _isLong True for long, false for short
     */
    function channelPoolDecreasePosition(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        bool _isLong
    ) external {
        address pool = memeFactory().channelOwnerPool(msg.sender);
        if(pool == address(0)) revert("pool err");
        address channelPoolToken = memeFactory().channelPoolToken(pool);      
        address targetIndexToken = dataReader.getTargetIndexToken(_indexToken);
        if(channelPoolToken != targetIndexToken) revert("channelPoolToken err");

        bytes32 key = vault.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory pos = vault.getPositionFrom(key);
        if (pos.size == 0) revert("position err");
        (bool hasProfit,) = vault.getDelta(_indexToken, pos.size, pos.averagePrice, _isLong, pos.lastIncreasedTime);
        if(!hasProfit) revert("profit err");

        uint256 amount = vault.autoDecreasePosition(_account, _collateralToken, _indexToken, _isLong);
        if(amount > 0) {
            IERC20(_collateralToken).safeTransfer(_account, amount);  
        }

        emit ChannelPoolDecreasePosition(pool, _account, _collateralToken, _indexToken, _isLong, amount);
    }

    function memeFactory() public view returns(IMemeFactory) {
        return IMemeFactory(dataReader.memeFactory());
    }

    // ***********************************************************************************
    /// @notice SlippageControl contract for two-stage slip calculation (Layer 1 size impact + Layer 2 skew adjustment)
    ISlippageControl public slippageControl;

    /// @notice Set the SlippageControl contract address
    /// @dev Only callable by governance. Once set, getLongRate/getShortRate delegate to SlippageControl.
    /// @param _slippageControl SlippageControl proxy address (must be non-zero)
    function setSlippageControl(address _slippageControl) external onlyGov {
        if(_slippageControl == address(0)) revert();
        slippageControl = ISlippageControl(_slippageControl);
    }

    // ***********************************************************************************
    IPriceOracle public priceOracle;
    
    function setPriceOracle(address _priceOracle) external onlyGov {
        if(_priceOracle == address(0)) revert();
        priceOracle = IPriceOracle(_priceOracle);
    }

    function getMaxPrice(address _indexToken) external view returns(uint256) {
        return priceOracle.getMaxPrice(_indexToken);
    }

    function getMinPrice(address _indexToken) external view returns(uint256) {
        return priceOracle.getMinPrice(_indexToken);
    }

    function getDecreaseSlipPrice(address indexToken, uint256 size, bool isLong) external view returns(uint256, uint256, uint256) {
        return slippageControl.getDecreaseSlipPrice(indexToken, size, isLong);
    }

    /// @notice Mark-to-market decrease price that skips request-scoped execution caches.
    /// @dev Used for health checks of the remaining position after a partial decrease.
    function getLiquidationPrice(address indexToken, uint256 size, bool isLong) external view returns(uint256, uint256, uint256) {
        return slippageControl.getLiquidationPrice(indexToken, size, isLong);
    }

    // ***********************************************************************************

    /// @notice Per-token open leverage (in basis points), set via setTokenLeverageConfig
    mapping(address => uint256) public tokenOpenLeverage;

    /**
     * @notice Per-token leverage configuration
     * @param indexToken           The underlying index token address
     * @param openLeverage         The maximum leverage allowed when opening a position
     * @param liquidationLeverage  The leverage threshold that triggers liquidation
     */
    struct TokenLeverageConfig {
        address indexToken;
        uint256 openLeverage;
        uint256 liquidationLeverage;
    }

    /// @notice Event emitted when per-token open/liquidation leverage config is set (per token, using resolved index token)
    event SetTokenLeverageConfig(address indexed indexToken, uint256 openLeverage, uint256 liquidationLeverage);

    /**
     * @notice Batch set per-token open leverage and liquidation leverage
     * @dev    Only callable by governance. Each input indexToken is resolved to its underlying
     *         index token via dataReader before storing, and a per-token event is emitted.
     *         - openLeverage must satisfy: MIN_LEVERAGE <= openLeverage <= MAX_LEVERAGE
     *         - liquidationLeverage must be >= openLeverage
     *         - liquidationLeverage is stored in tokenMaxLeverage
     *         - openLeverage is stored in tokenOpenLeverage
     * @param eDtata Array of TokenLeverageConfig
     */
    function setTokenLeverageConfig(TokenLeverageConfig[] memory eDtata) external onlyGov {
        uint256 len = eDtata.length;
        if(len == 0) revert();
        for(uint256 i = 0; i < len; i++) {
            address indexToken = dataReader.getIndexToken(eDtata[i].indexToken);
            uint256 openLeverage = eDtata[i].openLeverage;
            uint256 liquidationLeverage = eDtata[i].liquidationLeverage;

            if(openLeverage < vault.MIN_LEVERAGE() || openLeverage > vault.MAX_LEVERAGE() || liquidationLeverage < openLeverage) revert("leverage err");
            tokenOpenLeverage[indexToken] = openLeverage;
            tokenMaxLeverage[indexToken] = liquidationLeverage;

            emit SetTokenLeverageConfig(indexToken, openLeverage, liquidationLeverage);
        }
    }

    /**
     * @notice Get the open leverage and liquidation leverage for a token
     * @dev    Resolves channel tokens to their underlying index token before reading.
     *         - liquidationLeverage comes from getTokenMaxLeverage (tokenMaxLeverage, with
     *           fallback to vault.maxLeverage() when unset).
     *         - openLeverage comes from tokenOpenLeverage; when unset it defaults to
     *           half of the liquidation leverage (liquidationLeverage / 2).
     * @param  _indexToken The token to query (auto-resolved to its underlying index token)
     * @return openLeverage         The effective open leverage (defaults to liquidationLeverage / 2 if unset)
     * @return liquidationLeverage  The effective liquidation leverage (falls back to vault.maxLeverage() if unset)
     */
    function getTokenLeverage(address _indexToken) public view returns(uint256, uint256) {
        address indexToken = dataReader.getIndexToken(_indexToken);
        uint256 openLeverage = tokenOpenLeverage[indexToken];
        uint256 liquidationLeverage = getTokenMaxLeverage(indexToken);
        if (openLeverage == 0) openLeverage = liquidationLeverage / 2;
        if(openLeverage < vault.MIN_LEVERAGE()) revert("leverage err");
        
        return (openLeverage, liquidationLeverage);
    }
}  
