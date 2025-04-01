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

contract Slippage is  Synchron, IEventStruct {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet indexTokens;  

    IVault public vault;
    IOrderBook public orderBook;
    ICoinData public coinData;

    address public USDT;
    address public gov;
    address public glpManager;

    uint256 public constant muti = 1e8;
    uint256 public constant baseRate = 10000;
    uint256 public factor;
    uint256 public threshold;
    uint256 public decreaseFeeRate;

    bool public initialized;

    mapping(address => uint256) public removeNum;
    mapping(address => mapping(uint256 => RemoveShelves)) removeShelves;
    mapping(address => mapping(address => uint256)) _glpTokenSupply;
 
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
    event TransferTo(TransferData tData);

    event SetRemoveTime(
        address token,
        uint256 rNum,
        uint256 startTime,
        uint256 endtime
    );

    modifier onlyGov() {
        require(msg.sender == gov, "Governable: forbidden");
        _;
    }

    modifier onlyGlpManager() {
        require(msg.sender == glpManager, "not glpManager");
        _;
    }

    function initialize(address usdt) external {
        require(!initialized, "has initialized");
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
        coinData = ICoinData(_coinData);
        glpManager = _glpManager;
        vault = IVault(_vault);
        orderBook = IOrderBook(_orderBook);
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
        }
    }

    function setDecreaseFeeRate(uint256 rate_) external onlyGov {
        require(rate_ <= baseRate, "rate_ err");
        decreaseFeeRate = rate_;
    }

    function autoDecreasePosition(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        bool _isLong, 
        address _feeAccount
    ) external {
        require(orderBook.cancelAccount() == msg.sender && _feeAccount != address(0), "auto err");
        uint256 endtime = getEndTime(_indexToken);

        require(
            coinData.lastTime(_indexToken) < endtime &&
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

    
    function addGlpAmount(address _indexToken, address _collateralToken, uint256 _amount) external onlyGlpManager {
        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2        
        if(coinData.getCoinType(_indexToken) == 1) {
            _glpTokenSupply[_collateralToken][_collateralToken] += _amount;
        } else {
            _glpTokenSupply[_indexToken][_collateralToken] += _amount;
        }
    }

    function subGlpAmount(address _indexToken, address _collateralToken, uint256 _amount) external onlyGlpManager {        
        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2
        if(coinData.getCoinType(_indexToken) == 1) {
            _glpTokenSupply[_collateralToken][_collateralToken] -= _amount;
        } else {
            _glpTokenSupply[_indexToken][_collateralToken] -= _amount;
        }
    }

    function glpTokenSupply(address _indexToken, address _collateralToken) external view returns(uint256) {
        // value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
        // value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
        // There are only two situations on this dex: 1 and 2
        // If other tokens are transferred, there will be zero returned        
        if(coinData.getCoinType(_indexToken) == 1) {
           return _glpTokenSupply[_collateralToken][_collateralToken];
        } else {
           return _glpTokenSupply[_indexToken][_collateralToken];
        }
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

    function getLongRate(address indexToken, uint256 size)  public view returns(uint256) {
        (uint256 globalLongSizes, uint256 netAmount) = getLongNetAmount(indexToken, size);
        if(netAmount == 0) {
            return 0;
        }

        uint256 _longSize = getPoolAmountSizeThreshold(indexToken, true);
        if(netAmount > _longSize) {
            uint256 value = (size + netAmount - _longSize);
            return value * factor * muti / (globalLongSizes * baseRate);
        }

        return 0;
    }

    function getShortRate(address indexToken, uint256 size)  public view returns(uint256) {
        (uint256 globalShortSizes, uint256 netAmount) = getShortNetAmount(indexToken, size);

        uint256 _shortSize = getPoolAmountSizeThreshold(indexToken, false);

        if(netAmount > _shortSize) {
            uint256 value = (size + netAmount - _shortSize);
            return value *  factor *  muti / (globalShortSizes * baseRate);
        }
        return 0;
    }

    function getPoolAmountSizeThreshold(address indexToken, bool isLong) public view returns(uint256) {
        uint256 size = getPoolAmountSize(indexToken, isLong);

        return size * threshold / baseRate;
    }

    function getPoolAmountSize(address indexToken, bool isLong) public view returns(uint256) {
        uint256 amount = vault.poolAmounts(indexToken, USDT);
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
        tokenDecimals = vault.tokenDecimals(_token);
        tokenWeights = vault.tokenWeights(_token);
        minProfitBasisPoints = vault.minProfitBasisPoints(_token);
        stableTokens = vault.stableTokens(_token);
        shortableTokens = vault.shortableTokens(_token);
        iswrapped = vault.iswrapped(_token);
        isFrom = vault.isFrom(_token);
    }

    function getValue(
        address user, 
        address indexToken, 
        uint256 poolTotalValue,
        uint256 _poolValue,
        uint256 min, 
        bool isLong
    ) external view returns(uint256, uint256) {
        (uint256 _min, uint256 num) = _getValue(indexToken, poolTotalValue, _poolValue, min, isLong);

        return IVaultUtils(vault.vaultUtils()).getValueFor(user, isLong, _min, num);
    }

    function getMinValueFor(
        uint256 min,
        uint256 num,
        uint256 maxSize, 
        uint256 globalSizes,
        bool isSet
    ) public pure returns(uint256, uint256) {
        if(isSet) {
            if(globalSizes >= maxSize) {
                return (0, 6);
            } else {
                uint256 _min = maxSize - globalSizes;
                if(min > _min) {
                    return (_min, 7);
                } 
            }
        }
        return (min, num); 
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

        int256 longNetValue = int256(globalLongSizes) - int256(globalShortSizes);
        int256 shortNetValue = int256(globalShortSizes) - int256(globalLongSizes);


        if(isLong) {
            return getMinValue(min, _poolValue, longNetValue);
        } else {
            return getMinValue(min, _poolValue, shortNetValue);
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

        (uint256 maxLeverage, , , bool isSet) = IPhase(vault.phase()).getTokenData(user);
        if(isSet) {
            require(_sizeDelta * baseRate / size <= maxLeverage, "big err");
        }        

        validateCreate(indexToken);

        return true;
    }

    function validateOrderValue(
        address user, 
        uint256 size,
        bool isLong
    ) external view returns(bool) {
        (uint256 _size, bool isSet) = getOrderValue(user, isLong);
        if(isSet) {
            require(size <= _size, "size err");
        }

        return true;
    }

    function getOrderValue(
        address user, 
        bool isLong
    ) public view returns(uint256, bool) {
        return  IVaultUtils(vault.vaultUtils()).getOrderValue(user, isLong);
    }

    function getMinOrderValueFor(
        uint256 maxSize, 
        uint256 globalSizes,
        bool isSet
    ) public pure returns(uint256, bool) {
        if(isSet) {
            if(globalSizes >= maxSize) {
                return (0, true);
            } else {
                uint256 _min = maxSize - globalSizes;
                return (_min, true);
            }
        }
        return (0, false);
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
        if(endtime != 0) {
            require(
                coinData.lastTime(token) > endtime ||
                block.timestamp < endtime, 
                "has rmove  shelves"
            );
        }
        return true;
    }

    function validateCreate(address token) public view returns(bool) {
        (uint256 startTime, uint256 endtime) = getRemoveTime(token);
        if(startTime != 0) {
            require(
                coinData.lastTime(token) > endtime ||
                block.timestamp < startTime, 
                "has rmove  shelves"
            );
        }

        return true;
    }

    function getEndTime(address token) public  view returns(uint256) {
        uint256 rNum = removeNum[token];
        return removeShelves[token][rNum].endtime;
    }

    function getRemoveTime(address token) public view returns(uint256, uint256) {
        uint256 rNum = removeNum[token];
        return (removeShelves[token][rNum].startTime, removeShelves[token][rNum].endtime);
    }

    function setRemoveTime(
        address token,
        uint256 startTime,
        uint256 endTime
    ) external onlyGov {
        require(
            startTime > block.timestamp && 
            startTime < endTime, 
            "time err"
        );
        (uint256 pid, uint256 num) = coinData.getPidNum();
        require(
            coinData.getPeriodTokenContains(pid, num, token) ||
            coinData.getCoinContains(pid, num, token), 
            "token err"
        );

        uint256 rNum = ++removeNum[token];
        removeShelves[token][rNum].endtime = endTime;
        removeShelves[token][rNum].startTime = startTime;

        emit SetRemoveTime(token, rNum, startTime, endTime);
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
        return removeShelves[token][rNum];
    }

    function getSizeData(address indexToken) public view returns(
        uint256 globalShortSizes,
        uint256 globalLongSizes,
        uint256 totalSize
    ) {
        (uint256 pid, uint256 num) = coinData.getPidNum();
        if(coinData.getCoinContains(pid, num, indexToken)) {
           return coinData.getSizeData(address(vault));
        } else {
            globalShortSizes = vault.globalShortSizes(indexToken);
            globalLongSizes = vault.globalLongSizes(indexToken);
            totalSize = globalShortSizes + globalLongSizes;
        }
    }

    function getIndexTokensLength() external view returns(uint256) {
        return indexTokens.length();
    }

    function getIndexToken(uint256 index) external view returns(address) {
        return indexTokens.at(index);
    }
}  

