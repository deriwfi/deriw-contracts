// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IMemeStruct.sol";
import "../core/interfaces/IVault.sol";
import "./interfaces/IMemeData.sol";
import "./interfaces/IMemeFactory.sol";
import "../Pendant/interfaces/ICoinData.sol";
import "../Pendant/interfaces/IPhase.sol";
import "../fund-pool/v2/interfaces/IFundReader.sol";

contract MemeErrorContract is IMemeStruct {
    uint256 public deciCounter;

    IFundReader public foundReader;
    IMemeFactory public memeFactory;
    IMemeData public memeData;
    IVault public vault;
    IPhase public phase;
    
    address public memeRouter;
    address public coinData;
    address public immutable usdt;
    address public gov;

    constructor(address usdt_) {
        require(usdt_ != address(0), "usdt_ err");

        usdt = usdt_;
        gov = msg.sender;
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
        address memeFactory_,
        address memeData_,
        address memeRouter_,
        address vault_,
        address coinData_,
        address phase_,
        address foundReader_
    ) external onlyGov {
        require(
            memeFactory_ != address(0) &&
            memeData_ != address(0) &&
            memeRouter_ != address(0) &&
            vault_ != address(0) &&
            coinData_ != address(0) &&
            phase_ != address(0) &&
            foundReader_ != address(0),
            "addr err"
        );

        memeRouter = memeRouter_;
        memeFactory = IMemeFactory(memeFactory_);
        memeData = IMemeData(memeData_);
        vault = IVault(vault_);
        coinData = coinData_;
        phase = IPhase(phase_);
        foundReader = IFundReader(foundReader_);
    }

    function validateCreatePool(
        address factory,
        address account,
        address token
    ) external view returns(bool)  {
        require(factory == address(memeFactory), "factory err");
        require(memeFactory.getWhitelistIsIn(account), "no permission");
        require(!memeData.isTokenCreate(token), "has create");
        require(vault.whitelistedTokens(token), "not whitelistedToken");
        require(!ICoinData(coinData).isAddCoin(token) && token != usdt, "token err");

        return true;
    }

    function  validateDeposit(
        address router, 
        address user, 
        address pool, 
        uint256 amount
    ) external view returns(uint256) {
        validate(router, pool);
        require(user != address(0), "user err");
        require(amount > 0, "amount err");

        address token = memeData.poolToken(pool);

        return phase.getGlpAmount(token, usdt, amount);
    }

    function validateClaim(
        address router, 
        address user, 
        address pool, 
        uint256 glpAmount,
        bool isStake
    ) external view returns(bool) {
        validate(router, pool);
        require(user != address(0), "user err");
        MemeUserInfo memory mData = memeData.getMemeUserInfo(pool, user);
        require(glpAmount > 0 && glpAmount <= mData.glpAmount, "glpAmount err");
        require(isStake, "not stake");
        if(memeFactory.poolOwner(pool) == user) {
            require(block.timestamp >= memeData.startTime(pool) + memeData.lockTime(), "time err");
        }

        return true;
    }

    function validateWithdraw(
        address router, 
        address user, 
        address pool, 
        uint256 amount,
        uint256 haveDeposit,
        bool isStake
    ) external view returns(uint256) {
        validate(router, pool);
        require(user != address(0), "user err");
        require(amount > 0 && amount <= haveDeposit, "amount err");
        require(!isStake, "has stake");

        return phase.getGlpAmount(memeData.poolToken(pool), usdt, haveDeposit - amount);
    }

    function validateSetInitMinAmount(address router, uint256 amount) external view returns(bool) {
        require(memeRouter == router, "not router");
        require(amount > 0, "amount err");

        return true;
    }

    function getTokenValue(address token, uint256 amount) external view returns(uint256) {
        return foundReader.getTokenValue(token, amount);
    }

    function validateRouter(address router) external view returns(bool) {
        require(memeRouter == router, "not router");

        return true;
    }

    function validate(address router, address pool) public view  returns(bool){
        require(memeRouter == router, "not router");
        require(memeFactory.poolOwner(pool) != address(0), "pool err");

        return true;
    } 

    function getCurrTime() public view returns(uint256) {
        return block.timestamp;
    }

    function getCurrBlockNum() public view returns(uint256) {
        return block.number;
    }

}