
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IStruct.sol";

interface IFundFactoryV2 is IStruct {

    function authV2() external view returns(address);
    function foundRouterV2() external view returns(address);
    function errContractV2() external view returns(address);
    function poolDataV2() external view returns(address);
    function poolOwner(address account) external view returns(address);   
    function isTokenCreate(address token) external view returns(bool);  
    function setGov(address account) external;
    function setContract(
        address auth_,
        address errContract_,
        address poolData_
    ) external;
}
