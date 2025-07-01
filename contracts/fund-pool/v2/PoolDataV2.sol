// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IFundFactoryV2.sol";
import "./interfaces/IStruct.sol";
import "./interfaces/IErrorContractV2.sol";
import "./interfaces/IFundPoolV2.sol";
import "../../core/interfaces/IERC20Metadata.sol";
import "../../upgradeability/Synchron.sol";
import "../../referrals/interfaces/IFeeBonus.sol";
import "../../core/interfaces/ITransferAmountData.sol";
import "./interfaces/IRisk.sol";

contract PoolDataV2 is Synchron, IStruct, ITransferAmountData {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    IFundFactoryV2 public factoryV2;
    IErrorContractV2 public errContractV2;  
    IRisk public risk;

    address public lpToken;
    address public glpRewardRouter;
    address public gov;
    address public currPool;
    address public lastPool;
    address public feeBonus;
    address public vault;

    uint256 public constant baseRate = 10000;

    bool public initialized;

    mapping(address => bool) public isInit;
    mapping(address => address) public poolToken;
    mapping(address => address) public tokenToPool;
    mapping(address => uint256) public currPeriodID;
    mapping(address => uint256) public periodID;
    mapping(address => mapping(uint256 => FundInfoV2)) fundInfo;
    mapping(address => mapping(uint256 => FoundStateV2)) foundState;
    mapping(address => TxInfo) txInfo;
    mapping(address => mapping(uint256 => EnumerableSet.AddressSet)) remainUsers;
    mapping(address => mapping(uint256 => EnumerableSet.AddressSet)) trendsUsers;
    mapping(address => mapping(uint256 => EnumerableSet.AddressSet)) compoundUsers;
    mapping(address => mapping(uint256 => EnumerableSet.AddressSet)) previousUsers;
    mapping(address => mapping(address => mapping(uint256 => mapping(uint256 => UserPerInfo)))) userPerInfo; 
    mapping(address => mapping(address => mapping(uint256 => UserInfoV2))) userInfo; 
    mapping(address => mapping(address => mapping(uint256 => uint256))) public lastTime; 
    mapping(address => mapping(uint256 => uint256)) public feeAmount;
    mapping(address => mapping(uint256 => uint256)) public riskClaimAmount;
    mapping(address => mapping(uint256 => uint256)) public profitClaimAmount;

    struct ProfitAmount {
        address account;
        uint256 amount;
    }

    event CreateAndInit(address pool, address token,  TxInfo txInfo_, uint256 pid, FundInfoV2 fundInfo_);
    event CreatePeriod(address pool, uint256 pid, FundInfoV2 fundInfo_);
    event MintAndStakeGlp(address pool, uint256 pid, uint256 amount, uint256 glpAmount);
    event Claim(ClaimEvent cEvent);
    event SetPeriodAmount(address pool, uint256 fundraisingAmount); 
    event SetStartTime(address pool, uint256 pid, uint256 time);
    event SetEndTime(address pool, uint256 pid, uint256 time);
    event SetLockEndTime(address pool, uint256 pid, uint256 time);
    event SetTxRate(address pool, uint256 rate);
    event SetIsResubmit(address user, address pool, uint256 pid, bool isResubmit);
    event Deposit(DepositEvent dEvent);
    event CompoundToNext(address pool, address user, uint256 pid, uint256 nextPid, bool isAll);
    event TrendsUsers(address pool, address user, uint256 pid, uint256 nextPid);
    event SetName(address pool, string name);
    event SetDescribe(address pool, string describe);
    event Setwebsite(address pool, string website);
    event SetMinDepositAmount(address pool, uint256 amount);

    event UnstakeAndRedeemGlp(
        address pool, 
        uint256 pid, 
        uint256 glpAmount, 
        uint256 amount,
        uint256 fee1,
        uint256 fee2,
        ProfitAmount[] _profitAmount,
        uint256 rAmount,
        uint256 userAmount
    );

    event TransferProfit(
        address from,
        address to,
        address pool,
        uint256 pid,
        uint256 amount,
        TransferAmountData tData
    ); 

    event TransferRisk(
        address from,
        address to,
        address pool,
        uint256 pid,
        uint256 amount,
        TransferAmountData tData
    ); 

    modifier onlyGov() {
        require(gov == msg.sender, "gov err");
        _;
    }
    
    function initializeFor(address lpToken_) external {
        require(!initialized, "has initialized");
        initialized = true;

        lpToken = lpToken_;
        gov = msg.sender;
    }

    function setGov(address account) external onlyGov {
        require(account != address(0), "_gov err");
        gov = account;
    }

    function setContract(
        address factoryV2_,
        address errContractV2_,
        address glpRewardRouter_,
        address feeBonus_,
        address vault_
    ) external onlyGov {
        factoryV2 = IFundFactoryV2(factoryV2_);
        errContractV2 = IErrorContractV2(errContractV2_);
        glpRewardRouter = glpRewardRouter_;
        feeBonus = feeBonus_;
        vault = vault_;
    }

    function setRisk(address risk_) external onlyGov {
        risk = IRisk(risk_);
    }

    function initialize(
        address pool, 
        address token,  
        TxInfo memory txInfo_,
        FundInfoV2 memory fundInfo_
    ) external {
        require(!isInit[pool] && msg.sender == address(factoryV2), "init err");
        isInit[pool] = true;
        poolToken[pool] = token;
        tokenToPool[token] = pool;

        uint256 id = ++periodID[pool];
        fundInfo[pool][id] = fundInfo_;

        txInfo[pool] = txInfo_;

        emit CreateAndInit(pool, token, txInfo_, id, fundInfo_);
    }

    function createNewPeriod(
        address pool, 
        FundInfoV2 memory fundInfo_
    ) external {
        errContractV2.validateCreateNewPeriod(msg.sender, pool, periodID[pool], fundInfo_);
        uint256 id = ++periodID[pool];

        fundInfo[pool][id] = fundInfo_;

        emit CreatePeriod(pool, id, fundInfo_);
    }

    function setName(address pool, string memory name_) external {
        errContractV2.validateSet(msg.sender, pool);

        txInfo[pool].name = name_;
        emit SetName(pool, name_);
    }


    function setDescribe(address pool, string memory _describe) external {
        errContractV2.validateSet(msg.sender, pool);  

        txInfo[pool].describe = _describe;
        emit SetDescribe(pool, _describe);
    }


    function setwebsite(address pool, string memory website_) external {
        errContractV2.validateSet(msg.sender, pool);

        txInfo[pool].website = website_;

        emit Setwebsite(pool, website_);
    }

    function setPeriodAmount(
        address pool,      
        uint256 fundraisingAmount_
    ) external {
        uint256 pid = periodID[pool];
        errContractV2.validateSetPeriodAmount(msg.sender, pool, pid, fundraisingAmount_);

        txInfo[pool].fundraisingAmount = fundraisingAmount_;

        emit SetPeriodAmount(pool, fundraisingAmount_);
    }

    function setMinDepositAmount(address pool, uint256 amount) external {
        errContractV2.validateSetMinDepositAmount(msg.sender, pool, amount);

        txInfo[pool].minDepositAmount = amount;
        emit SetMinDepositAmount(pool, amount);
    }

    function setStartTime(address pool, uint256 pid, uint256 time) external {
        errContractV2.validateSetStartTime(msg.sender, pool, pid, time);

        fundInfo[pool][pid].startTime = time;

        emit SetStartTime(pool, pid, time);
    }


    function setEndTime(address pool, uint256 pid, uint256 time) external {
        errContractV2.validateSetEndTime(msg.sender, pool, pid, time);

        fundInfo[pool][pid].endTime = time;

        emit SetEndTime(pool, pid, time);
    }

    function setLockEndTime(address pool, uint256 pid, uint256 time) external {
        errContractV2.validateSetLockEndTime(msg.sender, pool, pid, time);

        fundInfo[pool][pid].lockEndTime = time;

        emit SetLockEndTime(pool, pid, time);
    }

    function setTxRate(address pool, uint256 rate) external {
        errContractV2.validateSetTxRate(msg.sender, pool, rate);

        txInfo[pool].txRate  = rate;
        emit SetTxRate(pool, rate);
    }

    function setIsResubmit(address user, address pool, uint256 pid, bool isResubmit) external {
        errContractV2.validateSetIsResubmit(msg.sender, user, pool, pid, isResubmit);

        _setIsResubmit(user, pool, pid, isResubmit);
    }

    function deposit(
        address user, 
        address pool,
        uint256 pid, 
        uint256 amount, 
        bool isResubmit
    ) external {
        (uint256 value, uint256 outAmount) = errContractV2.validateDeposit(msg.sender, pool, pid, amount, false);
        if(foundState[pool][pid].currFundraisingAmount == 0) {
            foundState[pool][pid].currFundraisingAmount = txInfo[pool].fundraisingAmount;
        }

        foundState[pool][pid].actAmount = outAmount;

        _deposit(user, pool, pid, amount, value, isResubmit, false);
    } 

    function mintAndStakeGlp(
        address pool, 
        uint256 pid,
        uint256 minGlp
    ) external {
        uint256 value = errContractV2.valitadeMintAndStakeGlp(msg.sender, pool, pid);

        currPeriodID[pool] = pid;
        currPool = pool;
        lastPool = pool;
        foundState[pool][pid].isFundraise = true;
        foundState[pool][pid].fundraisingValue = value;
        uint256 glpAmount = IFundPoolV2(pool).mintAndStakeGlp(poolToken[pool], foundState[pool][pid].depositAmount, minGlp);
        foundState[pool][pid].glpAmount = glpAmount;

        emit MintAndStakeGlp(pool, pid, foundState[pool][pid].depositAmount, glpAmount);
    }


    function unstakeAndRedeemGlp(
        address pool, 
        uint256 pid, 
        uint256 minOut
    ) external {
        errContractV2.valitadeUnstakeAndRedeemGlp(msg.sender, pool, pid);
        currPeriodID[pool] = 0;
        currPool = address(0);
        foundState[pool][pid].isClaim = true;

        address token =  poolToken[pool];
        uint256 riskAmount = risk.totalRiskDeposit(address(this), pool, token, pid);

        (uint256 fee1, uint256 fee2) = IFeeBonus(feeBonus).claimFeeAmount(vault);
        uint256 outAmount = IFundPoolV2(pool).unstakeAndRedeemGlp(token, foundState[pool][pid].glpAmount, minOut);
        foundState[pool][pid].outAmount = outAmount;
        feeAmount[pool][pid] = fee1 + fee2;

        uint256 dAmount =  foundState[pool][pid].depositAmount;

        uint256 len = risk.getProfitDataLength();
        ProfitAmount[] memory _profitAmount = new ProfitAmount[](len);
        uint256 rAmount;

        address _pool = pool;
        uint256 _pid = pid;
        address _token = token;
        if(outAmount > dAmount) {
            address _account = risk.profitAccount();

            if(outAmount > dAmount + riskAmount) {
                rAmount = riskAmount;
                uint256 pAmount = outAmount - dAmount - riskAmount;
                
                uint256 _total;
                if(len > 0) {
                    for(uint256 i = 0; i < len; i++) {
                        (address account, uint256 rate) = risk.profitData(i);
                        uint256 _amount = pAmount * rate / baseRate;

                        _total += _amount;
                        _profitAmount[i] = ProfitAmount(account, _amount);
                        _transferProfit(_pool, _token, account, _pid, _amount);
                    }
                }
                profitClaimAmount[_pool][_pid] = _total;
                
                foundState[_pool][_pid].userAmount = outAmount - rAmount - _total;
            } else {
                rAmount = outAmount - dAmount;
                foundState[_pool][_pid].userAmount = dAmount;
            }

            _transferRisk(_pool, token, _account, _pid, rAmount);
        } else {
            foundState[_pool][_pid].userAmount = outAmount;
        }

        riskClaimAmount[_pool][_pid] = rAmount;


        emit UnstakeAndRedeemGlp(
            pool, 
            pid, 
            foundState[_pool][_pid].glpAmount, 
            outAmount, 
            fee1, 
            fee2,
            _profitAmount,
            rAmount,
            foundState[_pool][_pid].userAmount
        );    
    }

    function compoundToNext(address pool, uint256 pid, uint256 number) external {
        if(foundState[pool][pid].currFundraisingAmount == 0) {
            foundState[pool][pid].currFundraisingAmount = txInfo[pool].fundraisingAmount;
        }

        uint256 len = errContractV2.validateCompound(msg.sender, pool, pid, number);
        uint256 nextPid = pid + 1;
        uint256 compoundAmount = errContractV2.getCompoundAmountFormPrevious(pool, nextPid);
        if(!foundState[pool][nextPid].isGet) {
            foundState[pool][nextPid].isGet = true;
            if(compoundAmount == 0 || len == 0) {
                foundState[pool][pid].isAllResubmit = true;
                emit CompoundToNext(pool, address(0), pid, nextPid, true);
                return;
            }
            foundState[pool][nextPid].needCompoundAmount = compoundAmount;
        }

        uint256 num = remainUsers[pool][pid].length();
        if(num > 0) {
            if(number > num) {
                number = num;
            }
            _compoundRemain(pool, pid, nextPid, number);
        } else {
            _compound(pool, pid, nextPid, number);
        }
    }

    function claim(address user, address pool, uint256 pid) public {
        (uint256 amount, uint256 lessLp) = errContractV2.validateClaim(msg.sender, user, pool, pid);
        
        userInfo[user][pool][pid].isClaim = true;
        userInfo[user][pool][pid].claimAmount = amount;
        address token = poolToken[pool];
        
        TransferAmountData memory tData = _safeTransfer(token, user, amount);

        IERC20Metadata(lpToken).burn(lessLp);

        ClaimEvent memory cEvent = ClaimEvent(
            user, 
            pool, 
            pid, 
            amount, 
            lessLp,
            tData.beforeAmount, 
            tData.afterAmount, 
            tData.beforeValue, 
            tData.afterValue
        );

        emit Claim(cEvent);
    }

    function batchClaim(address user, address pool, uint256[] memory pid) external {
        uint256 len = pid.length;
        require(len > 0, "len err");
        for(uint256 i = 0; i < len; i++) {
            claim(user, pool, pid[i]);
        }
    }

    function _setIsResubmit(address user, address pool, uint256 pid, bool isResubmit) internal {
        userInfo[user][pool][pid].isResubmit = isResubmit;

        emit SetIsResubmit(user, pool, pid, isResubmit);
    }

    function _transferProfit(
        address pool,
        address token, 
        address account, 
        uint256 pid,
        uint256 amount
    ) internal {
        TransferAmountData memory tData = _safeTransfer(token, account, amount);

        emit TransferProfit(address(this), account, pool, pid, amount, tData);
    }

    function _transferRisk(
        address pool,
        address token, 
        address account, 
        uint256 pid,
        uint256 amount
    ) internal {
        TransferAmountData memory tData = _safeTransfer(token, account, amount);

        emit TransferRisk(address(this), account, pool, pid, amount, tData);
    }

    function _safeTransfer(
        address token, 
        address account, 
        uint256 amount
    ) internal returns(TransferAmountData memory tData)  {
        tData.beforeAmount = getAmount(token, address(this));
        tData.beforeValue = getAmount(token, account);
        IERC20(token).safeTransfer(account, amount);
        tData.afterAmount = getAmount(token, address(this));
        tData.afterValue = getAmount(token, account);
    }

    function _depoitToNext(
        address pool, 
        address user, 
        uint256 nextPid,
        uint256 amount, 
        uint256 lpAmount,
        bool isResubmit
    ) internal {
        uint256 value = errContractV2.getDepositLpAmount(pool, nextPid, amount, true);
        if(remainUsers[pool][nextPid].contains(user)) {
            isResubmit = userInfo[user][pool][nextPid].isResubmit;
        }
        IERC20Metadata(lpToken).burn(lpAmount);
        _deposit(user, pool, nextPid, amount, value, isResubmit, true);
    }

    function _compoundToNext(
        address pool, 
        address user, 
        uint256 pid, 
        uint256 nextPid
    ) internal returns(bool) {     
        if(userInfo[user][pool][pid].isResubmit) {
            (uint256 amount, uint256 lpAmount, bool isAll) = errContractV2.getUserCompoundAmount(pool, user, pid);
            _depoitToNext(pool, user, nextPid, amount, lpAmount, userInfo[user][pool][pid].isResubmit);

            if(amount > 0) {
                foundState[pool][nextPid].actCompoundAmount += amount;
            }

            if(lpAmount > 0) {
                foundState[pool][pid].totalNextLpAmount += lpAmount;
                userInfo[user][pool][pid].nextLpAmount = lpAmount;
            }

            compoundUsers[pool][pid].add(user);
            
            emit CompoundToNext(pool, user, pid, nextPid, isAll);

            if(isAll) {
                if(userInfo[user][pool][pid].nextLpAmount != userInfo[user][pool][pid].lpAmount) {
                    trendsUsers[pool][pid].add(user);
                }
                foundState[pool][pid].isAllResubmit = true;
                return true;
            }
        } else {
            trendsUsers[pool][pid].add(user);
            if(remainUsers[pool][pid].length() + previousUsers[pool][pid].length() == 0) {
                foundState[pool][pid].isAllResubmit = true;
                emit CompoundToNext(pool, user, pid, nextPid, true);
            }
            emit TrendsUsers(pool, user, pid, nextPid);
        }
        return false;
    }

    function _compoundRemain(
        address pool, 
        uint256 pid, 
        uint256 nextPid,
        uint256 number
    ) internal {
        if(number > 0 && !foundState[pool][pid].isAllResubmit) {
            for(uint256 i = number; i > 0; i--) {
                address user = remainUsers[pool][pid].at(i-1);
                remainUsers[pool][pid].remove(user);
                if(_compoundToNext(pool, user, pid, nextPid)) {
                    break; 
                }
            }
        }

    }

    function _compound(
        address pool, 
        uint256 pid, 
        uint256 nextPid,
        uint256 number
    ) internal {
        if(pid > 1) {
            uint256 num = previousUsers[pool][pid].length();

            if(number > num) {
                number = num;
            }
            if(number > 0 && !foundState[pool][pid].isAllResubmit) {
                for(uint256 i = 0; i < number; i++) {
                    address user = previousUsers[pool][pid].at(0);
                    previousUsers[pool][pid].remove(user);
                    if(_compoundToNext(pool, user, pid, nextPid)) {
                        break; 
                    }
                }
            }
        }
    }

    function _deposit(
        address user, 
        address pool, 
        uint256 pid,
        uint256 amount,
        uint256 value,
        bool isResubmit,
        bool isLastIn
    ) internal {       
        uint256 did = ++userInfo[user][pool][pid].depositID;
        userPerInfo[user][pool][pid][did].fundAmount = amount;
        userPerInfo[user][pool][pid][did].lpAmount = value;
        userPerInfo[user][pool][pid][did].depositTime = block.timestamp;
        userPerInfo[user][pool][pid][did].isLastIn = isLastIn;
        userInfo[user][pool][pid].isResubmit = isResubmit;
        userInfo[user][pool][pid].fundAmount += amount;
        userInfo[user][pool][pid].lpAmount += value;

        DepositEvent memory dEvent = DepositEvent(
                address(0),
                user, 
                pool, 
                pid, 
                amount, 
                value, 
                userPerInfo[user][pool][pid][did].depositTime, 
                isResubmit, 
                isLastIn, 
                0, 
                0, 
                0, 
                0
        );

        if(pid == 1) {
            remainUsers[pool][pid].remove(user);
            remainUsers[pool][pid].add(user);
            lastTime[user][pool][pid] = userPerInfo[user][pool][pid][did].depositTime;
        } else {
            if(!isLastIn) {
                if(
                    userInfo[user][pool][pid].fundAmount >= 
                    userInfo[user][pool][pid-1].fundAmount * txInfo[pool].txRate / baseRate
                ) {
                    if(!userInfo[user][pool][pid].isUpdate) {
                        userInfo[user][pool][pid].isUpdate = true;
                        remainUsers[pool][pid].remove(user);
                        remainUsers[pool][pid].add(user);
                    }
                    lastTime[user][pool][pid] = userPerInfo[user][pool][pid][did].depositTime;
                } else {
                    remainUsers[pool][pid].add(user);
                }
            } else {
                if(!userInfo[user][pool][pid].isUpdate) {
                    remainUsers[pool][pid].remove(user);
                    previousUsers[pool][pid].add(user);
                }
            }
        }

        IERC20Metadata(lpToken).mint(address(this), value);
        foundState[pool][pid].depositAmount += amount;
        foundState[pool][pid].totalLpAmount += value;
        address token = poolToken[pool];

        if(!isLastIn) {
            uint256 beforeAmount = getAmount(token, user);
            uint256 beforeValue = getAmount(token, pool);
            IERC20(token).safeTransferFrom(user, pool, amount);
            uint256 afterAmount = getAmount(token, user);
            uint256 afterValue = getAmount(token, pool);

            dEvent.sender = user;
            dEvent.beforeAmount = beforeAmount;
            dEvent.afterAmount = afterAmount;
            dEvent.beforeValue = beforeValue;
            dEvent.afterValue = afterValue;
            emit Deposit(dEvent);
        } else {
            TransferAmountData memory tData = _safeTransfer(token, pool, amount);

            dEvent.sender =  address(this);
            dEvent.beforeAmount = tData.beforeAmount;
            dEvent.afterAmount = tData.afterAmount;
            dEvent.beforeValue = tData.beforeValue;
            dEvent.afterValue = tData.afterValue;
            emit Deposit(dEvent);
        }
    }

    function getUsersLength(address pool, uint256 pid, uint8 userType) external view returns(uint256) {
        if(userType == 1) {
            return remainUsers[pool][pid].length();
        }

        if(userType == 2) {
            return trendsUsers[pool][pid].length();
        }

        if(userType == 3) {
            return compoundUsers[pool][pid].length();
        }

        if(userType == 4) {
            return previousUsers[pool][pid].length();
        }       
        return 0;
    }

    function getUsersAddr(
        address pool, 
        uint256 pid, 
        uint8 userType, 
        uint256 index
    ) external view returns(address) {
        if(userType == 1) {
            return remainUsers[pool][pid].at(index);
        }

        if(userType == 2) {
            return trendsUsers[pool][pid].at(index);
        }

        if(userType == 3) {
            return compoundUsers[pool][pid].at(index);
        }

        if(userType == 4) {
            return previousUsers[pool][pid].at(index);
        } 

        return address(0);
    }

    function getUsersContains(address pool, uint256 pid, uint8 userType, address user) external view returns(bool) {
        if(userType == 1) {
            return remainUsers[pool][pid].contains(user);
        }

        if(userType == 2) {
            return trendsUsers[pool][pid].contains(user);
        }

        if(userType == 3) {
            return compoundUsers[pool][pid].contains(user);
        }

        if(userType == 4) {
            return previousUsers[pool][pid].contains(user);
        } 
        return false;
    }

    function getFoundState(address pool, uint256 pid) external view returns(FoundStateV2 memory) {
        return foundState[pool][pid];
    }

    function getFoundInfo(address pool, uint256 pid) external view returns(FundInfoV2 memory) {
        return fundInfo[pool][pid];
    }

    function getUserInfo(address user, address pool, uint256 pid) external view returns(UserInfoV2 memory) {
        return userInfo[user][pool][pid];
    }

    function getUserPerInfo(address user, address pool, uint256 pid, uint256 depositID) external view returns(UserPerInfo memory) {
        return userPerInfo[user][pool][pid][depositID];
    }

    function getTxInfo(address pool) external view returns(TxInfo memory) {
        return txInfo[pool];
    }

    function getFundraisingAmount(address pool, uint256 pid) external view returns(uint256) {
        return foundState[pool][pid].currFundraisingAmount;
    }

    function getAmount(address token, address account) public view returns(uint256) {
        return IERC20(token).balanceOf(account);
    }
}
