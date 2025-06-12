// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


interface IArbSys {
    function withdrawEth(address destination) external payable returns (uint256);
}