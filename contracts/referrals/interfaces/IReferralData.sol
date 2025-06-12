// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IReferralData  {
    function setGov(address _gov) external;

    function setContract(address _referralStorage) external;

    function setOperator(address account, bool isAdd) external;

    function setHander(address account, bool isAdd) external;

    function addFee(
        uint8 uType, 
        bytes32 typeKey, 
        bytes32 key, 
        address user, 
        address token, 
        uint256 fee,
        address indexToken
    ) external;

    function getAmount(address token, address account) external view returns(uint256);
}