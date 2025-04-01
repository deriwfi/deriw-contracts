// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IAuthV2.sol";
import "./FundPoolV2.sol";
import "../../libraries/utils/ReentrancyGuard.sol";
import "./interfaces/IPoolDataV2.sol";
import "./interfaces/IErrorContractV2.sol";
import "../../upgradeability/Synchron.sol";

contract FundFactoryV2 is Synchron, FundPoolV2, ReentrancyGuard {
    IAuthV2 public authV2;
    IErrorContractV2 public errContractV2;
    IPoolDataV2 public poolDataV2;
    address public gov;

    uint256 public poolID;

    bool public initialized;

    mapping(uint256 => address) public idToPool;
    mapping(address => address[]) public ownerPool;
    mapping(address => address) public poolOwner;
    mapping(address => bool) public isTokenCreate;

    event CreatePool(address creator, address pool, address token);


    modifier onlyGov() {
        require(gov == msg.sender, "gov err");
        _;
    }

    function initialize() external {
        require(!initialized, "has initialized");
        initialized = true;

        gov = msg.sender;
    }

    function setGov(address account) external onlyGov {
        require(account != address(0), "account err");
        gov = account;
    }

    function setContract(
        address auth_,
        address errContract_,
        address poolData_
    ) external onlyGov {
        authV2 = IAuthV2(auth_);
        poolDataV2 = IPoolDataV2(poolData_);
        errContractV2 = IErrorContractV2(errContract_);
    }

    function createPoolAndInit(
        address token, 
        TxInfo memory txInfo_,
        FundInfoV2 memory fundInfo_
    ) external nonReentrant {
        errContractV2.validateCreatePool(address(this), msg.sender, token, txInfo_, fundInfo_);

        isTokenCreate[token] = true;
        uint256 id = ++poolID;
        address pool = address(new FundPoolV2{salt: keccak256(abi.encode(id, txInfo_, fundInfo_))}());
        poolDataV2.initialize(pool, token, txInfo_, fundInfo_);

        idToPool[id] = pool;
        ownerPool[msg.sender].push(pool);
        poolOwner[pool] = msg.sender;

        emit CreatePool(msg.sender, pool, token);
    }  

    function getPoolNum(address account) external view returns(uint256) {
        return ownerPool[account].length;
    }
}