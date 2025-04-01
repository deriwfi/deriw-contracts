// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../access/Governable.sol";
import "./interfaces/IInviteStruct.sol";
import "./interfaces/IReferralData.sol";

contract ValidateReferral is Governable, IInviteStruct {
    IReferralData public invite;
    uint256 public constant baseRate = 10000;

    function setContract(address _invite) external onlyGov() {
        invite = IReferralData(_invite);
    }

    function validateDefaultSetTarget(
        address _invite, 
        Target[] memory _target
    ) external view returns(bool) {
        uint256 len1 = invite.getDefaultTargetLength();
        uint256 len = _target.length;
        require(len >= len1, "default err");

        return _validateSetTarget(_invite, _target);
    }

    function _validateSetTarget(
        address _invite, 
        Target[] memory _target
    ) internal view returns(bool) {
        validatte(_invite);
        uint256 len = _target.length;
        require(len > 0, "length err");
        if(len == 1) {
            require(_target[0].levelRate <= baseRate, "rate err");
        } else {
            for(uint256 i = 0; i < len-1; i++) {
                Target memory tgt1 = _target[i];
                Target memory tgt2 = _target[i+1];
                require(
                    tgt1.levelSizeDelta < tgt2.levelSizeDelta &&
                    tgt1.levelTradeNum < tgt2.levelTradeNum &&
                    tgt1.levelRate < tgt2.levelRate &&
                    tgt2.levelRate <= baseRate,
                    "set err"
                );
            }
        }

        return true;
    }

    function validatePromoted(
        address _invite, 
        address account
    ) external view returns(uint8 level, bool isUpdate) {
        validatte(_invite);
        uint256 num = invite.getTradeAccountLength(account);
        UserTransactionInfo memory uInfo = invite.getUserTransactionInfo(account);
        uint256 value = uInfo.sizeDelta + uInfo.secondarySizeDelta;

        uint256 len = invite.getDefaultTargetLength();
        level = invite.getUserLevel(account);
        for(uint256 i = len - 1; i > 0; i--) {
            Target memory target = invite.getDefaultTarget(i);
            uint256 _level = i + 1;
            if(level >= _level) {
                break;
            }
            if(num >= target.levelTradeNum && value >= target.levelSizeDelta) {
                level = uint8(_level);
                isUpdate = true;
            }
        }
    }

    function validateSettlement(
        address _invite, 
        address refer
    ) external view returns(uint256, uint256) {
        validatte(_invite);

        UserTransactionInfo memory uInfo = invite.getUserTransactionInfo(refer);
        uint256 totalFee = uInfo.secondaryFee;

        uint8 level = invite.getUserLevel(refer);
        uint256 rate = invite.getDefaultTarget(level-1).levelRate;  
        uint256 accFee = totalFee * rate / baseRate;

        return (accFee, totalFee);
    }

    function calculate(
        address _invite, 
        address referral,       
        address user, 
        uint256 totalFee,
        uint256 accFee,
        uint256 fee,
        uint256 rFee
    ) external view returns(uint256, uint256, uint256, uint256, uint256) {
        validatte(_invite);

        (, uint256 _rate) = invite.getUserAllocateRate(referral, user);
        uint256 accUserFee = accFee * _rate / baseRate;
        uint256 accRefFee = accFee - accUserFee;

        uint256 userFee = accUserFee * fee / totalFee;
        uint256 remainFee = accUserFee * rFee / totalFee;
        uint256 tFee = fee + rFee;
        uint256 refFee = accRefFee * tFee / totalFee;
        uint256 _fee = fee;
        uint256 pFee;

        if(tFee > userFee + refFee + remainFee) {
            pFee = tFee - userFee - refFee - remainFee;
        }
        
        return (userFee, refFee, pFee, _fee, remainFee);
    }

    function validatte(address _invite) public view returns(bool) {
        require(_invite == address(invite), "invite err");

        return true;
    }
}