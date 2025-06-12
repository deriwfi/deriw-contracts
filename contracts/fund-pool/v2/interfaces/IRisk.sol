// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IRisk {
    function totalRiskDeposit(address poolData, address pool, address token, uint256 pid) external view returns(uint256);
    function totalFundDeposit(address poolData, address pool, address token, uint256 pid) external view returns(uint256);
    function getProfitDataLength() external view returns(uint256);
    function profitData(uint256 index) external view returns(address, uint256);
    function profitAccount() external view returns(address);
}