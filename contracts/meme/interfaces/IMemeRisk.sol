// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IMemeRisk {
    function addFeeAmount(address _indexToken, uint256 _index, uint256 _fee) external;
    function fundDeposit(address _indexToken, address _collateralToken, uint256 _index, uint256 _amount) external;
}