// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;


import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../core/interfaces/IERC20Metadata.sol";
import "../core/interfaces/IVault.sol";
import "../fund-pool/v2/interfaces/IPoolDataV2.sol";
import "../fund-pool/v2/interfaces/IStruct.sol";
import "./interfaces/ISlippage.sol";
import "./interfaces/IPhaseStruct.sol";
import "./interfaces/ICoinData.sol";
import "../referrals/interfaces/IFeeBonus.sol";
import "../meme/interfaces/IMemeData.sol";
import "../upgradeability/Synchron.sol";

contract Phase is Synchron, IStruct, IPhaseStruct {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // PositionRouter
    bytes32 public constant zeroCode = 0x0000000000000000000000000000000000000000000000000000000000000000;
    // 1 OrderBook
    bytes32 public constant oneCode = 0x0000000000000000000000000000000000000000000000000000000000000001; 
    // 2 PositionRouter
    bytes32 public constant twoCode = 0x0000000000000000000000000000000000000000000000000000000000000002; 
    // 3 Vault liquidatePosition 
    bytes32 public constant threeCode = 0x0000000000000000000000000000000000000000000000000000000000000003;  
    // 4  Vault liquidatePosition _decreasePosition
    bytes32 public constant fourCode = 0x0000000000000000000000000000000000000000000000000000000000000004;
    // 5. Phase CollectFees
    bytes32 public constant fiveCode = 0x0000000000000000000000000000000000000000000000000000000000000005;
    // 6. Slippage
    bytes32 public constant sixCode = 0x0000000000000000000000000000000000000000000000000000000000000006;
    
    uint256 public constant DECI = 1e30;
    uint256 public constant muti = 1e12;
    uint256 public constant baseRate = 10000;
    uint256 public constant MUTI = 1e18;

    IVault public vault;
    IERC20 public GLP;
    IPoolDataV2 public poolDataV2;
    ICoinData public coinData;
    IMemeData public memeData;

    address public gov;
    address public USDT;
    address public feeBonus;

    uint256 public totalRate;
    uint256 public sideRate;
    uint256 public defaultPoolRate;
    uint256 public exponent;
    uint256 public feeTime;
    uint256 public totalPhasefee;
    uint256 public haveTotalPhasefee;

    bool public initialized;

    mapping(address => uint256) public lastPrice;
    mapping(address => bool) public handler;
    mapping(address => bool) public operator;
    mapping(uint8 => bytes32) public typeCode;
    mapping(bytes32 => uint8) public codeType;

    mapping(address => mapping(address => mapping(address => UserData))) userData;  
    mapping(address => mapping(address => EnumerableSet.AddressSet)) longUsers;
    mapping(address => mapping(address => EnumerableSet.AddressSet)) shortUsers;

    event SetHandler(address account, bool isAdd);
    event SetOperator(address account, bool isAdd);

    event TransferTo(
        address token, 
        address from, 
        address to, 
        uint256 amount, 
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );

    event CollectUserFee(
        address collateralToken, 
        address indexToken, 
        address user, 
        uint256 time,
        uint256 totalSize,
        uint256 size,
        uint256 rate,
        bool isLong,
        uint256 fee
    );

    event SetKey(
        address user, 
        address collateralToken, 
        address indexToken, 
        bytes32 key, 
        bool isLong
    );

    event CollectFees(
        address pool, 
        address collateralToken, 
        address indexToken, 
        uint256 pid
    );

    constructor() {
        initialized = true;
    }

    modifier onlyGov() {
        require(gov == msg.sender, "gov err");
        _;
    }

    function initialize(address usdt, address glp) external {
        require(!initialized, "init err");
        require(usdt != address(0) && glp != address(0), "addr err");

        initialized = true;

        USDT = usdt;
        GLP = IERC20(glp);
        gov = msg.sender;

        totalRate = 100000;
        sideRate = 20000;
        defaultPoolRate = 6000;
        exponent = 1e10;
        feeTime = 60 minutes;

        _setCode();
    }

    function setGov(address account) external onlyGov {
        _validate(account);
        gov = account;
    }

    function _setCode() internal {
        typeCode[0] = zeroCode;
        typeCode[1] = oneCode;
        typeCode[2] = twoCode;
        typeCode[3] = threeCode;
        typeCode[4] = fourCode;
        typeCode[5] = fiveCode;
        typeCode[6] = sixCode;
        
        codeType[zeroCode] = 0;
        codeType[oneCode] = 1;
        codeType[twoCode] = 2;
        codeType[threeCode] = 3;
        codeType[fourCode] = 4;
        codeType[fiveCode] = 5;
        codeType[sixCode] = 6;
    }

    function setData(
        address _coinData,
        address _poolDataV2,
        address _vault,
        address _feeBonus,
        address _memeData
    ) external onlyGov {
        coinData = ICoinData(_coinData);
        poolDataV2 = IPoolDataV2(_poolDataV2);
        vault = IVault(_vault);
        feeBonus = _feeBonus;
        memeData = IMemeData(_memeData);
    }

    function setHandler(address account, bool isAdd) external onlyGov {
        handler[account] = isAdd;

        emit SetHandler(account, isAdd);
    }

    function setOperator(address account, bool isAdd) external onlyGov {
        operator[account] = isAdd;

        emit SetOperator(account, isAdd);
    }

    function transferTo(address token, address account, uint256 amount) external {
        _validate(account);
        require(msg.sender == gov || handler[msg.sender], "no permission");

        _transferTo(token, account, amount);
    } 

    function setTotalRate(uint256 totalRate_) external onlyGov {
        totalRate = totalRate_;
    }

    function setSideRate(uint256 sideRate_) external onlyGov {
        sideRate = sideRate_;
    }

    function collectFees(
        address pool, 
        address collateralToken, 
        address indexToken, 
        uint256 pid, 
        address[] memory lUsers,
        address[] memory sUsers,
        uint256 longRate,
        uint256 shortRate
    ) external {
        require(msg.sender == gov || operator[msg.sender], "no permission");
        ISlippage(vault.slippage()).validateRemoveTime(indexToken);

        if(!memeData.isAddMeme(indexToken)) {
            uint256 currID = poolDataV2.currPeriodID(pool);
            require(currID > 0 && currID == pid, "pid err");
        } else {
            require(0 == pid, "meme pid err");
        }

        require((lUsers.length > 0 && longRate > 0) || (sUsers.length > 0 && shortRate > 0), "collect err");
        for(uint256 i = 0; i < lUsers.length; i++) {
            _collectLongFees(lUsers[i], collateralToken, indexToken, longRate);
        }

        for(uint256 i = 0; i < sUsers.length; i++) {
            _collectShortFees(sUsers[i], collateralToken, indexToken, shortRate);
        }

        uint256 fee = totalPhasefee;
        if(fee > 0) {
            totalPhasefee = 0;
            haveTotalPhasefee += fee;

            address  account = memeData.isAddMeme(indexToken) ?  address(vault) : feeBonus;
            require(account != address(0), "account err");
            _transferTo(USDT, account, fee);

            if(account == feeBonus) {
                IFeeBonus(feeBonus).addFeeAmount(indexToken, 2, fee);
            } else {
                vault.directPoolDeposit(indexToken, USDT, fee);
            }

        }

        emit CollectFees(pool, collateralToken, indexToken, pid);
    } 

    function setKey(
        address user, 
        address collateralToken, 
        address indexToken, 
        bytes32 key, 
        bool isLong
    ) external {
        require(msg.sender == address(vault), "vault err");
        ISlippage(vault.slippage()).addTokens(indexToken);

        if(isLong) {
            if(!userData[user][collateralToken][indexToken].isLongSet) {
                longUsers[collateralToken][indexToken].add(user); 
                userData[user][collateralToken][indexToken].isLongSet = true;
                userData[user][collateralToken][indexToken].longkey = key;
                
                emit SetKey(user, collateralToken, indexToken, key, isLong);
            }
        } else {
            if(!userData[user][collateralToken][indexToken].isShortSet) {
                shortUsers[collateralToken][indexToken].add(user);
                userData[user][collateralToken][indexToken].isShortSet = true;
                userData[user][collateralToken][indexToken].shortKey = key;

                emit SetKey(user, collateralToken, indexToken, key, isLong);
            }
        }
    }

    function _collectLongFees(
        address user,
        address collateralToken, 
        address indexToken,
        uint256 longRate
    ) internal {
        if(userData[user][collateralToken][indexToken].longLastTime + feeTime <= block.timestamp) {
            uint256 totalSize = getSize(user, collateralToken, indexToken, true);
            uint256 size = totalSize * longRate / muti;

            size = getCollateralSize(user, collateralToken, indexToken, size, true);
            if(size > 0) {
                userData[user][collateralToken][indexToken].longLastTime = block.timestamp;

                uint256 fee = vault.decreasePosition(fiveCode, user, collateralToken, indexToken, size, 0, true, address(this));
                totalPhasefee += fee;

                emit CollectUserFee(
                    collateralToken,
                    indexToken,
                    user, 
                    userData[user][collateralToken][indexToken].longLastTime,
                    totalSize,
                    size,
                    longRate,
                    true,
                    fee
                );
            }
        }
    }

    function _collectShortFees(
        address user,
        address collateralToken, 
        address indexToken,
        uint256 shortRate
    ) internal {
        if(userData[user][collateralToken][indexToken].shortLastTime + feeTime <= block.timestamp) {
            uint256 totalSize = getSize(user, collateralToken, indexToken, false);
            uint256 size = totalSize * shortRate / muti;
            size = getCollateralSize(user, collateralToken, indexToken, size, false);
            if(size > 0) {
                userData[user][collateralToken][indexToken].shortLastTime = block.timestamp;
                uint256 fee = vault.decreasePosition(fiveCode, user, collateralToken, indexToken, size, 0, false, address(this));
                totalPhasefee += fee;

                emit CollectUserFee(
                    collateralToken,
                    indexToken,
                    user, 
                    userData[user][collateralToken][indexToken].shortLastTime,
                    totalSize,
                    size,
                    shortRate,
                    false,
                    fee
                );
            }
        }
    }

    function getCollateralSize(
        address user,
        address collateralToken, 
        address indexToken,
        uint256 size,
        bool isLong
    ) public view returns(uint256) {
        (, uint256 collateral,,,,,,) =
        vault.getPosition(user, collateralToken, indexToken, isLong);
        if(size > collateral) {
            size = collateral;
        }
        return size;
    }

       
    function getSize(
        address user,
        address collateralToken, 
        address indexToken,
        bool isLong
    ) public view returns(uint256) {
        (uint256 size, , , , , , , ) = vault.getPosition(user, collateralToken, indexToken, isLong);

        return size;
    }

    function getUserFeeRate(address pool, address indexToken) public view returns(uint256, uint256) {
        (uint256 poolValue, bool isFundraise, bool isClaim) = coinData.getPoolValue(indexToken);

        uint256 uDeci =  10 ** IERC20Metadata(USDT).decimals();
        int256 initValue = int256(poolValue);
        int256 ratePoolValue = int256(poolValue * getPoolRate(pool) * getCurrRate(indexToken) / baseRate / baseRate);
        uint256 pAmount = vault.poolAmounts(indexToken, USDT);
        int256 pValue =  int256(pAmount * getTokenPrice(USDT) / uDeci); 

        int256 loss;  
        if(pValue < initValue) {
            loss = initValue - pValue;
        }

        if(memeData.isAddMeme(indexToken)) {
            return getFeeRate(indexToken, ratePoolValue, loss);
        } else {
            if(isFundraise && !isClaim) {
                return getFeeRate(indexToken, ratePoolValue, loss);
            }
            return (0, 0);
        }
    }

    function getFeeRate(
        address indexToken, 
        int256 ratePoolValue,
        int256 loss
    ) public view returns(uint256, uint256) {
        (int256 longValue, int256 shortValue) = getLongShortValue(indexToken);

        int256 totalSizeValue = longValue + shortValue;
        if(totalSizeValue > 0 && totalSizeValue + loss >= ratePoolValue) {
            if(longValue > 0 && shortValue > 0) {
                return (getLongFeeRate(indexToken, uint256(longValue)), getShortFeeRate(indexToken, uint256 (shortValue)));
            }

            if(longValue > 0) {
                return (getLongFeeRate(indexToken, uint256(longValue)), 0);
            }

            if(shortValue > 0) {
                return (0, getShortFeeRate(indexToken, uint256 (shortValue)));              
            }
        } else if((totalSizeValue < 0 && totalSizeValue + loss >= ratePoolValue)) {
            if(longValue > 0) {
                return (getLongFeeRate(indexToken, uint256(longValue)), 0);
            }

            if(shortValue > 0) {
                return (0, getShortFeeRate(indexToken, uint256(shortValue)));              
            }
        }
        return(0,0);
    }

    function getLongFeeRate(address indexToken, uint256 longValue) public view returns(uint256) {
        uint256 indexTokenValue = getIndextokenValue(indexToken);

        return longValue * exponent / indexTokenValue; 
    }

    function getShortFeeRate(address indexToken, uint256 shortValue) public view returns(uint256) {
        uint256 indexTokenValue = getIndextokenValue(indexToken);

        return shortValue * exponent / indexTokenValue; 
    }

    function getIndextokenValue(address indexToken) public view returns(uint256) {
        uint256 rate = getCurrRate(indexToken);
        uint256 totalAmount = vault.poolAmounts(indexToken, USDT) * rate;
        uint256 price = vault.getMaxPrice(USDT);
        uint256 deciCounter = 10 ** IERC20Metadata(USDT).decimals();

        return totalAmount * price / deciCounter / baseRate;
    }

    function getPoolRate(address pool) public view returns(uint256) {
        if(pool == address(0)) {
            return 0;
        }
        return defaultPoolRate;
    }

    function _getLongShortValue(address indexToken) internal view returns(int256 longValue, int256 shortValue) {
        int256 globalShortSizes = int256(vault.globalShortSizes(indexToken));
        int256 globalLongSizes = int256(vault.globalLongSizes(indexToken));
        if(globalShortSizes == 0 && globalLongSizes == 0) {
            return(0, 0);
        }

        int256 globalShortAveragePrices = int256(vault.globalShortAveragePrices(indexToken));
        int256 globalLongAveragePrices = int256(vault.globalLongAveragePrices(indexToken));

        {
            if(globalLongAveragePrices == 0 || globalShortAveragePrices == 0) {
                if(globalLongAveragePrices == 0) {
                    longValue = 0;
                } else {
                    int256 minPrice = int256(vault.getMinPrice(indexToken));
                    longValue = globalLongSizes  * (minPrice - globalLongAveragePrices) / globalLongAveragePrices;
                }

                if(globalShortAveragePrices == 0) {
                    shortValue = 0;
                } else {
                    int256 maxPrice = int256(vault.getMaxPrice(indexToken));
                    shortValue = -globalShortSizes * (maxPrice - globalShortAveragePrices) / globalShortAveragePrices;
                }
            } else {
                (int256 maxPrice, int256 minPrice) = getPrice(indexToken);
                longValue = globalLongSizes  * (minPrice - globalLongAveragePrices) / globalLongAveragePrices;
                shortValue = -globalShortSizes * (maxPrice - globalShortAveragePrices) / globalShortAveragePrices;
            }

        } 
    }

    function getLongShortValue(address indexToken) public view returns(int256 longValue, int256 shortValue) {
        (address _poolTargetToken, uint256 _memberTokenTargetID,,uint8 _belongTo) = coinData.getTokenInfo(indexToken);

        if(_belongTo == 1) {
            return _getLongShortValue(indexToken);
        } else if(_belongTo == 2) {
            uint256 _num = coinData.getPoolTargetTokenInfoSetNum(_poolTargetToken);
            uint256 _len = coinData.getMemberTokensLength(_poolTargetToken, _num, _memberTokenTargetID);
            for(uint256 i = 0; i < _len; i++) {
                address _token = coinData.getMemberToken(_poolTargetToken, _num, _memberTokenTargetID, i);
                (int256 _longValue, int256 _shortValue) = _getLongShortValue(_token);

                longValue += _longValue;
                shortValue += _shortValue;
            }
        } else {
            return (0, 0);
        }
    }

    function getPrice(address token) public view returns(int256 maxPrice, int256 minPrice) {
        maxPrice = int256(vault.getMaxPrice(token));
        minPrice = int256(vault.getMinPrice(token));
    }

    function getUserData(
        address user, 
        address collateralToken, 
        address indexToken
    ) external view returns(UserData memory) {
        return userData[user][collateralToken][indexToken];
    }

    function getUsersNum(
        address collateralToken, 
        address indexToken, 
        uint8 userType
    ) external view returns(uint256) {
        if(userType == 1) {
            return longUsers[collateralToken][indexToken].length();
        }

        if(userType == 2) {
            return shortUsers[collateralToken][indexToken].length();
        }
        return 0;
    }

    function getUser(
        address collateralToken, 
        address indexToken, 
        uint8 userType,
        uint256 index
    ) external view returns(address) {
        if(userType == 1) {
            return longUsers[collateralToken][indexToken].at(index);
        }

        if(userType == 2) {
            return shortUsers[collateralToken][indexToken].at(index);
        }
        return address(0);
    }

    function getNextGlobalShortAveragePrice(
        address _indexToken, 
        uint256 _nextPrice, 
        uint256 _sizeDelta
    ) external view returns (uint256) {
        uint256 size = vault.globalShortSizes(_indexToken);
        uint256 averagePrice = vault.globalShortAveragePrices(_indexToken);
        uint256 priceDelta = averagePrice > _nextPrice ? averagePrice - _nextPrice : _nextPrice - averagePrice;
        uint256 delta = size * priceDelta / averagePrice;
        bool hasProfit = averagePrice > _nextPrice;
        uint256 nextSize = size + _sizeDelta;
        uint256 divisor = hasProfit ? nextSize - delta : nextSize + delta;

        return _nextPrice * nextSize / divisor;
    }

    function getNextGlobalLongAveragePrice(
        address _indexToken, 
        uint256 _nextPrice, 
        uint256 _sizeDelta
    ) external view returns (uint256) {
        uint256 size = vault.globalLongSizes(_indexToken);
        uint256 averagePrice = vault.globalLongAveragePrices(_indexToken);
        if(averagePrice == 0) {
            averagePrice = vault.getMaxPrice(_indexToken);
        }
        uint256 priceDelta = averagePrice > _nextPrice ? averagePrice - _nextPrice : _nextPrice - averagePrice;
        uint256 delta = size * priceDelta / averagePrice;
        bool hasProfit = averagePrice < _nextPrice;

        uint256 nextSize = size + _sizeDelta;
        uint256 divisor = hasProfit ? nextSize + delta : nextSize - delta;

        return _nextPrice * nextSize / divisor;
    }

    function usdToToken(address _token, uint256 _usdAmount, uint256 _price) external view returns (uint256) {
        if (_usdAmount == 0) { return 0; }
        uint256 decimals = vault.tokenDecimals(_token);
        return _usdAmount * (10 ** decimals) / _price;
    }

    function tokenToUsdMin(address _token, uint256 _tokenAmount) external  view returns (uint256) {
        if (_tokenAmount == 0) { return 0; }
        uint256 price = vault.getMinPrice(_token);
        uint256 decimals = vault.tokenDecimals(_token);
        return _tokenAmount * price / (10 ** decimals);
    }

    function getNextAveragePrice(
        address _indexToken, 
        uint256 _size, 
        uint256 _averagePrice, 
        bool _isLong, 
        uint256 _nextPrice, 
        uint256 _sizeDelta, 
        uint256 _lastIncreasedTime
    ) external view returns (uint256) {
        (bool hasProfit, uint256 delta) = getDelta(_indexToken, _size, _averagePrice, _isLong, _lastIncreasedTime);
        uint256 nextSize = _size + _sizeDelta;
        uint256 divisor;
        if (_isLong) {
            divisor = hasProfit ? nextSize + delta : nextSize - delta;
        } else {
            divisor = hasProfit ? nextSize - delta : nextSize + delta;
        }
        return _nextPrice * nextSize / divisor;
    }

    function getGlobalShortDelta(address _token) external view returns (bool, uint256) {
        uint256 size = vault.globalShortSizes(_token);
        if (size == 0) { return (false, 0); }

        uint256 nextPrice = vault.getMaxPrice(_token);
        uint256 averagePrice = vault.globalShortAveragePrices(_token);
        uint256 priceDelta = averagePrice > nextPrice ? averagePrice - nextPrice : nextPrice - averagePrice;
        uint256 delta = size * priceDelta / averagePrice;
        bool hasProfit = averagePrice > nextPrice;

        return (hasProfit, delta);
    }

    function getDeltaFor(
        address _indexToken, 
        uint256 _size, 
        uint256 _averagePrice, 
        bool _isLong, 
        uint256 _lastIncreasedTime,
        uint256 price
    ) external view returns (bool, uint256) {
        return _getDelta(_indexToken, _size, _averagePrice, _isLong, _lastIncreasedTime, price);
    }

    function getDelta(
        address _indexToken, 
        uint256 _size, 
        uint256 _averagePrice, 
        bool _isLong, 
        uint256 _lastIncreasedTime
    ) public view returns (bool, uint256) {
        uint256 price = _isLong ? vault.getMinPrice(_indexToken) : vault.getMaxPrice(_indexToken);

        return _getDelta(_indexToken, _size, _averagePrice, _isLong, _lastIncreasedTime, price);
    }

    function _getDelta(
        address _indexToken, 
        uint256 _size, 
        uint256 _averagePrice, 
        bool _isLong, 
        uint256 _lastIncreasedTime,
        uint256 price
    ) internal view returns (bool, uint256) {

        uint256 priceDelta = _averagePrice > price ? _averagePrice - price : price - _averagePrice;
        uint256 delta = _size * priceDelta / _averagePrice;

        bool hasProfit;
        if (_isLong) {
            hasProfit = price > _averagePrice;
        } else {
            hasProfit = _averagePrice > price;
        }

        // if the minProfitTime has passed then there will be no min profit threshold
        // the min profit threshold helps to prevent front-running issues
        uint256 minBps = block.timestamp > _lastIncreasedTime + vault.minProfitTime() ? 0 : vault.minProfitBasisPoints(_indexToken);
        if (hasProfit && delta * 10000 <= _size * minBps) {
            delta = 0;
        }

        return (hasProfit, delta);
    }

    function validateTokens(address _collateralToken, address _indexToken) external view {
        vault.validate(vault.whitelistedTokens(_collateralToken), 43);
        vault.validate(vault.whitelistedTokens(_indexToken), 45);
    }

    // ******************************************************************************************
    function validateSizeDelta(
        address user,
        address indexToken, 
        uint256 sizeDelta, 
        bool isLong
    ) external view returns(bool) {
        if(memeData.isAddMeme(indexToken)) {
            require(!memeData.isPoolTokenClose(indexToken), "meme err");
        }

        (uint256 min,) = getValue(user, indexToken, isLong);
        require(min >= sizeDelta,  "size err");

        return true;
    }

    function getValue(address user, address indexToken, bool isLong) public view returns(uint256, uint256) {
        ISlippage slippage =  ISlippage(vault.slippage());
        (uint256 min, uint256 num) = slippage.getPhaseMinValue(indexToken);
        if(num == 1) {
            return  (min, num);
        }

        (uint256 poolValue,,) = coinData.getPoolValue(indexToken);
        uint256 poolTotalValue = poolValue * totalRate * getCurrRate(indexToken) / baseRate / baseRate;
        uint256 _poolValue = poolValue * sideRate * getCurrRate(indexToken) / baseRate / baseRate;

        return slippage.getValue(user, indexToken, poolTotalValue, _poolValue, min, isLong);
    }

    function getTokenPrice(address token) public view returns(uint256) {
        uint256 maxPrice = vault.getMaxPrice(token);
        uint256 minPrice = vault.getMinPrice(token);

        uint256 price = (maxPrice + minPrice) / 2;
        require(
            maxPrice > 0 && 
            minPrice > 0 &&
            price + 1 >= minPrice, 
            "price err"
        );

        return price;
    }

    function getOutAmount(address _indexToken, address tokenOut, uint256 glpAmount) public view returns(uint256) {
        uint256 total;

        address _poolTargetToken = _indexToken == USDT ? USDT : coinData.getTokenToPoolTargetToken(_indexToken);
        {
            if(tokenOut != USDT || coinData.getPoolTargetTokenInfoSetNum(_poolTargetToken) == 0) {
                return 0;
            }

            ISlippage sli = ISlippage(vault.slippage());
            total =  sli.glpTokenSupply(_poolTargetToken, tokenOut);
            
            if(glpAmount > total) {
                glpAmount = total;
            }

            if(glpAmount == 0) {
                return 0;
            }
        }

        int256 totalValue;
        {
            uint256 _lenSingleToken = coinData.getCurrSingleTokensLength(_poolTargetToken);
            for(uint256 i = 0; i < _lenSingleToken; i++) {
                (address _singleToken,) = coinData.getCurrSingleToken(_poolTargetToken, i);
                (int256 _longValue, int256 _shortValue) = _getLongShortValue(_singleToken);
                totalValue += (_longValue + _shortValue);   
            }

            uint256 _lenMemberTokenTargetID = coinData.getCurrMemberTokenTargetIDLength(_poolTargetToken);
            for(uint256 i = 0; i < _lenMemberTokenTargetID; i++) {
                (uint256 _memberTokenTargetID,) = coinData.getCurrMemberTokenTargetID(_poolTargetToken, i);
                uint256 _num = coinData.getPoolTargetTokenInfoSetNum(_poolTargetToken);

                uint256 _lenMemberTokens = coinData.getMemberTokensLength(_poolTargetToken, _num, _memberTokenTargetID);
                for(uint256 j = 0; j < _lenMemberTokens; j++) {
                    address _memberToken = coinData.getMemberToken(_poolTargetToken, _num, _memberTokenTargetID, j);
                    (int256 _longValue, int256 _shortValue) = _getLongShortValue(_memberToken);
                    totalValue += (_longValue + _shortValue);   
                }
            }
        }


        uint256 poolAmount = vault.poolAmounts(_poolTargetToken, tokenOut);
        {
            if(totalValue > 0) {
                uint256 deci = 10 ** IERC20Metadata(tokenOut).decimals();
                uint256 _total = uint256(totalValue);
                _total = _total * deci / getTokenPrice(tokenOut);
                if(_total >= poolAmount) {
                    return 0;
                }
                poolAmount -= _total;
            } 
        }
        
        return poolAmount * glpAmount / total;        
    }

    function calculatePrice(address _indexToken, address _token) external {
        require(handler[msg.sender], "no permission");
        uint256 total =  ISlippage(vault.slippage()).glpTokenSupply(_indexToken, _token);
        if(total == 0) {
            return;
        }

        uint256 amount = getOutAmount(_indexToken, _token, total);
        uint256 deci = 10 ** IERC20Metadata(_token).decimals();
        uint256 glpDeci = 10 ** IERC20Metadata(address(GLP)).decimals();

        lastPrice[_indexToken] = total *  MUTI * deci / amount / glpDeci;
    }

    function getGlpAmount(address _indexToken, address token, uint256 amount) external view returns(uint256) {
        if(token != USDT || amount == 0) {
            return 0;
        }

        uint256 deci = 10 ** IERC20Metadata(USDT).decimals();
        uint256 glpDeci = 10 ** IERC20Metadata(address(GLP)).decimals();
        if(lastPrice[_indexToken] == 0) {
            return  amount * glpDeci / deci;
        }

        return amount * lastPrice[_indexToken] * glpDeci / MUTI / deci;
    }

    function getCurrRate(address token) public view returns(uint256) {
        (uint256 rate, ) = coinData.getCurrRate(token);

        return rate;   
    }


    //********************************************* */
    function _transferTo(address token, address account, uint256 amount) internal {
        uint256 beforeAmount = getAmount(token, address(this));
        uint256 beforeValue = getAmount(token, account);
        IERC20(token).safeTransfer(account, amount);
        uint256 afterAmount = getAmount(token, address(this));
        uint256 afterValue = getAmount(token, account);

        emit TransferTo(
            token, 
            address(this), 
            account, 
            amount, 
            beforeAmount, 
            afterAmount,
            beforeValue,
            afterValue
        );
    } 

    function getAmount(address token, address account) public view returns(uint256) {
        return IERC20(token).balanceOf(account);
    }

    function _validate(address account) internal pure {
        require(account != address(0), "account err");
    }
}
