// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IStruct.sol";
import "./interfaces/IAuthV2.sol";
import "./interfaces/IFundFactoryV2.sol";
import "../../core/interfaces/IERC20Metadata.sol";
import "./interfaces/IPoolDataV2.sol";
import "../../core/interfaces/IVault.sol";
import "./interfaces/IFundReader.sol";

contract ErrorContractV2 is IStruct {
    uint256 public deciCounter;

    IFundReader public foundReader;
    IFundFactoryV2 public factoryV2;
    IAuthV2 public authV2;
    IPoolDataV2 public poolDataV2;
    address public foundRouterV2;
    address public immutable usdt;
    address public gov;

    constructor(address usdt_) {
        usdt = usdt_;
        gov = msg.sender;
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
        address poolData_,
        address router_,
        address foundReader_
    ) external onlyGov {
        foundReader = IFundReader(foundReader_);
        foundRouterV2 = router_;
        factoryV2 = IFundFactoryV2(factory_);
        authV2 = IAuthV2(auth_);
        poolDataV2 = IPoolDataV2(poolData_);
        deciCounter = 10 ** IERC20Metadata(poolDataV2.lpToken()).decimals();
    }


    function validateCreatePool(
        address factory,
        address account,
        address token,
        TxInfo memory txInfo_,
        FundInfoV2 memory fundInfo_
    ) external view returns(bool)  {
        require(factory == address(factoryV2), "factory err");
        require(authV2.getWhitelistIsIn(account), "no permission");
        require(!factoryV2.isTokenCreate(token), "has create");
        require(IVault(foundReader.vault()).whitelistedTokens(token), "not whitelistedToken");
        require(token == usdt, "token err");

        require(
            txInfo_.fundraisingAmount > 0 &&
            fundInfo_.startTime >= block.timestamp &&
            fundInfo_.startTime < fundInfo_.endTime &&
            fundInfo_.endTime < fundInfo_.lockEndTime &&
            txInfo_.minDepositAmount > 0 &&
            txInfo_.txRate > 0,
            "create err"
        );

        return true;
    }

    function validateCreateNewPeriod(
        address router,
        address pool, 
        uint256 id, 
        FundInfoV2 memory fundInfo_
    ) external view returns(bool) {
        validate(router, pool);
        
        require(
            fundInfo_.startTime >= block.timestamp &&
            fundInfo_.startTime < fundInfo_.endTime &&
            fundInfo_.endTime < fundInfo_.lockEndTime,
            "create err"
        );
        
        require(id > 1, "pid err");
        FundInfoV2 memory fInfo1 = poolDataV2.getFoundInfo(pool, id);
        require(
            fundInfo_.startTime < fInfo1.lockEndTime && 
            fundInfo_.endTime == fInfo1.lockEndTime &&
            block.timestamp >= fInfo1.startTime,
            "can not create"
        );

        return true;
    }

    function validateDeposit(
        address router, 
        address pool, 
        uint256 pid,
        uint256 amount,
        bool isNext   
    ) external view returns(uint256, uint256) {
        validate(router, pool);
        validatePid(pool, pid);

        FundInfoV2 memory fInfo = poolDataV2.getFoundInfo(pool, pid);
        FoundStateV2 memory fState = poolDataV2.getFoundState(pool, pid);
        TxInfo memory tInfo = poolDataV2.getTxInfo(pool);

        uint256 fAmount = poolDataV2.getFundraisingAmount(pool, pid);
        if(fAmount == 0) {
            fAmount = tInfo.fundraisingAmount;
        }

        uint256 outAmount;
        if(pid > 1) {
            FoundStateV2 memory fState1 = poolDataV2.getFoundState(pool, pid-1);
            if(fState1.isClaim) {
                outAmount = foundReader.getOutAmount(poolDataV2.poolToken(pool), 0);
            } else {
                outAmount = foundReader.getOutAmount(poolDataV2.poolToken(pool), fState1.glpAmount);
            }

            if(outAmount > fAmount) {
                fAmount = outAmount;
            }
        }

        require(amount >= tInfo.minDepositAmount, "too small");
        require(fInfo.startTime <= block.timestamp && fInfo.endTime > block.timestamp, "time err");
        require(amount + fState.depositAmount <= fAmount, "amount err");

        uint256 lp = getDepositLpAmount(pool, pid, amount, isNext);
        return (lp, outAmount);
    }

    function getOutAmount(address token, uint256 amount) public view returns(uint256) {
        return foundReader.getOutAmount(token, amount);
    }

    function getMaxDeposit(address pool, uint256 pid) external view returns(uint256, uint256) {
        FoundStateV2 memory fState = poolDataV2.getFoundState(pool, pid);
        TxInfo memory tInfo = poolDataV2.getTxInfo(pool);
        
        uint256 fAmount;
        if(fState.currFundraisingAmount != 0) {
            fAmount = fState.currFundraisingAmount; 
        } else {
            fAmount = tInfo.fundraisingAmount;
        }

        uint256 outAmount;
        if(pid > 1) {
            FoundStateV2 memory fState1 = poolDataV2.getFoundState(pool, pid-1);
            outAmount = foundReader.getOutAmount(poolDataV2.poolToken(pool), fState1.glpAmount);
            if(outAmount > fAmount) {
                fAmount = outAmount;
            }
        }

        if(fAmount > fState.depositAmount) {
            return (fAmount - fState.depositAmount, tInfo.minDepositAmount);
        }
        return (0, tInfo.minDepositAmount);
    }

    function getDepositLpAmount(
        address pool, 
        uint256 pid,
        uint256 amount,
        bool isNext 
    ) public view returns(uint256) {
        return foundReader.getDepositLpAmount(pool, pid, amount, isNext);
    }

    function validatePid(address pool, uint256 pid) internal view {
        require(pid > 0 && pid <= poolDataV2.periodID(pool), "pid err");
    }

    function valitadeMintAndStakeGlp(
        address router, 
        address pool,
        uint256 pid
    ) external view returns (uint256) {
        validate(router, pool);
        validatePid(pool, pid);

        require(poolDataV2.currPool() == address(0), "has pool stake");
        FundInfoV2 memory fInfo = poolDataV2.getFoundInfo(pool, pid);
        FoundStateV2 memory fState = poolDataV2.getFoundState(pool, pid);
        require(poolDataV2.currPeriodID(pool) == 0, "has stake");
        require(
            block.timestamp >= fInfo.endTime && 
            !fState.isFundraise &&
            fState.depositAmount > 0, 
            "stake err"
        );

        if(pid > 1) {
            FoundStateV2 memory fState1 = poolDataV2.getFoundState(pool, pid-1);
            require(
                (fState1.isClaim || fState1.depositAmount == 0) &&
                fState1.isAllResubmit,
                "last pid not claim"
            );
        }

        return foundReader.getTokenValue(poolDataV2.poolToken(pool), fState.depositAmount);
    } 

    function valitadeUnstakeAndRedeemGlp(
        address router, 
        address pool,
        uint256 pid
    ) external view returns (bool) {
        validate(router, pool);
        validatePid(pool, pid);

        FundInfoV2 memory fInfo = poolDataV2.getFoundInfo(pool, pid);
        FoundStateV2 memory fState = poolDataV2.getFoundState(pool, pid);

        require(block.timestamp >= fInfo.lockEndTime, "time err");
        require(
            !fState.isClaim && 
            fState.isFundraise,
            "unstake err"
        );

        return true;
    } 

    function validateClaim(
        address router, 
        address user, 
        address pool, 
        uint256 pid
    ) external view returns(uint256 amount, uint256 lessLp) {
        validate(router, pool);
        validatePid(pool, pid);

        FoundStateV2 memory fState = poolDataV2.getFoundState(pool, pid);
        UserInfoV2 memory uInfo = poolDataV2.getUserInfo(user, pool, pid);

        lessLp = uInfo.lpAmount - uInfo.nextLpAmount;
        require(
            fState.isAllResubmit &&
            fState.isClaim &&
            lessLp > 0 &&
            !uInfo.isClaim,
            "claim err"
        );

        amount = fState.userAmount * lessLp / fState.totalLpAmount;

        require(amount > 0, "no amount");
    }

    function validateCompound(
        address router, 
        address pool, 
        uint256 pid,
        uint256 number
    ) external view returns(uint256) {
        validate(router, pool);
        validatePid(pool, pid);

        uint256 nextPid = pid + 1;
        validatePid(pool, nextPid);

        FoundStateV2 memory fState = poolDataV2.getFoundState(pool, pid);
        FundInfoV2 memory fInfo1 = poolDataV2.getFoundInfo(pool, nextPid);

        uint256 len = poolDataV2.getUsersLength(pool, pid, 1) + poolDataV2.getUsersLength(pool, pid, 4);
        require(
            !fState.isAllResubmit &&
            number > 0 &&
            block.timestamp >= fInfo1.endTime,
            "compound err"
        );

        return len;
    }

    function validateSetPeriodAmount(
        address router, 
        address pool,   
        uint256 pid,      
        uint256 fundraisingAmount
    ) external view returns(bool) {
        validate(router, pool);
        validatePid(pool, pid);

        FundInfoV2 memory fInfo = poolDataV2.getFoundInfo(pool, pid);
        require(fundraisingAmount > 0, "fundraisingAmount err");

        if(fInfo.startTime <= block.timestamp && block.timestamp < fInfo.endTime) {
            revert("time err");
        }

        if(pid > 1) {
            FundInfoV2 memory fInfo1 = poolDataV2.getFoundInfo(pool, pid-1);
            if(fInfo1.startTime <= block.timestamp && block.timestamp < fInfo1.endTime) {
                revert("time1 err");
            }
        }

        return true;
    }

    function validateSetStartTime(
        address router, 
        address pool,         
        uint256 pid,
        uint256 time
    ) external view returns(bool) {
        validate(router, pool);
        validatePid(pool, pid);

        FundInfoV2 memory fInfo = poolDataV2.getFoundInfo(pool, pid);

        require(
            time >= block.timestamp &&
            fInfo.startTime > block.timestamp &&
            fInfo.endTime > time,
            "time err"
        );

        return true;
    }

    function validateSetEndTime(
        address router, 
        address pool,
        uint256 pid,         
        uint256 time
    ) external view returns(bool) {
        validate(router, pool);
        validatePid(pool, pid);

        FundInfoV2 memory fInfo = poolDataV2.getFoundInfo(pool, pid);

        require(
            time >= block.timestamp &&
            fInfo.endTime > block.timestamp &&
            time > fInfo.startTime,
            "time err"
        );

        return true;
    }

    function validateSetLockEndTime(
        address router, 
        address pool, 
        uint256 pid,        
        uint256 time
    ) external view returns(bool) {
        validate(router, pool);
        validatePid(pool, pid);

        FundInfoV2 memory fInfo = poolDataV2.getFoundInfo(pool, pid);
        require(
            time >= block.timestamp &&
            time > fInfo.endTime &&
            fInfo.lockEndTime > block.timestamp,
            "time err"
        );

        FundInfoV2 memory fInfo1 = poolDataV2.getFoundInfo(pool, pid + 1);
        if(fInfo1.startTime != 0) {
            require(block.timestamp <  fInfo1.startTime, "next has start");
        }

        return true;        
    }

    function validateSetTxRate(
        address router, 
        address pool, 
        uint256 rate
    ) external view returns(bool) {
        validate(router, pool);
        require(rate > 0, "rate err");

        return true;        
    }

    function validateSetIsResubmit(
        address router, 
        address user,
        address pool, 
        uint256 pid,
        bool isResubmit
    ) external view returns(bool) {
        validate(router, pool);
        validatePid(pool, pid);
        UserInfoV2 memory uInfo = poolDataV2.getUserInfo(user, pool, pid);
        FundInfoV2 memory fInfo = poolDataV2.getFoundInfo(pool, pid);
        require(
            block.timestamp < fInfo.lockEndTime &&
            uInfo.fundAmount > 0 &&
            uInfo.isResubmit != isResubmit,
            "set err"
        );

        return true;
    }

    function validateSetMinDepositAmount(
        address router, 
        address pool, 
        uint256 amount
    ) external view returns(bool) {
        validate(router, pool);
        require(amount > 0, "amount err");

        return true;
    }

    function validateSet(        
        address router, 
        address pool
    ) external view returns(bool) {
        validate(router, pool);
        return true;
    }

    function validate(address router, address pool) public view {
        require(foundRouterV2 == router, "not router");
        require(factoryV2.poolOwner(pool) != address(0), "pool err");
    } 

    function getCurrTime() public view returns(uint256) {
        return block.timestamp;
    }

    function getCurrBlockNum() public view returns(uint256) {
        return block.number;
    }

    function getCompoundAmountFormPrevious(address pool, uint256 pid) external view returns(uint256) {
        return foundReader.getCompoundAmountFormPrevious(pool, pid);
    }

    function getUserCompoundAmount(
        address pool, 
        address user,
        uint256 pid
    ) external view returns(uint256, uint256, bool) {
        return foundReader.getUserCompoundAmount(pool, user, pid);
    }
}