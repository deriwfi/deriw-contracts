// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../libraries/utils/ReentrancyGuard.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IOStruct.sol";
import "./interfaces/IOrderStruct.sol";
import "../Pendant/interfaces/ISlippage.sol";
import "../blackList/interfaces/IBlackList.sol";
import "../peripherals/interfaces/ITimelock.sol";
import "../referrals/interfaces/IReferralData.sol";
import "../Pendant/interfaces/IPhase.sol";
import "../upgradeability/Synchron.sol";

contract OrderBook is Synchron, ReentrancyGuard, IOStruct, IOrderStruct {
    using SafeERC20 for IERC20;

    bytes32 public constant oneCode = 0x0000000000000000000000000000000000000000000000000000000000000001;
    address public gov;
    address public router;
    address public vault;
    address public usdt;
    address public cancelAccount;
    
    IBlackList public blackList;
    IReferralData public referralData;

    uint256 public minAmount;
    uint256 public initAmount;

    bool public initialized;

    mapping (address => mapping(uint256 => IncreaseOrder)) public increaseOrders;
    mapping (address => uint256) public increaseOrdersIndex;
    mapping (address => mapping(uint256 => DecreaseOrder)) public decreaseOrders;
    mapping (address => uint256) public decreaseOrdersIndex;
    mapping (address => bool) public isPositionKeeper;

    struct CancelOrder {
        address user;
        uint256[] increaseOrderIndexes;
        uint256[] decreaseOrderIndexes;
    } 

    event ExecuteIncreaseOrderEvent(
        uint256 orderIndex,
        address from, 
        address to, 
        uint256 amount, 
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );

    event ExecuteDecreaseOrderEvent(
        uint256 orderIndex,
        address from, 
        address to, 
        uint256 amount, 
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );

    event CreateIncreaseOrderEvent(
        uint256 orderIndex,
        address from, 
        address to, 
        uint256 amount, 
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );

    event CancelIncreaseOrderEvent(
        uint256 orderIndex,
        address from, 
        address to, 
        uint256 amount, 
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );

    event CreateIncreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address purchaseToken,
        uint256 purchaseTokenAmount,
        address collateralToken,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 lever,
        uint256 time
    );

    event CancelIncreaseOrder(
        address indexed operator,
        address indexed account,
        uint256 orderIndex,
        address purchaseToken,
        uint256 purchaseTokenAmount,
        address collateralToken,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold
    );

    event ExecuteIncreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address purchaseToken,
        uint256 purchaseTokenAmount,
        address collateralToken,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionPrice
    );



    event CreateDecreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 lever,
        uint256 time
    );

    event CancelDecreaseOrder(
        address indexed operator,
        address indexed account,
        uint256 orderIndex,
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold
    );

    event ExecuteDecreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionPrice
    );

    event Initialize(
        address _router,
        address _vault,
        address _usdt,
        address _blackList,
        address _referralData
    );


    event UpdateGov(address gov);
    event SetCancelAccount(address account);

    event SetPositionKeeper(address indexed account, bool isActive);
    event SetMinAndInitAmount(uint256 minAmount, uint256 initAmount);

    constructor() {
        initialized = true;
    }

    modifier onlyGov() {
        require(msg.sender == gov, "OrderBook: forbidden");
        _;
    }

    modifier onlyCancel() {
        require(msg.sender == cancelAccount, "not cancelAccount");
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

        gov = msg.sender;
    }

    function setData(
        address _router,
        address _vault,
        address _usdt,
        address _blackList,
        address _referralData
    ) external onlyGov {
        require(
            _router != address(0) &&
            _vault != address(0) &&
            _usdt != address(0) &&
            _blackList != address(0) &&
            _referralData != address(0),
            "addr err"
        );

        router = _router;
        vault = _vault;
        usdt = _usdt;
        blackList = IBlackList(_blackList);
        referralData = IReferralData(_referralData);

        emit Initialize(_router, _vault, _usdt, _blackList, _referralData);
    }

    function setMinAndInitAmount(uint256 _minAmount, uint256 _initAmount) external onlyGov {
        require(_minAmount > 0, "_minAmount err");
        require(_initAmount > 0, "_initAmount err");

        minAmount = _minAmount;
        initAmount = _initAmount;

        emit SetMinAndInitAmount(_minAmount, _initAmount);
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "account err");
        gov = _gov;

        emit UpdateGov(_gov);
    }

    function setCancelAccount(address account) external onlyGov {
        require(account != address(0), "account err");

        cancelAccount = account;

        emit SetCancelAccount(account);
    }

    function setPositionKeeper(address _account, bool _isActive) external onlyGov {
        require(_account != address(0), "_account err");
        
        isPositionKeeper[_account] = _isActive;
        emit SetPositionKeeper(_account, _isActive);
    }


    function createIncreaseOrder(
        address[] memory _path,
        uint256 _amountIn,
        address _indexToken,
        uint256 _sizeDelta,
        address _collateralToken,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold,
        uint256 _lever
    ) external  nonReentrant {
        require(!blackList.isFusing() && !blackList.isStop(), "can not create");
        _validateTriggerPrice(_indexToken, _isLong, _triggerPrice);
        require(_triggerPrice > 0, "_triggerPrice err");
        if(_amountIn == 0 && _sizeDelta == 0) {
            revert("value err");
        }

        ISlippage(IVault(vault).slippage()).validateLever(msg.sender, usdt, _indexToken, _amountIn, _sizeDelta, _isLong);
        IPhase(IVault(vault).phase()).validateSizeDelta(msg.sender, _indexToken, _sizeDelta, _isLong);

        (address _purchaseToken, uint256 _purchaseTokenAmount) = _purchase(_path, _amountIn);

        (,uint256 collateral,,,,,,) = IVault(vault).getPosition(msg.sender, usdt, _indexToken, _isLong);
        if(collateral == 0) {
            require(_purchaseTokenAmount >= initAmount, "amount err");
        }
        if(_sizeDelta > 0) {
            uint256 minAmountToUsdAmount = IVault(vault).tokenToUsdMin(usdt, minAmount);
            require(_sizeDelta >= minAmountToUsdAmount, "OrderBook: insufficient collateral");
        }

        uint256 _orderIndex = _createIncreaseOrder(
            _purchaseToken,
            _purchaseTokenAmount,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            _lever
        );

        _validateCreateIncreaseOrder(_orderIndex, _path, _amountIn);
    }

    function cancelMultiple(
        uint256[] memory _increaseOrderIndexes,
        uint256[] memory _decreaseOrderIndexes
    ) external {
        for (uint256 i = 0; i < _increaseOrderIndexes.length; i++) {
            cancelIncreaseOrder(_increaseOrderIndexes[i]);
        }
        for (uint256 i = 0; i < _decreaseOrderIndexes.length; i++) {
            cancelDecreaseOrder(_decreaseOrderIndexes[i]);
        }
    }

    function cancelMultipleFor(
        address user,
        uint256[] memory _increaseOrderIndexes,
        uint256[] memory _decreaseOrderIndexes
    ) public {
        for (uint256 i = 0; i < _increaseOrderIndexes.length; i++) {
            cancelIncreaseOrderFor(user, _increaseOrderIndexes[i]);
        }
        for (uint256 i = 0; i < _decreaseOrderIndexes.length; i++) {
            cancelDecreaseOrderFor(user, _decreaseOrderIndexes[i]);
        }
    }

    function cancelMultipleAccountOrder(
        CancelOrder[] memory _cancelOrder
    ) external {
        uint256 len = _cancelOrder.length;
        for(uint256 i = 0; i < len; i++) {
            CancelOrder memory cOrder = _cancelOrder[i];
            cancelMultipleFor(cOrder.user, cOrder.increaseOrderIndexes, cOrder.decreaseOrderIndexes);
        }
    }

    function cancelIncreaseOrderFor(address user, uint256 _orderIndex) public onlyPositionKeeper {
        IncreaseOrder memory order = increaseOrders[user][_orderIndex];
        if(order.account != address(0)) {
            _cancelIncreaseOrder(user, _orderIndex);
        }
    } 

    function cancelIncreaseOrder(uint256 _orderIndex) public {
        IncreaseOrder memory order = increaseOrders[msg.sender][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");
        _cancelIncreaseOrder(msg.sender, _orderIndex);
    }

    function executeIncreaseOrder(address _address, uint256 _orderIndex) external onlyPositionKeeper nonReentrant {
        IncreaseOrder memory order = increaseOrders[_address][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");

        ISlippage(IVault(vault).slippage()).validateCreate(order.indexToken);
        IPhase(IVault(vault).phase()).validateSizeDelta(_address, order.indexToken, order.sizeDelta, order.isLong);

        (uint256 currentPrice, ) = validatePositionOrderPrice(
            order.triggerAboveThreshold,
            order.triggerPrice,
            order.indexToken,
            order.isLong,
            true
        );

        emit ExecuteIncreaseOrder(
            order.account,
            _orderIndex,
            order.purchaseToken,
            order.purchaseTokenAmount,
            order.collateralToken,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            currentPrice
        );

        delete increaseOrders[_address][_orderIndex];

        TransferAmountData memory tData = _safeTransfer(order.purchaseToken, vault, order.purchaseTokenAmount);

        emit ExecuteIncreaseOrderEvent(
            _orderIndex, 
            address(this), 
            vault, 
            order.purchaseTokenAmount, 
            tData.beforeAmount, 
            tData.afterAmount, 
            tData.beforeValue, 
            tData.afterValue
        );


        address timelock = IVault(vault).gov();
        ITimelock(timelock).setIsLeverageEnabled(vault, true);
        IRouter(router).pluginIncreasePosition(oneCode, order.account, order.collateralToken, order.indexToken, order.sizeDelta, order.isLong, order.purchaseTokenAmount);
        ITimelock(timelock).setIsLeverageEnabled(vault, false);
    }

    function createDecreaseOrder(
        address _indexToken,
        uint256 _sizeDelta,
        address _collateralToken,
        uint256 _collateralDelta,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold,
        uint256 _lever
    ) public nonReentrant {
        if(_collateralDelta == 0 && _sizeDelta == 0) {
            revert("value err");
        }
        require(!blackList.isStop(), "can not create");
        _validateTriggerPrice(_indexToken, _isLong, _triggerPrice);
        (uint256 size,uint256 collateral,,,,,,) = IVault(vault).getPosition(msg.sender, usdt, _indexToken, _isLong);
        if(collateral == 0) {
            revert("can not create");
        }
        if(_sizeDelta > 0) {
            uint256 minAmountToUsdAmount = IVault(vault).tokenToUsdMin(usdt, minAmount);
            require(
                (_sizeDelta >= minAmountToUsdAmount || _sizeDelta == size), 
                "_sizeDelta err"
            );
        }

        ISlippage(IVault(vault).slippage()).validateRemoveTime(_indexToken);
        _createDecreaseOrder(
            msg.sender,
            _collateralToken,
            _collateralDelta,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            _lever
        );
    }


    function executeDecreaseOrder(address _address, uint256 _orderIndex)  external onlyPositionKeeper nonReentrant {
        DecreaseOrder memory order = decreaseOrders[_address][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");

        // decrease long should use min price
        // decrease short should use max price
        (uint256 currentPrice, ) = validatePositionOrderPrice(
            order.triggerAboveThreshold,
            order.triggerPrice,
            order.indexToken,
            !order.isLong,
            true
        );

        delete decreaseOrders[_address][_orderIndex];

        uint256 amountOut = IRouter(router).pluginDecreasePosition(
            oneCode,
            order.account,
            order.collateralToken,
            order.indexToken,
            order.collateralDelta,
            order.sizeDelta,
            order.isLong,
            address(this)
        );

        TransferAmountData memory tData = _safeTransfer(order.collateralToken, order.account, amountOut);

        emit ExecuteDecreaseOrderEvent(
            _orderIndex, 
            address(this), 
            order.account, 
            amountOut, 
            tData.beforeAmount, 
            tData.afterAmount, 
            tData.beforeValue, 
            tData.afterValue
        );

        emit ExecuteDecreaseOrder(
            order.account,
            _orderIndex,
            order.collateralToken,
            order.collateralDelta,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            currentPrice
        );
    }

    function batchCreateDecreaseOrder(DecreaseOrderFor[] memory orders) external {
        uint256 len = orders.length;
        require(len > 0, "len err");
        for(uint256 i = 0; i < len; i++) {
            DecreaseOrderFor memory order = orders[i];
            createDecreaseOrder(
                order.indexToken,
                order.sizeDelta,
                order.collateralToken,
                order.collateralDelta,
                order.isLong,
                order.triggerPrice,
                order.triggerAboveThreshold,
                order.lever
            );
        }
    }

    function cancelDecreaseOrderFor(address user, uint256 _orderIndex) public onlyPositionKeeper() {
        DecreaseOrder memory order = decreaseOrders[user][_orderIndex];
        if(order.account != address(0)) {
            _cancelDecreaseOrder(user, _orderIndex);
        }
    }

    function cancelDecreaseOrder(uint256 _orderIndex) public {
        DecreaseOrder memory order = decreaseOrders[msg.sender][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");

        _cancelDecreaseOrder(msg.sender, _orderIndex);
    }

    function _validateCreateIncreaseOrder(uint256 _orderIndex, address[] memory _path, uint256 _amountIn) internal {
        address token = _path[0];
        uint256 beforeAmount = getAmount(token, address(this));
        uint256 beforeValue = getAmount(token, msg.sender);
        IRouter(router).pluginTransfer(token, msg.sender, address(this), _amountIn);
        uint256 afterAmount = getAmount(token, address(this));
        uint256 afterValue = getAmount(token, msg.sender);

        emit CreateIncreaseOrderEvent(
            _orderIndex, 
            msg.sender, 
            address(this), 
            _amountIn, 
            beforeAmount, 
            afterAmount, 
            beforeValue, 
            afterValue
        );
    }

    function getAmount(address token, address account) public view returns(uint256) {
        return IERC20(token).balanceOf(account);
    }

    function _purchase(address[] memory _path, uint256 _amountIn) internal view returns(address _purchaseToken, uint256 _purchaseTokenAmount) {
        _purchaseToken = _path[_path.length - 1];
        require(_purchaseToken == usdt, "_purchaseToken err");

        if (_path.length > 1) {
            require(_path[0] == _purchaseToken, "OrderBook: invalid _path");
        } 
        _purchaseTokenAmount = _amountIn;
    }

    function _createIncreaseOrder(
        address _purchaseToken,
        uint256 _purchaseTokenAmount,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold,
        uint256 _lever
    ) private returns(uint256) {
        address _account = msg.sender;
        uint256 _orderIndex = increaseOrdersIndex[msg.sender];
        IncreaseOrder memory order = IncreaseOrder(
            _account,
            _purchaseToken,
            _purchaseTokenAmount,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            _lever,
            block.timestamp
        );

        increaseOrdersIndex[_account] = _orderIndex + 1;
        increaseOrders[_account][_orderIndex] = order;

        emit CreateIncreaseOrder(
            _account,
            _orderIndex,
            _purchaseToken,
            _purchaseTokenAmount,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            _lever,
            order.time
        );    
        return _orderIndex;
    }


    function _cancelDecreaseOrder(address user, uint256 _orderIndex) internal nonReentrant {
        DecreaseOrder memory order = decreaseOrders[user][_orderIndex];
        delete decreaseOrders[user][_orderIndex];

        emit CancelDecreaseOrder(
            msg.sender,
            order.account,
            _orderIndex,
            order.collateralToken,
            order.collateralDelta,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold
        );
    }

    function _cancelIncreaseOrder( address user, uint256 _orderIndex) internal nonReentrant {
        IncreaseOrder memory order = increaseOrders[user][_orderIndex];

        delete increaseOrders[user][_orderIndex];
        TransferAmountData memory tData = _safeTransfer(order.purchaseToken, user, order.purchaseTokenAmount);

        emit CancelIncreaseOrderEvent(
            _orderIndex, 
            address(this), 
            user, 
            order.purchaseTokenAmount, 
            tData.beforeAmount, 
            tData.afterAmount, 
            tData.beforeValue, 
            tData.afterValue
        );

        uint256 triggerPrice = order.triggerPrice;
        bool triggerAboveThreshold = order.triggerAboveThreshold;
        emit CancelIncreaseOrder(
            msg.sender,
            order.account,
            _orderIndex,
            order.purchaseToken,
            order.purchaseTokenAmount,
            order.collateralToken,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            triggerPrice,
            triggerAboveThreshold
        );
    }

    function _createDecreaseOrder(
        address _account,
        address _collateralToken,
        uint256 _collateralDelta,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold,
        uint256 _lever
    ) private {
        uint256 _orderIndex = decreaseOrdersIndex[_account];
        DecreaseOrder memory order = DecreaseOrder(
            _account,
            _collateralToken,
            _collateralDelta,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            _lever,
            block.timestamp
        );
        decreaseOrdersIndex[_account] = _orderIndex + 1;
        decreaseOrders[_account][_orderIndex] = order;

        emit CreateDecreaseOrder(
            _account,
            _orderIndex,
            _collateralToken,
            _collateralDelta,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            _lever,
            order.time
        );
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

    function validatePositionOrderPrice(
        bool _triggerAboveThreshold,
        uint256 _triggerPrice,
        address _indexToken,
        bool _maximizePrice,
        bool _raise
    ) public view returns (uint256, bool) {
        uint256 currentPrice = _maximizePrice
            ? IVault(vault).getMaxPrice(_indexToken) : IVault(vault).getMinPrice(_indexToken);
        bool isPriceValid = _triggerAboveThreshold ? currentPrice > _triggerPrice : currentPrice < _triggerPrice;
        if (_raise) {
            require(isPriceValid, "OrderBook: invalid price for execution");
        }
        return (currentPrice, isPriceValid);
    }

    function getDecreaseOrder(address _account, uint256 _orderIndex)  external view returns (
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 lever,
        uint256 time
    ) {
        DecreaseOrder memory order = decreaseOrders[_account][_orderIndex];
        return (
            order.collateralToken,
            order.collateralDelta,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.lever,
            order.time
        );
    }

    function getIncreaseOrderData(address _account, uint256 _orderIndex) external view returns(IncreaseOrder memory) {
        return increaseOrders[_account][_orderIndex];
    }

    function getIncreaseOrderPara(address _account, uint256 _orderIndex)  external view returns(uint256, uint256) {
        return (increaseOrders[_account][_orderIndex].lever, increaseOrders[_account][_orderIndex].time);
    }

    function getIncreaseOrder(address _account, uint256 _orderIndex)  external view returns (
        address purchaseToken,
        uint256 purchaseTokenAmount,
        address collateralToken,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 lever,
        uint256 time
    ) {
        IncreaseOrder memory order = increaseOrders[_account][_orderIndex];
        return (
            order.purchaseToken,
            order.purchaseTokenAmount,
            order.collateralToken,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.lever,
            order.time
        );
    }
 
    function _validateTriggerPrice(address _indexToken, bool _isLong,uint256 _triggerPrice) internal view {
        uint256 _price = _isLong ? IVault(vault).getMaxPrice(_indexToken) : IVault(vault).getMinPrice(_indexToken);
        require(_price * 10000 >= _triggerPrice, "_triggerPrice err");
    }
}

