// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../core/interfaces/IVault.sol";
import "../fund-pool/v2/interfaces/IPoolDataV2.sol";
import "../meme/interfaces/IMemeData.sol";
import "../Pendant/interfaces/ICoinData.sol";
import "./interfaces/IDataReader.sol";
import "../fund-pool/v2/interfaces/IStruct.sol";
import "../meme/interfaces/IMemeStruct.sol";
import "../Pendant/interfaces/IPhase.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../upgradeability/Synchron.sol";

/**
 * @title ADL (Automatic Deleveraging) Contract
 * @notice Handles automatic deleveraging operations for positions when leverage thresholds are exceeded
 * @dev Inherits from Synchron contract for upgradeability functionality
 */
contract ADL is Synchron {
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice Transaction code identifier for ADL operations
    bytes32 public constant TX_CODE_ADL = 0x0000000000000000000000000000000000000000000000000000000000000007;

    /// @notice Minimum net value allowed for pool calculations (0.00001 * 1e30)
    uint256 public constant MIN_NET_VALUE = 0.00001 * 1e30;
    /// @notice Base value used for leverage calculations (1e9)
    uint256 public constant BASE_VALUE = 1e9;
    /// @notice Minimum leverage threshold (2e9)
    uint256 public constant MIN_LEVERAGE = 2e9;
    /// @notice Maximum leverage threshold (10e9)
    uint256 public constant MAX_LEVERAGE = 10e9;
    /// @notice Default leverage trigger value when not set (5e9)
    uint256 public constant DEFAULT_LEVERAGE_TRIGGER_VALUE = 5e9;
    /// @notice Default leverage set value when not set (2e9)
    uint256 public constant DEFAULT_LEVERAGE_SET_VALUE = 2e9;

    /// @notice Transaction type identifier for ADL operations
    uint8 public constant TX_TYPE_ADL = 7;

    IVault public vault;
    ICoinData public coinData;
    IDataReader public dataReader;
    IMemeData public memeData;
    IPoolDataV2 public poolDataV2;

    /// @notice Governance address with administrative privileges
    address public gov;
    /// @notice USDT token address used as base currency
    address public usdt;

    /// @notice Initialization status flag
    bool public initialized;

    /// @notice Mapping of total global long sizes per target index token
    mapping(address => uint256) _totalGlobalLongSizes;
    /// @notice Mapping of total global short sizes per target index token
    mapping(address => uint256) _totalGlobalShortSizes;
    /// @notice Mapping of leverage trigger values per target index token
    mapping(address => uint256) public leverageTriggerValue;
    /// @notice Mapping of leverage set values per target index token
    mapping(address => uint256) public leverageSetValue;
    /// @notice Mapping of time information for ADL operations per index
    mapping(address => mapping(uint256 => TimeInfo)) public timeInfo;
    /// @notice Mapping of index sets for ADL operations per target index token
    mapping(address => EnumerableSet.UintSet) indexes;
    /// @notice Mapping of operation numbers per index
    mapping(address => mapping(uint256 => uint256)) public number;
    /// @notice Mapping of ADL positions stored per operation
    mapping(address => mapping(uint256 => mapping(uint256 => ADLPosition))) listADLPosition;
    /// @notice Mapping of authorized operator addresses
    mapping(address => bool) public operator;

    /**
     * @notice Leverage configuration structure
     * @param indexToken The index token address
     * @param triggerValue The leverage value that triggers ADL
     * @param setValue The target leverage value after ADL execution
     */
    struct LeverageValue {
        address indexToken;
        uint256 triggerValue;
        uint256 setValue;
    }

    /**
     * @notice ADL position structure for deleveraging operations
     * @param account The account address holding the position
     * @param collateralToken The collateral token address
     * @param indexToken The index token address
     * @param collateralDelta The amount of collateral to decrease
     * @param sizeDelta The amount of position size to decrease
     * @param isLong Whether the position is long (true) or short (false)
     */
    struct ADLPosition {
        address account;
        address collateralToken;
        address indexToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
        bool isLong;
    }

    /**
     * @notice Position data structure for batch operations
     * @param account The account address
     * @param collateralToken The collateral token address
     * @param indexToken The index token address
     * @param isLong Whether the position is long (true) or short (false)
     */
    struct PositionData {
        address account;
        address collateralToken;
        address indexToken;
        bool isLong;
    }

    /**
     * @notice Time information structure for ADL operations
     * @param startTime The timestamp when ADL operation started
     * @param endTime The timestamp when ADL operation ended
     */
    struct TimeInfo {
        uint256 startTime;
        uint256 endTime;
    }

    /// @notice Emitted when leverage values are set for target index tokens
    event SetTargetIndexTokenleverageValue(LeverageValue[] leverageValue);

    /// @notice Emitted when operator status is changed
    event SetOperator(address account, bool isAdd);

    /// @notice Emitted when a position is decreased through ADL
    event DecreasePositionADL(
        address targetIndexToken,
        address pool,
        uint256 index,
        uint num,
        ADLPosition aPosition
    );

    /// @notice Emitted when ADL operation has completed
    event ADLHasEnd(address indexToken, address targetIndexToken, address pool, uint256 index, uint256 num);

    /// @notice Emitted when global long and short sizes are updated
    event SetGlobalLongAndShortSizes(address targetIndexToken, address pool, uint256 longSize, uint256 shortSize);

    
    event UserHasNoPosition(ADLPosition aPosition, address pool, uint256 index, uint256 num);
    
    /**
     * @notice Constructor that sets initialization status
     */
    constructor() {
        initialized = true;
    }

    /// @notice Modifier to restrict access to governance address only
    modifier onlyGov() {
        require(msg.sender == gov, "Governable: forbidden");
        _;
    }

    /// @notice Modifier to restrict access to vault contract only
    modifier onlyVault() {
        require(msg.sender == address(vault), "vault err");
        _;
    }

    /// @notice Modifier to restrict access to authorized operators only
    modifier onlyAuth() {
        require(operator[msg.sender], "operator err");
        _;
    }

    /**
     * @notice Initializes the contract with USDT address
     * @param _usdt The USDT token address
     */
    function initialize(address _usdt) external {
        require(!initialized, "has initialized");
        require(_usdt != address(0), "addr err");

        initialized = true;

        gov = msg.sender;
        usdt = _usdt;
    }

    /**
     * @notice Sets the governance address
     * @param _gov The new governance address
     */
    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "_gov err");
        gov = _gov;
    }

    /**
     * @notice Sets the required contract addresses
     * @param _coinData The coin data contract address
     * @param _vault The vault contract address
     * @param _dataReader The data reader contract address
     * @param _memeData The meme data contract address
     * @param _poolDataV2 The pool data contract address (version 2)
     */
    function setContract(
        address _coinData,
        address _vault,
        address _dataReader,
        address _memeData,
        address _poolDataV2
    ) external onlyGov {
        require(
            _coinData != address(0) &&
            _vault != address(0) &&
            _dataReader != address(0) &&
            _memeData != address(0) &&
            _poolDataV2 != address(0),
            "addr err"
        );

        coinData = ICoinData(_coinData);
        vault = IVault(_vault);
        dataReader = IDataReader(_dataReader);
        memeData = IMemeData(_memeData);
        poolDataV2 = IPoolDataV2(_poolDataV2);
    }

    /**
     * @notice Sets global long and short sizes for target index tokens
     * @param targetIndexTokens Array of target index token addresses
     */
    function setGlobalLongAndShortSizes(address[] calldata targetIndexTokens) external onlyGov {
        uint256 len = targetIndexTokens.length;
        for(uint256 i = 0; i < len; i++) {
            address tToken = targetIndexTokens[i];
            address targetIndexToken = dataReader.getTargetIndexToken(tToken);
            require(targetIndexToken == tToken, "targetIndexToken err");
            
            (uint256 longSize, uint256 shortSize) = _getGlobalLongAndShortSizes(targetIndexToken);
            _totalGlobalLongSizes[targetIndexToken] = longSize;
            _totalGlobalShortSizes[targetIndexToken] = shortSize;
            (address pool, ) = _getCurrPool(targetIndexToken);

            emit SetGlobalLongAndShortSizes(targetIndexToken, pool, longSize, shortSize);
        }
    }

    /**
     * @notice Sets operator status for an account
     * @param account The account address to modify operator status
     * @param isAdd Whether to add (true) or remove (false) operator privileges
     */
    function setOperator(address account, bool isAdd) external onlyGov {
        require(account != address(0), "account err");

        operator[account] = isAdd;

        emit SetOperator(account, isAdd);
    }

    /**
     * @notice Sets leverage trigger and set values for target index tokens
     * @param _leverageValue Array of leverage configuration structures
     */
    function setTargetIndexTokenleverageValue(
        LeverageValue[] calldata _leverageValue
    ) external onlyGov {
        uint256 lenLeverageValue = _leverageValue.length;

        require(lenLeverageValue > 0, "length err");
        for(uint256 i = 0; i < lenLeverageValue; i++) {
            address indexToken = _leverageValue[i].indexToken;
            address targetIndexToken = dataReader.getTargetIndexToken(indexToken);
            require(targetIndexToken == indexToken, "targetIndexToken err");

            uint256 triggerValue = _leverageValue[i].triggerValue;
            uint256 setValue = _leverageValue[i].setValue;
            require(MIN_LEVERAGE < triggerValue && triggerValue <= MAX_LEVERAGE, "triggerValue err");
            require(MIN_LEVERAGE <= setValue && setValue < MAX_LEVERAGE, "setValue err");

            leverageTriggerValue[targetIndexToken] = triggerValue;
            leverageSetValue[targetIndexToken] = setValue;
        }

        emit SetTargetIndexTokenleverageValue(_leverageValue);
    }

    /**
     * @notice Executes batch ADL position decreases
     * @param indexToken The index token address
     * @param index The operation index
     * @param aPosition Array of ADL position structures to decrease
     */
    function batchDecreasePositionADL(
        address indexToken,
        uint256 index,
        ADLPosition[] calldata aPosition
    ) external onlyAuth {
        uint256 len = aPosition.length;
        require(len > 0, "length err");
        address targetIndexToken = dataReader.getTargetIndexToken(indexToken);
        (address pool, ) = _getCurrPool(targetIndexToken);
        if(timeInfo[targetIndexToken][index].endTime == 0) {
            for(uint256 i = 0; i < len; i++) {
                ADLPosition calldata _aPosition = aPosition[i];
                address _indexToken = _aPosition.indexToken;
                address _targetIndexToken = dataReader.getTargetIndexToken(_indexToken);
                require(_targetIndexToken == targetIndexToken, "_targetIndexToken err");
 
                if(timeInfo[targetIndexToken][index].startTime == 0) {
                    timeInfo[targetIndexToken][index].startTime = block.timestamp;
                    if(!_shouldExecuteADL(targetIndexToken)) {
                        timeInfo[targetIndexToken][index].endTime = block.timestamp;
                        emit ADLHasEnd(indexToken, targetIndexToken, pool, index, 0);
                        return;
                    }
                }

                bytes32 key = vault.getPositionKey(_aPosition.account, _aPosition.collateralToken, _aPosition.indexToken, _aPosition.isLong);
                IVault.Position memory position = vault.getPositionFrom(key);
                uint256 num = ++number[targetIndexToken][index];
                if(position.size > 0) {
                    vault.ADLDecreasePosition(
                        TX_TYPE_ADL, 
                        TX_CODE_ADL, 
                        _aPosition.account, 
                        _aPosition.collateralToken, 
                        _aPosition.indexToken, 
                        _aPosition.collateralDelta, 
                        _aPosition.sizeDelta, 
                        _aPosition.isLong, 
                        _aPosition.account
                    );
                    indexes[targetIndexToken].add(index);

                    listADLPosition[targetIndexToken][index][num] = _aPosition;
                    emit DecreasePositionADL(targetIndexToken, pool, index, num, _aPosition);

                    uint256 _index = index;
                    if(_getIsSetValue(targetIndexToken)) {
                        timeInfo[targetIndexToken][_index].endTime = block.timestamp;
                        emit ADLHasEnd(indexToken, targetIndexToken, pool, _index, num);
                        return;
                    }
                } else {
                    emit UserHasNoPosition(_aPosition, pool, index, num);
                }
            }
        } else {
            emit ADLHasEnd(indexToken, targetIndexToken, pool, index, number[targetIndexToken][index]);
        }
    }

    /**
     * @notice Increases global long size for an index token
     * @param _indexToken The index token address
     * @param _amount The amount to increase
     * @return size The new global long size
     */
    function increaseGlobalLongSize(address _indexToken, uint256 _amount) external onlyVault returns(uint256 size) {
        uint256 maxSize = vault.maxGlobalLongSizes(_indexToken);
        size = vault.globalLongSizes(_indexToken) + _amount;
        if (maxSize != 0) {
            require(size <= maxSize, "long err");
        }

        _indexToken = dataReader.getTargetIndexToken(_indexToken);
        _totalGlobalLongSizes[_indexToken] += _amount;
    }

    /**
     * @notice Decreases global long size for an index token
     * @param _indexToken The index token address
     * @param _amount The amount to decrease
     * @return _globalLongSize The new global long size
     */
    function decreaseGlobalLongSize(address _indexToken, uint256 _amount) external onlyVault returns(uint256 _globalLongSize) {
        uint256 size = vault.globalLongSizes(_indexToken);
        _indexToken = dataReader.getTargetIndexToken(_indexToken);
        if(size > _amount) {
            _globalLongSize = size - _amount;
            _totalGlobalLongSizes[_indexToken] -= _amount;
        } else {
            _totalGlobalLongSizes[_indexToken] -= size;
        }
    }

    /**
     * @notice Increases global short size for an index token
     * @param _indexToken The index token address
     * @param _amount The amount to increase
     * @return size The new global short size
     */
    function increaseGlobalShortSize(address _indexToken, uint256 _amount) external onlyVault returns(uint256 size) {
        size = vault.globalShortSizes(_indexToken) + _amount;
        uint256 maxSize = vault.maxGlobalShortSizes(_indexToken);
        if (maxSize != 0) {
            require(size <= maxSize, "short");
        }

        _indexToken = dataReader.getTargetIndexToken(_indexToken);
        _totalGlobalShortSizes[_indexToken] += _amount;
    }

    /**
     * @notice Decreases global short size for an index token
     * @param _indexToken The index token address
     * @param _amount The amount to decrease
     * @return _globalShortSize The new global short size
     */
    function decreaseGlobalShortSize(address _indexToken, uint256 _amount) external onlyVault returns(uint256 _globalShortSize) {
        uint256 size = vault.globalShortSizes(_indexToken);
        _indexToken = dataReader.getTargetIndexToken(_indexToken);
        if(size > _amount) {
            _globalShortSize = size - _amount;
            _totalGlobalShortSizes[_indexToken] -= _amount;
        } else {
            _totalGlobalShortSizes[_indexToken] -= size;
        }
    }

    /**
     * @notice Gets current pool information for an index token
     * @param indexToken The index token address
     * @return indexTargetToken The target index token address
     * @return pool The pool contract address
     * @return currID The current period ID
     */
    function getCurrPool(address indexToken)
        external
        view
        returns(address indexTargetToken, address pool, uint256 currID)
    {
        indexTargetToken = dataReader.getTargetIndexToken(indexToken);
        (pool, currID) = _getCurrPool(indexTargetToken);
    }

    /**
     * @notice Gets batch position information
     * @param _positionData Array of position data structures
     * @return positions Array of vault position structures
     */
    function batchGetPositions(
        PositionData[] calldata _positionData
    ) external view returns(IVault.Position[] memory) {
        uint256 len = _positionData.length;
        IVault.Position[] memory positions = new IVault.Position[](len);
        for(uint256 i = 0; i < len; i++) {
            PositionData memory _pData = _positionData[i];
            bytes32 key = vault.getPositionKey(_pData.account, _pData.collateralToken, _pData.indexToken, _pData.isLong);

            IVault.Position memory position = vault.getPositionFrom(key);
            if(position.averagePrice > 0) {
                (bool _hasProfit, uint256 delta) = vault.getDelta(
                    _pData.indexToken, 
                    position.size, 
                    position.averagePrice, 
                    _pData.isLong, 
                    position.lastIncreasedTime
                );
                position.realisedPnl = _hasProfit ? int256(delta) : -int256(delta);
            } else {
                position.realisedPnl = 0;
            }
            positions[i] = position;
        }

        return positions;
    }

    /**
     * @notice Checks if ADL execution conditions are met
     * @param _indexToken The index token address
     * @return bool True if ADL should be executed, false otherwise
     */
    function shouldExecuteADL(address _indexToken) external view returns(bool) {
        address targetIndexToken = dataReader.getTargetIndexToken(_indexToken);
        return _shouldExecuteADL(targetIndexToken);
    }

    /**
     * @notice Checks if leverage set value conditions are met
     * @param _indexToken The index token address
     * @return bool True if leverage has reached set value, false otherwise
     */
    function getIsSetValue(address _indexToken) external view returns(bool) {
        address targetIndexToken = dataReader.getTargetIndexToken(_indexToken);
        return _getIsSetValue(targetIndexToken);
    }

    /**
     * @notice Gets current pool leverage
     * @param _indexToken The index token address
     * @return uint256 The current pool leverage value
     */
    function getPoolLever(address _indexToken) external view returns(uint256) {
        address targetIndexToken = dataReader.getTargetIndexToken(_indexToken);
        return _getPoolLever(targetIndexToken);
    }

    /**
     * @notice Gets current pool net position
     * @param _indexToken The index token address
     * @return uint256 The current pool net position value
     */
    function getPoolNetPosition(address _indexToken) external view returns(uint256) {
        address targetIndexToken = dataReader.getTargetIndexToken(_indexToken);
        return _getPoolNetPosition(targetIndexToken);
    }

    /**
     * @notice Gets current pool real-time net value
     * @param _indexToken The index token address
     * @return value The current pool real-time net value(if value < 0, value = 0)
     */
    function getPoolRealTimeNetValue(address _indexToken) external view returns(uint256 value) {
        address targetIndexToken = dataReader.getTargetIndexToken(_indexToken);

        return _getPoolRealTimeNetValue(targetIndexToken);
    }

    /**
     * @notice Gets leverage trigger value for an index token
     * @param _indexToken The index token address
     * @return uint256 The leverage trigger value
     */
    function getLeverageTriggerValue(address _indexToken) external view returns(uint256) {
        address targetIndexToken = dataReader.getTargetIndexToken(_indexToken);
        return _getLeverageTriggerValue(targetIndexToken);
    }

    /**
     * @notice Gets leverage set value for an index token
     * @param _indexToken The index token address
     * @return uint256 The leverage set value
     */
    function getLeverageSetValue(address _indexToken) external view returns(uint256) {
        address targetIndexToken = dataReader.getTargetIndexToken(_indexToken);
        return _getLeverageSetValue(targetIndexToken);
    }

    /**
     * @notice Gets the length of indexes for a target index token
     * @param targetIndexToken The target index token address
     * @return uint256 The number of indexes
     */
    function getIndexesLength(address targetIndexToken) external view returns(uint256) {
        return indexes[targetIndexToken].length();
    }

    /**
     * @notice Gets a specific index for a target index token
     * @param targetIndexToken The target index token address
     * @param num The index number to retrieve
     * @return uint256 The index value
     */
    function getIndex(address targetIndexToken, uint256 num) external view returns(uint256) {
        return indexes[targetIndexToken].at(num);
    }

    /**
     * @notice Checks if an index exists for a target index token
     * @param targetIndexToken The target index token address
     * @param index The index value to check
     * @return bool True if index exists, false otherwise
     */
    function getIndexIsIn(address targetIndexToken, uint256 index) external view returns(bool) {
        return indexes[targetIndexToken].contains(index);
    }

    /**
     * @notice Gets a specific ADL position from storage
     * @param targetIndexToken The target index token address
     * @param index The operation index
     * @param num The position number
     * @return ADLPosition The ADL position structure
     */
    function getListADLPosition(
        address targetIndexToken,
        uint256 index,
        uint256 num
    ) external view returns(ADLPosition memory) {
        return listADLPosition[targetIndexToken][index][num];
    }

    /**
     * @notice Gets total global long sizes for an index token
     * @param _indexToken The index token address
     * @return uint256 The total global long size
     */
    function totalGlobalLongSizes(address _indexToken) external view returns(uint256) {
        address targetIndexToken = dataReader.getTargetIndexToken(_indexToken);
        return _totalGlobalLongSizes[targetIndexToken];
    }

    /**
     * @notice Gets total global short sizes for an index token
     * @param _indexToken The index token address
     * @return uint256 The total global short size
     */
    function totalGlobalShortSizes(address _indexToken) external view returns(uint256) {
        address targetIndexToken = dataReader.getTargetIndexToken(_indexToken);
        return _totalGlobalShortSizes[targetIndexToken];
    }

    /**
     * @notice Gets global long and short sizes for an index token
     * @param _indexToken The index token address
     * @return uint256, uint256 The global long size and global short size
     */
    function getGlobalLongAndShortSizes(
        address _indexToken
    ) public view returns(uint256, uint256) {
        address targetIndexToken = dataReader.getTargetIndexToken(_indexToken);
        return _getGlobalLongAndShortSizes(targetIndexToken);
    }

    /**
     * @notice Internal function to calculate pool leverage
     * @param targetIndexToken The target index token address
     * @return lever The calculated pool leverage
     */
    function _getPoolLever(address targetIndexToken) internal view returns(uint256 lever) {
        uint256 realTimeNetValue = _getPoolRealTimeNetValue(targetIndexToken);
        if(realTimeNetValue <= 0) {
            realTimeNetValue = MIN_NET_VALUE;
        }
        uint256 netPosition = _getPoolNetPosition(targetIndexToken);
        lever = netPosition * BASE_VALUE / realTimeNetValue;
    }

    /**
     * @notice Internal function to calculate pool net position
     * @param targetIndexToken The target index token address
     * @return value The calculated pool net position
     */
    function _getPoolNetPosition(address targetIndexToken) internal view returns(uint256 value) {
        value = _totalGlobalLongSizes[targetIndexToken] > _totalGlobalShortSizes[targetIndexToken] ?
            _totalGlobalLongSizes[targetIndexToken] - _totalGlobalShortSizes[targetIndexToken] :
            _totalGlobalShortSizes[targetIndexToken] - _totalGlobalLongSizes[targetIndexToken];
    }

    /**
     * @notice Internal function to get current pool information
     * @param indexTargetToken The target index token address
     * @return pool The pool contract address
     * @return currID The current period ID
     */
    function _getCurrPool(address indexTargetToken)
        internal
        view
        returns(address pool, uint256 currID)
    {
        if(memeData.isAddMeme(indexTargetToken)) {
            pool = memeData.tokenToPool(indexTargetToken);
        } else {
            pool = poolDataV2.tokenToPool(indexTargetToken);
            currID = poolDataV2.currPeriodID(pool);
            require(currID > 0, "pid err");
        }
    }

    /**
     * @notice Internal function to check ADL execution conditions
     * @param targetIndexToken The target index token address
     * @return bool True if ADL should be executed, false otherwise
     */
    function _shouldExecuteADL(address targetIndexToken) internal view returns(bool) {
        uint256 lever = _getPoolLever(targetIndexToken);
        if(lever > _getLeverageTriggerValue(targetIndexToken)) {
            return true;
        }
        return false;
    }

    /**
     * @notice Internal function to check leverage set value conditions
     * @param targetIndexToken The target index token address
     * @return bool True if leverage has reached set value, false otherwise
     */
    function _getIsSetValue(address targetIndexToken) internal view returns(bool) {
        uint256 lever = _getPoolLever(targetIndexToken);
        if(lever <= _getLeverageSetValue(targetIndexToken)) {
            return true;
        }
        return false;
    }

    /**
     * @notice Internal function to calculate pool real-time net value
     * @param targetIndexToken The target index token address
     * @return value The calculated pool real-time net value(if value < 0, value = 0)
     */
    function _getPoolRealTimeNetValue(address targetIndexToken) internal view returns(uint256 value) {
        IPhase _phase = IPhase(vault.phase());
        if(memeData.isAddMeme(targetIndexToken)) {
            (address pool,) = _getCurrPool(targetIndexToken);
            IMemeStruct.MemeState memory mState = memeData.getMemeState(pool);
            value = _phase.getPoolRealTimeNetValue(targetIndexToken, usdt, mState.totalGlpAmount);

        } else {
            (address pool, uint256 currID) = _getCurrPool(targetIndexToken);
            IStruct.FoundStateV2 memory fState = poolDataV2.getFoundState(pool, currID);
            value = _phase.getPoolRealTimeNetValue(targetIndexToken, usdt, fState.glpAmount);

        }
    }

    /**
     * @notice Internal function to get leverage trigger value
     * @param targetIndexToken The target index token address
     * @return value The leverage trigger value
     */
    function _getLeverageTriggerValue(address targetIndexToken) internal view returns(uint256 value) {
        value = leverageTriggerValue[targetIndexToken];
        if(value == 0) {
            value = DEFAULT_LEVERAGE_TRIGGER_VALUE;
        }
    }

    /**
     * @notice Internal function to get leverage set value
     * @param targetIndexToken The target index token address
     * @return value The leverage set value
     */
    function _getLeverageSetValue(address targetIndexToken) internal view returns(uint256 value) {
        value = leverageSetValue[targetIndexToken];
        if(value == 0) {
            value = DEFAULT_LEVERAGE_SET_VALUE;
        }
    }

    /**
     * @notice Internal function to calculate global long and short sizes
     * @param targetIndexToken The target index token address
     * @return longSize The calculated global long size
     * @return shortSize The calculated global short size
     */
    function _getGlobalLongAndShortSizes(
        address targetIndexToken
    ) internal view returns(uint256 longSize, uint256 shortSize) {
        {
            uint256 _lenSingleToken = coinData.getCurrSingleTokensLength(targetIndexToken);
            for(uint256 i = 0; i < _lenSingleToken; i++) {
                (address _singleToken,) = coinData.getCurrSingleToken(targetIndexToken, i);
                longSize += vault.globalLongSizes(_singleToken);
                shortSize += vault.globalShortSizes(_singleToken);
            }

            uint256 _lenMemberTokenTargetID = coinData.getCurrMemberTokenTargetIDLength(targetIndexToken);
            for(uint256 i = 0; i < _lenMemberTokenTargetID; i++) {
                (uint256 _memberTokenTargetID,) = coinData.getCurrMemberTokenTargetID(targetIndexToken, i);

                uint256 _lenMemberTokens = coinData.getCurrMemberTokensLength(targetIndexToken, _memberTokenTargetID);
                for(uint256 j = 0; j < _lenMemberTokens; j++) {
                    address _memberToken = coinData.getCurrMemberToken(targetIndexToken, _memberTokenTargetID, j);
                    longSize += vault.globalLongSizes(_memberToken);
                    shortSize += vault.globalShortSizes(_memberToken);
                }
            }
        }
    }
}
