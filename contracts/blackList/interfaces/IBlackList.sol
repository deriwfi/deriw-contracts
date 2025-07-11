// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IBlackList {
    function isFusing() external view returns(bool);
    function isStop() external view returns(bool);
}