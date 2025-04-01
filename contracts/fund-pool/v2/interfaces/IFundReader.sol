// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IFundReader { 
    function setContract(
        address vault_,
        address factoryV2_,
        address poolDataV2_,
        address phase_
    ) external;

    function getPrice(address token) external view returns(uint256);
    function isGlpAuth(address pool) external view returns(bool);
    function vault() external view returns(address);
    function getPidValue(address tokenOut, uint256 glpAmount) external view returns(uint256);
    function getLpValue(address pool, uint256 pid, address tokenOut, uint256 glpAmount) external view returns(uint256);

    function getDepositLpAmount(
        address pool, 
        uint256 pid,
        uint256 amount,
        bool isNext
    ) external view returns(uint256);

    function getCompoundAmountFormPrevious(address pool, uint256 pid) external view returns(uint256);

    function getUserCompoundAmount(
        address pool, 
        address user,
        uint256 pid
    ) external view returns(uint256, uint256, bool);

    function getOutAmount(address tokenOut, uint256 glpAmount) external view returns(uint256);

    function getTokenValue(address token, uint256 amount) external view returns(uint256);

    function getCurrPool() external view returns(address);

    function getLastPool() external view returns(address);
}