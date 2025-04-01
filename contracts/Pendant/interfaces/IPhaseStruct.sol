// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IPhaseStruct {
    struct TokenBase {
        address token;
        uint256 rate;
    }   

    struct UserData {
        bytes32 longkey;
        bytes32 shortKey;
        uint256 longLastTime;
        uint256 shortLastTime;
        bool isLongSet;
        bool isShortSet;
    }

    struct TokenData {
        address user;
        uint256 maxLeverage;
        uint256 maxLongSize;
        uint256 maxShortSize;
    }
}