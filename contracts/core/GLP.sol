 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract GLP is ERC20 {
    using Address for address;

    address public gov;
    mapping (address => bool) public isMinter;

    constructor () ERC20("Deriw LP", "DLP") {
        gov = msg.sender;
    }
    
    modifier onlyGov() {
        require(msg.sender == gov, "gov err");
        _;
    }

    modifier onlyMinter() {
        require(isMinter[msg.sender], "minter err");
        _;
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "account err");
        gov = _gov;
    }

    function setMinter(address _minter, bool _isActive) external onlyGov {
        isMinter[_minter] = _isActive;
    }

    function mint(address _account, uint256 _amount) external onlyMinter {
        _mint(_account, _amount);
    }

    function burn(address _account, uint256 _amount) external onlyMinter {
        _burn(_account, _amount);
    }
}