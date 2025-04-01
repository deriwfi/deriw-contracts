// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IBlackList {
    function getBlackListAddressIsIn(address account) external view returns(bool);
    function isFusing() external view returns(bool);
}