// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../core/interfaces/IOrderBook.sol";
import "../core/interfaces/IOStruct.sol";
import "../core/interfaces/IOB.sol";

contract OrderBookReader is IOStruct {
    struct Vars {
        uint256 i;
        uint256 index;
        address account;
        uint256 uintLength;
        uint256 addressLength;
    }

    function getIncreaseOrders(
        address payable _orderBookAddress, 
        address _account,
        uint256[] memory _indices
    ) external view returns (uint256[] memory, address[] memory) {
        Vars memory vars = Vars(0, 0, _account, 7, 3);

        uint256[] memory uintProps = new uint256[](vars.uintLength * _indices.length);
        address[] memory addressProps = new address[](vars.addressLength * _indices.length);
        
        IOB ob = IOB(_orderBookAddress);

        while (vars.i < _indices.length) {
            vars.index = _indices[vars.i];
            IncreaseOrder memory order = ob.getIncreaseOrderData(_account, vars.index);
            uintProps[vars.i * vars.uintLength] = order.purchaseTokenAmount;
            uintProps[vars.i * vars.uintLength + 1] = order.sizeDelta;
            uintProps[vars.i * vars.uintLength + 2] = order.isLong ? 1 : 0;
            uintProps[vars.i * vars.uintLength + 3] = order.triggerPrice;
            uintProps[vars.i * vars.uintLength + 4] = order.triggerAboveThreshold ? 1 : 0;
            uintProps[vars.i * vars.uintLength + 5] = order.lever;
            uintProps[vars.i * vars.uintLength + 6] = order.time;

            addressProps[vars.i * vars.addressLength] = order.purchaseToken;
            addressProps[vars.i * vars.addressLength + 1] = order.collateralToken;
            addressProps[vars.i * vars.addressLength + 2] = order.indexToken;

            vars.i++;
        }

        return (uintProps, addressProps);
    }

    function getDecreaseOrders(
        address payable _orderBookAddress, 
        address _account,
        uint256[] memory _indices
    ) external view returns (uint256[] memory, address[] memory) {
        Vars memory vars = Vars(0, 0, _account, 7, 2);

        uint256[] memory uintProps = new uint256[](vars.uintLength * _indices.length);
        address[] memory addressProps = new address[](vars.addressLength * _indices.length);

        IOrderBook orderBook = IOrderBook(_orderBookAddress);

        while (vars.i < _indices.length) {
            vars.index = _indices[vars.i];
            (
                address collateralToken,
                uint256 collateralDelta,
                address indexToken,
                uint256 sizeDelta,
                bool isLong,
                uint256 triggerPrice,
                bool triggerAboveThreshold,
                uint256 lever,
                uint256 time
                // uint256 executionFee
            ) = orderBook.getDecreaseOrder(vars.account, vars.index);

            uintProps[vars.i * vars.uintLength] = uint256(collateralDelta);
            uintProps[vars.i * vars.uintLength + 1] = uint256(sizeDelta);
            uintProps[vars.i * vars.uintLength + 2] = uint256(isLong ? 1 : 0);
            uintProps[vars.i * vars.uintLength + 3] = uint256(triggerPrice);
            uintProps[vars.i * vars.uintLength + 4] = uint256(triggerAboveThreshold ? 1 : 0);
            uintProps[vars.i * vars.uintLength + 5] = lever;
            uintProps[vars.i * vars.uintLength + 6] = time;

            addressProps[vars.i * vars.addressLength] = (collateralToken);
            addressProps[vars.i * vars.addressLength + 1] = (indexToken);

            vars.i++;
        }

        return (uintProps, addressProps);
    }
}
