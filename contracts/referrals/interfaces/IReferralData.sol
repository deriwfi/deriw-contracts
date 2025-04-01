// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IInviteStruct.sol";

interface IReferralData is IInviteStruct {
    function addSizeDelta(address user, address token, uint256 amount) external;
    function addFee(
        uint8 uType, 
        bytes32 typeKey, 
        bytes32 key, 
        address user, 
        address token, 
        uint256 fee,
        address indexToken
    ) external;
    function maxRate() external view returns(uint256);
    function getTradeAccountLength(address account) external view returns(uint256);
    function getTradeAccount(address account, uint256 index) external view returns(address);
    function getTradeAccountContains(address account, address user) external view returns(bool);

    function getUserTransactionInfo(
        address user
    ) external view returns(UserTransactionInfo memory); 

    function getDefaultTargetLength() external view returns(uint256);

    function getDefaultTarget(uint256 index) external view returns(Target memory);

    function getUserLevel(address user) external view returns(uint8);

    function getUserAllocateRate(address referral, address user) external view returns(address, uint256);

    function remianFee(address account, address user) external view returns(uint256);

    function replaceInvitation(address oldReferral, address newReferral, address user) external;
}