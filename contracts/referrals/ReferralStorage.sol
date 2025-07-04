// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../upgradeability/Synchron.sol";

contract ReferralStorage is Synchron {
    using EnumerableSet for EnumerableSet.AddressSet;

    address public gov;
    EnumerableSet.AddressSet partnerAccount;


    bool public initialized;

    mapping(address => bool) public isHandler;
    mapping(string => address) public codeOwner;
    mapping(address => string) public ownerCode;
    mapping(address => address) public referral;
    mapping(address => EnumerableSet.AddressSet) secondaryAccount;

    struct RegisterData {
        address account;
        string code;
    }

    event SetHandler(address handler, bool isActive);
    event BatchRegisterCode(RegisterData[] rData);
    event SetTraderReferralCode(address user, address ref, string code);

    modifier onlyHandler() {
        require(isHandler[msg.sender], "ReferralStorage: forbidden");
        _;
    }

    modifier onlyGov() {
        require(msg.sender == gov, "Governable: forbidden");
        _;
    }

    function initialize() external {
        require(!initialized, "has initialized");
        initialized = true;
        gov = msg.sender;
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "_gov err");
        gov = _gov;
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        require(_handler != address(0), "_handler err");

        isHandler[_handler] = _isActive;
        emit SetHandler(_handler, _isActive);
    }

    function setTraderReferralCodeByUser(string memory _code) external {
        _setTraderReferralCode(msg.sender, _code);
    }

    function batchRegisterCode(RegisterData[] memory rData) external onlyHandler {
        uint256 len = rData.length;
        require(len > 0, "length err");
        for(uint256 i = 0; i < len; i++) {
            _registerCode(rData[i].account, rData[i].code);
        }

        emit BatchRegisterCode(rData);
    }

    function _registerCode(address account, string memory code) internal {
        require(bytes(ownerCode[account]).length == 0, "account err");
        require(codeOwner[code] == address(0), "code err");

        codeOwner[code] = account;
        ownerCode[account] = code;
        partnerAccount.add(account);
    }

    function _setTraderReferralCode(address _account, string memory _code) internal {
        require(referral[_account] == address(0), "has referral");
        address ref = codeOwner[_code];
        require(ref != address(0) && _account != ref, "_code err");

        secondaryAccount[ref].add(_account);
        referral[_account] = ref;

        emit SetTraderReferralCode(_account, ref, _code);
    }

    function getPartnerAccountAccountLength() external view returns(uint256) {
        return partnerAccount.length();
    }

    function getPartnerAccountAccount(uint256 index) external view returns(address) {
        return partnerAccount.at(index);
    }  

    function getPartnerAccountAccountIsIn(address user) external view returns(bool) {
        return partnerAccount.contains(user);
    }   

    function getSecondaryAccountLength(address account) external view returns(uint256) {
        return secondaryAccount[account].length();
    }

    function getSecondaryAccount(address account, uint256 index) external view returns(address) {
        return secondaryAccount[account].at(index);
    }  

    function getSecondaryAccountLength(address account, address user) external view returns(bool) {
        return secondaryAccount[account].contains(user);
    }  
}
