// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./interfaces/IFundFactoryV2.sol";
import "./interfaces/IErrorContractV2.sol";
import "./interfaces/IFundReader.sol";
import "./interfaces/IAuthV2.sol";
import "./interfaces/IFundRouterV2.sol";
import "./interfaces/IPoolDataV2.sol";
import "./interfaces/IFundPoolTimeLokTarget.sol";
import "./interfaces/IStruct.sol";

contract FundPoolTimeLok is IStruct, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public nextAdminSetID = 1;
    uint256 public constant MAX_BUFFER = 5 days;
    uint256 public buffer;

    address public admin;

	IAuthV2 public authV2;
    IFundFactoryV2 public foundFactoryV2;
    IPoolDataV2 public poolDataV2;
    IErrorContractV2 public errorContractV2;
    IFundRouterV2 public foundRouterV2;
    IFundReader public foundReader;
    EnumerableSet.AddressSet signature;

    mapping(address => mapping(bytes32 => bool)) public isSign;
    mapping(bytes32 => uint256) public comNum;
    mapping (bytes32 => uint256) public pendingActions;

    struct Sig {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    event ClearAction(bytes32 action);
    event SignalPendingAction(bytes32 action);
    event SignalSetAdmin(address _admin, bytes32 action);
    event Confirm(address singer, bytes32 action, uint256 num, bool isAll);
    event SetAdmin(address _admin, bytes32 action);
    event SignalSetGov(address target, address gov, bytes32 action);
    event SignalSetAuthFactory(address auth, address factory_ , bytes32 action);
    event SignalAuthAddOremoveWhitelist(address[] accounts, bool isAdd, bytes32 action);
    event SignalAuthAddOrRemoveOperator(address pool, address[] accounts, bool isAdd, bytes32 action);

    event SignalSetContract(
        address authV2_,
        address foundFactoryV2_,
        address poolDataV2_,
        address errorContractV2_,
        address foundRouterV2_,
        address foundReader_,
        bytes32 action
    );

    event SignalAuthAddOrRemoveTrader(
        address pool, 
        address[] accounts,
        bool isAdd, 
        bytes32 action
    );

    event SignalPoolDataV2Contract(
        address factoryV2_,
        address errContractV2_,
        address glpRewardRouter_,
        bytes32 action
    );

    event SignalErrorContractV2Contract(
        address auth_,
        address factory_,
        address poolData_,
        address router_,
        address foundReader_,
        bytes32 action
    );

    event SignalFoundReaderContract(
        address vault_,
        address factoryV2_,
        address poolDataV2_,
        address phase_,
        bytes32 action
    );

    event SignalFoundRouterV2Contract(
        address auth_,
        address factory_,
        address poolData_,
        bytes32 action
    );

    event SignalfoundFactoryV2Contract(
        address auth_,
        address errContract_,
        address poolData_,
        bytes32 action
    );

    constructor(
        address[] memory signature_,
        address _admin,
        uint256 _buffer
    ) {
        _setSignature(signature_);

        require(_admin != address(0), "admin err");
        admin = _admin;
        buffer = _buffer;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Timelock: forbidden");
        _;
    }

    function signalSetAdmin(address _admin) external onlyOwner {
        bytes32 action = getAdminAction(_admin);
        _setPendingAction(action);
        emit SignalSetAdmin(_admin, action);
    }

    function batchConfirm(bytes32 action, Sig[] memory sign) external {
        require(sign.length > 0, "length err");
        for(uint256 i = 0; i < sign.length; i ++) {
            confirm(action, sign[i]);
        }
    }

    function confirm(bytes32 action, Sig memory sign) public {
        address singer = validateSign(action, sign);
        isSign[singer][action] = true;
        comNum[action] += 1;

        if(comNum[action] < signature.length()) {
            emit Confirm(singer, action, comNum[action], false);
        } else {
            emit Confirm(singer, action, comNum[action], true);
        }
    }

    function setAdmin(address _admin) external onlyOwner {
        bytes32 action = getAdminAction(_admin);
        _validateAction(action);
        _clearAction(action);
        require(comNum[action] == signature.length(), "not all sign");

        nextAdminSetID++;
        admin = _admin;

        emit SetAdmin(_admin, action);
    }

    function signalSetContract(
        address authV2_,
        address foundFactoryV2_,
        address poolDataV2_,
        address errorContractV2_,
        address foundRouterV2_,
        address foundReader_
    ) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setContract", authV2_, foundFactoryV2_, poolDataV2_, errorContractV2_, foundRouterV2_, foundReader_));
        _setPendingAction(action);

        emit SignalSetContract(authV2_, foundFactoryV2_, poolDataV2_, errorContractV2_, foundRouterV2_, foundReader_, action);
    }


    function setContract(
        address authV2_,
        address foundFactoryV2_,
        address poolDataV2_,
        address errorContractV2_,
        address foundRouterV2_,
        address foundReader_
    ) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setContract", authV2_, foundFactoryV2_, poolDataV2_, errorContractV2_, foundRouterV2_, foundReader_));

        _validateAction(action);
        _clearAction(action);

        authV2 = IAuthV2(authV2_);
        foundFactoryV2 = IFundFactoryV2(foundFactoryV2_);
        poolDataV2 = IPoolDataV2(poolDataV2_);
        errorContractV2 = IErrorContractV2(errorContractV2_);
        foundRouterV2 =  IFundRouterV2(foundRouterV2_);
        foundReader = IFundReader(foundReader_);
    }


    function setBuffer(uint256 _buffer) external onlyAdmin {
        require(_buffer <= MAX_BUFFER, "Timelock: invalid _buffer");
        require(_buffer > buffer, "Timelock: buffer cannot be decreased");
        buffer = _buffer;
    }

    function signalSetGov(address _target, address _gov) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setGov", _target, _gov));
        _setPendingAction(action);
        emit SignalSetGov(_target, _gov, action);
    }

    function setGov(address _target, address _gov) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setGov", _target, _gov));
        _validateAction(action);
        _clearAction(action);
        IFundPoolTimeLokTarget(_target).setGov(_gov);
    }

    function signalSetAuthFactory(address factory_) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setFactory", factory_));
        _setPendingAction(action);

        emit SignalSetAuthFactory(address(authV2), factory_, action);
    }

    function setAuthFactory(address factory_) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setFactory", factory_));
        _validateAction(action);
        _clearAction(action);
        authV2.setFactory(factory_);
    }

    function signalAuthAddOremoveWhitelist(address[] memory accounts, bool isAdd) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("addOremoveWhitelist", accounts, isAdd));
        _setPendingAction(action);

        emit SignalAuthAddOremoveWhitelist(accounts, isAdd, action);
    }

    function setAuthAddOremoveWhitelist(address[] memory accounts, bool isAdd) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("addOremoveWhitelist", accounts, isAdd));
        _validateAction(action);
        _clearAction(action);
        authV2.addOremoveWhitelist(accounts, isAdd);
    }

    function signalAuthAddOrRemoveTrader(address pool, address[] memory accounts, bool isAdd) external {
        require(foundFactoryV2.poolOwner(pool) == msg.sender, "pool err");
        bytes32 action = keccak256(abi.encodePacked("addOrRemoveTrader", pool, accounts, isAdd));
        
        _setPendingAction(action);

        emit SignalAuthAddOrRemoveTrader(pool, accounts, isAdd, action);
    }

    function setAuthAddOrRemoveTrader(address pool, address[] memory accounts, bool isAdd) external {
        require(foundFactoryV2.poolOwner(pool) == msg.sender, "pool err");
        bytes32 action = keccak256(abi.encodePacked("addOrRemoveTrader", pool, accounts, isAdd));

        _validateAction(action);
        _clearAction(action);
        authV2.addOrRemoveTrader(pool, accounts, isAdd);
    }


//******************* */
    function signalAuthAddOrRemoveOperator(address pool, address[] memory accounts, bool isAdd) external {
        require(foundFactoryV2.poolOwner(pool) == msg.sender, "pool err");
        bytes32 action = keccak256(abi.encodePacked("addOrRemoveOperator", pool, accounts, isAdd));
        
        _setPendingAction(action);

        emit SignalAuthAddOrRemoveOperator(pool, accounts, isAdd, action);
    }

    function setAuthAddOrRemoveOperator(address pool, address[] memory accounts, bool isAdd) external {
        require(foundFactoryV2.poolOwner(pool) == msg.sender, "pool err");
        bytes32 action = keccak256(abi.encodePacked("addOrRemoveOperator", pool, accounts, isAdd));

        _validateAction(action);
        _clearAction(action);
        authV2.addOrRemoveOperator(pool, accounts, isAdd);
    }

    function signalPoolDataV2Contract(
        address factoryV2_,
        address errContractV2_,
        address glpRewardRouter_,
        address feeBonus_,
        address vault_
    ) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setContract", factoryV2_, errContractV2_, glpRewardRouter_, feeBonus_, vault_));
        
        _setPendingAction(action);

        emit SignalPoolDataV2Contract(factoryV2_, errContractV2_, glpRewardRouter_, action);
    }

    function setPoolDataV2Contract(
        address factoryV2_,
        address errContractV2_,
        address glpRewardRouter_,
        address feeBonus_,
        address vault_
    ) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setContract", factoryV2_, errContractV2_, glpRewardRouter_, feeBonus_, vault_));

        _validateAction(action);
        _clearAction(action);

        poolDataV2.setContract(factoryV2_, errContractV2_, glpRewardRouter_, feeBonus_, vault_);
    }


    function signalfoundFactoryV2Contract(
        address auth_,
        address errContract_,
        address poolData_
    ) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setContract", auth_, errContract_, poolData_));
        
        _setPendingAction(action);

        emit SignalfoundFactoryV2Contract(auth_, errContract_, poolData_, action);
    }

    function setfoundFactoryV2Contract(
        address auth_,
        address errContract_,
        address poolData_
    ) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setContract", auth_, errContract_, poolData_));

        _validateAction(action);
        _clearAction(action);

        foundFactoryV2.setContract(auth_, errContract_, poolData_);
    }


    function signalErrorContractV2Contract(
        address auth_,
        address factory_,
        address poolData_,
        address router_,
        address foundReader_
    ) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setContract", auth_, factory_, poolData_, router_, foundReader_));
        
        _setPendingAction(action);

        emit SignalErrorContractV2Contract(auth_, factory_, poolData_, router_, foundReader_, action);
    }

    function setErrorContractV2Contract(
        address auth_,
        address factory_,
        address poolData_,
        address router_,
        address foundReader_
    ) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setContract", auth_, factory_, poolData_, router_, foundReader_));
        
        _validateAction(action);
        _clearAction(action);

        errorContractV2.setContract(auth_, factory_, poolData_, router_, foundReader_);
    }

    function signalFoundReaderContract(
        address vault_,
        address factoryV2_,
        address poolDataV2_,
        address phase_
    ) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setContract", vault_, factoryV2_, poolDataV2_, phase_));
        
        _setPendingAction(action);

        emit SignalFoundReaderContract(vault_, factoryV2_,poolDataV2_, phase_, action);
    }

    function setFoundReaderContract(
        address vault_,
        address factoryV2_,
        address poolDataV2_,
        address phase_
    ) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setContract", vault_, factoryV2_, poolDataV2_, phase_));

        _validateAction(action);
        _clearAction(action);

        foundReader.setContract(vault_, factoryV2_, poolDataV2_, phase_);
    }


    // ****************************************************
    function signalFoundRouterV2Contract(
        address auth_,
        address factory_,
        address poolData_
    ) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setContract", auth_, factory_, poolData_));
        
        _setPendingAction(action);

        emit SignalFoundRouterV2Contract(auth_, factory_, poolData_, action);
    }

    function setFoundRouterV2Contract(
        address auth_,
        address factory_,
        address poolData_
    ) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setContract", auth_, factory_, poolData_));

        _validateAction(action);
        _clearAction(action);

        foundRouterV2.setContract(auth_, factory_, poolData_);
    }


    function _validateAction(bytes32 _action) private view {
        require(pendingActions[_action] != 0, "Timelock: action not signalled");
        require(pendingActions[_action] <= block.timestamp, "Timelock: action time not yet passed");
    }

    function _clearAction(bytes32 _action) private {
        require(pendingActions[_action] != 0, "Timelock: invalid _action");
        delete pendingActions[_action];
        emit ClearAction(_action);
    }

    function _setPendingAction(bytes32 _action) private {
        require(pendingActions[_action] == 0, "Timelock: action already signalled");
        pendingActions[_action] = block.timestamp + buffer;
        emit SignalPendingAction(_action);
    }



    function _setSignature(address[] memory signature_) internal {
        uint256 len = signature_.length;
        require(len > 0, "length err");
        for(uint256 i = 0; i < len; i++) {
            address account = signature_[i];
            if(account == address(0) || signature.contains(account)) {
                revert("account err");
            }

            signature.add(account);
        }
    }

    function getSignatureLength() external view returns(uint256) {
        return signature.length();
    }

    function getSignature(uint256 index) external view returns(address) {
        return signature.at(index);
    }

    function getSignatureContains(address account) external view returns(bool) {
        return signature.contains(account);
    }


    function validateSign(
        bytes32 action,
        Sig memory sign
    ) 
        public 
        view 
        returns(address) 
    {
        address singer = ecrecover(action, sign.v, sign.r, sign.s);
        require(signature.contains(singer), "not signer");
        require(!isSign[singer][action], "has sign");
        require(pendingActions[action] != 0, "action not signalled");

        return singer;
    } 

    function getAdminAction(address _admin) public view returns(bytes32) {
        return keccak256(abi.encodePacked("setAdmin", _admin, nextAdminSetID));
    }

}