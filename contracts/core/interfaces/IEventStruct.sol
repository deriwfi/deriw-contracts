// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./ITransferAmountData.sol";

interface IEventStruct is ITransferAmountData {
    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }

    struct DecreaseEvent {
        bytes32 decreaseKey;
        bytes32 key;
        address account;
        address collateralToken;
        address indexToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
        bool isLong;
        uint256 price;
        uint256 fee;
        uint256 usdOutAfterFee;
        uint256 averagePrice;
        uint256 time;
        uint256 collateral;
        uint256 amountOutAfterFees;
        uint256 afterCollateral;
    }

    struct IncreaseEvent {
        bytes32 createKey; 
        bytes32 key;
        address account;
        address collateralToken;
        address indexToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
        bool isLong;
        uint256 price;
        uint256 fee;
    }

    struct RedCollateral{
        uint8 cType;
        bytes32 _key; 
        address _account; 
        address _collateralToken; 
        address _indexToken; 
        uint256 _collateralDelta; 
        uint256 _sizeDelta; 
        bool _isLong;
    }



    struct ClosePositionEvent {
        address collteraltoken;
        address account;
        address indextoken;
        bool islong;
        bytes32 key;
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
    }

    struct DecreaseEventFor {
        uint8 cType;
        bytes32 typeKey;
        bytes32 key;
        address from; 
        address to; 
        uint256 amount; 
        uint256 beforeAmount; 
        uint256 afterAmount;
        uint256 beforeValue;
        uint256 afterValue;
    }

    struct LiquidateEvent {
        bytes32 key;
        address account;
        address collateralToken;
        address indexToken;
        bool isLong;
        uint256 size;
        uint256 collateral;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 markPrice;
        uint256 averagePrice;
    }
}
