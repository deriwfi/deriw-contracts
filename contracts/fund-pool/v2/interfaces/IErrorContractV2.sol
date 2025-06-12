// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "../interfaces/IStruct.sol";

interface IErrorContractV2 is IStruct {
    function setContract(
        address auth_,
        address factory_,
        address poolData_,
        address router_,
        address foundReader_
    ) external;

    function validateSet(        
        address router, 
        address pool
    ) external view returns(bool);

    function validateCreatePool(
        address factory,
        address account,
        address token,
        TxInfo memory txInfo_,
        FundInfoV2 memory fundInfo_
    ) external view returns(bool);

    function validateCreateNewPeriod(
        address router,
        address pool,  
        uint256 id, 
        FundInfoV2 memory fundInfo_
    ) external view returns(bool);

    function validateSetStartTime(
        address router, 
        address pool,         
        uint256 pid,
        uint256 time
    ) external view returns(bool);

    
    function validateDeposit(
        address router, 
        address pool, 
        uint256 pid,
        uint256 amount,
        bool isNext 
    ) external view returns(uint256, uint256);

    function valitadeMintAndStakeGlp(
        address router, 
        address pool,
        uint256 pid
    ) external view returns (uint256);

    function valitadeUnstakeAndRedeemGlp(
        address router, 
        address pool,
        uint256 pid
    ) external view returns (bool);

    function validateClaim(
        address router, 
        address user, 
        address pool, 
        uint256 pid
    ) external view returns(uint256 amount, uint256 lessLp);

    function validateCompound(
        address router, 
        address pool, 
        uint256 pid,
        uint256 number
    ) external view returns(uint256);

    function validateSetPeriodAmount(
        address router, 
        address pool,   
        uint256 pid,      
        uint256 fundraisingAmount
    ) external view returns(bool);


    function getCompoundAmountFormPrevious(address pool, uint256 pid) external view returns(uint256);
    function getUserCompoundAmount(
        address pool, 
        address user,
        uint256 pid
    ) external view returns(uint256, uint256, bool);

    function validateSetEndTime(
        address router, 
        address pool,  
        uint256 pid,       
        uint256 time
    ) external view returns(bool);

    function getDepositLpAmount(
        address pool, 
        uint256 pid,
        uint256 amount,
        bool isNext
    ) external view returns(uint256);

    function validateSetLockEndTime(
        address router, 
        address pool, 
        uint256 pid,        
        uint256 time
    ) external view returns(bool);

    function validateSetTxRate(
        address router, 
        address pool, 
        uint256 rate
    ) external view returns(bool);

    function validateSetIsResubmit(
        address router, 
        address user,
        address pool, 
        uint256 pid,
        bool isResubmit
    ) external view returns(bool);

    function setGov(address account) external;

    function validateSetMinDepositAmount(
        address router, 
        address pool, 
        uint256 amount
    ) external view returns(bool);

    function foundRouterV2() external view returns(address);
    
}