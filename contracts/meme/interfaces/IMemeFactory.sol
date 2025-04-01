// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;


interface IMemeFactory {
    function memeErrorContract() external view returns(address);
    function memeData() external view returns(address);
    function poolOwner(address account) external view returns(address);   

    function setGov(address account) external;
    function setContract(
        address errContract_,
        address memeData_
    ) external;

    function isAddMeme(address token) external view returns(bool);  
    
    function getWhitelistNum() external view returns(uint256);

    function getWhitelist(uint256 index) external view returns(address);

    function getWhitelistIsIn(address account) external view returns(bool);

    function getRemovelistNum() external view returns(uint256);

    function getRemovelist(uint256 index) external view returns(address);

    function getRemovelistIsIn(address account) external view returns(bool);

    function operator(address account) external view returns(bool);

    function trader(address account) external view returns(bool);
    
    function gov() external view returns(address);
}