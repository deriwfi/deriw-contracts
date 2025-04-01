// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IOrderStruct.sol";

interface IOrderBook is IOrderStruct {
    function setBlackList(address blackList_) external;
    function setMinPurchaseTokenAmountUsd(uint256 _minPurchaseTokenAmountUsd) external;

    function getIncreaseOrderPara(address _account, uint256 _orderIndex) external view returns(uint256, uint256);
    function getIncreaseOrder(address _account, uint256 _orderIndex) external view returns (
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

    function getDecreaseOrder(address _account, uint256 _orderIndex) external view returns (
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

    function executeDecreaseOrder(address, uint256) external;
    function executeIncreaseOrder(address, uint256) external;
    function cancelAccount() external view returns(address);

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
    ) external;
    function cancelMultiple(
        uint256[] memory _increaseOrderIndexes,
        uint256[] memory _decreaseOrderIndexes
    ) external;
    function cancelMultipleFor(
        address user,
        uint256[] memory _increaseOrderIndexes,
        uint256[] memory _decreaseOrderIndexes
    ) external;
    function updateIncreaseOrder(uint256 _orderIndex, uint256 _sizeDelta, uint256 _triggerPrice, bool _triggerAboveThreshold, uint256 _lever) external;

    function createDecreaseOrder(
        address _indexToken,
        uint256 _sizeDelta,
        address _collateralToken,
        uint256 _collateralDelta,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold,
        uint256 _lever
    ) external;
    function batchCreateDecreaseOrder(DecreaseOrderFor[] memory orders) external;

    function updateDecreaseOrder(
        uint256 _orderIndex,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold,
        uint256 _lever
    ) external;
}
