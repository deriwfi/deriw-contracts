// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IStruct {
    struct FundInfoV2 {
        uint256 startTime;
        uint256 endTime;
        uint256 lockEndTime;
    }

    struct FoundStateV2 {
        uint256 currFundraisingAmount;
        uint256 actAmount;
        uint256 depositAmount;
        uint256 totalLpAmount;
        uint256 totalNextLpAmount;
        uint256 glpAmount;
        uint256 outAmount;
        uint256 needCompoundAmount;
        uint256 actCompoundAmount;
        uint256 fundraisingValue;
        uint256 userAmount;
        bool isGet;
        bool isFundraise;
        bool isAllResubmit;
        bool isClaim;
    }

    struct UserInfoV2 {
        uint256 fundAmount;
        uint256 lpAmount;
        uint256 nextLpAmount;
        uint256 claimAmount;
        uint256 depositID;
        bool isUpdate;
        bool isResubmit;
        bool isClaim;

    }

    struct UserPerInfo {
        uint256 fundAmount;
        uint256 lpAmount;
        uint256 depositTime;
        bool isLastIn;
    }

    struct TxInfo {
        string name;
        string describe;
        string website;
        uint256 minDepositAmount;
        uint256 txRate;
        uint256 fundraisingAmount;
    }

    struct DepositEvent {
        address sender;
        address user; 
        address pool; 
        uint256 pid;
        uint256 amount; 
        uint256 lpTokenAmount;
        uint256 time;
        bool isResubmit;
        bool isLastIn;
        uint256 beforeAmount; 
        uint256 afterAmount;
        uint256 beforeValue;
        uint256 afterValue;
    }

    struct ClaimEvent {
        address user; 
        address pool; 
        uint256 pid; 
        uint256 amount; 
        uint256 lessLp;
        uint256 beforeAmount; 
        uint256 afterAmount;
        uint256 beforeValue;
        uint256 afterValue;
    }

}