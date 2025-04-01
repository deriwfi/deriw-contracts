// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


contract BlackList is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    
    EnumerableSet.AddressSet operators;
    EnumerableSet.AddressSet blackListAddress;

    bool public isFusing;

    event AddBlackListAddress(address indexed account);
    event RemoveBlackListAddress(address indexed account);
    event SetFusing(bool _isFusing);    
    event SetOperator(address _operator, bool isAdd);

    constructor(address _operator) {
        require(_operator != address(0), "operator err");
        operators.add(_operator);
    }

    modifier onlyAuth {
        require(operators.contains(msg.sender) || msg.sender == owner(), "no auth");
        _;
    }

    function setOperator(address _operator, bool isAdd) external onlyOwner {
        require(_operator != address(0), "operator err");
        if(isAdd) {
            operators.add(_operator);
        } else {
            operators.remove(_operator);
        }


        emit SetOperator(_operator, isAdd);
    }


    function setBlackList(address[] memory accounts, bool isAdd) external onlyAuth() {
        if(isAdd) {
            _addBlackListAddress(accounts);
        } else {
            _removeBlackListAddress(accounts);
        }
    }

    function setOpenFusing() external onlyAuth {
        require(!isFusing, "has open");
        isFusing = true;

        emit SetFusing(true);
    }

    function setCloseFusing() external onlyAuth {
        require(isFusing, "has close");
        isFusing = false;

        emit SetFusing(false);
    }

    function _addBlackListAddress(address[] memory accounts) internal {
        for (uint256 i = 0; i < accounts.length; i++) {
            if(!blackListAddress.contains(accounts[i])) {
                blackListAddress.add(accounts[i]);
                emit AddBlackListAddress(accounts[i]);
            }
        }
    }

    function _removeBlackListAddress(address[] memory accounts) internal  {
        for (uint256 i = 0; i < accounts.length; i++) {
            if(blackListAddress.contains(accounts[i])) {
                blackListAddress.remove(accounts[i]);
                emit RemoveBlackListAddress(accounts[i]);
            }
        }
    }

    function getBlackListAddressNum() external view returns(uint256) {
        return blackListAddress.length();
    }

    function getBlackListAddress(uint256 index) external view returns(address) {
        return blackListAddress.at(index);
    }

    function getBlackListAddressIsIn(address account) external view returns(bool) {
        return blackListAddress.contains(account);
    }

    function getOperatorsLength() external view returns(uint256) {
        return operators.length();
    }

    function getOperator(uint256 index) external view returns(address) {
        return operators.at(index);
    }

    function getOperatorsContains(address account) external view returns(bool) {
        return operators.contains(account);
    }
}
