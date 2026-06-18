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

contract Slippage is  Synchron, IEventStruct {
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
    
    function setTokenMaxLeverage(LeverageData[] memory eDtata) external onlyGov {
        uint256 len = eDtata.length;
        require(len > 0, "length err");
        for(uint256 i = 0; i < len; i++) {
            address indexToken = eDtata[i].indexToken;
            uint256 maxLeverage = eDtata[i].maxLeverage;

            require(maxLeverage >= vault.MIN_LEVERAGE() && maxLeverage <= vault.MAX_LEVERAGE(), "maxLeverage err");
            tokenMaxLeverage[indexToken] = maxLeverage;
        }

        emit SetTokenMaxLeverage(eDtata);
    }
    
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
                    price = 1;    
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
        (uint256 globalLongSizes, uint256 netAmount) = getLongNetAmount(indexToken, size);
        if(netAmount == 0) {
            return 0;
        }

        uint256 _longSize = getPoolAmountSizeThreshold(indexToken, true);
        if(netAmount > _longSize) {
            uint256 value = (size + netAmount - _longSize);
            return value * getFactor(indexToken) * muti / (globalLongSizes * baseRate);
        }

        return 0;
    }

    function getShortRate(address indexToken, uint256 size)  public view returns(uint256) {
        (uint256 globalShortSizes, uint256 netAmount) = getShortNetAmount(indexToken, size);

        uint256 _shortSize = getPoolAmountSizeThreshold(indexToken, false);

        if(netAmount > _shortSize) {
            uint256 value = (size + netAmount - _shortSize);
            return value * getFactor(indexToken) *  muti / (globalShortSizes * baseRate);
        }
        return 0;
    }

    function getPoolAmountSizeThreshold(address indexToken, bool isLong) public view returns(uint256) {
        uint256 size = getPoolAmountSize(indexToken, isLong);

        return size * getThresholdValue(indexToken) / baseRate;
    }

    function getPoolAmountSize(address indexToken, bool isLong) public view returns(uint256) {
        uint256 amount = dataReader.getUsePoolAmounts(indexToken, USDT);
        uint256 deci = 10 ** IERC20Metadata(USDT).decimals();
        uint256 price;
        if(isLong) {
            price = vault.getMaxPrice(USDT);
        } else {
            price = vault.getMinPrice(USDT); 
        }

        return amount * price / deci;
    }

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
        uint256 maxLeverage = getTokenMaxLeverage(indexToken);
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
        int256 realisedPnl = getRealisedPnl(_account,_collateralToken, _indexToken, _sizeDelta, _isLong);

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

    function getRealisedPnl(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) public view returns (int256) {
        IVault _vault = vault;
        (uint256 size, /*uint256 collateral*/, uint256 averagePrice, , , , , uint256 lastIncreasedTime) = _vault.getPosition(_account, _collateralToken, _indexToken, _isLong);

        (bool hasProfit, uint256 delta) = _vault.getDelta(_indexToken, size, averagePrice, _isLong, lastIncreasedTime);
        // get the proportional change in pnl
        uint256 adjustedDelta = _sizeDelta * delta / size;
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
    
    /**
     * @notice Set a custom threshold value for an index token
     * @dev Only callable by governance. Threshold is stored per pool target token:
     *      _belongTo == 2 (member token) → setTokenThresholdValue[pair][memberId]
     *      _belongTo == 1 (single token) → singleTokenThresholdValue[pair][token]
     *      Other classifications revert.
     * @param _indexToken The token address (will be resolved via dataReader)
     * @param _thresholdValue The threshold in basis points (0 < value <= baseRate = 10000)
     */
    function setIndexTokenThresholdValue(address _indexToken, uint256 _thresholdValue) external onlyGov() {
        if(_thresholdValue > baseRate || _thresholdValue == 0) revert("_thresholdValue err");

        (address _poolTargetToken, uint256 _memberTokenTargetID,,uint8 _belongTo) = dataReader.getTokenInfo(_indexToken);
        if(_belongTo == 2) {
            setTokenThresholdValue[_poolTargetToken][_memberTokenTargetID] = _thresholdValue;
        } else if(_belongTo == 1) {
            singleTokenThresholdValue[_poolTargetToken][_indexToken] = _thresholdValue;
        } else {
            revert("_belongTo err");
        }

        emit SetIndexTokenThresholdValue(_indexToken, _poolTargetToken, _memberTokenTargetID, _thresholdValue);
    }

    /**
     * @notice Get the effective threshold value for a token
     * @dev Resolution order:
     *      1. If token is a channel mapped token (indexToken != _indexToken):
     *         a. Check custom threshold via dataReader → return if set
     *         b. Fallback to _getThresholdValue with the same _belongTo
     *      2. Otherwise, resolve via coinData.getTokenInfo and call _getThresholdValue
     * @param _indexToken The token address (channel token or regular token)
     * @return uint256 The resolved threshold value in basis points
     */
    function getThresholdValue(address _indexToken) public view returns(uint256) {
        address indexToken = dataReader.getIndexToken(_indexToken);

        (address _poolTargetToken, uint256 _memberTokenTargetID,,uint8 _belongTo) = coinData.getTokenInfo(indexToken);        
        if(indexToken != _indexToken) {
            address _poolToken = dataReader.getTargetIndexToken(_indexToken);
            if(_belongTo == 2) {
                uint256 _thresholdValue = setTokenThresholdValue[_poolToken][_memberTokenTargetID];
                return _thresholdValue == 0 ? _getThresholdValue(indexToken, _poolTargetToken, _memberTokenTargetID, _belongTo) : _thresholdValue;
            } else if(_belongTo == 1) {
                uint256 _thresholdValue = singleTokenThresholdValue[_poolToken][_indexToken];
                return _thresholdValue == 0 ? _getThresholdValue(indexToken, _poolTargetToken, _memberTokenTargetID, _belongTo) : _thresholdValue;
            }
        }

        return _getThresholdValue(indexToken, _poolTargetToken, _memberTokenTargetID, _belongTo);
    }

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
     * @notice Resolve the threshold value for a given token based on its classification
     * @dev Fallback chain (category → check custom → default):
     *      1. _belongTo == 2 (member token): setTokenThresholdValue[pool][memberID] → threshold
     *      2. _belongTo == 1 (single token): singleTokenThresholdValue[pool][token] → threshold
     *      3. _belongTo == 0 (legacy token): always returns global threshold
     *      4. Other: returns 0 (unregistered token)
     * @param _indexToken The token to query (resolved beforehand)
     * @param _poolTargetToken The pool's target token address
     * @param _memberTokenTargetID The member token target ID (for _belongTo == 2)
     * @param _belongTo Token classification: 0=legacy, 1=single, 2=member
     * @return uint256 The resolved threshold value in basis points
     */
    function _getThresholdValue(address _indexToken, address _poolTargetToken, uint256 _memberTokenTargetID, uint8 _belongTo) internal view returns(uint256) {
        if(_belongTo == 2) {
            uint256 _setTokenThresholdValue = setTokenThresholdValue[_poolTargetToken][_memberTokenTargetID];
            return _setTokenThresholdValue == 0 ? threshold : _setTokenThresholdValue;
        } else if(_belongTo == 1) {
            uint256 _singleTokenThresholdValue = singleTokenThresholdValue[_poolTargetToken][_indexToken];
            return _singleTokenThresholdValue == 0 ? threshold : _singleTokenThresholdValue;
        } else if(_belongTo == 0) {
            return threshold;
        } else {
            return 0;
        }
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
}  
