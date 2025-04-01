// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IOrderStruct {
    struct DecreaseOrderFor {
        address indexToken;
        uint256 sizeDelta;
        address collateralToken;
        uint256 collateralDelta;
        bool isLong;
        uint256 triggerPrice;
        bool triggerAboveThreshold;
        uint256 lever;
    }

}