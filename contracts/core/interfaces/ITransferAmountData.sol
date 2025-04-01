// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ITransferAmountData {
    struct TransferAmountData {
        uint256 beforeAmount; 
        uint256 afterAmount;
        uint256 beforeValue;
        uint256 afterValue;
    }
}