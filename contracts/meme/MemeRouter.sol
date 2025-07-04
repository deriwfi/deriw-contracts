// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IMemeFactory.sol";
import "./interfaces/IMemeData.sol";
import "./interfaces/IMemeStruct.sol";

contract MemeRouter is IMemeStruct {
    using SafeERC20 for IERC20;

    IMemeFactory public memeFactory;
    IMemeData public memeData;

    address public gov;

    constructor() {
        gov = msg.sender;
    }

    modifier onlyOperator() {
        require(memeFactory.operator(msg.sender), "no permission");
        _;
    }

    modifier onlyAuth() {
        require(memeFactory.trader(msg.sender) || msg.sender == memeFactory.gov(), "no permission");
        _;
    }

    modifier onlyGov() {
        require(gov == msg.sender, "gov err");
        _;
    }
    function setGov(address account) external onlyGov {
        require(account != address(0), "_gov err");
        gov = account;
    }

    function setContract(
        address factory_,
        address memeData_
    ) external onlyGov {
        require(
            factory_ != address(0) &&
            memeData_ != address(0),
            "addr err"
        );

        memeFactory = IMemeFactory(factory_);
        memeData = IMemeData(memeData_);
    }

    function deposit(address pool, uint256 amount) external {
        memeData.deposit(msg.sender, pool, amount);
    }

    function claim(address pool, uint256 amount) external {
        MemeState memory mState = memeData.getMemeState(pool);
        if(mState.isStake) {
            memeData.claim(msg.sender, pool, amount);
        } else {
            memeData.withdraw(msg.sender, pool, amount);
        }
    }

    function claimAll() external {
        uint256 num = memeData.getUserDepositPoolNum(msg.sender);
        for(uint256 i = 0; i < num; i++) {
            address pool = memeData.getUserDepositPool(msg.sender, 0);
            MemeState memory mState = memeData.getMemeState(pool);
            MemeUserInfo memory uInfo = memeData.getMemeUserInfo(pool, msg.sender);
            if(mState.isStake) {
                memeData.claim(msg.sender, pool, uInfo.glpAmount);
            } else {
                memeData.withdraw(msg.sender, pool, uInfo.depositAmount);
            }
        }
    }

    function setIsPoolTokenClose(address pool, bool isClose) external onlyOperator {
        memeData.setIsPoolTokenClose(pool, isClose);
    }

    function setInitMinAmount(uint256 amount) external onlyAuth {
        memeData.setInitMinAmount(amount);
    }

    function setLockTime(uint256 time) external onlyAuth {
        memeData.setLockTime(time);
    }

    function getCurrTime() public view returns(uint256) {
        return block.timestamp;
    }

    function getBlock() external view returns(uint256) {
        return block.number;
    }
}