// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "../interfaces/IStruct.sol";

interface IPoolDataV2 is IStruct {
    function  feeAmount(address pool, uint256 pid) external view returns(uint256);

    function glpRewardRouter() external view returns(address);

    function initialize(
        address pool, 
        address token,  
        TxInfo memory txInfo_,
        FundInfoV2 memory fundInfo_
    ) external;

    function setTxRate(address pool, uint256 rate) external;
    
    function getFoundInfo(address pool, uint256 pid) external view returns(FundInfoV2 memory);

    function getFoundState(address pool, uint256 pid) external view returns(FoundStateV2 memory);

    function getUserInfo(address user, address pool, uint256 pid) external view returns(UserInfoV2 memory);

    function getTxInfo(address pool) external view returns(TxInfo memory);

    function poolToken(address pool) external view returns(address);

    function tokenToPool(address pool) external view returns(address);

    function currPeriodID(address pool) external view returns(uint256);

    function currPool() external view returns(address);

    function lastPool() external view returns(address);

    function getUsersLength(address pool, uint256 pid, uint8 userType) external view returns(uint256);

    function lpToken() external view returns(address);  

    function periodID(address pool) external view returns(uint256);

    function getFundraisingAmount(address pool, uint256 pid) external view returns(uint256);

    function createNewPeriod(
        address pool, 
        FundInfoV2 memory fundInfo_
    ) external;

    function setPeriodAmount(
        address pool,       
        uint256 fundraisingAmount
    ) external;


    function setStartTime(address pool, uint256 pid, uint256 time) external;

    function setEndTime(address pool, uint256 pid, uint256 time) external;

    function setLockEndTime(address pool, uint256 pid, uint256 time) external;

    function setIsResubmit(address user, address pool, uint256 pid, bool isResubmit) external;

    function deposit(
        address user, 
        address pool,
        uint256 pid, 
        uint256 amount, 
        bool isResubmit
    ) external;

    function mintAndStakeGlp(
        address pool, 
        uint256 pid,
        uint256 minGlp
    ) external;

    function unstakeAndRedeemGlp(
        address pool, 
        uint256 pid, 
        uint256 minOut
    ) external;

    function claim(address user, address pool, uint256 pid) external;

    function compoundToNext(address pool, uint256 pid, uint256 number) external;

    function batchClaim(address user, address pool, uint256[] memory pid) external;

    function setName(address pool, string memory name_) external;
    
    function setDescribe(address pool, string memory describe_) external;

    function setwebsite(address pool, string memory website_) external;

    function setContract(
        address factoryV2_,
        address errContractV2_,
        address glpRewardRouter_,
        address feeBonus_,
        address vault_
    ) external;

    function setGov(address account) external;
    
    function setMinDepositAmount(address pool, uint256 amount) external;

    function riskClaimAmount(address pool, uint256 pid) external view returns(uint256);

    function profitClaimAmount(address pool, uint256 pid) external view returns(uint256);

    function risk() external view returns(address);

    function feeBonus() external view returns(address);
}
