// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "./IInviteStruct.sol";

interface IValidateReferral is IInviteStruct {
    function validateDefaultSetTarget(
        address _invite, 
        Target[] memory _target
    ) external view returns(bool);


    function validatePromoted(
        address _invite, 
        address account
    ) external view returns(uint8 level, bool isUpdate);

    function validateSettlement(
        address _invite, 
        address refer
    ) external view returns(uint256, uint256);

    function calculate(
        address _invite,   
        address referral,       
        address user, 
        uint256 totalFee,
        uint256 accFee,
        uint256 fee,
        uint256 rFee
    ) external view returns(uint256, uint256, uint256, uint256, uint256);
}