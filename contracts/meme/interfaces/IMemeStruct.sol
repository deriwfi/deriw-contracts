// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IMemeStruct {
    struct MemeState {
        uint256 totalDepositAmount;
        uint256 totalGlpAmount;
        uint256 totalUnStakeAmount;
        bool isStake;
    }

    struct MemeUserInfo {
        uint256 depositAmount;
        uint256 glpAmount;
        uint256 unStakeAmount;
    }

    struct MemeEvent {
        address user; 
        address pool; 
        uint256 amount; 
        uint256 lpTokenAmount;
        uint256 beforeAmount; 
        uint256 afterAmount;
        uint256 beforeValue;
        uint256 afterValue;
    }
}