// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IAuthV2.sol";
import "./interfaces/IFundFactoryV2.sol";
import "./interfaces/IPoolDataV2.sol";
import "./interfaces/IStruct.sol";

contract FundRouterV2 is IStruct {
    using SafeERC20 for IERC20;

    IAuthV2 public authV2;
    IFundFactoryV2 public factoryV2;
    IPoolDataV2 public poolDataV2;

    address public gov;

    constructor() {
        gov = msg.sender;
    }

    modifier onlyAuth(address pool) {
        require(authV2.getOperatorIsIn(pool, msg.sender), "no permission");
        _;
    }

    modifier onlyTrader(address pool) {
        require(authV2.getTraderAuth(pool, msg.sender), "not trader");
        _;
    }


    modifier onlyGov() {
        require(gov == msg.sender, "gov err");
        _;
    }
    function setGov(address account) external onlyGov {
        require(account != address(0), "account err");
        gov = account;
    }

    function setContract(
        address auth_,
        address factory_,
        address poolData_
    ) external onlyGov {
        require(
            auth_ != address(0) &&
            factory_ != address(0) &&
            poolData_ != address(0),
            "addr err"
        );

        factoryV2 = IFundFactoryV2(factory_);
        authV2 = IAuthV2(auth_);
        poolDataV2 = IPoolDataV2(poolData_);
    }
        
    function createNewPeriod(
        address pool, 
        FundInfoV2 memory fundInfo_
    ) external onlyTrader(pool) {
        poolDataV2.createNewPeriod(pool, fundInfo_);
    }

    function setPeriodAmount(
        address pool,       
        uint256 fundraisingAmount
    ) external onlyTrader(pool) {
        poolDataV2.setPeriodAmount(pool, fundraisingAmount);
    }


    function setStartTime(address pool, uint256 pid, uint256 time) external onlyTrader(pool) {
        poolDataV2.setStartTime(pool, pid, time);
    }

    function setEndTime(address pool, uint256 pid, uint256 time) external onlyTrader(pool) {
        poolDataV2.setEndTime(pool, pid, time);
    }

    function setLockEndTime(address pool, uint256 pid, uint256 time) external onlyTrader(pool) {
        poolDataV2.setLockEndTime(pool, pid, time);
    }

    function setTxRate(address pool, uint256 rate) external onlyTrader(pool) {
        poolDataV2.setTxRate(pool, rate);
    }

    function setIsResubmit(address pool, uint256 pid, bool isResubmit) external {
        poolDataV2.setIsResubmit(msg.sender, pool, pid, isResubmit);
    }

    function deposit(
        address pool,
        uint256 pid, 
        uint256 amount, 
        bool isResubmit
    ) external {
        poolDataV2.deposit(msg.sender, pool, pid, amount, isResubmit);
    }

    function mintAndStakeGlp(
        address pool, 
        uint256 pid,
        uint256 minGlp
    ) external onlyAuth(pool) {
        poolDataV2.mintAndStakeGlp(pool, pid, minGlp);
    }

    function unstakeAndRedeemGlp(
        address pool, 
        uint256 pid, 
        uint256 minOut
    ) external onlyAuth(pool) {
        poolDataV2.unstakeAndRedeemGlp(pool, pid, minOut);
    }

    function claim(address pool, uint256 pid) external {
        poolDataV2.claim(msg.sender, pool, pid);
    }

    function compoundToNext(address pool, uint256 pid, uint256 number) external onlyAuth(pool) {
        poolDataV2.compoundToNext(pool, pid, number);
    }

    function batchClaim(address pool, uint256[] memory pid) external {
        poolDataV2.batchClaim(msg.sender, pool, pid);
    }

    function setName(address pool, string memory name_) external onlyTrader(pool) {
        poolDataV2.setName(pool, name_);
    }

    function setDescribe(address pool, string memory describe_) external onlyTrader(pool)  {
        poolDataV2.setDescribe(pool, describe_);
    }

    function setwebsite(address pool, string memory website_) external onlyTrader(pool)  {
        poolDataV2.setwebsite(pool, website_);
    }


    function setMinDepositAmount(address pool, uint256 amount) external onlyTrader(pool) {
        poolDataV2.setMinDepositAmount(pool, amount);
    }

    function getCurrTime() public view returns(uint256) {
        return block.timestamp;
    }

    function getBlock() external view returns(uint256) {
        return block.number;
    }
}