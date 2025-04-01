// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./interfaces/IReferralStorage.sol";
import "./interfaces/IReferralData.sol";
import "../upgradeability/Synchron.sol";

contract ReferralStorage is Synchron, IReferralStorage {

    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant BASIS_POINTS = 10000;
    bytes32 public constant zeroCode = 0x0000000000000000000000000000000000000000000000000000000000000000;

    IReferralData public invite;
    address public gov;

    bool public initialized;

    mapping (address => bool) public isHandler;
    mapping (bytes32 => address) public override codeOwners;
    mapping(address => EnumerableSet.AddressSet) secondaryAccount;
    mapping(address => address) public referral;
    mapping(address => bytes32) public owerCode;

    event SetHandler(address handler, bool isActive);
    event SetTraderReferralCode(address account, bytes32 code, address newRef);
    event RegisterCode(address account, bytes32 code);

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

    function setContract(address _invite) external onlyGov() {
        invite = IReferralData(_invite);
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
        emit SetHandler(_handler, _isActive);
    }

    function setTraderReferralCode(address _account, bytes32 _code) external override onlyHandler {
        _setTraderReferralCode(_account, _code);
    }

    function setTraderReferralCodeByUser(bytes32 _code) external {    
        _setTraderReferralCode(msg.sender, _code);
    }

    function registerCode(bytes32 _code) external {
        require(_code != bytes32(0), "ReferralStorage: invalid _code");
        require(codeOwners[_code] == address(0), "ReferralStorage: code already exists");
        require(referral[msg.sender] == address(0), "has be invated");

        bytes32 oldCode = owerCode[msg.sender];
        if(oldCode != zeroCode) {
            codeOwners[oldCode] = address(0);
        }

        codeOwners[_code] = msg.sender;
        owerCode[msg.sender] = _code;
        emit RegisterCode(msg.sender, _code);
    }

    function getTraderReferralInfo(address _account) external override view returns (bytes32, address) {
        address referrer = referral[_account];
        bytes32 code = owerCode[referrer];

        return (code, referrer);
    }

    function _setTraderReferralCode(address _account, bytes32 _code) private {
        require(owerCode[_account] == zeroCode, "has registerCode");

        address newRef = codeOwners[_code];
        require(newRef != address(0) || zeroCode == _code, "_code err");
        address ref =  referral[_account];
        if(zeroCode == _code) {
            require(ref != address(0), "set err");
        }

        secondaryAccount[ref].remove(_account);
        secondaryAccount[newRef].add(_account);
        referral[_account] = newRef;
        invite.replaceInvitation(ref, newRef, _account);

        emit SetTraderReferralCode(_account, _code, newRef);
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
