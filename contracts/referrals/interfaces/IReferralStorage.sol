// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IReferralStorage {
    
    function zeroCode() external view returns (bytes32);
    function owerCode(address account) external view returns (bytes32);
    function codeOwners(bytes32 _code) external view returns (address);
    function getTraderReferralInfo(address _account) external view returns (bytes32, address);
    function setTraderReferralCode(address _account, bytes32 _code) external;

    function getSecondaryAccountLength(address account) external view returns(uint256);

    function getSecondaryAccount(address account, uint256 index) external view returns(address);

    function getSecondaryAccountLength(address account, address user) external view returns(bool);

    function referral(address account) external view returns (address);
}
