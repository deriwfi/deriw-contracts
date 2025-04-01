// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./MemePool.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import "./interfaces/IMemeErrorContract.sol";
import "./interfaces/IMemeData.sol";
import "../core/interfaces/IERC20Metadata.sol";
import "../upgradeability/Synchron.sol";

contract MemeFactory is Synchron, MemePool, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    event CreatePool(address creator, address pool, address token, string symbol);
    event AddWhitelist(address indexed account);
    event RemoveWhitelist(address indexed account);

    EnumerableSet.AddressSet Whitelist;
    EnumerableSet.AddressSet removelist;
    IMemeErrorContract public memeErrorContract;
    IMemeData public memeData;

    address public coinData;
    address public gov;

    uint256 public poolID;

    bool public initialized;

    mapping(uint256 => address) public idToPool;
    mapping(address => address[]) public ownerPool;
    mapping(address => address) public poolOwner;
    mapping(address => bool) public operator;
    mapping(address => bool) public trader;

    modifier onlyGov() {
        require(gov == msg.sender, "no permission");
        _;
    }

    modifier onlyAuth() {
        require(gov == msg.sender || trader[msg.sender] == true, "no permission");
        _;
    }

    function initialize() external {
        require(!initialized, "has initialized");
        initialized = true;

        gov = msg.sender;
    }


    function setGov(address account) external onlyGov {
        require(account != address(0), "_gov err");
        gov = account;
    }

    function setTrader(address account, bool isAdd) external onlyGov {
        trader[account] = isAdd;
    }

    function setOperator(address account, bool isAdd) external onlyAuth {
        operator[account] = isAdd;
    }

    function setContract(
        address errContract_,
        address memeData_,
        address coinData_
    ) external onlyAuth {
        memeData = IMemeData(memeData_);
        memeErrorContract = IMemeErrorContract(errContract_);
        coinData = coinData_;
    }


    function addOremoveWhitelist(address[] memory accounts, bool isAdd) external onlyAuth {
        if(isAdd) {
            _addWhitelist(accounts);
        } else {
            _removeWhitelist(accounts);
        }
    }

    function createPool(address token) external nonReentrant {
        memeErrorContract.validateCreatePool(address(this), msg.sender, token);

        uint256 id = ++poolID;
        address pool = address(new MemePool{salt: keccak256(abi.encode(id, token))}());
       
        memeData.createPool(pool, token);

        idToPool[id] = pool;
        ownerPool[msg.sender].push(pool);
        poolOwner[pool] = msg.sender;
        string memory _symbol = IERC20Metadata(token).symbol();

        emit CreatePool(msg.sender, pool, token, _symbol);
    }  

    function _addWhitelist(address[] memory accounts) internal {
        for (uint256 i = 0; i < accounts.length; i++) {
            if(!Whitelist.contains(accounts[i])) {
                Whitelist.add(accounts[i]);
                removelist.remove(accounts[i]);
                emit AddWhitelist(accounts[i]);
            }
        }
    }

    function _removeWhitelist(address[] memory accounts) internal  {
        for (uint256 i = 0; i < accounts.length; i++) {
            if(Whitelist.contains(accounts[i])) {
                Whitelist.remove(accounts[i]);
                removelist.add(accounts[i]);
                emit RemoveWhitelist(accounts[i]);
            }
        }
    }

    function getWhitelistNum() external view returns(uint256) {
        return Whitelist.length();
    }

    function getWhitelist(uint256 index) external view returns(address) {
        return Whitelist.at(index);
    }

    function getWhitelistIsIn(address account) external view returns(bool) {
        return Whitelist.contains(account);
    }

    function getRemovelistNum() external view returns(uint256) {
        return removelist.length();
    }

    function getRemovelist(uint256 index) external view returns(address) {
        return removelist.at(index);
    }

    function getRemovelistIsIn(address account) external view returns(bool) {
        return removelist.contains(account);
    }

    function getInList(address account) external view returns(bool) {
        if(Whitelist.contains(account) || removelist.contains(account)) {
            return true;
        }
        return false;
    }

    function getPoolNum(address account) external view returns(uint256) {
        return ownerPool[account].length;
    }
}