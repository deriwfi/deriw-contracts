// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../libraries/utils/ReentrancyGuard.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IVault.sol";
import "../peripherals/interfaces/ITimelock.sol";
import "../Pendant/interfaces/IPhase.sol";
import "../blackList/interfaces/IBlackList.sol";
import "../Pendant/interfaces/ISlippage.sol";
import "../referrals/interfaces/IReferralStorage.sol";
import "../referrals/interfaces/IReferralData.sol";
import "./interfaces/ITransferAmountData.sol";
import "../upgradeability/Synchron.sol";


contract PositionRouter is Synchron, ReentrancyGuard, ITransferAmountData {
    using Address for address;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    address public adminFor;
    address public gov;
    address public vault;
    address public router;
    address public usdt;
    address public referralStorage;

    IReferralData public referralData;
    IPhase public phase;
    IBlackList public blackList;

    uint256 public increasePositionBufferBps;
    uint256 public minBlockDelayKeeper;
    uint256 public minTimeDelayPublic;
    uint256 public maxTimeDelay;
    uint256 public totalIncreaseIndex;
    uint256 public totalDecreaseIndex;
    uint256 public minAmount;
    uint256 public initAmount;

    EnumerableSet.UintSet increaseIndex;
    EnumerableSet.UintSet decreaseIndex;

    bool public isLeverageEnabled;
    bool public initialized;

    mapping(uint256 => bytes32) public increasePositionIndexToKey;
    mapping(uint256 => bytes32) public decreasePositionIndexToKey;
    mapping(bytes32 => uint256) public increasePositionKeyToIndex;
    mapping(bytes32 => uint256) public decreasePositionKeyToIndex;
    mapping (address => uint256) public feeReserves;
    mapping (address => bool) public isPositionKeeper;
    mapping (address => uint256) public increasePositionsIndex;
    mapping (bytes32 => IncreasePositionRequest)  _increasePositionRequests;
    mapping (address => uint256) public decreasePositionsIndex;
    mapping (bytes32 => DecreasePositionRequest) _decreasePositionRequests;


    struct IncreasePositionRequest {
        address account;
        address[] path;
        address indexToken;
        uint256 amountIn;
        uint256 sizeDelta;
        bool isLong;
        uint256 acceptablePrice;
        uint256 blockNumber;
        uint256 blockTime;
        bool hasCollateralInETH;
        address callbackTarget;
    }

    struct DecreasePositionRequest {
        address account;
        address[] path;
        address indexToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
        bool isLong;
        address receiver;
        uint256 acceptablePrice;
        uint256 blockNumber;
        uint256 blockTime;
        address callbackTarget;
    }

   
    struct CreateIncreasePositionEvent {
        bytes32 key;
        address[] path;
        address account;
        address indexToken;
        uint256 amountIn;
        uint256 sizeDelta;
        uint256 acceptablePrice;
        uint256 index;
        uint256 queueIndex;
        uint256 blockNumber;
        uint256 blockTime;
        uint256 gasPrice;
        bool isLong;
    }

    struct ExecuteIncreaseEvent {
        bytes32 key;
        address account;
        address[] path;
        address indexToken;
        uint256 amountIn;
        uint256 sizeDelta;
        bool isLong;
        uint256 acceptablePrice;
        uint256 blockGap;
        uint256 timeGap;
        uint256 index;
    }

    struct CancelIncreaseEvent{
        bytes32 key;
        address account;
        address[] path;
        address indexToken;
        uint256 amountIn;
        uint256 sizeDelta;
        bool isLong;
        uint256 acceptablePrice;
        uint256 blockGap;
        uint256 timeGap;
        uint256 index;
    }

    struct CreateDecreasePositionEvent{
        DecreasePositionRequest request;
        bytes32 key;
        uint256 index;
        uint256 queueIndex;
    }

    struct ExecuteDecreaseEventFor {
        bytes32 key;
        address account;
        address[] path;
        address indexToken;
        address receiver;
        uint256 collateralDelta;
        uint256 sizeDelta;
        bool isLong;
        uint256 acceptablePrice;
        uint256 blockGap;
        uint256 timeGap;
        uint256 index;
    }

    struct CancelDecreaseEvent {
        bytes32 key;
        address account;
        address[] path;
        address indexToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
        bool isLong;
        address receiver;
        uint256 acceptablePrice;
        uint256 blockGap;
        uint256 timeGap;
        uint256 index;
    }

    struct IncreaseTransferEvent{
        bytes32 key;
        address from; 
        address to; 
        uint256 amount; 
        uint256 beforeAmount; 
        uint256 afterAmount;
        uint256 beforeValue;
        uint256 afterValue;
    }

    event SetIncreasePositionBufferBps(uint256 increasePositionBufferBps);
    event SetReferralStorage(address referralStorage);
    event SetAdmin(address adminFor);

    event SetPositionKeeper(address indexed account, bool isActive);
    event SetIsLeverageEnabled(bool isLeverageEnabled);
    event SetDelayValues(uint256 minBlockDelayKeeper, uint256 minTimeDelayPublic, uint256 maxTimeDelay);
    event CreateIncreaseTransferEvent(IncreaseTransferEvent iEvent);
    event CreateIncreasePosition(CreateIncreasePositionEvent cEvent);
    event ExecuteIncreasePosition(ExecuteIncreaseEvent eEvent);
    event CancelIncreasePosition(CancelIncreaseEvent cEvent);
    event ExecuteDecreasePosition(ExecuteDecreaseEventFor eEvent);
    event CancelDecreasePosition(CancelDecreaseEvent cEvent);

    event CreateDecreasePosition(
        DecreasePositionRequest request,
        bytes32 key,
        uint256 index,
        uint256 queueIndex
    );

    event ExecuteIncreaseTransferEvent(
        bytes32 key,
        address from, 
        address to, 
        uint256 amount, 
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );

    event CancelIncreaseTransferEvent(
        bytes32 key,
        address from, 
        address to, 
        uint256 amount, 
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );

    event ExecuteDecreaseEvent(
        bytes32 _key,
        address from, 
        address to, 
        uint256 amount, 
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );

    event SetMinAndInitAmount(uint256 minAmount, uint256 initAmount);


    constructor() {
        initialized = true;
    }


    modifier onlyGov() {
        require(msg.sender == gov, "Governable: forbidden");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == adminFor, "forbidden");
        _;
    }

    modifier onlyPositionKeeper() {
        require(isPositionKeeper[msg.sender], "403");
        _;
    }

    function initialize() external {
        require(!initialized, "has initialized");
        initialized = true;

        initAmount = 10e6;
        minAmount = 10e6;

        increasePositionBufferBps = 100;
        isLeverageEnabled = true;

        gov = msg.sender;
        adminFor = msg.sender;
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "account err");
        gov = _gov;
    }

    function setAdmin(address _admin) external onlyGov {
        require(_admin != address(0), "_admin err");

        adminFor = _admin;
        emit SetAdmin(_admin);
    }

    function setContract(
        address _phase,
        address _blackList,
        address _referralData,
        address _vault,
        address _router,
        address _usdt
    ) external onlyGov {
        require(
            _phase != address(0) &&
            _blackList != address(0) &&
            _referralData != address(0) &&
            _vault != address(0) &&
            _router != address(0) &&
            _usdt != address(0),
            "addr err"
        );

        phase = IPhase(_phase);   
        blackList = IBlackList(_blackList);
        referralData = IReferralData(_referralData);   
        vault = _vault;
        router = _router;
        usdt = _usdt;
    }


    function setMinAndInitAmount(uint256 _minAmount, uint256 _initAmount) external onlyAdmin {
        require(_minAmount > 0, "_minAmount err");
        require(_initAmount > 0, "_initAmount err");

        minAmount = _minAmount;
        initAmount = _initAmount;

        emit SetMinAndInitAmount(_minAmount, _initAmount);
    }

    function setIncreasePositionBufferBps(uint256 _increasePositionBufferBps) external onlyAdmin {
        increasePositionBufferBps = _increasePositionBufferBps;

        emit SetIncreasePositionBufferBps(_increasePositionBufferBps);
    }

    function setReferralStorage(address _referralStorage) external onlyAdmin {
        referralStorage = _referralStorage;

        emit SetReferralStorage(_referralStorage);
    } 

    function setPositionKeeper(address _account, bool _isActive) external onlyAdmin {
        require(_account != address(0), "_account err");
        
        isPositionKeeper[_account] = _isActive;
        emit SetPositionKeeper(_account, _isActive);
    }

    function setIsLeverageEnabled(bool _isLeverageEnabled) external onlyAdmin {
        isLeverageEnabled = _isLeverageEnabled;
        emit SetIsLeverageEnabled(_isLeverageEnabled);
    }

    function setDelayValues(
        uint256 _minBlockDelayKeeper, 
        uint256 _minTimeDelayPublic, 
        uint256 _maxTimeDelay
    ) external onlyAdmin {
        minBlockDelayKeeper = _minBlockDelayKeeper;
        minTimeDelayPublic = _minTimeDelayPublic;
        maxTimeDelay = _maxTimeDelay;

        emit SetDelayValues(_minBlockDelayKeeper, _minTimeDelayPublic, _maxTimeDelay);
    }

    function createIncreasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _amountIn,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        bytes32 _referralCode,
        address _callbackTarget
    ) external nonReentrant returns (bytes32) {
        require(_referralCode == bytes32(0), "_referralCode err");
        require(!blackList.isFusing() && !blackList.isStop(), "can not create");
        uint256 len = _path.length;
        require(len == 1 || len == 2, "408");
        address _pToken = _path[0];
        if(len == 1) {
            require(usdt == _pToken, "_path[0] err");
        } else if(len == 2) {
            require(usdt == _path[1] && usdt == _pToken, "_path[1] err");
        } else {
            revert("len err");
        }

        if(_amountIn == 0 && _sizeDelta == 0) {
            revert("value err");
        }

        (,uint256 collateral,,,,,,) = IVault(vault).getPosition(msg.sender, usdt, _indexToken, _isLong);
        if(collateral == 0) {
            require(_amountIn >= initAmount, "amount err");
        }

        if(_sizeDelta > 0) {
            uint256 minAmountToUsdAmount = IVault(vault).tokenToUsdMin(usdt, minAmount);
            require(_sizeDelta >= minAmountToUsdAmount, "_sizeDelta err");
        }

        ISlippage(IVault(vault).slippage()).validateLever(msg.sender, usdt, _indexToken, _amountIn, _sizeDelta, _isLong);
        phase.validateSizeDelta(msg.sender, _indexToken, _sizeDelta, _isLong);

        bytes32 key = _createIncreasePosition(
            msg.sender,
            _path,
            _indexToken,
            _amountIn,
            _sizeDelta,
            _isLong,
            _acceptablePrice,
            false,
            _callbackTarget
        );

        uint256 _value = _amountIn;
        if (_value > 0) {
            uint256 beforeAmount = getAmount(_pToken, address(this));
            uint256 beforeValue = getAmount(_pToken, msg.sender);
            IRouter(router).pluginTransfer(_pToken, msg.sender, address(this), _value);
            uint256 afterAmount = getAmount(_pToken, address(this));
            uint256 afterValue = getAmount(_pToken, msg.sender);

            IncreaseTransferEvent memory iEvent = IncreaseTransferEvent(
                key, msg.sender, address(this), _value, beforeAmount, afterAmount, beforeValue, afterValue
            );
            emit CreateIncreaseTransferEvent(iEvent);
        }

        return key;
    }

    function createDecreasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _acceptablePrice,
        address _callbackTarget
    ) external nonReentrant returns (bytes32) {
        require(!blackList.isStop(), "can not create");
        ISlippage(IVault(vault).slippage()).validateRemoveTime(_indexToken);
        require(_path.length == 1 || _path.length == 2, "505");
        require(_path[0] == usdt, "path[0] err");
        if(_path.length == 2) {
            require(_path[1] == usdt, "path[1] err");
        }

        (,uint256 collateral,,,,,,) = IVault(vault).getPosition(msg.sender, usdt, _indexToken, _isLong);
        if((_collateralDelta == 0 && _sizeDelta == 0) || collateral == 0) {
            revert("value err");
        }

        if(_sizeDelta > 0) {
            (uint256 size,,,,,,,) = IVault(vault).getPosition(msg.sender, usdt, _indexToken, _isLong);
            uint256 minAmountToUsdAmount = IVault(vault).tokenToUsdMin(usdt, minAmount);

            require(
                (_sizeDelta >= minAmountToUsdAmount || _sizeDelta == size), 
                "_sizeDelta err"
            );
        }

        return _createDecreasePosition(
            msg.sender,
            _path,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _receiver,
            _acceptablePrice,
            _callbackTarget
        );
    }

    function executeIncreasePosition(bytes32 _key) public nonReentrant returns (bool) {
        uint256 index = increasePositionKeyToIndex[_key];
        if(!increaseIndex.contains(index)) {
            return true;
        }

        IncreasePositionRequest memory request = _increasePositionRequests[_key];
        ISlippage(IVault(vault).slippage()).validateCreate(request.indexToken);
        phase.validateSizeDelta(request.account, request.indexToken, request.sizeDelta, request.isLong);

        bool shouldExecute = _validateExecution(request.blockNumber, request.blockTime, request.account);
        if (!shouldExecute) { return false; }

        address token = request.path[request.path.length - 1];

        uint256 amountIn = request.amountIn;
        if (request.amountIn > 0) {
            TransferAmountData memory tData = _safeTransfer(token, vault, amountIn);

            emit ExecuteIncreaseTransferEvent(
                _key, 
                address(this),
                vault, 
                amountIn, 
                tData.beforeAmount, 
                tData.afterAmount,
                tData.beforeValue,
                tData.afterValue
            );
        }

        _increasePosition(
            _key, 
            request.account,
            token, 
            request.indexToken, 
            request.sizeDelta, 
            request.isLong, 
            request.acceptablePrice,
            amountIn
        );

        ExecuteIncreaseEvent memory eEvent = ExecuteIncreaseEvent(
            _key,
            request.account,
            request.path,
            request.indexToken,
            request.amountIn,
            request.sizeDelta,
            request.isLong,
            request.acceptablePrice,
            (block.number - request.blockNumber),
            (block.timestamp - request.blockTime),
            index
        );

        increaseIndex.remove(index);

        emit ExecuteIncreasePosition(eEvent);

        return true;
    }

    function executeIncreasePositions(uint256[] memory indexes) external onlyPositionKeeper {
        uint256 len = indexes.length;
        require(len > 0, "length err");

        for (uint256 i = 0; i < len; i++)  {
            // if the request was executed then delete the key from the array
            // if the request was not executed then break from the loop, this can happen if the
            // minimum number of blocks has not yet passed
            // an error could be thrown if the request is too old or if the slippage is
            // higher than what the user specified, or if there is insufficient liquidity for the position
            // in case an error was thrown, cancel the request
            bytes32 key = increasePositionIndexToKey[indexes[i]];
            try this.executeIncreasePosition(key) returns (bool _wasExecuted) {
                if (!_wasExecuted) { break; }
            } catch {
                // wrap this call in a try catch to prevent invalid cancels from blocking the loop
                try this.cancelIncreasePosition(key) returns (bool _wasCancelled) {
                    if (!_wasCancelled) { break; }
                } catch {}
            }
        }
    }

    function executeDecreasePositions(uint256[] memory indexes) external onlyPositionKeeper {
        uint256 len = indexes.length;
        require(len > 0, "length err");

        for (uint256 i = 0; i < len; i++) {
            // if the request was executed then delete the key from the array
            // if the request was not executed then break from the loop, this can happen if the
            // minimum number of blocks has not yet passed
            // an error could be thrown if the request is too old
            // in case an error was thrown, cancel the request
            bytes32 key = decreasePositionIndexToKey[indexes[i]];
            try this.executeDecreasePosition(key) returns (bool _wasExecuted) {
                if (!_wasExecuted) { break; }
            } catch {
                // wrap this call in a try catch to prevent invalid cancels from blocking the loop
                try this.cancelDecreasePosition(key) returns (bool _wasCancelled) {
                    if (!_wasCancelled) { break; }
                } catch {}
            }
        }
    }

    function cancelIncreasePosition(bytes32 _key) public nonReentrant returns (bool) {
        uint256 index = increasePositionKeyToIndex[_key];
        if(!increaseIndex.contains(index)) {
            return true;
        }

        IncreasePositionRequest memory request = _increasePositionRequests[_key];

        bool shouldCancel = _validateCancellation(request.blockNumber, request.blockTime, request.account);
        if (!shouldCancel) { return false; }

        uint256 time = request.blockTime;
        uint256 num = request.blockNumber;
        CancelIncreaseEvent memory cEvent = CancelIncreaseEvent(
            _key,
            request.account,
            request.path,
            request.indexToken,
            request.amountIn,
            request.sizeDelta,
            request.isLong,
            request.acceptablePrice,
            block.number - num,
            block.timestamp - time,
            index
        );

        emit CancelIncreasePosition(cEvent);

        address token = request.path[0];
        TransferAmountData memory tData = _safeTransfer(token, request.account, request.amountIn);

        emit CancelIncreaseTransferEvent(
            _key, 
            address(this), 
            request.account, 
            request.amountIn, 
            tData.beforeAmount, 
            tData.afterAmount, 
            tData.beforeValue, 
            tData.afterValue
        );
        increaseIndex.remove(index);

        return true;
    }

    function executeDecreasePosition(bytes32 _key) public nonReentrant returns (bool) {
        uint256 index = decreasePositionKeyToIndex[_key];
        if(!decreaseIndex.contains(index)) {
            return true;
        }
       
        DecreasePositionRequest memory request = _decreasePositionRequests[_key];
        // if the request was already executed or cancelled, return true so that the executeDecreasePositions loop will continue executing the next request
        if (request.account == address(0)) { return true; }


        bool shouldExecute = _validateExecution(request.blockNumber, request.blockTime, request.account);
        if (!shouldExecute) { return false; }
        uint256 amountOut = _decreasePosition(_key, request.account, request.path[0], request.indexToken, request.collateralDelta, request.sizeDelta, request.isLong, address(this), request.acceptablePrice);

        if (amountOut > 0) {
            address token = request.path[request.path.length - 1];

            TransferAmountData memory tData = _safeTransfer(token, request.receiver, amountOut);

            emit ExecuteDecreaseEvent(
                _key, 
                address(this), 
                request.receiver, 
                amountOut, 
                tData.beforeAmount, 
                tData.afterAmount, 
                tData.beforeValue, 
                tData.afterValue
            );
        }

        ExecuteDecreaseEventFor memory eEvent = ExecuteDecreaseEventFor(
            _key,
            request.account,
            request.path,
            request.indexToken,
            request.receiver,
            request.collateralDelta,
            request.sizeDelta,
            request.isLong,
            request.acceptablePrice,
            (block.number - request.blockNumber),
            (block.timestamp- request.blockTime),
            index
        );

        decreaseIndex.remove(index);
        emit ExecuteDecreasePosition(eEvent);

        return true;
    }

    function cancelDecreasePosition(bytes32 _key) public nonReentrant returns (bool) {
        uint256 index = decreasePositionKeyToIndex[_key];
        if(!decreaseIndex.contains(index)) {
            return true;
        }

        DecreasePositionRequest memory request = _decreasePositionRequests[_key];

        bool shouldCancel = _validateCancellation(request.blockNumber, request.blockTime, request.account);
        if (!shouldCancel) { return false; }

        CancelDecreaseEvent memory cEvent = CancelDecreaseEvent(
            _key,
            request.account,
            request.path,
            request.indexToken,
            request.collateralDelta,
            request.sizeDelta,
            request.isLong,
            request.receiver,
            request.acceptablePrice,
            (block.number - request.blockNumber),
            (block.timestamp - request.blockTime),
            index
        );

        decreaseIndex.remove(index);
        emit CancelDecreasePosition(cEvent);

        return true;
    }

    function getRequestKey(address _account, uint256 _index) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _index));
    }

    function getIncreasePositionRequestPath(bytes32 _key) public view returns (address[] memory) {
        IncreasePositionRequest memory request = _increasePositionRequests[_key];
        return request.path;
    }

    function getDecreasePositionRequestPath(bytes32 _key) public view returns (address[] memory) {
        DecreasePositionRequest memory request = _decreasePositionRequests[_key];
        return request.path;
    }

    function _validateExecution(
        uint256 _positionBlockNumber, 
        uint256 _positionBlockTime, 
        address _account
    ) internal view returns (bool) {
        if (_positionBlockTime+maxTimeDelay <= block.timestamp) {
            revert("expired");
        }

        return _validateExecutionOrCancellation(_positionBlockNumber, _positionBlockTime, _account);
    }

    function _validateCancellation(
        uint256 _positionBlockNumber, 
        uint256 _positionBlockTime, 
        address _account
    ) internal view returns (bool) {
        return _validateExecutionOrCancellation(_positionBlockNumber, _positionBlockTime, _account);
    }

    function _validateExecutionOrCancellation(
        uint256 _positionBlockNumber, 
        uint256 _positionBlockTime, 
        address _account
    ) internal view returns (bool) {
        bool isKeeperCall = msg.sender == address(this) || isPositionKeeper[msg.sender];

        if (!isLeverageEnabled && !isKeeperCall) {
            revert("403");
        }

        if (isKeeperCall) {
            return _positionBlockNumber + minBlockDelayKeeper <= block.number;
        }

        require(msg.sender == _account, "407");

        require(_positionBlockTime + minTimeDelayPublic <= block.timestamp, "delay");

        return true;
    }

    function _createIncreasePosition(
        address _account,
        address[] memory _path,
        address _indexToken,
        uint256 _amountIn,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        bool _hasCollateralInETH,
        address _callbackTarget
    ) internal returns (bytes32) {
        IncreasePositionRequest memory request;

        request.account = _account;
        request.path = _path;
        request.indexToken = _indexToken;
        request.amountIn = _amountIn;
        request.sizeDelta = _sizeDelta;
        request.isLong = _isLong;
        request.acceptablePrice = _acceptablePrice;
        request.blockNumber = block.number;
        request.blockTime = block.timestamp;
        request.hasCollateralInETH = _hasCollateralInETH;
        request.callbackTarget = _callbackTarget;

        (uint256 index, bytes32 requestKey) = _storeIncreasePositionRequest(request);
        CreateIncreasePositionEvent memory cEvent = CreateIncreasePositionEvent(
            requestKey,
            request.path,
            _account,
            _indexToken,
            _amountIn,
            _sizeDelta,
            _acceptablePrice,
            index,
            totalIncreaseIndex,
            block.number,
            block.timestamp,
            tx.gasprice,
            _isLong
        );
        
        emit CreateIncreasePosition(cEvent);
        return requestKey;
    }

    function _storeIncreasePositionRequest(IncreasePositionRequest memory _request) internal returns (uint256, bytes32) {
        address account = _request.account;
        uint256 index = increasePositionsIndex[account] + 1;
        increasePositionsIndex[account] = index;
        totalIncreaseIndex += 1;
        increaseIndex.add(totalIncreaseIndex);

        bytes32 key = getRequestKey(account, index);
        increasePositionIndexToKey[totalIncreaseIndex] = key;
        increasePositionKeyToIndex[key] = totalIncreaseIndex;
        _increasePositionRequests[key] = _request;

        return (index, key);
    }

    function _storeDecreasePositionRequest(DecreasePositionRequest memory _request) internal returns (uint256, bytes32) {
        address account = _request.account;
        uint256 index = decreasePositionsIndex[account] + 1;
        decreasePositionsIndex[account] = index;
        bytes32 key = getRequestKey(account, index);
        totalDecreaseIndex += 1;
        decreaseIndex.add(totalDecreaseIndex);
        
        _decreasePositionRequests[key] = _request;
        decreasePositionIndexToKey[totalDecreaseIndex] = key;
        decreasePositionKeyToIndex[key] = totalDecreaseIndex;

        return (index, key);
    }

    function _createDecreasePosition(
        address _account,
        address[] memory _path,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _acceptablePrice,
        address _callbackTarget
    ) internal returns (bytes32) {
        DecreasePositionRequest memory request;

        request.account = _account;
        request.path = _path;
        request.indexToken = _indexToken;
        request.collateralDelta = _collateralDelta;
        request.sizeDelta = _sizeDelta;
        request.isLong =  _isLong;
        request.receiver = _receiver;
        request.acceptablePrice = _acceptablePrice;
        request.blockNumber = block.number;
        request.blockTime = block.timestamp;
        request.callbackTarget = _callbackTarget;

        (uint256 index, bytes32 requestKey) = _storeDecreasePositionRequest(request);

        emit CreateDecreasePosition(
            request,
            requestKey,
            index,
            totalDecreaseIndex
        );
        
        return requestKey;
    }

    function _increasePosition(
        bytes32 _key, 
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _sizeDelta, 
        bool _isLong, 
        uint256 _price,
        uint256 _amount
    ) internal {
        _increasePosition(
            _key,
            vault,
            router,
            _account,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isLong,
            _price,
            _amount
        );
    }

    function _decreasePosition(
        bytes32 _key, 
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _collateralDelta, 
        uint256 _sizeDelta, 
        bool _isLong, 
        address _receiver, 
        uint256 _price
    ) internal returns (uint256) {
        address _vault = vault;

        uint256 markPrice = _isLong ? IVault(_vault).getMinPrice(_indexToken) : IVault(_vault).getMaxPrice(_indexToken);
        if (_isLong) {
            require(markPrice >= _price, "markPrice < price");
        } else {
            require(markPrice <= _price, "markPrice > price");
        }

        address timelock = IVault(_vault).gov();

        ITimelock(timelock).enableLeverage(_vault);
        uint256 amountOut = IRouter(router).pluginDecreasePosition(
            _key, 
            _account, 
            _collateralToken, 
            _indexToken, 
            _collateralDelta, 
            _sizeDelta, 
            _isLong, 
            _receiver
        )
        ;
        ITimelock(timelock).disableLeverage(_vault);

        return amountOut;
    }

    function getAmount(address token, address account) public view returns(uint256) {
        return IERC20(token).balanceOf(account);
    }

    
    function _increasePosition(
        bytes32 _key,
        address _vault,
        address _router,
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _price,
        uint256 _amount
    ) internal {
        uint256 markPrice = _isLong ? IVault(_vault).getMaxPrice(_indexToken) : IVault(_vault).getMinPrice(_indexToken);
        if (_isLong) {
            require(markPrice <= _price, "markPrice > price");
        } else {
            require(markPrice >= _price, "markPrice < price");
        }

        address timelock = IVault(_vault).gov();

        ITimelock(timelock).enableLeverage(_vault);
        IRouter(_router).pluginIncreasePosition(_key, _account, _collateralToken, _indexToken, _sizeDelta, _isLong, _amount);
        ITimelock(timelock).disableLeverage(_vault);
    }


    function _safeTransfer(
        address token, 
        address to, 
        uint256 amount
    ) internal returns(TransferAmountData memory tData) {
        tData.beforeAmount = getAmount(token, address(this));
        tData.beforeValue = getAmount(token, to);
        IERC20(token).safeTransfer(to, amount);
        tData.afterAmount = getAmount(token, address(this));
        tData.afterValue = getAmount(token, to);
    }

    function increasePositionRequests(bytes32 request) external view returns(IncreasePositionRequest memory) {
        return _increasePositionRequests[request];
    }

    function decreasePositionRequests(bytes32 request) external view returns(DecreasePositionRequest memory) {
        return _decreasePositionRequests[request];
    }


    function getIndexNum(uint8 queryType) external view returns(uint256) {
        if(queryType == 1) {
            return increaseIndex.length();
        }

        if(queryType == 2) {
            return decreaseIndex.length();
        }

        return 0;
    }

    function getIndex(uint8 queryType, uint256 num) external view returns(uint256) {
        if(queryType == 1) {
            return increaseIndex.at(num);
        }

        if(queryType == 2) {
            return decreaseIndex.at(num);
        }

        return 0;
    }

    function getIndexIsIn(uint8 queryType, uint256 index) external view returns(bool) {
        if(queryType == 1) {
            return increaseIndex.contains(index);
        }

        if(queryType == 2) {
            return decreaseIndex.contains(index);
        }

        return false;
    }
}
