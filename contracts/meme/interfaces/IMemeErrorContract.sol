// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;


interface IMemeErrorContract {
    function validateCreatePool(
        address factory,
        address account,
        address token
    ) external view returns(bool);

    function  validateDeposit(
        address router, 
        address user, 
        address pool, 
        uint256 amount
    ) external view returns(uint256);

    function validateClaim(
        address router, 
        address user, 
        address pool, 
        uint256 glpAmount,
        bool isStake
    ) external view returns(bool);

    function validateWithdraw(
        address router, 
        address user, 
        address pool, 
        uint256 amount,
        uint256 haveDeposit,
        bool isStake
    ) external view returns(uint256);

    function validate(address router, address pool) external view  returns(bool);

    function validateSetInitMinAmount(address router, uint256 amount) external view returns(bool);

    function validateRouter(address router) external view returns(bool);

    function getTokenValue(address token, uint256 amount) external view returns(uint256);

    function memeRouter() external view returns(address);

    function coinData() external view returns(address);
}