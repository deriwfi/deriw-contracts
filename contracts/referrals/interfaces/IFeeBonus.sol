// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IFeeBonus {
    function addFeeAmount(address indexToken, uint8 addType, uint256 amount) external;
    function claimFeeAmount(address account) external returns(uint256, uint256);
    function claimMemeFeeAmount(address account) external returns(uint256);
    function feeAmount(address account) external view returns(uint256);
    function phasefeeAmount(address account) external view returns(uint256);
}