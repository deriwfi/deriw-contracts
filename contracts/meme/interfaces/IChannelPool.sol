// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IChannelPool {
    function approve(address account, address token, uint256 amount) external;
}