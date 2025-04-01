// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IStruct.sol";
import "./interfaces/IFundFactoryV2.sol";
import "../../core/interfaces/IERC20Metadata.sol";
import "./interfaces/IPoolDataV2.sol";
import "../../core/interfaces/IVault.sol";
import "../../Pendant/interfaces/IPhase.sol";

contract FundReader is IStruct {
    IVault public vault;
    IFundFactoryV2 public factoryV2;

    IPoolDataV2 public poolDataV2;
    IPhase public phase;
    uint256 public deciCounter;
    address public gov;

    constructor() {
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
        address vault_,
        address factoryV2_,
        address poolDataV2_,
        address phase_
    ) external onlyGov {
        vault = IVault(vault_);
        factoryV2 = IFundFactoryV2(factoryV2_);
        poolDataV2 = IPoolDataV2(poolDataV2_);
        phase = IPhase(phase_);

        deciCounter = 10 ** IERC20Metadata(poolDataV2.lpToken()).decimals();
    }

    function getLpValue(address pool, uint256 pid, address tokenOut, uint256 glpAmount) external view returns(uint256) {
        FoundStateV2 memory fState = poolDataV2.getFoundState(pool, pid);
        uint256 dValue = fState.fundraisingValue;

        uint256 value = getPidValue(tokenOut, glpAmount);

        return dValue * (1e18) / value;
    }

    function getPidValue(address tokenOut, uint256 glpAmount) public view returns(uint256) {
        uint256 amount = getOutAmount(tokenOut, glpAmount);
        uint256 price = getPrice(tokenOut);

        uint256 deci = 10 ** IERC20Metadata(tokenOut).decimals();
        return amount * price * (10 ** 18) / 1e30 / deci;
    }

    function getTokenValue(address token, uint256 amount) external view returns(uint256) {
        uint256 price = getPrice(token);

        uint256 deci = 10 ** IERC20Metadata(token).decimals();

        uint256 _amount =  amount * price / 1e30;
        
        return _amount *  (10 ** 18) /  deci;
    }

    function getOutAmount(address tokenOut, uint256 glpAmount) public view returns(uint256) {
        return phase.getOutAmount(tokenOut, tokenOut, glpAmount);
    }

    function getPrice(address token) public view returns(uint256) {
        uint256 maxPrice = vault.getMaxPrice(token);
        uint256 minPrice = vault.getMinPrice(token);

        uint256 price = (maxPrice + minPrice) / 2;
        require(
            maxPrice > 0 && 
            minPrice > 0 &&
            price + 1 >= minPrice, 
            "price err"
        );

        return price;
    }

    function isGlpAuth(address pool) external view returns(bool) {
        return factoryV2.poolOwner(pool)  != address(0);
    }

    function getCurrPool() external view returns(address) {
        return poolDataV2.currPool();
    }

    function getLastPool() external view returns(address) {
        return poolDataV2.lastPool();
    }

    // ****************************************

    function getDepositLpAmount(
        address pool, 
        uint256 pid,
        uint256 amount,
        bool isNext
    ) public view returns(uint256 value) {
        value = _getDepositLpAmount(pool, pid, amount, isNext);
        require(value > 0, "value err");
    }

    function _getDepositLpAmount(
        address pool, 
        uint256 pid,
        uint256 amount,
        bool isNext
    ) internal view returns(uint256) {
        if(pid == 0) {
            return 0;
        }

        address token = poolDataV2.poolToken(pool);
        uint256 deci = 10 ** IERC20Metadata(token).decimals();
        if(pid == 1) {
            return amount * deciCounter / deci;
        } 

        if(isNext) {
            FoundStateV2 memory fState = poolDataV2.getFoundState(pool, pid);
            if(fState.depositAmount > 0) {
                uint256 price = 1e18 * (fState.totalLpAmount * deci) / (deciCounter * fState.depositAmount);
                return amount * deciCounter * price / deci  / 1e18;
            } else {
                return amount * deciCounter / deci;
            }
        }

        FoundStateV2 memory fState1 = poolDataV2.getFoundState(pool, pid-1);

        if(fState1.glpAmount > 0) {
            uint256 outAmount = getOutAmount(token, fState1.glpAmount);
            if(outAmount == 0) {
                return amount * deciCounter / deci;
            }
            return (amount * 1e18 * fState1.totalLpAmount) / (outAmount  *  deciCounter);
        } else {
            return amount * deciCounter / deci;
        }
    }

    function getCompoundAmountFormPrevious(address pool, uint256 pid) external view returns(uint256) {
        if(pid <= 1) {
            return 0;
        }
        FoundStateV2 memory fState = poolDataV2.getFoundState(pool, pid);
        if(fState.isGet) {
            return fState.needCompoundAmount;
        }

        FoundStateV2 memory fState1 = poolDataV2.getFoundState(pool, pid-1);
        uint256 outAmount;
        if(fState1.isClaim) {
            outAmount = fState1.outAmount;
        } else {
            address token = poolDataV2.poolToken(pool);
            outAmount = getOutAmount(token, fState1.glpAmount);
        }

        uint256 fAmount = poolDataV2.getFundraisingAmount(pool, pid);
        if(outAmount >= fState.depositAmount) {
            if(outAmount > fAmount) {
                return outAmount - fState.depositAmount;
            }
            return fAmount - fState.depositAmount;
        } else {
            if(fAmount > fState.depositAmount) {
                return fAmount - fState.depositAmount;
            }
            return 0; 
        }
    }

    function getUserCompoundAmount(
        address pool, 
        address user,
        uint256 pid
    ) external view returns(uint256 amount, uint256 lpAmount, bool isAll) {
        (amount, lpAmount, isAll) = _getUserCompoundAmount(pool, user, pid);
        if(!isAll) {
            if((poolDataV2.getUsersLength(pool, pid, 1) + poolDataV2.getUsersLength(pool, pid, 4)) == 0) {
                isAll = true;
            }
        }
    }

    function _getUserCompoundAmount(
        address pool, 
        address user,
        uint256 pid
    ) internal view returns(uint256, uint256, bool) {
        if(pid < 1) {
            return (0, 0, true);
        }
        UserInfoV2 memory uInfo = poolDataV2.getUserInfo(user, pool, pid);
        FoundStateV2 memory fState = poolDataV2.getFoundState(pool, pid);
        FoundStateV2 memory fState1 = poolDataV2.getFoundState(pool, pid+1);
        if(fState1.actCompoundAmount >= fState1.needCompoundAmount || fState.isAllResubmit) {
            return (0, 0, true);
        }

        uint256 remain = fState1.needCompoundAmount - fState1.actCompoundAmount;
        uint256 amount = fState.outAmount * uInfo.lpAmount / fState.totalLpAmount;
        if(remain > amount) {
            return (amount, uInfo.lpAmount, false);
        } else {
            uint256 rLp = uInfo.lpAmount * remain / amount;
            return (remain, rLp, true);
        }
    }
}