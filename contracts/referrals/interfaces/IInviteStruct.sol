// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IInviteStruct {
    struct UserAllocateInfo {
        uint256 allocateRate;
        bool isAllocate;
    }

    struct UserRate {
        address user;
        uint256 allocateRate;
    }

    struct UserTransactionInfo {
        uint256 sizeDelta;
        uint256 secondarySizeDelta;
        uint256 fee;
        uint256 secondaryFee;
        uint256 haveFee;
        uint256 haveSecondaryFee;
        uint256 secondaryActClaim;
        uint256 claimFee;
    }

    struct Target {
        uint256 levelSizeDelta;
        uint256 levelTradeNum;
        uint256 levelRate;
    }

    struct ProFee {
        uint256 fee;
        uint256 haveClaim;
        uint256 actClaim;
    }

    struct TransferEvent {
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
}
