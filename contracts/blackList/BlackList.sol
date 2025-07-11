// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


contract BlackList is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    
    EnumerableSet.AddressSet operators;

    bool public isFusing;
    bool public isStop;

    event SetFusing(bool _isFusing);    
    event SeStop(bool _isStop);    
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

    function setStop() external onlyOwner {
        require(!isStop, "has stop");
        isStop = true;

        emit SeStop(true);
    }

    function setStart() external onlyOwner {
        require(isStop, "has start");
        isStop = false;

        emit SeStop(false);
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
