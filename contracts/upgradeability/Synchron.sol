// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Synchron{
    /**
    * @notice Administrator for this contract
    */
    address public admin;
    /**
    * @notice Active brains of Knowhere
    */
    address public oldImplementation;

    /**
    * @notice Pending brains of Knowhere
    */
    address public implementation;
}