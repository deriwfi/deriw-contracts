// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.0;

import "./Synchron.sol";

contract Proxy is Synchron{
    event NewImplementation(address oldImplementation, address newImplementation);
    event NewAdmin(address oldAdmin, address newAdmin);

    receive() external payable {
        //assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    constructor() {
        // Set admin to caller
        admin = msg.sender;
    }

    function setImplementation(address newPendingImplementation) external {
        require(admin == msg.sender,"KnowhereProxy:not permit");
        require(newPendingImplementation != address(0), "newPendingImplementation err");

        if(implementation != address(0)) {
            oldImplementation = implementation;
        } 

        implementation = newPendingImplementation;

        emit NewImplementation(oldImplementation, implementation);
    }

    function updateAdmin(address _admin) external {
        require(admin == msg.sender,"KnowhereProxy:not permit");
        admin = _admin;
    }

    /**
     * @dev Delegates execution to an implementation contract.
     * It returns to the external caller whatever the implementation returns
     * or forwards reverts.
     */
    fallback() payable external {
        // delegate all other functions to current implementation
        (bool success, ) = implementation.delegatecall(msg.data);

        assembly {
              let free_mem_ptr := mload(0x40)
              returndatacopy(free_mem_ptr, 0, returndatasize())

              switch success
              case 0 { revert(free_mem_ptr, returndatasize()) }
              default { return(free_mem_ptr, returndatasize()) }
        }
    }

    function withdrawETH(address account, uint256 amount) external {
        require(admin == msg.sender,"KnowhereProxy:not permit");
        require(account != address(0), "account err");
        require(address(this).balance >= amount, "amount err");

        payable(account).transfer(amount);
    }
}
