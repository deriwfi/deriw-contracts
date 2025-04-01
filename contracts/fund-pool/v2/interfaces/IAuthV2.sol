// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IAuthV2 {
    function getOpAuth(address pool, address account)  external view returns(bool);
    function getTraderAuth(address pool, address account) external view returns(bool);
    function getWhitelistIsIn(address account) external view returns(bool);
    function getTraderIsIn(address pool, address account) external view returns(bool);
    function getOperatorIsIn(address pool, address account) external view returns(bool);
    function setGov(address account) external;
    function setFactory(address factory_) external;
    function addOremoveWhitelist(address[] memory accounts, bool isAdd) external;
    function addOrRemoveOperator(address pool, address[] memory accounts, bool isAdd) external;
    function addOrRemoveTrader(address pool, address[] memory accounts, bool isAdd) external;
}