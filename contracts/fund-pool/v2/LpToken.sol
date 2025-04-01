// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LpToken is ERC20 {
    using SafeERC20 for IERC20;
    using Address for address;    
    
    address public governance;
    mapping (address => bool) public minters;

    constructor (string memory name, string memory symbol) 
        ERC20(name, symbol) 
    {
        governance = msg.sender;
    }

    function mint(address account, uint256 amount) external {
        require(minters[msg.sender], "!minter");
        _mint(account, amount);
    }

    function burn(uint256 _amount) external  {
        _burn(msg.sender, _amount);
    }
  
    function setGovernance(address _governance) external {
        require(msg.sender == governance, "!governance");
        governance = _governance;
    }
    
    function addMinter(address _minter) external {
        require(msg.sender == governance, "!governance");
        minters[_minter] = true;
    }
    
    function removeMinter(address _minter) external {
        require(msg.sender == governance, "!governance");
        minters[_minter] = false;
    }
}