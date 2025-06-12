// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IReferralStorage {
    function setGov(address _gov) external;
    function setContract(address _invite) external;
    function setHandler(address _handler, bool _isActive) external;
    function ownerCode(address account) external view returns (string memory);
    function codeOwners(string memory _code) external view returns (address);
    function getPartnerAccountAccountLength(address account) external view returns(uint256);
    function getPartnerAccountAccount(address account, uint256 index) external view returns(address);
    function getPartnerAccountAccountIsIn(address account, address user) external view returns(bool);
}
