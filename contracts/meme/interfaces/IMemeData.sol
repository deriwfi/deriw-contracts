// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "./IMemeStruct.sol";

interface IMemeData is IMemeStruct {
    function createPool(address pool, address token) external;

    function isTokenCreate(address token) external view returns(bool);  

    function isAddMeme(address token) external view returns(bool);  

    function poolToken(address pool) external view returns(address);  

    function tokenToPool(address token) external view returns(address);  

    function glpRewardRouter() external view returns(address);
    
    function lockTime() external view returns(uint256);

    function startTime(address pool) external view returns(uint256); 
    
    function isPoolTokenClose(address account) external view returns(bool);  
    
    function deposit(address user, address pool, uint256 amount) external;

    function claim(address user, address pool, uint256 glpAmount) external;

    function withdraw(address user, address pool, uint256 amount) external;

    function setIsPoolTokenClose(address pool, bool isClose) external;

    function setInitMinAmount(uint256 amount) external;

    function setLockTime(uint256 time) external;

    function initValue(address pool) external view returns(uint256); 

    function getMemeState(address pool) external view returns(MemeState memory);

    function getMemeUserInfo(address pool, address user) external view returns(MemeUserInfo memory);
    
    function getUserDepositPoolNum(address user) external view returns(uint256);

    function getUserDepositPool(address user, uint256 index) external view returns(address);

    function addMemeState(address indexToken) external;
}