// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./interfaces/IFundFactoryV2.sol";

contract AuthV2 {
    using EnumerableSet for EnumerableSet.AddressSet;

    event AddWhitelist(address indexed account);
    event RemoveWhitelist(address indexed account);
    event AddOperator(address indexed creator, address indexed pool, address account);
    event RemoveOperator(address indexed creator, address indexed pool, address account);
    event AddTrader(address indexed creator, address indexed pool, address account);
    event RemoveTrader(address indexed creator, address indexed pool, address account);

    IFundFactoryV2 public factory;
    EnumerableSet.AddressSet Whitelist;
    EnumerableSet.AddressSet removelist;
    address public gov;

    mapping(address => EnumerableSet.AddressSet) operator;
    mapping(address => EnumerableSet.AddressSet) trader;

    constructor() {
        gov = msg.sender;
    }

    modifier onlyGov() {
        require(gov == msg.sender, "gov err");
        _;
    }

    function setGov(address account) external onlyGov {
        require(account != address(0), "account err");
        gov = account;
    }

    function setFactory(address factory_) external onlyGov {
        factory = IFundFactoryV2(factory_);
    }

    function addOremoveWhitelist(address[] memory accounts, bool isAdd) external onlyGov {
        if(isAdd) {
            _addWhitelist(accounts);
        } else {
            _removeWhitelist(accounts);
        }
    }

    function _addWhitelist(address[] memory accounts) internal {
        for (uint256 i = 0; i < accounts.length; i++) {
            if(!Whitelist.contains(accounts[i])) {
                Whitelist.add(accounts[i]);
                removelist.remove(accounts[i]);
                emit AddWhitelist(accounts[i]);
            }
        }
    }

    function _removeWhitelist(address[] memory accounts) internal  {
        for (uint256 i = 0; i < accounts.length; i++) {
            if(Whitelist.contains(accounts[i])) {
                Whitelist.remove(accounts[i]);
                removelist.add(accounts[i]);
                emit RemoveWhitelist(accounts[i]);
            }
        }
    }

    function getWhitelistNum() external view returns(uint256) {
        return Whitelist.length();
    }

    function getWhitelist(uint256 index) external view returns(address) {
        return Whitelist.at(index);
    }

    function getWhitelistIsIn(address account) external view returns(bool) {
        return Whitelist.contains(account);
    }

    function getRemovelistNum() external view returns(uint256) {
        return removelist.length();
    }

    function getRemovelist(uint256 index) external view returns(address) {
        return removelist.at(index);
    }

    function getRemovelistIsIn(address account) external view returns(bool) {
        return removelist.contains(account);
    }

    function getInList(address account) external view returns(bool) {
        if(Whitelist.contains(account) || removelist.contains(account)) {
            return true;
        }
        return false;
    }

    // *****************************************
    function addOrRemoveOperator(address pool, address[] memory accounts, bool isAdd) external onlyGov  {
        if(isAdd) {
            _addOperator(pool, accounts);
        } else {
            _removeOperator(pool, accounts);
        }
    }

    function _addOperator(address pool, address[] memory accounts) internal {
        for (uint256 i = 0; i < accounts.length; i++) {
            if(!operator[pool].contains(accounts[i])) {
                operator[pool].add(accounts[i]);
                emit AddOperator(msg.sender, pool, accounts[i]);
            }
        }
    }

    function _removeOperator(address pool, address[] memory accounts) internal  {
        for (uint256 i = 0; i < accounts.length; i++) {
            if(operator[pool].contains(accounts[i])) {
                operator[pool].remove(accounts[i]);
                emit RemoveOperator(msg.sender, pool, accounts[i]);
            }
        }
    }

    function getOperatorNum(address pool) external view returns(uint256) {
        return operator[pool].length();
    }

    function getOperator(address pool, uint256 index) external view returns(address) {
        return operator[pool].at(index);
    }

    function getOperatorIsIn(address pool, address account) external view returns(bool) {
        return operator[pool].contains(account);
    }

    function getOpAuth(address pool, address account)  external view returns(bool) {
        if(factory.poolOwner(pool) == account|| operator[pool].contains(account)) {
            return true;
        }
        return false;
    } 

    //******************************* 

    function addOrRemoveTrader(address pool, address[] memory accounts, bool isAdd) external onlyGov  {
        if(isAdd) {
            _addTrader(pool, accounts);
        } else {
            _removeTrader(pool, accounts);
        }
    }

    function _addTrader(address pool, address[] memory accounts) internal {
        for (uint256 i = 0; i < accounts.length; i++) {
            if(!trader[pool].contains(accounts[i])) {
                trader[pool].add(accounts[i]);
                emit AddTrader(msg.sender, pool, accounts[i]);
            }
        }
    }

    function _removeTrader(address pool, address[] memory accounts) internal  {
        for (uint256 i = 0; i < accounts.length; i++) {
            if(trader[pool].contains(accounts[i])) {
                trader[pool].remove(accounts[i]);
                emit RemoveTrader(msg.sender, pool, accounts[i]);
            }
        }
    }

    function getTraderNum(address pool) external view returns(uint256) {
        return trader[pool].length();
    }

    function getTrader(address pool, uint256 index) external view returns(address) {
        return trader[pool].at(index);
    }

    function getTraderIsIn(address pool, address account) external view returns(bool) {
        return trader[pool].contains(account);
    }

    function getTraderAuth(address pool, address account) external view returns(bool) {
        if(factory.poolOwner(pool) == account || trader[pool].contains(account)) {
            return true;
        }
        return false;
    }
}
